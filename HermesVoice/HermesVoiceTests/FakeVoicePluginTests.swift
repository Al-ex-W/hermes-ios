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

    private func session() async throws -> SessionSummary {
        let sessions = try await client.sessions()
        return try XCTUnwrap(sessions.first, "the fake seeds sessions")
    }

    func testRoutes() async throws {
        let status = try await VoicePluginAPI.status(client)
        XCTAssertEqual(status.tts, "fake")
        try await VoicePluginAPI.registerDevice(client, voipToken: String(repeating: "ab", count: 32), environment: "sandbox",
                                                bundleID: "com.example.hermesvoice")
        let token = try await VoicePluginAPI.scribeToken(client)
        XCTAssertFalse(token.isEmpty)
    }

    func testUserCallHearsHermesAndSendsTurns() async throws {
        let session = try await session()
        let callID = CallID.make()
        let link = link(PhoneHello(callID: callID, sessionID: session.id, title: session.title, initiatedBy: .user))
        await link.connect()
        await waitUntil(timeout: 5) { self.messages.contains(.ready(callID: callID, ringing: false)) }

        // The plugin announces the call to the session; the fake agent greets with start_call.
        await waitUntil(timeout: 10) { self.speechStarts.first.map { self.speechEnded($0.id) } ?? false }
        let greeting = try XCTUnwrap(speechStarts.first)
        XCTAssertTrue(events.contains { if case .message(.audio) = $0 { return true } else { return false } }, "PCM frames")
        link.send(.played(greeting.id))

        let now = Date()
        link.send(.userTurn(UserTurn(callID: callID, text: "blue", ending: .endOfSpeech(detector: "typed", detail: nil),
                                     provider: .apple, language: "en-US", startedAt: now, endedAt: now)))
        await waitUntil(timeout: 10) { self.speechStarts.count >= 2 }
        XCTAssertTrue(speechStarts[1].text.contains("blue"), speechStarts[1].text)

        link.close(after: [.bye("hang_up")])
        XCTAssertFalse(events.contains { if case .closed = $0 { return true } else { return false } })
    }

    func testAgentRingsAndThePhoneAnswers() async throws {
        let session = try await session()
        let result = try await client.request("POST", "\(VoicePluginAPI.path)/debug/ring",
                                              body: ["session_id": session.id, "mode": "async", "text": "Pick a color"]) as? JSON
        let payload = (result?["push"] as? JSON) ?? result ?? [:]
        let push = try XCTUnwrap(CallPush(payload: payload), "debug/ring returns the push: \(String(describing: result))")

        let link = link(PhoneHello(callID: push.callID, sessionID: push.sessionID, title: push.title, initiatedBy: .push))
        await link.connect()
        await waitUntil(timeout: 5) { self.messages.contains(.ready(callID: push.callID, ringing: true)) }
        link.send(.ringing)
        link.send(.answered)
        await waitUntil(timeout: 10) { self.speechStarts.contains { $0.text.contains("Pick a color") } }
        link.close(after: [.bye("hang_up")])
    }

    func testUnknownPushCallIsCancelled() async throws {
        // A hello for a push call the plugin doesn't know is cancelled, not refused.
        let link = link(PhoneHello(callID: CallID.make(), sessionID: nil, title: nil, initiatedBy: .push))
        await link.connect()
        await waitUntil(timeout: 5) { self.messages.contains { if case .cancel = $0 { return true } else { return false } } }
    }
}
