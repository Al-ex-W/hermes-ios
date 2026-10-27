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
        let settings = ConnectionSettings(dashboardURL: url, username: "test", password: "test")
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
        let chat = ChatModel(client: client, connection: connection, prompts: prompts, summary: nil)
        chat.setInUse("view", true)
        await chat.open()
        return chat
    }

    private func reply(_ chat: ChatModel, _ text: String) async {
        let sent = await chat.send(text)
        XCTAssertTrue(sent, "\(text): \(chat.error ?? "")")
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply != nil }
    }

    private func storedSessions() async throws -> [SessionSummary] {
        try await client.profileSessions(profile: SidebarOptions.allProfiles, limit: 100, minMessages: 1).rows.map(\.summary)
    }

    private func waitForPrompt(_ chat: ChatModel) async throws -> PromptCenter.Prompt {
        await waitUntil(timeout: 5) { !self.prompts.prompts(for: chat.sessionIDs).isEmpty }
        return try XCTUnwrap(prompts.prompts(for: chat.sessionIDs).first)
    }

    func testStoredChatShowsHistoryAndStreamsAReply() async throws {
        let sessions = try await storedSessions()
        let welcome = try XCTUnwrap(sessions.first { $0.title == "Fake Hermes welcome" })
        let chat = ChatModel(client: client, connection: connection, prompts: prompts, summary: welcome)
        chat.setInUse("view", true)
        await chat.open()

        XCTAssertNil(chat.error)
        XCTAssertTrue(chat.spokenLines.contains("This line was spoken in an earlier call."), "\(chat.transcript.items)")
        await reply(chat, "hello there")
        XCTAssertEqual(chat.lastReply, "Echo: hello there")
    }

    /// Two M5 reads as Hermes answers them: a kanban worker's live stats, and a workspace download that names its
    /// session (resolved in the requested profile, relative paths against the session's folder; 404 otherwise).
    func testKanbanRunInspectAndSessionScopedDownloads() async throws {
        // A dispatched card gets a worker whose run reports live stats.
        let kanban = KanbanAPI(transport: client)
        let created = try await kanban.createTask(KanbanNewTask(title: "Inspect this worker", assignee: "default"))
        let taskID = try XCTUnwrap(created.task?.id)
        try await kanban.dispatch()
        let workers = try await kanban.activeWorkers()
        let worker = try XCTUnwrap(workers.first { $0.taskID == taskID })
        let live = try await kanban.inspectRun(worker.runID)
        XCTAssertTrue(live.alive)
        XCTAssertEqual(live.pid, worker.workerPID)
        XCTAssertNotNil(live.memoryRSSBytes)
        XCTAssertNotNil(live.threads)
        let ended = try await kanban.inspectRun(2)
        XCTAssertFalse(ended.alive)
        XCTAssertEqual(ended.reason, "run already ended")

        let sessions = try await storedSessions()
        let q3 = try XCTUnwrap(sessions.first { $0.title == "Q3 latency report" })
        let file = try await client.workspaceDownloadFile("README.md", profile: q3.profile, sessionID: q3.id)
        defer { DashboardClient.removeTemporaryFile(file) }
        XCTAssertTrue(String(decoding: try Data(contentsOf: file), as: UTF8.self).hasPrefix("# Atlas"))
        do {
            _ = try await client.workspaceDownloadFile("README.md", profile: "research", sessionID: q3.id)
            XCTFail("the session isn't in that profile")
        } catch DashboardError.http(404, _) {}
    }

    func testNewChatIsStoredAndTitled() async throws {
        let chat = await newChat()
        var reported: String?
        chat.onStoredID = { reported = $0 }
        await reply(chat, "first words")

        XCTAssertEqual(chat.texts, ["first words", "Echo: first words"])
        XCTAssertNotNil(reported)
        XCTAssertEqual(reported, chat.storedID)
        await waitUntil { chat.title != "New chat" }
        let listed = try await storedSessions()
        XCTAssertTrue(listed.contains { $0.id == reported })
    }

    /// A pushed call finds its session through the dashboard's real lookups: the stored row
    /// (`GET /api/sessions/:id`), then the live list (`session.active_list`); an unknown id runs standalone.
    func testPushedCallRouterFindsStoredAndLiveSessions() async throws {
        let chat = await newChat()
        await reply(chat, "route me")
        let stored = try XCTUnwrap(chat.storedID)
        await waitUntil { chat.title != "New chat" }

        let row = try await client.storedSession(stored, profile: nil)
        XCTAssertEqual(row?.id, stored)
        XCTAssertEqual(row?.profile, "default")
        let missing = try await client.storedSession("20200101_000000_abcdef", profile: nil)
        XCTAssertNil(missing, "an id the store doesn't hold is not found, not an error")

        let router = PushedCallRouter.live(client: client, connection: connection) { _ in nil }
        let push = { (id: String) in CallPush(callID: String(repeating: "a", count: 32), sessionID: id, profile: nil,
                                              mode: "async", title: "Ring") }
        guard case let .chat(summary) = await router.route(push(stored)) else {
            return XCTFail("a stored session opens its chat")
        }
        XCTAssertEqual(summary.id, stored)
        XCTAssertEqual(summary.title, chat.title)

        // A runtime id is found in the live list and opens the stored session behind it.
        let runtime = try XCTUnwrap(chat.runtimeID)
        guard case let .chat(live) = await router.route(push(runtime)) else {
            return XCTFail("a live runtime id opens its chat")
        }
        XCTAssertEqual(live.id, stored)
        let unknown = await router.route(push("local-telegram-123"))
        XCTAssertEqual(unknown, .standalone)
    }

    func testPromptsAreAnswered() async throws {
        let chat = await newChat()

        _ = await chat.send("please approve this")
        let approval = try await waitForPrompt(chat)
        guard case .approval = approval.kind else { return XCTFail("\(approval.kind)") }
        await prompts.approve(approval.id, .once)
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply?.hasPrefix("Approved (once)") == true }

        _ = await chat.send("clarify please")
        let clarify = try await waitForPrompt(chat)
        await prompts.answerClarify(clarify.id, answers: ["q0": "Green", "q1": #"["Logs","Metrics"]"#, "q2": nil])
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply?.hasPrefix("Clarify submitted") == true }
        XCTAssertTrue(chat.lastReply?.contains("q2: (skipped)") == true, chat.lastReply ?? "")

        _ = await chat.send("sudo now")
        let sudo = try await waitForPrompt(chat)
        await prompts.answerValue(sudo.id, "pw")
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply?.hasPrefix("Got a sudo password (2 characters)") == true }

        await reply(chat, "window please")
        XCTAssertTrue(chat.lastReply?.hasPrefix("window.read declined by every client") == true, chat.lastReply ?? "")
        XCTAssertTrue(prompts.prompts.isEmpty)
    }

    func testDroppedSocketIsReattachedWithActivate() async throws {
        let chat = await newChat()
        await reply(chat, "one")
        transports.last?.close()

        await reply(chat, "two")
        XCTAssertEqual(chat.lastReply, "Echo: two")
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
        XCTAssertEqual(chat.lastReply, "Echo: two")
        XCTAssertEqual(chat.sessionIDs.count, 3, "resume made a new runtime id")
        await settle(0.5)
        XCTAssertEqual(chat.texts, ["one", "Echo: one", "two", "Echo: two"])
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
        XCTAssertEqual(idle.texts, ["one", "Echo: one", "four", "Echo: four"])
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

    // MARK: Composer

    func testComposerSendsAndQueuesWhatTheRunningTurnRefuses() async throws {
        let chat = await newChat()
        let first = await chat.sender.send("first")
        XCTAssertEqual(first, .submitted)
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply == "Echo: first" }

        _ = await chat.sender.send("delegate this")
        await waitUntil(timeout: 5) { chat.busy }
        // The fake has no session.redirect, so the correction waits in the local queue for the next turn.
        let correction = await chat.sender.send("follow up")
        XCTAssertEqual(correction, .queued)
        await waitUntil(timeout: 10) { !chat.busy && chat.lastReply == "Echo: follow up" }
        XCTAssertTrue(chat.sender.queue.isEmpty)
        XCTAssertEqual(chat.userTexts, ["first", "delegate this", "follow up"])
        XCTAssertTrue(chat.transcript.items.contains { if case .subagent = $0 { return true }; return false })
    }

    func testTypingOverAClarifySkipsItAndSendsTheWords() async throws {
        let chat = await newChat()
        _ = await chat.sender.send("clarify please")
        _ = try await waitForPrompt(chat)
        XCTAssertTrue(chat.hasPendingClarify)

        _ = await chat.sender.send("never mind")
        XCTAssertFalse(chat.hasPendingClarify)
        await waitUntil(timeout: 10) { !chat.busy && chat.lastReply == "Echo: never mind" }
        XCTAssertTrue(chat.texts.contains("Clarify cancelled."), "\(chat.texts)")
    }

    func testSlashCommandOutputShowsInTheTranscript() async throws {
        let chat = await newChat()
        await reply(chat, "hello")
        let result = await chat.sender.send("/help")
        XCTAssertEqual(result, .ranSlash)
        XCTAssertTrue(chat.transcript.items.contains { item in
            if case let .system(note) = item, case .slash("/help") = note.kind { return !note.text.isEmpty }
            return false
        }, "\(chat.transcript.items)")
    }

    func testAttachedFileRidesThePromptAsAChip() async throws {
        let chat = await newChat()
        let file = ComposerAttachment(pending: .file(Data("hello".utf8), filename: "notes.txt", mime: "text/plain"))
        let result = await chat.sender.send("read this", attachments: [file])
        XCTAssertEqual(result, .submitted, chat.error ?? "")
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply != nil }
        guard case let .user(prompt)? = chat.transcript.items.first(where: \.isUser) else { return XCTFail("no prompt") }
        XCTAssertEqual(prompt.text, "read this")
        XCTAssertEqual(prompt.attachments.map(\.kind), [.file])

        await chat.open()
        guard case let .user(stored)? = chat.transcript.items.first(where: \.isUser) else { return XCTFail("no stored prompt") }
        XCTAssertNotNil(stored.rowID, "the reload shows Hermes' copy")
        XCTAssertEqual(stored.attachments.map(\.kind), [.file])
    }

    func testReopeningShowsTheStoredTurnInPlaceOfTheLiveOne() async throws {
        let chat = await newChat()
        _ = await chat.send("think tools")
        await waitUntil(timeout: 10) { !chat.busy && chat.transcript.items.contains { if case .changedFiles = $0 { return true }; return false } }
        let reply = chat.texts.last
        XCTAssertNotNil(reply)

        await chat.open()
        guard case let .user(prompt)? = chat.transcript.items.first(where: \.isUser) else { return XCTFail("no prompt") }
        XCTAssertNotNil(prompt.rowID, "the stored prompt replaced the local one")
        XCTAssertEqual(chat.userTexts, ["think tools"])
        XCTAssertEqual(chat.texts.last, reply)
        XCTAssertTrue(chat.transcript.items.contains { if case .reasoning = $0 { return true }; return false })
        XCTAssertTrue(chat.transcript.items.contains { if case .changedFiles = $0 { return true }; return false })
    }

    // MARK: Mid-turn reloads, rewinds, deletes

    func testARefetchMidTurnShowsEachSavedToolCallOnce() async throws {
        let chat = await newChat()
        _ = await chat.send("tools approve")
        let approval = try await waitForPrompt(chat)
        let before = chat.callIDs
        XCTAssertFalse(before.isEmpty)

        // Events were lost while the turn runs (an overflowed replay): the stored page already holds its rounds.
        chat.gatewayNeedsRefetch()
        await chat.resync()
        XCTAssertEqual(chat.callIDs, before, "\(chat.transcript.items)")

        await prompts.approve(approval.id, .once)
        await waitUntil(timeout: 10) { !chat.busy && chat.texts.last?.hasPrefix("Found the bug") == true }
        XCTAssertEqual(Set(chat.callIDs).count, chat.callIDs.count, "\(chat.callIDs)")
        XCTAssertEqual(chat.userTexts, ["tools approve"])
    }

    func testOpeningASessionWhoseTurnRunsElsewhereShowsItOnce() async throws {
        let chat = await newChat()
        await reply(chat, "hello")
        _ = await chat.send("tools approve")
        let approval = try await waitForPrompt(chat)
        let storedID = try XCTUnwrap(chat.storedID)

        // Another client with its own socket: it watched nothing of the turn.
        let other = GatewayConnection { [client] in try await WebSocketTransport.dial(client!) }
        defer { other.disconnect() }
        let watcher = ChatModel(client: client, connection: other,
                                summary: SessionSummary(id: storedID, title: chat.title, lastActive: nil, profile: nil))
        watcher.setInUse("view", true)
        await watcher.open()
        XCTAssertTrue(watcher.busy)
        XCTAssertEqual(watcher.userTexts, ["hello", "tools approve"])
        XCTAssertEqual(Set(watcher.callIDs).count, watcher.callIDs.count)

        await prompts.approve(approval.id, .once)
        await waitUntil(timeout: 10) { !chat.busy && chat.texts.last?.hasPrefix("Found the bug") == true }
        await waitUntil(timeout: 10) { !watcher.busy && watcher.texts.last == chat.texts.last }
        XCTAssertEqual(watcher.userTexts, ["hello", "tools approve"])
        XCTAssertEqual(Set(watcher.callIDs).count, watcher.callIDs.count, "\(watcher.callIDs)")
    }

    func testEditingAPromptRunsTheConversationAgainFromIt() async throws {
        let chat = await newChat()
        await reply(chat, "first")
        await reply(chat, "second")

        // A prompt sent from here learns its stored id from a fresh copy of the transcript.
        guard case let .user(second)? = chat.transcript.items.last(where: \.isUser) else { return XCTFail("no prompt") }
        let edited = await chat.rewind(second, to: "second, edited")
        XCTAssertTrue(edited, chat.error ?? "")
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply == "Echo: second, edited" }
        XCTAssertEqual(chat.userTexts, ["first", "second, edited"])

        await chat.open()
        guard case let .user(first)? = chat.transcript.items.first(where: \.isUser) else { return XCTFail("no prompt") }
        XCTAssertNotNil(first.rowID)
        let rewound = await chat.rewind(first, to: "first, edited")
        XCTAssertTrue(rewound, chat.error ?? "")
        await waitUntil(timeout: 5) { !chat.busy && chat.lastReply == "Echo: first, edited" }
        await chat.open()
        XCTAssertEqual(chat.texts, ["first, edited", "Echo: first, edited"], "Hermes dropped everything after it")
    }

    func testRetryReplacesTheFailedTurnAndShowsThePromptItResends() async throws {
        let chat = await newChat()
        _ = await chat.send("fail please")
        await waitUntil(timeout: 5) { !chat.busy && chat.errorCount == 1 }

        let ran = await chat.runSlash("/retry")
        XCTAssertTrue(ran)
        await waitUntil(timeout: 10) { !chat.busy && chat.errorCount == 1 && chat.transcript.items.last.map(\.isUser) == false }
        XCTAssertEqual(chat.userTexts, ["fail please"], "one bubble with the resent words, not /retry")
        XCTAssertEqual(chat.errorCount, 1, "the rewound turn's card went with it")
    }

    func testDeletingARunningChatStopsAndClosesItFirst() async throws {
        let chat = await newChat()
        _ = await chat.send("tools approve")
        _ = try await waitForPrompt(chat)
        XCTAssertTrue(chat.busy)
        let storedID = try XCTUnwrap(chat.storedID)

        let target = SessionMenuTarget(storedID: storedID, runtimeID: chat.attachedRuntimeID, title: chat.title)
        try await chat.sessionActions.delete(target)
        chat.sessionGone()
        let sessions = try await storedSessions()
        XCTAssertFalse(sessions.contains { $0.id == storedID })
        await waitUntil(timeout: 5) { self.prompts.prompts(for: chat.sessionIDs).isEmpty }
        XCTAssertFalse(chat.busy)
    }

    func testANewChatStartsWithTheEffortPickedBeforeIt() async throws {
        // Not opened yet, so Hermes has no session for it.
        let chat = ChatModel(client: client, connection: connection, prompts: prompts, summary: nil)
        chat.setInUse("view", true)
        await chat.composer.setEffort("high")
        XCTAssertEqual(chat.composer.pendingEffort, "high")
        await reply(chat, "hi")
        let runtimeID = try XCTUnwrap(chat.attachedRuntimeID)
        let effort = try await connection.client.configGet(.init(key: "reasoning", sessionId: runtimeID)).value
        XCTAssertEqual(effort, "high")
    }
}

@MainActor
extension ChatModel {
    /// The prompts and replies, in order.
    var texts: [String] {
        transcript.items.compactMap { item in
            switch item {
            case let .user(message): return message.text
            case let .assistant(text) where !text.interim: return text.markdown
            default: return nil
            }
        }
    }

    var userTexts: [String] {
        transcript.items.compactMap { if case let .user(message) = $0 { return message.text }; return nil }
    }

    /// Every tool call's id, in order.
    var callIDs: [String] {
        transcript.items.flatMap { item -> [String] in
            guard case let .toolRun(run) = item else { return [] }
            return run.calls.map(\.callID)
        }
    }

    var errorCount: Int {
        transcript.items.filter { if case .error = $0 { return true }; return false }.count
    }

    /// The text of the last row when it is a reply.
    var lastReply: String? {
        if case let .assistant(text)? = transcript.items.last { return text.markdown }
        return nil
    }

    /// What Hermes said out loud through the speak tool.
    var spokenLines: [String] {
        transcript.items.flatMap { item -> [String] in
            guard case let .toolRun(run) = item else { return [] }
            return run.calls.filter { $0.name.hasSuffix("speak") }.compactMap { $0.args["text"]?.stringValue }
        }
    }
}
