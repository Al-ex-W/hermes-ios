import XCTest
@testable import HermesVoice

/// Follow-ups from M2 and M6b: where a pushed call runs (its session's chat, or on its own), closing the gateway
/// connection in the background and replaying on return, and the user-bubble actions' requests (edit, restore,
/// stop) with the desktop's edge cases.
@MainActor
final class FollowUpsTests: XCTestCase {
    private let callID = "00112233445566778899aabbccddeeff"

    // MARK: - Where a pushed call runs

    private func push(session: String?, profile: String? = "default", title: String? = "Groceries") -> CallPush {
        CallPush(callID: callID, sessionID: session, profile: profile, mode: "async", title: title)
    }

    /// A router that records its lookups.
    private final class Lookups {
        var open: [String: SessionSummary] = [:]
        var stored: [String: SessionInfo] = [:]
        var storedError: Error?
        var live: [PushedCallRouter.LiveRow] = []
        var liveDelay: TimeInterval = 0
        private(set) var storedAsked: [(String, String?)] = []
        private(set) var liveAsked = 0

        @MainActor func router(timeout: TimeInterval = 2) -> PushedCallRouter {
            PushedCallRouter(
                openChat: { [unowned self] id in self.open[id] },
                stored: { [unowned self] id, profile in
                    self.storedAsked.append((id, profile))
                    if let error = self.storedError { throw error }
                    return self.stored[id]
                },
                live: { [unowned self] in
                    self.liveAsked += 1
                    if self.liveDelay > 0 { try await Task.sleep(nanoseconds: UInt64(self.liveDelay * 1_000_000_000)) }
                    return self.live
                },
                timeout: timeout
            )
        }
    }

    func testAPushWithoutASessionRunsOnItsOwn() async {
        let lookups = Lookups()
        let route = await lookups.router().route(push(session: nil))
        XCTAssertEqual(route, .standalone)
        XCTAssertTrue(lookups.storedAsked.isEmpty)
        XCTAssertEqual(lookups.liveAsked, 0)
    }

    func testAPushForAChatAlreadyOpenUsesItWithoutLookingFurther() async {
        let lookups = Lookups()
        let open = SessionSummary(id: "s1", title: "Trip plan", lastActive: nil, profile: "default")
        lookups.open["s1"] = open
        let route = await lookups.router().route(push(session: "s1"))
        XCTAssertEqual(route, .chat(open))
        XCTAssertTrue(lookups.storedAsked.isEmpty)
        XCTAssertEqual(lookups.liveAsked, 0)
    }

    func testAStoredSessionOpensItsChatUnderItsOwnTitleAndProfile() async {
        let lookups = Lookups()
        lookups.stored["s1"] = SessionInfo(id: "s1", title: "Trip plan", source: "telegram", profile: "work")
        let route = await lookups.router().route(push(session: "s1", profile: "work", title: "Hermes"))
        XCTAssertEqual(route, .chat(SessionSummary(id: "s1", title: "Trip plan", lastActive: nil, profile: "work")))
        XCTAssertEqual(lookups.storedAsked.map(\.0), ["s1"])
        XCTAssertEqual(lookups.storedAsked.map(\.1), ["work"], "the push's profile names the store")
        XCTAssertEqual(lookups.liveAsked, 0)
    }

    func testASessionLiveInTheDashboardOpensByItsStoredOrRuntimeID() async {
        let lookups = Lookups()
        lookups.live = [PushedCallRouter.LiveRow(runtime: "r9", stored: "s9", title: "Draft")]
        let byRuntime = await lookups.router().route(push(session: "r9"))
        XCTAssertEqual(byRuntime, .chat(SessionSummary(id: "s9", title: "Draft", lastActive: nil, profile: "default")))
        let byStored = await lookups.router().route(push(session: "s9", title: "Groceries"))
        XCTAssertEqual(byStored, .chat(SessionSummary(id: "s9", title: "Draft", lastActive: nil, profile: "default")))
        XCTAssertEqual(lookups.storedAsked.count, 2, "the stored lookup goes first")
    }

    func testAMessagingOrGatewayLocalSessionRunsOnItsOwn() async {
        let lookups = Lookups()
        lookups.live = [PushedCallRouter.LiveRow(runtime: "r1", stored: "s1")]
        for id in ["local-5f3a9c", "telegram:dm:42"] {
            let route = await lookups.router().route(push(session: id))
            XCTAssertEqual(route, .standalone, id)
        }
    }

    func testLookupsThatFailOrHangCountAsNotFound() async {
        let lookups = Lookups()
        lookups.storedError = DashboardError.http(500, "boom")
        lookups.live = [PushedCallRouter.LiveRow(runtime: "r1", stored: "s1")]
        lookups.liveDelay = 5
        let started = Date()
        let route = await lookups.router(timeout: 0.2).route(push(session: "s1"))
        XCTAssertEqual(route, .standalone)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a hung lookup doesn't hold the ringing call")
    }

    func testAStandaloneCallRingsAndRunsWithoutAttachingAChat() async {
        var links: [FakeLink] = []
        var attaches = 0
        var environment = VoiceCall.Environment(
            makeLink: { hello in
                let link = FakeLink(hello: hello)
                links.append(link)
                return link
            },
            makeSpeech: { id, callID in FakeSpeech(id: id, callID: callID) },
            makeAudio: { FakeAudio() }
        )
        environment.attach = { _ in attaches += 1 }
        let call = VoiceCall(chat: nil, settings: CallSettings(provider: .apple, speechLocale: "", endOfSpeech: .normal),
                             initiatedBy: .push, callID: callID, push: push(session: "local-5f3a9c", title: "Kitchen bot"),
                             environment: environment)
        XCTAssertEqual(call.title, "Kitchen bot")
        call.begin()
        await waitUntil { links.count == 1 && links[0].connects == 1 }
        let link = links[0]
        XCTAssertEqual(link.hello.sessionID, "local-5f3a9c", "the plugin knows the call by its id; the session is only named")
        XCTAssertEqual(link.hello.title, "Kitchen bot")
        XCTAssertEqual(link.hello.initiatedBy, .push)
        XCTAssertEqual(attaches, 0, "nothing is resumed for a session the app can't open")

        link.deliver(.ready(callID: callID, ringing: true))
        XCTAssertEqual(link.types, ["ringing"])
        call.answer()
        call.audioDidActivate()
        await waitUntil { call.state == .live }
        XCTAssertEqual(link.types, ["ringing", "answered"])
        call.sayTyped("hello there")
        XCTAssertEqual(link.turns.map(\.text), ["hello there"])
        call.hangUp()
        XCTAssertTrue(call.isEnded)
        XCTAssertEqual(attaches, 0)
    }

    // MARK: - Background detach and foreground re-attach

    /// Records what the lifecycle asks of the connection.
    private final class PauseLog: GatewayPausing {
        private(set) var events: [String] = []
        func pauseForBackground() { events.append("pause") }
        func resumeFromBackground() { events.append("resume") }
    }

    func testTheConnectionClosesInTheBackgroundOnlyWithoutACall() {
        let lifecycle = GatewayLifecycle(phase: .foreground)
        let log = PauseLog()
        lifecycle.use(log)
        XCTAssertFalse(lifecycle.paused)
        lifecycle.setPhase(.background)
        XCTAssertTrue(lifecycle.paused)
        lifecycle.setPhase(.foreground)
        XCTAssertEqual(log.events, ["resume", "pause", "resume"])

        // A call rings while the app is in the background: the connection comes back for it, and goes once it ends.
        lifecycle.setPhase(.background)
        lifecycle.setCallActive(true)
        XCTAssertFalse(lifecycle.paused)
        lifecycle.setCallActive(false)
        XCTAssertTrue(lifecycle.paused)
        XCTAssertEqual(log.events, ["resume", "pause", "resume", "pause", "resume", "pause"])

        // Going to the background during a call keeps the connection.
        lifecycle.setPhase(.foreground)
        lifecycle.setCallActive(true)
        lifecycle.setPhase(.background)
        XCTAssertFalse(lifecycle.paused)
        XCTAssertEqual(log.events.last, "resume")

        // A new sign-in's connection starts the way the app is now.
        lifecycle.setCallActive(false)
        let next = PauseLog()
        lifecycle.use(next)
        XCTAssertEqual(next.events, ["pause"])
    }

    func testBackgroundClosesTheSocketAndTheForegroundReplaysWhatWasMissed() async throws {
        let gateway = ScriptedGateway()
        // Reconnects on, so a socket that went away would be redialled if the pause didn't hold it.
        let connection = gateway.connection { $0.reconnectDelays = [0.01] }
        let owner = RecordingOwner()
        let log = EventLog(connection)
        try await connection.connect()
        connection.track(owner, runtimeID: "r1", storedID: "s1", profile: nil)
        gateway.current.push(event: "message.delta", session: "r1", seq: 1, payload: ["text": "1"])
        await waitUntil { connection.watermarks["r1"] == 1 }

        let lifecycle = GatewayLifecycle(phase: .foreground)
        lifecycle.use(connection)
        lifecycle.setPhase(.background)
        XCTAssertTrue(gateway.sockets[0].closedByClient, "Hermes sees the client go, so alerts are pushed")
        XCTAssertEqual(connection.state, .disconnected)

        // Nothing redials while in the background; a call made meanwhile waits for the foreground.
        gateway.handlers["session.usage"] = { _ in .result(["input": 1]) }
        var answered: JSONValue?
        let waiting = Task { answered = try await connection.call("session.usage", params: ["session_id": "r1"], timeout: nil) }
        await settle(0.2)
        XCTAssertEqual(gateway.sockets.count, 1)
        XCTAssertTrue(gateway.calls("session.usage").isEmpty)

        // Back in front: re-attached, and what the turn emitted meanwhile is replayed once, in order.
        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1", running: true)) }
        gateway.handlers["session.events.since"] = { _ in
            .result(eventsSince([replayed("message.delta", session: "r1", seq: 2, payload: ["text": "2"]),
                                 replayed("message.complete", session: "r1", seq: 3, payload: ["text": "12"])], latest: 3))
        }
        lifecycle.setPhase(.foreground)
        try await waiting.value
        XCTAssertEqual(answered?["input"], 1)
        XCTAssertEqual(gateway.sockets.count, 2)
        XCTAssertEqual(gateway.calls("session.activate").map(\.params), [["session_id": "r1", "cols": 96, "omit_messages": true]])
        XCTAssertEqual(gateway.calls("session.events.since").map(\.params), [["session_id": "r1", "last_seen": 1]])
        XCTAssertEqual(log.seqs("r1"), [1, 2, 3])
        XCTAssertEqual(owner.reattached.map(\.runtimeID), ["r1"])
        XCTAssertEqual(owner.refetches, 0, "nothing was lost")
        XCTAssertEqual(gateway.calls("session.usage").map(\.socket), [1], "the waiting call went out on the new socket")
        connection.disconnect()
    }

    func testACallKeepsTheConnectionOpenInTheBackground() async throws {
        let gateway = ScriptedGateway()
        let connection = gateway.connection()
        try await connection.connect()
        let lifecycle = GatewayLifecycle(phase: .foreground)
        lifecycle.use(connection)
        lifecycle.setCallActive(true)
        lifecycle.setPhase(.background)
        XCTAssertFalse(gateway.sockets[0].closedByClient)
        XCTAssertTrue(connection.isConnected)

        // The call ends while the app is still in the background: now the socket goes.
        lifecycle.setCallActive(false)
        XCTAssertTrue(gateway.sockets[0].closedByClient)
        XCTAssertTrue(connection.paused)
        connection.disconnect()
    }

    func testASessionReapedWhileInTheBackgroundIsResumedAndRefetched() async throws {
        let gateway = ScriptedGateway()
        let connection = gateway.connection()
        let owner = RecordingOwner()
        try await connection.connect()
        connection.track(owner, runtimeID: "r1", storedID: "s1", profile: nil)
        gateway.current.push(event: "message.complete", session: "r1", seq: 4, payload: ["text": "done"])
        await waitUntil { connection.watermarks["r1"] == 4 }
        connection.pauseForBackground()

        // Idle and clientless, Hermes reaped the runtime meanwhile.
        gateway.handlers["session.activate"] = { _ in .error(4007, "session no longer live; retry resume") }
        gateway.handlers["session.resume"] = { _ in .result(liveResult("r2")) }
        connection.resumeFromBackground()
        await waitUntil { owner.reattached.count == 1 }
        XCTAssertEqual(gateway.calls("session.resume").map(\.params),
                       [["session_id": "s1", "cols": 96, "source": "desktop", "omit_messages": true]])
        XCTAssertEqual(owner.reattached.map(\.runtimeID), ["r2"])
        XCTAssertEqual(owner.refetches, 1, "the stored transcript is fetched again instead")
        XCTAssertTrue(gateway.calls("session.events.since").isEmpty)
        connection.disconnect()
    }

    func testSigningOutWhilePausedFailsTheWaitingCalls() async throws {
        let gateway = ScriptedGateway()
        let connection = gateway.connection()
        try await connection.connect()
        connection.pauseForBackground()
        var failure: Error?
        let waiting = Task {
            do { _ = try await connection.call("session.usage", params: [:], timeout: nil) } catch { failure = error }
        }
        await settle()
        connection.disconnect()
        await waiting.value
        XCTAssertNotNil(failure)
        XCTAssertEqual(gateway.sockets.count, 1)
    }

    // MARK: - User-bubble actions

    private var gateway: ScriptedGateway!
    private var connection: GatewayConnection!
    private var client: DashboardClient!
    private var nextRow = 10

    /// A new chat on a scripted gateway whose `prompt.submit` answers with the stored row of each prompt.
    private func chatOnGateway() async throws -> ChatModel {
        gateway = ScriptedGateway()
        connection = gateway.connection()
        client = try DashboardClient(settings: ConnectionSettings(dashboardURL: "http://127.0.0.1:9", username: "test", password: "test"))
        gateway.handlers["session.create"] = { _ in
            .result(["session_id": "r1", "stored_session_id": "s1", "message_count": 0, "messages": [], "info": ["running": false]])
        }
        submits { [unowned self] _ in
            self.nextRow += 1
            return .result(["status": "streaming", "user_row_id": .int(self.nextRow)])
        }
        try await connection.connect()
        return ChatModel(client: client, connection: connection, summary: nil)
    }

    private func submits(_ reply: @escaping (JSONValue) -> ScriptedGateway.Reply) {
        gateway.handlers["prompt.submit"] = reply
    }

    private var rewinds: [JSONValue] {
        gateway.calls("prompt.submit").map(\.params).filter { $0["truncate_before_row_id"] != nil }
    }

    private func reply(_ chat: ChatModel, _ text: String) async {
        let sent = await chat.send(text)
        XCTAssertTrue(sent, chat.error ?? "")
        gateway.current.push(event: "message.start", session: "r1")
        gateway.current.push(event: "message.complete", session: "r1", payload: ["text": .string("re: \(text)"), "status": "complete"])
        await waitUntil { !chat.busy }
    }

    private func prompt(_ chat: ChatModel, _ text: String) throws -> UserMessage {
        for case let .user(message) in chat.transcript.items where message.text == text { return message }
        throw XCTSkip("no prompt \(text)")
    }

    override func tearDown() async throws {
        await settle(0.2)
        connection?.disconnect()
        connection = nil
        gateway = nil
    }

    func testAnEditRewindsFromTheStoredRowAndAsksForTheKeptIDs() async throws {
        let chat = try await chatOnGateway()
        await reply(chat, "first")
        await reply(chat, "second")
        let first = try prompt(chat, "first")
        XCTAssertEqual(first.rowID, 11, "prompt.submit's user_row_id gives the bubble its stored row")

        let edited = await chat.rewind(first, to: "first, edited")
        XCTAssertTrue(edited, chat.error ?? "")
        XCTAssertEqual(rewinds, [[
            "session_id": "r1", "text": "first, edited", "truncate_before_row_id": 11, "confirm_truncate": true,
            "confirm_empty_truncate": true, "rebind_survivor_row_ids": [11, 12],
        ]], "never queued, and only the cut's own keys")
        XCTAssertEqual(chat.userTexts, ["first, edited"])
        XCTAssertTrue(gateway.calls("session.interrupt").isEmpty, "an idle session isn't interrupted")
    }

    func testARestoreRebindsTheRowsHermesKept() async throws {
        let chat = try await chatOnGateway()
        await reply(chat, "first")
        await reply(chat, "second")
        let second = try prompt(chat, "second")
        submits { params in
            params["truncate_before_row_id"] == 12
                ? .result(["status": "streaming", "user_row_id": 31, "survivor_row_id_map": ["11": 30, "12": .null]])
                : .error(4000, "unexpected")
        }
        let restored = await chat.rewind(second, to: ChatModel.promptText(second), kind: .restore)
        XCTAssertTrue(restored, chat.error ?? "")
        XCTAssertEqual(rewinds.first?["text"], "second")
        XCTAssertEqual(rewinds.first?["rebind_survivor_row_ids"], [11, 12])
        XCTAssertEqual(chat.userTexts, ["first", "second"])
        XCTAssertEqual(try prompt(chat, "first").rowID, 30, "the kept prompt takes its new id")
        XCTAssertEqual(try prompt(chat, "second").rowID, 31, "the re-sent prompt takes its own")
    }

    func testARewindDuringATurnStopsItFirstAndRidesOutSessionBusy() async throws {
        let chat = try await chatOnGateway()
        await reply(chat, "first")
        _ = await chat.send("second")
        gateway.current.push(event: "message.start", session: "r1")
        await waitUntil { chat.busy }
        XCTAssertEqual(chat.runningPromptID, try prompt(chat, "second").id, "Stop sits on the running turn's prompt")

        gateway.handlers["session.interrupt"] = { _ in .result(["status": "interrupted"]) }
        gateway.beforeReply["session.interrupt"] = { socket in
            socket.push(event: "message.complete", session: "r1", payload: ["text": "", "status": "interrupted"])
        }
        var busyAnswers = 2
        submits { params in
            guard params["truncate_before_row_id"] != nil else { return .result(["status": "streaming"]) }
            if busyAnswers > 0 {
                busyAnswers -= 1
                return .error(4009, "session busy")
            }
            return .result(["status": "streaming"])
        }
        let first = try prompt(chat, "first")
        let edited = await chat.rewind(first, to: "again")
        XCTAssertTrue(edited, chat.error ?? "")
        XCTAssertEqual(gateway.calls("session.interrupt").count, 2, "Stop, then once more when Hermes was still busy")
        XCTAssertEqual(rewinds.count, 3, "retried while the stopped turn wound down")
        XCTAssertNil(chat.error)
    }

    func testEditingAPromptThatNeverReachedHermesSendsItAsANewTurn() async throws {
        let chat = try await chatOnGateway()
        await reply(chat, "first")
        submits { _ in .error(4002, "model refused the request") }
        let sent = await chat.send("oops")
        XCTAssertFalse(sent)
        chat.error = nil
        submits { _ in .result(["status": "streaming", "user_row_id": 40]) }

        let edited = await chat.rewind(try prompt(chat, "oops"), to: "fixed")
        XCTAssertTrue(edited, chat.error ?? "")
        let last = gateway.calls("prompt.submit").last?.params
        XCTAssertEqual(last?["text"], "fixed")
        XCTAssertNil(last?["truncate_before_row_id"], "nothing stored to cut")
        XCTAssertNil(last?["confirm_truncate"])
        XCTAssertEqual(chat.userTexts, ["first", "fixed"])
    }

    func testAStaleTargetIsLookedUpOnceMoreThenReportedAsCompressedAway() async throws {
        let chat = try await chatOnGateway()
        await reply(chat, "first")
        await reply(chat, "second")
        submits { _ in .error(4018, "target user message is no longer in session history") }
        let edited = await chat.rewind(try prompt(chat, "first"), to: "first, edited")
        XCTAssertFalse(edited)
        XCTAssertEqual(rewinds.count, 2, "one more try after looking the prompt up again")
        XCTAssertEqual(chat.error, "Edit failed: this turn is no longer in server history (it may have been compressed away).")
        XCTAssertEqual(chat.userTexts, ["first", "second"], "the transcript is put back")
    }

    func testAFailedRestorePutsTheTranscriptBack() async throws {
        let chat = try await chatOnGateway()
        await reply(chat, "first")
        await reply(chat, "second")
        let texts = chat.texts
        submits { _ in .error(4010, "session is not running") }
        let restored = await chat.rewind(try prompt(chat, "first"), to: "first", kind: .restore)
        XCTAssertFalse(restored)
        XCTAssertEqual(chat.texts, texts)
        XCTAssertEqual(chat.error, "Restore failed: session is not running")
    }

    func testAnUnchangedEditSendsNothing() async {
        let scripted = ScriptedGateway()
        let composer = ComposerModel(sender: SendController(chat: IdleChat()), connection: scripted.connection(), profile: nil)
        var rewound = 0
        composer.rewind = { _, _ in
            rewound += 1
            return true
        }
        composer.draft = "half-typed"
        composer.editMessage(UserMessage(id: "row-3", text: "fix the bug", rowID: 3))
        composer.draft = "fix the bug  "
        await composer.send()
        XCTAssertEqual(rewound, 0)
        XCTAssertNil(composer.editingMessage)
        XCTAssertEqual(composer.draft, "half-typed")
    }

    func testAnEditThatDropsLaterTurnsAsksFirst() async {
        let scripted = ScriptedGateway()
        let composer = ComposerModel(sender: SendController(chat: IdleChat()), connection: scripted.connection(), profile: nil)
        var rewound: [String] = []
        composer.rewind = { _, text in
            rewound.append(text)
            return true
        }
        composer.promptsAfter = { _ in 2 }
        composer.editMessage(UserMessage(id: "row-3", text: "fix the bug", rowID: 3))
        composer.draft = "fix the other bug"
        await composer.send()
        XCTAssertEqual(composer.deepEditConfirmation?.id, "row-3")
        XCTAssertTrue(rewound.isEmpty, "nothing is cut before the user agrees")
        XCTAssertEqual(composer.draft, "fix the other bug")

        await composer.confirmDeepEdit()
        XCTAssertEqual(rewound, ["fix the other bug"])
        XCTAssertNil(composer.deepEditConfirmation)
        XCTAssertNil(composer.editingMessage)
    }
}

/// An idle chat with a live session, for the composer's edit flow.
@MainActor
private final class IdleChat: ChatSending {
    var runtimeSessionID: String? = "r1"
    var isBusy = false
    var hasPendingClarify = false
    var hasBlockingPrompt = false
    func skipPendingClarify() async {}
    func submit(_ text: String, attachments: [StagedAttachment], queued: Bool, display: String?) async -> Bool { true }
    func redirect(_ text: String) async -> RedirectOutcome { .redirected }
    func interrupt() async {}
    func runSlash(_ command: String) async -> Bool { true }
    func stage(_ attachment: PendingAttachment) async throws -> StagedAttachment {
        StagedAttachment(kind: .file, name: attachment.filename, refText: nil)
    }
    func unstage(_ staged: StagedAttachment) async {}
}
