import XCTest
@testable import HermesVoice

/// The spawn tree (roster, tree, formats, store over a scripted gateway) and the session importer (list paging,
/// sources, previews, import flow).
@MainActor
final class AgentsImportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func payload(_ object: [String: JSONValue]) -> AgentPayload {
        AgentPayload(json: .object(object))
    }

    private func event(_ type: String, _ object: [String: JSONValue]) -> GatewayEvent {
        GatewayEvent.decode(type: type, payload: .object(object))
    }

    // MARK: Status and payloads

    func testStatusNormalizesLikeTheDesktop() {
        XCTAssertEqual(AgentStatus.normalize("completed"), .completed)
        XCTAssertEqual(AgentStatus.normalize("timeout"), .failed)
        XCTAssertEqual(AgentStatus.normalize("error"), .failed)
        XCTAssertEqual(AgentStatus.normalize("cancelled"), .interrupted)
        XCTAssertEqual(AgentStatus.normalize("queued"), .queued)
        XCTAssertEqual(AgentStatus.normalize("weird"), .running, "live frames stay lenient")
        XCTAssertEqual(AgentStatus.normalize(nil), .running)
        XCTAssertEqual(AgentStatus.normalize("running", terminalEvent: true), .failed, "a completion never spins")
        XCTAssertEqual(AgentStatus.normalize(nil, terminalEvent: true), .failed)
    }

    func testPayloadReadsTypedAndLenientFields() throws {
        guard case let .subagentTool(typed) = event("subagent.tool", [
            "goal": "Scan repo", "task_count": 2, "task_index": 1, "subagent_id": "sa-1", "parent_id": "sa-0",
            "child_session_id": "child-1", "delegation_id": "d-1", "model": "m-small", "tool_count": 3,
            "input_tokens": 1200, "output_tokens": 300, "files_read": ["a.py"], "files_written": ["b.py"],
            "tool_name": "web_search", "tool_preview": "swift   concurrency", "text": "swift concurrency",
            "output_tail": [["tool": "read_file", "preview": "a.py", "is_error": false]],
        ]) else { return XCTFail("a contract frame decodes typed") }
        let read = AgentPayload(typed)
        XCTAssertEqual(read.subagentID, "sa-1")
        XCTAssertEqual(read.parentID, "sa-0")
        XCTAssertEqual(read.childSessionID, "child-1")
        XCTAssertEqual(read.taskCount, 2)
        XCTAssertEqual(read.inputTokens, 1200)
        XCTAssertEqual(read.filesWritten, ["b.py"])
        XCTAssertEqual(read.outputTail.first?.tool, "read_file")
        XCTAssertEqual(read.rowID, "sa-1")

        let loose = payload(["goal": "", "task_index": "2", "duration_seconds": "12.5", "error": "boom",
                             "files_read": ["", "x"]])
        XCTAssertNil(loose.goal, "an empty string reads as absent")
        XCTAssertEqual(loose.taskIndex, 2)
        XCTAssertEqual(loose.durationSeconds, 12.5)
        XCTAssertTrue(loose.hasError)
        XCTAssertEqual(loose.filesRead, ["x"])
        XCTAssertEqual(loose.rowID, "root:2:", "no id: parent, task index and goal")
    }

    // MARK: Roster

    func testFramesBuildARowAndFinishedRowsIgnoreLateFrames() {
        var roster = AgentRoster()
        roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "Scan", "model": "m"]),
                      createIfMissing: true, eventType: "subagent.start", now: t0)
        roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "Scan", "tool_name": "web_search",
                                                      "tool_preview": "swift  actors", "tool_count": 1]),
                      createIfMissing: false, eventType: "subagent.tool", now: t0.addingTimeInterval(2))
        roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "Scan", "tool_name": "web_search",
                                                      "tool_preview": "swift  actors"]),
                      createIfMissing: false, eventType: "subagent.tool", now: t0.addingTimeInterval(3))
        roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "Scan", "text": "thinking hard"]),
                      createIfMissing: false, eventType: "subagent.thinking", now: t0.addingTimeInterval(4))
        var agent = roster.agents(in: "s")[0]
        XCTAssertEqual(agent.status, .running)
        XCTAssertEqual(agent.startedAt, t0, "the first frame dates it")
        XCTAssertEqual(agent.updatedAt, t0.addingTimeInterval(4))
        XCTAssertEqual(agent.currentTool, "web_search")
        XCTAssertEqual(agent.model, "m", "a frame without the field keeps it")
        XCTAssertEqual(agent.stream.map(\.text), ["Web Search(\"swift actors\")", "thinking hard"],
                       "a repeated line isn't added twice")
        XCTAssertEqual(agent.stream.map(\.kind), [.tool, .thinking])

        roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "Scan", "status": "completed",
                                                      "summary": "Found 3 files", "duration_seconds": 9.4]),
                      createIfMissing: false, eventType: "subagent.complete", now: t0.addingTimeInterval(9))
        agent = roster.agents(in: "s")[0]
        XCTAssertEqual(agent.status, .completed)
        XCTAssertNil(agent.currentTool, "a finished row runs no tool")
        XCTAssertEqual(agent.stream.last?.kind, .summary)
        XCTAssertEqual(agent.stream.last?.text, "Found 3 files")

        roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "Scan", "text": "late"]),
                      createIfMissing: true, eventType: "subagent.progress", now: t0.addingTimeInterval(10))
        XCTAssertEqual(roster.agents(in: "s")[0], agent, "a finished row ignores late frames")

        roster.upsert(session: "s", payload: payload(["subagent_id": "b", "goal": "Never started"]),
                      createIfMissing: false, eventType: "subagent.complete", now: t0)
        XCTAssertEqual(roster.agents(in: "s").count, 1, "no row is made when creating isn't allowed")
    }

    func testTimeoutAndFailedCompletionsExplainThemselves() {
        var roster = AgentRoster()
        roster.upsert(session: "s", payload: payload(["subagent_id": "t", "goal": "Slow", "status": "timeout",
                                                      "duration_seconds": 612.3]),
                      createIfMissing: true, eventType: "subagent.complete", now: t0)
        let agent = roster.agents(in: "s")[0]
        XCTAssertEqual(agent.status, .failed)
        XCTAssertEqual(agent.summary, "Timed out after 612.3s")
        XCTAssertEqual(agent.stream.last?.text, "Timed out after 612.3s")
        XCTAssertEqual(agent.stream.last?.isError, true)
    }

    func testStreamKeepsTheNewest24Lines() {
        var roster = AgentRoster()
        for index in 0..<30 {
            roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "G", "text": .string("line \(index)")]),
                          createIfMissing: true, eventType: "subagent.progress", now: t0)
        }
        let stream = roster.agents(in: "s")[0].stream
        XCTAssertEqual(stream.count, AgentRoster.maxStream)
        XCTAssertEqual(stream.first?.text, "line 6")
        XCTAssertEqual(stream.last?.text, "line 29")
    }

    func testANewTurnRetiresFinishedRowsAndKeepsLiveOnes() {
        var roster = AgentRoster()
        roster.upsert(session: "s", payload: payload(["subagent_id": "done", "goal": "A", "status": "completed"]),
                      createIfMissing: true, eventType: "subagent.complete", now: t0)
        roster.upsert(session: "s", payload: payload(["subagent_id": "live", "goal": "B"]),
                      createIfMissing: true, eventType: "subagent.start", now: t0)
        roster.pruneFinished(session: "s")
        XCTAssertEqual(roster.agents(in: "s").map(\.id), ["live"])
        roster.upsert(session: "s", payload: payload(["subagent_id": "done", "goal": "A"]),
                      createIfMissing: true, eventType: "subagent.start", now: t0)
        XCTAssertEqual(roster.agents(in: "s").map(\.id), ["live"], "a retired row can't come back")
        roster.reconcile(session: "s", children: [payload(["subagent_id": "done", "goal": "A"])], now: t0)
        XCTAssertFalse(roster.agents(in: "s").contains { $0.id == "done" }, "nor through a roster")
        roster.clear(session: "s")
        XCTAssertTrue(roster.agents(in: "s").isEmpty)
        XCTAssertNil(roster.retired["s"])
    }

    func testRosterReconcilesWithoutLosingTheStream() {
        var roster = AgentRoster()
        roster.upsert(session: "s", payload: payload(["subagent_id": "a", "goal": "Scan", "text": "working"]),
                      createIfMissing: true, eventType: "subagent.progress", now: t0)
        roster.upsert(session: "s", payload: payload(["subagent_id": "gone", "goal": "Vanished"]),
                      createIfMissing: true, eventType: "subagent.start", now: t0)
        roster.upsert(session: "s", payload: payload(["subagent_id": "fin", "goal": "Done", "status": "completed"]),
                      createIfMissing: true, eventType: "subagent.complete", now: t0)
        let started = t0.addingTimeInterval(-30).timeIntervalSince1970
        roster.reconcile(session: "s", children: [
            payload(["subagent_id": "a", "goal": "Scan", "status": "running", "tool_count": 4, "accepting_steer": true]),
            payload(["subagent_id": "cold", "goal": "Cold", "status": "running", "started_at": .double(started),
                     "last_tool": "read_file"]),
        ], failed: [
            payload(["delegation_id": "d1", "task_index": 0, "status": "failed", "goal": "Broke", "error": "rate limited",
                     "dispatched_at": .double(t0.timeIntervalSince1970 - 20), "completed_at": .double(t0.timeIntervalSince1970 - 5)]),
        ], now: t0)
        let byID = Dictionary(uniqueKeysWithValues: roster.agents(in: "s").map { ($0.id, $0) })
        XCTAssertNil(byID["gone"], "a live row the roster no longer holds goes")
        XCTAssertNotNil(byID["fin"], "a finished row stays")
        XCTAssertEqual(byID["a"]?.stream.map(\.text), ["working"], "the stream history stays")
        XCTAssertEqual(byID["a"]?.toolCount, 4)
        XCTAssertEqual(byID["a"]?.acceptingSteer, true)
        XCTAssertEqual(byID["cold"]?.startedAt, Date(timeIntervalSince1970: started))
        XCTAssertEqual(byID["cold"]?.stream.map(\.text), ["Read File"], "a cold row is seeded with its last tool")
        let failed = byID["delegation:d1:0"]
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.summary, "rate limited")
        XCTAssertEqual(failed?.durationSeconds, 15)
        XCTAssertEqual(failed?.updatedAt, t0.addingTimeInterval(-5))

        roster.reconcile(session: "s", children: [], failed: [
            payload(["delegation_id": "d1", "task_index": 0, "status": "failed", "goal": "Broke"]),
        ], now: t0)
        XCTAssertEqual(roster.agents(in: "s").filter { $0.id == "delegation:d1:0" }.count, 1, "a failed task lands once")
    }

    func testThePanelShowsLiveRowsEverywhereAndFinishedOnesForTheFocus() {
        var roster = AgentRoster()
        for session in ["s1", "s2"] {
            roster.upsert(session: session, payload: payload(["subagent_id": .string("\(session)-live"), "goal": "L"]),
                          createIfMissing: true, eventType: "subagent.start", now: t0)
            roster.upsert(session: session, payload: payload(["subagent_id": .string("\(session)-done"), "goal": "D",
                                                              "status": "completed"]),
                          createIfMissing: true, eventType: "subagent.complete", now: t0)
        }
        XCTAssertEqual(Set(roster.panel(focus: "s1").map(\.id)), ["s1-live", "s1-done", "s2-live"])
        XCTAssertEqual(Set(roster.panel(focus: nil).map(\.id)), ["s1-live", "s2-live"])
        XCTAssertEqual(roster.liveCount, 2)
        XCTAssertEqual(roster.failedCount, 0)
    }

    // MARK: Tree

    private func agent(_ id: String, parent: String? = nil, session: String = "s", started: TimeInterval = 0,
                       delegation: String? = nil, taskCount: Int = 1, taskIndex: Int = 0,
                       status: AgentStatus = .running, tools: Int? = nil, tokens: Int? = nil,
                       files: [String] = []) -> AgentProgress {
        AgentProgress(id: id, ownerSession: session, parentID: parent, goal: id, delegationID: delegation,
                      status: status, taskCount: taskCount, taskIndex: taskIndex,
                      startedAt: t0.addingTimeInterval(started), updatedAt: t0.addingTimeInterval(started),
                      inputTokens: tokens, toolCount: tools, filesRead: files)
    }

    func testTreeNestsChildrenAndSortsByStart() {
        let tree = AgentTree.build([
            agent("late", started: 5),
            agent("child-b", parent: "root", started: 3),
            agent("root", started: 1),
            agent("child-a", parent: "root", started: 2),
            agent("orphan", parent: "missing", started: 4),
            agent("other", session: "s2", started: 0),
        ])
        XCTAssertEqual(tree.map(\.agent.id), ["other", "root", "orphan", "late"])
        XCTAssertEqual(tree[1].children.map(\.agent.id), ["child-a", "child-b"])
        XCTAssertEqual(tree[1].flattened.map(\.id), ["root", "child-a", "child-b"])
        XCTAssertNotEqual(tree[0].id, AgentNode(agent: agent("other")).id, "node ids carry the session")
    }

    func testTreeSurvivesAParentCycle() {
        let tree = AgentTree.build([agent("a", parent: "b"), agent("b", parent: "a")])
        XCTAssertEqual(Set(tree.flatMap(\.flattened).map(\.id)), ["a", "b"], "no row vanishes")
    }

    func testDelegationsGroupByIdThenByShape() {
        let tagged = AgentTree.build([
            agent("w1", started: 0, delegation: "d", taskCount: 2, taskIndex: 0),
            agent("solo", started: 1),
            agent("w2", started: 2, delegation: "d", taskCount: 2, taskIndex: 1, status: .completed),
        ])
        let groups = AgentTree.groups(tagged)
        XCTAssertEqual(groups.map(\.id), ["delegation:d", "s|solo"])
        XCTAssertEqual(groups[0].index, 1)
        XCTAssertEqual(groups[0].nodes.map(\.agent.id), ["w1", "w2"])
        XCTAssertEqual(groups[0].activeWorkers, 1)
        XCTAssertTrue(groups[1].isSingle)

        let untagged = AgentTree.groups(AgentTree.build([
            agent("x0", started: 0, taskCount: 3, taskIndex: 0),
            agent("x1", started: 1, taskCount: 3, taskIndex: 1),
            agent("x2", started: 9, taskCount: 3, taskIndex: 2),
        ]))
        XCTAssertEqual(untagged.map(\.nodes.count), [2, 1], "workers more than 5 s apart start a new fan-out")
        XCTAssertEqual(untagged.map(\.index), [1, 2])
    }

    func testSummaryCountsTheWholeTree() {
        let tree = AgentTree.build([
            agent("a", tools: 3, tokens: 1500, files: ["x", "y"]),
            agent("b", parent: "a", status: .failed, tools: 2, tokens: 600),
            agent("c", status: .completed),
        ])
        let summary = AgentTree.Summary(tree)
        XCTAssertEqual(summary.parts, ["3 agents", "1 active", "1 failed", "5 tools", "2 files", "2.1k tok"])
        XCTAssertEqual(summary.failedPart, "1 failed")
        XCTAssertEqual(AgentTree.Summary(AgentTree.build([agent("one", status: .completed)])).parts, ["1 agent"])
    }

    // MARK: Formats

    func testFormatsMatchTheDesktop() {
        XCTAssertEqual(AgentFormat.compactNumber(950), "950")
        XCTAssertEqual(AgentFormat.compactNumber(999.6), "1k")
        XCTAssertEqual(AgentFormat.compactNumber(1234), "1.2k")
        XCTAssertEqual(AgentFormat.compactNumber(18_000), "18k")
        XCTAssertEqual(AgentFormat.compactNumber(999_950), "1M")
        XCTAssertEqual(AgentFormat.compactNumber(0), "0")
        XCTAssertEqual(AgentFormat.duration(nil), "")
        XCTAssertEqual(AgentFormat.duration(12.34), "12.3s")
        XCTAssertEqual(AgentFormat.duration(247), "4m 7s")
        XCTAssertEqual(AgentFormat.tokens(0), "")
        XCTAssertEqual(AgentFormat.tokens(18_200), "18.2k tok")
        XCTAssertEqual(AgentFormat.age(t0, now: t0.addingTimeInterval(1)), "now")
        XCTAssertEqual(AgentFormat.age(t0, now: t0.addingTimeInterval(42)), "42s ago")
        XCTAssertEqual(AgentFormat.age(t0, now: t0.addingTimeInterval(600)), "10m ago")
        XCTAssertEqual(AgentFormat.age(t0, now: t0.addingTimeInterval(90_000)), "25h ago")
        XCTAssertEqual(AgentRoster.formatTool("read_file"), "Read File")
        XCTAssertEqual(AgentRoster.compact("  a \n b  "), "a b")
        XCTAssertEqual(AgentRoster.compact(String(repeating: "x", count: 300)).count, AgentRoster.previewMax)

        var live = agent("a", tools: 2, tokens: 1200)
        live.model = "m-small"
        XCTAssertEqual(AgentFormat.subtitle(live, now: t0.addingTimeInterval(12)),
                       "m-small · 12.0s · 2 tools · 1.2k tok · updated 12s ago")
    }

    // MARK: Store over the gateway

    private final class FakeChat: AgentsSessionSource {
        var runtimeSessionID: String?
        var storedSessionID: String?
        var sessionTitle = "Chat"
        var sessionProfile: String?

        init(runtime: String?, stored: String?, profile: String?) {
            runtimeSessionID = runtime
            storedSessionID = stored
            sessionProfile = profile
        }
    }

    func testStoreFollowsFramesAndPrunesOnANewTurn() async throws {
        let gateway = ScriptedGateway()
        let connection = gateway.connection()
        let store = AgentsStore(connection: connection, now: { self.t0 })
        try await connection.connect()
        gateway.current.push(event: "subagent.start", session: "rt-1", seq: 1,
                             payload: ["goal": "Scan", "task_count": 1, "task_index": 0, "subagent_id": "sa-1"])
        gateway.current.push(event: "subagent.progress", session: "rt-1", seq: 2,
                             payload: ["goal": "Scan", "task_count": 1, "task_index": 0, "subagent_id": "sa-1",
                                       "text": "reading"])
        // Outside the contract (no task_count): still applied.
        gateway.current.push(event: "subagent.progress", session: "rt-2", seq: 1,
                             payload: ["subagent_id": "sa-2", "goal": "Other", "text": "mid-run"])
        await waitUntil { store.roster.agents(in: "rt-1").first?.stream.count == 1 && store.roster.agents(in: "rt-2").count == 1 }
        XCTAssertEqual(store.roster.agents(in: "rt-2").first?.status, .running, "a mid-run frame creates its row")

        gateway.current.push(event: "subagent.complete", session: "rt-1", seq: 3,
                             payload: ["goal": "Scan", "task_count": 1, "task_index": 0, "subagent_id": "sa-1",
                                       "status": "completed", "summary": "ok"])
        await waitUntil { store.roster.agents(in: "rt-1").first?.status == .completed }
        let chat = FakeChat(runtime: "rt-1", stored: "stored-1", profile: "work")
        store.focus(chat)
        XCTAssertEqual(store.focusSession, "rt-1")
        XCTAssertEqual(Set(store.tree.flatMap(\.flattened).map(\.id)), ["sa-1", "sa-2"])
        XCTAssertEqual(store.parentStoredSession(of: store.roster.agents(in: "rt-1")[0]), "stored-1")
        XCTAssertEqual(store.profile(of: store.roster.agents(in: "rt-1")[0]), "work")

        gateway.current.push(event: "message.start", session: "rt-1", seq: 4)
        await waitUntil { store.roster.agents(in: "rt-1").isEmpty }
        XCTAssertEqual(store.roster.agents(in: "rt-2").count, 1, "other sessions keep their rows")
    }

    func testStoreReadsTheRosterAndSendsControlsThroughTheOwningSession() async throws {
        let gateway = ScriptedGateway()
        gateway.handlers["subagent.list"] = { params in
            params["session_id"]?.stringValue == "rt-1"
                ? .result(["subagents": [["subagent_id": "sa-9", "goal": "Roster", "status": "running",
                                           "started_at": 1_750_000_000, "accepting_steer": true]],
                           "delegations": []])
                : .error(4001, "session not found or not owned by this transport")
        }
        gateway.handlers["subagent.interrupt"] = { params in
            .result(["found": true, "subagent_id": params["subagent_id"] ?? ""])
        }
        gateway.handlers["subagent.steer"] = { params in
            .result(["status": "queued", "subagent_id": params["subagent_id"] ?? "", "text": params["text"] ?? ""])
        }
        gateway.handlers["subagent.tail"] = { params in
            .result(["subagent_id": params["subagent_id"] ?? "", "available": true, "text": "log", "truncated": false])
        }
        let connection = gateway.connection()
        let store = AgentsStore(connection: connection, now: { self.t0 })
        let chat = FakeChat(runtime: "rt-1", stored: "stored-1", profile: "work")
        store.focus(chat)
        await store.refresh()
        let row = try XCTUnwrap(store.roster.agents(in: "rt-1").first)
        XCTAssertEqual(row.id, "sa-9")
        XCTAssertEqual(row.startedAt, Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(gateway.calls("subagent.list").first?.params["profile"]?.stringValue, "work")

        let interrupted = await store.interrupt(row)
        XCTAssertTrue(interrupted)
        XCTAssertEqual(store.notice, "Stop requested")
        let stop = try XCTUnwrap(gateway.calls("subagent.interrupt").first)
        XCTAssertEqual(stop.params["session_id"]?.stringValue, "rt-1")
        XCTAssertEqual(stop.params["subagent_id"]?.stringValue, "sa-9")

        let steered = await store.steer(row, "  focus on tests  ")
        XCTAssertTrue(steered)
        XCTAssertEqual(gateway.calls("subagent.steer").first?.params["text"]?.stringValue, "focus on tests")
        XCTAssertEqual(store.notice, "Queued for the next checkpoint")
        let empty = await store.steer(row, "   ")
        XCTAssertFalse(empty)
        XCTAssertEqual(gateway.calls("subagent.steer").count, 1, "blank steering isn't sent")

        let tail = try await store.tail(row)
        XCTAssertEqual(tail.text, "log")

        // A session whose roster reads keep failing is left alone until refreshed by hand. (The store holds chats
        // weakly, as the app model owns them.)
        let other = FakeChat(runtime: "rt-x", stored: nil, profile: nil)
        store.focus(other)
        for _ in 0..<(AgentsStore.maxFailures + 2) { await store.refresh() }
        let failing = gateway.calls("subagent.list").filter { $0.params["session_id"]?.stringValue == "rt-x" }.count
        XCTAssertEqual(failing, AgentsStore.maxFailures)
        await store.refresh(manual: true)
        XCTAssertEqual(gateway.calls("subagent.list").filter { $0.params["session_id"]?.stringValue == "rt-x" }.count,
                       AgentsStore.maxFailures + 1)
        XCTAssertEqual(store.focusSession, other.runtimeSessionID)
    }

    func testStoreReportsARefusedStop() async throws {
        let gateway = ScriptedGateway()
        gateway.handlers["subagent.interrupt"] = { params in
            .result(["found": false, "subagent_id": params["subagent_id"] ?? ""])
        }
        let store = AgentsStore(connection: gateway.connection(), now: { self.t0 })
        let finished = await store.interrupt(agent("gone"))
        XCTAssertFalse(finished)
        XCTAssertEqual(store.notice, "The subagent did not accept the request")
    }

    // MARK: Session import

    private func row(_ id: String, _ mtime: TimeInterval, source: ForeignSource = .claude, title: String? = nil,
                     cwd: String? = nil, excerpt: String? = nil) -> ForeignSessionRow {
        ForeignSessionRow(id: id, source: source, label: source == .claude ? "Claude Code" : "Codex CLI",
                          title: title ?? id, cwd: cwd, mtime: mtime, turnCount: 4, excerpt: excerpt)
    }

    private final class FakeForeign: ForeignSessionCalls {
        var pages: [String: SessionForeignListResult] = [:]
        var listCalls: [(source: ForeignSource?, offset: Int, profile: String?)] = []
        var previewCalls: [(id: String, profile: String?)] = []
        var importCalls: [(id: String, profile: String?)] = []
        var listError: Error?
        var importError: Error?
        var previewResult = SessionForeignPreviewResult(messages: [ForeignTurn(role: "user", content: "hi")], total: 1,
                                                        truncated: false, alreadyImported: nil, cwd: nil)
        /// Holds the next list answer until released.
        var gate: CheckedContinuation<Void, Never>?
        var holdNext = false

        func foreignList(source: ForeignSource?, offset: Int, profile: String?) async throws -> SessionForeignListResult {
            listCalls.append((source, offset, profile))
            if holdNext {
                holdNext = false
                await withCheckedContinuation { gate = $0 }
            }
            if let listError { throw listError }
            return pages["\(source?.rawValue ?? "all"):\(offset)"]
                ?? SessionForeignListResult(sessions: [], nextOffset: nil, host: "box", unreadable: 0)
        }

        func foreignPreview(id: String, profile: String?) async throws -> SessionForeignPreviewResult {
            previewCalls.append((id, profile))
            return previewResult
        }

        func foreignImport(id: String, profile: String?) async throws -> SessionForeignImportResult {
            importCalls.append((id, profile))
            if let importError { throw importError }
            return SessionForeignImportResult(sessionId: "hermes-\(id)", alreadyImported: false)
        }
    }

    func testImportListPagesMergeAndCountSkippedLogs() async {
        let calls = FakeForeign()
        calls.pages["all:0"] = SessionForeignListResult(sessions: [row("a", 300), row("b", 200)], nextOffset: 25,
                                                        host: "build-box", unreadable: 1)
        calls.pages["all:25"] = SessionForeignListResult(sessions: [row("b", 200, title: "B again"), row("c", 100)],
                                                         nextOffset: nil, host: "build-box", unreadable: 2)
        let store = SessionImportStore(calls: calls, destination: "work")
        XCTAssertEqual(store.phase, .loading)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.host, "build-box")
        XCTAssertTrue(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(store.rows.map(\.id), ["a", "b", "c"], "a row listed twice keeps its place")
        XCTAssertEqual(store.row("b")?.displayTitle, "B again")
        XCTAssertEqual(store.unreadable, 3)
        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(calls.listCalls.map(\.offset), [0, 25])
        XCTAssertEqual(calls.listCalls.first?.profile, "work")
        await store.loadMore()
        XCTAssertEqual(calls.listCalls.count, 2, "nothing more to load")
    }

    func testImportSourceTabsStartOverAndDropStaleAnswers() async {
        let calls = FakeForeign()
        calls.pages["all:0"] = SessionForeignListResult(sessions: [row("a", 3)], nextOffset: nil, host: "box", unreadable: 0)
        calls.pages["codex:0"] = SessionForeignListResult(sessions: [row("x", 2, source: .codex)], nextOffset: nil,
                                                          host: "box", unreadable: 0)
        let store = SessionImportStore(calls: calls, destination: nil)
        calls.holdNext = true
        let first = Task { await store.load() }
        await waitUntil { calls.gate != nil }
        await store.select(.codex)
        calls.gate?.resume()
        await first.value
        XCTAssertEqual(store.source, .codex)
        XCTAssertEqual(store.rows.map(\.id), ["x"], "the earlier source's answer is dropped")
        XCTAssertEqual(calls.listCalls.map(\.source), [nil, .codex])
    }

    func testImportListFailureAndRetry() async {
        let calls = FakeForeign()
        calls.listError = GatewayRPCError(code: -32000, message: "Could not read session folders on this backend")
        let store = SessionImportStore(calls: calls, destination: nil)
        await store.load()
        XCTAssertEqual(store.phase, .failed("Could not read session folders on this backend"))
        calls.listError = nil
        calls.pages["all:0"] = SessionForeignListResult(sessions: [row("a", 1)], nextOffset: nil, host: "", unreadable: nil)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertNil(store.host, "an empty host name reads as unknown")
    }

    func testImportPreviewThenImportIntoTheDestination() async {
        let calls = FakeForeign()
        let store = SessionImportStore(calls: calls, destination: "work")
        await store.loadPreview("a")
        await store.loadPreview("a")
        XCTAssertEqual(calls.previewCalls.count, 1, "a loaded preview is read once")
        XCTAssertEqual(store.previews["a"]?.result?.messages?.first?.content, "hi")

        let result = await store.importSession("a")
        XCTAssertEqual(result?.sessionId, "hermes-a")
        XCTAssertEqual(calls.importCalls.first?.profile, "work")
        XCTAssertNil(store.importing)
        XCTAssertEqual(store.previews["a"]?.result?.alreadyImported, "hermes-a", "the preview now says it is in Hermes")

        store.setDestination("other")
        XCTAssertTrue(store.previews.isEmpty, "a copy in one profile says nothing about another")
        await store.loadPreview("a")
        XCTAssertEqual(calls.previewCalls.last?.profile, "other")
    }

    func testImportFailureIsKeptPerConversation() async {
        let calls = FakeForeign()
        calls.importError = GatewayRPCError(code: -32602, message: "Session no longer available. Refresh the list and try again")
        let store = SessionImportStore(calls: calls, destination: nil)
        let result = await store.importSession("a")
        XCTAssertNil(result)
        XCTAssertEqual(store.importErrors["a"], "Session no longer available. Refresh the list and try again")
        calls.importError = nil
        let again = await store.importSession("a")
        XCTAssertEqual(again?.sessionId, "hermes-a")
        XCTAssertNil(store.importErrors["a"], "a new attempt clears the failure")
    }

    func testImportListSearchAndDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let rows = [
            row("a", 1_750_000_000 + 7200, title: "Fix login", cwd: "/srv/app"),
            row("b", 1_750_000_000, title: "Write docs", excerpt: "README pass"),
            row("c", 1_750_000_000 - 86_400, title: "Old"),
        ]
        let days = SessionImportList.days(rows, calendar: calendar, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(days.map(\.rows.count), [2, 1])
        XCTAssertEqual(days.map(\.title), ["Jun 15", "Jun 14"])
        XCTAssertEqual(SessionImportList.filter(rows, query: "SRV").map(\.id), ["a"], "the folder matches, any case")
        XCTAssertEqual(SessionImportList.filter(rows, query: "readme").map(\.id), ["b"])
        XCTAssertEqual(SessionImportList.filter(rows, query: "").count, 3)
        XCTAssertEqual(rows[1].detail, "README pass", "no folder: the excerpt")
    }

    func testImportCallsGoOverTheGatewayWithTheDesktopsParams() async throws {
        let gateway = ScriptedGateway()
        gateway.handlers["session.foreign.list"] = { _ in
            .result(["sessions": [["id": .string(String(repeating: "a", count: 64)), "source": "codex", "label": "Codex CLI",
                                   "title": "T", "cwd": .null, "mtime": 1_750_000_000.5, "turn_count": 3, "excerpt": "e"]],
                     "next_offset": .null, "host": "box", "unreadable": 0])
        }
        gateway.handlers["session.foreign.import"] = { _ in .result(["session_id": "new-1", "already_imported": true]) }
        let client = gateway.connection().client
        let page = try await client.foreignList(source: nil, offset: 0, profile: nil)
        XCTAssertEqual(page.sessions?.first?.source, .codex)
        XCTAssertEqual(page.sessions?.first?.messages, 3)
        let list = try XCTUnwrap(gateway.calls("session.foreign.list").first)
        XCTAssertNil(list.params["source"], "All sends no source")
        XCTAssertEqual(list.params["offset"]?.intValue, 0)
        _ = try await client.foreignList(source: .claude, offset: 25, profile: "work")
        XCTAssertEqual(gateway.calls("session.foreign.list").last?.params["source"]?.stringValue, "claude")
        XCTAssertEqual(gateway.calls("session.foreign.list").last?.params["profile"]?.stringValue, "work")
        let imported = try await client.foreignImport(id: "h", profile: "work")
        XCTAssertEqual(imported.sessionId, "new-1")
        XCTAssertEqual(gateway.calls("session.foreign.import").first?.params["id"]?.stringValue, "h")
    }
}

/// The star map: the learning graph's decoders and routes, the radial time layout, and the timeline.
@MainActor
final class StarmapTests: XCTestCase {
    private final class Recorder: CapabilitiesTransport {
        var answers: [String: Any] = [:]
        private(set) var calls: [(method: String, path: String, query: [String: String], body: JSON?)] = []

        func request(_ method: String, _ path: String, query: [String: String], body: JSON?) async throws -> Any {
            calls.append((method, path, query, body))
            return answers["\(method) \(path)"] ?? [:]
        }
    }

    private func node(_ id: String, _ timestamp: Double?, kind: LearningNode.Kind = .skill, uses: Int = 0) -> LearningNode {
        LearningNode(id: id, label: id, kind: kind, timestamp: timestamp, category: kind == .memory ? "memory" : "dev",
                     useCount: uses)
    }

    private func json(_ text: String) -> JSON {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSON ?? [:]
    }

    func testGraphDecodesLenientlyAndDropsDanglingLinks() {
        let graph = LearningGraph(response: json("""
        {"nodes": [
           {"id": "git-flow", "label": "git-flow", "kind": "skill", "timestamp": 1750000000.5, "category": "dev",
            "useCount": 4, "state": "active", "createdBy": "agent", "pinned": true},
           {"id": "memory:memory:0:ab", "label": "Prefers short answers", "kind": "memory", "memorySource": "profile",
            "timestamp": null, "category": "memory", "useCount": 0},
           {"label": "no id"}],
         "edges": [{"source": "git-flow", "target": "memory:memory:0:ab"}, {"source": "git-flow", "target": "gone"}],
         "clusters": [{"category": "dev", "count": 1}, {"category": "memory", "count": "1"}]}
        """))
        XCTAssertEqual(graph.nodes.map(\.id), ["git-flow", "memory:memory:0:ab"])
        XCTAssertEqual(graph.edges.count, 1, "a link to a missing node is dropped")
        XCTAssertEqual(graph.clusters.map(\.count), [1, 1])
        let skill = graph.nodes[0]
        XCTAssertTrue(skill.learned)
        XCTAssertEqual(skill.countLabel, "x4")
        XCTAssertEqual(skill.badges(formatter: { _ in "Jun 15" }), ["Jun 15", "dev", "learned", "pinned"])
        let memory = graph.nodes[1]
        XCTAssertNil(memory.timestamp)
        XCTAssertNil(memory.countLabel)
        XCTAssertEqual(memory.badges(), ["unknown", "profile memory"])
        XCTAssertEqual(graph.skillCount, 1)
        XCTAssertEqual(graph.memoryCount, 1)
    }

    func testLearningRoutesScopeToTheProfileAndReportRefusals() async throws {
        let recorder = Recorder()
        recorder.answers["GET /api/learning/node"] = json(##"{"ok": true, "kind": "skill", "label": "git-flow", "content": "# Git"}"##)
        recorder.answers["PUT /api/learning/node"] = json(#"{"ok": true, "message": "updated 'git-flow'"}"#)
        recorder.answers["DELETE /api/learning/node"] = json(#"{"ok": false, "message": "'git-flow' is pinned — unpin it first"}"#)
        let api = LearningAPI(transport: recorder, profile: "work")
        _ = try await api.graph()
        XCTAssertEqual(recorder.calls[0].path, "/api/learning/graph")
        XCTAssertEqual(recorder.calls[0].query, ["profile": "work"])
        let detail = try await api.node("git-flow")
        XCTAssertEqual(detail.content, "# Git")
        XCTAssertEqual(recorder.calls[1].query["id"], "git-flow")
        let saved = try await api.edit("git-flow", content: "# New")
        XCTAssertEqual(saved, "updated 'git-flow'")
        XCTAssertEqual(recorder.calls[2].body?["content"] as? String, "# New")
        do {
            try await api.delete("git-flow")
            XCTFail("a refusal throws")
        } catch {
            XCTAssertEqual(error.localizedDescription, "'git-flow' is pinned — unpin it first")
        }
        XCTAssertEqual(recorder.calls[3].body?["id"] as? String, "git-flow")
    }

    func testRecencyIsLinearInTimeAndOrdinalWhenUndated() {
        let timed = StarmapLayout.recency([node("a", 100), node("b", 200), node("c", 150)])
        XCTAssertEqual(timed.rec["a"], StarmapLayout.leadIn)
        XCTAssertEqual(timed.rec["b"]!, 1, accuracy: 1e-9)
        XCTAssertEqual(timed.rec["c"]!, StarmapLayout.recForRatio(0.5), accuracy: 1e-9)
        let undated = StarmapLayout.recency([node("y", nil), node("x", nil)])
        XCTAssertEqual(undated.rec["x"], StarmapLayout.leadIn, "undated nodes fall back to their order")
        XCTAssertEqual(undated.rec["y"]!, 1, accuracy: 1e-9)
    }

    func testCalendarBucketsAndUnits() {
        let march3 = 1_772_496_000.0 // 2026-03-03T00:00:00Z
        XCTAssertEqual(StarmapLayout.bucketStart(march3 + 3600, .init(kind: .day, step: 1)), march3)
        let quarter = StarmapLayout.bucketStart(march3, .init(kind: .month, step: 3))
        XCTAssertEqual(quarter, 1_767_225_600, "a 3-month step starts in January")
        let day = StarmapLayout.day
        let daily = (0..<6).map { march3 + Double($0) * day }
        XCTAssertEqual(StarmapLayout.chooseUnit(daily, spanDays: 5), .init(kind: .day, step: 2),
                       "six days: two-day rings, nearest the floor of five")
        let yearly = (0..<24).map { march3 + Double($0) * 30 * day }
        XCTAssertEqual(StarmapLayout.chooseUnit(yearly, spanDays: 690).kind, .month)
    }

    func testLayoutPlacesNodesInTheirRingsAndRevealsInOrder() {
        let day = StarmapLayout.day
        let base = 1_772_496_000.0
        var nodes = (0..<30).map { node("s\($0)", base + Double($0 % 6) * day, uses: $0) }
        nodes.append(node("m", base + 5 * day, kind: .memory))
        let graph = LearningGraph(nodes: nodes, edges: [.init(source: "s0", target: "s1")])
        let layout = StarmapLayout(graph: graph, labels: { _, _ in "label" })
        XCTAssertEqual(layout.rings.count, 4, "six days in two-day rings")
        XCTAssertEqual(layout.rings.last!.ratio, 1, accuracy: 1e-9)
        XCTAssertTrue(layout.timed)
        for star in layout.stars {
            let distance = hypot(star.x, star.y)
            let outer = layout.rings[star.ring].radius
            XCTAssertLessThanOrEqual(distance, outer + 12, "\(star.id) stays near its ring")
            XCTAssertGreaterThan(star.reveal, 0)
            XCTAssertLessThanOrEqual(star.reveal, 1)
        }
        let oldest = layout.stars.filter { $0.ring == 0 }.map(\.reveal).max()!
        let newest = layout.stars.filter { $0.ring == 3 }.map(\.reveal).min()!
        XCTAssertLessThan(oldest, newest, "older rings light first")
        XCTAssertEqual(layout.visibleStars(1).count, 31)
        XCTAssertLessThan(layout.visibleStars(0.3).count, 31)
        XCTAssertEqual(layout.visibleRings(0).count, 1, "the core ring always shows")
        XCTAssertEqual(layout.buckets.reduce(0) { $0 + $1.total }, 31)
        XCTAssertEqual(layout.buckets.reduce(0) { $0 + $1.memories }, 1)
        XCTAssertEqual(layout.neighbors(of: "s0"), ["s1"])
        // Nodes in one band don't pile up.
        let crowded = layout.stars.filter { $0.ring == 0 }
        for (i, a) in crowded.enumerated() {
            for b in crowded.dropFirst(i + 1) {
                XCTAssertGreaterThan(hypot(a.x - b.x, a.y - b.y), (a.radius + b.radius) * 0.8, "\(a.id) and \(b.id) overlap")
            }
        }
        let target = layout.stars[3]
        XCTAssertEqual(layout.star(at: target.x + 1, target.y, slop: 2)?.id, target.id)
        XCTAssertNil(layout.star(at: 10_000, 10_000, slop: 2))
        XCTAssertEqual(layout.revealLabel(0), LearningGraph.formatDate(base))
    }

    func testUndatedGraphUsesEvenRings() {
        let layout = StarmapLayout(graph: LearningGraph(nodes: [node("a", nil), node("b", nil), node("c", nil)]))
        XCTAssertEqual(layout.rings.count, StarmapLayout.ringSteps + 1)
        XCTAssertNil(layout.rings[0].label)
        XCTAssertFalse(layout.timed)
        XCTAssertEqual(layout.revealLabel(1), "3 / 3")
    }

    func testGlyphSizesInkAndHash() {
        XCTAssertEqual(StarmapLayout.hash(""), 2_166_136_261)
        XCTAssertEqual(StarmapLayout.hash("a"), 0xE40C_292C)
        XCTAssertEqual(StarmapLayout.nodeRadius(node("m", nil, kind: .memory)), 4.4)
        XCTAssertEqual(StarmapLayout.nodeRadius(node("s", nil, uses: 4)), 3 + 2 * 0.55, accuracy: 1e-9)
        XCTAssertEqual(StarmapLayout.recencyInk(0), 0.42, accuracy: 1e-9)
        XCTAssertEqual(StarmapLayout.recencyInk(1), 0.95, accuracy: 1e-9)
        XCTAssertEqual(StarmapStore.ease(0), 0)
        XCTAssertEqual(StarmapStore.ease(1), 1)
        XCTAssertEqual(StarmapStore.invEase(StarmapStore.ease(0.3)), 0.3, accuracy: 1e-5)
    }

    func testStoreLoadsAndRemovesANodeOptimistically() async {
        let recorder = Recorder()
        recorder.answers["GET /api/learning/graph"] = json("""
        {"nodes": [{"id": "a", "kind": "skill", "timestamp": 100}, {"id": "b", "kind": "memory", "timestamp": 200}],
         "edges": [{"source": "a", "target": "b"}]}
        """)
        recorder.answers["DELETE /api/learning/node"] = json(#"{"ok": false, "message": "stale id"}"#)
        let store = StarmapStore(transport: recorder, profile: nil)
        await store.load()
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.layout.stars.count, 2)
        store.selected = "b"
        let star = store.selectedStar!
        await store.remove(star)
        XCTAssertEqual(store.graph.nodes.count, 2, "a refused delete puts the node back")
        XCTAssertEqual(store.notice, "stale id")
        recorder.answers["DELETE /api/learning/node"] = json(#"{"ok": true, "message": "deleted"}"#)
        recorder.answers["GET /api/learning/graph"] = json(#"{"nodes": [{"id": "a", "kind": "skill", "timestamp": 100}]}"#)
        await store.remove(star)
        XCTAssertEqual(store.graph.nodes.map(\.id), ["a"])
        XCTAssertNil(store.selected)
    }
}
