import XCTest
@testable import HermesVoice

/// Location sharing end to end against `devtools/fake_hermes.py` (its fake hermes_voice plugin): the registration's
/// `location` flag, a request answered by `POST …/location` as after a background push, and one answered over a
/// call's socket. Skipped unless `HERMES_FAKE_URL` is set (see FakeVoicePluginTests).
@MainActor
final class FakeLocationTests: XCTestCase {
    private var client: DashboardClient!
    private var source: StubLocationSource!
    private var sharing: LocationSharing!
    private var suite = ""
    /// This test class's own phone, so the other classes' registrations don't matter.
    private let voip = String(repeating: "a7", count: 32), alert = String(repeating: "b8", count: 32)

    override func setUp() async throws {
        guard let url = ProcessInfo.processInfo.environment["HERMES_FAKE_URL"] else {
            throw XCTSkip("Set HERMES_FAKE_URL to run against devtools/fake_hermes.py.")
        }
        let client = try DashboardClient(settings: ConnectionSettings(dashboardURL: url, username: "test", password: "test"))
        try await client.signIn()
        self.client = client
        suite = "FakeLocationTests-\(UUID().uuidString)"
        source = StubLocationSource(access: .always)
        sharing = LocationSharing(source: source, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        sharing.client = { client }
        sharing.tokens = { [voip, alert] in (voip, alert) }
    }

    override func tearDown() async throws {
        if client != nil {
            // Leave the fake with no phone that shares, as the other tests found it.
            try? await register(["enabled": false, "background": false])
        }
        UserDefaults().removePersistentDomain(forName: suite)
        client = nil
        sharing = nil
        source = nil
    }

    private func register(_ location: [String: Bool]?) async throws {
        try await VoicePluginAPI.registerDevice(client, body: PushRegistration.deviceBody(
            voipToken: voip, environment: "sandbox", bundleID: "com.example.hermesvoice", alertToken: alert, alerts: nil,
            location: location))
    }

    /// The fake asks the phone as `get_location` would, and says how (`via`) and with which id.
    private func ask() async throws -> JSON {
        let answer = try await client.request("POST", "\(VoicePluginAPI.path)/debug/location-request", body: [:])
        return try XCTUnwrap(answer as? JSON)
    }

    /// What the fake knows: `{sharing, fix, requests}`.
    private func known() async throws -> JSON {
        let answer = try await client.request("GET", "\(VoicePluginAPI.path)/debug/location")
        return try XCTUnwrap(answer as? JSON)
    }

    private func request(_ id: String) async throws -> JSON? {
        (try await known()["requests"] as? [JSON])?.first { $0["request_id"] as? String == id }
    }

    func testABackgroundRequestIsAnsweredWithTheFix() async throws {
        // Off (the default): the plugin knows, asks nobody, and takes no position.
        try await register(sharing.registration)
        XCTAssertEqual(sharing.registration, ["enabled": false, "background": false])
        var asked = try await ask()
        XCTAssertEqual(asked["status"] as? String, "sharing_off")
        var status = try await VoicePluginAPI.status(client)
        XCTAssertEqual(status.location?.sharing, false)

        sharing.setEnabled(true)
        try await register(sharing.registration)
        status = try await VoicePluginAPI.status(client)
        XCTAssertEqual(status.location?.sharing, true)

        // Asked with no call up: a background push, which the fake only records. The app answers it as it would
        // when iOS hands it the push.
        asked = try await ask()
        XCTAssertEqual(asked["via"] as? String, "push")
        XCTAssertEqual(asked["sent_to"] as? [String], [alert])
        let payload = try XCTUnwrap(asked["payload"] as? [AnyHashable: Any])
        let push = try XCTUnwrap(LocationRequestPush(userInfo: payload), "the app reads the plugin's push")
        XCTAssertEqual(push.requestID, asked["request_id"] as? String)
        let sent = await sharing.handle(push)
        XCTAssertTrue(sent, sharing.lastProblem ?? "")
        let stored = try await known()
        let fix = try XCTUnwrap(stored["fix"] as? JSON)
        XCTAssertEqual(fix["latitude"] as? Double, 59.0)
        XCTAssertEqual(fix["longitude"] as? Double, 18.0)
        XCTAssertEqual(fix["accuracy_m"] as? Double, 12.5)
        XCTAssertEqual(fix["source"] as? String, "push")
        let answered = try await request(push.requestID)
        XCTAssertEqual(answered?["status"] as? String, "answered")
        XCTAssertNotNil(sharing.lastSent)

        // A phone that can't get a fix says so, and the plugin doesn't wait.
        source.next = .failure(.denied)
        asked = try await ask()
        let second = try XCTUnwrap((asked["payload"] as? [AnyHashable: Any]).flatMap(LocationRequestPush.init(userInfo:)))
        _ = await sharing.handle(second)
        let failed = try await request(second.requestID)
        XCTAssertEqual(failed?["status"] as? String, "failed")
        XCTAssertEqual(failed?["error"] as? String, "denied")

        // An answer nobody asked for is refused, in the plugin's words.
        source.next = .fix(LocationTests.fix)
        let unasked = await sharing.handle(LocationRequestPush(requestID: "0000000000000000"))
        XCTAssertFalse(unasked)
        XCTAssertEqual(sharing.lastProblem?.contains("Nobody asked"), true, sharing.lastProblem ?? "")

        // Off again: the plugin hears it with the registration, drops the fix and refuses a late answer.
        sharing.setEnabled(false)
        try await register(sharing.registration)
        let after = try await known()
        XCTAssertEqual(after["sharing"] as? Bool, false)
        XCTAssertTrue(after["fix"] is NSNull || after["fix"] == nil)
        let late = await sharing.handle(push)
        XCTAssertFalse(late)
    }

    func testOnACallTheRequestComesOverTheSocket() async throws {
        sharing.setEnabled(true)
        try await register(sharing.registration)
        let sessions = try await client.profileSessions(profile: SidebarOptions.allProfiles, limit: 100, minMessages: 1).rows.map(\.summary)
        let session = try XCTUnwrap(sessions.first, "the fake seeds sessions")
        let callID = CallID.make()
        var events: [VoiceLink.Event] = []
        let link = VoiceLink(client: client, hello: PhoneHello(callID: callID, sessionID: session.id, title: session.title,
                                                               initiatedBy: .user))
        link.onEvent = { events.append($0) }
        func closed() -> Bool { events.contains { if case .closed = $0 { return true } else { return false } } }
        await link.connect()
        await waitUntil(timeout: 5) { events.contains(.message(.ready(callID: callID, ringing: false))) || closed() }
        XCTAssertFalse(closed(), "the plugin closed the link")
        // Hear the fake agent's greeting out, as the app does, so its turn ends before this test does.
        func greeting() -> String? {
            let started = events.compactMap { event -> String? in
                if case let .message(.speechStart(id, _, _)) = event { return id } else { return nil }
            }
            return started.first { id in events.contains(.message(.speechEnd(id: id, cancelled: false, error: nil))) }
        }
        await waitUntil(timeout: 10) { greeting() != nil || closed() }
        if let heard = greeting() { link.send(.played(heard)) }

        let asked = try await ask()
        XCTAssertEqual(asked["via"] as? String, "call")
        let id = try XCTUnwrap(asked["request_id"] as? String)
        await waitUntil(timeout: 5) { events.contains(.message(.locationRequest(id))) || closed() }
        let answer = await sharing.answerOnCall()
        XCTAssertEqual(answer, .fix(LocationTests.fix))
        link.send(.location(id: id, answer))
        var fix: JSON?
        for _ in 0..<250 where fix == nil {
            fix = try await known()["fix"] as? JSON
            if fix == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(fix?["source"] as? String, "call")
        XCTAssertEqual(fix?["latitude"] as? Double, 59.0)
        let answered = try await request(id)
        XCTAssertEqual(answered?["status"] as? String, "answered")

        link.close(after: [.bye("hang_up")])
        let deadline = Date().addingTimeInterval(5)
        while try await VoicePluginAPI.status(client).activeCall != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let held = try await VoicePluginAPI.status(client).activeCall
        XCTAssertNil(held, "the plugin let the call go after the bye")
        // The fake agent answers the hang-up notice in a short turn of its own: let it finish, so the next test
        // finds the session idle.
        try await Task.sleep(for: .seconds(1))
    }
}
