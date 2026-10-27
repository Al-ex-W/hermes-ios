import Foundation

// The desktop's spawn tree (`app/agents/index.tsx` over `store/subagents.ts`): every subagent a delegation started,
// fed by the gateway's `subagent.*` events of the sessions this connection is attached to and reconciled with the
// `subagent.list` roster. These are the pure parts (payload reading, the per-session roster, the tree and its
// formatting); `AgentsStore` drives them from the connection.

/// A subagent's state, normalized the way the desktop's `asStatus` does.
enum AgentStatus: String, Hashable, Sendable {
    case queued, running, completed, failed, interrupted

    var isLive: Bool { self == .queued || self == .running }
    var isTerminal: Bool { !isLive }

    /// `timeout`/`error` fail, `cancelled` interrupts. A `subagent.complete` is terminal by definition, so there an
    /// unknown (or still-live) status fails rather than leaving a dead row spinning; live events stay lenient.
    static func normalize(_ raw: String?, terminalEvent: Bool = false) -> AgentStatus {
        switch raw {
        case "completed": return .completed
        case "failed", "timeout", "error": return .failed
        case "interrupted", "cancelled", "canceled": return .interrupted
        default:
            if terminalEvent { return .failed }
            return raw == "queued" ? .queued : .running
        }
    }
}

/// One line of a subagent's activity stream.
struct AgentStreamEntry: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case progress, summary, thinking, tool }

    var at: Date
    var isError = false
    var kind: Kind
    var text: String
}

/// A `subagent.*` event payload, a `subagent.list` roster row or a failed delegation, read leniently (numbers may
/// arrive as strings or floats, and an older backend omits identity fields).
struct AgentPayload: Hashable, Sendable {
    struct TailEntry: Hashable, Sendable {
        var tool: String?
        var preview: String?
        var isError = false
    }

    var subagentID: String?
    var parentID: String?
    var childSessionID: String?
    var delegationID: String?
    var goal: String?
    var model: String?
    var status: String?
    var taskCount: Int?
    var taskIndex: Int?
    var startedAt: Double?
    var durationSeconds: Double?
    var costUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var toolCount: Int?
    var filesRead: [String] = []
    var filesWritten: [String] = []
    var outputTail: [TailEntry] = []
    var toolName: String?
    var toolPreview: String?
    var text: String?
    var summary: String?
    var lastTool: String?
    var error: String?
    var hasError = false
    var acceptingSteer: Bool?
    var dispatchedAt: Double?
    var completedAt: Double?

    init() {}

    init(json: JSONValue) {
        func string(_ key: String) -> String? {
            guard let value = json[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        func number(_ key: String) -> Double? {
            guard let value = json[key] else { return nil }
            if let double = value.doubleValue, double.isFinite { return double }
            return value.stringValue.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        }
        func int(_ key: String) -> Int? { number(key).map { Int($0) } }
        func strings(_ key: String) -> [String] {
            (json[key]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.isEmpty }
        }
        subagentID = string("subagent_id")
        parentID = string("parent_id")
        childSessionID = string("child_session_id")
        delegationID = string("delegation_id")
        goal = string("goal")
        model = string("model")
        status = string("status")
        taskCount = int("task_count")
        taskIndex = int("task_index")
        startedAt = number("started_at")
        durationSeconds = number("duration_seconds")
        costUSD = number("cost_usd")
        inputTokens = int("input_tokens")
        outputTokens = int("output_tokens")
        toolCount = int("tool_count")
        filesRead = strings("files_read")
        filesWritten = strings("files_written")
        outputTail = (json["output_tail"]?.arrayValue ?? []).compactMap { item in
            guard item.objectValue != nil else { return nil }
            return TailEntry(tool: item["tool"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                             preview: item["preview"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                             isError: item["is_error"]?.boolValue == true)
        }
        toolName = string("tool_name")
        toolPreview = string("tool_preview")
        text = string("text")
        summary = string("summary")
        lastTool = string("last_tool")
        error = string("error")
        // The desktop marks a line failed on any truthy `error`.
        switch json["error"] {
        case nil, .null?: hasError = false
        case let .bool(flag)?: hasError = flag
        case let .string(text)?: hasError = !text.isEmpty
        case let .int(value)?: hasError = value != 0
        case let .double(value)?: hasError = value != 0
        default: hasError = true
        }
        acceptingSteer = json["accepting_steer"]?.boolValue
        dispatchedAt = number("dispatched_at")
        completedAt = number("completed_at")
    }

    /// A typed payload, read through its JSON so typed and untyped frames take one path.
    init<Value: Encodable>(_ typed: Value) {
        self.init(json: (try? JSONValue.encode(typed)) ?? .null)
    }

    /// The row id the desktop's `idOf` derives: the subagent id, else parent, task index and goal.
    var rowID: String {
        subagentID ?? "\(parentID ?? "root"):\(taskIndex ?? 0):\(goal ?? "")"
    }
}

/// One subagent as the spawn tree shows it (`SubagentProgress`).
struct AgentProgress: Hashable, Identifiable, Sendable {
    var id: String
    /// The runtime session that owns it (whose `subagent.*` frames carried it): its controls go through that session.
    var ownerSession: String
    var parentID: String?
    var goal: String
    /// The child's own stored session id, so the tree can open its session.
    var childSessionID: String?
    /// Batch (delegation) id: the exact grouping key for one fan-out's workers.
    var delegationID: String?
    var model: String?
    var status: AgentStatus
    var taskCount: Int
    var taskIndex: Int
    var startedAt: Date
    var updatedAt: Date
    var durationSeconds: Double?
    var costUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var toolCount: Int?
    var filesRead: [String] = []
    var filesWritten: [String] = []
    var stream: [AgentStreamEntry] = []
    var summary: String?
    /// The active tool while running; cleared on a terminal status.
    var currentTool: String?
    /// The roster says it takes steering text now (`accepting_steer`); nil when unknown.
    var acceptingSteer: Bool?

    var isLive: Bool { status.isLive }
    var tokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }
}

/// A subagent with its children, for the tree.
struct AgentNode: Hashable, Identifiable, Sendable {
    var agent: AgentProgress
    var children: [AgentNode] = []

    /// Unique across sessions (fallback ids could repeat in two sessions).
    var id: String { "\(agent.ownerSession)|\(agent.id)" }

    var flattened: [AgentProgress] { [agent] + children.flatMap(\.flattened) }
}

/// Every session's subagents and the bookkeeping that keeps finished rows retired (`store/subagents.ts`).
struct AgentRoster: Equatable, Sendable {
    static let maxStream = 24
    static let previewMax = 220
    static let toolPreviewMax = 96

    private(set) var bySession: [String: [AgentProgress]] = [:]
    /// Row ids a turn retired per session, so late frames or rosters can't bring finished work back.
    private(set) var retired: [String: Set<String>] = [:]

    func agents(in session: String) -> [AgentProgress] { bySession[session] ?? [] }

    var all: [AgentProgress] { bySession.values.flatMap { $0 } }

    /// Applies one `subagent.*` frame (`upsertSubagent`). A row already terminal, or retired, ignores it.
    mutating func upsert(session: String, payload: AgentPayload, createIfMissing: Bool, eventType: String?,
                         now: Date) {
        let list = agents(in: session)
        let id = payload.rowID
        let index = list.firstIndex { $0.id == id }
        if retired[session]?.contains(id) == true || (index == nil && !createIfMissing) { return }
        let previous = index.map { list[$0] }
        if let previous, previous.status.isTerminal { return }
        let next = Self.project(payload, session: session, previous: previous, eventType: eventType, now: now)
        var nextList = list
        if let index { nextList[index] = next } else { nextList.append(next) }
        set(session, previous: list, next: nextList)
    }

    /// Reconciles a `subagent.list` roster without replacing the stream history (`reconcileSubagentSnapshot`).
    /// Live rows the roster no longer holds go; `failed` delegations the roster lost land as failed rows unless a
    /// row already covers that task.
    mutating func reconcile(session: String, children: [AgentPayload], failed: [AgentPayload] = [], now: Date) {
        let previous = agents(in: session)
        let ids = Set(children.compactMap(\.subagentID))
        var next = previous.filter { $0.status.isTerminal || ids.contains($0.id) }
        let retiredIDs = retired[session] ?? []

        for payload in children {
            guard let id = payload.subagentID, !retiredIDs.contains(id) else { continue }
            let index = next.firstIndex { $0.id == id }
            let prev = index.map { next[$0] }
            if let prev, prev.status.isTerminal { continue }
            var projected = Self.project(payload, session: session, previous: prev, eventType: nil, now: now)
            if let started = payload.startedAt, started > 0 {
                projected.startedAt = Date(timeIntervalSince1970: started)
            } else if let prev {
                projected.startedAt = prev.startedAt
            }
            projected.updatedAt = prev?.updatedAt ?? projected.startedAt
            // A roster records the last tool, not a running call: it seeds a cold row only.
            if projected.stream.isEmpty, let tool = payload.lastTool {
                projected.stream = [AgentStreamEntry(at: projected.updatedAt, kind: .tool, text: Self.formatTool(tool))]
            }
            if let index { next[index] = projected } else { next.append(projected) }
        }

        for payload in failed {
            guard let delegation = payload.delegationID else { continue }
            let taskIndex = payload.taskIndex ?? 0
            let id = "delegation:\(delegation):\(taskIndex)"
            if retiredIDs.contains(id)
                || next.contains(where: { $0.id == id || ($0.delegationID == delegation && $0.taskIndex == taskIndex) }) {
                continue
            }
            let at = payload.completedAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } ?? now
            let started = payload.dispatchedAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil } ?? at
            var row = payload
            row.subagentID = id
            row.summary = payload.error
            var projected = Self.project(row, session: session, previous: nil, eventType: "subagent.complete", now: now)
            projected.durationSeconds = max(0, at.timeIntervalSince(started).rounded())
            projected.startedAt = started
            projected.updatedAt = at
            next.append(projected)
        }

        if next != previous { set(session, previous: previous, next: next) }
    }

    /// A new turn began (`message.start`): the previous turn's finished rows go, live background work stays.
    mutating func pruneFinished(session: String) {
        let list = agents(in: session)
        let next = list.filter(\.isLive)
        guard next.count != list.count else { return }
        set(session, previous: list, next: next)
    }

    /// Forgets a session's rows and its retired ids.
    mutating func clear(session: String) {
        bySession[session] = nil
        retired[session] = nil
    }

    /// The spawn tree's scope: live rows from every session (a background session's work stays visible) and
    /// finished rows only for `focus`, the session the user is in (`subagentsForPanel`).
    func panel(focus: String?) -> [AgentProgress] {
        bySession.keys.sorted().flatMap { session -> [AgentProgress] in
            let items = bySession[session] ?? []
            return session == focus ? items : items.filter(\.isLive)
        }
    }

    var liveCount: Int { all.filter(\.isLive).count }
    var failedCount: Int { all.filter { $0.status == .failed || $0.status == .interrupted }.count }

    private mutating func set(_ session: String, previous: [AgentProgress], next: [AgentProgress]) {
        let finished = previous.filter(\.status.isTerminal).map(\.id)
        if !finished.isEmpty { retired[session, default: []].formUnion(finished) }
        bySession[session] = next
    }

    // MARK: Projection (`toProgress`)

    static func project(_ payload: AgentPayload, session: String, previous: AgentProgress?, eventType: String?,
                        now: Date) -> AgentProgress {
        let status = AgentStatus.normalize(payload.status, terminalEvent: eventType == "subagent.complete")
        let entries = streamEntries(payload, status: status, eventType: eventType, at: now)
        let stream = entries.reduce(previous?.stream ?? [], append)
        return AgentProgress(
            id: previous?.id ?? payload.rowID,
            ownerSession: session,
            parentID: payload.parentID ?? previous?.parentID,
            goal: payload.goal ?? previous?.goal ?? "Subagent",
            childSessionID: payload.childSessionID ?? previous?.childSessionID,
            delegationID: payload.delegationID ?? previous?.delegationID,
            model: payload.model ?? previous?.model,
            status: status,
            taskCount: payload.taskCount ?? previous?.taskCount ?? 1,
            taskIndex: payload.taskIndex ?? previous?.taskIndex ?? 0,
            startedAt: previous?.startedAt ?? now,
            updatedAt: now,
            durationSeconds: payload.durationSeconds ?? previous?.durationSeconds,
            costUSD: payload.costUSD ?? previous?.costUSD,
            inputTokens: payload.inputTokens ?? previous?.inputTokens,
            outputTokens: payload.outputTokens ?? previous?.outputTokens,
            toolCount: payload.toolCount ?? previous?.toolCount,
            filesRead: payload.filesRead.isEmpty ? previous?.filesRead ?? [] : payload.filesRead,
            filesWritten: payload.filesWritten.isEmpty ? previous?.filesWritten ?? [] : payload.filesWritten,
            stream: stream,
            summary: payload.summary ?? timeoutSummary(payload) ?? previous?.summary,
            currentTool: status.isTerminal ? nil : payload.toolName ?? previous?.currentTool,
            acceptingSteer: payload.acceptingSteer ?? previous?.acceptingSteer
        )
    }

    /// The lines one frame adds (`streamFromPayload`).
    static func streamEntries(_ payload: AgentPayload, status: AgentStatus, eventType: String?, at: Date) -> [AgentStreamEntry] {
        var out: [AgentStreamEntry] = []
        let preview = payload.toolPreview ?? payload.text ?? ""
        let text = compact(payload.text ?? preview)
        for tail in payload.outputTail {
            let line = tail.tool.map { formatTool($0, preview: tail.preview ?? "") } ?? compact(tail.preview ?? "")
            if !line.isEmpty {
                out.append(AgentStreamEntry(at: at, isError: tail.isError, kind: tail.tool == nil ? .progress : .tool, text: line))
            }
        }
        if let tool = payload.toolName {
            out.append(AgentStreamEntry(at: at, isError: payload.hasError, kind: .tool, text: formatTool(tool, preview: preview)))
        }
        if eventType == "subagent.progress", !text.isEmpty {
            out.append(AgentStreamEntry(at: at, isError: payload.hasError, kind: .progress, text: text))
        }
        if eventType == "subagent.thinking", !text.isEmpty {
            out.append(AgentStreamEntry(at: at, kind: .thinking, text: text))
        }
        let summary = compact(payload.summary ?? payload.text ?? timeoutSummary(payload) ?? "")
        if status.isTerminal, !summary.isEmpty {
            out.append(AgentStreamEntry(at: at, isError: status == .failed, kind: .summary, text: summary))
        }
        return out
    }

    /// Appends unless it repeats the last line; keeps the newest `maxStream`.
    static func append(_ stream: [AgentStreamEntry], _ entry: AgentStreamEntry) -> [AgentStreamEntry] {
        if let last = stream.last, last.kind == entry.kind, last.text == entry.text, last.isError == entry.isError {
            return stream
        }
        return Array((stream + [entry]).suffix(maxStream))
    }

    /// A hard child timeout sends no summary, only `timeout` and its duration: say why it failed.
    static func timeoutSummary(_ payload: AgentPayload) -> String? {
        guard payload.status == "timeout" else { return nil }
        let seconds = payload.durationSeconds.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "?"
        return "Timed out after \(seconds)s"
    }

    /// One line, collapsed whitespace, cut to `max` with an ellipsis.
    static func compact(_ text: String, max: Int = previewMax) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > max else { return line }
        return String(line.prefix(max - 1)) + "…"
    }

    /// `web_search` → `Web Search`.
    static func toolLabel(_ name: String) -> String {
        let words = name.split(separator: "_").map { word in word.prefix(1).uppercased() + word.dropFirst() }
        return words.isEmpty ? name : words.joined(separator: " ")
    }

    /// `Web Search("query")`.
    static func formatTool(_ name: String, preview: String = "") -> String {
        let snippet = compact(preview, max: toolPreviewMax)
        return snippet.isEmpty ? toolLabel(name) : "\(toolLabel(name))(\"\(snippet)\")"
    }
}

/// The tree the panel draws: nodes nested under their parents, delegations grouped, and the counts over them.
enum AgentTree {
    /// Children under their parent within a session; roots and children by start, task index, then goal
    /// (`buildSubagentTree`).
    static func build(_ items: [AgentProgress]) -> [AgentNode] {
        var roots: [AgentNode] = []
        for session in Set(items.map(\.ownerSession)).sorted() {
            let agents = items.filter { $0.ownerSession == session }
            let ids = Set(agents.map(\.id))
            var children: [String: [AgentProgress]] = [:]
            var top: [AgentProgress] = []
            for agent in agents {
                if let parent = agent.parentID, parent != agent.id, ids.contains(parent) {
                    children[parent, default: []].append(agent)
                } else {
                    top.append(agent)
                }
            }
            var seen: Set<String> = []
            func node(_ agent: AgentProgress) -> AgentNode {
                seen.insert(agent.id)
                let kids = (children[agent.id] ?? []).filter { !seen.contains($0.id) }.sorted(by: order)
                return AgentNode(agent: agent, children: kids.map(node))
            }
            roots += top.sorted(by: order).map(node)
            // A parent cycle leaves rows unreached: they show at the top level rather than vanish.
            roots += agents.filter { !seen.contains($0.id) }.sorted(by: order).map { AgentNode(agent: $0) }
        }
        return roots.sorted { order($0.agent, $1.agent) }
    }

    /// A node in the list: its row, then its children's, each with its depth.
    struct Row: Identifiable, Hashable {
        var node: AgentNode
        var depth: Int
        var id: String { node.id }
    }

    /// The tree as list rows, parents before their children (depth first).
    static func rows(_ nodes: [AgentNode], depth: Int = 0) -> [Row] {
        nodes.flatMap { node in [Row(node: node, depth: depth)] + rows(node.children, depth: depth + 1) }
    }

    static func order(_ a: AgentProgress, _ b: AgentProgress) -> Bool {
        if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
        if a.taskIndex != b.taskIndex { return a.taskIndex < b.taskIndex }
        return a.goal < b.goal
    }

    /// One delegation's workers (`RootGroup`).
    struct Group: Hashable, Identifiable {
        var id: String
        /// "Delegation n"; 0 for a single task.
        var index: Int
        var nodes: [AgentNode]
        var taskCount: Int

        /// A lone single-task row shows without a group header.
        var isSingle: Bool { nodes.count == 1 && taskCount <= 1 }
        var activeWorkers: Int { nodes.filter(\.agent.isLive).count }
    }

    /// Roots grouped by delegation (`groupDelegations`): exactly by `delegation_id` when the backend tags workers,
    /// else an older backend's fan-out by shape and time (same task count, started within 5 s, distinct tasks).
    static func groups(_ roots: [AgentNode]) -> [Group] {
        var groups: [Group] = []
        var count = 0
        for node in roots {
            let agent = node.agent
            if let delegation = agent.delegationID {
                let key = "delegation:\(delegation)"
                if let index = groups.firstIndex(where: { $0.id == key }) {
                    groups[index].nodes.append(node)
                    continue
                }
                count += 1
                groups.append(Group(id: key, index: count, nodes: [node], taskCount: agent.taskCount))
                continue
            }
            if let previous = groups.last, let tail = previous.nodes.last?.agent,
               !previous.id.hasPrefix("delegation:"), agent.taskCount > 1, previous.taskCount == agent.taskCount,
               abs(agent.startedAt.timeIntervalSince(tail.startedAt)) <= 5,
               !previous.nodes.contains(where: { $0.agent.taskIndex == agent.taskIndex }) {
                groups[groups.count - 1].nodes.append(node)
                continue
            }
            if agent.taskCount > 1 {
                count += 1
                groups.append(Group(id: "delegation-\(count)", index: count, nodes: [node], taskCount: agent.taskCount))
                continue
            }
            groups.append(Group(id: node.id, index: 0, nodes: [node], taskCount: agent.taskCount))
        }
        return groups
    }

    /// The counts line over the tree.
    struct Summary: Equatable {
        var agents = 0
        var active = 0
        var failed = 0
        var tools = 0
        var files = 0
        var tokens = 0
        var cost: Double = 0

        init(_ roots: [AgentNode]) {
            let flat = roots.flatMap(\.flattened)
            agents = flat.count
            active = flat.filter(\.isLive).count
            failed = flat.filter { $0.status == .failed || $0.status == .interrupted }.count
            tools = flat.reduce(0) { $0 + ($1.toolCount ?? 0) }
            files = flat.reduce(0) { $0 + $1.filesRead.count + $1.filesWritten.count }
            tokens = flat.reduce(0) { $0 + $1.tokens }
            cost = flat.reduce(0) { $0 + ($1.costUSD ?? 0) }
        }

        /// "3 agents · 1 active · 1 failed · 12 tools · 4 files · 18.2k tok · $0.04"; `failed` is the part the
        /// screen tints.
        var parts: [String] {
            [
                "\(agents) \(agents == 1 ? "agent" : "agents")",
                active > 0 ? "\(active) active" : "",
                failedPart ?? "",
                tools > 0 ? "\(tools) tools" : "",
                files > 0 ? "\(files) files" : "",
                tokens > 0 ? AgentFormat.tokens(tokens) : "",
                cost > 0 ? String(format: "$%.2f", cost) : "",
            ].filter { !$0.isEmpty }
        }

        var failedPart: String? { failed > 0 ? "\(failed) failed" : nil }
    }
}

/// The spawn tree's number formats (`fmtDuration`, `fmtTokens`, `fmtAge`, `compactNumber`).
enum AgentFormat {
    /// "12.3s", "4m 7s"; empty for none.
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds / 60)
        let rest = Int((seconds.truncatingRemainder(dividingBy: 60)).rounded())
        return "\(minutes)m \(rest)s"
    }

    /// "18.2k tok"; empty for none.
    static func tokens(_ value: Int?) -> String {
        guard let value, value > 0 else { return "" }
        return "\(compactNumber(Double(value))) tok"
    }

    /// "now", "12s ago", "4m ago", "25h ago" (hours unbounded, as the desktop's tree).
    static func age(_ updated: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(updated).rounded()))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes)m ago" : "\(minutes / 60)h ago"
    }

    /// 950, 1.2k, 18k, 1.5M; thresholds sit under the unit so rounding never shows "1000k".
    static func compactNumber(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        func scaled(_ number: Double, _ suffix: String) -> String {
            var text = String(format: "%.1f", number)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + suffix
        }
        if value >= 999_950 { return scaled(value / 1_000_000, "M") }
        if value >= 999.5 { return scaled(value / 1000, "k") }
        return String(Int(value.rounded()))
    }

    /// A row's subtitle: model · duration · tools · tokens · updated age.
    static func subtitle(_ agent: AgentProgress, now: Date) -> String {
        let seconds = agent.durationSeconds.map { max(0, $0.rounded()) }
            ?? (agent.isLive ? max(0, now.timeIntervalSince(agent.startedAt).rounded(.down)) : nil)
        return [
            agent.model ?? "",
            duration(seconds),
            (agent.toolCount ?? 0) > 0 ? "\(agent.toolCount ?? 0) tools" : "",
            tokens(agent.tokens),
            "updated \(age(agent.updatedAt, now: now))",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
