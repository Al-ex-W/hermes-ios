import SwiftUI

/// What the job editor sheet edits.
enum CronEditorMode: Identifiable, Hashable {
    /// A new job, optionally starting from a blueprint.
    case create(blueprintKey: String?)
    case edit(CronJob)

    var id: String {
        switch self {
        case let .create(key): return "create:\(key ?? "")"
        case let .edit(job): return "edit:\(job.id)"
        }
    }
}

/// The desktop's Scheduled jobs page (`app/cron/index.tsx`): the jobs of the sidebar's profile scope with their state,
/// a detail per job (schedule, last result, run history, pause / resume / trigger), the editor, and the blueprint
/// gallery below the jobs. The desktop's master/detail becomes push navigation.
struct ScheduledJobsScreen: View {
    @StateObject private var store: CronStore
    /// Opens a run's session (wired to `SidebarModel.open(sessionID:profile:)`).
    let openSession: (_ sessionID: String, _ profile: String?) -> Void
    private let initialJobID: String?

    @State private var query = ""
    @State private var editor: CronEditorMode?
    @State private var pendingDelete: CronJob?
    @State private var opened: String?
    @State private var focusedInitial = false

    /// `profileScope` is a profile name or `SidebarOptions.allProfiles`; `initialJobID` (an id or a job name) opens
    /// that job once the list has loaded.
    init(client: DashboardClient, profileScope: String = SidebarOptions.allProfiles, initialJobID: String? = nil,
         openSession: @escaping (_ sessionID: String, _ profile: String?) -> Void) {
        _store = StateObject(wrappedValue: CronStore(client: client, profileScope: profileScope))
        self.initialJobID = initialJobID
        self.openSession = openSession
    }

    var body: some View {
        content
            .hermesForm()
            .searchable(text: $query, prompt: "Search cron jobs...")
            .navigationTitle("Scheduled jobs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = .create(blueprintKey: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New cron")
                        .disabled(store.jobs == nil && store.loadError == nil)
                }
            }
            .task {
                async let jobs: Void = store.load()
                async let blueprints: Void = store.loadBlueprints()
                _ = await (jobs, blueprints)
                focusInitialJob()
            }
            .refreshable {
                async let jobs: Void = store.load()
                async let blueprints: Void = store.loadBlueprints()
                _ = await (jobs, blueprints)
            }
            .navigationDestination(item: $opened) { id in
                CronJobDetailView(store: store, jobID: id, openSession: openSession,
                                  edit: { editor = .edit($0) }, delete: { pendingDelete = $0 })
            }
            .sheet(item: $editor) { mode in
                CronEditorSheet(store: store, mode: mode)
            }
            // An alert, not a dialog: the job's page asks too, and a dialog would anchor to the list behind it.
            .alert("Delete cron job?", isPresented: Binding(get: { pendingDelete != nil },
                                                            set: { if !$0 { pendingDelete = nil } }),
                   presenting: pendingDelete) { job in
                Button("Delete", role: .destructive) {
                    if opened == job.id { opened = nil }
                    Task { await store.delete(job) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { job in
                Text("This will remove \(CronText.truncate(job.title, 60)) permanently. It will stop firing immediately.")
            }
            .failureAlert($store.failure)
            .opsToast($store.notice)
    }

    @ViewBuilder private var content: some View {
        if let jobs = store.jobs {
            if jobs.isEmpty, store.blueprints.isEmpty {
                ContentUnavailableView {
                    Label("No scheduled jobs yet", systemImage: Theme.Icon.scheduledJobs)
                } description: {
                    Text("Schedule a prompt to run on a cron expression. Hermes will run it and deliver results to the destination you pick.")
                } actions: {
                    Button("New cron") { editor = .create(blueprintKey: nil) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            } else {
                list(jobs)
            }
        } else if let error = store.loadError {
            ContentUnavailableView {
                Label("Failed to load cron jobs", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        } else {
            List { OpsLoaderRow() }
        }
    }

    private func list(_ jobs: [CronJob]) -> some View {
        let visible = store.visibleJobs(query)
        let blueprints = store.visibleBlueprints(query)
        return List {
            Section {
                ForEach(visible) { job in
                    Button { opened = job.id } label: {
                        CronJobListRow(job: job, showsProfile: store.spansProfiles)
                    }
                    .foregroundStyle(Theme.Text.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = job } label: { Label("Delete", systemImage: Theme.Icon.delete) }
                        Button { editor = .edit(job) } label: { Label("Edit", systemImage: Theme.Icon.rename) }
                    }
                    .contextMenu { menu(job) }
                }
                if visible.isEmpty {
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "No scheduled jobs yet" : "No matches")
                        .foregroundStyle(Theme.Text.tertiary)
                }
                Button { editor = .create(blueprintKey: nil) } label: {
                    Label("New cron", systemImage: "plus")
                }
            } header: {
                FormNote("\(jobs.count) \(jobs.count == 1 ? "job" : "jobs")")
            }
            .hermesFormRows()

            if !blueprints.isEmpty {
                Section {
                    ForEach(blueprints) { blueprint in
                        Button { editor = .create(blueprintKey: blueprint.key) } label: {
                            CronBlueprintRow(blueprint: blueprint)
                        }
                        .foregroundStyle(Theme.Text.primary)
                    }
                } header: {
                    FormNote("Blueprints")
                } footer: {
                    FormNote("Ready-made automations. Fill in the details and schedule it.")
                }
                .hermesFormRows()
            }
        }
    }

    @ViewBuilder private func menu(_ job: CronJob) -> some View {
        Button { editor = .edit(job) } label: { Label("Edit cron", systemImage: Theme.Icon.rename) }
        Button { Task { await store.setPaused(job) } } label: {
            Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play" : "pause")
        }
        .disabled(store.busy.contains(job.id))
        Button { Task { await store.trigger(job) } } label: { Label("Trigger now", systemImage: "bolt") }
            .disabled(store.triggering.contains(job.id) || store.pendingRuns[job.id] != nil)
        Divider()
        Button(role: .destructive) { pendingDelete = job } label: { Label("Delete", systemImage: Theme.Icon.delete) }
    }

    /// A job opened from elsewhere (its id or name) shows once the list holds it.
    private func focusInitialJob() {
        guard !focusedInitial, let wanted = initialJobID, let jobs = store.jobs else { return }
        focusedInitial = true
        if let match = jobs.first(where: { $0.id == wanted || $0.name == wanted }) { opened = match.id }
    }
}

private struct CronJobListRow: View {
    let job: CronJob
    let showsProfile: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            OpsDot(color: job.stateColor)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(job.title).hermesText(.rowTitle).lineLimit(1)
                Text(subtitle)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if job.effectiveState == "paused" || job.effectiveState == "error" {
                OpsPill(job.stateLabel, tone: job.stateTone)
            }
            Image(systemName: Theme.Icon.disclosure)
                .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(job.stateLabel)
    }

    private var subtitle: String {
        var parts = [job.scheduleLabel]
        if showsProfile, let profile = job.profile { parts.append(profile) }
        return parts.joined(separator: " · ")
    }
}

private struct CronBlueprintRow: View {
    let blueprint: CronBlueprint

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.IconSize.sm))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(blueprint.title).hermesText(.rowTitle).lineLimit(1)
                    if let plugin = blueprint.plugin { OpsPill(plugin) }
                }
                if !blueprint.description.isEmpty {
                    Text(blueprint.description)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
    }
}
