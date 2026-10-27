import XCTest
@testable import HermesVoice

/// Records the kanban plugin calls and answers them from canned responses.
private final class RecordingKanbanTransport: KanbanTransport {
    struct Call {
        let method: String
        let path: String
        let query: [String: String]
        let body: JSON?
        var timeout: TimeInterval?
    }

    struct Upload {
        let path: String
        let query: [String: String]
        let filename: String
        let contentType: String?
        let data: Data
        let fields: [String: String]
    }

    private(set) var calls: [Call] = []
    private(set) var uploads: [Upload] = []
    /// `"METHOD path"` → the answer.
    var responses: [String: Any] = [:]
    /// `"METHOD path"` → the error that call throws.
    var failures: [String: Error] = [:]

    func request(_ method: String, _ path: String, query: [String: String], body: JSON?) async throws -> Any {
        try answer(Call(method: method, path: path, query: query, body: body))
    }

    func request(_ method: String, _ path: String, query: [String: String], body: JSON?,
                 timeout: TimeInterval) async throws -> Any {
        try answer(Call(method: method, path: path, query: query, body: body, timeout: timeout))
    }

    func kanbanUpload(_ path: String, query: [String: String], filename: String, contentType: String?,
                      data: Data, fields: [String: String]) async throws -> Any {
        uploads.append(Upload(path: path, query: query, filename: filename, contentType: contentType, data: data, fields: fields))
        return ["attachment": ["id": 9, "filename": filename, "size": data.count]]
    }

    func kanbanDownload(_ path: String, query: [String: String]) async throws -> Data {
        calls.append(Call(method: "GET", path: path, query: query, body: nil))
        return Data("bytes".utf8)
    }

    private func answer(_ call: Call) throws -> Any {
        calls.append(call)
        let key = "\(call.method) \(call.path)"
        if let failure = failures[key] { throw failure }
        return responses[key] ?? JSON()
    }

    func recorded(_ method: String, _ path: String) -> [Call] {
        calls.filter { $0.method == method && $0.path == path }
    }
}

final class KanbanTests: XCTestCase {
    private let root = KanbanAPI.root

    private func any(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// A body as canonical JSON, so dictionaries compare whole.
    private func canonical(_ body: JSON?) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body ?? [:], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func board(_ columns: [(String, [String])], latest: Int = 10, archived: Bool = false) -> KanbanBoard {
        var all = columns.map { name, ids in KanbanColumn(name: name, tasks: ids.map { KanbanTask(id: $0, title: $0, status: name) }) }
        if archived { all.append(KanbanColumn(name: "archived", tasks: [])) }
        return KanbanBoard(columns: all, latestEventID: latest)
    }

    private func ids(_ board: KanbanBoard, _ column: String) -> [String] {
        board.columns.first { $0.name == column }?.tasks.map(\.id) ?? []
    }

    // MARK: Decoding

    func testBoardDecodesLeniently() throws {
        let board = KanbanBoard(response: try any("""
        {"columns": [
           {"name": "triage", "tasks": [
              {"id": "t_a1b2c3d4", "title": "Spec it", "status": "triage", "priority": "3", "assignee": "",
               "tenant": "acme", "created_at": 1700000000, "comment_count": 2,
               "link_counts": {"parents": 1, "children": 2}, "progress": {"done": 1, "total": 2},
               "warnings": {"count": 2, "kinds": {"stale": 2}, "latest_at": 5, "highest_severity": "error"},
               "diagnostics": [{"kind": "stale", "severity": "error", "title": "Stale", "detail": "d", "count": 2,
                                "actions": [{"kind": "reclaim", "label": "Reclaim", "suggested": true}, {"label": "no kind"}],
                                "data": {"ids": ["t_x"]}}],
               "future_field": {"x": 1}},
              {"id": "t_a1b2c3d4", "title": "duplicate"},
              {"title": "no id"},
              "not a row"]},
           {"name": "ready", "tasks": [{"id": "t_r", "status": "running", "goal_mode": true, "skills": ["git", 3, ""],
                                        "progress": {"done": 0, "total": 0}, "warnings": {"count": 0}}]},
           {"name": "ready", "tasks": []},
           {"tasks": []},
           {"name": "done"}],
         "tenants": ["acme", "", 4], "assignees": ["coder"], "latest_event_id": "41", "now": 1700000100}
        """))
        XCTAssertEqual(board.columns.map(\.name), ["triage", "ready", "done"], "duplicate and unnamed columns are dropped")
        XCTAssertEqual(board.tenants, ["acme"])
        XCTAssertEqual(board.assignees, ["coder"])
        XCTAssertEqual(board.latestEventID, 41)
        XCTAssertEqual(board.total, 2)

        let task = try XCTUnwrap(board.task("t_a1b2c3d4"))
        XCTAssertEqual(task.title, "Spec it")
        XCTAssertEqual(task.priority, 3)
        XCTAssertNil(task.assignee, "a blank assignee is none")
        XCTAssertEqual(task.tenant, "acme")
        XCTAssertEqual(task.commentCount, 2)
        XCTAssertEqual(task.linkCount, 3)
        XCTAssertEqual(task.progress?.done, 1)
        XCTAssertEqual(task.progress?.total, 2)
        XCTAssertEqual(task.warnings?.count, 2)
        XCTAssertEqual(task.warnings?.highestSeverity, "error")
        XCTAssertEqual(task.diagnostics.count, 1)
        XCTAssertEqual(task.diagnostics[0].actions.map(\.kind), ["reclaim"])
        XCTAssertTrue(task.diagnostics[0].actions[0].suggested)
        XCTAssertEqual(task.diagnostics[0].data["ids"], ["t_x"])
        XCTAssertEqual(task.shortID, "a1b2c3")

        let running = try XCTUnwrap(board.task("t_r"))
        XCTAssertEqual(running.status, "ready", "a card's column is the one it was listed in")
        XCTAssertTrue(running.goalMode)
        XCTAssertEqual(running.skills, ["git"])
        XCTAssertNil(running.progress, "no children: no progress")
        XCTAssertNil(running.warnings, "a zero count is no warning")

        let empty = KanbanBoard(response: try any(#"{"detail": "nope"}"#))
        XCTAssertEqual(empty.columns, [])
        XCTAssertEqual(empty.latestEventID, 0)
    }

    func testTaskDetailDecodesLeniently() throws {
        let detail = try XCTUnwrap(KanbanTaskDetail(response: try any("""
        {"task": {"id": "t_1", "title": "Ship", "status": "running", "body": "**Goal**", "worker_pid": 42,
                  "model_override": "gpt-x", "provider_override": "openai", "reasoning_effort": "", "block_kind": "needs_input",
                  "block_recurrences": 2, "consecutive_failures": "1", "current_run_started_at": 1700000050,
                  "workspace_kind": "worktree", "workspace_path": "/srv/repo", "branch_name": "hermes/t_1"},
         "comments": [{"id": 1, "author": "mobile", "body": "hi", "created_at": 1700000001}, {"id": 2}, {"body": "anon"}],
         "events": [{"id": 3, "task_id": "t_1", "kind": "status", "payload": {"status": "ready"}, "created_at": 1},
                    {"id": 4, "task_id": "t_1", "kind": "edited", "payload": "{\\"fields\\": [\\"title\\"]}"},
                    {"id": 5, "kind": "weird", "payload": "not json"},
                    {"kind": "no id"}],
         "attachments": [{"id": 7, "filename": "a.png", "size": 12, "content_type": "image/png"}, {"filename": "no id"}],
         "links": {"parents": ["t_p"], "children": ["t_c", ""]},
         "link_tasks": [{"id": "t_p", "title": "Parent", "status": "done"}],
         "runs": [{"id": 9, "profile": "coder", "status": "running", "started_at": 10},
                  {"id": 8, "status": "ended", "outcome": "crashed", "started_at": 1, "ended_at": 5, "error": "boom"}]}
        """)))
        XCTAssertEqual(detail.task.status, "running")
        XCTAssertEqual(detail.task.workerPID, 42)
        XCTAssertEqual(detail.task.consecutiveFailures, 1)
        XCTAssertNil(detail.task.reasoningEffort)
        XCTAssertEqual(KanbanModelOverride(task: detail.task), KanbanModelOverride(effort: "", model: "gpt-x", provider: "openai"))
        XCTAssertEqual(detail.comments.map(\.body), ["hi", "anon"])
        XCTAssertEqual(detail.comments[1].author, "someone")
        XCTAssertEqual(detail.events.map(\.id), [3, 4, 5])
        XCTAssertEqual(detail.events[0].string("status"), "ready")
        XCTAssertEqual(detail.events[1].payload["fields"], ["title"], "a payload sent as JSON text is read")
        XCTAssertEqual(detail.events[2].rawPayload, "not json")
        XCTAssertEqual(detail.attachments?.map(\.id), [7])
        XCTAssertEqual(detail.parents, ["t_p"])
        XCTAssertEqual(detail.children, ["t_c"])
        XCTAssertEqual(detail.linkTitle("t_p"), "Parent")
        XCTAssertEqual(detail.linkTitle("t_c"), "c", "an unresolved link falls back to its short id")
        XCTAssertEqual(detail.runs.map(\.id), [9, 8])
        XCTAssertTrue(detail.runs[0].isActive)
        XCTAssertTrue(detail.runs[1].failed)
        XCTAssertEqual(KanbanFormat.duration(detail.runs[1].startedAt, detail.runs[1].endedAt), "4s")

        let old = try XCTUnwrap(KanbanTaskDetail(response: try any(#"{"task": {"id": "t_2"}, "comments": "x"}"#)))
        XCTAssertNil(old.attachments, "hosts before attachments omit the key: the section hides")
        XCTAssertEqual(old.task.status, "todo")
        XCTAssertNil(KanbanTaskDetail(response: try any(#"{"comments": []}"#)), "no task, no detail")
    }

    func testSmallShapesDecodeLeniently() throws {
        let boards = KanbanBoardList(response: try any("""
        {"boards": [{"slug": "default", "name": "Default", "total": 3, "counts": {"todo": 3},
                     "default_workspace_kind": "scratch"},
                    {"slug": "ops", "is_current": true, "project_id": "p1", "project_name": "Ops repo"},
                    {"slug": "ops"}, {"name": "no slug"}]}
        """))
        XCTAssertEqual(boards.boards.map(\.slug), ["default", "ops"])
        XCTAssertEqual(boards.current, "ops", "without `current`, the flagged board")
        XCTAssertEqual(boards.boards[1].name, "ops")
        XCTAssertEqual(boards.board("default")?.total, 3)
        XCTAssertEqual(KanbanBoardList(response: JSON()).current, "default")

        let orchestration = KanbanOrchestration(response: try any(#"{"orchestrator_profile": "", "default_assignee": "coder", "resolved_orchestrator_profile": "default"}"#))
        XCTAssertEqual(orchestration.defaultAssignee, "coder")
        XCTAssertEqual(orchestration.resolvedDefaultAssignee, "coder", "unresolved falls back to the explicit value")
        XCTAssertTrue(orchestration.autoDecompose, "auto-decompose defaults on")

        let config = KanbanConfig(response: try any(#"{"lane_by_profile": "yes", "default_tenant": ""}"#))
        XCTAssertTrue(config.laneByProfile, "a string isn't a boolean: the default holds")
        XCTAssertNil(config.defaultTenant)

        let estimate = KanbanEstimate(response: try any(#"{"ok": true, "est_tokens": "12000", "complexity": "m", "rationale": "multi-file"}"#))
        XCTAssertEqual(estimate.estTokens, 12000)
        XCTAssertEqual(estimate.complexityLabel, "Medium")
        XCTAssertNil(KanbanEstimate(response: try any(#"{"ok": true, "complexity": "XL"}"#)).complexity)

        let outcome = KanbanAuxOutcome(response: try any(#"{"ok": true, "fanout": true, "child_ids": ["t_a", "t_b"], "new_title": "Better"}"#))
        XCTAssertEqual(outcome.childIDs, ["t_a", "t_b"])
        XCTAssertTrue(outcome.fanout)

        let results = KanbanBulkResult.list(try any(#"{"results": [{"id": "t_a", "ok": true}, {"id": "t_b", "ok": false, "error": "refused"}, {"ok": true}]}"#))
        XCTAssertEqual(results, [KanbanBulkResult(id: "t_a", ok: true, error: nil), KanbanBulkResult(id: "t_b", ok: false, error: "refused")])

        let channels = (try any(#"{"home_channels": [{"platform": "telegram", "chat_id": 123, "name": "Me", "subscribed": true}, {"chat_id": "x"}]}"#) as? JSON)?["home_channels"] as? [Any] ?? []
        let homes = channels.compactMap(KanbanHomeChannel.init)
        XCTAssertEqual(homes.count, 1)
        XCTAssertEqual(homes[0].chatID, "123")
        XCTAssertTrue(homes[0].subscribed)

        let providers = (try any(#"[{"slug": "openai", "models": ["gpt-x"]}, {"slug": "empty", "models": []}, {"models": ["m"]}]"#) as? [Any] ?? [])
            .compactMap(KanbanModelProvider.init)
        XCTAssertEqual(providers.map(\.slug), ["openai"])
        XCTAssertEqual(providers[0].label, "openai")

        let workers = KanbanActiveWorker.list(try any(#"{"workers": [{"run_id": 4, "task_id": "t_a", "task_title": "A", "worker_pid": 99}, {"task_id": "t_b"}]}"#))
        XCTAssertEqual(workers.map(\.runID), [4])
        let inspect = KanbanRunInspect(response: try any(#"{"alive": false, "reason": "process not found", "pid": 99}"#))
        XCTAssertFalse(inspect.alive)
        XCTAssertEqual(inspect.reason, "process not found")

        let stats = KanbanStats(response: try any(#"{"by_status": {"ready": 2}, "by_assignee": {"coder": {"running": 1}}, "oldest_ready_age_seconds": 90}"#))
        XCTAssertEqual(stats.byStatus["ready"], 2)
        XCTAssertEqual(stats.byAssignee["coder"]?["running"], 1)

        let profiles = KanbanProfile.list(try any(#"{"profiles": [{"name": "default", "is_default": true}, {"name": "default"}, {"description": "x"}]}"#))
        XCTAssertEqual(profiles.map(\.name), ["default"])

        let frame = try XCTUnwrap(KanbanEventFrame(text: #"{"events": [{"id": 12, "task_id": "t_a", "kind": "commented"}, {"id": 11, "task_id": "t_a", "kind": "assigned", "payload": {"assignee": null}}]}"#))
        XCTAssertEqual(frame.events.map(\.id), [11, 12], "a frame's events apply in id order")
        XCTAssertEqual(frame.cursor, 12, "without a cursor, the last event's id")
        XCTAssertNil(KanbanEventFrame(text: "ping"))
    }

    func testWorkflowDecodesAndGatesMoves() throws {
        let served = KanbanWorkflow(response: try any("""
        {"columns": [{"key": "triage", "label": "Triage"}, {"key": "todo"}, {"key": "running", "drag_target": false},
                     {"key": "done", "label": "Done", "drag_target": true}, {"label": "no key"}],
         "manual": {"triage": ["todo"], "todo": ["triage", "done"], "archived": ["triage"]}, "archived": "archived"}
        """))
        XCTAssertEqual(served.columns.map(\.key), ["triage", "todo", "running", "done"])
        XCTAssertEqual(served.columns[1].label, "Todo")
        XCTAssertEqual(served.targets(from: "triage"), ["todo"])
        XCTAssertEqual(served.targets(from: "todo"), ["triage", "done"])
        XCTAssertTrue(served.canMove(from: "done", to: "archived"), "archiving is always allowed")
        XCTAssertFalse(served.canMove(from: "todo", to: "running"), "a locked column is never a target")
        XCTAssertFalse(served.canMove(from: "todo", to: "todo"))
        XCTAssertEqual(served.targets(from: "archived"), ["triage"], "archived is a restore source")

        XCTAssertEqual(KanbanWorkflow(response: try any(#"{"detail": "Not Found"}"#)), .standard, "hosts before the route get today's board")
        let standard = KanbanWorkflow.standard
        XCTAssertEqual(standard.columns.map(\.key), KanbanColumns.order)
        XCTAssertEqual(standard.targets(from: "ready"), ["triage", "todo", "blocked", "done"],
                       "review and scheduled are locked even where the matrix lists them")
        XCTAssertFalse(standard.isDropTarget("running"))
        XCTAssertTrue(standard.isDropTarget("archived"))
    }

    // MARK: Request bodies

    func testTaskPatchBodies() throws {
        XCTAssertEqual(try canonical(KanbanTaskPatch.move(to: "ready").json), #"{"status":"ready"}"#)
        XCTAssertEqual(try canonical(KanbanTaskPatch.move(to: "done", summary: "  Shipped it \n").json),
                       #"{"result":"Shipped it","status":"done","summary":"Shipped it"}"#)
        XCTAssertEqual(try canonical(KanbanTaskPatch.move(to: "done", summary: "   ").json), #"{"status":"done"}"#,
                       "a blank summary isn't evidence")
        XCTAssertEqual(try canonical(KanbanTaskPatch(assignee: "").json), #"{"assignee":""}"#, "an empty assignee unassigns")
        XCTAssertEqual(try canonical(KanbanTaskPatch(modelOverride: .inherit).json),
                       #"{"clear_model_override":true,"clear_reasoning_effort":true}"#, "inherit clears explicitly")
        XCTAssertEqual(try canonical(KanbanTaskPatch(modelOverride: KanbanModelOverride(effort: "none", model: " gpt-x ", provider: "openai")).json),
                       #"{"model_override":"gpt-x","provider_override":"openai","reasoning_effort":"none"}"#)
        XCTAssertEqual(try canonical(KanbanModelOverride(effort: "high", model: "", provider: "x").createFields),
                       #"{"reasoning_effort":"high"}"#, "create omits instead of clearing; no provider without a model")
        XCTAssertEqual(KanbanModelOverride(effort: "xhigh", model: "m", provider: "p").label(inherit: "Profile default"), "p: m · Extra high")
        XCTAssertEqual(KanbanModelOverride.inherit.label(inherit: "Profile default"), "Profile default")
    }

    func testBulkBodies() throws {
        XCTAssertEqual(try canonical(KanbanBulkPatch.move(to: "todo").json(ids: ["t_a", "t_b"])),
                       #"{"ids":["t_a","t_b"],"status":"todo"}"#)
        XCTAssertEqual(try canonical(KanbanBulkPatch.move(to: "done", summary: "done all").json(ids: ["t_a"])),
                       #"{"ids":["t_a"],"result":"done all","status":"done","summary":"done all"}"#)
        XCTAssertEqual(try canonical(KanbanBulkPatch.assign(nil).json(ids: ["t_a"])),
                       #"{"assignee":"","ids":["t_a"],"reclaim_first":true}"#, "unassign is an empty assignee, reclaiming first")
        XCTAssertEqual(try canonical(KanbanBulkPatch.assign("coder").json(ids: ["t_a"])),
                       #"{"assignee":"coder","ids":["t_a"],"reclaim_first":true}"#)
        XCTAssertEqual(try canonical(KanbanBulkPatch.archiveAll.json(ids: ["t_a"])), #"{"archive":true,"ids":["t_a"]}"#)
    }

    func testNewTaskAndBoardBodies() throws {
        var draft = KanbanNewTask(title: "  Write docs  ")
        draft.body = "   "
        draft.assignee = "coder"
        draft.priority = 2
        draft.workspaceKind = "scratch"
        draft.workspacePath = "/ignored"
        draft.parents = ["t_p"]
        draft.triage = true
        draft.skills = KanbanNewTask.skills(from: " git, ,docs ,")
        draft.modelOverride = KanbanModelOverride(effort: "low", model: "m", provider: "p")
        XCTAssertEqual(try canonical(draft.json),
                       #"{"assignee":"coder","goal_mode":false,"model_override":"m","parents":["t_p"],"priority":2,"provider_override":"p","reasoning_effort":"low","skills":["git","docs"],"title":"Write docs","triage":true,"workspace_kind":"scratch"}"#)
        var worktree = KanbanNewTask(title: "x")
        worktree.workspaceKind = "worktree"
        worktree.workspacePath = " /srv/repo "
        XCTAssertEqual(worktree.json["workspace_path"] as? String, "/srv/repo")
        XCTAssertNil(KanbanNewTask(title: "x").json["assignee"], "parked: no assignee sent")

        XCTAssertEqual(KanbanNewBoard.slug(for: "  ATM10 Server!! v2 "), "atm10-server-v2")
        XCTAssertEqual(KanbanNewBoard.slug(for: "--__--"), "")
        XCTAssertEqual(try canonical(KanbanNewBoard(name: "Ops Board", projectID: "p1", switchTo: false).json),
                       #"{"name":"Ops Board","project_id":"p1","slug":"ops-board"}"#)
    }

    func testRoutesNameTheirBoard() async throws {
        let transport = RecordingKanbanTransport()
        let api = KanbanAPI(transport: transport, board: "ops")
        transport.responses["PATCH \(root)/tasks/t_a"] = ["task": ["id": "t_a", "status": "ready"]]
        let moved = try await api.patchTask("t_a", .move(to: "ready"))
        XCTAssertEqual(moved?.status, "ready")
        XCTAssertEqual(transport.calls.last?.query, ["board": "ops"])

        _ = try await api.boardSnapshot(includeArchived: true, tenant: "acme")
        XCTAssertEqual(transport.calls.last?.path, "\(root)/board")
        XCTAssertEqual(transport.calls.last?.query, ["board": "ops", "include_archived": "true", "tenant": "acme"])

        try await api.removeLink(parent: "t_p", child: "t_c")
        XCTAssertEqual(transport.calls.last?.method, "DELETE")
        XCTAssertEqual(transport.calls.last?.query, ["board": "ops", "parent_id": "t_p", "child_id": "t_c"])
        XCTAssertNil(transport.calls.last?.body)

        try await api.setHomeSubscription(task: "t_a", platform: "telegram", subscribed: false)
        XCTAssertEqual(transport.calls.last?.method, "DELETE")
        XCTAssertEqual(transport.calls.last?.path, "\(root)/tasks/t_a/home-subscribe/telegram")

        _ = try await api.makeCurrent("ops")
        XCTAssertEqual(transport.calls.last?.path, "\(root)/boards/ops/switch")
        XCTAssertEqual(transport.calls.last?.query, [:])

        try await api.reassign("t_a", profile: nil)
        XCTAssertEqual(try canonical(transport.calls.last?.body), #"{"profile":"","reclaim_first":true}"#)

        _ = try await api.specify("t_a")
        XCTAssertEqual(transport.calls.last?.timeout, KanbanAPI.modelTimeout, "auxiliary-model routes wait longer")

        _ = try await api.log("t_a")
        XCTAssertEqual(transport.calls.last?.query, ["board": "ops", "tail": "16384"])

        let attachment = try await api.uploadAttachment(task: "t_a", filename: "a.txt", contentType: "text/plain", data: Data("hi".utf8))
        XCTAssertEqual(attachment?.id, 9)
        XCTAssertEqual(transport.uploads.last?.path, "\(root)/tasks/t_a/attachments")
        XCTAssertEqual(transport.uploads.last?.fields, ["uploaded_by": "mobile"])

        let unpinned = api.on(board: nil)
        _ = try await unpinned.boards()
        XCTAssertEqual(transport.calls.last?.query, [:], "the board list is not board-scoped")
        try await unpinned.deleteTask("t_z")
        XCTAssertEqual(transport.calls.last?.query, [:], "no board picked: the host's current one")

        do {
            try await api.deleteTask("../config")
            XCTFail("a path can't escape its route")
        } catch {}

        XCTAssertEqual(KanbanAPI.eventsQuery(board: "ops", since: 41, ticket: "tk"), ["board": "ops", "since": "41", "ticket": "tk"])
        XCTAssertEqual(KanbanAPI.eventsQuery(board: nil, since: nil, ticket: "tk"), ["ticket": "tk"],
                       "no cursor: the host starts at the tail instead of replaying history")
    }

    func testMultipartBody() {
        let body = String(decoding: KanbanMultipart.body(boundary: "B", filename: "a\"b.txt", contentType: nil,
                                                         data: Data("hi".utf8), fields: ["uploaded_by": "mobile"]), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"uploaded_by\"\r\n\r\nmobile\r\n"))
        XCTAssertTrue(body.contains("filename=\"a%22b.txt\""), "a quote can't end the filename early")
        XCTAssertTrue(body.contains("Content-Type: application/octet-stream\r\n\r\nhi\r\n--B--"))
    }

    // MARK: Board edits and live events

    func testOptimisticMovesAndFilters() {
        let start = board([("triage", ["a"]), ("ready", ["b", "c"]), ("done", [])])
        let moved = start.moving("c", to: "triage")
        XCTAssertEqual(ids(moved, "triage"), ["c", "a"], "a moved card lands on top")
        XCTAssertEqual(moved.task("c")?.status, "triage")
        XCTAssertEqual(start.moving("zz", to: "done"), start, "an unknown card changes nothing")
        let all = start.movingAll(["a", "b"], to: "done")
        XCTAssertEqual(ids(all, "done"), ["a", "b"])
        XCTAssertEqual(ids(start.moving("a", to: "archived"), "triage"), [], "a column the board doesn't show drops the card")
        XCTAssertEqual(start.removing(["b"]).total, 2)

        var tagged = start
        tagged.columns[1].tasks[0].tenant = "acme"
        tagged.columns[1].tasks[1].assignee = "coder"
        XCTAssertEqual(tagged.filtered(search: "", tenant: "acme", assignee: "").total, 1)
        XCTAssertEqual(tagged.filtered(search: "", tenant: "", assignee: "coder").allTasks.map(\.id), ["c"])
        XCTAssertEqual(tagged.filtered(search: " B ", tenant: "", assignee: "").allTasks.map(\.id), ["b"], "search matches title and id")
        XCTAssertEqual(tagged.filtered(search: "x", tenant: "", assignee: "").columns.count, 3, "every column stays")

        var lanes = [KanbanTask(id: "1", status: "running", assignee: "zed"), KanbanTask(id: "2", status: "running"),
                     KanbanTask(id: "3", status: "running", assignee: "amy")]
        lanes.append(KanbanTask(id: "4", status: "running", assignee: "zed"))
        XCTAssertEqual(KanbanBoard.lanes(lanes).map(\.assignee), ["amy", "unassigned", "zed"])
        XCTAssertEqual(KanbanBoard.lanes(lanes).last?.tasks.map(\.id), ["1", "4"])
    }

    func testEventsApplyToTheBoard() {
        var live = board([("todo", ["a", "b"]), ("ready", []), ("running", []), ("done", [])], latest: 10)
        let effect = live.apply([
            KanbanEvent(id: 12, taskID: "a", kind: "status", payload: ["status": "ready"]),
            KanbanEvent(id: 11, taskID: "b", kind: "assigned", payload: ["assignee": "coder"]),
            KanbanEvent(id: 13, taskID: "b", kind: "commented", payload: ["author": "x"]),
            KanbanEvent(id: 14, taskID: "b", kind: "reprioritized", payload: ["priority": 4]),
            KanbanEvent(id: 15, taskID: "b", kind: "claimed"),
            KanbanEvent(id: 9, taskID: "a", kind: "status", payload: ["status": "done"]),
        ])
        XCTAssertEqual(live.latestEventID, 15, "the tail advances to the newest event")
        XCTAssertEqual(effect.applied, 5, "events already in the snapshot change nothing")
        XCTAssertEqual(effect.touched, ["a", "b"])
        XCTAssertTrue(effect.needsReload)
        XCTAssertEqual(ids(live, "ready"), ["a"])
        let b = live.task("b")
        XCTAssertEqual(b?.status, "running")
        XCTAssertEqual(b?.assignee, "coder")
        XCTAssertEqual(b?.commentCount, 1)
        XCTAssertEqual(b?.priority, 4)

        let replay = live.apply([KanbanEvent(id: 15, taskID: "b", kind: "completed")])
        XCTAssertEqual(replay, KanbanEventEffect(), "a reconnect's replay is a no-op")

        live.apply([KanbanEvent(id: 16, taskID: "b", kind: "assigned", payload: ["assignee": .null]),
                    KanbanEvent(id: 17, taskID: "b", kind: "completed")])
        XCTAssertNil(live.task("b")?.assignee)
        XCTAssertEqual(ids(live, "done"), ["b"])

        let unknown = live.apply([KanbanEvent(id: 18, taskID: "t_new", kind: "created", payload: ["status": "triage"])])
        XCTAssertEqual(unknown.touched, ["t_new"])
        XCTAssertTrue(unknown.needsReload, "a card the snapshot lacks needs the snapshot")

        live.apply([KanbanEvent(id: 19, taskID: "a", kind: "archived")])
        XCTAssertNil(live.task("a"), "archived while hidden: the card leaves")
        var shown = board([("todo", ["a"])], latest: 0, archived: true)
        shown.apply([KanbanEvent(id: 1, taskID: "a", kind: "archived")])
        XCTAssertEqual(ids(shown, "archived"), ["a"], "archived while shown: the card moves there")

        XCTAssertEqual(KanbanBoard.targetStatus(of: KanbanEvent(id: 1, taskID: "x", kind: "unblocked")), "ready")
        XCTAssertEqual(KanbanBoard.targetStatus(of: KanbanEvent(id: 1, taskID: "x", kind: "unblocked", payload: ["status": "todo"])), "todo")
        XCTAssertNil(KanbanBoard.targetStatus(of: KanbanEvent(id: 1, taskID: "x", kind: "spawned")))
    }

    @MainActor
    func testStoreAppliesFramesAndResumesFromTheNewerCursor() async throws {
        let transport = RecordingKanbanTransport()
        transport.responses["GET \(root)/board"] = try any("""
        {"columns": [{"name": "todo", "tasks": [{"id": "t_a", "title": "A"}]}, {"name": "ready", "tasks": []}],
         "latest_event_id": 20}
        """)
        let store = KanbanStore(context: KanbanContext(transport: transport, dialer: nil, storageKey: nil))
        await store.reloadBoard()
        XCTAssertEqual(store.board?.total, 1)
        XCTAssertNil(store.resumeCursor(for: "default"), "no board known yet: no cursor")

        store.handle(frame: KanbanEventFrame(events: [KanbanEvent(id: 21, taskID: "t_a", kind: "status", payload: ["status": "ready"])],
                                             cursor: 21), slug: nil)
        XCTAssertEqual(store.board?.task("t_a")?.status, "ready")
        XCTAssertEqual(store.taskTicks["t_a"], 1, "an open task sheet hears about its own events")

        XCTAssertNil(store.notice, "a move is no worker outcome")
        store.handle(frame: KanbanEventFrame(events: [KanbanEvent(id: 22, taskID: "t_a", kind: "completed"),
                                                      KanbanEvent(id: 20, taskID: "t_a", kind: "blocked")], cursor: 22), slug: nil)
        XCTAssertEqual(store.notice?.title, "Task completed", "only events newer than the snapshot notify")
        XCTAssertEqual(store.notice?.message, "A")
        XCTAssertEqual(store.board?.task("t_a")?.status, "ready", "done isn't a column of this snapshot: the reload settles it")

        store.handle(frame: KanbanEventFrame(events: [], cursor: 30), slug: "ops")
        XCTAssertEqual(store.resumeCursor(for: "ops"), 30, "a board seen only on the socket resumes at its last frame")
    }

    func testMoveRulesAndLiveness() {
        var task = KanbanTask(id: "t", status: "ready")
        XCTAssertTrue(KanbanMoveRules.needsSummary(task, to: "done"))
        XCTAssertFalse(KanbanMoveRules.needsSummary(task, to: "blocked"))
        task.result = "already done"
        XCTAssertFalse(KanbanMoveRules.needsSummary(task, to: "done"), "a stored result is evidence")
        XCTAssertFalse(KanbanMoveRules.needsSummary(KanbanTask(id: "r", status: "review"), to: "done"), "approving a review needs none")

        let now = Date(timeIntervalSince1970: 100_000)
        var running = KanbanTask(id: "r", status: "running")
        running.lastHeartbeatAt = 99_950
        XCTAssertEqual(KanbanArc.of(running, defaultAssignee: "", now: now), .running)
        running.lastHeartbeatAt = 99_800
        XCTAssertEqual(KanbanArc.of(running, defaultAssignee: "", now: now), .stale)
        XCTAssertNil(KanbanArc.of(KanbanTask(id: "x", status: "ready"), defaultAssignee: ""), "unassigned ready won't run")
        XCTAssertEqual(KanbanArc.of(KanbanTask(id: "x", status: "ready"), defaultAssignee: "coder"), .queued)

        XCTAssertEqual(KanbanFormat.compactElapsed(59), "59s")
        XCTAssertEqual(KanbanFormat.compactElapsed(3600 * 5), "5h")
        XCTAssertEqual(KanbanFormat.compactNumber(12_345), "12.3K")
        XCTAssertEqual(KanbanFormat.ago(99_970, now: now), "just now")
        XCTAssertEqual(KanbanFormat.ago(100_000 - 7200, now: now), "2h ago")
        XCTAssertTrue(KanbanEventText.isAdminSummary("status changed to ready (dashboard/direct)"))
        XCTAssertEqual(KanbanEventText.describe(KanbanEvent(id: 1, taskID: "x", kind: "status", payload: ["status": "blocked"])).label,
                       "moved to Blocked")
        XCTAssertEqual(KanbanEventText.describe(KanbanEvent(id: 1, taskID: "x", kind: "new_thing", payload: ["n": 2, "o": ["x": 1]])).detail,
                       "n=2", "unknown kinds keep their scalar detail")
    }

    func testReconnectPolicyBacksOffAndStopsOnRefusals() {
        var policy = KanbanReconnectPolicy()
        XCTAssertEqual((0..<7).map { _ in policy.failed(refused: false) }, [1, 2, 4, 8, 16, 30, 30])
        XCTAssertFalse(policy.stopped, "a dropped connection keeps trying")
        policy.opened()
        XCTAssertEqual(policy.nextDelay, 1, "an open socket resets the backoff")
        for _ in 0..<4 { _ = policy.failed(refused: true) }
        XCTAssertFalse(policy.stopped)
        policy.opened()
        XCTAssertEqual(policy.refusals, 0, "refusals count only in a row")
        for _ in 0..<5 { _ = policy.failed(refused: true) }
        XCTAssertTrue(policy.stopped)
    }

    // MARK: Store writes

    @MainActor
    func testStoreRollsBackARefusedMoveAndKeepsFailedBulkSelected() async throws {
        let transport = RecordingKanbanTransport()
        transport.responses["GET \(root)/board"] = try any("""
        {"columns": [{"name": "todo", "tasks": [{"id": "t_a"}, {"id": "t_b"}]}, {"name": "ready", "tasks": []},
                     {"name": "running", "tasks": []}], "latest_event_id": 3}
        """)
        transport.failures["PATCH \(root)/tasks/t_a"] = DashboardError.http(409, #"{"detail": "Cannot move to 'ready': blocked by parent(s) not done"}"#)
        let store = KanbanStore(context: KanbanContext(transport: transport, dialer: nil, storageKey: nil))
        await store.reloadBoard()

        await store.move("t_a", to: "ready")
        XCTAssertEqual(store.board?.task("t_a")?.status, "todo", "a refused move goes back")
        XCTAssertEqual(store.failure, "Cannot move to 'ready': blocked by parent(s) not done", "with the host's reason")
        XCTAssertEqual(try canonical(transport.recorded("PATCH", "\(root)/tasks/t_a").last?.body), #"{"status":"ready"}"#)

        store.failure = nil
        await store.move("t_b", to: "running")
        XCTAssertTrue(transport.recorded("PATCH", "\(root)/tasks/t_b").isEmpty, "a locked column is never sent")
        XCTAssertNotNil(store.notice)

        transport.responses["POST \(root)/tasks/bulk"] = ["results": [["id": "t_a", "ok": false, "error": "refused"], ["id": "t_b", "ok": true]]]
        store.toggleSelected("t_a")
        store.toggleSelected("t_b")
        XCTAssertTrue(store.selecting)
        await store.applyBulk(.move(to: "ready"))
        XCTAssertEqual(store.selected, ["t_a"], "the refused card stays selected")
        XCTAssertEqual(try canonical(transport.recorded("POST", "\(root)/tasks/bulk").last?.body).contains(#""status":"ready""#), true)
        XCTAssertNotNil(store.failure)

        store.clearSelection()
        XCTAssertFalse(store.selecting)
    }

    // MARK: Availability

    func testAvailability() async throws {
        let transport = RecordingKanbanTransport()
        let served = try await KanbanAvailability.check(client: transport)
        XCTAssertTrue(served)
        XCTAssertEqual(transport.calls.last?.path, "\(root)/config", "the probe touches no board")

        transport.failures["GET \(root)/config"] = DashboardError.http(404, #"{"detail": "Plugin not found"}"#)
        let refused = try await KanbanAvailability.check(client: transport)
        XCTAssertFalse(refused)

        transport.failures["GET \(root)/config"] = DashboardError.http(502, "Bad gateway")
        do {
            _ = try await KanbanAvailability.check(client: transport)
            XCTFail("an outage isn't an answer")
        } catch {}
    }
}
