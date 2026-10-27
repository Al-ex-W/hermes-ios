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
        // A change while the first registration is on its way goes out after it, so the last state wins.
        let first = Task { await push.send(to: client) }
        // Against a fake on the loopback the first upload can finish between two polls: then the change goes out
        // after it all the same.
        await waitUntil(timeout: 5) {
            if case .sent = push.upload { return true }
            return push.upload == .sending
        }
        push.setAlerts(NotificationPreferences(approval: false, clarify: true, turnDone: false))
        await push.send(to: client)
        await first.value
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
