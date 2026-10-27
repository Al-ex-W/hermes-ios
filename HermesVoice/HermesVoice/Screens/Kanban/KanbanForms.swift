import SwiftUI

// The board's dialogs as sheets: new task, the switcher's board dialogs, orchestration settings, active workers.

/// New task in a column (`NewTaskDialog`): title and description, priority, workspace, assignee (the orchestration
/// default, a profile, or parked), skills, model, parent and goal mode, with an optional effort estimate.
struct KanbanNewTaskSheet: View {
    @ObservedObject var store: KanbanStore
    let target: String
    @Environment(\.dismiss) private var dismiss

    private static let parked = "__parked__"

    @State private var title = ""
    @State private var bodyText = ""
    @State private var priority = 0
    @State private var workspaceKind = ""
    @State private var workspacePath = ""
    /// "" is the orchestration default; `parked` leaves it unassigned.
    @State private var assignee = ""
    @State private var skills = ""
    @State private var parent = ""
    @State private var goalMode = false
    @State private var modelOverride = KanbanModelOverride.inherit
    @State private var providers: [KanbanModelProvider]?
    @State private var busy = false
    @State private var error: String?
    @State private var estimate: KanbanEstimate?
    @State private var estimating = false
    @FocusState private var titleFocused: Bool

    private var isTriage: Bool { target == "triage" }
    private var boardDefaultKind: String { store.currentBoard?.defaultWorkspaceKind ?? "scratch" }
    private var boardDefaultDir: String? { store.currentBoard?.defaultWorkdir }
    private var resolvedDefault: String { store.orchestration?.resolvedDefaultAssignee ?? "default" }
    private var kind: String { workspaceKind.isEmpty ? boardDefaultKind : workspaceKind }
    private var canCreate: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isTriage ? "Rough idea — a specifier will flesh it out" : "Title", text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .focused($titleFocused)
                    TextField("Description (optional)", text: $bodyText, axis: .vertical)
                        .lineLimit(3...10)
                }
                .hermesFormRows()

                Section {
                    Stepper(value: $priority, in: -10...100) {
                        LabeledContent("Priority") { KanbanPriority(priority: priority) }
                    }
                    Picker("Workspace", selection: $workspaceKind) {
                        ForEach(["scratch", "worktree", "dir"], id: \.self) { kind in
                            Text(kind + (kind == boardDefaultKind ? " · board default" : "")).tag(kind == boardDefaultKind ? "" : kind)
                        }
                    }
                    if kind != "scratch" {
                        TextField(boardDefaultDir ?? "Workspace path (optional override)", text: $workspacePath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                    Picker("Assignee", selection: $assignee) {
                        Text("\(resolvedDefault) (default)").tag("")
                        ForEach(store.profiles.filter { $0.name != resolvedDefault }) { Text($0.name).tag($0.name) }
                        Text("unassigned (parked — won't run)").tag(Self.parked)
                    }
                    LabeledContent("Model") {
                        KanbanModelMenu(value: modelOverride, providers: providers, load: loadProviders) { modelOverride = $0 }
                    }
                    TextField("Skills (comma-separated)", text: $skills, prompt: Text("translation, github"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let tasks = store.board?.allTasks, !tasks.isEmpty {
                        Picker("Parent", selection: $parent) {
                            Text("— no parent —").tag("")
                            ForEach(tasks) { Text($0.title.isEmpty ? $0.id : $0.title).lineLimit(1).tag($0.id) }
                        }
                    }
                    Toggle("Goal mode", isOn: $goalMode)
                } footer: {
                    FormNote(footer)
                }
                .hermesFormRows()

                Section {
                    if let estimate, estimate.ok {
                        HStack {
                            Text("~\(KanbanFormat.compactNumber(estimate.estTokens)) tok\(estimate.complexityLabel.map { " · \($0)" } ?? "")")
                                .monospacedDigit()
                            Spacer()
                            Button { Task { await runEstimate() } } label: { Image(systemName: Theme.Icon.retry) }
                                .buttonStyle(.borderless)
                                .disabled(estimating || !canCreate)
                                .accessibilityLabel("Re-estimate")
                        }
                        if let rationale = estimate.rationale {
                            Text(rationale).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                        }
                    } else {
                        Button { Task { await runEstimate() } } label: {
                            HStack {
                                Label(estimating ? "Estimating…" : "Estimate", systemImage: "gauge.with.dots.needle.33percent")
                                Spacer()
                                if estimating { ProgressView() }
                            }
                        }
                        .disabled(estimating || !canCreate)
                    }
                } footer: {
                    FormNote("Rough token and complexity estimate from the auxiliary model — makes a model call.")
                }
                .hermesFormRows()

                if let error {
                    Section { Text(error).foregroundStyle(Theme.destructive) }.hermesFormRows()
                }
            }
            .hermesForm()
            .navigationTitle("New task in \(KanbanColumns.label(target))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Create task") { Task { await create() } }.disabled(!canCreate) }
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    private var footer: String {
        var lines: [String] = []
        if kind != "scratch" {
            lines.append(boardDefaultDir.map { "Leave the path empty to inherit \($0)." }
                         ?? "Leave the path empty to inherit the board’s project directory.")
        }
        lines.append("Model runs this task on a specific model and thinking depth; unset uses the assigned profile’s own.")
        lines.append("Goal mode: the worker loops until a judge agrees it's done. A parent blocks the task until it's done.")
        return lines.joined(separator: " ")
    }

    private func loadProviders() async {
        guard providers == nil else { return }
        providers = (try? await store.api.modelOptions()) ?? []
    }

    private func runEstimate() async {
        estimating = true
        defer { estimating = false }
        do {
            let result = try await store.api.estimate(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: bodyText)
            if result.ok { estimate = result } else { error = result.reason ?? "Could not estimate" }
        } catch {
            self.error = error.dashboardMessage
        }
    }

    private func create() async {
        guard canCreate else { return }
        busy = true
        error = nil
        var draft = KanbanNewTask(title: title)
        draft.body = bodyText
        draft.assignee = assignee == Self.parked ? nil : (assignee.isEmpty ? resolvedDefault : assignee)
        draft.priority = priority
        draft.workspaceKind = kind
        draft.workspacePath = workspacePath
        draft.parents = parent.isEmpty ? [] : [parent]
        draft.triage = isTriage
        draft.skills = KanbanNewTask.skills(from: skills)
        draft.goalMode = goalMode
        draft.modelOverride = modelOverride
        do {
            try await store.createTask(draft, in: target)
            dismiss()
        } catch {
            self.error = error.dashboardMessage
            busy = false
        }
    }
}

/// The switcher's board dialogs: new board (name and project), rename, settings (project scope), import.
struct KanbanBoardDialog: View {
    @ObservedObject var store: KanbanStore
    let sheet: KanbanBoardSheet
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var project = ""
    @State private var archive = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                switch sheet {
                case .new:
                    nameSection(slug: KanbanNewBoard.slug(for: name))
                    projectSection
                case let .rename(board):
                    nameSection(slug: board.slug)
                case .settings:
                    projectSection
                case .importArchive:
                    Section {
                        TextField("Archive path on the host", text: $archive)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    } footer: {
                        FormNote("Board archives are read on the Hermes host, not this phone: enter the path of a .tar.gz there (an export lands in the host’s kanban/board-exports folder). It imports as a new board.")
                    }
                    .hermesFormRows()
                }
            }
            .hermesForm()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button(confirmLabel) { Task { await confirm() } }.disabled(!canConfirm) }
                }
            }
            .task {
                switch sheet {
                case let .rename(board): name = board.name
                case let .settings(board): project = board.projectID ?? ""
                default: break
                }
                if needsProjects { await store.loadProjects() }
            }
            .failureAlert($store.failure)
        }
        .presentationDetents([.medium, .large])
    }

    private var needsProjects: Bool {
        switch sheet {
        case .new, .settings: return true
        default: return false
        }
    }

    private func nameSection(slug: String) -> some View {
        Section {
            TextField("Board name", text: $name)
        } footer: {
            if !slug.isEmpty { FormNote("slug: \(slug)") }
        }
        .hermesFormRows()
    }

    private var projectSection: some View {
        Section {
            Picker("Project", selection: $project) {
                Text("No project (scratch sandboxes)").tag("")
                ForEach(store.projects) { Text($0.name).tag($0.id) }
            }
        } footer: {
            FormNote("New tasks run in the project’s repo (a worktree per task); each task can still override its workspace at creation. Manage projects with `hermes project`.")
        }
        .hermesFormRows()
    }

    private var title: String {
        switch sheet {
        case .new: return "New board"
        case .rename: return "Rename board"
        case let .settings(board): return "Board settings — \(board.name)"
        case .importArchive: return "Import board"
        }
    }

    private var confirmLabel: String {
        switch sheet {
        case .new: return "Create board"
        case .importArchive: return "Import"
        default: return "Save"
        }
    }

    private var canConfirm: Bool {
        switch sheet {
        case .new: return !KanbanNewBoard.slug(for: name).isEmpty
        case .rename: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .settings: return true
        case .importArchive: return !archive.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func confirm() async {
        busy = true
        defer { busy = false }
        let done: Bool
        switch sheet {
        case .new:
            done = await store.createBoard(KanbanNewBoard(name: name, projectID: project.isEmpty ? nil : project))
        case let .rename(board):
            done = await store.renameBoard(board.slug, name: name)
        case let .settings(board):
            done = await store.setProject(board.slug, projectID: project)
        case .importArchive:
            done = await store.importBoard(archive: archive)
        }
        if done { dismiss() }
    }
}

/// Orchestration settings (`OrchestrationPanel`): the orchestrator profile, the default assignee, auto-decompose,
/// and the profile descriptions the decomposer routes by.
struct KanbanOrchestrationSheet: View {
    @ObservedObject var store: KanbanStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let settings = store.orchestration {
                    Section {
                        Picker("Orchestrator profile", selection: binding(settings.orchestratorProfile, key: "orchestrator_profile")) {
                            Text("(default)").tag("")
                            ForEach(store.profiles) { Text($0.name).tag($0.name) }
                        }
                        Picker("Default assignee", selection: binding(settings.defaultAssignee, key: "default_assignee")) {
                            Text("(default)").tag("")
                            ForEach(store.profiles) { Text($0.name).tag($0.name) }
                        }
                        Toggle("Auto-decompose triage tasks", isOn: Binding(get: { settings.autoDecompose }, set: { value in
                            Task { await store.saveOrchestration(["auto_decompose": value]) }
                        }))
                    } footer: {
                        FormNote("Unset uses the active profile (\(settings.activeProfile ?? "default")). Ready cards without an assignee go to the default assignee on the next dispatch tick.")
                    }
                    .hermesFormRows()
                } else {
                    Section { OpsLoaderRow() }
                }

                if !store.profiles.isEmpty {
                    Section {
                        ForEach(store.profiles) { profile in
                            KanbanProfileDescriptionRow(store: store, profile: profile)
                        }
                    } header: {
                        FormNote("Profile descriptions")
                    } footer: {
                        FormNote("Descriptions guide the decomposer’s routing. Auto-generate with the auxiliary model, or write your own.")
                    }
                    .hermesFormRows()
                }
            }
            .hermesForm()
            .navigationTitle("Orchestration settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await store.loadSettings() }
            .failureAlert($store.failure)
            .opsToast($store.notice)
        }
    }

    private func binding(_ value: String, key: String) -> Binding<String> {
        Binding(get: { value }, set: { name in Task { await store.saveOrchestration([key: name]) } })
    }
}

private struct KanbanProfileDescriptionRow: View {
    @ObservedObject var store: KanbanStore
    let profile: KanbanProfile
    @State private var draft: String
    @State private var saving = false
    @State private var describing = false

    init(store: KanbanStore, profile: KanbanProfile) {
        self.store = store
        self.profile = profile
        _draft = State(initialValue: profile.description)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(profile.name).fontWeight(.medium)
                if profile.isDefault { Text("(default)").hermesText(.meta).foregroundStyle(Theme.Text.quaternary) }
                Spacer()
                Button {
                    Task {
                        describing = true
                        if let text = await store.autoDescribe(profile.name) { draft = text }
                        describing = false
                    }
                } label: {
                    if describing { ProgressView().controlSize(.small) } else { Text("Auto") }
                }
                .disabled(describing)
                Button("Save") {
                    Task {
                        saving = true
                        _ = await store.saveProfileDescription(profile.name, draft)
                        saving = false
                    }
                }
                .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines) == profile.description)
            }
            .buttonStyle(.borderless)
            TextField("What is this profile good at?", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .hermesText(.caption)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

/// The running workers of the board (`GET /workers/active`) with live process stats and a terminate per run,
/// above the board's per-status counts.
struct KanbanWorkersSheet: View {
    @ObservedObject var store: KanbanStore
    let openTask: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var workers: [KanbanActiveWorker]?
    @State private var stats: KanbanStats?
    @State private var inspections: [Int: KanbanRunInspect] = [:]
    @State private var error: String?
    @State private var confirmation: OpsConfirmation?
    @State private var notice: OpsNotice?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let stats {
                    Section {
                        ForEach(store.board?.columns.map(\.name) ?? KanbanColumns.order, id: \.self) { status in
                            if let count = stats.byStatus[status], count > 0 {
                                LabeledContent {
                                    Text("\(count)").monospacedDigit()
                                } label: {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        OpsDot(color: KanbanTone.color(status), size: 6)
                                        Text(KanbanColumns.label(status))
                                    }
                                }
                            }
                        }
                        if let age = stats.oldestReadyAgeSeconds {
                            LabeledContent("Oldest ready card", value: KanbanFormat.compactElapsed(TimeInterval(age)))
                        }
                    } header: {
                        FormNote("Board")
                    }
                    .hermesFormRows()
                }
                Section {
                    if let workers {
                        if workers.isEmpty {
                            Text("No workers running.").foregroundStyle(Theme.Text.tertiary)
                        }
                        ForEach(workers) { worker in row(worker) }
                    } else if let error {
                        Text(error).foregroundStyle(Theme.destructive)
                    } else {
                        OpsLoaderRow()
                    }
                } header: {
                    FormNote("Active workers")
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle("Active workers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
            .opsConfirm($confirmation)
            .failureAlert($failure)
            .opsToast($notice)
        }
    }

    private func row(_ worker: KanbanActiveWorker) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button { openTask(worker.taskID) } label: {
                Text(worker.taskTitle ?? worker.taskID).fontWeight(.medium).lineLimit(2)
            }
            .foregroundStyle(Theme.Text.primary)
            HStack(spacing: Theme.Spacing.sm) {
                if let profile = worker.profile ?? worker.assignee {
                    KanbanAvatar(name: profile, size: 14)
                    Text(profile)
                }
                if let pid = worker.workerPID { Text("pid \(pid)") }
                if let started = worker.startedAt {
                    Text("running \(KanbanFormat.compactElapsed(Date().timeIntervalSince1970 - Double(started)))")
                }
                if let beat = worker.lastHeartbeatAt, Date().timeIntervalSince1970 - Double(beat) > 120 {
                    Text("no heartbeat").foregroundStyle(Theme.Semantic.attention)
                }
            }
            .hermesText(.meta)
            .foregroundStyle(Theme.Text.tertiary)
            if let stats = inspections[worker.runID] {
                Text(describe(stats)).hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
            }
            HStack {
                Button("Inspect") {
                    Task { if let result = try? await store.api.inspectRun(worker.runID) { inspections[worker.runID] = result } }
                }
                Spacer()
                Button("Terminate run", role: .destructive) {
                    confirmation = OpsConfirmation(title: "Terminate this run?",
                                                   message: "The worker on “\(worker.taskTitle ?? worker.taskID)” is stopped and the task returns to the queue.",
                                                   confirmLabel: "Terminate") { await terminate(worker) }
                }
            }
            .buttonStyle(.borderless)
            .hermesText(.button)
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private func describe(_ stats: KanbanRunInspect) -> String {
        guard stats.alive else { return "Not running: \(stats.reason ?? "no process")" }
        var parts: [String] = []
        if let cpu = stats.cpuPercent { parts.append(String(format: "CPU %.0f%%", cpu)) }
        if let memory = KanbanFormat.bytes(stats.memoryRSSBytes) { parts.append("\(memory) RSS") }
        if let threads = stats.threads { parts.append("\(threads) threads") }
        if let reason = stats.reason { parts.append(reason) }
        return parts.isEmpty ? "Running" : parts.joined(separator: " · ")
    }

    private func load() async {
        let api = store.api
        do {
            async let rows = api.activeWorkers()
            async let counts = try? api.stats()
            workers = try await rows
            stats = await counts
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }

    private func terminate(_ worker: KanbanActiveWorker) async {
        do {
            try await store.api.terminateRun(worker.runID, reason: "terminated from the phone")
            notice = OpsNotice(title: "Run terminated", message: worker.taskTitle)
            store.didWrite(worker.taskID)
        } catch {
            failure = error.dashboardMessage
        }
        await load()
    }
}
