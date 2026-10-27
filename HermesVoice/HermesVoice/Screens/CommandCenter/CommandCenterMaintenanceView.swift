import SwiftUI

/// The Maintenance section (`maintenance.tsx`, with the dashboard System page's backup download and checkpoint
/// prune): diagnostics that run on the host and tail their log, a backup to download and share, the debug share,
/// the skill curator, the built-in memory files, and the rollback checkpoints. Anything that deletes, archives,
/// uploads or overwrites asks first.
struct CommandCenterMaintenanceView: View {
    let client: DashboardClient
    /// Nil acts on the dashboard's own profile; routes that refuse an unnamed profile get its name.
    let profile: String?

    @StateObject private var runner: OpsActionRunner
    @State private var curator: CuratorStatus?
    @State private var curatorBusy = false
    @State private var memory: MemoryStatus?
    @State private var memoryBusy = false
    @State private var checkpoints: CheckpointsSummary?
    @State private var share: DebugShareResult?
    @State private var sharing = false
    /// The archive the last backup is writing, and whether it finished.
    @State private var backupArchive: String?
    @State private var backupReady = false
    @State private var downloading = false
    @State private var downloaded: SharedFile?
    @State private var resolvedProfile: String?
    @State private var confirmation: OpsConfirmation?
    @State private var failure: String?
    @State private var notice: OpsNotice?

    init(client: DashboardClient, profile: String?) {
        self.client = client
        self.profile = profile
        _runner = StateObject(wrappedValue: OpsActionRunner(client: client))
    }

    var body: some View {
        List {
            diagnostics
            OpsActionLog(runner: runner)
            if let share { shareLinks(share) }
            curatorSection
            memorySection
            checkpointsSection
        }
        .hermesForm()
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .opsConfirm($confirmation)
        .opsShareSheet($downloaded)
        .failureAlert($failure)
        .opsToast($notice)
    }

    // MARK: Diagnostics

    private var diagnostics: some View {
        Section {
            OpRow(title: "Run doctor", detail: "Health-check the install, config, and providers", running: runner.isRunning) {
                Task { await launch("Run doctor") { try await client.startOpsAction("/api/ops/doctor", name: "doctor", profile: profile) } }
            }
            OpRow(title: "Security audit", detail: "Scan config and skills for risky settings", running: runner.isRunning) {
                Task {
                    await launch("Security audit") {
                        try await client.startOpsAction("/api/ops/security-audit", name: "security-audit", profile: profile)
                    }
                }
            }
            OpRow(title: "Create backup", detail: "Zip config, memories, skills, and sessions", running: runner.isRunning) {
                Task { await backup() }
            }
            if backupReady, backupArchive != nil {
                Button { Task { await downloadBackup() } } label: {
                    HStack {
                        Label("Download backup", systemImage: "square.and.arrow.down")
                        if downloading { Spacer(); ProgressView() }
                    }
                }
                .disabled(downloading)
            }
            OpRow(title: sharing ? "Uploading debug report..." : "Debug share",
                  detail: "Upload a redacted report + logs, get shareable links (auto-deletes in 6h)", running: sharing) {
                confirmation = OpsConfirmation(
                    title: "Upload a debug report?",
                    message: "A redacted report and the recent logs go to the public paste service. Anyone with the links can read them until they auto-delete.",
                    confirmLabel: "Upload", destructive: false
                ) { await debugShare() }
            }
        } header: {
            FormNote("Diagnostics")
        } footer: {
            if backupReady, backupArchive != nil {
                FormNote("The backup holds this profile's config and credentials. Keep the downloaded copy somewhere safe.")
            }
        }
        .hermesFormRows()
    }

    private func launch(_ label: String, start: () async throws -> OpsActionStart) async {
        do {
            try await runner.run(label, start: start)
            notice = OpsNotice(title: "\(label) started — tailing log...")
        } catch {
            if !error.isCancellation { failure = "\(label) failed to start. \(error.dashboardMessage)" }
        }
    }

    private func backup() async {
        backupReady = false
        backupArchive = nil
        do {
            let started = try await runner.run("Create backup", start: {
                try await client.startOpsAction("/api/ops/backup", name: "backup", profile: profile)
            }) { last in
                Task { @MainActor in
                    if last?.running == false, last?.exitCode == 0 {
                        backupReady = true
                        notice = OpsNotice(title: "Backup ready to download")
                    }
                }
            }
            backupArchive = started.archive
            notice = OpsNotice(title: "Create backup started — tailing log...")
        } catch {
            if !error.isCancellation { failure = "Create backup failed to start. \(error.dashboardMessage)" }
        }
    }

    private func downloadBackup() async {
        guard let backupArchive else { return }
        downloading = true
        defer { downloading = false }
        do {
            downloaded = SharedFile(url: try await client.downloadBackup(archive: backupArchive, profile: profile))
        } catch {
            if !error.isCancellation { failure = "Download failed. \(error.dashboardMessage)" }
        }
    }

    private func debugShare() async {
        sharing = true
        share = nil
        defer { sharing = false }
        do {
            share = try await client.debugShare(profile: profile)
        } catch {
            if !error.isCancellation { failure = "Debug share failed. \(error.dashboardMessage)" }
        }
    }

    private func shareLinks(_ share: DebugShareResult) -> some View {
        Section {
            ForEach(share.urls, id: \.key) { link in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(link.key).hermesText(.label).foregroundStyle(Theme.Text.tertiary)
                    CopyableText(text: link.url)
                }
            }
            ForEach(share.failures, id: \.key) { failed in
                Text("\(failed.key): \(failed.reason)").hermesText(.caption).foregroundStyle(Theme.destructive)
            }
        } header: {
            FormNote("Share links")
        } footer: {
            if let seconds = share.autoDeleteSeconds {
                FormNote("Auto-deletes in \(max(1, seconds / 3600)) h\(share.redacted ? "; credentials were redacted." : ".")")
            }
        }
        .hermesFormRows()
    }

    // MARK: Curator

    private var curatorSection: some View {
        Section {
            if let curator {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("Skill curator").hermesText(.rowTitle)
                        OpsPill(curator.stateLabel, tone: !curator.enabled ? .muted : curator.paused ? .warn : .good)
                    }
                    Text("Background review that archives stale agent-created skills · "
                         + (curator.lastRunAt.map { "Last run \(CronTime.display($0))" } ?? "Never ran"))
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .accessibilityElement(children: .combine)
                if curator.enabled {
                    Button(curator.paused ? "Resume" : "Pause") { Task { await toggleCurator(curator) } }
                        .disabled(curatorBusy)
                }
                Button("Run now") {
                    confirmation = OpsConfirmation(
                        title: "Run the skill curator now?",
                        message: "It reviews agent-created skills and may archive or rewrite stale ones.",
                        confirmLabel: "Run now"
                    ) { await runCurator() }
                }
                .disabled(runner.isRunning)
            } else {
                OpsLoaderRow()
            }
        } header: {
            FormNote("Skill curator")
        }
        .hermesFormRows()
    }

    private func toggleCurator(_ current: CuratorStatus) async {
        curatorBusy = true
        defer { curatorBusy = false }
        do {
            try await client.setCuratorPaused(!current.paused, profile: profile)
            curator?.paused = !current.paused
        } catch {
            if !error.isCancellation { failure = "Skill curator failed to start. \(error.dashboardMessage)" }
        }
    }

    private func runCurator() async {
        do {
            let target = try await explicitProfile()
            try await runner.run("Skill curator", start: {
                try await client.startOpsAction("/api/curator/run", name: "curator-run", profile: target)
            }) { _ in
                Task { @MainActor in curator = try? await client.curatorStatus(profile: profile) }
            }
            notice = OpsNotice(title: "Skill curator started — tailing log...")
        } catch {
            if !error.isCancellation { failure = "Skill curator failed to start. \(error.dashboardMessage)" }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        Section {
            if let memory {
                Text("Built-in memory files injected into every session · Active provider: \(memory.active ?? "built-in")")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                memoryRow("Agent memory (MEMORY.md)", size: memory.memoryBytes, reset: "Reset memory", target: "memory")
                memoryRow("User profile (USER.md)", size: memory.userBytes, reset: "Reset profile", target: "user")
            } else {
                OpsLoaderRow()
            }
        } header: {
            FormNote("Memory data")
        }
        .hermesFormRows()
    }

    private func memoryRow(_ label: String, size: Int, reset: String, target: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(label)
                Text(size > 0 ? ByteSize.format(Double(size)) : "empty").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            Spacer()
            Button(reset, role: .destructive) {
                confirmation = OpsConfirmation(title: "Delete \(label)?", message: "This cannot be undone.",
                                               confirmLabel: reset) { await resetMemory(target, label: label) }
            }
            .buttonStyle(.borderless)
            .disabled(memoryBusy || size <= 0)
        }
    }

    private func resetMemory(_ target: String, label: String) async {
        memoryBusy = true
        defer { memoryBusy = false }
        do {
            let deleted = try await client.resetMemory(target, profile: try await explicitProfile())
            notice = OpsNotice(title: "Deleted \(deleted.isEmpty ? label : deleted.joined(separator: ", ")).")
            memory = try? await client.memoryStatus(profile: profile)
        } catch {
            if !error.isCancellation { failure = "Memory reset failed. \(error.dashboardMessage)" }
        }
    }

    // MARK: Checkpoints

    private var checkpointsSection: some View {
        Section {
            if let checkpoints {
                LabeledContent("Rollback checkpoints",
                               value: checkpoints.sessions == 0 ? "None"
                                   : "\(checkpoints.sessions) \(checkpoints.sessions == 1 ? "session" : "sessions") · \(ByteSize.format(Double(checkpoints.totalBytes)))")
                Button("Prune checkpoints", role: .destructive) {
                    confirmation = OpsConfirmation(
                        title: "Prune checkpoints?",
                        message: "Hermes deletes old /rollback checkpoints on the host. Sessions can no longer roll back past them.",
                        confirmLabel: "Prune"
                    ) { await pruneCheckpoints() }
                }
                .disabled(runner.isRunning || checkpoints.sessions == 0)
            } else {
                OpsLoaderRow()
            }
        } header: {
            FormNote("Checkpoints")
        }
        .hermesFormRows()
    }

    private func pruneCheckpoints() async {
        do {
            let target = try await explicitProfile()
            try await runner.run("Prune checkpoints", start: {
                try await client.startOpsAction("/api/ops/checkpoints/prune", name: "checkpoints-prune", profile: target)
            }) { _ in
                Task { @MainActor in checkpoints = try? await client.checkpoints(profile: profile) }
            }
        } catch {
            if !error.isCancellation { failure = "Prune failed to start. \(error.dashboardMessage)" }
        }
    }

    // MARK: Loading

    /// Routes that delete or overwrite a profile's data refuse an unnamed profile while the host serves several:
    /// the scope's profile, else the dashboard's own by name.
    private func explicitProfile() async throws -> String {
        if let profile { return profile }
        if let resolvedProfile { return resolvedProfile }
        let current = try await client.profileActivity().current
        resolvedProfile = current
        return current
    }

    private func load() async {
        async let curatorRead = try? client.curatorStatus(profile: profile)
        async let memoryRead = try? client.memoryStatus(profile: profile)
        async let checkpointsRead = try? client.checkpoints(profile: profile)
        curator = await curatorRead ?? curator
        memory = await memoryRead ?? memory
        checkpoints = await checkpointsRead ?? checkpoints
    }
}

/// One diagnostic: what it does, and the button that runs it.
private struct OpRow: View {
    let title: String
    let detail: String
    let running: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title).foregroundStyle(Theme.Text.primary)
                Text(detail).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            Spacer(minLength: Theme.Spacing.md)
            Button("Run", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(running)
                .accessibilityLabel(title)
        }
    }
}
