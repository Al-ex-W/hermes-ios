import XCTest
@testable import HermesVoice

/// End to end against `devtools/fake_hermes.py` over the real WebSocket: chats, prompts and reconnects as the app
/// runs them. Skipped unless `HERMES_FAKE_URL` is set, e.g.
/// `TEST_RUNNER_HERMES_FAKE_URL=http://127.0.0.1:9311 TEST_RUNNER_HERMES_FAKE_REAP_GRACE=1 xcodebuild test …`
/// with the fake started as `fake_hermes.py --port 9311 --reap-grace 1`.
@MainActor
final class FakeHermesTests: XCTestCase {
    private var client: DashboardClient!
    private var connection: GatewayConnection!
    private var prompts: PromptCenter!
    private var transports: [WebSocketTransport] = []
    /// Dialing fails: the dashboard can't be reached.
    private var offline = false

    override func setUp() async throws {
        guard let url = ProcessInfo.processInfo.environment["HERMES_FAKE_URL"] else {
            throw XCTSkip("Set HERMES_FAKE_URL to run against devtools/fake_hermes.py.")
        }
        let settings = ConnectionSettings(dashboardURL: url, username: "test", password: "test",
                                          voiceServerURL: "", voiceToken: "", speechLocale: "")
        let client = try DashboardClient(settings: settings)
        try await client.signIn()
        self.client = client
        connection = GatewayConnection { [weak self] in
            if self?.offline == true { throw URLError(.notConnectedToInternet) }
            let transport = try await WebSocketTransport.dial(client)
            self?.transports.append(transport)
            return transport
        }
        prompts = PromptCenter(connection: connection)
    }

    override func tearDown() async throws {
        connection?.disconnect()
        connection = nil
        prompts = nil
        client = nil
    }

    private func newChat() async -> ChatModel {
        let chat = ChatModel(client: client, connection: connection, summary: nil)
        chat.setInUse("view", true)
        await chat.open()
        return chat
    }

    private func reply(_ chat: ChatModel, _ text: String) async {
        let sent = await chat.send(text)
        XCTAssertTrue(sent, "\(text): \(chat.error ?? "")")
        await waitUntil(timeout: 5) { !chat.busy && chat.messages.last?.role == .assistant }
    }

    private func waitForPrompt(_ chat: ChatModel) async throws -> PromptCenter.Prompt {
        await waitUntil(timeout: 5) { !self.prompts.prompts(for: chat.sessionIDs).isEmpty }
        return try XCTUnwrap(prompts.prompts(for: chat.sessionIDs).first)
    }

    func testStoredChatShowsHistoryAndStreamsAReply() async throws {
        let sessions = try await client.sessions()
        let welcome = try XCTUnwrap(sessions.first { $0.title == "Fake Hermes welcome" })
        let chat = ChatModel(client: client, connection: connection, summary: welcome)
        chat.setInUse("view", true)
        await chat.open()

        XCTAssertNil(chat.error)
        XCTAssertTrue(chat.messages.contains { $0.role == .tool && $0.text == "🔊 This line was spoken in an earlier call." })
        await reply(chat, "hello there")
        XCTAssertEqual(chat.messages.last?.text, "Echo: hello there")
    }

    func testNewChatIsStoredAndTitled() async throws {
        let chat = await newChat()
        var reported: String?
        chat.onStoredID = { reported = $0 }
        await reply(chat, "first words")

        XCTAssertEqual(chat.messages.map(\.text), ["first words", "Echo: first words"])
        XCTAssertNotNil(reported)
        XCTAssertEqual(reported, chat.storedID)
        await waitUntil { chat.title != "New chat" }
        let listed = try await client.sessions()
        XCTAssertTrue(listed.contains { $0.id == reported })
    }

    func testPromptsAreAnswered() async throws {
        let chat = await newChat()

        _ = await chat.send("please approve this")
        let approval = try await waitForPrompt(chat)
        guard case .approval = approval.kind else { return XCTFail("\(approval.kind)") }
        await prompts.approve(approval.id, .once)
        await waitUntil(timeout: 5) { !chat.busy && chat.messages.last?.text.hasPrefix("Approved (once)") == true }

        _ = await chat.send("clarify please")
        let clarify = try await waitForPrompt(chat)
        await prompts.answerClarify(clarify.id, answers: ["q0": "Green", "q1": #"["Logs","Metrics"]"#, "q2": nil])
        await waitUntil(timeout: 5) { !chat.busy && chat.messages.last?.text.hasPrefix("Clarify submitted") == true }
        XCTAssertTrue(chat.messages.last?.text.contains("q2: (skipped)") == true, chat.messages.last?.text ?? "")

        _ = await chat.send("sudo now")
        let sudo = try await waitForPrompt(chat)
        await prompts.answerValue(sudo.id, "pw")
        await waitUntil(timeout: 5) { !chat.busy && chat.messages.last?.text.hasPrefix("Got a sudo password (2 characters)") == true }

        await reply(chat, "window please")
        XCTAssertTrue(chat.messages.last?.text.hasPrefix("window.read declined by every client") == true, chat.messages.last?.text ?? "")
        XCTAssertTrue(prompts.prompts.isEmpty)
    }

    func testDroppedSocketIsReattachedWithActivate() async throws {
        let chat = await newChat()
        await reply(chat, "one")
        transports.last?.close()

        await reply(chat, "two")
        XCTAssertEqual(chat.messages.last?.text, "Echo: two")
        XCTAssertEqual(transports.count, 2)
        XCTAssertEqual(chat.sessionIDs.count, 2, "the same runtime id came back (stored id + runtime id)")
    }

    private func reapGrace() throws -> Double {
        guard let grace = ProcessInfo.processInfo.environment["HERMES_FAKE_REAP_GRACE"].flatMap(Double.init) else {
            throw XCTSkip("Set HERMES_FAKE_REAP_GRACE to the fake's --reap-grace.")
        }
        return grace
    }

    func testSessionReapedWhileAwayIsResumed() async throws {
        let grace = try reapGrace()
        let chat = await newChat()
        await reply(chat, "one")
        transports.last?.close()
        try await Task.sleep(nanoseconds: UInt64((grace + 1.5) * 1_000_000_000))

        await reply(chat, "two")
        XCTAssertEqual(chat.messages.last?.text, "Echo: two")
        XCTAssertEqual(chat.sessionIDs.count, 3, "resume made a new runtime id")
        await settle(0.5)
        XCTAssertEqual(chat.messages.map(\.text), ["one", "Echo: one", "two", "Echo: two"])
    }

    func testChatNotInUseIsLeftReapedUntilOpened() async throws {
        let grace = try reapGrace()
        let idle = await newChat()
        await reply(idle, "one")
        idle.setInUse("view", false)
        let active = await newChat()
        await reply(active, "two")
        let idleIDs = idle.sessionIDs
        transports.last?.close()
        try await Task.sleep(nanoseconds: UInt64((grace + 1.5) * 1_000_000_000))

        await reply(active, "three")
        XCTAssertEqual(active.sessionIDs.count, 3, "the chat in use was resumed")
        XCTAssertEqual(idle.sessionIDs, idleIDs, "nothing rebuilt the idle chat's runtime")

        idle.setInUse("view", true)
        await idle.open()
        await reply(idle, "four")
        await settle(0.5)
        XCTAssertEqual(idle.messages.map(\.text), ["one", "Echo: one", "four", "Echo: four"])
    }

    func testTurnCutOffWhileOfflineStopsSpinningWhenCatchingUpGivesUp() async throws {
        let chat = await newChat()
        await reply(chat, "one")
        var dropped = false
        let listener = connection.addListener { [weak self] event, _, _ in
            guard case .messageDelta = event, !dropped, let self else { return }
            dropped = true
            self.offline = true
            self.transports.last?.close()
            self.connection.probe()
        }
        defer { connection.removeListener(listener) }
        _ = await chat.send("four four")
        await waitUntil(timeout: 5) { dropped }
        XCTAssertTrue(chat.busy)

        await waitUntil(timeout: 30) { chat.error != nil }
        XCTAssertFalse(chat.busy, "nothing would end the spinner while offline")
    }
}
