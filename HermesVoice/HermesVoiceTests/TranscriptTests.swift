import XCTest
@testable import HermesVoice

final class TranscriptTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var transcript = Transcript()

    override func setUp() {
        clock = Date(timeIntervalSince1970: 1_000)
        transcript = Transcript(now: { [unowned self] in clock })
    }

    // MARK: Events

    private func apply(_ events: GatewayEvent...) {
        for event in events { transcript.apply(event) }
    }

    private func delta(_ text: String) -> GatewayEvent { .messageDelta(StreamDeltaPayload(text: text)) }
    private func reasoning(_ text: String) -> GatewayEvent { .reasoningDelta(StreamDeltaPayload(text: text)) }
    private func interim(_ text: String, streamed: Bool = true) -> GatewayEvent {
        .messageInterim(MessageInterimPayload(text: text, alreadyStreamed: streamed))
    }

    private func start(_ id: String, _ name: String, _ args: [String: JSONValue] = [:]) -> GatewayEvent {
        .toolStart(ToolStartPayload(toolId: id, name: name, args: args))
    }

    private func finish(_ id: String, _ name: String, _ result: JSONValue? = ["ok": true], diff: String? = nil,
                        args: [String: JSONValue]? = nil) -> GatewayEvent {
        .toolComplete(ToolCompletePayload(toolId: id, name: name, args: args, durationS: 0.5, result: result, inlineDiff: diff))
    }

    private func complete(_ text: String?, status: TurnStatus = .complete, error: String? = nil, partial: Bool? = nil,
                          surface: ErrorSurface? = nil, reasoning: String? = nil) -> GatewayEvent {
        .messageComplete(MessageCompletePayload(text: text.map(JSONValue.string), status: status, reasoning: reasoning,
                                                error: error, errorSurface: surface, partial: partial))
    }

    private func subagent(_ goal: String, index: Int = 0, count: Int = 1, id: String? = nil, tool: String? = nil,
                          preview: String? = nil, status: SubagentStatus? = nil, duration: Double? = nil,
                          summary: String? = nil) -> SubagentEventPayload {
        SubagentEventPayload(goal: goal, taskCount: count, taskIndex: index, subagentId: id, toolName: tool, status: status,
                             summary: summary, durationSeconds: duration, toolPreview: preview)
    }

    // MARK: Row access

    private var assistants: [AssistantText] {
        transcript.items.compactMap { if case let .assistant(item) = $0 { return item }; return nil }
    }

    private var runs: [ToolRun] {
        transcript.items.compactMap { if case let .toolRun(item) = $0 { return item }; return nil }
    }

    private var reasonings: [Reasoning] {
        transcript.items.compactMap { if case let .reasoning(item) = $0 { return item }; return nil }
    }

    private var errors: [TurnError] {
        transcript.items.compactMap { if case let .error(item) = $0 { return item }; return nil }
    }

    private var notes: [SystemNote] {
        transcript.items.compactMap { if case let .system(item) = $0 { return item }; return nil }
    }

    private var delegations: [Delegation] {
        transcript.items.compactMap { if case let .subagent(item) = $0 { return item }; return nil }
    }

    /// Each row's kind, in order.
    private var kinds: [String] {
        transcript.items.map { item in
            switch item {
            case .user: return "user"
            case .assistant: return "assistant"
            case .reasoning: return "reasoning"
            case .toolRun: return "run"
            case .subagent: return "subagent"
            case .system: return "system"
            case .error: return "error"
            case .media: return "media"
            case .changedFiles: return "files"
            }
        }
    }

    // MARK: Streaming

    func testMessageStartMakesNoRow() {
        apply(.messageStart)
        XCTAssertTrue(transcript.items.isEmpty)
        XCTAssertTrue(transcript.turnRunning)
        apply(delta("\n\n"), delta("  "))
        XCTAssertTrue(transcript.items.isEmpty, "whitespace before the reply makes no row")
    }

    func testDeltasStreamIntoOneRowThatTheFinalTextSettles() {
        transcript.appendUser("Hi")
        apply(.messageStart, delta("Hel"), delta("lo"))
        XCTAssertEqual(kinds, ["user", "assistant"])
        XCTAssertEqual(assistants.first?.markdown, "Hello")
        XCTAssertEqual(assistants.first?.streaming, true)

        apply(complete("Hello there"))
        XCTAssertEqual(kinds, ["user", "assistant"])
        XCTAssertEqual(assistants.first?.markdown, "Hello there")
        XCTAssertEqual(assistants.first?.streaming, false)
        XCTAssertFalse(transcript.turnRunning)
    }

    func testFinalTextWithoutDeltasIsAdded() {
        transcript.appendUser("Hi")
        apply(.messageStart, complete("Hello"))
        XCTAssertEqual(kinds, ["user", "assistant"])
        XCTAssertEqual(assistants.first?.markdown, "Hello")
    }

    func testChainedTurnWithoutPromptKeepsTheEarlierReply() {
        transcript.appendUser("Hi")
        apply(.messageStart, delta("One"), complete("One"))
        apply(.messageStart, complete("Two"))
        XCTAssertEqual(assistants.map(\.markdown), ["One", "Two"])
    }

    func testReasoningIsTimedAndSealedByTheReply() {
        apply(.messageStart, reasoning("Let me "), reasoning("think"))
        XCTAssertEqual(reasonings.first?.text, "Let me think")
        XCTAssertEqual(reasonings.first?.streaming, true)
        clock += 3
        apply(delta("Answer"))
        XCTAssertEqual(kinds, ["reasoning", "assistant"])
        XCTAssertEqual(reasonings.first?.streaming, false)
        XCTAssertEqual(reasonings.first?.duration, 3)
    }

    func testFinishedReasoningBlockReplacesTheLiveOne() {
        apply(.messageStart, reasoning("draft"))
        clock += 2
        apply(.reasoningAvailable(StreamDeltaPayload(text: "final thoughts")))
        XCTAssertEqual(reasonings.count, 1)
        XCTAssertEqual(reasonings.first?.text, "final thoughts")
        XCTAssertEqual(reasonings.first?.duration, 2)
        apply(.reasoningAvailable(StreamDeltaPayload(text: "final thoughts")))
        XCTAssertEqual(reasonings.count, 1, "a repeated block isn't shown twice")
    }

    func testReasoningFromTheFinalFrameGoesAboveTheReply() {
        apply(.messageStart, delta("Answer"), complete("Answer", reasoning: "Because"))
        XCTAssertEqual(kinds, ["reasoning", "assistant"])
        XCTAssertNil(reasonings.first?.duration)
    }

    func testInterimCommentarySealsItsRowAndSplitsRuns() {
        apply(.messageStart, start("a", "terminal", ["command": "ls"]), finish("a", "terminal"))
        apply(delta("Looking closer"), interim("Looking closer"))
        apply(start("b", "read_file", ["path": "/x/y.swift"]), finish("b", "read_file"))
        XCTAssertEqual(kinds, ["run", "assistant", "run"])
        XCTAssertEqual(assistants.first?.interim, true)
        XCTAssertEqual(assistants.first?.streaming, false)

        apply(interim("Looking closer"))
        XCTAssertEqual(assistants.count, 1, "a second delivery of the same commentary is dropped")

        apply(interim("Not streamed", streamed: false))
        XCTAssertEqual(assistants.map(\.markdown), ["Looking closer", "Not streamed"])
    }

    func testFinalRepeatingTheCommentaryBeforeToolsIsNotDuplicated() {
        apply(.messageStart, delta("Answer"), interim("Answer"), start("a", "terminal"), finish("a", "terminal"), complete("Answer"))
        XCTAssertEqual(assistants.map(\.markdown), ["Answer"])
    }

    func testReplyAfterToolsIsItsOwnRow() {
        apply(.messageStart, delta("Checking"), start("a", "terminal"), finish("a", "terminal"), delta("Done"), complete("Done"))
        XCTAssertEqual(kinds, ["assistant", "run", "assistant"])
        XCTAssertEqual(assistants.map(\.markdown), ["Checking", "Done"])
    }

    // MARK: Tools

    func testConsecutiveCallsGroupIntoOneRun() {
        apply(.messageStart, start("a", "terminal", ["command": "ls"]))
        XCTAssertEqual(runs.first?.live, true)
        XCTAssertEqual(runs.first?.calls.first?.isPending, true)
        apply(finish("a", "terminal", ["output": "x", "exit_code": 0]), start("b", "read_file", ["path": "/p/a.swift"]),
              finish("b", "read_file", ["content": "code"]))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.calls.map(\.name), ["terminal", "read_file"])
        XCTAssertEqual(runs.first?.calls.allSatisfy(\.done), true)
        XCTAssertEqual(runs.first?.calls.first?.duration, 0.5)

        apply(delta("ok"))
        XCTAssertEqual(runs.first?.live, false, "text after a run settles it")
    }

    func testCompletionWithoutStartMakesTheCall() {
        apply(.messageStart, finish("a", "web_search", ["results": []], args: ["query": "swift"]))
        XCTAssertEqual(runs.first?.calls.first?.args["query"], "swift")
        XCTAssertEqual(runs.first?.calls.first?.done, true)
    }

    func testRepeatedCallIDsStayUniqueAndCompleteTheOpenCall() {
        transcript.appendUser("one")
        apply(.messageStart, start("c1", "terminal"), finish("c1", "terminal"), complete("done"))
        transcript.appendUser("two")
        apply(.messageStart, start("c1", "terminal", ["command": "pwd"]), finish("c1", "terminal", ["output": "/"]))
        let calls = runs.flatMap(\.calls)
        XCTAssertEqual(calls.count, 2)
        XCTAssertNotEqual(calls[0].id, calls[1].id)
        XCTAssertEqual(calls[1].callID, "c1")
        XCTAssertEqual(calls[1].output, "/")
    }

    func testFileEditsStandAloneAndTheTurnEndsWithChangedFiles() {
        transcript.appendUser("fix it")
        apply(.messageStart, start("r", "read_file", ["path": "/p/a.swift"]), finish("r", "read_file"))
        apply(start("e", "patch", ["path": "/p/a.swift"]), finish("e", "patch", ["success": true], diff: "--- a\n+++ b\n+new\n-old\n+more"))
        apply(start("w", "write_file", ["path": "/p/b.swift"]), finish("w", "write_file", ["success": true], diff: "+x"))
        apply(delta("Fixed"), complete("Fixed"))
        XCTAssertEqual(kinds, ["user", "run", "run", "run", "assistant", "files"])
        guard case let .changedFiles(changes)? = transcript.items.last else { return XCTFail("\(kinds)") }
        XCTAssertEqual(changes.files.map(\.name), ["a.swift", "b.swift"])
        XCTAssertEqual(changes.files.first?.added, 2)
        XCTAssertEqual(changes.files.first?.removed, 1)
        XCTAssertEqual(runs[1].calls.first?.diffCounts?.added, 2)
    }

    func testSpokenLinesStandAlone() {
        apply(.messageStart, start("a", "terminal"), start("s", "mcp__hermes_voice__speak", ["text": "Hello there"]),
              start("t", "start_call", ["text": "Calling you"]))
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs[1].calls.first?.isSpeech, true)
        XCTAssertEqual(runs[1].calls.first?.spokenText, "Hello there")
        XCTAssertEqual(runs[2].calls.first?.isSpeech, true)
    }

    func testTodoCallsStayOutOfTheTranscript() {
        let todos: JSONValue = [["id": "1", "content": "Write tests", "status": "in_progress"]]
        apply(.messageStart, start("t", "todo", ["todos": todos]),
              .toolComplete(ToolCompletePayload(toolId: "t", name: "todo", result: ["todos": todos], todos: todos.arrayValue, revision: 2)))
        XCTAssertTrue(transcript.items.isEmpty)
        XCTAssertEqual(transcript.todos, [TodoItem(id: "1", content: "Write tests", status: "in_progress")])

        apply(.todoUpdated(TodoUpdatedPayload(todos: [["id": "1", "content": "Write tests", "status": "completed"]], revision: 1)))
        XCTAssertEqual(transcript.todos.first?.status, "in_progress", "an older revision is ignored")
        apply(.todoUpdated(TodoUpdatedPayload(todos: [["id": "1", "content": "Write tests", "status": "completed"]], revision: 3)))
        XCTAssertEqual(transcript.todos.first?.status, "completed")

        apply(start("u", "todo"), finish("u", "todo", ["error": "bad todo list"]))
        XCTAssertEqual(runs.first?.calls.first?.name, "todo", "a failing todo call is shown")
    }

    func testStatusIsRedOnlyForRealFailures() {
        func status(_ name: String, _ result: JSONValue) -> ToolStatus {
            ToolCall(id: "x", callID: "x", name: name, result: result, done: true).status
        }
        XCTAssertEqual(status("terminal", ["output": "no match", "exit_code": 1]), .success)
        XCTAssertEqual(status("terminal", ["output": "", "exit_code": 1]), .notice)
        XCTAssertEqual(status("terminal", ["output": "", "exit_code": 2]), .error)
        XCTAssertEqual(status("read_file", ["error": "File not found: /x"]), .notice)
        XCTAssertEqual(status("patch", ["success": false, "error": "denied"]), .error)
        XCTAssertEqual(status("memory", ["success": true, "error": "stale"]), .success)
        XCTAssertEqual(status("web_extract", ["content": "an error page about errors"]), .success)
        XCTAssertEqual(status("browser_click", .string("{\"status\": \"failed\", \"message\": \"gone\"}")), .error)
        XCTAssertEqual(ToolCall(id: "x", callID: "x", name: "terminal", done: true).status, .warning, "no result arrived")
        XCTAssertEqual(ToolCall(id: "x", callID: "x", name: "terminal", done: true, interrupted: true).status, .notice)
    }

    func testTitlesAndRunSummary() {
        let ls = ToolCall(id: "1", callID: "1", name: "terminal", args: ["command": "cd /repo && ls  -la"], result: ["output": ""], done: true)
        XCTAssertEqual(ls.title, "Ran ls -la")
        let read = ToolCall(id: "2", callID: "2", name: "read_file", args: ["path": "/src/Foo.swift"], result: ["content": ""], done: true)
        XCTAssertEqual(read.title, "Read Foo.swift")
        let search = ToolCall(id: "3", callID: "3", name: "web_search", args: ["query": "swift regex"])
        XCTAssertEqual(search.title, "Searching “swift regex”")
        XCTAssertEqual(ToolCall(id: "4", callID: "4", name: "mcp__github__list_issues", result: [:], done: true).title, "List Issues")

        let read2 = ToolCall(id: "5", callID: "5", name: "list_files", args: ["path": "/src"], result: [:], done: true)
        XCTAssertEqual(ToolRunSummary.summarize([read, read2, ls], live: false), "Explored 2 files, ran 1 command")
        var running = ls
        running.done = false
        running.result = nil
        XCTAssertEqual(ToolRunSummary.summarize([read, running], live: true), "Explored Foo.swift, running ls -la")
    }

    // MARK: Turn end

    func testStoppedTurnSealsOpenCallsAndSaysSo() {
        apply(.messageStart, start("a", "terminal"), complete("", status: .interrupted))
        XCTAssertEqual(runs.first?.calls.first?.done, true)
        XCTAssertEqual(runs.first?.calls.first?.interrupted, true)
        XCTAssertEqual(runs.first?.calls.first?.title, "Interrupted")
        XCTAssertEqual(notes.last?.kind, .stopped)
    }

    func testIdleSessionSettlesOpenRowsAndTheLateFinalStillLands() {
        transcript.appendUser("go")
        apply(.messageStart, start("a", "terminal"), delta("Almost"))
        apply(.sessionInfo(SessionLiveInfo(running: false)))
        XCTAssertFalse(transcript.turnRunning)
        XCTAssertEqual(runs.first?.calls.first?.done, true)
        XCTAssertEqual(assistants.first?.streaming, false)
        apply(complete("Almost done"))
        XCTAssertEqual(assistants.map(\.markdown), ["Almost done"])
    }

    func testFailedTurnDropsTheErrorTextAndShowsTheLayer() {
        apply(.messageStart, delta("Rate limit"))
        let surface = ErrorSurface(layer: "provider", code: "rate_limit", retryable: true, provider: "openrouter")
        apply(complete("Rate limit", status: .error, error: "429 Too Many Requests", surface: surface))
        XCTAssertEqual(kinds, ["error"])
        XCTAssertEqual(errors.first?.layer, .provider)
        XCTAssertEqual(errors.first?.code, "rate_limit")
        XCTAssertEqual(errors.first?.message, "429 Too Many Requests")
        XCTAssertEqual(errors.first?.recovery, [.retry, .switchProvider])
        XCTAssertEqual(errors.first.map { ErrorCopy.text(for: $0).title }, "The AI service is busy")
    }

    func testPartialFailureKeepsTheStreamedText() {
        apply(.messageStart, delta("Half an ans"))
        apply(complete("Half an answer", status: .error, error: "stream dropped", partial: true,
                       surface: ErrorSurface(layer: "streaming", code: "stream_drop", retryable: true)))
        XCTAssertEqual(kinds, ["assistant", "error"])
        XCTAssertEqual(assistants.first?.markdown, "Half an answer")
    }

    func testTerminalFrameSettlesOntoTheBareErrorCard() {
        apply(.messageStart, .error(ErrorPayload(message: "agent failed")))
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(errors.first?.layer)
        XCTAssertEqual(errors.first?.recovery, [.retry])
        apply(complete(nil, status: .error, error: "agent failed", surface: ErrorSurface(layer: "runtime", code: "x", retryable: false)))
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.layer, .runtime)
        XCTAssertEqual(errors.first?.recovery, [])
    }

    func testRecoveryPlans() {
        func plan(_ layer: String, _ code: String, retryable: Bool = true, extras: [String: JSONValue] = [:]) -> [ErrorRecovery] {
            Transcript.turnError(message: "x", surface: ErrorSurface(layer: layer, code: code, retryable: retryable, extras: extras), id: "e").recovery
        }
        XCTAssertEqual(plan("provider", "context_overflow"), [.compress, .switchProvider, .startNewSession])
        XCTAssertEqual(plan("provider", "model_not_found"), [.chooseModel, .switchProvider])
        XCTAssertEqual(plan("provider", "content_policy_blocked"), [.switchProvider, .editMessage])
        XCTAssertEqual(plan("auth", "auth", retryable: false, extras: ["auth_kind": "api_key"]), [.retry, .switchProvider])
        XCTAssertEqual(plan("gateway", "loop_error"), [.retry, .startNewSession])

        let owned = Transcript.turnError(message: "Session already has a live owner", surface: nil, id: "e")
        XCTAssertEqual(owned.code, "SESSION_NOT_OWNED")
        XCTAssertEqual(owned.recovery, [.startNewSession])
        XCTAssertEqual(Transcript.turnError(message: "No space left on device", surface: nil, id: "e").layer, .disk)
    }

    // MARK: Subagents

    func testSubagentEventsFillTheDelegationCard() {
        let tasks: JSONValue = [["goal": "Audit docs"], ["goal": "Fix tests"]]
        apply(.messageStart, start("d", "delegate_task", ["tasks": tasks]))
        XCTAssertEqual(delegations.first?.rows.map(\.goal), ["Audit docs", "Fix tests"])
        XCTAssertEqual(delegations.first?.rows.map(\.status), [.running, .running])

        apply(.subagentStart(subagent("Audit docs", index: 0, count: 2, id: "s1")),
              .subagentTool(subagent("Audit docs", index: 0, count: 2, id: "s1", tool: "terminal", preview: "ls docs")),
              .subagentStart(subagent("", index: 1, count: 2, id: "s2")))
        XCTAssertEqual(delegations.first?.rows.first?.activity, ["terminal: ls docs"])
        XCTAssertEqual(delegations.first?.rows.last?.subagentID, "s2", "claimed by task index when the goal is missing")

        apply(.subagentComplete(subagent("Audit docs", index: 0, count: 2, id: "s1", status: .completed, duration: 4, summary: "All good")))
        XCTAssertEqual(delegations.first?.rows.first?.status, .completed)
        XCTAssertEqual(delegations.first?.rows.first?.activity.last, "All good")

        apply(finish("d", "delegate_task", ["results": [["status": "ok", "summary": "All good"], ["status": "timeout"]]]))
        XCTAssertEqual(delegations.first?.rows.map(\.status), [.completed, .failed])
        XCTAssertEqual(delegations.count, 1)
        XCTAssertTrue(runs.isEmpty)
    }

    func testChildrenWithoutAVisibleCallGetACard() {
        apply(.messageStart, .subagentSpawnRequested(subagent("Look around", id: "s1")))
        XCTAssertEqual(delegations.first?.rows.first?.status, .queued)
        XCTAssertNil(delegations.first?.call)
        apply(finish("d", "delegate_task", ["status": "dispatched", "goals": ["Look around"]], args: ["goal": "Look around"]))
        XCTAssertEqual(delegations.count, 1, "the call joins the card its children made")
        XCTAssertEqual(delegations.first?.call?.callID, "d")
    }

    // MARK: History

    func testStoredPageBecomesRows() {
        transcript.load(history: [
            ["id": 1, "role": "user", "content": "@file:notes/todo.txt\nPlease look", "timestamp": 1_700_000_000],
            ["id": 2, "role": "assistant", "content": "", "reasoning": "Thinking it over",
             "tool_calls": [["id": "c1", "type": "function", "function": ["name": "terminal", "arguments": "{\"command\":\"ls\"}"]]]],
            ["id": 3, "role": "tool", "tool_call_id": "c1", "tool_name": "terminal", "content": "{\"output\": \"a.txt\", \"exit_code\": 0}"],
            ["id": 4, "role": "assistant", "content": [["type": "text", "text": "Here it is\nMEDIA:/tmp/out.png"]]],
            ["id": 5, "role": "user", "content": "[Background process p1 heartbeat #2 ..."],
            ["id": 6, "role": "user", "content": "scaffold", "display_kind": "hidden"],
            ["id": 7, "role": "system", "content": "", "display_kind": "model_switch"],
        ])
        XCTAssertEqual(kinds, ["user", "reasoning", "run", "assistant", "media", "system"])
        guard case let .user(user) = transcript.items[0] else { return XCTFail() }
        XCTAssertEqual(user.text, "Please look")
        XCTAssertEqual(user.attachments.map(\.label), ["todo.txt"])
        XCTAssertEqual(user.rowID, 1)
        XCTAssertEqual(runs.first?.calls.first?.args["command"], "ls")
        XCTAssertEqual(runs.first?.calls.first?.output, "a.txt")
        XCTAssertEqual(runs.first?.calls.first?.status, .success)
        XCTAssertEqual(assistants.first?.markdown, "Here it is")
        XCTAssertEqual(assistants.first?.media.map(\.name), ["out.png"])
        XCTAssertEqual(notes.first?.text, "model changed")
    }

    func testNewestFirstPageIsTurnedAround() {
        transcript.load(history: [
            ["id": 9, "role": "assistant", "content": "second"],
            ["id": 8, "role": "user", "content": "first"],
        ])
        XCTAssertEqual(kinds, ["user", "assistant"])
    }

    func testStoredCallWithoutResultReadsAsUnavailable() {
        transcript.load(history: [
            ["id": 1, "role": "user", "content": "go"],
            ["id": 2, "role": "assistant", "content": "", "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": "{}"]]]],
            ["id": 3, "role": "tool", "tool_call_id": "zz", "tool_name": "web_search", "content": "{\"results\": []}"],
            ["id": 4, "role": "user", "content": "again"],
        ])
        XCTAssertEqual(runs.first?.calls.map(\.name), ["terminal", "web_search"])
        XCTAssertEqual(runs.first?.calls.first?.title, "Result unavailable")
        XCTAssertEqual(runs.first?.calls.last?.done, true)
    }

    func testStoredFailedTurnShowsItsErrorCard() {
        transcript.load(history: [
            ["id": 1, "role": "user", "content": "go"],
            ["id": 2, "role": "assistant", "content": "Your request was not processed.", "display_kind": "failed_turn",
             "display_metadata": ["error": "upstream 529", "error_surface": ["layer": "provider", "code": "overloaded", "retryable": true]]],
        ])
        XCTAssertEqual(kinds, ["user", "error", "system"])
        XCTAssertEqual(errors.first?.code, "overloaded")
        XCTAssertEqual(errors.first?.message, "upstream 529")
    }

    func testStoredEditsEndTheirTurnWithChangedFiles() {
        transcript.load(history: [
            ["id": 1, "role": "user", "content": "edit"],
            ["id": 2, "role": "assistant", "content": "", "tool_calls": [["id": "p", "function": ["name": "patch", "arguments": "{\"path\": \"a.txt\"}"]]]],
            ["id": 3, "role": "tool", "tool_call_id": "p", "tool_name": "patch", "content": "{\"success\": true, \"diff\": \"+a\\n-b\"}"],
            ["id": 4, "role": "assistant", "content": "Done"],
            ["id": 5, "role": "user", "content": "thanks"],
        ])
        XCTAssertEqual(kinds, ["user", "run", "assistant", "files", "user"])
    }

    func testLoadKeepsATurnStillRunningOpen() {
        apply(.sessionInfo(SessionLiveInfo(running: true)))
        transcript.load(history: [
            ["id": 1, "role": "user", "content": "go"],
            ["id": 2, "role": "assistant", "content": "", "tool_calls": [["id": "c1", "function": ["name": "terminal", "arguments": "{}"]]]],
        ])
        XCTAssertEqual(runs.first?.calls.first?.isPending, true)
        apply(finish("c1", "terminal", ["output": "ok"]), delta("Finished"), complete("Finished"))
        XCTAssertEqual(kinds, ["user", "run", "assistant"])
        XCTAssertEqual(runs.first?.calls.first?.output, "ok")
    }

    func testReloadMidTurnKeepsTheTurnAndItsStream() {
        let prompt = transcript.appendUser("go", id: "local-1")
        apply(.messageStart, start("c1", "terminal", ["command": "ls"]), finish("c1", "terminal", ["output": "a.txt"]), delta("Look"))
        let running = transcript.runningTurnIDs
        XCTAssertEqual(running.count, 2, "the run and the reply, not the prompt")
        XCTAssertFalse(running.contains(prompt))

        transcript.load(history: [["id": 1, "role": "user", "content": "go"]], keeping: running)
        XCTAssertEqual(kinds, ["user", "run", "assistant"])
        apply(delta("ing"))
        XCTAssertEqual(assistants.map(\.markdown), ["Looking"], "the stream went on in the kept row")
        apply(complete("Looking good"))
        XCTAssertEqual(kinds, ["user", "run", "assistant"])
        XCTAssertEqual(assistants.map(\.markdown), ["Looking good"])
        XCTAssertEqual(runs.first?.calls.first?.output, "a.txt")
        XCTAssertTrue(transcript.runningTurnIDs.isEmpty)
    }

    func testReloadPutsKeptPromptsAfterTheStoredRows() {
        transcript.appendUser("unsent", id: "local-1")
        transcript.appendSlashOutput(command: "/status", output: "ok")
        transcript.load(history: [["id": 1, "role": "user", "content": "first"], ["id": 2, "role": "assistant", "content": "One"]],
                        keeping: ["local-1"])
        XCTAssertEqual(kinds, ["user", "assistant", "user"])
        XCTAssertEqual(transcript.items.last?.id, "local-1")
    }

    func testCorrectionSealsWhatStreamedAndTheReplyFollowsIt() {
        transcript.appendUser("write a poem")
        apply(.messageStart, delta("Roses are"))
        let correction = transcript.appendCorrection("make it about cats")
        apply(delta("Cats are"))
        XCTAssertEqual(kinds, ["user", "assistant", "user", "assistant"])
        XCTAssertEqual(assistants.map(\.markdown), ["Roses are", "Cats are"])
        XCTAssertEqual(assistants.first?.streaming, false)
        apply(complete("Cats are soft"))
        XCTAssertEqual(assistants.map(\.markdown), ["Roses are", "Cats are soft"])
        XCTAssertEqual(transcript.items[2].id, correction)
    }

    func testRefusedCorrectionLetsTheReplyStreamOn() {
        transcript.appendUser("write a poem")
        apply(.messageStart, delta("Roses are"))
        let correction = transcript.appendCorrection("make it about cats")
        transcript.withdrawCorrection(correction)
        apply(delta(" red"), complete("Roses are red"))
        XCTAssertEqual(kinds, ["user", "assistant"])
        XCTAssertEqual(assistants.map(\.markdown), ["Roses are red"])
    }

    // MARK: Prompts and notes

    func testPromptProjection() {
        let attached = Transcript.userText("Look at this\n\n--- Attached Context ---\n@file:src/a.swift\n@url:\"https://example.com/x\"\nbody")
        XCTAssertEqual(attached.text, "Look at this")
        XCTAssertEqual(attached.refs.map(\.kind), [.file, .url])
        XCTAssertEqual(attached.refs.last?.label, "example.com/x")

        let images = Transcript.userText("@image:/tmp/shot.png\n[screenshot]\nWhat is this?")
        XCTAssertEqual(images.text, "What is this?")
        XCTAssertEqual(images.refs.map(\.label), ["shot.png"])

        transcript.appendUser("[Voice] turn the lights on")
        transcript.appendUser("[Voice call started] Speak with start_call.")
        guard case let .user(spoken) = transcript.items[0] else { return XCTFail() }
        XCTAssertEqual(spoken.spoken, "turn the lights on")
        XCTAssertEqual(notes.first?.kind, .call)
        XCTAssertEqual(notes.first?.text, "Voice call started")
    }

    func testSystemNotes() {
        transcript.appendSlashOutput(command: "/model", output: "model → x")
        transcript.appendSteer("use tabs")
        apply(.btwComplete(SideAgentCompletePayload(taskId: "t1", text: "42", question: "answer?")),
              .reviewSummary(ReviewSummaryPayload(text: "💾 Self-improvement review: saved 1 memory")))
        XCTAssertEqual(notes.map(\.kind), [.slash(command: "/model"), .steer, .background(report: "42", process: false), .review(label: "Self-improvement review")])
        XCTAssertEqual(notes.last?.text, "saved 1 memory")
    }

    func testEventsOutsideTheContractAreSalvaged() {
        apply(.messageStart, .unknown(type: "message.delta", payload: ["text": "hi", "rendered": 4]))
        XCTAssertEqual(assistants.first?.markdown, "hi")
    }

    // MARK: Media and markdown

    func testMediaTags() {
        let line = MediaRef.split("Here:\nMEDIA:/tmp/My Report.pdf\nDone")
        XCTAssertEqual(line.text, "Here:\nDone")
        XCTAssertEqual(line.media.map(\.name), ["My Report.pdf"])
        XCTAssertEqual(line.media.first?.kind, .document)

        let inline = MediaRef.split("Open MEDIA:/tmp/a.png.")
        XCTAssertEqual(inline.text, "Open `a.png`.")
        XCTAssertEqual(inline.media.first?.kind, .image)

        XCTAssertEqual(MediaRef.split("talk about MEDIA: tags").media, [], "a stray word isn't a file")
    }

    func testMarkdownBlocks() {
        let blocks = MarkdownBlock.parse("""
        # Title
        Some *text*
        continued.

        - one
          - nested
        - [x] done

        1. first
        2) second

        ```swift
        let x = 1
        ```

        | A | B |
        |:--|--:|
        | 1 | 2 |

        > quoted

        ---
        ```
        open fence
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("Some *text*\ncontinued."),
            .list([
                MarkdownListItem(level: 0, marker: "•", text: "one"),
                MarkdownListItem(level: 1, marker: "•", text: "nested"),
                MarkdownListItem(level: 0, marker: "•", text: "done", checked: true),
            ]),
            .list([MarkdownListItem(level: 0, marker: "1.", text: "first"), MarkdownListItem(level: 0, marker: "2.", text: "second")]),
            .code(language: "swift", code: "let x = 1"),
            .table(header: ["A", "B"], alignments: [.leading, .trailing], rows: [["1", "2"]]),
            .quote([.paragraph("quoted")]),
            .rule,
            .code(language: nil, code: "open fence"),
        ])
    }
}
