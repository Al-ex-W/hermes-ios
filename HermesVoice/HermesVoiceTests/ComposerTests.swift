import XCTest
@testable import HermesVoice

/// Records what slash commands asked of the chat.
@MainActor
private final class RecordingHost: SlashCommandHost {
    var sessionID = "r1"
    private(set) var outputs: [String] = []
    private(set) var prompts: [(text: String, display: String?)] = []
    private(set) var prefills: [String] = []
    private(set) var actions: [SlashAction] = []
    private(set) var reloads = 0

    func slashSessionID() async throws -> String { sessionID }
    func showSlashOutput(_ text: String) { outputs.append(text) }
    func sendSlashPrompt(_ text: String, display: String?) async -> Bool {
        prompts.append((text, display))
        return true
    }
    func prefillComposer(_ text: String) { prefills.append(text) }
    func performSlashAction(_ action: SlashAction) async { actions.append(action) }
    func transcriptChanged() async { reloads += 1 }
}

/// A chat with a live session, for the composer's model controls.
@MainActor
private final class AttachedChat: ChatSending {
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

@MainActor
final class ComposerTests: XCTestCase {
    private var gateway: ScriptedGateway!
    private var connection: GatewayConnection!
    private var host: RecordingHost!

    override func setUp() async throws {
        gateway = ScriptedGateway()
        connection = gateway.connection()
        host = RecordingHost()
        try await connection.connect()
    }

    override func tearDown() async throws {
        connection.disconnect()
        connection = nil
        gateway = nil
        host = nil
    }

    private func run(_ text: String, catalog: CommandsCatalogResult? = nil) async -> Bool {
        await SlashCommandRunner(client: connection.client, profile: nil, host: host, catalog: catalog).run(text)
    }

    // MARK: Parsing

    func testSlashCommandSplitsNameAndArgument() {
        XCTAssertEqual(SlashCommand("/Title  My chat "), SlashCommand(name: "title", arg: "My chat"))
        XCTAssertEqual(SlashCommand("/goal first line\n  second"), SlashCommand(name: "goal", arg: "first line\n  second"))
        XCTAssertEqual(SlashCommand("/"), SlashCommand(name: "", arg: ""))
        XCTAssertEqual(SlashCommand("/ words"), SlashCommand(name: "", arg: ""))
    }

    // MARK: Hermes' commands

    func testExecShowsItsOutput() async {
        gateway.handlers["slash.exec"] = { _ in .result(["output": "3 calls"]) }
        let ran = await run("/usage")
        XCTAssertTrue(ran)
        XCTAssertEqual(gateway.calls("slash.exec").first?.params, ["session_id": "r1", "command": "usage"])
        XCTAssertEqual(host.outputs, ["3 calls"])
    }

    func testExecWarningPrecedesTheOutput() async {
        gateway.handlers["slash.exec"] = { _ in .result(["output": "done", "warning": "slow"]) }
        _ = await run("/tools list")
        XCTAssertEqual(gateway.calls("slash.exec").first?.params["command"], "tools list")
        XCTAssertEqual(host.outputs, ["warning: slow\ndone"])
    }

    func testExecSendDirectiveSendsTheMessage() async {
        gateway.handlers["slash.exec"] = { _ in
            .result(["type": "send", "message": "Pursue the goal", "notice": "⊙ Goal set", "display": "/goal ship it"])
        }
        _ = await run("/goal ship it")
        XCTAssertEqual(host.outputs, ["⊙ Goal set"])
        XCTAssertEqual(host.prompts.map(\.text), ["Pursue the goal"])
        XCTAssertEqual(host.prompts.first?.display, "/goal ship it")
    }

    func testFailedExecFallsBackToDispatch() async {
        gateway.handlers["slash.exec"] = { _ in .error(5000, "worker crashed") }
        gateway.handlers["command.dispatch"] = { _ in .result(["type": "skill", "name": "work", "message": "SKILL BODY"]) }
        _ = await run("/work fix the leak")
        XCTAssertEqual(gateway.calls("command.dispatch").first?.params, ["name": "work", "arg": "fix the leak", "session_id": "r1"])
        XCTAssertEqual(host.prompts.first?.text, "SKILL BODY")
        XCTAssertEqual(host.prompts.first?.display, "/work fix the leak")
    }

    func testSendDirectiveShowsTheMessageItSends() async {
        gateway.handlers["slash.exec"] = { _ in .error(5000, "worker crashed") }
        gateway.handlers["command.dispatch"] = { _ in .result(["type": "send", "message": "fix the build"]) }
        _ = await run("/queue fix the build")
        XCTAssertEqual(host.prompts.first?.text, "fix the build")
        XCTAssertNil(host.prompts.first?.display, "not the command typed")
        XCTAssertEqual(host.reloads, 0)
    }

    func testRetryShowsTheRewoundTranscriptAndThePromptItResends() async {
        gateway.handlers["slash.exec"] = { _ in .error(5000, "worker crashed") }
        gateway.handlers["command.dispatch"] = { _ in .result(["type": "send", "message": "the original prompt"]) }
        _ = await run("/retry")
        XCTAssertEqual(host.reloads, 1, "Hermes rewound the failed turn: the transcript is fetched again first")
        XCTAssertEqual(host.prompts.first?.text, "the original prompt")
        XCTAssertNil(host.prompts.first?.display)
    }

    func testASkillScaffoldShowsItsInvocation() {
        let single = "[IMPORTANT: The user has invoked the \"work\" skill, indicating they want you to follow its instructions. "
            + "The full skill content is loaded below.]\n\nBODY\n\nThe user has provided the following instruction alongside "
            + "the skill invocation: fix   the\nleak\n\n[Runtime note: x]"
        XCTAssertEqual(SlashCommandRunner.skillInvocation(single), "/work fix the leak")
        XCTAssertEqual(SlashCommandRunner.skillInvocation("[IMPORTANT: The user has invoked the \"work\" skill. "
                                                          + "The full skill content is loaded below.]\n\nBODY"), "/work")
        XCTAssertNil(SlashCommandRunner.skillInvocation("just words"))
        let skill = SlashCommand("/work fix it")
        XCTAssertEqual(SlashCommandRunner.shown("BODY", display: nil, skill: true, command: skill), "/work fix it",
                       "a skill body without a projection shows the command")
        XCTAssertEqual(SlashCommandRunner.shown(single, display: nil, skill: false, command: skill), "/work fix the leak")
        XCTAssertEqual(SlashCommandRunner.shown("x", display: " /goal ship ", skill: false, command: skill), "/goal ship")
    }

    func testDispatchRoutingNoiseKeepsTheExecError() async {
        gateway.handlers["slash.exec"] = { _ in .error(5000, "worker timed out") }
        gateway.handlers["command.dispatch"] = { _ in .error(4000, "not a quick/plugin/skill command: nope") }
        _ = await run("/nope")
        XCTAssertEqual(host.outputs, ["error: /nope failed: worker timed out"])
    }

    func testAliasRunsItsTarget() async {
        var commands: [String] = []
        gateway.handlers["slash.exec"] = { params in
            commands.append(params["command"]?.stringValue ?? "")
            return commands.count == 1 ? .result(["type": "alias", "target": "usage"]) : .result(["output": "usage here"])
        }
        _ = await run("/u")
        XCTAssertEqual(commands, ["u", "usage"])
        XCTAssertEqual(host.outputs, ["usage here"])
    }

    func testPrefillGoesToTheComposer() async {
        gateway.handlers["slash.exec"] = { _ in .result(["type": "prefill", "message": "the last prompt"]) }
        _ = await run("/undo")
        XCTAssertEqual(host.prefills, ["the last prompt"])
        XCTAssertTrue(host.prompts.isEmpty)
    }

    // MARK: Local commands

    func testTitleRenamesThroughTheGateway() async {
        gateway.handlers["session.title"] = { _ in .result(["title": "Trip plan"]) }
        _ = await run("/title Trip plan")
        XCTAssertEqual(gateway.calls("session.title").first?.params, ["session_id": "r1", "title": "Trip plan"])
        XCTAssertEqual(host.outputs, ["Session title set: Trip plan"])
    }

    func testStopInterruptsAndStopsProcesses() async {
        gateway.handlers["session.interrupt"] = { _ in .result(["ok": true, "status": "interrupted"]) }
        gateway.handlers["process.stop"] = { _ in .result(["killed": 2]) }
        _ = await run("/stop")
        XCTAssertEqual(gateway.calls("session.interrupt").count, 1)
        XCTAssertEqual(gateway.calls("process.stop").first?.params, [:])
        XCTAssertEqual(host.outputs, ["Stopped the active turn.\nStopped 2 background processes."])
    }

    func testReasoningSetsTheLevel() async {
        gateway.handlers["config.set"] = { _ in .result(["key": "reasoning", "value": "high"]) }
        _ = await run("/reasoning high --global")
        XCTAssertEqual(gateway.calls("config.set").first?.params,
                       ["key": "reasoning", "value": "high", "session_id": "r1", "scope": "global"])
        XCTAssertEqual(host.outputs, ["reasoning: high"])
    }

    func testBareReasoningShowsTheSetting() async {
        gateway.handlers["config.get"] = { _ in .result(["value": "low", "display": "show"]) }
        _ = await run("/reasoning")
        XCTAssertEqual(host.outputs, ["reasoning: low · display show"])
    }

    func testSideQuestionUsesItsRPC() async {
        gateway.handlers["prompt.btw"] = { _ in .result(["task_id": "t1"]) }
        _ = await run("/btw what is this?")
        XCTAssertEqual(gateway.calls("prompt.btw").first?.params, ["session_id": "r1", "text": "what is this?"])
        XCTAssertEqual(host.outputs, ["btw t1 — answering from a conversation snapshot"])
        _ = await run("/btw")
        XCTAssertEqual(gateway.calls("prompt.btw").count, 1)
    }

    func testCompressReloadsTheTranscript() async {
        gateway.handlers["session.compress"] = { _ in .result(["status": "compressed", "removed": 4, "summary": ["headline": "Compressed 4 messages"]]) }
        _ = await run("/compact")
        XCTAssertEqual(host.outputs, ["compressing context...", "✓ Compressed 4 messages"])
        XCTAssertEqual(host.reloads, 1)
    }

    func testAppCommandsBecomeActions() async {
        _ = await run("/new")
        _ = await run("/fork")
        _ = await run("/model")
        _ = await run("/resume")
        XCTAssertEqual(host.actions, [.newChat, .branch, .chooseModel, .chooseSession])
        XCTAssertTrue(gateway.calls.filter { $0.method != "client.capabilities" }.isEmpty)
    }

    func testJourneyOpensTheMemoryGraph() async {
        // The desktop opens its memory graph for /journey and its aliases instead of printing the timeline.
        _ = await run("/journey")
        _ = await run("/learning")
        _ = await run("/memory-graph last week")
        XCTAssertEqual(host.actions, [.openMemoryGraph, .openMemoryGraph, .openMemoryGraph])
        XCTAssertTrue(host.outputs.isEmpty)
        XCTAssertTrue(gateway.calls("slash.exec").isEmpty)
    }

    func testCommandsThisAppCantOfferAreRefused() async {
        let catalog = CommandsCatalogResult(commands: ["/config": CommandCatalogMeta(desktop: "terminal")])
        _ = await run("/voice")
        _ = await run("/wake on")
        _ = await run("/config", catalog: catalog)
        XCTAssertEqual(host.outputs, [
            "/voice isn't available here. Use the call button to talk with Hermes.",
            "/wake isn't available on iPhone.",
            "/config is only available in the terminal interface.",
        ])
        XCTAssertTrue(gateway.calls("slash.exec").isEmpty)
    }

    func testLocalCommandsWinOverTheCatalog() async {
        let catalog = CommandsCatalogResult(commands: ["/clear": CommandCatalogMeta(desktop: "terminal")])
        _ = await run("/clear", catalog: catalog)
        XCTAssertEqual(host.actions, [.newChat])
        XCTAssertTrue(host.outputs.isEmpty)
    }

    // MARK: Staging

    func testPhotoStagesAsBase64Bytes() async throws {
        gateway.handlers["image.attach_bytes"] = { _ in .result(["attached": true, "path": "/w/.hermes/upload-1.jpg"]) }
        let staged = try await connection.client.stage(.image(Data([0xff, 0xd8]), filename: "photo.jpg"), sessionID: "r1")
        XCTAssertEqual(gateway.calls("image.attach_bytes").first?.params,
                       ["session_id": "r1", "content_base64": "/9g=", "filename": "photo.jpg"])
        XCTAssertEqual(staged, StagedAttachment(kind: .image, name: "upload-1.jpg", refText: nil, path: "/w/.hermes/upload-1.jpg",
                                                sessionID: "r1"), "the full path is what image.detach takes")
    }

    func testFileStagesAsADataURL() async throws {
        gateway.handlers["file.attach"] = { _ in
            .result(["attached": true, "name": "notes.txt", "path": "/w/notes.txt", "ref_path": "notes.txt",
                     "ref_text": "@file:notes.txt", "uploaded": true])
        }
        let staged = try await connection.client.stage(.file(Data("hi".utf8), filename: "notes.txt", mime: "text/plain"), sessionID: "r1")
        XCTAssertEqual(gateway.calls("file.attach").first?.params,
                       ["session_id": "r1", "data_url": "data:text/plain;base64,aGk=", "name": "notes.txt"])
        XCTAssertEqual(staged.refText, "@file:notes.txt")
    }

    func testRefusedPhotoThrows() async {
        gateway.handlers["image.attach_bytes"] = { _ in .result(["attached": false, "message": "unsupported"]) }
        do {
            _ = try await connection.client.stage(.image(Data([1]), filename: "x.heic"), sessionID: "r1")
            XCTFail("staged")
        } catch {
            XCTAssertEqual(error.localizedDescription, "unsupported")
        }
    }

    // MARK: Model controls

    func testModelSwitchUsesConfigSet() async {
        gateway.handlers["config.set"] = { _ in .result(["key": "model", "value": "gpt-5 --provider openai", "deferred": true]) }
        let composer = ComposerModel(sender: SendController(chat: AttachedChat()), connection: connection, profile: nil)
        await composer.select(ModelPick(provider: "openai", model: "gpt-5"))
        await composer.select(ModelPick(provider: "moa", model: "council"))
        let values = gateway.calls("config.set").map { $0.params["value"]?.stringValue }
        XCTAssertEqual(values, ["gpt-5 --provider openai", "council --provider moa --session"])
        XCTAssertEqual(gateway.calls("config.set").first?.params["session_id"], "r1")
        XCTAssertEqual(composer.model, ModelPick(provider: "moa", model: "council"))
    }

    func testConfirmRequiredRollsBackAndAsks() async {
        gateway.handlers["config.set"] = { _ in .result(["key": "model", "confirm_required": true, "confirm_message": "Costly"]) }
        let composer = ComposerModel(sender: SendController(chat: AttachedChat()), connection: connection, profile: nil)
        await composer.select(ModelPick(provider: "openai", model: "o-pro"))
        XCTAssertNil(composer.model)
        XCTAssertEqual(composer.modelConfirmation?.message, "Costly")
    }

    func testEffortAndFastUseConfigSet() async {
        gateway.handlers["config.set"] = { params in .result(["key": params["key"] ?? "", "value": params["value"] ?? ""]) }
        let composer = ComposerModel(sender: SendController(chat: AttachedChat()), connection: connection, profile: nil)
        await composer.setEffort("high")
        await composer.setFast(true)
        XCTAssertEqual(gateway.calls("config.set").map(\.params), [
            ["key": "reasoning", "value": "high", "session_id": "r1"],
            ["key": "fast", "value": "fast", "session_id": "r1"],
        ])
        XCTAssertEqual(composer.effort, "high")
        XCTAssertTrue(composer.fast)
    }

    func testWithoutASessionThePickWaits() async {
        let chat = AttachedChat()
        chat.runtimeSessionID = nil
        let composer = ComposerModel(sender: SendController(chat: chat), connection: connection, profile: nil)
        await composer.select(ModelPick(provider: "openai", model: "gpt-5"))
        await composer.setEffort("high")
        await composer.setFast(true)
        XCTAssertEqual(composer.pendingModel, ModelPick(provider: "openai", model: "gpt-5"))
        XCTAssertEqual(composer.pendingEffort, "high")
        XCTAssertEqual(composer.pendingFast, true)
        XCTAssertTrue(gateway.calls("config.set").isEmpty)

        composer.pendingApplied(ModelPick(provider: "openai", model: "gpt-5"), effort: "high", fast: true)
        XCTAssertNil(composer.pendingModel)
        XCTAssertNil(composer.pendingEffort)
        XCTAssertNil(composer.pendingFast)
    }

    func testAConfirmedMoASwitchStaysSessionOnly() async {
        gateway.handlers["config.set"] = { _ in .result(["key": "model", "value": "council --provider moa --session"]) }
        let composer = ComposerModel(sender: SendController(chat: AttachedChat()), connection: connection, profile: nil)
        await composer.confirmSelect(ModelPick(provider: "moa", model: "council"))
        XCTAssertEqual(gateway.calls("config.set").first?.params["value"], "council --provider moa --session")
        XCTAssertEqual(gateway.calls("config.set").first?.params["confirm_expensive_model"], true)
    }

    func testEditingASentPromptSendsItAsARewind() async {
        let composer = ComposerModel(sender: SendController(chat: AttachedChat()), connection: connection, profile: nil)
        var rewound: [(String, String)] = []
        composer.rewind = { message, text in
            rewound.append((message.id, text))
            return true
        }
        composer.draft = "half-typed"
        composer.editMessage(UserMessage(id: "row-3", text: "fix the bug",
                                         attachments: [AttachmentRef("@file:src/a.swift")!, AttachmentRef("@image:shot.png")!], rowID: 3))
        XCTAssertEqual(composer.draft, "@file:src/a.swift\n\nfix the bug", "references ride along; images can't be sent again")
        composer.draft = "@file:src/a.swift\n\nfix the other bug"
        await composer.send()
        XCTAssertEqual(rewound.map(\.0), ["row-3"])
        XCTAssertEqual(rewound.map(\.1), ["@file:src/a.swift\n\nfix the other bug"])
        XCTAssertNil(composer.editingMessage)
        XCTAssertEqual(composer.draft, "half-typed")

        composer.editMessage(UserMessage(id: "row-3", text: "fix the bug", rowID: 3))
        composer.cancelMessageEdit()
        XCTAssertEqual(composer.draft, "half-typed")
    }

    func testARefusedRewindKeepsTheEdit() async {
        let composer = ComposerModel(sender: SendController(chat: AttachedChat()), connection: connection, profile: nil)
        composer.rewind = { _, _ in false }
        composer.editMessage(UserMessage(id: "row-3", text: "fix the bug", rowID: 3))
        composer.draft = "fix it now"
        await composer.send()
        XCTAssertEqual(composer.editingMessage?.id, "row-3")
        XCTAssertEqual(composer.draft, "fix it now")
    }

    func testEditingAQueuedPromptSetsTheDraftAside() async {
        let chat = AttachedChat()
        chat.isBusy = true
        let composer = ComposerModel(sender: SendController(chat: chat), connection: connection, profile: nil)
        composer.draft = "queued words"
        composer.queue()
        XCTAssertEqual(composer.draft, "")
        composer.draft = "half-typed"
        composer.edit(composer.sender.queue[0].id)
        XCTAssertEqual(composer.draft, "queued words")
        XCTAssertTrue(composer.isEditingQueued)

        composer.draft = "queued words, edited"
        await composer.send()
        XCTAssertEqual(composer.sender.queue.map(\.text), ["queued words, edited"])
        XCTAssertEqual(composer.draft, "half-typed")
        XCTAssertFalse(composer.isEditingQueued)

        composer.edit(composer.sender.queue[0].id)
        composer.cancelEdit()
        XCTAssertEqual(composer.draft, "half-typed")
        XCTAssertEqual(composer.sender.queue.map(\.text), ["queued words, edited"])
    }

    func testRefusedSendGivesTheDraftBack() async {
        let chat = AttachedChat()
        let composer = ComposerModel(sender: SendController(chat: chat), connection: connection, profile: nil)
        composer.draft = "/usage"
        composer.add(ComposerAttachment(pending: .file(Data(), filename: "a.txt", mime: "text/plain")))
        await composer.send()
        XCTAssertEqual(composer.draft, "/usage")
        XCTAssertEqual(composer.attachments.count, 1)
        XCTAssertEqual(composer.notice, SendController.slashWithAttachments)
    }

    // MARK: Completions

    func testPathToken() {
        XCTAssertEqual(ComposerModel.pathToken("look at @src/ma"), "@src/ma")
        XCTAssertEqual(ComposerModel.pathToken("@"), "@")
        XCTAssertNil(ComposerModel.pathToken("look at @src "))
        XCTAssertNil(ComposerModel.pathToken("mail me"))
    }

    func testArgumentCompletionsKeepTheCommand() {
        let result = CompleteSlashResult(items: [CompletionItem(text: "alice", meta: "friendly")], replaceFrom: 13)
        let rows = ComposerModel.slashRows(result, text: "/personality al", catalog: nil)
        XCTAssertEqual(rows.map(\.insert), ["/personality alice "])
        XCTAssertEqual(rows.first?.group, "Options")
    }

    func testCommandCompletionsHideWhatCantRunHere() {
        let result = CompleteSlashResult(items: [
            CompletionItem(text: "/work", kind: "skill"), CompletionItem(text: "/wake"), CompletionItem(text: "/config"),
            CompletionItem(text: "/usage"),
        ], replaceFrom: 1)
        let catalog = CommandsCatalogResult(commands: ["/config": CommandCatalogMeta(desktop: "terminal")])
        let rows = ComposerModel.slashRows(result, text: "/", catalog: catalog)
        XCTAssertEqual(rows.map(\.title), ["/usage", "/work"])
        XCTAssertEqual(rows.map(\.group), ["Commands", "Skills"])
    }

    func testCatalogRowsListSectionsThenSkills() {
        let catalog = CommandsCatalogResult(
            pairs: [["/new", "New chat"], ["/work", "Work skill"], ["/pet", "Pet"]],
            categories: [CommandCategory(name: "Session", pairs: [["/new", "New chat"], ["/pet", "Pet"]])]
        )
        let rows = ComposerModel.catalogRows(catalog)
        XCTAssertEqual(rows.map(\.title), ["/new", "/work"])
        XCTAssertEqual(rows.map(\.group), ["Session", "Skills"])
        XCTAssertEqual(rows.first?.insert, "/new ")
    }

    // MARK: Status stack and session menu

    func testTodosParseAndNest() {
        let raw: [JSONValue] = [
            ["id": "1", "content": "Plan", "status": "completed"],
            ["id": "2", "content": "Build", "status": "in_progress"],
            ["id": "2a", "content": "Write tests", "status": "pending", "parent": "2"],
            ["id": "3", "content": "", "status": "pending"],
            ["id": "4", "content": "Odd", "status": "unknown"],
        ]
        let todos = StatusStackModel.ordered(StatusStackModel.parseTodos(raw))
        XCTAssertEqual(todos.map(\.id), ["1", "2", "2a"])
        XCTAssertEqual(todos.map(\.depth), [0, 0, 1])
        XCTAssertEqual(todos[1].status, .inProgress)
    }

    func testExportFilename() {
        let target = SessionMenuTarget(storedID: "20260101_abcdef12", title: "Trip / Plan!")
        XCTAssertEqual(SessionActions.filename(target), "trip-plan-20260101.json")
        XCTAssertEqual(SessionActions.filename(SessionMenuTarget(storedID: "x", title: "")), "session-x.json")
    }
}
