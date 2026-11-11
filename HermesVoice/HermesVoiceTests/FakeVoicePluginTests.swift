import XCTest
@testable import HermesVoice

/// The real VoiceLink and plugin routes against `devtools/fake_voice_plugin.py` (mounted by fake_hermes.py): the wire
/// contract end to end over a real WebSocket. Skipped unless `HERMES_FAKE_URL` is set, e.g.
/// `TEST_RUNNER_HERMES_FAKE_URL=http://127.0.0.1:9311 xcodebuild test …` with `fake_hermes.py --port 9311` running.
@MainActor
final class FakeVoicePluginTests: XCTestCase {
    private var client: DashboardClient!
    private var events: [VoiceLink.Event] = []

    override func setUp() async throws {
        guard let url = ProcessInfo.processInfo.environment["HERMES_FAKE_URL"] else {
            throw XCTSkip("Set HERMES_FAKE_URL to run against devtools/fake_hermes.py.")
        }
        let client = try DashboardClient(settings: ConnectionSettings(dashboardURL: url, username: "test", password: "test"))
        try await client.signIn()
        self.client = client
        events = []
    }

    override func tearDown() async throws {
        client = nil
    }

    private func link(_ hello: PhoneHello) -> VoiceLink {
        let link = VoiceLink(client: client, hello: hello)
        link.onEvent = { [weak self] event in self?.events.append(event) }
        return link
    }

    private var messages: [PluginMessage] {
        events.compactMap { if case let .message(message) = $0 { return message } else { return nil } }
    }

    private var speechStarts: [(id: String, text: String)] {
        messages.compactMap { if case let .speechStart(id, text, _) = $0 { return (id, text) } else { return nil } }
    }

    private func speechEnded(_ id: String) -> Bool {
        messages.contains { if case let .speechEnd(end, false, nil) = $0 { return end == id } else { return false } }
    }

    private var closes: [VoiceLink.Close] {
        events.compactMap { if case let .closed(reason) = $0 { return reason } else { return nil } }
    }

    /// Waits for `condition` while the link is up: a link the plugin closed (busy, say) fails at once, saying why.
    private func waitOnLink(timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        await waitUntil(timeout: timeout, file: file, line: line) { condition() || !self.closes.isEmpty }
        XCTAssertEqual(closes, [], "the plugin closed the link", file: file, line: line)
    }

    /// Waits until the plugin let the call go after a bye, so a bye it never read fails the test that hung up
    /// rather than the next one (as busy: the plugin would hold the slot for a reconnect).
    private func waitForCallToEnd(file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while let call = try await VoicePluginAPI.status(client).activeCall {
            guard Date() < deadline else {
                return XCTFail("the plugin still holds call \(call.callID) (\(call.state)) after the bye", file: file, line: line)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func session() async throws -> SessionSummary {
        let sessions = try await client.profileSessions(profile: SidebarOptions.allProfiles, limit: 100, minMessages: 1).rows.map(\.summary)
        return try XCTUnwrap(sessions.first, "the fake seeds sessions")
    }

    func testRoutes() async throws {
        let status = try await VoicePluginAPI.status(client)
        XCTAssertEqual(status.tts, "fake")
        let voip = String(repeating: "ab", count: 32)
        try await VoicePluginAPI.registerDevice(client, body: PushRegistration.deviceBody(
            voipToken: voip, environment: "sandbox", bundleID: "com.example.hermesvoice", alertToken: nil, alerts: nil))
        let token = try await VoicePluginAPI.scribeToken(client)
        XCTAssertFalse(token.isEmpty)
    }

    /// The device the fake plugin keeps for `voip` (`GET /status` lists them, with the alerts each one gets).
    /// The fake's test knob: hold every device registration until released. Answers how many were waiting.
    @discardableResult
    private func holdDevices(_ hold: Bool) async throws -> Int {
        let result = try await client.request("POST", "\(VoicePluginAPI.path)/debug/hold-devices", body: ["hold": hold]) as? JSON
        return (result?["waiting"] as? Int) ?? -1
    }

    private func device(_ voip: String) async throws -> JSON? {
        let status = try await client.request("GET", "\(VoicePluginAPI.path)/status") as? JSON
        return (status?["devices"] as? [JSON])?.first { $0["voip_token"] as? String == voip }
    }

    private func alerts(_ device: JSON?) -> [String: Bool]? {
        device?["alerts"] as? [String: Bool]
    }

    func testRegistrationWithAndWithoutAnAlertToken() async throws {
        let voip = String(repeating: "c1", count: 32), alert = String(repeating: "d2", count: 32)
        func register(alertToken: String?, alerts: NotificationPreferences?) async throws {
            try await VoicePluginAPI.registerDevice(client, body: PushRegistration.deviceBody(
                voipToken: voip, environment: "sandbox", bundleID: "com.example.hermesvoice",
                alertToken: alertToken, alerts: alerts))
        }
        try await register(alertToken: alert, alerts: .defaults)
        var stored = try await device(voip)
        XCTAssertEqual(stored?["alert_token"] as? String, alert)
        XCTAssertEqual(alerts(stored), ["approval": true, "clarify": true, "turn_done": true])

        // A launch before iOS hands over the alert token: the opt-ins go through, the stored token stays.
        try await register(alertToken: nil, alerts: NotificationPreferences(approval: true, clarify: false, turnDone: true))
        stored = try await device(voip)
        XCTAssertEqual(stored?["alert_token"] as? String, alert)
        XCTAssertEqual(alerts(stored), ["approval": true, "clarify": false, "turn_done": true])

        // Signing out registers no alerts at all.
        try await register(alertToken: nil, alerts: NotificationPreferences.none)
        stored = try await device(voip)
        XCTAssertEqual(alerts(stored), ["approval": false, "clarify": false, "turn_done": false])
    }

    func testPushRegistrationSendsTheLatestStateInOrder() async throws {
        let voip = String(repeating: "e3", count: 32), alert = String(repeating: "f4", count: 32)
        let push = PushRegistration()
        push.useTokens(voip: voip, alert: alert)
        push.setAlerts(.defaults)
        // A change while the first registration is on its way goes out after it, so the last state wins. The fake
        // holds the first upload until the change is made, so it is really in flight.
        try await holdDevices(true)
        addTeardownBlock { [client] in
            _ = try? await client?.request("POST", "\(VoicePluginAPI.path)/debug/hold-devices", body: ["hold": false])
        }
        let first = Task { await push.send(to: client) }
        var waiting = 0
        for _ in 0..<250 where waiting == 0 {
            waiting = try await holdDevices(true)
            if waiting == 0 { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(waiting, 1, "the first upload is held by the fake")
        XCTAssertEqual(push.upload, .sending)
        push.setAlerts(NotificationPreferences(approval: false, clarify: true, turnDone: false))
        let second = Task { await push.send(to: client) }
        let held = try await holdDevices(false)
        XCTAssertEqual(held, 1, "only the first upload was on its way; the change waits for it")
        await first.value
        await second.value
        guard case .sent = push.upload else { return XCTFail("upload is \(push.upload)") }
        let stored = try await device(voip)
        XCTAssertEqual(stored?["alert_token"] as? String, alert)
        XCTAssertEqual(alerts(stored), ["approval": false, "clarify": true, "turn_done": false])

        // An upload that can't reach the dashboard says so.
        let offline = try DashboardClient(settings: ConnectionSettings(dashboardURL: "http://127.0.0.1:9", username: "test",
                                                                       password: "test"))
        await push.send(to: offline)
        guard case .failed = push.upload else { return XCTFail("upload is \(push.upload)") }
    }

    /// The test alerts the fake plugin kept (`GET debug/test-alerts`), oldest first.
    private func testAlerts() async throws -> [JSON] {
        let listed = try await client.request("GET", "\(VoicePluginAPI.path)/debug/test-alerts") as? JSON
        return listed?["tests"] as? [JSON] ?? []
    }

    func testTestAlertIsSentAfterItsDelayAndAnsweredWithoutTheGateway() async throws {
        let voip = String(repeating: "a7", count: 32), alert = String(repeating: "b8", count: 32)
        try await VoicePluginAPI.registerDevice(client, body: PushRegistration.deviceBody(
            voipToken: voip, environment: "sandbox", bundleID: "com.example.hermesvoice", alertToken: alert, alerts: .defaults))
        let notifications = AlertNotifications()
        notifications.testPollInterval = 0.05
        notifications.testClient = { [client] in try XCTUnwrap(client) }
        var connected = 0
        notifications.connect = { client in
            connected += 1
            return GatewayConnection(client: client)
        }

        // Settings > Notifications > Send test notification: scheduled, with the hint to lock the phone.
        await notifications.requestTest(.approval, client: client, voipToken: voip, alertToken: alert, delay: 0.4)
        let scheduled = try XCTUnwrap(notifications.test)
        XCTAssertEqual(scheduled.phase, .scheduled)
        XCTAssertTrue(TestAlertRow(scheduled, delay: 0.4).busy)
        XCTAssertTrue(scheduled.message.contains("Lock the iPhone"), scheduled.message)
        let id = try XCTUnwrap(scheduled.id)
        await waitUntil(timeout: 5) { notifications.test?.phase == .sent }
        XCTAssertTrue(notifications.test?.message.contains("APNs accepted") == true, notifications.test?.message ?? "nil")
        XCTAssertFalse(TestAlertRow(notifications.test, delay: 0.4).isError)

        // What the phone would have got: the plugin's payload, to this phone's alert token.
        let kept = try await testAlerts()
        let sent = try XCTUnwrap(kept.last { $0["test_id"] as? String == id })
        XCTAssertEqual(sent["sent_to"] as? [String], [alert])
        let push = try XCTUnwrap(AlertPush(userInfo: try XCTUnwrap(sent["payload"] as? JSON)))
        XCTAssertTrue(push.isTest)
        XCTAssertEqual(push.testID, id)
        XCTAssertEqual(push.category, AlertCategory.approval)
        XCTAssertEqual(AlertNotifications.presentation(for: push, sessionOnScreen: true), [.banner, .list, .sound])

        // "Run" on the lock screen: confirmed here, reported to the plugin, and no request.answer.
        await notifications.handle(action: AlertAction.run, text: nil, push: push)
        XCTAssertEqual(notifications.test, TestAlertState(kind: .approval, id: id, phase: .answered,
                                                         message: "Test approval answered: Run. Nothing was run."))
        XCTAssertEqual(connected, 0)
        let answered = try await VoicePluginAPI.testAlertStatus(client, id: id)
        XCTAssertEqual(answered.status, .answered)
        XCTAssertEqual(answered.action, "once")
    }

    func testTestAlertOfEachKindAndItsReply() async throws {
        let voip = String(repeating: "c9", count: 32), alert = String(repeating: "da", count: 32)
        try await VoicePluginAPI.registerDevice(client, body: PushRegistration.deviceBody(
            voipToken: voip, environment: "sandbox", bundleID: "com.example.hermesvoice", alertToken: alert, alerts: .defaults))
        let notifications = AlertNotifications()
        notifications.testClient = { [client] in try XCTUnwrap(client) }
        for kind in AlertPush.Kind.allCases {
            await notifications.requestTest(kind, client: client, voipToken: voip, alertToken: alert, delay: 0)
            XCTAssertEqual(notifications.test?.phase, .sent, "\(kind)")
            let id = try XCTUnwrap(notifications.test?.id)
            let kept = try await testAlerts()
            let sent = try XCTUnwrap(kept.last { $0["test_id"] as? String == id })
            let push = try XCTUnwrap(AlertPush(userInfo: try XCTUnwrap(sent["payload"] as? JSON)))
            XCTAssertEqual(push.kind, kind)
            XCTAssertTrue(push.isTest)
            XCTAssertEqual(push.category, [.approval: "HERMES_APPROVAL", .clarify: "HERMES_CLARIFY", .turnDone: "HERMES_TURN_DONE"][kind])
            let action = [.approval: AlertAction.reject, .clarify: AlertAction.reply, .turnDone: AlertAction.open][kind] ?? ""
            await notifications.handle(action: action, text: kind == .clarify ? "blue" : nil, push: push)
            XCTAssertEqual(notifications.test?.phase, .answered, "\(kind)")
            let reported = try await VoicePluginAPI.testAlertStatus(client, id: id)
            XCTAssertEqual(reported.action, [.approval: "deny", .clarify: "reply", .turnDone: "open"][kind], "\(kind)")
            XCTAssertFalse(reported.message.contains("blue"), "the reply's text stays on the phone")
        }
        XCTAssertNil(notifications.openRequest)
    }

    func testTestAlertFailuresAreSaidInPlace() async throws {
        let notifications = AlertNotifications()
        // A phone the plugin never heard of.
        await notifications.requestTest(.approval, client: client, voipToken: String(repeating: "0e", count: 32), alertToken: nil)
        XCTAssertEqual(notifications.test?.phase, .failed)
        XCTAssertTrue(notifications.test?.message.contains("isn't registered") == true, notifications.test?.message ?? "nil")
        XCTAssertTrue(TestAlertRow(notifications.test, delay: 5).isError)

        // Registered for calls only: iOS gave no alert token (notifications never allowed). The explicit null clears
        // the token an earlier run against the same fake left there.
        let voip = String(repeating: "eb", count: 32), alert = String(repeating: "fc", count: 32)
        var callsOnly = PushRegistration.deviceBody(voipToken: voip, environment: "sandbox", bundleID: "com.example.hermesvoice",
                                                    alertToken: nil, alerts: .defaults)
        callsOnly["alert_token"] = NSNull()
        try await VoicePluginAPI.registerDevice(client, body: callsOnly)
        await notifications.requestTest(.approval, client: client, voipToken: voip, alertToken: nil)
        XCTAssertTrue(notifications.test?.message.contains("no notification token") == true, notifications.test?.message ?? "nil")

        // Question alerts turned off on this phone.
        try await VoicePluginAPI.registerDevice(client, body: PushRegistration.deviceBody(
            voipToken: voip, environment: "sandbox", bundleID: "com.example.hermesvoice", alertToken: alert,
            alerts: NotificationPreferences(approval: true, clarify: false, turnDone: true)))
        await notifications.requestTest(.clarify, client: client, voipToken: voip, alertToken: alert)
        XCTAssertEqual(notifications.test, .failed(.clarify, "This iPhone has question notifications turned off.", id: notifications.test?.id))

        // A request the plugin refuses says why in its own words; a test it doesn't keep isn't "not installed".
        do {
            _ = try await VoicePluginAPI.testAlert(client, body: ["voip_token": voip, "kind": "approval", "delay_s": 99])
            XCTFail("a delay of 99 s is refused")
        } catch let VoicePluginAPI.Failure.refused(detail) {
            XCTAssertTrue(detail.contains("delay_s"), detail)
        }
        do {
            _ = try await VoicePluginAPI.testAlertStatus(client, id: "0000000000000000")
            XCTFail("no such test")
        } catch let VoicePluginAPI.Failure.refused(detail) {
            XCTAssertTrue(detail.contains("No such test notification"), detail)
        }
    }

    func testUserCallHearsHermesAndSendsTurns() async throws {
        let session = try await session()
        let callID = CallID.make()
        let link = link(PhoneHello(callID: callID, sessionID: session.id, title: session.title, initiatedBy: .user))
        await link.connect()
        await waitOnLink(timeout: 5) { self.messages.contains(.ready(callID: callID, ringing: false)) }

        // The plugin announces the call to the session; the fake agent greets with start_call.
        await waitOnLink(timeout: 10) { self.speechStarts.first.map { self.speechEnded($0.id) } ?? false }
        let greeting = try XCTUnwrap(speechStarts.first)
        XCTAssertTrue(events.contains { if case .message(.audio) = $0 { return true } else { return false } }, "PCM frames")
        link.send(.played(greeting.id))

        let now = Date()
        link.send(.userTurn(UserTurn(callID: callID, text: "blue", ending: .endOfSpeech(detector: "typed", detail: nil),
                                     provider: .apple, language: "en-US", startedAt: now, endedAt: now)))
        await waitOnLink(timeout: 10) { self.speechStarts.count >= 2 }
        XCTAssertTrue(speechStarts[1].text.contains("blue"), speechStarts[1].text)

        // A turn the user ended with Send now is a finished turn like any other.
        await waitOnLink(timeout: 10) { self.speechEnded(self.speechStarts[1].id) }
        link.send(.played(speechStarts[1].id))
        let later = Date()
        link.send(.userTurn(UserTurn(callID: callID, text: "green", ending: .endOfSpeech(detector: "send_now", detail: nil),
                                     provider: .scribe, language: nil, startedAt: later, endedAt: later)))
        await waitOnLink(timeout: 10) { self.speechStarts.count >= 3 }
        XCTAssertTrue(speechStarts.count >= 3 && speechStarts[2].text.contains("green"), "\(speechStarts.map(\.text))")

        link.close(after: [.bye("hang_up")])
        XCTAssertFalse(events.contains { if case .closed = $0 { return true } else { return false } })
        try await waitForCallToEnd()
    }

    func testHangingUpWhileHermesSpeaksEndsTheCall() async throws {
        // The bye goes out while the plugin is still streaming the greeting: it must read it and end the call,
        // not take the close for a dropped link and hold the call for a reconnect.
        let session = try await session()
        let callID = CallID.make()
        let link = VoiceLink(client: client, hello: PhoneHello(callID: callID, sessionID: session.id, title: session.title,
                                                               initiatedBy: .user))
        var hungUp = false
        link.onEvent = { [weak self, weak link] event in
            self?.events.append(event)
            if !hungUp, case .message(.speechStart) = event {
                hungUp = true
                link?.close(after: [.bye("hang_up")])
            }
        }
        await link.connect()
        await waitOnLink(timeout: 10) { hungUp }
        try await waitForCallToEnd()
    }

    func testAgentRingsAndThePhoneAnswers() async throws {
        let session = try await session()
        let result = try await client.request("POST", "\(VoicePluginAPI.path)/debug/ring",
                                              body: ["session_id": session.id, "mode": "async", "text": "Pick a color"]) as? JSON
        let payload = (result?["push"] as? JSON) ?? result ?? [:]
        let push = try XCTUnwrap(CallPush(payload: payload), "debug/ring returns the push: \(String(describing: result))")

        let link = link(PhoneHello(callID: push.callID, sessionID: push.sessionID, title: push.title, initiatedBy: .push))
        await link.connect()
        await waitOnLink(timeout: 5) { self.messages.contains(.ready(callID: push.callID, ringing: true)) }
        link.send(.ringing)
        link.send(.answered)
        await waitOnLink(timeout: 10) { self.speechStarts.contains { $0.text.contains("Pick a color") } }
        link.close(after: [.bye("hang_up")])
        try await waitForCallToEnd()
    }

    func testUnknownPushCallIsCancelled() async throws {
        // A hello for a push call the plugin doesn't know is cancelled, not refused.
        let link = link(PhoneHello(callID: CallID.make(), sessionID: nil, title: nil, initiatedBy: .push))
        await link.connect()
        await waitUntil(timeout: 5) { self.messages.contains { if case .cancel = $0 { return true } else { return false } } }
    }
}
