import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A linked task pushed inside the sheet.
private struct KanbanLinkedTask: Hashable {
    let id: String
}

/// The task sheet (the desktop's task modal): the task, and linked tasks pushed on its own stack.
struct KanbanTaskSheet: View {
    @ObservedObject var store: KanbanStore
    let taskID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            KanbanTaskDetailView(store: store, taskID: taskID, isRoot: true, close: { dismiss() })
                .navigationDestination(for: KanbanLinkedTask.self) { linked in
                    KanbanTaskDetailView(store: store, taskID: linked.id, isRoot: false, close: { dismiss() })
                }
        }
        .presentationDetents([.large])
    }
}

/// One task (`TaskDrawer`): the status menu and title, then diagnostics, description, result, latest summary and the
/// feed (comments, activity, runs, worker log), then the property rows with their inline editors, the estimate,
/// attachments and home-channel notifications.
private struct KanbanTaskDetailView: View {
    @ObservedObject var store: KanbanStore
    let taskID: String
    let isRoot: Bool
    let close: () -> Void

    @StateObject private var model: KanbanTaskModel
    @State private var feed = Feed.comments
    @State private var editingBody = false
    @State private var bodyDraft = ""
    @State private var commentDraft = ""
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var priorityPrompt = false
    @State private var priorityDraft = ""
    @State private var summaryPrompt = false
    @State private var summaryDraft = ""
    @State private var confirmation: OpsConfirmation?
    @State private var importsFile = false
    @State private var photo: PhotosPickerItem?
    @State private var choosesPhoto = false

    enum Feed: Hashable { case comments, activity, runs, log }

    struct FeedTab: Hashable {
        let feed: Feed
        let title: String
    }

    init(store: KanbanStore, taskID: String, isRoot: Bool, close: @escaping () -> Void) {
        self.store = store
        self.taskID = taskID
        self.isRoot = isRoot
        self.close = close
        _model = StateObject(wrappedValue: KanbanTaskModel(store: store, taskID: taskID))
    }

    var body: some View {
        content
            .hermesForm()
            .navigationTitle(model.task.map { $0.title.isEmpty ? $0.shortID : $0.title } ?? KanbanTask.shortID(taskID))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar { toolbar }
            .task { await model.load() }
            .task { await model.pollLog() }
            .onChange(of: store.taskTicks[taskID]) { _, _ in Task { await model.reload() } }
            .alert("Rename task", isPresented: $renaming) {
                TextField("Title", text: $titleDraft)
                Button("Save") { Task { _ = await model.saveTitle(titleDraft) } }
                    .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Priority", isPresented: $priorityPrompt) {
                TextField("Priority", text: $priorityDraft).keyboardType(.numbersAndPunctuation)
                Button("Save") { if let value = Int(priorityDraft.trimmingCharacters(in: .whitespaces)) { Task { await model.setPriority(value) } } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Higher-priority tasks are claimed first by the dispatcher.")
            }
            .alert("Completion summary", isPresented: $summaryPrompt) {
                TextField("What was done", text: $summaryDraft, axis: .vertical)
                Button("Mark done") { Task { await model.move(to: "done", summary: summaryDraft) } }
                    .disabled(summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Completion summary for this task. This is stored as the task result.")
            }
            .opsConfirm($confirmation)
            .failureAlert($model.failure)
            .opsToast($model.notice)
            .fileImporter(isPresented: $importsFile, allowedContentTypes: [.item]) { result in
                if case let .success(url) = result { Task { await upload(file: url) } }
            }
            .photosPicker(isPresented: $choosesPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { await upload(photo: item) }
            }
            .quickLookPreview($model.preview)
            .onChange(of: model.preview) { old, new in
                if let old, new == nil { DashboardClient.removeTemporaryFile(old) }
            }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let detail = model.detail {
            list(detail)
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Couldn’t load the task", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await model.reload() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("Loading")
        }
    }

    private func list(_ detail: KanbanTaskDetail) -> some View {
        let task = detail.task
        return List {
            header(task)
            if let message = model.auxMessage {
                Section {
                    Label(message.text, systemImage: message.ok ? "checkmark.circle" : Theme.Icon.error)
                        .hermesText(.caption)
                        .foregroundStyle(message.ok ? Theme.Text.secondary : Theme.destructive)
                }
                .hermesFormRows()
            }
            if task.status == "ready", task.assignee == nil, store.defaultAssignee.isEmpty {
                Section {
                    callout("Ready, but unassigned — this card will never run.",
                            "The dispatcher only claims Ready cards that have an assignee. Pick a profile in the Assignee field below (or set a default assignee in the orchestration settings) and it runs within a minute.",
                            tone: Theme.Semantic.attention)
                }
                .hermesFormRows()
            }
            if !task.diagnostics.isEmpty { diagnostics(task) }
            descriptionSection(task)
            if let result = task.result {
                Section { markdown(result) } header: { FormNote("Result") }.hermesFormRows()
            }
            if let summary = task.latestSummary, !KanbanEventText.isAdminSummary(summary) {
                Section { markdown(summary) } header: { FormNote("Latest summary") }.hermesFormRows()
            }
            feedSection(detail)
            properties(task)
            dependencies(detail)
            estimateSection
            if let attachments = detail.attachments { attachmentsSection(attachments) }
            if !model.homeChannels.isEmpty { homeSection }
        }
    }

    private func header(_ task: KanbanTask) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    statusMenu(task)
                    Text(task.shortID)
                        .hermesText(.meta)
                        .monospaced()
                        .foregroundStyle(Theme.Text.quaternary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if task.status == "running" { KanbanRunClock(task: task).hermesText(.meta) }
                }
                Text(task.title.isEmpty ? task.id : task.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Text.primary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .hermesFormRows()
    }

    /// The Jira-style status control: the current column, click to move (locked columns listed only as current).
    private func statusMenu(_ task: KanbanTask) -> some View {
        let tone = KanbanTone.color(task.status)
        return Menu {
            ForEach(store.workflow.columns.map(\.key), id: \.self) { column in
                if column == task.status {
                    Label(KanbanColumns.label(column), systemImage: "checkmark")
                } else if store.workflow.canMove(from: task.status, to: column) {
                    Button { requestMove(task, to: column) } label: {
                        Label(KanbanColumns.label(column), systemImage: KanbanTone.icon(column))
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                OpsDot(color: tone, size: 6)
                Text(KanbanColumns.label(task.status).uppercased()).tracking(0.5)
                if model.isBusy("status") { ProgressView().controlSize(.mini) } else {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            }
            .hermesText(.label)
            .fontWeight(.semibold)
            .foregroundStyle(tone)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(tone.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        }
        .accessibilityLabel("Status: \(KanbanColumns.label(task.status))")
    }

    private func requestMove(_ task: KanbanTask, to status: String) {
        if KanbanMoveRules.needsSummary(task, to: status) {
            summaryDraft = ""
            summaryPrompt = true
        } else {
            Task { await model.move(to: status) }
        }
    }

    private func callout(_ title: String, _ detail: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: Theme.Icon.warning)
                .hermesText(.rowTitle)
                .foregroundStyle(tone)
            Text(detail).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .listRowBackground(tone.opacity(0.07))
    }

    private func markdown(_ text: String) -> some View {
        MarkdownView(markdown: text, style: .caption, color: Theme.Text.secondary)
            .padding(.vertical, Theme.Spacing.xxs)
    }

    // MARK: Diagnostics

    private func diagnostics(_ task: KanbanTask) -> some View {
        Section {
            ForEach(Array(task.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                let tone = KanbanTone.severity(diagnostic.severity)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label(diagnostic.title + (diagnostic.count > 1 ? " ×\(diagnostic.count)" : ""), systemImage: Theme.Icon.warning)
                        .hermesText(.rowTitle)
                        .foregroundStyle(tone)
                    if !diagnostic.detail.isEmpty {
                        Text(diagnostic.detail).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                    }
                    let actions = diagnostic.actions.filter { ["reclaim", "unblock", "cli_hint", "open_docs"].contains($0.kind) }
                    if !actions.isEmpty {
                        HStack(spacing: Theme.Spacing.sm) {
                            ForEach(actions, id: \.self) { action in diagnosticButton(action) }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                .listRowBackground(tone.opacity(0.07))
            }
        } header: {
            FormNote("Diagnostics · \(task.diagnostics.count)")
        }
        .hermesFormRows()
    }

    @ViewBuilder private func diagnosticButton(_ action: KanbanDiagnosticAction) -> some View {
        switch action.kind {
        case "reclaim":
            Button(action.label) { confirmReclaim() }
                .buttonStyle(.bordered).controlSize(.small)
        case "unblock":
            Button(action.label) { Task { await model.unblock() } }
                .buttonStyle(.bordered).controlSize(.small)
        case "cli_hint":
            Button {
                UIPasteboard.general.string = action.command
                model.notice = OpsNotice(title: "Command copied")
            } label: {
                Label(action.label, systemImage: Theme.Icon.copy)
            }
            .buttonStyle(.bordered).controlSize(.small)
        default:
            if let url = action.payload["url"]?.stringValue.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                Link(action.label, destination: url).buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func confirmReclaim() {
        confirmation = OpsConfirmation(title: "Reclaim the task?",
                                       message: "The worker's claim is released and the worker is stopped; the task returns to the queue.",
                                       confirmLabel: "Reclaim") { await model.reclaim(reason: "recovery action from the phone") }
    }

    // MARK: Description

    private func descriptionSection(_ task: KanbanTask) -> some View {
        Section {
            if editingBody {
                TextField("Description", text: $bodyDraft, axis: .vertical)
                    .lineLimit(4...16)
                    .hermesText(.caption)
                HStack {
                    Button("Cancel") { editingBody = false }
                    Spacer()
                    Button("Save") {
                        editingBody = false
                        Task { await model.saveBody(bodyDraft) }
                    }
                    .fontWeight(.semibold)
                }
                .buttonStyle(.borderless)
            } else if let body = task.body {
                markdown(body)
            } else {
                Text("No description yet.").hermesText(.caption).foregroundStyle(Theme.Text.quaternary)
            }
        } header: {
            HStack {
                FormNote("Description")
                Spacer()
                if !editingBody {
                    Button {
                        bodyDraft = task.body ?? ""
                        editingBody = true
                    } label: {
                        Image(systemName: Theme.Icon.rename)
                    }
                    .accessibilityLabel("Edit description")
                }
            }
        }
        .hermesFormRows()
    }

    // MARK: Feed

    private func feedSection(_ detail: KanbanTaskDetail) -> some View {
        let tabs = feedTabs(detail)
        return Section {
            if tabs.count > 1 {
                Picker("Show", selection: $feed) {
                    ForEach(tabs, id: \.self) { Text($0.title).tag($0.feed) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }
            switch tabs.contains(where: { $0.feed == feed }) ? feed : .comments {
            case .comments: comments(detail)
            case .activity: activity(detail)
            case .runs: runs(detail)
            case .log: logView
            }
        } header: {
            if tabs.count <= 1 { FormNote("Comments · \(detail.comments.count)") }
        } footer: {
            if feed == .comments || tabs.count <= 1 {
                FormNote(model.running
                         ? "This task is running. Your note is folded into the worker’s current turn within a few seconds. “Requeue with note” instead restarts the task from scratch with your note in context."
                         : "Comments are added to the task thread. When a worker picks the task up it reads them as part of its context.")
            }
        }
        .hermesFormRows()
    }

    private func feedTabs(_ detail: KanbanTaskDetail) -> [FeedTab] {
        var tabs = [FeedTab(feed: .comments, title: "Comments · \(detail.comments.count)")]
        if !detail.events.isEmpty { tabs.append(FeedTab(feed: .activity, title: "Activity · \(detail.events.count)")) }
        if !detail.runs.isEmpty { tabs.append(FeedTab(feed: .runs, title: "Runs · \(detail.runs.count)")) }
        if model.log?.hasContent == true { tabs.append(FeedTab(feed: .log, title: "Worker log")) }
        return tabs
    }

    @ViewBuilder private func comments(_ detail: KanbanTaskDetail) -> some View {
        ForEach(detail.comments) { comment in
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(comment.author).hermesText(.rowTitle).foregroundStyle(Theme.Text.secondary)
                    if let ago = KanbanFormat.ago(comment.createdAt) {
                        Text(ago).hermesText(.meta).foregroundStyle(Theme.Text.quaternary)
                    }
                }
                markdown(comment.body)
            }
        }
        VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
            TextField(model.running ? "Message the running worker…" : "Add a comment…", text: $commentDraft, axis: .vertical)
                .lineLimit(1...6)
                .hermesText(.caption)
            HStack(spacing: Theme.Spacing.md) {
                if model.running {
                    Button {
                        let note = commentDraft
                        confirmation = OpsConfirmation(title: "Requeue with note?",
                                                       message: "Your note is posted and the running worker is stopped; the task restarts from scratch with the note in context.",
                                                       confirmLabel: "Requeue") {
                            if await model.requeue(with: note) { commentDraft = "" }
                        }
                    } label: {
                        Label("Requeue with note", systemImage: "arrow.counterclockwise")
                    }
                }
                Spacer(minLength: 0)
                if model.isBusy("comment") { ProgressView().controlSize(.small) }
                Button {
                    let note = commentDraft
                    Task { if await model.comment(note) { commentDraft = "" } }
                } label: {
                    Text(model.running ? "Send" : "Comment").fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderless)
            .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy("comment"))
        }
    }

    @ViewBuilder private func activity(_ detail: KanbanTaskDetail) -> some View {
        ForEach(detail.events.reversed()) { event in
            let text = KanbanEventText.describe(event)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(text.label).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                    if let detail = text.detail {
                        Text(detail).hermesText(.meta).foregroundStyle(Theme.Text.quaternary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                if let ago = KanbanFormat.ago(event.createdAt) {
                    Text(ago).hermesText(.meta).foregroundStyle(Theme.Text.quaternary)
                }
            }
        }
    }

    @ViewBuilder private func runs(_ detail: KanbanTaskDetail) -> some View {
        ForEach(detail.runs.reversed()) { run in
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    OpsPill(run.state, tone: run.failed ? .bad : run.isActive ? .good : .muted)
                    if let profile = run.profile { Text(profile).foregroundStyle(Theme.Text.tertiary) }
                    if let duration = KanbanFormat.duration(run.startedAt, run.endedAt) {
                        Text(duration).foregroundStyle(Theme.Text.quaternary)
                    }
                    Spacer(minLength: 0)
                    if let ago = KanbanFormat.ago(run.endedAt ?? run.startedAt) {
                        Text(ago).foregroundStyle(Theme.Text.quaternary)
                    }
                }
                .hermesText(.meta)
                if let text = run.error ?? run.summary {
                    Text(text)
                        .hermesText(.caption)
                        .foregroundStyle(run.error != nil ? Theme.destructive : Theme.Text.tertiary)
                        .lineLimit(4)
                }
                if run.isActive {
                    if let stats = model.inspections[run.id] {
                        Text(inspection(stats)).hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                    }
                    HStack(spacing: Theme.Spacing.md) {
                        Button("Inspect") { Task { await model.inspect(run) } }
                        Spacer(minLength: 0)
                        Button("Terminate run", role: .destructive) {
                            confirmation = OpsConfirmation(title: "Terminate this run?",
                                                           message: "The worker is stopped and the task returns to the queue.",
                                                           confirmLabel: "Terminate") { await model.terminate(run) }
                        }
                        .disabled(model.isBusy("terminate:\(run.id)"))
                    }
                    .buttonStyle(.borderless)
                    .hermesText(.button)
                }
            }
            .padding(.vertical, Theme.Spacing.xxs)
        }
    }

    private func inspection(_ stats: KanbanRunInspect) -> String {
        guard stats.alive else { return "Not running: \(stats.reason ?? "no process")" }
        var parts: [String] = []
        if let pid = stats.pid { parts.append("pid \(pid)") }
        if let cpu = stats.cpuPercent { parts.append(String(format: "CPU %.0f%%", cpu)) }
        if let memory = KanbanFormat.bytes(stats.memoryRSSBytes) { parts.append("\(memory) RSS") }
        if let threads = stats.threads { parts.append("\(threads) threads") }
        if let reason = stats.reason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var logView: some View {
        if let log = model.log, log.hasContent {
            ScrollView {
                Text(log.content)
                    .hermesText(.code)
                    .foregroundStyle(Theme.Text.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxHeight: 320)
            if log.truncated {
                FormNote("Worker log · tail")
            }
        }
    }

    // MARK: Properties

    private func properties(_ task: KanbanTask) -> some View {
        Section {
            LabeledContent("Assignee") { assigneeMenu(task) }
            LabeledContent("Priority") {
                Menu {
                    ForEach(0...5, id: \.self) { value in
                        Button { Task { await model.setPriority(value) } } label: {
                            if value == task.priority { Label("\(value)", systemImage: "checkmark") } else { Text("\(value)") }
                        }
                    }
                    Divider()
                    Button("Other…") {
                        priorityDraft = String(task.priority)
                        priorityPrompt = true
                    }
                } label: {
                    KanbanPriority(priority: task.priority)
                }
            }
            if let tenant = task.tenant { LabeledContent("Tenant", value: tenant) }
            if task.status == "blocked", let kind = task.blockKind {
                LabeledContent("Block kind") {
                    Text(kind).foregroundStyle(Theme.destructive)
                }
                .accessibilityHint(KanbanEventText.blockKindHelp(kind))
            }
            if task.blockRecurrences > 0 {
                LabeledContent("Block recurrences", value: "×\(task.blockRecurrences)")
            }
            if task.consecutiveFailures > 0 {
                LabeledContent("Consecutive failures", value: "\(task.consecutiveFailures)")
            }
            if let failure = task.lastFailureError {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Last failure").foregroundStyle(Theme.Text.primary)
                    Text(failure).hermesText(.code).foregroundStyle(Theme.Text.tertiary).textSelection(.enabled)
                }
            }
            if let path = task.workspacePath {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack {
                        Text("Workspace").foregroundStyle(Theme.Text.primary)
                        if let kind = task.workspaceKind, kind != "dir" { OpsPill(kind) }
                        Spacer()
                        OpsCopyButton(text: path).labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    Text(path).hermesText(.code).foregroundStyle(Theme.Text.tertiary).textSelection(.enabled)
                    if let branch = task.branchName {
                        Label(branch, systemImage: "arrow.triangle.branch").hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                    }
                }
            }
            LabeledContent("Model") {
                KanbanModelMenu(value: KanbanModelOverride(task: task), providers: model.modelProviders,
                                busy: model.isBusy("model"), load: { await model.loadModelOptions() }) { next in
                    Task { await model.setModel(next) }
                }
            }
            if let skills = task.skills, !skills.isEmpty {
                LabeledContent("Skills", value: skills.joined(separator: ", "))
            }
            if task.goalMode { LabeledContent("Goal mode", value: task.goalMaxTurns.map { "up to \($0) turns" } ?? "on") }
            if let creator = task.createdBy { LabeledContent("Created by", value: creator) }
            if let created = KanbanFormat.ago(task.createdAt) { LabeledContent("Created", value: created) }
            if task.status == "running", let pid = task.workerPID { LabeledContent("Worker pid", value: "\(pid)") }
        } header: {
            FormNote("Details")
        }
        .hermesFormRows()
    }

    private func assigneeMenu(_ task: KanbanTask) -> some View {
        Menu {
            ForEach(store.profiles) { profile in
                Button { reassign(task, to: profile.name) } label: {
                    if profile.name == task.assignee { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                }
            }
            if task.assignee != nil {
                Divider()
                Button("Unassign") { reassign(task, to: nil) }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if model.isBusy("assignee") { ProgressView().controlSize(.mini) }
                if let assignee = task.assignee {
                    KanbanAvatar(name: assignee, size: 16)
                    Text(assignee)
                } else {
                    Text("unassigned").foregroundStyle(Theme.Text.quaternary)
                }
            }
        }
    }

    private func reassign(_ task: KanbanTask, to profile: String?) {
        guard profile != task.assignee else { return }
        if task.status == "running" {
            confirmation = OpsConfirmation(title: profile.map { "Reassign to \($0)?" } ?? "Unassign?",
                                           message: "The running worker is stopped first; the task goes back to the queue.",
                                           confirmLabel: profile == nil ? "Unassign" : "Reassign") { await model.reassign(profile) }
        } else {
            Task { await model.reassign(profile) }
        }
    }

    // MARK: Dependencies

    private func dependencies(_ detail: KanbanTaskDetail) -> some View {
        let candidates = (store.board?.allTasks ?? []).filter {
            $0.id != taskID && !detail.parents.contains($0.id) && !detail.children.contains($0.id)
        }
        return Section {
            linkRows(detail.parents, label: "Blocked by", detail: detail) { await model.removeLink(parent: $0, child: taskID) }
            linkRows(detail.children, label: "Blocks", detail: detail) { await model.removeLink(parent: taskID, child: $0) }
            if !candidates.isEmpty {
                Menu {
                    Menu("Blocked by…") {
                        ForEach(candidates) { other in
                            Button(other.title.isEmpty ? other.id : other.title) {
                                Task { await model.addLink(parent: other.id, child: taskID) }
                            }
                        }
                    }
                    Menu("Blocks…") {
                        ForEach(candidates) { other in
                            Button(other.title.isEmpty ? other.id : other.title) {
                                Task { await model.addLink(parent: taskID, child: other.id) }
                            }
                        }
                    }
                } label: {
                    Label("Add dependency", systemImage: "plus")
                }
                .disabled(model.isBusy("links"))
            }
        } header: {
            FormNote("Dependencies")
        } footer: {
            if !detail.parents.isEmpty { FormNote("A task stays blocked until every task it’s blocked by is done.") }
        }
        .hermesFormRows()
    }

    @ViewBuilder private func linkRows(_ ids: [String], label: String, detail: KanbanTaskDetail,
                                       remove: @escaping (String) async -> Void) -> some View {
        ForEach(ids, id: \.self) { id in
            NavigationLink(value: KanbanLinkedTask(id: id)) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(label).hermesText(.meta).foregroundStyle(Theme.Text.quaternary).frame(width: 64, alignment: .leading)
                    if let status = detail.linkTasks.first(where: { $0.id == id })?.status {
                        OpsDot(color: KanbanTone.color(status), size: 6)
                    }
                    Text(detail.linkTitle(id)).lineLimit(1)
                }
            }
            .swipeActions {
                Button(role: .destructive) { Task { await remove(id) } } label: { Label("Remove", systemImage: "link.badge.plus") }
            }
            .contextMenu {
                Button(role: .destructive) { Task { await remove(id) } } label: { Label("Remove dependency", systemImage: Theme.Icon.close) }
            }
        }
    }

    // MARK: Estimate, attachments, notifications

    private var estimateSection: some View {
        Section {
            if let estimate = model.estimate {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("~\(KanbanFormat.compactNumber(estimate.estTokens)) tok").fontWeight(.medium).monospacedDigit()
                    if let size = estimate.complexityLabel { Text("· \(size)").foregroundStyle(Theme.Text.tertiary) }
                    Spacer()
                    Button { Task { await model.runEstimate() } } label: { Image(systemName: Theme.Icon.retry) }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy("estimate"))
                        .accessibilityLabel("Re-estimate")
                }
                if let rationale = estimate.rationale {
                    Text(rationale).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
            } else {
                Button { Task { await model.runEstimate() } } label: {
                    HStack {
                        Label(model.isBusy("estimate") ? "Estimating…" : "Estimate effort", systemImage: "gauge.with.dots.needle.33percent")
                        Spacer()
                        if model.isBusy("estimate") { ProgressView() }
                    }
                }
                .disabled(model.isBusy("estimate"))
            }
        } header: {
            FormNote("Estimate")
        } footer: {
            FormNote("Runs a quick auxiliary-model call to estimate tokens and complexity. A rough guide, not a bill.")
        }
        .hermesFormRows()
    }

    private func attachmentsSection(_ attachments: [KanbanAttachment]) -> some View {
        Section {
            ForEach(attachments) { attachment in
                Button { Task { await model.open(attachment) } } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "paperclip").foregroundStyle(Theme.Text.tertiary)
                        Text(attachment.filename).lineLimit(1)
                        Spacer(minLength: 0)
                        if model.isBusy("download:\(attachment.id)") {
                            ProgressView()
                        } else if let size = KanbanFormat.bytes(attachment.size) {
                            Text(size).hermesText(.meta).foregroundStyle(Theme.Text.quaternary)
                        }
                    }
                }
                .foregroundStyle(Theme.Text.primary)
                .swipeActions {
                    Button(role: .destructive) { confirmDelete(attachment) } label: { Label("Delete", systemImage: Theme.Icon.delete) }
                }
                .contextMenu {
                    Button(role: .destructive) { confirmDelete(attachment) } label: { Label("Delete", systemImage: Theme.Icon.delete) }
                }
            }
            if attachments.isEmpty {
                Text("No attachments yet.").hermesText(.caption).foregroundStyle(Theme.Text.quaternary)
            }
            Menu {
                Button { importsFile = true } label: { Label("Choose file…", systemImage: "folder") }
                Button { choosesPhoto = true } label: { Label("Photo library…", systemImage: "photo") }
            } label: {
                HStack {
                    Label("Upload attachment", systemImage: "icloud.and.arrow.up")
                    Spacer()
                    if model.isBusy("upload") { ProgressView() }
                }
            }
            .disabled(model.isBusy("upload"))
        } header: {
            FormNote("Attachments · \(attachments.count)")
        }
        .hermesFormRows()
    }

    private func confirmDelete(_ attachment: KanbanAttachment) {
        confirmation = OpsConfirmation(title: "Delete attachment?",
                                       message: "“\(attachment.filename)” is removed from the task on the host.",
                                       confirmLabel: "Delete") { await model.deleteAttachment(attachment) }
    }

    private var homeSection: some View {
        Section {
            ForEach(model.homeChannels) { channel in
                Toggle(isOn: Binding(get: { channel.subscribed }, set: { _ in Task { await model.toggleHome(channel) } })) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(channel.platform.capitalized)
                        Text(channel.name).hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .disabled(model.isBusy("home:\(channel.platform)"))
            }
        } header: {
            FormNote("Notify home channels")
        } footer: {
            FormNote("Sends completed, blocked and gave-up notifications to the platform’s home channel.")
        }
        .hermesFormRows()
    }

    /// Streams a picked file from disk (the size is checked before it is read).
    private func upload(file url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        await model.upload(filename: url.lastPathComponent, contentType: type, file: url)
    }

    /// A photo arrives as data (the picker shows images only); it is size-checked, then sent from a temporary file.
    private func upload(photo item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let name = "photo-\(formatter.string(from: Date())).\(ext)"
            if let refusal = KanbanLimits.refusal(name, size: data.count) {
                model.failure = refusal
                return
            }
            let file = try DashboardClient.temporaryFile(data, name: name)
            defer { DashboardClient.removeTemporaryFile(file) }
            await model.upload(filename: name, contentType: type?.preferredMIMEType, file: file)
        } catch {
            model.failure = error.localizedDescription
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .cancellationAction) { Button("Done", action: close) }
        }
        ToolbarItem(placement: .primaryAction) {
            if let task = model.task {
                Menu {
                    Button {
                        UIPasteboard.general.string = task.id
                        model.notice = OpsNotice(title: "Copied \(task.id)")
                    } label: { Label("Copy task id", systemImage: Theme.Icon.copy) }
                    Button {
                        UIPasteboard.general.string = task.title.isEmpty ? task.id : task.title
                        model.notice = OpsNotice(title: "Copied title")
                    } label: { Label("Copy title", systemImage: Theme.Icon.copy) }
                    Button {
                        titleDraft = task.title
                        renaming = true
                    } label: { Label("Rename…", systemImage: Theme.Icon.rename) }
                    if task.status == "triage" {
                        Divider()
                        Button { Task { await model.specify() } } label: {
                            Label(model.isBusy("specify") ? "Specifying…" : "Specify", systemImage: "sparkles")
                        }
                        .disabled(model.isBusy("specify"))
                        Button { Task { await model.decompose() } } label: {
                            Label(model.isBusy("decompose") ? "Decomposing…" : "Decompose", systemImage: "square.split.2x2")
                        }
                        .disabled(model.isBusy("decompose"))
                    }
                    Divider()
                    if task.status != KanbanColumns.archived {
                        Button { Task { if await model.archive(), isRoot { close() } } } label: {
                            Label("Archive", systemImage: Theme.Icon.archive)
                        }
                    }
                    Button(role: .destructive) {
                        confirmation = OpsConfirmation(title: "Delete task?",
                                                       message: "Permanently delete this task? This cannot be undone.",
                                                       confirmLabel: "Delete") {
                            if await model.delete() { close() }
                        }
                    } label: { Label("Delete", systemImage: Theme.Icon.delete) }
                } label: {
                    if model.isBusy("specify") || model.isBusy("decompose") { ProgressView() } else { Image(systemName: Theme.Icon.more) }
                }
                .accessibilityLabel("Task actions")
            }
        }
    }
}

/// The per-task model override (the desktop reuses the composer's catalog menu): the host's providers and models,
/// thinking depth, and "Profile default" to inherit. Without a catalog, a typed model id.
struct KanbanModelMenu: View {
    let value: KanbanModelOverride
    let providers: [KanbanModelProvider]?
    var busy = false
    let load: () async -> Void
    let change: (KanbanModelOverride) -> Void

    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        Menu {
            Button { change(.inherit) } label: {
                if value.isInherited { Label("Profile default", systemImage: "checkmark") } else { Text("Profile default") }
            }
            if let providers, !providers.isEmpty {
                ForEach(providers) { provider in
                    Menu(provider.label) {
                        ForEach(provider.models, id: \.self) { model in
                            Button {
                                change(KanbanModelOverride(effort: value.effort, model: model, provider: provider.slug))
                            } label: {
                                if value.model == model, value.provider.isEmpty || value.provider == provider.slug {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
            }
            Button("Model id…") {
                typed = value.model
                typing = true
            }
            Menu("Thinking") {
                Button { change(KanbanModelOverride(effort: "", model: value.model, provider: value.provider)) } label: {
                    if value.effort.isEmpty { Label("Profile default", systemImage: "checkmark") } else { Text("Profile default") }
                }
                ForEach(KanbanModelOverride.efforts, id: \.self) { effort in
                    Button { change(KanbanModelOverride(effort: effort, model: value.model, provider: value.provider)) } label: {
                        if value.effort == effort {
                            Label(KanbanModelOverride.effortTitle(effort), systemImage: "checkmark")
                        } else {
                            Text(KanbanModelOverride.effortTitle(effort))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if busy { ProgressView().controlSize(.mini) }
                Text(value.label(inherit: "Profile default"))
                    .lineLimit(1)
                    .foregroundStyle(value.isInherited ? Theme.Text.tertiary : Theme.Text.primary)
            }
        }
        .task { await load() }
        .alert("Model", isPresented: $typing) {
            TextField("provider/model", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Use") {
                let model = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                change(KanbanModelOverride(effort: value.effort, model: model, provider: model.isEmpty ? "" : value.provider))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs this task on a specific model. Leave empty to use the assigned profile’s own.")
        }
    }
}
