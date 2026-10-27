import Foundation

// The kanban dashboard plugin's REST routes (`plugins/kanban/dashboard/plugin_api.py`, mounted at
// `/api/plugins/kanban/`), as the desktop's native board (`apps/desktop/src/plugins/kanban/api.ts`) uses them.
// Every board-scoped call names its board (`?board=<slug>`) so the phone's selection never moves the host's
// current-board pointer. Boards are shared by every profile on the host, so nothing here is profile-scoped.
// Every decoder is lenient: a missing or mistyped field falls back, unknown fields and kinds are ignored.

// MARK: - Transport

/// The REST calls the Kanban screen makes (`DashboardClient` in the app), so tests can record them.
protocol KanbanTransport: CapabilitiesTransport {
    /// A single-file multipart POST (`file` field plus plain form fields).
    func kanbanUpload(_ path: String, query: [String: String], filename: String, contentType: String?,
                      data: Data, fields: [String: String]) async throws -> Any
    /// The raw bytes of a GET (an attachment download).
    func kanbanDownload(_ path: String, query: [String: String]) async throws -> Data
}

extension DashboardClient: KanbanTransport {
    func kanbanUpload(_ path: String, query: [String: String], filename: String, contentType: String?,
                      data: Data, fields: [String: String]) async throws -> Any {
        let boundary = "hermes-\(UUID().uuidString)"
        let body = KanbanMultipart.body(boundary: boundary, filename: filename, contentType: contentType,
                                        data: data, fields: fields)
        for attempt in 0..<2 {
            var request = URLRequest(url: url(path, query: query))
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Self.origin(of: base), forHTTPHeaderField: "Origin")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (answer, response) = try await session.upload(for: request, from: body)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 || code == 403 || isSignInRedirect(http, for: request) {
                if attempt == 0 { try await signIn(); continue }
                throw DashboardError.signedOut
            }
            guard (200..<300).contains(code) else { throw DashboardError.http(code, String(decoding: answer, as: UTF8.self)) }
            return answer.isEmpty ? JSON() : try JSONSerialization.jsonObject(with: answer)
        }
        throw DashboardError.signedOut
    }

    func kanbanDownload(_ path: String, query: [String: String]) async throws -> Data {
        try await opsData(path, query: query, timeout: 300)
    }
}

/// A `multipart/form-data` body with one file part.
enum KanbanMultipart {
    static func body(boundary: String, filename: String, contentType: String?, data: Data,
                     fields: [String: String]) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(quoted(name))\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(quoted(filename))\"")
        line("Content-Type: \(contentType ?? "application/octet-stream")")
        line("")
        body.append(data)
        line("")
        line("--\(boundary)--")
        return body
    }

    /// A header parameter value: quotes and line breaks can't end it early.
    static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Columns and workflow

/// The board's columns as `kanban_workflow.DEFAULT_WORKFLOW` defines them, and the desktop's presentation of them.
enum KanbanColumns {
    /// Board order (`BOARD_COLUMNS`). `archived` is a filter toggle, never a column of its own unless shown.
    static let order = ["triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"]
    static let archived = "archived"
    /// System-owned columns (the desktop's `LOCKED_COLUMNS`): a card can leave them, never be dropped in.
    static let locked: Set<String> = ["review", "running", "scheduled"]

    static func isLocked(_ name: String) -> Bool { locked.contains(name) }

    /// The desktop's labels (`i18n.ts` `col.*.label`).
    static func label(_ name: String) -> String {
        switch name {
        case "triage": return "Triage"
        case "todo": return "Todo"
        case "scheduled": return "Scheduled"
        case "ready": return "Ready"
        case "running": return "Running"
        case "blocked": return "Blocked"
        case "review": return "Review"
        case "done": return "Done"
        case "archived": return "Archived"
        default: return name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    /// The desktop's column help (`col.*.help`).
    static func help(_ name: String) -> String {
        switch name {
        case "triage": return "Raw ideas — a specifier fleshes out the spec."
        case "todo": return "Waiting on dependencies, or unassigned."
        case "scheduled": return "Waiting for a scheduled time to arrive."
        case "ready": return "Dependencies satisfied — assign a profile and the dispatcher runs it."
        case "running": return "Claimed by a worker — an agent is on it. Set by the dispatcher."
        case "blocked": return "The worker asked for human input."
        case "review": return "A review agent is checking the work. Set by the dispatcher."
        case "done": return "Completed; dependent children become ready."
        case "archived": return "Hidden from the default board view."
        default: return ""
        }
    }

    /// Why a card can't be moved into a locked column (`locked.*`).
    static func lockedReason(_ name: String) -> String {
        switch name {
        case "review": return "Review is entered by the dispatcher when a review agent takes the card."
        case "running": return "Running is set by the dispatcher when a worker claims the card."
        case "scheduled": return "Scheduled needs a wake-up time — agents set it; it can’t be dragged into."
        default: return "\(label(name)) can’t be set by hand."
        }
    }
}

/// `GET /workflow`: the columns (order, label, drag target) and the manual move allow-list. Hosts before the route
/// get `standard`, today's board written down.
struct KanbanWorkflow: Hashable {
    struct Column: Hashable {
        var key: String
        var label: String
        var dragTarget: Bool
    }

    var columns: [Column]
    /// `src → {dst}` a human may request (archiving is always allowed and not listed; `archived` is a source).
    var manual: [String: Set<String>]

    static let standard = KanbanWorkflow(
        columns: KanbanColumns.order.map { Column(key: $0, label: KanbanColumns.label($0), dragTarget: !KanbanColumns.isLocked($0)) },
        manual: [
            "triage": ["todo", "ready"],
            "todo": ["triage", "scheduled", "ready"],
            "scheduled": ["triage", "todo", "ready"],
            "ready": ["triage", "todo", "scheduled", "blocked", "review", "done"],
            "running": ["triage", "todo", "scheduled", "ready", "blocked", "review", "done"],
            "blocked": ["triage", "todo", "scheduled", "ready", "done"],
            "review": ["triage", "todo", "ready", "done"],
            "done": ["triage", "todo", "ready"],
            "archived": ["triage", "todo", "ready"],
        ])

    init(columns: [Column], manual: [String: Set<String>]) {
        self.columns = columns
        self.manual = manual
    }

    init(response: Any) {
        let row = response as? JSON ?? [:]
        let columns: [Column] = (row["columns"] as? [Any] ?? []).compactMap { item in
            guard let column = item as? JSON, let key = LenientField.text(column["key"]) else { return nil }
            return Column(key: key, label: LenientField.text(column["label"]) ?? KanbanColumns.label(key),
                          dragTarget: LenientField.optionalBool(column["drag_target"]) ?? !KanbanColumns.isLocked(key))
        }
        var manual: [String: Set<String>] = [:]
        for (source, targets) in row["manual"] as? JSON ?? [:] {
            manual[source] = Set(LenientField.strings(targets))
        }
        self = columns.isEmpty ? .standard
            : KanbanWorkflow(columns: columns, manual: manual.isEmpty ? Self.standard.manual : manual)
    }

    /// Whether a human may move a card from `source` to `target` (archiving always, a column never into itself).
    func canMove(from source: String, to target: String) -> Bool {
        guard source != target else { return false }
        if target == KanbanColumns.archived { return true }
        guard let column = columns.first(where: { $0.key == target }), column.dragTarget else { return false }
        guard let allowed = manual[source] else { return true }
        return allowed.contains(target)
    }

    /// The columns a card in `source` can be moved to by hand, in board order.
    func targets(from source: String) -> [String] {
        columns.map(\.key).filter { canMove(from: source, to: $0) }
    }

    func isDropTarget(_ key: String) -> Bool {
        columns.first(where: { $0.key == key })?.dragTarget ?? !KanbanColumns.isLocked(key)
    }
}

// MARK: - Cards

/// A card's diagnostics rollup (`warnings`): present only when it has active ones.
struct KanbanWarnings: Hashable {
    var count: Int
    var kinds: [String: Int]
    var latestAt: Int?
    var highestSeverity: String?

    init?(_ value: Any?) {
        guard let row = value as? JSON else { return nil }
        count = max(0, LenientField.int(row["count"]))
        var kinds: [String: Int] = [:]
        for (kind, n) in row["kinds"] as? JSON ?? [:] { kinds[kind] = LenientField.int(n) }
        self.kinds = kinds
        latestAt = LenientField.optionalInt(row["latest_at"])
        highestSeverity = LenientField.text(row["highest_severity"])
        guard count > 0 else { return nil }
    }
}

/// One structured recovery action of a diagnostic (`reclaim`, `reassign`, `unblock`, `comment`, `cli_hint`, `open_docs`).
struct KanbanDiagnosticAction: Hashable {
    var kind: String
    var label: String
    var payload: [String: JSONValue]
    var suggested: Bool

    init?(_ value: Any?) {
        guard let row = value as? JSON, let kind = LenientField.text(row["kind"]) else { return nil }
        self.kind = kind
        label = LenientField.text(row["label"]) ?? kind
        payload = JSONValue(any: row["payload"] ?? NSNull()).objectValue ?? [:]
        suggested = LenientField.bool(row["suggested"])
    }

    /// The command a `cli_hint` copies.
    var command: String { payload["command"]?.stringValue ?? label }
}

/// One active distress signal on a task (`kanban_diagnostics.Diagnostic`).
struct KanbanDiagnostic: Hashable {
    var kind: String
    var severity: String
    var title: String
    var detail: String
    var actions: [KanbanDiagnosticAction]
    var count: Int
    var lastSeenAt: Int?
    var data: [String: JSONValue]

    init?(_ value: Any?) {
        guard let row = value as? JSON, let kind = LenientField.text(row["kind"]) else { return nil }
        self.kind = kind
        severity = LenientField.text(row["severity"]) ?? "warning"
        title = LenientField.text(row["title"]) ?? kind.replacingOccurrences(of: "_", with: " ")
        detail = (row["detail"] as? String) ?? ""
        actions = (row["actions"] as? [Any] ?? []).compactMap(KanbanDiagnosticAction.init)
        count = max(1, LenientField.optionalInt(row["count"]) ?? 1)
        lastSeenAt = LenientField.optionalInt(row["last_seen_at"])
        data = JSONValue(any: row["data"] ?? NSNull()).objectValue ?? [:]
    }

    static func list(_ value: Any?) -> [KanbanDiagnostic] {
        (value as? [Any] ?? []).compactMap(KanbanDiagnostic.init)
    }
}

/// One card: the board's task row (`_task_dict` plus the board's rollups), or the full task of `GET /tasks/:id`.
struct KanbanTask: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String?
    /// The column id.
    var status: String
    var assignee: String?
    var priority: Int
    var tenant: String?
    var createdBy: String?
    var createdAt: Int?
    var startedAt: Int?
    var completedAt: Int?
    var workspaceKind: String?
    var workspacePath: String?
    var branchName: String?
    var projectID: String?
    var result: String?
    var latestSummary: String?
    var consecutiveFailures: Int
    var workerPID: Int?
    var lastFailureError: String?
    var lastHeartbeatAt: Int?
    var currentRunID: Int?
    /// Start of the current run (a retried task's `startedAt` is its first-ever start).
    var currentRunStartedAt: Int?
    var skills: [String]?
    var modelOverride: String?
    var providerOverride: String?
    var reasoningEffort: String?
    var goalMode: Bool
    var goalMaxTurns: Int?
    var sessionID: String?
    var blockKind: String?
    var blockRecurrences: Int
    var commentCount: Int
    var parentCount: Int
    var childCount: Int
    /// Children done / total; nil without children.
    var progress: (done: Int, total: Int)? {
        get { progressTotal.map { (progressDone, $0) } }
        set { progressDone = newValue?.done ?? 0; progressTotal = newValue?.total }
    }
    private var progressDone = 0
    private var progressTotal: Int?
    var warnings: KanbanWarnings?
    var diagnostics: [KanbanDiagnostic]

    init(id: String, title: String = "", status: String = "todo", assignee: String? = nil, priority: Int = 0) {
        self.id = id
        self.title = title
        self.status = status
        self.assignee = assignee
        self.priority = priority
        consecutiveFailures = 0
        goalMode = false
        blockRecurrences = 0
        commentCount = 0
        parentCount = 0
        childCount = 0
        diagnostics = []
    }

    init?(_ value: Any?, fallbackStatus: String = "todo") {
        guard let row = value as? JSON, let id = LenientField.text(row["id"]) else { return nil }
        self.init(id: id)
        let text = { (key: String) in LenientField.text(row[key]) }
        let int = { (key: String) in LenientField.optionalInt(row[key]) }
        title = (row["title"] as? String) ?? ""
        body = (row["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        status = text("status") ?? fallbackStatus
        assignee = text("assignee")
        priority = int("priority") ?? 0
        tenant = text("tenant")
        createdBy = text("created_by")
        createdAt = int("created_at")
        startedAt = int("started_at")
        completedAt = int("completed_at")
        workspaceKind = text("workspace_kind")
        workspacePath = text("workspace_path")
        branchName = text("branch_name")
        projectID = text("project_id")
        result = text("result")
        latestSummary = text("latest_summary")
        consecutiveFailures = max(0, int("consecutive_failures") ?? 0)
        workerPID = int("worker_pid")
        lastFailureError = text("last_failure_error")
        lastHeartbeatAt = int("last_heartbeat_at")
        currentRunID = int("current_run_id")
        currentRunStartedAt = int("current_run_started_at")
        skills = row["skills"] is [Any] ? LenientField.strings(row["skills"]) : nil
        modelOverride = text("model_override")
        providerOverride = text("provider_override")
        reasoningEffort = text("reasoning_effort")
        goalMode = LenientField.optionalBool(row["goal_mode"]) ?? (int("goal_mode") ?? 0 != 0)
        goalMaxTurns = int("goal_max_turns")
        sessionID = text("session_id")
        blockKind = text("block_kind")
        blockRecurrences = max(0, int("block_recurrences") ?? 0)
        commentCount = max(0, int("comment_count") ?? 0)
        if let links = row["link_counts"] as? JSON {
            parentCount = max(0, LenientField.int(links["parents"]))
            childCount = max(0, LenientField.int(links["children"]))
        }
        if let progress = row["progress"] as? JSON, let total = LenientField.optionalInt(progress["total"]), total > 0 {
            self.progress = (max(0, LenientField.int(progress["done"])), total)
        }
        warnings = KanbanWarnings(row["warnings"])
        diagnostics = KanbanDiagnostic.list(row["diagnostics"])
    }

    var linkCount: Int { parentCount + childCount }

    /// The id as the desktop shows it: no `t_` prefix, six characters.
    var shortID: String { Self.shortID(id) }

    static func shortID(_ id: String) -> String {
        String((id.hasPrefix("t_") ? String(id.dropFirst(2)) : id).prefix(6))
    }

    /// The card's preview line: the latest run summary, else the description.
    var preview: String? { latestSummary ?? body }

    /// What a search matches (the desktop's filter: title, description, id).
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return "\(title) \(body ?? "") \(id)".lowercased().contains(needle)
    }
}

/// One board column and its cards.
struct KanbanColumn: Identifiable, Hashable {
    var name: String
    var tasks: [KanbanTask]
    var id: String { name }
}

/// `GET /board`: every column with its cards, plus the board's tenants and assignees and its event tail.
struct KanbanBoard: Hashable {
    var columns: [KanbanColumn]
    var tenants: [String]
    var assignees: [String]
    /// The newest `task_events` id when the snapshot was read: where the live stream resumes.
    var latestEventID: Int
    var now: Int?

    init(columns: [KanbanColumn], tenants: [String] = [], assignees: [String] = [], latestEventID: Int = 0, now: Int? = nil) {
        self.columns = columns
        self.tenants = tenants
        self.assignees = assignees
        self.latestEventID = latestEventID
        self.now = now
    }

    init(response: Any) {
        let row = response as? JSON ?? [:]
        var seen = Set<String>()
        columns = (row["columns"] as? [Any] ?? []).compactMap { item in
            guard let column = item as? JSON, let name = LenientField.text(column["name"]), seen.insert(name).inserted else {
                return nil
            }
            var ids = Set<String>()
            let tasks = (column["tasks"] as? [Any] ?? []).compactMap { KanbanTask($0, fallbackStatus: name) }
                .filter { ids.insert($0.id).inserted }
                .map { task -> KanbanTask in
                    var task = task
                    task.status = name
                    return task
                }
            return KanbanColumn(name: name, tasks: tasks)
        }
        tenants = LenientField.strings(row["tenants"])
        assignees = LenientField.strings(row["assignees"])
        latestEventID = max(0, LenientField.int(row["latest_event_id"]))
        now = LenientField.optionalInt(row["now"])
    }

    var allTasks: [KanbanTask] { columns.flatMap(\.tasks) }
    var total: Int { columns.reduce(0) { $0 + $1.tasks.count } }

    func task(_ id: String) -> KanbanTask? {
        for column in columns { if let task = column.tasks.first(where: { $0.id == id }) { return task } }
        return nil
    }

    func count(_ column: String) -> Int { columns.first { $0.name == column }?.tasks.count ?? 0 }
}

// MARK: - Task detail

struct KanbanComment: Identifiable, Hashable {
    var id: String
    var author: String
    var body: String
    var createdAt: Int?

    init?(_ value: Any?) {
        guard let row = value as? JSON, let body = row["body"] as? String else { return nil }
        id = LenientField.optionalInt(row["id"]).map(String.init) ?? LenientField.text(row["id"]) ?? UUID().uuidString
        author = LenientField.text(row["author"]) ?? "someone"
        self.body = body
        createdAt = LenientField.optionalInt(row["created_at"])
    }
}

/// One `task_events` row (the drawer's Activity, and each frame of the live stream).
struct KanbanEvent: Identifiable, Hashable {
    var id: Int
    var taskID: String?
    var runID: Int?
    var kind: String
    var payload: [String: JSONValue]
    /// A payload that arrived as text it couldn't read as an object.
    var rawPayload: String?
    var createdAt: Int?

    init(id: Int, taskID: String?, kind: String, payload: [String: JSONValue] = [:], createdAt: Int? = nil) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
    }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let id = LenientField.optionalInt(row["id"]), let kind = LenientField.text(row["kind"]) else {
            return nil
        }
        self.id = id
        taskID = LenientField.text(row["task_id"])
        runID = LenientField.optionalInt(row["run_id"])
        self.kind = kind
        createdAt = LenientField.optionalInt(row["created_at"])
        switch row["payload"] {
        case let object as JSON:
            payload = JSONValue(any: object).objectValue ?? [:]
        case let text as String where !text.isEmpty:
            if let data = text.data(using: .utf8), let parsed = (try? JSONSerialization.jsonObject(with: data)) as? JSON {
                payload = JSONValue(any: parsed).objectValue ?? [:]
            } else {
                payload = [:]
                rawPayload = text
            }
        default:
            payload = [:]
        }
    }

    func string(_ key: String) -> String? {
        guard let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}

/// One attempt at a task (`task_runs`).
struct KanbanRun: Identifiable, Hashable {
    var id: Int
    var profile: String?
    var stepKey: String?
    var status: String
    var outcome: String?
    var summary: String?
    var error: String?
    var workerPID: Int?
    var startedAt: Int?
    var endedAt: Int?
    var lastHeartbeatAt: Int?

    init?(_ value: Any?) {
        guard let row = value as? JSON, let id = LenientField.optionalInt(row["id"]) else { return nil }
        self.id = id
        profile = LenientField.text(row["profile"])
        stepKey = LenientField.text(row["step_key"])
        status = LenientField.text(row["status"]) ?? "unknown"
        outcome = LenientField.text(row["outcome"])
        summary = LenientField.text(row["summary"])
        error = LenientField.text(row["error"])
        workerPID = LenientField.optionalInt(row["worker_pid"])
        startedAt = LenientField.optionalInt(row["started_at"])
        endedAt = LenientField.optionalInt(row["ended_at"])
        lastHeartbeatAt = LenientField.optionalInt(row["last_heartbeat_at"])
    }

    var isActive: Bool { endedAt == nil }
    /// The outcome when it ended, else the status.
    var state: String { outcome ?? status }
    var failed: Bool { ["crashed", "failed", "timed_out", "gave_up"].contains(state) }
}

struct KanbanAttachment: Identifiable, Hashable {
    var id: Int
    var taskID: String?
    var filename: String
    var contentType: String?
    var size: Int?
    var uploadedBy: String?
    var createdAt: Int?

    init?(_ value: Any?) {
        guard let row = value as? JSON, let id = LenientField.optionalInt(row["id"]) else { return nil }
        self.id = id
        taskID = LenientField.text(row["task_id"])
        filename = LenientField.text(row["filename"]) ?? "attachment-\(id)"
        contentType = LenientField.text(row["content_type"])
        size = LenientField.optionalInt(row["size"])
        uploadedBy = LenientField.text(row["uploaded_by"])
        createdAt = LenientField.optionalInt(row["created_at"])
    }
}

/// A linked task resolved to its title (`link_tasks`).
struct KanbanLinkTask: Identifiable, Hashable {
    var id: String
    var title: String
    var status: String?

    init?(_ value: Any?) {
        guard let row = value as? JSON, let id = LenientField.text(row["id"]) else { return nil }
        self.id = id
        title = LenientField.text(row["title"]) ?? id
        status = LenientField.text(row["status"])
    }
}

/// `GET /tasks/:id`: the task and its related collections (siblings of `task`).
struct KanbanTaskDetail: Hashable {
    var task: KanbanTask
    var comments: [KanbanComment]
    var events: [KanbanEvent]
    /// Nil on hosts before attachments (the section hides instead of offering uploads that would 404).
    var attachments: [KanbanAttachment]?
    var parents: [String]
    var children: [String]
    var linkTasks: [KanbanLinkTask]
    var runs: [KanbanRun]

    init?(response: Any) {
        guard let row = response as? JSON, let task = KanbanTask(row["task"]) else { return nil }
        self.task = task
        comments = (row["comments"] as? [Any] ?? []).compactMap(KanbanComment.init)
        events = (row["events"] as? [Any] ?? []).compactMap(KanbanEvent.init)
        attachments = (row["attachments"] as? [Any]).map { $0.compactMap(KanbanAttachment.init) }
        let links = row["links"] as? JSON ?? [:]
        parents = LenientField.strings(links["parents"])
        children = LenientField.strings(links["children"])
        linkTasks = (row["link_tasks"] as? [Any] ?? []).compactMap(KanbanLinkTask.init)
        runs = (row["runs"] as? [Any] ?? []).compactMap(KanbanRun.init)
    }

    /// A linked task's title, else its short id.
    func linkTitle(_ id: String) -> String {
        linkTasks.first { $0.id == id }?.title ?? KanbanTask.shortID(id)
    }
}

/// `GET /tasks/:id/log`: the worker's stdout/stderr tail.
struct KanbanWorkerLog: Hashable {
    var exists: Bool
    var sizeBytes: Int
    var content: String
    var truncated: Bool

    init(response: Any) {
        let row = response as? JSON ?? [:]
        exists = LenientField.bool(row["exists"])
        sizeBytes = max(0, LenientField.int(row["size_bytes"]))
        content = row["content"] as? String ?? ""
        truncated = LenientField.bool(row["truncated"])
    }

    var hasContent: Bool { exists && !content.isEmpty }
}

// MARK: - Boards

/// One board on the host (`GET /boards`).
struct KanbanBoardMeta: Identifiable, Hashable {
    var slug: String
    var name: String
    var description: String
    var icon: String
    var isCurrent: Bool
    /// Live cards (archived excluded).
    var total: Int?
    var counts: [String: Int]
    var defaultWorkdir: String?
    /// `scratch` when no directory, `worktree` in a git repo, else `dir`.
    var defaultWorkspaceKind: String?
    var projectID: String?
    var projectName: String?
    var archived: Bool

    var id: String { slug }

    init(slug: String, name: String? = nil) {
        self.slug = slug
        self.name = name ?? slug
        description = ""
        icon = ""
        isCurrent = false
        counts = [:]
        archived = false
    }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let slug = LenientField.text(row["slug"]) else { return nil }
        self.init(slug: slug, name: LenientField.text(row["name"]))
        description = LenientField.text(row["description"]) ?? ""
        icon = LenientField.text(row["icon"]) ?? ""
        isCurrent = LenientField.bool(row["is_current"])
        total = LenientField.optionalInt(row["total"])
        for (status, n) in row["counts"] as? JSON ?? [:] { counts[status] = LenientField.int(n) }
        defaultWorkdir = LenientField.text(row["default_workdir"])
        defaultWorkspaceKind = LenientField.text(row["default_workspace_kind"])
        projectID = LenientField.text(row["project_id"])
        projectName = LenientField.text(row["project_name"])
        archived = LenientField.bool(row["archived"])
    }
}

struct KanbanBoardList: Hashable {
    var boards: [KanbanBoardMeta]
    /// The host's current board (the CLI's pointer).
    var current: String

    init(boards: [KanbanBoardMeta], current: String) {
        self.boards = boards
        self.current = current
    }

    init(response: Any) {
        let row = response as? JSON ?? [:]
        var seen = Set<String>()
        let boards = (row["boards"] as? [Any] ?? []).compactMap(KanbanBoardMeta.init).filter { seen.insert($0.slug).inserted }
        self.boards = boards
        current = LenientField.text(row["current"]) ?? boards.first(where: \.isCurrent)?.slug ?? KanbanAPI.defaultBoard
    }

    func board(_ slug: String) -> KanbanBoardMeta? { boards.first { $0.slug == slug } }
}

/// `POST /boards/{slug}/export`: the archive the host wrote.
struct KanbanBoardExport: Hashable {
    var board: String
    var archive: String
    var size: Int?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        board = LenientField.text(row["board"]) ?? ""
        archive = LenientField.text(row["archive"]) ?? LenientField.text(row["path"]) ?? ""
        size = LenientField.optionalInt(row["size"])
    }
}

/// `POST /boards/import`: the new board the archive landed as.
struct KanbanBoardImport: Hashable {
    var board: String
    var name: String
    /// The archive's slug was taken, so the import got a suffix.
    var renamed: Bool
    var warnings: [String]

    init(response: Any) {
        let row = response as? JSON ?? [:]
        board = LenientField.text(row["board"]) ?? ""
        name = LenientField.text(row["name"]) ?? board
        renamed = LenientField.bool(row["renamed"])
        warnings = LenientField.strings(row["warnings"])
    }
}

/// A first-class Hermes project a board can be scoped to (`GET /projects`).
struct KanbanProject: Identifiable, Hashable {
    var id: String
    var slug: String
    var name: String
    var primaryPath: String?

    init?(_ value: Any?) {
        guard let row = value as? JSON, let id = LenientField.text(row["id"]) else { return nil }
        self.id = id
        slug = LenientField.text(row["slug"]) ?? id
        name = LenientField.text(row["name"]) ?? slug
        primaryPath = LenientField.text(row["primary_path"])
    }
}

// MARK: - Profiles, orchestration, settings

/// One installed profile the decomposer routes across (`GET /profiles`).
struct KanbanProfile: Identifiable, Hashable {
    var name: String
    var isDefault: Bool
    var model: String?
    var provider: String?
    var description: String
    var descriptionAuto: Bool

    var id: String { name }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        isDefault = LenientField.bool(row["is_default"])
        model = LenientField.text(row["model"])
        provider = LenientField.text(row["provider"])
        description = LenientField.text(row["description"]) ?? ""
        descriptionAuto = LenientField.bool(row["description_auto"])
    }

    static func list(_ response: Any) -> [KanbanProfile] {
        var seen = Set<String>()
        return ((response as? JSON)?["profiles"] as? [Any] ?? []).compactMap(KanbanProfile.init)
            .filter { seen.insert($0.name).inserted }
    }
}

/// `GET /assignees`: on-disk profiles and every assignee used on the board, with their per-status counts.
struct KanbanAssignee: Identifiable, Hashable {
    var name: String
    var onDisk: Bool
    var counts: [String: Int]
    var id: String { name }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        onDisk = LenientField.bool(row["on_disk"])
        var counts: [String: Int] = [:]
        for (status, n) in row["counts"] as? JSON ?? [:] { counts[status] = LenientField.int(n) }
        self.counts = counts
    }
}

/// `GET /orchestration`: the dispatcher knobs from config.yaml and their resolved values.
struct KanbanOrchestration: Hashable {
    var orchestratorProfile: String
    var defaultAssignee: String
    var autoDecompose: Bool
    var autoPromoteChildren: Bool
    var resolvedOrchestratorProfile: String
    var resolvedDefaultAssignee: String
    var activeProfile: String?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        let orchestrator = LenientField.text(row["orchestrator_profile"]) ?? ""
        let fallback = LenientField.text(row["default_assignee"]) ?? ""
        orchestratorProfile = orchestrator
        defaultAssignee = fallback
        autoDecompose = LenientField.optionalBool(row["auto_decompose"]) ?? true
        autoPromoteChildren = LenientField.optionalBool(row["auto_promote_children"]) ?? true
        activeProfile = LenientField.text(row["active_profile"])
        resolvedOrchestratorProfile = LenientField.text(row["resolved_orchestrator_profile"]) ?? orchestrator
        resolvedDefaultAssignee = LenientField.text(row["resolved_default_assignee"]) ?? fallback
    }
}

/// `GET /config`: the dashboard's kanban preferences (`dashboard.kanban`).
struct KanbanConfig: Hashable {
    var defaultTenant: String?
    var laneByProfile: Bool
    var includeArchivedByDefault: Bool
    var renderMarkdown: Bool

    init(response: Any) {
        let row = response as? JSON ?? [:]
        defaultTenant = LenientField.text(row["default_tenant"])
        laneByProfile = LenientField.optionalBool(row["lane_by_profile"]) ?? true
        includeArchivedByDefault = LenientField.optionalBool(row["include_archived_by_default"]) ?? false
        renderMarkdown = LenientField.optionalBool(row["render_markdown"]) ?? true
    }
}

/// `GET /stats`: per-status and per-assignee counts and the oldest ready card's age.
struct KanbanStats: Hashable {
    var byStatus: [String: Int]
    var byAssignee: [String: [String: Int]]
    var oldestReadyAgeSeconds: Int?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        var byStatus: [String: Int] = [:]
        for (status, n) in row["by_status"] as? JSON ?? [:] { byStatus[status] = LenientField.int(n) }
        self.byStatus = byStatus
        var byAssignee: [String: [String: Int]] = [:]
        for (name, value) in row["by_assignee"] as? JSON ?? [:] {
            var counts: [String: Int] = [:]
            for (status, n) in value as? JSON ?? [:] { counts[status] = LenientField.int(n) }
            byAssignee[name] = counts
        }
        self.byAssignee = byAssignee
        oldestReadyAgeSeconds = LenientField.optionalInt(row["oldest_ready_age_seconds"])
    }
}

/// One task with active diagnostics (`GET /diagnostics`).
struct KanbanDiagnosticsEntry: Identifiable, Hashable {
    var taskID: String
    var taskTitle: String?
    var taskStatus: String?
    var taskAssignee: String?
    var diagnostics: [KanbanDiagnostic]
    var id: String { taskID }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let taskID = LenientField.text(row["task_id"]) else { return nil }
        self.taskID = taskID
        taskTitle = LenientField.text(row["task_title"])
        taskStatus = LenientField.text(row["task_status"])
        taskAssignee = LenientField.text(row["task_assignee"])
        diagnostics = KanbanDiagnostic.list(row["diagnostics"])
    }
}

/// One running worker (`GET /workers/active`).
struct KanbanActiveWorker: Identifiable, Hashable {
    var runID: Int
    var taskID: String
    var taskTitle: String?
    var assignee: String?
    var profile: String?
    var workerPID: Int?
    var startedAt: Int?
    var lastHeartbeatAt: Int?
    var maxRuntimeSeconds: Int?
    var id: Int { runID }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let runID = LenientField.optionalInt(row["run_id"]),
              let taskID = LenientField.text(row["task_id"]) else { return nil }
        self.runID = runID
        self.taskID = taskID
        taskTitle = LenientField.text(row["task_title"])
        assignee = LenientField.text(row["task_assignee"])
        profile = LenientField.text(row["profile"])
        workerPID = LenientField.optionalInt(row["worker_pid"])
        startedAt = LenientField.optionalInt(row["started_at"])
        lastHeartbeatAt = LenientField.optionalInt(row["last_heartbeat_at"])
        maxRuntimeSeconds = LenientField.optionalInt(row["max_runtime_seconds"])
    }

    static func list(_ response: Any) -> [KanbanActiveWorker] {
        ((response as? JSON)?["workers"] as? [Any] ?? []).compactMap(KanbanActiveWorker.init)
    }
}

/// `GET /runs/{id}/inspect`: live process stats of a run's worker.
struct KanbanRunInspect: Hashable {
    var alive: Bool
    var pid: Int?
    var cpuPercent: Double?
    var memoryRSSBytes: Int?
    var threads: Int?
    var processStatus: String?
    /// Why it isn't alive ("run already ended", "process not found"), or an access error.
    var reason: String?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        alive = LenientField.bool(row["alive"])
        pid = LenientField.optionalInt(row["pid"])
        cpuPercent = (row["cpu_percent"] as? NSNumber)?.doubleValue
        memoryRSSBytes = LenientField.optionalInt(row["memory_rss_bytes"])
        threads = LenientField.optionalInt(row["num_threads"])
        processStatus = LenientField.text(row["status"])
        reason = LenientField.text(row["reason"]) ?? LenientField.text(row["error"])
    }
}

/// A platform's home channel and whether the task notifies it (`GET /home-channels`).
struct KanbanHomeChannel: Identifiable, Hashable {
    var platform: String
    var chatID: String
    var threadID: String
    var name: String
    var subscribed: Bool
    var id: String { platform }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let platform = LenientField.text(row["platform"]) else { return nil }
        self.platform = platform
        chatID = LenientField.text(row["chat_id"]) ?? (row["chat_id"] as? NSNumber)?.stringValue ?? ""
        threadID = LenientField.text(row["thread_id"]) ?? ""
        name = LenientField.text(row["name"]) ?? "Home"
        subscribed = LenientField.bool(row["subscribed"])
    }
}

/// A provider and its curated models for the per-task override (`GET /model-options`).
struct KanbanModelProvider: Identifiable, Hashable {
    var slug: String
    var label: String
    var models: [String]
    var id: String { slug }

    init?(_ value: Any?) {
        guard let row = value as? JSON, let slug = LenientField.text(row["slug"]) else { return nil }
        self.slug = slug
        label = LenientField.text(row["label"]) ?? slug
        models = LenientField.strings(row["models"])
        guard !models.isEmpty else { return nil }
    }
}

/// The rough auxiliary-model estimate (`/estimate`): tokens and complexity, never dollars.
struct KanbanEstimate: Hashable {
    var ok: Bool
    var reason: String?
    var estTokens: Int
    /// S, M or L.
    var complexity: String?
    var rationale: String?
    var model: String?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        ok = LenientField.bool(row["ok"])
        reason = LenientField.text(row["reason"])
        estTokens = max(0, LenientField.int(row["est_tokens"]))
        let size = LenientField.text(row["complexity"])?.uppercased()
        complexity = ["S", "M", "L"].contains(size ?? "") ? size : nil
        rationale = LenientField.text(row["rationale"])
        model = LenientField.text(row["model"])
    }

    var complexityLabel: String? {
        switch complexity {
        case "S": return "Small"
        case "M": return "Medium"
        case "L": return "Large"
        default: return nil
        }
    }
}

/// What an auxiliary-model action answered (specify, decompose, auto-describe). Not OK is no HTTP error: the reason
/// is shown inline.
struct KanbanAuxOutcome: Hashable {
    var ok: Bool
    var reason: String?
    var newTitle: String?
    /// Decompose fanned the task out into these children.
    var childIDs: [String]
    var fanout: Bool
    /// Auto-describe's text.
    var description: String?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        ok = LenientField.bool(row["ok"])
        reason = LenientField.text(row["reason"])
        newTitle = LenientField.text(row["new_title"])
        childIDs = LenientField.strings(row["child_ids"])
        fanout = LenientField.bool(row["fanout"])
        description = LenientField.text(row["description"])
    }
}

/// One id's outcome of `POST /tasks/bulk`.
struct KanbanBulkResult: Hashable {
    var id: String
    var ok: Bool
    var error: String?

    static func list(_ response: Any) -> [KanbanBulkResult] {
        ((response as? JSON)?["results"] as? [Any] ?? []).compactMap { item in
            guard let row = item as? JSON, let id = LenientField.text(row["id"]) else { return nil }
            return KanbanBulkResult(id: id, ok: LenientField.optionalBool(row["ok"]) ?? false, error: LenientField.text(row["error"]))
        }
    }
}

/// `POST /tasks`: the created task and the dispatcher-presence warning ("this ready task will sit idle").
struct KanbanCreateResult: Hashable {
    var task: KanbanTask?
    var warning: String?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        task = KanbanTask(row["task"])
        warning = LenientField.text(row["warning"])
    }
}

/// `DELETE /boards/{slug}`: archived (recoverable, the default) or deleted.
struct KanbanBoardRemoval: Hashable {
    var action: String
    var newPath: String?
    var current: String?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        let result = row["result"] as? JSON ?? [:]
        action = LenientField.text(result["action"]) ?? "archived"
        newPath = LenientField.text(result["new_path"])
        current = LenientField.text(row["current"])
    }
}

/// One frame of the `/events` socket: `{events: [...], cursor}`.
struct KanbanEventFrame: Hashable {
    var events: [KanbanEvent]
    var cursor: Int?

    init(events: [KanbanEvent], cursor: Int?) {
        self.events = events
        self.cursor = cursor
    }

    init?(text: String) {
        guard let data = text.data(using: .utf8), let row = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            return nil
        }
        events = (row["events"] as? [Any] ?? []).compactMap(KanbanEvent.init).sorted { $0.id < $1.id }
        cursor = LenientField.optionalInt(row["cursor"]) ?? events.last?.id
    }
}

// MARK: - Request bodies

/// A task's model override. Empty strings inherit the assigned profile's own model and effort.
struct KanbanModelOverride: Hashable {
    /// "" inherits, "none" turns thinking off, else a reasoning level.
    var effort = ""
    var model = ""
    var provider = ""

    static let inherit = KanbanModelOverride()
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    init(effort: String = "", model: String = "", provider: String = "") {
        self.effort = effort
        self.model = model
        self.provider = provider
    }

    init(task: KanbanTask) {
        self.init(effort: task.reasoningEffort ?? "", model: task.modelOverride ?? "", provider: task.providerOverride ?? "")
    }

    var isInherited: Bool { trimmed(model).isEmpty && trimmed(provider).isEmpty && trimmed(effort).isEmpty }

    /// `provider: model · High`, or `inherit` when nothing is pinned.
    func label(inherit: String) -> String {
        guard !isInherited else { return inherit }
        let model = trimmed(self.model)
        let base = model.isEmpty ? inherit : (trimmed(provider).isEmpty ? model : "\(trimmed(provider)): \(model)")
        let effort = trimmed(self.effort)
        return effort.isEmpty ? base : "\(base) · \(Self.effortTitle(effort))"
    }

    /// The PATCH fields: explicit clears, since a missing field means "not sent".
    var patchFields: JSON {
        var fields: JSON = [:]
        let model = trimmed(self.model), effort = trimmed(self.effort), provider = trimmed(self.provider)
        if model.isEmpty {
            fields["clear_model_override"] = true
        } else {
            fields["model_override"] = model
            if !provider.isEmpty { fields["provider_override"] = provider }
        }
        if effort.isEmpty { fields["clear_reasoning_effort"] = true } else { fields["reasoning_effort"] = effort }
        return fields
    }

    /// The create fields: omitted rather than cleared, so the host's defaults apply.
    var createFields: JSON {
        var fields: JSON = [:]
        let model = trimmed(self.model), effort = trimmed(self.effort), provider = trimmed(self.provider)
        if !model.isEmpty {
            fields["model_override"] = model
            if !provider.isEmpty { fields["provider_override"] = provider }
        }
        if !effort.isEmpty { fields["reasoning_effort"] = effort }
        return fields
    }

    static func effortTitle(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none": return "Off"
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return effort.capitalized
        }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// `PATCH /tasks/:id`. Nil fields aren't sent; `assignee: ""` unassigns.
struct KanbanTaskPatch: Hashable {
    var status: String?
    var assignee: String?
    var priority: Int?
    var title: String?
    var body: String?
    /// Completion evidence for a move to done (the result and the closing run's summary).
    var result: String?
    var summary: String?
    var blockReason: String?
    var modelOverride: KanbanModelOverride?

    init(status: String? = nil, assignee: String? = nil, priority: Int? = nil, title: String? = nil, body: String? = nil,
         result: String? = nil, summary: String? = nil, blockReason: String? = nil, modelOverride: KanbanModelOverride? = nil) {
        self.status = status
        self.assignee = assignee
        self.priority = priority
        self.title = title
        self.body = body
        self.result = result
        self.summary = summary
        self.blockReason = blockReason
        self.modelOverride = modelOverride
    }

    /// A move, with the completion summary when it is one to done.
    static func move(to status: String, summary: String? = nil) -> KanbanTaskPatch {
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = (summary?.isEmpty ?? true) ? nil : summary
        return KanbanTaskPatch(status: status, result: evidence, summary: evidence)
    }

    var json: JSON {
        var body: JSON = [:]
        if let status { body["status"] = status }
        if let assignee { body["assignee"] = assignee }
        if let priority { body["priority"] = priority }
        if let title { body["title"] = title }
        if let text = self.body { body["body"] = text }
        if let result { body["result"] = result }
        if let summary { body["summary"] = summary }
        if let blockReason { body["block_reason"] = blockReason }
        if let modelOverride { body.merge(modelOverride.patchFields) { _, new in new } }
        return body
    }
}

/// `POST /tasks/bulk`: one patch applied to every id independently.
struct KanbanBulkPatch: Hashable {
    var status: String?
    /// "" unassigns.
    var assignee: String?
    var priority: Int?
    var archive = false
    var result: String?
    var summary: String?
    /// Release a running worker's claim before reassigning.
    var reclaimFirst = false

    static func move(to status: String, summary: String? = nil) -> KanbanBulkPatch {
        let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = (summary?.isEmpty ?? true) ? nil : summary
        return KanbanBulkPatch(status: status, result: evidence, summary: evidence)
    }

    static func assign(_ profile: String?) -> KanbanBulkPatch {
        KanbanBulkPatch(assignee: profile ?? "", reclaimFirst: true)
    }

    static let archiveAll = KanbanBulkPatch(archive: true)

    func json(ids: [String]) -> JSON {
        var body: JSON = ["ids": ids]
        if let status { body["status"] = status }
        if let assignee { body["assignee"] = assignee }
        if let priority { body["priority"] = priority }
        if archive { body["archive"] = true }
        if let result { body["result"] = result }
        if let summary { body["summary"] = summary }
        if reclaimFirst { body["reclaim_first"] = true }
        return body
    }
}

/// `POST /tasks`: a new card.
struct KanbanNewTask: Hashable {
    var title: String
    var body = ""
    /// Nil leaves the card unassigned (parked).
    var assignee: String?
    var priority = 0
    var tenant: String?
    /// `scratch`, `worktree` or `dir`; nil lets the host pick.
    var workspaceKind: String?
    /// Overrides the board's project directory (only for `worktree`/`dir`).
    var workspacePath = ""
    var parents: [String] = []
    /// Lands in Triage for a specifier to flesh out.
    var triage = false
    var skills: [String] = []
    var goalMode = false
    var modelOverride = KanbanModelOverride.inherit

    var json: JSON {
        var json: JSON = ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "priority": priority,
                          "triage": triage, "goal_mode": goalMode]
        let body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { json["body"] = body }
        if let assignee = assignee?.trimmingCharacters(in: .whitespaces), !assignee.isEmpty { json["assignee"] = assignee }
        if let tenant = tenant?.trimmingCharacters(in: .whitespaces), !tenant.isEmpty { json["tenant"] = tenant }
        if let workspaceKind { json["workspace_kind"] = workspaceKind }
        let path = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let kind = workspaceKind, kind != "scratch", !path.isEmpty { json["workspace_path"] = path }
        if !parents.isEmpty { json["parents"] = parents }
        let skills = self.skills.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !skills.isEmpty { json["skills"] = skills }
        json.merge(modelOverride.createFields) { _, new in new }
        return json
    }

    /// "a, b ,, c" → ["a", "b", "c"].
    static func skills(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// `POST /boards`: a new board.
struct KanbanNewBoard: Hashable {
    var name: String
    var projectID: String?
    var switchTo = false

    /// The slug the desktop derives from the name: lower-case, runs of anything else become "-".
    static func slug(for name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug
    }

    var slug: String { Self.slug(for: name) }

    var json: JSON {
        var json: JSON = ["slug": slug, "name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let projectID, !projectID.isEmpty { json["project_id"] = projectID }
        if switchTo { json["switch"] = true }
        return json
    }
}

// MARK: - Routes

/// The kanban plugin's routes for one board (`board` nil: the host's current board).
struct KanbanAPI {
    static let root = "/api/plugins/kanban"
    /// `kanban_db.DEFAULT_BOARD`: always exists, can't be removed.
    static let defaultBoard = "default"
    /// Routes that call the auxiliary model answer only once it has.
    static let modelTimeout: TimeInterval = 180

    let transport: KanbanTransport
    var board: String?

    init(transport: KanbanTransport, board: String? = nil) {
        self.transport = transport
        self.board = board
    }

    func on(board: String?) -> KanbanAPI { KanbanAPI(transport: transport, board: board) }

    /// A path part: no slashes or dot segments can address another route.
    static func segment(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw DashboardError.rpc("“\(value)” can't be addressed on the dashboard.")
        }
        return trimmed
    }

    /// `?board=` plus `extra`.
    func boardQuery(_ extra: [String: String] = [:]) -> [String: String] {
        var query = extra
        if let board, !board.isEmpty { query["board"] = board }
        return query
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> Any {
        try await transport.request("GET", Self.root + path, query: query, body: nil)
    }

    private func send(_ method: String, _ path: String, _ query: [String: String] = [:], body: JSON? = [:],
                      timeout: TimeInterval? = nil) async throws -> Any {
        if let timeout {
            return try await transport.request(method, Self.root + path, query: query, body: body, timeout: timeout)
        }
        return try await transport.request(method, Self.root + path, query: query, body: body)
    }

    private func taskPath(_ id: String, _ suffix: String = "") throws -> String {
        "/tasks/\(try Self.segment(id))\(suffix)"
    }

    // MARK: Reads

    func boardSnapshot(includeArchived: Bool = false, tenant: String? = nil) async throws -> KanbanBoard {
        var extra: [String: String] = [:]
        if includeArchived { extra["include_archived"] = "true" }
        if let tenant, !tenant.isEmpty { extra["tenant"] = tenant }
        return KanbanBoard(response: try await get("/board", boardQuery(extra)))
    }

    func task(_ id: String) async throws -> KanbanTaskDetail {
        guard let detail = KanbanTaskDetail(response: try await get(try taskPath(id), boardQuery())) else {
            throw DashboardError.rpc("The task's details didn't come back.")
        }
        return detail
    }

    /// The worker's stdout/stderr tail (16 KiB, as the desktop's drawer reads it).
    func log(_ id: String, tail: Int = 16_384) async throws -> KanbanWorkerLog {
        KanbanWorkerLog(response: try await get(try taskPath(id, "/log"), boardQuery(["tail": String(max(1, tail))])))
    }

    func boards(includeArchived: Bool = false) async throws -> KanbanBoardList {
        KanbanBoardList(response: try await get("/boards", includeArchived ? ["include_archived": "true"] : [:]))
    }

    func profiles() async throws -> [KanbanProfile] { KanbanProfile.list(try await get("/profiles")) }

    func projects() async throws -> [KanbanProject] {
        ((try await get("/projects") as? JSON)?["projects"] as? [Any] ?? []).compactMap(KanbanProject.init)
    }

    func assignees() async throws -> [KanbanAssignee] {
        ((try await get("/assignees", boardQuery()) as? JSON)?["assignees"] as? [Any] ?? []).compactMap(KanbanAssignee.init)
    }

    func orchestration() async throws -> KanbanOrchestration { KanbanOrchestration(response: try await get("/orchestration")) }

    func config() async throws -> KanbanConfig { KanbanConfig(response: try await get("/config")) }

    func workflow() async throws -> KanbanWorkflow { KanbanWorkflow(response: try await get("/workflow")) }

    func stats() async throws -> KanbanStats { KanbanStats(response: try await get("/stats", boardQuery())) }

    func diagnostics(severity: String? = nil) async throws -> [KanbanDiagnosticsEntry] {
        var extra: [String: String] = [:]
        if let severity { extra["severity"] = severity }
        return ((try await get("/diagnostics", boardQuery(extra)) as? JSON)?["diagnostics"] as? [Any] ?? [])
            .compactMap(KanbanDiagnosticsEntry.init)
    }

    func activeWorkers() async throws -> [KanbanActiveWorker] {
        KanbanActiveWorker.list(try await get("/workers/active", boardQuery()))
    }

    func run(_ id: Int) async throws -> KanbanRun? {
        KanbanRun((try await get("/runs/\(id)", boardQuery()) as? JSON)?["run"])
    }

    func inspectRun(_ id: Int) async throws -> KanbanRunInspect {
        KanbanRunInspect(response: try await get("/runs/\(id)/inspect", boardQuery()))
    }

    func homeChannels(task id: String?) async throws -> [KanbanHomeChannel] {
        var extra: [String: String] = [:]
        if let id { extra["task_id"] = id }
        return ((try await get("/home-channels", boardQuery(extra)) as? JSON)?["home_channels"] as? [Any] ?? [])
            .compactMap(KanbanHomeChannel.init)
    }

    func modelOptions() async throws -> [KanbanModelProvider] {
        ((try await get("/model-options") as? JSON)?["providers"] as? [Any] ?? []).compactMap(KanbanModelProvider.init)
    }

    func downloadAttachment(_ id: Int) async throws -> Data {
        try await transport.kanbanDownload(Self.root + "/attachments/\(id)", query: boardQuery())
    }

    // MARK: Task writes

    func createTask(_ draft: KanbanNewTask) async throws -> KanbanCreateResult {
        KanbanCreateResult(response: try await send("POST", "/tasks", boardQuery(), body: draft.json))
    }

    @discardableResult
    func patchTask(_ id: String, _ patch: KanbanTaskPatch) async throws -> KanbanTask? {
        KanbanTask((try await send("PATCH", try taskPath(id), boardQuery(), body: patch.json) as? JSON)?["task"])
    }

    func deleteTask(_ id: String) async throws {
        _ = try await send("DELETE", try taskPath(id), boardQuery(), body: nil)
    }

    func bulk(_ ids: [String], _ patch: KanbanBulkPatch) async throws -> [KanbanBulkResult] {
        KanbanBulkResult.list(try await send("POST", "/tasks/bulk", boardQuery(), body: patch.json(ids: ids)))
    }

    /// Posts a comment as the phone (the desktop signs its own as "desktop").
    func addComment(_ id: String, body: String, author: String = "mobile") async throws {
        _ = try await send("POST", try taskPath(id, "/comments"), boardQuery(), body: ["author": author, "body": body])
    }

    func addLink(parent: String, child: String) async throws {
        _ = try await send("POST", "/links", boardQuery(), body: ["parent_id": parent, "child_id": child])
    }

    func removeLink(parent: String, child: String) async throws {
        _ = try await send("DELETE", "/links", boardQuery(["parent_id": parent, "child_id": child]), body: nil)
    }

    func uploadAttachment(task id: String, filename: String, contentType: String?, data: Data) async throws -> KanbanAttachment? {
        let answer = try await transport.kanbanUpload(Self.root + (try taskPath(id, "/attachments")), query: boardQuery(),
                                                      filename: filename, contentType: contentType, data: data,
                                                      fields: ["uploaded_by": "mobile"])
        return KanbanAttachment((answer as? JSON)?["attachment"])
    }

    func deleteAttachment(_ id: Int) async throws {
        _ = try await send("DELETE", "/attachments/\(id)", boardQuery(), body: nil)
    }

    /// Releases a worker's claim now (the task returns to the queue).
    func reclaim(_ id: String, reason: String? = nil) async throws {
        var body: JSON = [:]
        if let reason { body["reason"] = reason }
        _ = try await send("POST", try taskPath(id, "/reclaim"), boardQuery(), body: body)
    }

    /// Reassigns (nil or "" unassigns), reclaiming a running worker first when asked.
    func reassign(_ id: String, profile: String?, reclaimFirst: Bool = true, reason: String? = nil) async throws {
        var body: JSON = ["profile": profile ?? "", "reclaim_first": reclaimFirst]
        if let reason { body["reason"] = reason }
        _ = try await send("POST", try taskPath(id, "/reassign"), boardQuery(), body: body)
    }

    func specify(_ id: String) async throws -> KanbanAuxOutcome {
        KanbanAuxOutcome(response: try await send("POST", try taskPath(id, "/specify"), boardQuery(), timeout: Self.modelTimeout))
    }

    func decompose(_ id: String) async throws -> KanbanAuxOutcome {
        KanbanAuxOutcome(response: try await send("POST", try taskPath(id, "/decompose"), boardQuery(), timeout: Self.modelTimeout))
    }

    func estimate(task id: String) async throws -> KanbanEstimate {
        KanbanEstimate(response: try await send("POST", try taskPath(id, "/estimate"), boardQuery(), timeout: Self.modelTimeout))
    }

    /// An estimate from typed text, before the task exists.
    func estimate(title: String, body: String) async throws -> KanbanEstimate {
        var json: JSON = ["title": title]
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { json["body"] = body }
        return KanbanEstimate(response: try await send("POST", "/estimate", body: json, timeout: Self.modelTimeout))
    }

    func setHomeSubscription(task id: String, platform: String, subscribed: Bool) async throws {
        let path = try taskPath(id, "/home-subscribe/\(try Self.segment(platform))")
        _ = try await send(subscribed ? "POST" : "DELETE", path, boardQuery(), body: subscribed ? [:] : nil)
    }

    func terminateRun(_ id: Int, reason: String? = nil) async throws {
        var body: JSON = [:]
        if let reason { body["reason"] = reason }
        _ = try await send("POST", "/runs/\(id)/terminate", boardQuery(), body: body)
    }

    /// Kicks the dispatcher so a change runs now instead of on its next tick.
    func dispatch(max: Int = 8) async throws {
        _ = try await send("POST", "/dispatch", boardQuery(["max": String(max)]), timeout: 60)
    }

    // MARK: Boards, profiles, orchestration

    func createBoard(_ draft: KanbanNewBoard) async throws -> KanbanBoardMeta? {
        KanbanBoardMeta((try await send("POST", "/boards", body: draft.json) as? JSON)?["board"])
    }

    /// Display metadata and project scope (`project_id: ""` clears it); the slug is immutable.
    func updateBoard(_ slug: String, name: String? = nil, projectID: String? = nil) async throws -> KanbanBoardMeta? {
        var body: JSON = [:]
        if let name { body["name"] = name }
        if let projectID { body["project_id"] = projectID }
        return KanbanBoardMeta((try await send("PATCH", "/boards/\(try Self.segment(slug))", body: body) as? JSON)?["board"])
    }

    /// Archives the board (recoverable on the host); `hard` erases it.
    func deleteBoard(_ slug: String, hard: Bool = false) async throws -> KanbanBoardRemoval {
        KanbanBoardRemoval(response: try await send("DELETE", "/boards/\(try Self.segment(slug))",
                                                    hard ? ["delete": "true"] : [:], body: nil))
    }

    /// Writes the board to an archive on the host (`output` empty: the host's export folder).
    func exportBoard(_ slug: String, output: String = "") async throws -> KanbanBoardExport {
        KanbanBoardExport(response: try await send("POST", "/boards/\(try Self.segment(slug))/export",
                                                   body: ["output": output], timeout: 300))
    }

    /// Moves the host's current-board pointer (the CLI's active board). The screen picks boards on the phone
    /// instead, as the desktop does, so a terminal left open on the host keeps its board.
    @discardableResult
    func makeCurrent(_ slug: String) async throws -> String? {
        LenientField.text((try await send("POST", "/boards/\(try Self.segment(slug))/switch") as? JSON)?["current"])
    }

    /// Imports an archive already on the host as a new board.
    func importBoard(archive: String) async throws -> KanbanBoardImport {
        KanbanBoardImport(response: try await send("POST", "/boards/import", body: ["archive": archive], timeout: 300))
    }

    func saveOrchestration(_ patch: JSON) async throws -> KanbanOrchestration {
        KanbanOrchestration(response: try await send("PUT", "/orchestration", body: patch))
    }

    func saveProfileDescription(_ name: String, _ description: String) async throws {
        _ = try await send("PATCH", "/profiles/\(try Self.segment(name))", body: ["description": description])
    }

    func autoDescribeProfile(_ name: String) async throws -> KanbanAuxOutcome {
        KanbanAuxOutcome(response: try await send("POST", "/profiles/\(try Self.segment(name))/describe-auto",
                                                  body: ["overwrite": true], timeout: Self.modelTimeout))
    }

    // MARK: Live events

    /// The `/events` socket's query: the board it is pinned to, where to resume, and the one-use ticket.
    static func eventsQuery(board: String?, since: Int?, ticket: String) -> [String: String] {
        var query = ["ticket": ticket]
        if let board, !board.isEmpty { query["board"] = board }
        if let since { query["since"] = String(max(0, since)) }
        return query
    }
}

// MARK: - Availability

/// Whether the host serves the kanban plugin, so the sidebar can offer the board only where it works.
enum KanbanAvailability {
    /// True when the plugin's API answers; false when the host refuses it (not installed, disabled, or consent
    /// withheld: the dashboard answers 404). Other failures (offline, signed out) throw, so the caller keeps what it
    /// knew. The probe reads `/config`, which touches no board (the board route creates the database).
    static func check(client: KanbanTransport) async throws -> Bool {
        do {
            _ = try await client.request("GET", KanbanAPI.root + "/config", query: [:], body: nil)
            return true
        } catch let DashboardError.http(code, _) where code == 404 {
            return false
        }
    }
}
