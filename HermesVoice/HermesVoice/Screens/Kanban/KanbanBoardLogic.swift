import Foundation

// The board's pure logic: optimistic edits (reconciled by the follow-up refresh, as on the desktop), the client-side
// filters, live `task_events` applied to the snapshot, and the events socket's reconnect policy.

// MARK: - Optimistic edits

extension KanbanBoard {
    /// `id` moved to the top of `status` (`moveCard` on the desktop). A move into a column the board doesn't show
    /// (archived while hidden) drops the card. Unknown ids leave the board as it is.
    func moving(_ id: String, to status: String) -> KanbanBoard {
        movingAll([id], to: status)
    }

    /// Every card in `ids` moved to the top of `status`, in board order.
    func movingAll(_ ids: Set<String>, to status: String) -> KanbanBoard {
        var moved: [KanbanTask] = []
        var columns = self.columns.map { column -> KanbanColumn in
            var column = column
            column.tasks = column.tasks.filter { task in
                guard ids.contains(task.id) else { return true }
                var task = task
                task.status = status
                moved.append(task)
                return false
            }
            return column
        }
        guard !moved.isEmpty else { return self }
        if let index = columns.firstIndex(where: { $0.name == status }) {
            columns[index].tasks.insert(contentsOf: moved, at: 0)
        }
        var board = self
        board.columns = columns
        return board
    }

    func removing(_ ids: Set<String>) -> KanbanBoard {
        var board = self
        board.columns = columns.map { KanbanColumn(name: $0.name, tasks: $0.tasks.filter { !ids.contains($0.id) }) }
        return board
    }

    /// The cards the toolbar's search and filter menu keep (the desktop's `filtered`), every column still present.
    func filtered(search: String, tenant: String, assignee: String) -> KanbanBoard {
        var board = self
        board.columns = columns.map { column in
            KanbanColumn(name: column.name, tasks: column.tasks.filter { task in
                task.matches(search) && (tenant.isEmpty || task.tenant == tenant)
                    && (assignee.isEmpty || task.assignee == assignee)
            })
        }
        return board
    }

    /// The Running column sub-grouped by assignee ("Group Running by profile"), sorted by name.
    static func lanes(_ tasks: [KanbanTask]) -> [(assignee: String, tasks: [KanbanTask])] {
        var groups: [String: [KanbanTask]] = [:]
        var order: [String] = []
        for task in tasks {
            let key = task.assignee ?? KanbanLanes.unassigned
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(task)
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, groups[$0] ?? []) }
    }
}

enum KanbanLanes {
    static let unassigned = "unassigned"
}

// MARK: - Live events

/// What a batch of `task_events` did to the board.
struct KanbanEventEffect: Equatable {
    /// Tasks the events named (an open task sheet reloads itself on these).
    var touched: Set<String> = []
    /// Something changed that the events alone can't show (a new card, an edit): the snapshot must be read again.
    var needsReload = false
    /// Events newer than the snapshot were applied.
    var applied = 0
}

extension KanbanBoard {
    /// The column an event puts its task in, when it says. A `status` in the payload wins (status, created,
    /// unblocked, review_reopened…); otherwise the kinds that always land in one column.
    static func targetStatus(of event: KanbanEvent) -> String? {
        if let status = event.string("status") { return status }
        switch event.kind {
        case "completed": return "done"
        case "claimed": return "running"
        case "archived": return KanbanColumns.archived
        case "scheduled": return "scheduled"
        case "blocked": return "blocked"
        case "unblocked", "promoted", "promoted_manual", "review_reopened": return "ready"
        case "review_requested": return "review"
        default: return nil
        }
    }

    /// Applies a frame of the `/events` stream to the snapshot. Events at or below `latestEventID` are already in
    /// it (a reconnect replays them) and change nothing. Moves, assignees, priorities and comment counts show at
    /// once; anything else asks for a reload. Every applied event also asks for one: the snapshot is the truth,
    /// the local edit only makes the board feel instant until it arrives.
    @discardableResult
    mutating func apply(_ events: [KanbanEvent]) -> KanbanEventEffect {
        var effect = KanbanEventEffect()
        for event in events.sorted(by: { $0.id < $1.id }) where event.id > latestEventID {
            latestEventID = event.id
            effect.applied += 1
            effect.needsReload = true
            guard let taskID = event.taskID else { continue }
            effect.touched.insert(taskID)
            guard task(taskID) != nil else { continue }
            switch event.kind {
            case "assigned":
                update(taskID) { $0.assignee = event.string("assignee") }
            case "commented":
                update(taskID) { $0.commentCount += 1 }
            case "reprioritized":
                if let priority = event.payload["priority"]?.intValue { update(taskID) { $0.priority = priority } }
            default:
                break
            }
            if let target = Self.targetStatus(of: event), target != task(taskID)?.status {
                let shown = columns.contains { $0.name == target }
                if shown {
                    self = moving(taskID, to: target)
                } else if target == KanbanColumns.archived {
                    self = removing([taskID])
                }
            }
        }
        return effect
    }

    private mutating func update(_ id: String, _ change: (inout KanbanTask) -> Void) {
        for column in columns.indices {
            if let index = columns[column].tasks.firstIndex(where: { $0.id == id }) {
                change(&columns[column].tasks[index])
                return
            }
        }
    }
}

// MARK: - Terminal events

/// The worker outcomes worth a toast (the desktop's completion notifications, `completion-notify.ts`).
enum KanbanTerminalEvents {
    static func title(_ kind: String) -> String? {
        switch kind {
        case "completed": return "Task completed"
        case "blocked": return "Task blocked — needs your input"
        case "block_loop_detected": return "Task routed to triage — needs a decision"
        case "gave_up": return "Task stopped"
        case "crashed": return "Task hit a problem — Hermes will retry it automatically"
        case "timed_out": return "Task took too long — Hermes will retry it automatically"
        default: return nil
        }
    }

    /// The newest terminal event among `events` newer than `after` (a replay never notifies), with its task's title.
    static func notice(_ events: [KanbanEvent], after cursor: Int, board: KanbanBoard) -> OpsNotice? {
        guard let event = events.filter({ $0.id > cursor && title($0.kind) != nil }).max(by: { $0.id < $1.id }),
              let title = title(event.kind) else { return nil }
        let task = event.taskID.flatMap(board.task)
        let name = task.map { $0.title.isEmpty ? $0.shortID : $0.title } ?? event.taskID.map(KanbanTask.shortID)
        return OpsNotice(title: title, message: name)
    }
}

// MARK: - Moves

enum KanbanMoveRules {
    /// A move to done from anywhere but Review needs completion evidence (the host refuses an empty completion):
    /// the dashboard asks for a summary, stored as the task's result. A card that already has a result needs none.
    static func needsSummary(_ task: KanbanTask, to status: String) -> Bool {
        status == "done" && task.status != "review" && (task.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether any of `tasks` needs a summary to move to `status`.
    static func needsSummary(_ tasks: [KanbanTask], to status: String) -> Bool {
        tasks.contains { needsSummary($0, to: status) }
    }
}

// MARK: - Liveness

/// The card's machine-activity state (`arcState` on the desktop): running with a heartbeat, running without one
/// for two minutes (the dispatcher will reclaim it), or queued for an agent.
enum KanbanArc: Equatable {
    case running, stale, queued

    static func of(_ task: KanbanTask, defaultAssignee: String, now: Date = Date()) -> KanbanArc? {
        if task.status == "running" {
            if let beat = task.lastHeartbeatAt, now.timeIntervalSince1970 - Double(beat) > 120 { return .stale }
            return .running
        }
        let queued = task.status == "triage" || task.status == "review"
            || (task.status == "ready" && (task.assignee != nil || !defaultAssignee.isEmpty))
        return queued ? .queued : nil
    }
}

// MARK: - Socket reconnects

/// When the `/events` socket dials again (the desktop's `pluginSocket`): capped exponential backoff from 1 s to 30 s,
/// reset by a socket that opened. Refusals (the handshake answered 401/403/404, or the socket closed at once) stop it
/// after five in a row; the board then lives on pull-to-refresh and the slow heartbeat.
struct KanbanReconnectPolicy: Equatable {
    static let initialDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 30
    static let maxRefusals = 5

    private(set) var nextDelay: TimeInterval = initialDelay
    private(set) var refusals = 0

    var stopped: Bool { refusals >= Self.maxRefusals }

    mutating func opened() {
        nextDelay = Self.initialDelay
        refusals = 0
    }

    /// The wait before the next dial after a failure.
    mutating func failed(refused: Bool) -> TimeInterval {
        if refused { refusals += 1 }
        let delay = nextDelay
        nextDelay = min(nextDelay * 2, Self.maxDelay)
        return delay
    }
}

// MARK: - Formatting

enum KanbanFormat {
    /// "42s", "3m", "5h", "2d" between two epoch-second stamps.
    static func duration(_ start: Int?, _ end: Int?) -> String? {
        guard let start, let end, end >= start else { return nil }
        return compactElapsed(TimeInterval(end - start))
    }

    static func compactElapsed(_ seconds: TimeInterval) -> String {
        let seconds = max(0, Int(seconds))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    /// "just now", "5m ago", "3h ago", "2d ago", else the date.
    static func ago(_ seconds: Int?, now: Date = Date()) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let elapsed = now.timeIntervalSince1970 - TimeInterval(seconds)
        if elapsed < 45 { return "just now" }
        if elapsed < 3600 { return "\(max(1, Int(elapsed / 60)))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h ago" }
        if elapsed < 7 * 86_400 { return "\(Int(elapsed / 86_400))d ago" }
        return Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(date: .abbreviated, time: .omitted)
    }

    static func bytes(_ count: Int?) -> String? {
        guard let count else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "12.3K", "1.2M".
    static func compactNumber(_ value: Int) -> String {
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let number = Double(value) / divisor
            let text = number >= 100 ? String(format: "%.0f", number) : String(format: "%.1f", number)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        if value >= 1_000_000 { return scaled(1_000_000, "M") }
        if value >= 1000 { return scaled(1000, "K") }
        return "\(value)"
    }
}
