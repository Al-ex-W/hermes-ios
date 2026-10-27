import SwiftUI

/// The Scheduled jobs page's state (`app/cron/index.tsx`, `cron-actions.ts`): the jobs of the sidebar's profile
/// scope, the blueprint gallery, and the per-job work in flight. Every mutation reloads the list from the host,
/// since a fired one-shot may have removed itself.
@MainActor
final class CronStore: ObservableObject {
    let client: DashboardClient
    /// A profile name, or `SidebarOptions.allProfiles` for every profile's jobs.
    let profileScope: String

    @Published private(set) var jobs: [CronJob]?
    @Published private(set) var loadError: String?
    @Published private(set) var blueprints: [CronBlueprint] = []
    /// Jobs with a pause or resume in flight.
    @Published private(set) var busy: Set<String> = []
    /// Jobs whose trigger request hasn't answered yet.
    @Published private(set) var triggering: Set<String> = []
    /// Accepted triggers whose run hasn't shown up in the history yet: job id → when it was asked for.
    @Published private(set) var pendingRuns: [String: Date] = [:]
    @Published var notice: OpsNotice?
    @Published var failure: String?

    private var generation = 0

    init(client: DashboardClient, profileScope: String) {
        self.client = client
        self.profileScope = profileScope
    }

    var spansProfiles: Bool { profileScope == SidebarOptions.allProfiles }

    /// Where a new job is written: "all" isn't a store, so the dashboard's own profile.
    var createProfile: String? { spansProfiles ? nil : profileScope }

    /// Blueprints are fetched and instantiated for one profile; "all" collapses to "default", as on the desktop.
    var blueprintProfile: String { spansProfiles ? "default" : profileScope }

    func job(_ id: String) -> CronJob? { jobs?.first { $0.id == id } }

    /// Sorted by title, filtered by the search.
    func visibleJobs(_ query: String) -> [CronJob] {
        (jobs ?? []).filter { $0.matches(query) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func visibleBlueprints(_ query: String) -> [CronBlueprint] {
        blueprints.filter { $0.matches(query) }
    }

    // MARK: Loading

    func load() async {
        generation += 1
        let mine = generation
        do {
            let rows = try await client.cronJobs(profile: profileScope)
            guard mine == generation else { return }
            jobs = rows
            loadError = nil
        } catch {
            guard mine == generation, !error.isCancellation else { return }
            if jobs == nil { loadError = error.dashboardMessage } else { failure = "Failed to load cron jobs. \(error.dashboardMessage)" }
        }
    }

    func loadBlueprints() async {
        if let rows = try? await client.cronBlueprints(profile: blueprintProfile) { blueprints = rows }
    }

    /// Runs `mutate`, then reloads the list; a failed reload doesn't make the mutation look failed.
    private func mutateAndRefresh<T>(_ mutate: () async throws -> T) async throws -> T {
        let value = try await mutate()
        await load()
        return value
    }

    // MARK: Actions

    func setPaused(_ job: CronJob) async {
        guard !busy.contains(job.id) else { return }
        busy.insert(job.id)
        defer { busy.remove(job.id) }
        let pausing = !job.isPaused
        do {
            _ = try await mutateAndRefresh { try await client.setCronJobPaused(job, pausing) }
            notice = OpsNotice(title: pausing ? "Cron paused" : "Cron resumed", message: CronText.truncate(job.title, 60))
        } catch {
            if !error.isCancellation { failure = "Failed to update cron job. \(error.dashboardMessage)" }
        }
    }

    /// Runs the job now. The run history shows a queued row from the tap until the host's run appears (or 90 s
    /// pass). The host answers only when the run finishes; a timeout means it is still running there.
    func trigger(_ job: CronJob) async {
        guard !triggering.contains(job.id) else { return }
        let requestedAt = Date()
        triggering.insert(job.id)
        pendingRuns[job.id] = requestedAt
        notice = OpsNotice(title: "Trigger now", message: CronText.truncate(job.title, 60))
        scheduleSettle(job.id, requestedAt)
        defer { triggering.remove(job.id) }
        do {
            _ = try await mutateAndRefresh { try await client.triggerCronJob(job) }
            notice = OpsNotice(title: "Cron triggered", message: CronText.truncate(job.title, 60))
        } catch {
            if error.isCancellation { return }
            if error.isTimeout {
                notice = OpsNotice(title: "Still running on the host", message: "The run shows in Run history when it lands.")
                await load()
                return
            }
            // The request never started a run: the queued row would be a lie.
            settlePending(job.id, requestedAt)
            failure = "Failed to trigger cron job. \(error.dashboardMessage)"
        }
    }

    func delete(_ job: CronJob) async {
        do {
            try await mutateAndRefresh { try await client.deleteCronJob(job) }
            notice = OpsNotice(title: "Cron deleted", message: CronText.truncate(job.title, 60))
        } catch {
            if !error.isCancellation { failure = "Failed to delete cron job. \(error.dashboardMessage)" }
        }
    }

    /// Creates or updates; throws so the editor can show the error and stay open.
    func save(_ values: CronEditorValues, editing job: CronJob?) async throws {
        if let job {
            let updated = try await mutateAndRefresh { try await client.updateCronJob(job, values) }
            notice = OpsNotice(title: "Cron updated", message: CronText.truncate(updated.title, 60))
        } else {
            let created = try await mutateAndRefresh { try await client.createCronJob(values, profile: createProfile) }
            notice = OpsNotice(title: "Cron created", message: CronText.truncate(created.title, 60))
        }
    }

    func instantiate(_ blueprint: CronBlueprint, values: [String: String]) async throws {
        let job = try await mutateAndRefresh {
            try await client.instantiateCronBlueprint(blueprint, values: values, profile: blueprintProfile)
        }
        notice = OpsNotice(title: "Blueprint scheduled", message: job.scheduleDisplay ?? blueprint.title)
    }

    // MARK: Queued runs

    /// The history saw the run (or the wait is over): the queued row goes.
    func settlePending(_ jobID: String, _ requestedAt: Date) {
        guard pendingRuns[jobID] == requestedAt else { return }
        pendingRuns[jobID] = nil
    }

    private func scheduleSettle(_ jobID: String, _ requestedAt: Date) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(CronTime.pendingRunTimeout))
            self?.settlePending(jobID, requestedAt)
        }
    }
}

extension CronJob {
    /// The state pill's text (`states`).
    var stateLabel: String {
        switch effectiveState {
        case "error": return "last run failed"
        default: return effectiveState
        }
    }

    var stateTone: OpsPill.Tone {
        switch effectiveState {
        case "enabled", "scheduled", "running": return .good
        case "paused": return .warn
        case "error": return .bad
        default: return .muted
        }
    }

    /// The list row's dot (`STATE_DOT`).
    var stateColor: Color {
        switch effectiveState {
        case "enabled", "scheduled", "running": return Theme.primary
        case "paused": return Theme.Semantic.attention
        case "error": return Theme.destructive
        case "completed", "disabled": return Theme.Text.quaternary
        default: return Theme.Text.tertiary
        }
    }
}
