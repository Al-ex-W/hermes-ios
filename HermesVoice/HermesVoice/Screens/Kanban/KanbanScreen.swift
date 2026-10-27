import SwiftUI

/// A task the sheet shows.
struct KanbanOpenTask: Identifiable, Hashable {
    let id: String
}

/// A move to done that waits for its completion summary.
struct KanbanSummaryRequest: Identifiable {
    let id = UUID()
    /// One card, or nil for the selection.
    let taskID: String?
    let count: Int
}

/// The board dialogs of the switcher.
enum KanbanBoardSheet: Identifiable {
    case new, rename(KanbanBoardMeta), settings(KanbanBoardMeta), importArchive

    var id: String {
        switch self {
        case .new: return "new"
        case let .rename(board): return "rename:\(board.slug)"
        case let .settings(board): return "settings:\(board.slug)"
        case .importArchive: return "import"
        }
    }
}

/// The desktop's Kanban page (`plugins/kanban/board.tsx`), backed by the host's kanban plugin: the board switcher,
/// the filter menu and search, columns in board order with drag-to-move and a "Move to" menu, multi-select with a
/// bulk bar, the new-task dialog and the task sheet, kept live by the plugin's `/events` socket with pull-to-refresh
/// and a slow heartbeat as the fallback. On iPhone the columns page horizontally under a strip of column chips (also
/// drop targets); on iPad they sit side by side and empty lanes fold into rails. Place it inside a
/// `NavigationStack`.
struct KanbanScreen: View {
    /// The sidebar row's label and glyph (the desktop's nav row: "Kanban", codicon `project`).
    static let title = "Kanban"
    static let icon = "rectangle.split.3x1"

    @StateObject private var store: KanbanStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("kanban.introDismissed") private var introDismissed = false

    @State private var openTask: KanbanOpenTask?
    @State private var newTaskLane: KanbanOpenTask?
    @State private var boardSheet: KanbanBoardSheet?
    @State private var showsOrchestration = false
    @State private var showsWorkers = false
    @State private var confirmation: OpsConfirmation?
    @State private var summaryRequest: KanbanSummaryRequest?
    @State private var summaryText = ""
    @State private var pendingMove: (ids: [String], status: String)?
    @State private var page: String?
    @State private var laneOverrides: [String: Bool] = [:]
    @State private var attentionExpanded = false
    @State private var attentionDismissed = false
    /// Bumped when the app returns to the foreground, so the socket dials again at once.
    @State private var liveGeneration = 0

    init(context: KanbanContext) {
        _store = StateObject(wrappedValue: KanbanStore(context: context))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationTitle("Kanban")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .searchable(text: $store.search, prompt: "Filter cards…")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.selecting { KanbanSelectionBar(store: store, requestMove: requestBulkMove, confirmDelete: confirmBulkDelete) }
            }
            .task { await store.load() }
            .task(id: "\(store.effectiveSlug ?? "")|\(liveGeneration)") { await store.runLive() }
            .task { await store.runHeartbeat() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                liveGeneration += 1
                Task { await store.reloadBoard() }
            }
            .sheet(item: $openTask) { open in
                KanbanTaskSheet(store: store, taskID: open.id)
            }
            .sheet(item: $newTaskLane) { lane in
                KanbanNewTaskSheet(store: store, target: lane.id)
            }
            .sheet(item: $boardSheet) { sheet in
                KanbanBoardDialog(store: store, sheet: sheet)
            }
            .sheet(isPresented: $showsOrchestration) { KanbanOrchestrationSheet(store: store) }
            .sheet(isPresented: $showsWorkers) {
                KanbanWorkersSheet(store: store) { id in
                    showsWorkers = false
                    openTask = KanbanOpenTask(id: id)
                }
            }
            .alert("Completion summary", isPresented: Binding(get: { summaryRequest != nil },
                                                              set: { if !$0 { summaryRequest = nil } }),
                   presenting: summaryRequest) { request in
                TextField("What was done", text: $summaryText, axis: .vertical)
                Button("Mark done") { finishSummary(request) }
                    .disabled(summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    pendingMove = nil
                    pendingBulkStatus = nil
                }
            } message: { request in
                Text("Completion summary for \(request.count > 1 ? "\(request.count) selected tasks" : "this task"). This is stored as the task result.")
            }
            .opsConfirm($confirmation)
            .failureAlert($store.failure)
            .opsToast($store.notice)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let board = store.visibleBoard {
            VStack(spacing: 0) {
                banners(board)
                if board.total == 0 {
                    empty
                } else if sizeClass == .compact {
                    pagedColumns(board)
                } else {
                    sideBySide(board)
                }
            }
        } else if let error = store.loadError {
            ContentUnavailableView {
                Label("Failed to load the board", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.load() } }
            }
        } else {
            ProgressView().accessibilityLabel("Loading")
        }
    }

    private var empty: some View {
        let filtered = !store.search.isEmpty || !store.tenant.isEmpty || !store.assignee.isEmpty
        return ScrollView {
            ContentUnavailableView {
                Label(filtered ? "No tasks match the filters" : "No tasks on this board", systemImage: "square.grid.3x1.below.line.grid.1x2")
            } actions: {
                Button { newTaskLane = KanbanOpenTask(id: "triage") } label: { Label("New task", systemImage: "plus") }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 80)
        }
        .refreshable { await store.refresh() }
    }

    @ViewBuilder private func banners(_ board: KanbanBoard) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            if !introDismissed { intro }
            attention(board)
            if store.live == .unavailable || store.live == .offline {
                Label(store.live == .unavailable ? "Live updates are off — pull to refresh." : "Reconnecting to live updates…",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.sm)
    }

    /// One-time explainer: this is a dispatcher queue, not a to-do list.
    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("You don’t run the cards — agents do. Put a card in Ready with an assignee and an agent picks it up within a minute. No assignee, no run. Triage: an agent rewrites the idea into a proper task first. Todo: waiting on other cards. Scheduled: waiting on a timer. Running and Review: the agents’ lanes, hands off. Blocked: it’s waiting on you. Results come back on the card.")
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.secondary)
            Button("Got it") { introDismissed = true }
                .hermesText(.button)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Fill.quinary, in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
    }

    /// The dashboard's attention strip: every card with active diagnostics, worst first.
    @ViewBuilder private func attention(_ board: KanbanBoard) -> some View {
        let tasks = attentionTasks(store.board ?? board)
        if !tasks.isEmpty, !attentionDismissed {
            let worst = tasks.first?.warnings?.highestSeverity
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: Theme.Icon.warning).foregroundStyle(KanbanTone.severity(worst))
                    Text(tasks.count == 1 ? "1 task needs attention" : "\(tasks.count) tasks need attention")
                        .hermesText(.rowTitle)
                    Spacer(minLength: 0)
                    Button(attentionExpanded ? "Hide" : "Show") { withAnimation { attentionExpanded.toggle() } }
                        .hermesText(.button)
                    Button { attentionDismissed = true } label: { Image(systemName: Theme.Icon.close) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityLabel("Dismiss")
                }
                if attentionExpanded {
                    ForEach(tasks) { task in
                        Button { openTask = KanbanOpenTask(id: task.id) } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                OpsDot(color: KanbanTone.severity(task.warnings?.highestSeverity), size: 6)
                                Text(task.title.isEmpty ? task.id : task.title).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(task.assignee.map { "@\($0)" } ?? "unassigned")
                                    .foregroundStyle(Theme.Text.tertiary)
                            }
                            .hermesText(.caption)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.Spacing.md)
            .background(KanbanTone.severity(worst).opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
        }
    }

    private func attentionTasks(_ board: KanbanBoard) -> [KanbanTask] {
        func rank(_ severity: String?) -> Int {
            switch severity { case "critical": return 3; case "error": return 2; default: return 1 }
        }
        return board.allTasks.filter { !$0.diagnostics.isEmpty || $0.warnings != nil }.sorted {
            let left = rank($0.warnings?.highestSeverity), right = rank($1.warnings?.highestSeverity)
            if left != right { return left > right }
            return ($0.warnings?.latestAt ?? 0) > ($1.warnings?.latestAt ?? 0)
        }
    }

    // MARK: Layouts

    /// iPhone: one column per page under a strip of column chips that also take drops.
    private func pagedColumns(_ board: KanbanBoard) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(board.columns) { column in
                            KanbanColumnChip(column: column, current: (page ?? board.columns.first?.name) == column.name,
                                             drop: drop) {
                                withAnimation { page = column.name }
                            }
                            .id(column.name)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .onChange(of: page) { _, name in
                    if let name { withAnimation { reader.scrollTo(name, anchor: .center) } }
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(board.columns) { column in
                        KanbanColumnView(store: store, column: column, actions: actions, showsHeader: false)
                            .padding(.horizontal, Theme.Spacing.md)
                            .containerRelativeFrame(.horizontal)
                            .id(column.name)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
        }
    }

    /// iPad: lanes side by side; empty lanes fold into rails unless opened (on a board with work at all).
    private func sideBySide(_ board: KanbanBoard) -> some View {
        let hasWork = (store.board?.total ?? 0) > 0
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ForEach(board.columns) { column in
                    let auto = hasWork && column.tasks.isEmpty
                    if laneOverrides[column.name] ?? auto {
                        KanbanColumnRail(column: column, expand: { toggleLane(column.name, auto: auto) }, drop: drop)
                    } else {
                        KanbanColumnView(store: store, column: column, actions: actions,
                                         onCollapse: { toggleLane(column.name, auto: auto) })
                            .frame(width: 290)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func toggleLane(_ name: String, auto: Bool) {
        let next = !(laneOverrides[name] ?? auto)
        withAnimation(.easeOut(duration: 0.2)) { laneOverrides[name] = next == auto ? nil : next }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            KanbanBoardSwitcher(store: store, open: { boardSheet = $0 }, confirmDelete: confirmBoardDelete)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { newTaskLane = KanbanOpenTask(id: "triage") } label: { Image(systemName: "plus") }
                .accessibilityLabel("New task")
                .disabled(store.board == nil)
            filterMenu
            Menu {
                Button {
                    if store.selecting { store.clearSelection() } else { store.selecting = true }
                } label: {
                    Label(store.selecting ? "Done selecting" : "Select cards", systemImage: "checkmark.circle")
                }
                Button { showsOrchestration = true } label: {
                    Label("Orchestration settings", systemImage: "person.3")
                }
                Button { showsWorkers = true } label: {
                    Label("Active workers", systemImage: "cpu")
                }
                Button { Task { await store.nudgeNow() } } label: {
                    Label("Nudge dispatcher", systemImage: "bolt")
                }
            } label: {
                Image(systemName: Theme.Icon.more)
            }
            .accessibilityLabel("More")
        }
    }

    private var filterMenu: some View {
        Menu {
            if let board = store.board {
                Section {
                    Picker("Profile", selection: $store.assignee) {
                        Text("All profiles").tag("")
                        ForEach(board.assignees, id: \.self) { Text($0).tag($0) }
                    }
                }
                if !board.tenants.isEmpty {
                    Section {
                        Picker("Tenant", selection: $store.tenant) {
                            Text("All tenants").tag("")
                            ForEach(board.tenants, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }
            Section {
                Toggle("Show archived", isOn: $store.showArchived)
                Toggle("Group Running by profile", isOn: $store.lanesByProfile)
            }
        } label: {
            Image(systemName: store.filtersActive ? "line.3.horizontal.decrease.circle.fill" : Theme.Icon.filter)
        }
        .accessibilityLabel("Filters")
    }

    // MARK: Actions

    private var actions: KanbanCardActions {
        KanbanCardActions(
            open: { openTask = KanbanOpenTask(id: $0.id) },
            toggleSelect: { store.toggleSelected($0.id) },
            move: { requestMove([$0.id], to: $1) },
            delete: { task in
                confirmation = OpsConfirmation(title: "Delete task?",
                                               message: "Permanently delete this task? This cannot be undone.",
                                               confirmLabel: "Delete") { await store.deleteTask(task.id) }
            },
            add: { newTaskLane = KanbanOpenTask(id: $0) },
            drop: drop)
    }

    /// Cards dragged onto a column or chip: locked columns refuse, the rest move like the menu.
    private func drop(_ ids: [String], _ status: String) -> Bool {
        let known = ids.filter { store.task($0) != nil }
        guard !known.isEmpty else { return false }
        guard store.workflow.isDropTarget(status) else {
            store.notice = OpsNotice(title: "Can’t move there", message: KanbanColumns.lockedReason(status))
            return false
        }
        // Dragging a selected card carries the whole selection, as on the dashboard.
        if known.count == 1, store.selected.contains(known[0]), store.selected.count > 1 {
            requestBulkMove(status)
        } else {
            requestMove(known, to: status)
        }
        return true
    }

    private func requestMove(_ ids: [String], to status: String) {
        let tasks = ids.compactMap(store.task).filter { $0.status != status }
        guard !tasks.isEmpty else { return }
        if KanbanMoveRules.needsSummary(tasks, to: status) {
            pendingMove = (tasks.map(\.id), status)
            summaryText = ""
            summaryRequest = KanbanSummaryRequest(taskID: tasks.count == 1 ? tasks[0].id : nil, count: tasks.count)
            return
        }
        Task { for task in tasks { await store.move(task.id, to: status) } }
    }

    private func requestBulkMove(_ status: String) {
        let tasks = store.selectedTasks
        guard !tasks.isEmpty else { return }
        if KanbanMoveRules.needsSummary(tasks, to: status) {
            pendingMove = nil
            summaryText = ""
            summaryRequest = KanbanSummaryRequest(taskID: nil, count: tasks.count)
            pendingBulkStatus = status
            return
        }
        Task { await store.applyBulk(.move(to: status)) }
    }

    @State private var pendingBulkStatus: String?

    private func finishSummary(_ request: KanbanSummaryRequest) {
        let summary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return }
        if let move = pendingMove {
            pendingMove = nil
            Task { for id in move.ids { await store.move(id, to: move.status, summary: summary) } }
        } else if let status = pendingBulkStatus {
            pendingBulkStatus = nil
            Task { await store.applyBulk(.move(to: status, summary: summary)) }
        }
    }

    private func confirmBulkDelete() {
        let count = store.selected.count
        confirmation = OpsConfirmation(title: count == 1 ? "Delete task?" : "Delete \(count) tasks?",
                                       message: "Permanently delete \(count == 1 ? "this task" : "\(count) selected tasks")? This cannot be undone.",
                                       confirmLabel: "Delete") { await store.deleteSelected() }
    }

    private func confirmBoardDelete(_ board: KanbanBoardMeta) {
        confirmation = OpsConfirmation(title: "Delete “\(board.name)”?",
                                       message: "The board is archived, not erased — its tasks and attachments stay on the host and can be restored.",
                                       confirmLabel: "Delete") { await store.deleteBoard(board.slug) }
    }
}

/// A column chip of the iPhone strip: tone dot, label, count; tap to page there, drop a card to move it there.
private struct KanbanColumnChip: View {
    let column: KanbanColumn
    let current: Bool
    let drop: ([String], String) -> Bool
    let select: () -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: Theme.Spacing.xs) {
                OpsDot(color: KanbanTone.color(column.name), size: 6)
                Text(KanbanColumns.label(column.name))
                Text("\(column.tasks.count)").monospacedDigit().foregroundStyle(Theme.Text.quaternary)
            }
            .hermesText(.button)
            .foregroundStyle(current ? Theme.Text.primary : Theme.Text.tertiary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(targeted ? Theme.Fill.primary : current ? Theme.Fill.secondary : Theme.Fill.quinary,
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityHint(KanbanColumns.help(column.name))
        .dropDestination(for: String.self) { ids, _ in drop(ids, column.name) } isTargeted: { targeted = $0 }
    }
}

/// The floating bulk bar while cards are selected: move, assign, archive, delete.
private struct KanbanSelectionBar: View {
    @ObservedObject var store: KanbanStore
    let requestMove: (String) -> Void
    let confirmDelete: () -> Void

    var body: some View {
        let busy = store.bulkBusy || store.selected.isEmpty
        HStack(spacing: Theme.Spacing.md) {
            Text("\(store.selected.count) selected")
                .hermesText(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.secondary)
            Spacer(minLength: 0)
            Menu("Move to") {
                ForEach(moveTargets, id: \.self) { status in
                    Button { requestMove(status) } label: {
                        Label(KanbanColumns.label(status), systemImage: KanbanTone.icon(status))
                    }
                }
            }
            .disabled(busy)
            Menu("Assign") {
                ForEach(store.profiles) { profile in
                    Button(profile.name) { Task { await store.applyBulk(.assign(profile.name)) } }
                }
                Divider()
                Button("Unassign") { Task { await store.applyBulk(.assign(nil)) } }
            }
            .disabled(busy)
            Button("Archive") { Task { await store.applyBulk(.archiveAll) } }
                .disabled(busy)
            Button(role: .destructive, action: confirmDelete) { Image(systemName: Theme.Icon.delete) }
                .disabled(busy)
                .accessibilityLabel("Delete")
            Button { store.clearSelection() } label: { Image(systemName: Theme.Icon.close) }
                .accessibilityLabel("Clear selection")
        }
        .hermesText(.button)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .hermesFloating(radius: Theme.Radius.widget)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .overlay { if store.bulkBusy { ProgressView() } }
    }

    private var moveTargets: [String] {
        let shown = store.board?.columns.map(\.name) ?? KanbanColumns.order
        return shown.filter { store.workflow.isDropTarget($0) }
    }
}

/// The board switcher (the desktop's page-header control): the boards with their counts, then rename, settings,
/// new, export, import, and delete for any board but `default`.
private struct KanbanBoardSwitcher: View {
    @ObservedObject var store: KanbanStore
    let open: (KanbanBoardSheet) -> Void
    let confirmDelete: (KanbanBoardMeta) -> Void

    var body: some View {
        Menu {
            if let list = store.boards {
                Section {
                    ForEach(list.boards) { board in
                        Button { store.switchBoard(to: board.slug) } label: {
                            if board.slug == store.effectiveSlug {
                                Label(title(board), systemImage: "checkmark")
                            } else {
                                Text(title(board))
                            }
                        }
                    }
                }
                Section {
                    if let current = store.currentBoard {
                        Button { open(.rename(current)) } label: { Label("Rename…", systemImage: Theme.Icon.rename) }
                        Button { open(.settings(current)) } label: { Label("Settings…", systemImage: Theme.Icon.settings) }
                    }
                    Button { open(.new) } label: { Label("New board…", systemImage: "plus") }
                }
                Section {
                    if let current = store.currentBoard {
                        Button { Task { await store.exportBoard(current.slug) } } label: {
                            Label("Export…", systemImage: "shippingbox")
                        }
                    }
                    Button { open(.importArchive) } label: { Label("Import…", systemImage: "icloud.and.arrow.down") }
                }
                if let current = store.currentBoard, current.slug != KanbanAPI.defaultBoard {
                    Section {
                        Button(role: .destructive) { confirmDelete(current) } label: {
                            Label("Delete", systemImage: Theme.Icon.delete)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(label).hermesText(.rowTitle).lineLimit(1)
                if let total = store.currentBoard?.total {
                    Text("\(total)").hermesText(.meta).monospacedDigit().foregroundStyle(Theme.Text.quaternary)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.Text.tertiary)
            }
            .foregroundStyle(Theme.Text.primary)
        }
        .accessibilityLabel("Board: \(label)")
        .accessibilityHint("Switch board")
    }

    private var label: String { store.currentBoard?.name ?? store.effectiveSlug ?? "Board" }

    private func title(_ board: KanbanBoardMeta) -> String {
        board.total.map { "\(board.name)  \($0)" } ?? board.name
    }
}
