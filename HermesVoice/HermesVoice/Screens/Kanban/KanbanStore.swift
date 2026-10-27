import SwiftUI

/// What the Kanban screen talks to: the dashboard's kanban plugin routes and its `/events` socket. Boards are shared
/// by every profile on the host, so the screen has no profile scope.
@MainActor
final class KanbanContext: ObservableObject {
    let transport: KanbanTransport
    let dialer: KanbanEventDialing?
    /// Where the picked board is remembered (one per host); nil remembers nothing.
    let storageKey: String?

    init(transport: KanbanTransport, dialer: KanbanEventDialing?, storageKey: String?) {
        self.transport = transport
        self.dialer = dialer
        self.storageKey = storageKey
    }

    /// The signed-in dashboard.
    convenience init(client: DashboardClient) {
        self.init(transport: client, dialer: KanbanSocketDialer(client: client),
                  storageKey: "kanban.board.\(client.base.host ?? "host")")
    }
}

/// The board page's state (`board.tsx`, `api.ts` on the desktop): the boards on the host and the one picked, its
/// snapshot with optimistic edits on top, the toolbar's filters, the multi-select, and the live `/events` stream
/// that keeps it current. Every write nudges the dispatcher so it runs now instead of on its next tick.
@MainActor
final class KanbanStore: ObservableObject {
    enum Live: Equatable {
        case idle, connecting, live, offline
        /// The host refused the socket repeatedly: the board updates on pull-to-refresh and the heartbeat.
        case unavailable
    }

    let context: KanbanContext

    @Published private(set) var boards: KanbanBoardList?
    /// The board picked here; "" follows the host's current board.
    @Published private(set) var selectedSlug: String
    @Published private(set) var board: KanbanBoard?
    @Published private(set) var loadError: String?
    @Published private(set) var workflow = KanbanWorkflow.standard
    @Published private(set) var orchestration: KanbanOrchestration?
    @Published private(set) var profiles: [KanbanProfile] = []
    @Published private(set) var projects: [KanbanProject] = []
    @Published private(set) var live = Live.idle
    /// Per-task event counters: an open task sheet reloads when its own ticks.
    @Published private(set) var taskTicks: [String: Int] = [:]

    // Filters (the toolbar's search and filter menu).
    @Published var search = ""
    @Published var tenant = ""
    @Published var assignee = ""
    @Published var showArchived = false {
        didSet { if showArchived != oldValue { Task { await reloadBoard() } } }
    }
    @Published var lanesByProfile: Bool {
        didSet { UserDefaults.standard.set(lanesByProfile, forKey: "kanban.lanesByProfile") }
    }

    // Multi-select.
    @Published var selecting = false
    @Published var selected: Set<String> = []
    @Published private(set) var bulkBusy = false

    @Published var notice: OpsNotice?
    @Published var failure: String?

    private var generation = 0
    private var reloadTask: Task<Void, Never>?
    private var nudgeTask: Task<Void, Never>?
    /// The last frame cursor seen per board, so a reconnect replays only what was missed.
    private var cursors: [String: Int] = [:]

    init(context: KanbanContext) {
        self.context = context
        selectedSlug = context.storageKey.flatMap { UserDefaults.standard.string(forKey: $0) } ?? ""
        lanesByProfile = UserDefaults.standard.bool(forKey: "kanban.lanesByProfile")
    }

    var api: KanbanAPI { KanbanAPI(transport: context.transport, board: effectiveSlug) }

    /// The board every call names: the picked one, else the host's current one once the list is in.
    var effectiveSlug: String? { selectedSlug.isEmpty ? boards?.current : selectedSlug }

    var currentBoard: KanbanBoardMeta? { effectiveSlug.flatMap { boards?.board($0) } }

    /// The snapshot as the filters show it.
    var visibleBoard: KanbanBoard? { board?.filtered(search: search, tenant: tenant, assignee: assignee) }

    var filtersActive: Bool { !tenant.isEmpty || !assignee.isEmpty || showArchived }

    /// `kanban.default_assignee`: who an unassigned ready card goes to ("" when unset: it never runs).
    var defaultAssignee: String { orchestration?.defaultAssignee ?? "" }

    func task(_ id: String) -> KanbanTask? { board?.task(id) }

    func targets(for task: KanbanTask) -> [String] {
        let shown = Set(board?.columns.map(\.name) ?? KanbanColumns.order)
        return workflow.targets(from: task.status).filter { shown.contains($0) }
    }

    // MARK: Loading

    /// The boards, the picked board's snapshot and the settings the cards read.
    func load() async {
        await loadBoards()
        async let snapshot: Void = reloadBoard()
        async let settings: Void = loadSettings()
        _ = await (snapshot, settings)
    }

    func loadBoards() async {
        do {
            let list = try await api.boards()
            boards = list
            // A board deleted elsewhere: follow the host's current board instead of a 404.
            if !selectedSlug.isEmpty, list.board(selectedSlug) == nil { select("") }
        } catch {
            if board == nil, !error.isCancellation, boards == nil { loadError = error.dashboardMessage }
        }
    }

    func loadSettings() async {
        let api = self.api
        async let workflow = try? api.workflow()
        async let orchestration = try? api.orchestration()
        async let profiles = try? api.profiles()
        if let value = await workflow { self.workflow = value }
        if let value = await orchestration { self.orchestration = value }
        if let value = await profiles { self.profiles = value }
    }

    func loadProjects() async {
        if let rows = try? await api.projects() { projects = rows }
    }

    /// Reads the snapshot again. A failure shows only when there's nothing to show, or when asked for.
    func reloadBoard(userInitiated: Bool = false) async {
        generation += 1
        let mine = generation
        let slug = effectiveSlug
        do {
            let snapshot = try await api.boardSnapshot(includeArchived: showArchived)
            guard mine == generation, slug == effectiveSlug else { return }
            board = snapshot
            loadError = nil
            pruneSelection()
        } catch {
            guard mine == generation, !error.isCancellation else { return }
            if board == nil { loadError = error.dashboardMessage } else if userInitiated { failure = error.dashboardMessage }
        }
    }

    /// Pull-to-refresh.
    func refresh() async {
        await loadBoards()
        async let snapshot: Void = reloadBoard(userInitiated: true)
        async let settings: Void = loadSettings()
        _ = await (snapshot, settings)
    }

    /// One read for a burst of events (the dashboard's 250 ms debounce).
    func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil
            await self.reloadBoard()
            await self.loadBoards()
        }
    }

    // MARK: Boards

    /// Picks a board; the host's current one is followed rather than pinned (the desktop's switcher).
    func switchBoard(to slug: String) {
        let target = slug == boards?.current ? "" : slug
        guard target != selectedSlug else { return }
        select(target)
        board = nil
        loadError = nil
        search = ""
        tenant = ""
        assignee = ""
        if showArchived { showArchived = false }
        clearSelection()
        Task { await reloadBoard() }
    }

    private func select(_ slug: String) {
        selectedSlug = slug
        guard let key = context.storageKey else { return }
        if slug.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(slug, forKey: key) }
    }

    func createBoard(_ draft: KanbanNewBoard) async -> Bool {
        do {
            let meta = try await api.createBoard(draft)
            await loadBoards()
            switchBoard(to: meta?.slug ?? draft.slug)
            return true
        } catch {
            failure = error.dashboardMessage
            return false
        }
    }

    func renameBoard(_ slug: String, name: String) async -> Bool {
        do {
            _ = try await api.updateBoard(slug, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
            await loadBoards()
            return true
        } catch {
            failure = error.dashboardMessage
            return false
        }
    }

    /// Scopes the board to a project ("" clears it, which also drops the mirrored directory on the host).
    func setProject(_ slug: String, projectID: String) async -> Bool {
        do {
            _ = try await api.updateBoard(slug, projectID: projectID)
            await loadBoards()
            return true
        } catch {
            failure = error.dashboardMessage
            return false
        }
    }

    /// Archives the board on the host (recoverable there); the host reverts to `default`, so the picker follows it.
    func deleteBoard(_ slug: String) async {
        do {
            let removal = try await api.deleteBoard(slug)
            select("")
            board = nil
            await loadBoards()
            await reloadBoard()
            notice = OpsNotice(title: "Board archived", message: removal.newPath)
        } catch {
            failure = error.dashboardMessage
        }
    }

    func exportBoard(_ slug: String) async {
        do {
            let result = try await api.exportBoard(slug)
            notice = OpsNotice(title: "Board exported", message: result.archive.isEmpty ? nil : "On the host: \(result.archive)")
        } catch {
            failure = error.dashboardMessage
        }
    }

    func importBoard(archive: String) async -> Bool {
        do {
            let result = try await api.importBoard(archive: archive.trimmingCharacters(in: .whitespacesAndNewlines))
            await loadBoards()
            if !result.board.isEmpty { switchBoard(to: result.board) }
            var lines: [String] = []
            if result.renamed { lines.append("That name was taken — imported as \(result.board).") }
            lines.append(contentsOf: result.warnings)
            notice = OpsNotice(title: "Imported \(result.name)", message: lines.isEmpty ? nil : lines.joined(separator: " "))
            return true
        } catch {
            failure = error.dashboardMessage
            return false
        }
    }

    // MARK: Moves

    /// Moves one card (optimistic, rolled back with the host's reason when it refuses the transition).
    func move(_ id: String, to status: String, summary: String? = nil) async {
        guard let task = board?.task(id), task.status != status else { return }
        guard workflow.isDropTarget(status) || status == KanbanColumns.archived else {
            notice = OpsNotice(title: "Can’t move there", message: KanbanColumns.lockedReason(status))
            return
        }
        let previous = board
        board = board?.moving(id, to: status)
        do {
            try await api.patchTask(id, .move(to: status, summary: summary))
            nudge()
        } catch {
            if !error.isCancellation {
                board = previous
                failure = error.dashboardMessage
            }
        }
        await reloadBoard()
        bump([id])
    }

    // MARK: Selection and bulk

    func toggleSelected(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        if !selected.isEmpty { selecting = true }
    }

    func clearSelection() {
        selected = []
        selecting = false
    }

    var selectedTasks: [KanbanTask] { board?.allTasks.filter { selected.contains($0.id) } ?? [] }

    /// Drops ids that left the board, so the bar's count never lies about what a bulk action hits.
    private func pruneSelection() {
        guard !selected.isEmpty, let board else { return }
        let alive = Set(board.allTasks.map(\.id))
        let kept = selected.intersection(alive)
        if kept.count != selected.count { selected = kept }
    }

    /// One patch for every selected card; the ones the host refused stay selected.
    func applyBulk(_ patch: KanbanBulkPatch) async {
        let ids = Array(selected)
        guard !ids.isEmpty, !bulkBusy else { return }
        bulkBusy = true
        defer { bulkBusy = false }
        if let status = patch.status { board = board?.movingAll(selected, to: status) }
        if patch.archive, !showArchived { board = board?.removing(selected) }
        do {
            let results = try await api.bulk(ids, patch)
            let failed = results.filter { !$0.ok }
            finishBulk(failed: failed.map(\.id), total: ids.count, firstError: failed.first?.error)
            nudge()
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
        }
        await reloadBoard()
        bump(Set(ids))
    }

    /// Deletes every selected card (the host has no bulk delete: one call each, the same partial-failure story).
    func deleteSelected() async {
        let ids = Array(selected)
        guard !ids.isEmpty, !bulkBusy else { return }
        bulkBusy = true
        defer { bulkBusy = false }
        board = board?.removing(selected)
        var failed: [String] = []
        var firstError: String?
        for id in ids {
            do {
                try await api.deleteTask(id)
            } catch {
                failed.append(id)
                if firstError == nil { firstError = error.dashboardMessage }
            }
        }
        finishBulk(failed: failed, total: ids.count, firstError: firstError)
        nudge()
        await reloadBoard()
    }

    private func finishBulk(failed: [String], total: Int, firstError: String?) {
        if failed.isEmpty {
            clearSelection()
        } else {
            selected = Set(failed)
            failure = "\(failed.count) of \(total) failed — \(firstError ?? "refused"). Failed cards stay selected."
        }
    }

    // MARK: Single-card writes

    func deleteTask(_ id: String) async {
        let previous = board
        board = board?.removing([id])
        selected.remove(id)
        do {
            try await api.deleteTask(id)
            nudge()
        } catch {
            if !error.isCancellation {
                board = previous
                failure = error.dashboardMessage
            }
        }
        await reloadBoard()
    }

    /// Creates a card in `target` (the host derives triage or ready; a different column is a move after it).
    func createTask(_ draft: KanbanNewTask, in target: String) async throws {
        let result = try await api.createTask(draft)
        if let task = result.task, task.status != target {
            try await api.patchTask(task.id, .move(to: target))
        }
        if let warning = result.warning { notice = OpsNotice(title: "Task created", message: warning) }
        nudge()
        await reloadBoard()
        await loadBoards()
    }

    /// A write made elsewhere (the task sheet, which reloads itself): read the board again and nudge the dispatcher.
    func didWrite(_ id: String?) {
        nudge()
        scheduleReload()
    }

    // MARK: Orchestration

    func saveOrchestration(_ patch: JSON) async {
        do {
            orchestration = try await api.saveOrchestration(patch)
        } catch {
            failure = error.dashboardMessage
        }
    }

    func saveProfileDescription(_ name: String, _ text: String) async -> Bool {
        do {
            try await api.saveProfileDescription(name, text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let rows = try? await api.profiles() { profiles = rows }
            return true
        } catch {
            failure = error.dashboardMessage
            return false
        }
    }

    /// Writes a description with the auxiliary model; returns it.
    func autoDescribe(_ name: String) async -> String? {
        do {
            let outcome = try await api.autoDescribeProfile(name)
            guard outcome.ok else {
                notice = OpsNotice(title: "Auto-describe failed", message: outcome.reason)
                return nil
            }
            if let rows = try? await api.profiles() { profiles = rows }
            return outcome.description ?? ""
        } catch {
            failure = error.dashboardMessage
            return nil
        }
    }

    // MARK: Dispatcher

    /// Kicks the dispatcher 400 ms after the last write (debounced, fire-and-forget; the tick still runs anyway).
    func nudge() {
        nudgeTask?.cancel()
        let api = self.api
        nudgeTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await api.dispatch()
        }
    }

    /// The toolbar's explicit nudge.
    func nudgeNow() async {
        do {
            try await api.dispatch()
            notice = OpsNotice(title: "Dispatcher nudged")
            await reloadBoard()
        } catch {
            failure = error.dashboardMessage
        }
    }

    // MARK: Live events

    private func bump(_ ids: Set<String>) {
        for id in ids { taskTicks[id, default: 0] += 1 }
    }

    /// One frame of the `/events` stream for `slug` (nil: the host's current board): the cursor advances, the
    /// events apply to the snapshot, the touched tasks tick, and one reload reconciles.
    func handle(frame: KanbanEventFrame, slug: String?) {
        if let cursor = frame.cursor { cursors[slug ?? ""] = max(cursors[slug ?? ""] ?? 0, cursor) }
        guard slug == effectiveSlug, !frame.events.isEmpty else { return }
        var effect = KanbanEventEffect(touched: Set(frame.events.compactMap(\.taskID)), needsReload: true)
        if var current = board {
            let notice = KanbanTerminalEvents.notice(frame.events, after: current.latestEventID, board: current)
            effect = current.apply(frame.events)
            board = current
            effect.touched.formUnion(frame.events.compactMap(\.taskID))
            if let notice { self.notice = notice }
        }
        bump(effect.touched)
        if effect.needsReload { scheduleReload() }
    }

    /// Where a socket for `slug` resumes: the newer of the last frame seen and the snapshot's tail.
    func resumeCursor(for slug: String?) -> Int? {
        let snapshot = slug == effectiveSlug ? board?.latestEventID : nil
        switch (cursors[slug ?? ""], snapshot) {
        case let (seen?, tail?): return max(seen, tail)
        case let (seen?, nil): return seen
        case let (nil, tail?): return tail
        default: return nil
        }
    }

    /// Keeps the `/events` socket open for the current board until cancelled (the view's task ends, or the board
    /// changes), dialling again with backoff. Without a snapshot yet it waits for one, so it never replays history.
    func runLive() async {
        guard let dialer = context.dialer else { return }
        var policy = KanbanReconnectPolicy()
        while !Task.isCancelled {
            guard board != nil || loadError != nil else {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            let slug = effectiveSlug
            live = .connecting
            var connection: KanbanEventConnection?
            var ending = KanbanSocketEnding.dropped
            var opened = false
            do {
                let socket = try await dialer.dial(board: slug, since: resumeCursor(for: slug))
                connection = socket
                // A pending receive ignores task cancellation: closing the socket is what ends it.
                try await withTaskCancellationHandler {
                    try await socket.confirmOpen()
                    opened = true
                    policy.opened()
                    live = .live
                    while !Task.isCancelled {
                        let text = try await socket.receive()
                        if let frame = KanbanEventFrame(text: text) { handle(frame: frame, slug: slug) }
                    }
                } onCancel: {
                    socket.abort()
                }
            } catch {
                ending = connection?.ending ?? (error.isRefusal ? .refused : .dropped)
            }
            connection?.close()
            if Task.isCancelled { break }
            if ending == .policy {
                // The host closed the stream as stale: the board was archived or deleted elsewhere.
                await loadBoards()
                await reloadBoard()
            }
            let delay = policy.failed(refused: ending == .refused || (!opened && ending == .policy))
            if policy.stopped {
                live = .unavailable
                return
            }
            live = .offline
            try? await Task.sleep(for: .seconds(delay))
        }
        if live != .unavailable { live = .idle }
    }

    /// The slow read for socketless stretches (the desktop's 60 s refetch), while the screen shows.
    func runHeartbeat() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await reloadBoard()
        }
    }
}
