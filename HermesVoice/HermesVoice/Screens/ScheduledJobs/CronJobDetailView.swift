import SwiftUI

/// One job (`CronJobDetail`): state, pause / resume and trigger, schedule and last result, the prompt, and the run
/// history, polled while the page is open (fast while a trigger waits for its run).
struct CronJobDetailView: View {
    @ObservedObject var store: CronStore
    let jobID: String
    let openSession: (_ sessionID: String, _ profile: String?) -> Void
    let edit: (CronJob) -> Void
    /// Deletes the job (asked here first) and leaves the page.
    let delete: (CronJob) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var runs: [CronRun]?
    @State private var showsFullError = false
    @State private var viewOnlyRun: CronRun?
    @State private var confirmingDelete: CronJob?

    /// Runs come from the scheduler's tick; while a trigger waits, poll every second (`RUNS_POLL_INTERVAL_MS`,
    /// `PENDING_RUNS_POLL_INTERVAL_MS`).
    private static let pollInterval: TimeInterval = 8
    private static let pendingPollInterval: TimeInterval = 1

    var body: some View {
        Group {
            if let job = store.job(jobID) {
                detail(job)
            } else if store.jobs == nil {
                List { OpsLoaderRow() }
            } else {
                ContentUnavailableView("Job not found", systemImage: Theme.Icon.scheduledJobs,
                                       description: Text("It may have been deleted, or a one-shot job finished."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
        }
        .hermesForm()
        .navigationTitle(store.job(jobID)?.title ?? "Scheduled job")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            if let job = store.job(jobID) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { edit(job) } label: { Label("Edit cron", systemImage: Theme.Icon.rename) }
                        Divider()
                        Button(role: .destructive) { confirmingDelete = job } label: {
                            Label("Delete", systemImage: Theme.Icon.delete)
                        }
                    } label: {
                        Image(systemName: Theme.Icon.more)
                    }
                    .accessibilityLabel("Manage")
                }
            }
        }
        .refreshable {
            await store.load()
            await loadRuns()
        }
        .task(id: PollKey(jobID: jobID, pendingAt: store.pendingRuns[jobID], active: scenePhase == .active)) {
            await pollRuns()
        }
        .alert("View-only run", isPresented: Binding(get: { viewOnlyRun != nil }, set: { if !$0 { viewOnlyRun = nil } }),
               presenting: viewOnlyRun) { run in
            Button("Open anyway") { open(run) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The scheduler never closed this run and no longer owns it. Read it, but don't write into it.")
        }
        // Asked on this page: an alert of the list underneath doesn't show while this page covers it.
        .alert("Delete cron job?", isPresented: Binding(get: { confirmingDelete != nil },
                                                        set: { if !$0 { confirmingDelete = nil } }),
               presenting: confirmingDelete) { job in
            Button("Delete", role: .destructive) { delete(job) }
            Button("Cancel", role: .cancel) {}
        } message: { job in
            Text("This will remove \(CronText.truncate(job.title, 60)) permanently. It will stop firing immediately.")
        }
    }

    // MARK: Sections

    private func detail(_ job: CronJob) -> some View {
        let busy = store.busy.contains(job.id) || store.triggering.contains(job.id)
        let pending = store.pendingRuns[job.id]
        return List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(job.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.Text.primary)
                        if job.isScriptOnly { OpsPill("script") }
                        OpsPill(job.stateLabel, tone: job.stateTone)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: Theme.Spacing.md) {
                        Button {
                            Task { await store.setPaused(job) }
                        } label: {
                            Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play" : "pause")
                        }
                        .buttonStyle(.bordered)
                        Button {
                            Task { await store.trigger(job) }
                        } label: {
                            HStack(spacing: Theme.Spacing.sm) {
                                if pending != nil { ProgressView().controlSize(.small) } else { Image(systemName: "bolt") }
                                Text("Trigger now")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .disabled(busy)
                    .controlSize(.small)
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .hermesFormRows()

            Section {
                LabeledContent("Frequency", value: job.scheduleLabel)
                LabeledContent("Last", value: CronTime.display(job.lastRunAt))
                LabeledContent(job.overdue() == nil ? "Next" : "Overdue since", value: CronTime.display(job.nextRunAt))
                    .foregroundStyle(job.overdue() == nil ? Theme.Text.primary : Theme.Semantic.attention)
                LabeledContent("Deliver to", value: CronDelivery.summary(job.deliverValue))
                if let model = job.model { LabeledContent("Model", value: model) }
                if store.spansProfiles, let profile = job.profile { LabeledContent("Profile", value: profile) }
            }
            .hermesFormRows()

            if let lastError = job.lastError {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Label {
                            Text("Last run failed: \(showsFullError ? lastError : CronText.errorSummary(lastError))")
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: Theme.Icon.warning)
                        }
                        .hermesText(.caption)
                        .foregroundStyle(Theme.destructive)
                        HStack(spacing: Theme.Spacing.md) {
                            Button { edit(job) } label: { Label("Edit job", systemImage: Theme.Icon.rename) }
                            Button { Task { await store.trigger(job) } } label: { Label("Run again", systemImage: "bolt") }
                            Spacer()
                            if CronText.errorSummary(lastError) != lastError {
                                Button(showsFullError ? "Less" : "More") { showsFullError.toggle() }
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(busy)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                .listRowBackground(Theme.destructive.opacity(0.08))
            }

            if !job.descriptionText.isEmpty {
                Section {
                    OpsTextBlock(text: job.descriptionText)
                        .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.md,
                                                   bottom: Theme.Spacing.md, trailing: Theme.Spacing.md))
                } header: {
                    FormNote(job.isScriptOnly && job.prompt.isEmpty ? "Script" : "Prompt")
                }
                .hermesFormRows()
            }

            runHistory(job, pending: pending)
        }
    }

    private func runHistory(_ job: CronJob, pending: Date?) -> some View {
        let count = (runs?.count ?? 0) + (pending == nil ? 0 : 1)
        return Section {
            if let pending {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Queued run").foregroundStyle(Theme.Text.tertiary)
                    Spacer()
                    Text(pending.formatted(date: .abbreviated, time: .shortened))
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Text.quaternary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            if let runs {
                ForEach(runs) { run in
                    if run.hasSession {
                        Button { tapped(run, job: job) } label: { CronRunRow(run: run, opens: true) }
                            .foregroundStyle(Theme.Text.primary)
                    } else {
                        CronRunRow(run: run, opens: false)
                    }
                }
                if runs.isEmpty, pending == nil {
                    Text("No runs yet").foregroundStyle(Theme.Text.tertiary)
                }
            } else if pending == nil {
                OpsLoaderRow()
            }
        } header: {
            FormNote(count > 0 ? "Run history · \(count)" : "Run history")
        }
        .hermesFormRows()
    }

    // MARK: Runs

    private struct PollKey: Hashable {
        var jobID: String
        var pendingAt: Date?
        var active: Bool
    }

    private func pollRuns() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            await loadRuns()
            let interval = store.pendingRuns[jobID] == nil ? Self.pollInterval : Self.pendingPollInterval
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func loadRuns() async {
        guard let job = store.job(jobID) else { return }
        do {
            let rows = try await store.client.cronJobRuns(job)
            guard !Task.isCancelled else { return }
            runs = rows
            // The queued row is settled by any run that started after the tap.
            if let pending = store.pendingRuns[jobID], CronRun.settles(rows, triggeredAt: pending) {
                store.settlePending(jobID, pending)
                await store.load()
            }
        } catch {
            if runs == nil, !error.isCancellation { runs = [] }
        }
    }

    /// A run the scheduler never closed opens view-only on the desktop (#88443); here it asks first.
    private func tapped(_ run: CronRun, job: CronJob) {
        if run.isResumable() { open(run, fallbackProfile: job.profile) } else { viewOnlyRun = run }
    }

    private func open(_ run: CronRun, fallbackProfile: String? = nil) {
        openSession(run.id, run.profile ?? fallbackProfile ?? store.job(jobID)?.profile)
    }
}

private struct CronRunRow: View {
    let run: CronRun
    let opens: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(run.label)
                .lineLimit(1)
                .foregroundStyle(Theme.Text.secondary)
            Spacer(minLength: Theme.Spacing.md)
            Text(run.time.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.quaternary)
                .monospacedDigit()
            if opens {
                Image(systemName: Theme.Icon.disclosure)
                    .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                    .foregroundStyle(Theme.Text.quaternary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(opens ? "Opens the run's session" : "")
    }
}
