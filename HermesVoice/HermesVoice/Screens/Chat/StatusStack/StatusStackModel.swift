import Foundation

/// What the session is doing beside the transcript, for the stack above the composer (the desktop's
/// `status-stack`): its todo list (`todo.updated`), live subagents (`subagent.*`, `subagent.list`), background
/// processes (`process.list`), and how full its context is (`session.usage`, `session.context_breakdown`).
@MainActor
final class StatusStackModel: ObservableObject {
    struct Todo: Identifiable, Hashable {
        enum Status: String { case pending, inProgress = "in_progress", completed, cancelled }
        let id: String
        var content: String
        var status: Status
        var parent: String?
        /// Nesting under its parent, after `ordered`.
        var depth = 0
    }

    struct Subagent: Identifiable, Hashable {
        let id: String
        var goal: String
        var status: SubagentStatus
        var lastTool: String?
        /// The newest line it streamed.
        var activity: String?
        var startedAt: Date
        var toolCount: Int?
        var acceptsSteer: Bool

        var isLive: Bool { status == .running || status == .queued }
    }

    struct Process: Identifiable, Hashable {
        enum State { case running, done, failed }
        /// The process registry's id (`process_id` for `process.kill`).
        let id: String
        var title: String
        var state: State
        var exitCode: Int?
        var output: String?
    }

    @Published private(set) var todos: [Todo] = []
    /// The last finished list, reviewable once the live one retired.
    @Published private(set) var previousTodos: [Todo] = []
    @Published private(set) var subagents: [Subagent] = []
    @Published private(set) var processes: [Process] = []
    @Published private(set) var usage: Usage?
    @Published private(set) var breakdown: SessionContextBreakdownResult?
    @Published private(set) var loadingBreakdown = false
    @Published var notice: String?

    private let connection: GatewayConnection
    /// Held weakly: the chat owns this model.
    private weak var chat: ChatSending?
    private let profile: String?
    private var listener: UUID?
    private var todoRevision: Int?
    private var dismissed: Set<String> = []
    private var todoLinger: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var session: String?

    /// How long a finished todo list stays before it retires.
    static let todoLinger: TimeInterval = 4
    /// The safety-net poll for processes and subagents while some run (silent exits send no event).
    static let pollInterval: TimeInterval = 5

    init(connection: GatewayConnection, chat: ChatSending, profile: String?) {
        self.connection = connection
        self.chat = chat
        self.profile = profile
        listener = connection.addListener { [weak self] event, sessionID, _ in
            guard let self, let sessionID, sessionID == self.chat?.runtimeSessionID else { return }
            self.handle(event)
        }
    }

    deinit {
        polling?.cancel()
        todoLinger?.cancel()
        let connection = connection, listener = listener
        Task { @MainActor in if let listener { connection.removeListener(listener) } }
    }

    private var client: GatewayClient { connection.client }

    var liveSubagents: [Subagent] { subagents.filter(\.isLive) }
    var hasRunningProcess: Bool { processes.contains { $0.state == .running } }
    var isEmpty: Bool { todos.isEmpty && liveSubagents.isEmpty && processes.isEmpty && previousTodos.isEmpty }

    // MARK: Refreshing

    /// Reads the session's registry snapshots and usage; call when the chat shows, and on a new session.
    func refresh() async {
        guard let sessionID = chat?.runtimeSessionID else { return }
        if sessionID != session {
            session = sessionID
            todos = []
            subagents = []
            processes = []
            usage = nil
            breakdown = nil
            todoRevision = nil
        }
        await refreshProcesses(sessionID)
        await refreshSubagents(sessionID)
        await refreshUsage(sessionID)
    }

    /// Polls while something runs and the stack is on screen; `stopPolling` ends it.
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard let self, !Task.isCancelled, let sessionID = self.chat?.runtimeSessionID else { continue }
                if self.hasRunningProcess { await self.refreshProcesses(sessionID) }
                if !self.liveSubagents.isEmpty { await self.refreshSubagents(sessionID) }
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
    }

    private func refreshProcesses(_ sessionID: String) async {
        guard let result = try? await client.processList(.init(sessionId: sessionID, profile: profile)) else { return }
        reconcile(result.processes ?? [])
    }

    private func refreshSubagents(_ sessionID: String) async {
        guard let result = try? await client.subagentList(.init(sessionId: sessionID, profile: profile)) else { return }
        let snapshot = result.subagents ?? []
        var next: [Subagent] = []
        for item in snapshot {
            var row = subagents.first { $0.id == item.subagentId } ?? Subagent(
                id: item.subagentId, goal: item.goal ?? "", status: item.status ?? .running,
                startedAt: item.startedAt.map { Date(timeIntervalSince1970: $0) } ?? Date(), acceptsSteer: false
            )
            if let goal = item.goal, !goal.isEmpty { row.goal = goal }
            row.status = item.status ?? row.status
            row.lastTool = item.lastTool ?? row.lastTool
            row.toolCount = item.toolCount ?? row.toolCount
            row.acceptsSteer = item.acceptingSteer ?? row.acceptsSteer
            next.append(row)
        }
        subagents = next
    }

    private func refreshUsage(_ sessionID: String) async {
        guard let result = try? await client.sessionUsage(.init(sessionId: sessionID, profile: profile)) else { return }
        usage = Usage(model: result.model, input: result.input, output: result.output, total: result.total,
                      calls: result.calls, compressions: result.compressions, contextUsed: result.contextUsed,
                      contextMax: result.contextMax, contextPercent: result.contextPercent,
                      contextSource: result.contextSource, contextEstimated: result.contextEstimated)
    }

    /// The breakdown behind the context meter.
    func loadBreakdown() async {
        guard let sessionID = chat?.runtimeSessionID else { return }
        loadingBreakdown = true
        defer { loadingBreakdown = false }
        if let result = try? await client.sessionContextBreakdown(.init(sessionId: sessionID, profile: profile)) {
            breakdown = result
        }
        await refreshUsage(sessionID)
    }

    /// Keeps rows in place (status flips happen where they are), appends new processes, and leaves dismissed ones out.
    private func reconcile(_ entries: [ProcessEntry]) {
        let fresh = entries.filter { !dismissed.contains($0.sessionId) }.map { entry -> Process in
            let exited = entry.status == "exited"
            let title = (entry.command ?? "").split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return Process(id: entry.sessionId, title: title.isEmpty ? "background process" : title,
                           state: exited ? (entry.exitCode.map { $0 != 0 } == true ? .failed : .done) : .running,
                           exitCode: entry.exitCode, output: entry.outputTail?.isEmpty == false ? entry.outputTail : nil)
        }
        var byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next = processes.compactMap { byID.removeValue(forKey: $0.id) }
        next += fresh.filter { byID[$0.id] != nil }
        processes = next
        let reported = Set(entries.map(\.sessionId))
        dismissed.formIntersection(reported)
    }

    // MARK: Actions

    /// Kills one background process; its row goes once the kill is confirmed.
    func kill(_ process: Process) async {
        guard let sessionID = chat?.runtimeSessionID else { return }
        do {
            let result = try await client.processKill(.init(sessionId: sessionID, processId: process.id, profile: profile))
            if result.status == .error { notice = result.error ?? "Couldn't stop the process." } else { dismiss(process) }
        } catch is GatewayDecodingError {
            dismiss(process)
        } catch let error as GatewayRPCError where error.code == 4001 {
            dismiss(process)
        } catch {
            notice = "Couldn't stop the process: \(error.localizedDescription)"
        }
    }

    /// Drops a finished process's row and keeps it dropped across refreshes.
    func dismiss(_ process: Process) {
        dismissed.insert(process.id)
        processes.removeAll { $0.id == process.id }
    }

    func interrupt(_ subagent: Subagent) async {
        guard let sessionID = chat?.runtimeSessionID else { return }
        do {
            let result = try await client.subagentInterrupt(.init(sessionId: sessionID, profile: profile, subagentId: subagent.id))
            if !result.found { notice = "That subagent already finished." }
        } catch {
            notice = "Couldn't stop the subagent: \(error.localizedDescription)"
        }
    }

    /// Sends a subagent a correction; true once it was queued for it.
    func steer(_ subagent: Subagent, _ text: String) async -> Bool {
        guard let sessionID = chat?.runtimeSessionID, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let result = try? await client.subagentSteer(.init(sessionId: sessionID, profile: profile, subagentId: subagent.id,
                                                           text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        guard result?.status == .queued else {
            notice = "The subagent didn't take the message."
            return false
        }
        return true
    }

    // MARK: Events

    private func handle(_ event: GatewayEvent) {
        switch event {
        case let .todoUpdated(payload):
            applyTodos(payload.todos, revision: payload.revision)
        case let .toolComplete(payload):
            if let todos = payload.todos { applyTodos(todos, revision: payload.revision) }
            let name = payload.name.lowercased()
            if name.contains("terminal") || name.contains("process"), let sessionID = chat?.runtimeSessionID {
                Task { await refreshProcesses(sessionID) }
            }
        case let .subagentStart(payload), let .subagentSpawnRequested(payload):
            upsert(payload, status: payload.status ?? .running)
        case let .subagentProgress(payload), let .subagentThinking(payload), let .subagentTool(payload):
            upsert(payload, status: payload.status ?? .running)
        case let .subagentComplete(payload):
            upsert(payload, status: payload.status ?? .completed)
        case let .sessionUsage(payload):
            usage = payload.usage
        case .messageComplete:
            if let sessionID = chat?.runtimeSessionID { Task { await refreshUsage(sessionID) } }
        case let .sessionInfo(info):
            if let usage = info.usage { self.usage = usage }
        default:
            break
        }
    }

    private func upsert(_ payload: SubagentEventPayload, status: SubagentStatus) {
        guard let id = payload.subagentId ?? payload.delegationId.map({ "\($0):\(payload.taskIndex)" }) else { return }
        var row = subagents.first { $0.id == id } ?? Subagent(id: id, goal: payload.goal, status: status, startedAt: Date(),
                                                               acceptsSteer: false)
        row.status = status
        if !payload.goal.isEmpty { row.goal = payload.goal }
        if let tool = payload.toolName { row.lastTool = tool }
        if let count = payload.toolCount { row.toolCount = count }
        if let text = (payload.text ?? payload.toolPreview ?? payload.summary)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            row.activity = text.split(separator: "\n").last.map(String.init)
        }
        if let index = subagents.firstIndex(where: { $0.id == id }) { subagents[index] = row } else { subagents.append(row) }
    }

    /// Takes a todo snapshot (newer revisions only). A finished list lingers a moment, then becomes the previous one.
    private func applyTodos(_ raw: [JSONValue], revision: Int?) {
        if let revision, let todoRevision, revision < todoRevision { return }
        if let revision { todoRevision = revision }
        let items = Self.parseTodos(raw)
        todoLinger?.cancel()
        todos = Self.ordered(items)
        guard !items.isEmpty, !items.contains(where: { $0.status == .pending || $0.status == .inProgress }) else { return }
        todoLinger = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.todoLinger * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.previousTodos = self.todos
            self.todos = []
        }
    }

    nonisolated static func parseTodos(_ raw: [JSONValue]) -> [Todo] {
        raw.compactMap { item in
            guard let id = (item["id"]?.stringValue ?? item["id"]?.intValue.map(String.init))?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty,
                  let content = item["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty,
                  let status = item["status"]?.stringValue.flatMap(Todo.Status.init(rawValue:)) else { return nil }
            let parent = item["parent"]?.stringValue?.trimmingCharacters(in: .whitespaces)
            return Todo(id: id, content: content, status: status, parent: parent?.isEmpty == false && parent != id ? parent : nil)
        }
    }

    /// Parents before their children, depth-first (the desktop's `todoTree`); a dangling or cyclic parent leaves
    /// an item at the top level.
    nonisolated static func ordered(_ todos: [Todo]) -> [Todo] {
        let ids = Set(todos.map(\.id))
        var children: [String: [Todo]] = [:]
        var roots: [Todo] = []
        for todo in todos {
            if let parent = todo.parent, ids.contains(parent) { children[parent, default: []].append(todo) } else { roots.append(todo) }
        }
        var out: [Todo] = []
        var seen: Set<String> = []
        func walk(_ todo: Todo, _ depth: Int) {
            guard seen.insert(todo.id).inserted else { return }
            var row = todo
            row.depth = depth
            out.append(row)
            for child in children[todo.id] ?? [] { walk(child, depth + 1) }
        }
        for root in roots { walk(root, 0) }
        for todo in todos where !seen.contains(todo.id) {
            seen.insert(todo.id)
            out.append(todo)
        }
        return out
    }
}
