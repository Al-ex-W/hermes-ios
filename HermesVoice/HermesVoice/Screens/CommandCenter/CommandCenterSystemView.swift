import SwiftUI
import UIKit

/// The System section: gateway status with restart and update, component health, the host's stats, the update
/// check, and the recent logs.
struct CommandCenterSystemView: View {
    let client: DashboardClient
    /// Nil acts on the dashboard's own profile.
    let profile: String?

    @StateObject private var runner: OpsActionRunner
    @State private var status: HermesStatus?
    @State private var stats: SystemStats?
    @State private var update: UpdateCheck?
    @State private var checkingUpdate = false
    @State private var loadError: String?
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
            gatewaySection
            OpsActionLog(runner: runner)
            if let status, !status.components.isEmpty || !status.platforms.isEmpty { healthSection(status) }
            updateSection
            if let stats { hostSection(stats) }
            Section {
                NavigationLink {
                    CommandCenterLogsView(client: client, profile: profile)
                } label: {
                    PageRow(title: "Recent logs", detail: "Agent, errors and gateway logs; filter, follow, copy.",
                            systemImage: "doc.text.magnifyingglass")
                }
            }
            .hermesFormRows()
        }
        .hermesForm()
        .navigationTitle("System")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .opsConfirm($confirmation)
        .failureAlert($failure)
        .opsToast($notice)
    }

    // MARK: Gateway

    @ViewBuilder private var gatewaySection: some View {
        Section {
            if let status {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.md) {
                        OpsDot(color: status.gatewayRunning ? Theme.Semantic.success : Theme.Semantic.attention, size: 8)
                        Text(status.gatewayRunning ? "Messaging gateway running" : "Messaging gateway stopped")
                            .hermesText(.rowTitle)
                    }
                    Text("Hermes \(status.version) · Active sessions \(status.activeSessions)")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                    if let reason = status.gatewayExitReason, !status.gatewayRunning {
                        Text(reason).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                    }
                    if let stale = status.gatewayHeartbeatStale {
                        Text("Heartbeat stale for \(Int(stale)) s: the gateway may be wedged.")
                            .hermesText(.caption)
                            .foregroundStyle(Theme.Semantic.attention)
                    }
                }
                .padding(.vertical, Theme.Spacing.xxs)
                .accessibilityElement(children: .combine)
                Button { confirmRestart(status) } label: { Label("Restart gateway", systemImage: "arrow.clockwise") }
                    .disabled(runner.isRunning)
                if status.canUpdateHermes {
                    Button { confirmUpdate() } label: { Label("Update Hermes", systemImage: "arrow.down.circle") }
                        .disabled(runner.isRunning)
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(Theme.destructive)
                Button("Try again") { Task { await load() } }
            } else {
                OpsLoaderRow()
            }
        } header: {
            FormNote("Status")
        }
        .hermesFormRows()
    }

    private func confirmRestart(_ status: HermesStatus) {
        let message: String
        if let shared = status.sharedWith {
            message = "All bots on this device reconnect: \(shared.joined(separator: ", "))"
        } else {
            message = "Messaging platforms disconnect briefly and running turns are interrupted."
        }
        confirmation = OpsConfirmation(title: status.sharedWith == nil ? "Restart the gateway?" : "Restart the shared gateway?",
                                       message: message,
                                       confirmLabel: status.sharedWith == nil ? "Restart gateway" : "Restart all") {
            await restart(sharedCount: status.sharedWith?.count)
        }
    }

    private func restart(sharedCount: Int?) async {
        do {
            // The desktop polls a restart 18 times: in a no-service install the child becomes the gateway and never
            // exits, which counts as done.
            try await runner.run("Restart gateway", limit: 18, start: { try await client.restartGateway(profile: profile) }) { last in
                Task { @MainActor in
                    if let sharedCount, last.map({ !$0.running && $0.exitCode == 0 }) ?? false {
                        notice = OpsNotice(title: "Shared gateway restarted (\(sharedCount) \(sharedCount == 1 ? "bot" : "bots"))")
                    }
                    await load()
                }
            }
        } catch {
            if !error.isCancellation { failure = "Gateway restart failed. \(error.dashboardMessage)" }
        }
    }

    private func confirmUpdate() {
        confirmation = OpsConfirmation(title: "Update Hermes?",
                                       message: "Hermes updates on the host and restarts. Running turns are interrupted and the app reconnects.",
                                       confirmLabel: "Update") {
            await runUpdate()
        }
    }

    private func runUpdate() async {
        do {
            // An update restarts the dashboard under the poll: survive about half a minute of failed reads.
            try await runner.run("Update Hermes", limit: 400, tolerance: 30, start: { try await client.updateHermes() }) { _ in
                Task { @MainActor in await load() }
            }
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
        }
    }

    // MARK: Health

    private func healthSection(_ status: HermesStatus) -> some View {
        Section {
            if let overall = status.overall {
                LabeledContent("Overall") {
                    OpsPill(overall, tone: overall == "ok" ? .good : .warn)
                }
            }
            ForEach(status.components) { component in
                LabeledContent(SettingsText.prettyName(component.name)) {
                    OpsPill(component.status, tone: component.isOK ? .good : .warn)
                }
            }
            ForEach(status.platforms) { platform in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    LabeledContent(SettingsText.prettyName(platform.name)) {
                        OpsPill(platform.state, tone: Self.platformTone(platform.state))
                    }
                    if let message = platform.errorMessage {
                        Text(message).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                    }
                }
            }
        } header: {
            FormNote("Health")
        }
        .hermesFormRows()
    }

    private static func platformTone(_ state: String) -> OpsPill.Tone {
        switch state.lowercased() {
        case "connected", "running", "ok", "ready": return .good
        case "disabled", "stopped": return .muted
        case "error", "failed", "fatal": return .bad
        default: return .warn
        }
    }

    // MARK: Updates

    private var updateSection: some View {
        Section {
            if let update {
                LabeledContent("Installed", value: update.currentVersion.isEmpty ? "Unknown" : update.currentVersion)
                Text(update.summary).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                ForEach(update.commits.prefix(10)) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                        Text(commit.sha).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary)
                        Text(commit.summary).hermesText(.caption).foregroundStyle(Theme.Text.secondary).lineLimit(2)
                    }
                }
                if update.updateAvailable, !update.canApply, let command = update.updateCommand {
                    CopyableText(text: command)
                }
            }
            Button {
                Task { await checkUpdate(force: true) }
            } label: {
                HStack {
                    Label("Check for updates", systemImage: "arrow.triangle.2.circlepath")
                    if checkingUpdate { Spacer(); ProgressView() }
                }
            }
            .disabled(checkingUpdate)
        } header: {
            FormNote("Updates")
        } footer: {
            if let update, update.updateAvailable, update.canApply {
                FormNote("Update Hermes above applies it in place.")
            }
        }
        .hermesFormRows()
    }

    private func checkUpdate(force: Bool) async {
        checkingUpdate = true
        defer { checkingUpdate = false }
        do {
            update = try await client.checkHermesUpdate(force: force, profile: profile)
        } catch {
            if force, !error.isCancellation { failure = "Update check failed. \(error.dashboardMessage)" }
        }
    }

    // MARK: Host

    private func hostSection(_ stats: SystemStats) -> some View {
        Section {
            if let hostname = stats.hostname { LabeledContent("Host", value: hostname) }
            if let os = stats.os { LabeledContent("System", value: [os, stats.arch].compactMap { $0 }.joined(separator: " · ")) }
            if let cpu = stats.cpuPercent {
                LabeledContent("CPU", value: String(format: "%.0f%%", cpu) + (stats.cpuCount.map { " of \($0) cores" } ?? ""))
            }
            if !stats.loadAverage.isEmpty {
                LabeledContent("Load", value: stats.loadAverage.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
            if let memory = stats.memory { usageRow("Memory", memory) }
            if let disk = stats.disk { usageRow("Disk", disk) }
            if let uptime = stats.uptime { LabeledContent("Uptime", value: Self.duration(uptime)) }
            if let rss = stats.processRSS { LabeledContent("Dashboard memory", value: ByteSize.format(rss)) }
            if let python = stats.pythonVersion { LabeledContent("Python", value: python) }
        } header: {
            FormNote("Host")
        }
        .hermesFormRows()
    }

    private func usageRow(_ title: String, _ usage: SystemStats.Usage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            LabeledContent(title, value: "\(ByteSize.format(usage.used)) of \(ByteSize.format(usage.total))")
            ProgressView(value: min(max(usage.percent / 100, 0), 1))
                .tint(usage.percent >= 90 ? Theme.destructive : usage.percent >= 75 ? Theme.Semantic.attention : Theme.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(String(format: "%.0f percent", usage.percent))
    }

    /// "3 d 4 h", "5 h 12 m", "42 m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400, hours = total % 86_400 / 3600, minutes = total % 3600 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) m" }
        return "\(minutes) m"
    }

    // MARK: Loading

    private func load() async {
        async let statsRead = try? client.systemStats()
        // The cached check (no force), so the version shows its update state without a network round trip.
        async let updateRead = try? client.checkHermesUpdate(force: false, profile: profile)
        do {
            status = try await client.hermesStatus(profile: profile)
            loadError = nil
        } catch {
            if !error.isCancellation, status == nil { loadError = error.dashboardMessage }
        }
        if let value = await statsRead { stats = value }
        if let value = await updateRead { update = value }
    }
}

// MARK: - Logs

/// The recent log lines of one file at one level (`GET /api/logs`), with a search, a follow mode that refreshes and
/// keeps the newest line in view, and copy.
struct CommandCenterLogsView: View {
    let client: DashboardClient
    let profile: String?

    @State private var file = LogFile.agent
    @State private var level = LogLevel.all
    @State private var lines: [String]?
    @State private var query = ""
    @State private var follow = false
    @State private var loading = false
    @State private var error: String?
    @State private var copied = false

    private static let followInterval: TimeInterval = 3
    private static let bottomID = "logs.bottom"

    private var search: LogSearch { LogSearch(query: query) }

    var body: some View {
        VStack(spacing: 0) {
            filters
            content
        }
        .background(Theme.background)
        .searchable(text: $query, prompt: "Search log lines...")
        .navigationTitle("Recent logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = search.filter(lines ?? []).joined(separator: "\n")
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : Theme.Icon.copy)
                }
                .accessibilityLabel(copied ? "Copied" : "Copy lines")
                .disabled((lines ?? []).isEmpty)
                Button { Task { await load() } } label: { Image(systemName: Theme.Icon.retry) }
                    .accessibilityLabel("Refresh")
                    .disabled(loading)
            }
        }
        .task(id: LoadKey(file: file, level: level)) { await load() }
        .task(id: follow) {
            guard follow else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.followInterval))
                guard !Task.isCancelled else { return }
                await load()
            }
        }
    }

    private struct LoadKey: Hashable {
        var file: LogFile
        var level: LogLevel
    }

    private var filters: some View {
        HStack(spacing: Theme.Spacing.md) {
            Picker("Log file", selection: $file) {
                ForEach(LogFile.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Level", selection: $level) {
                ForEach(LogLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            Spacer()
            Toggle(isOn: $follow) { Text("Follow").hermesText(.button) }
                .toggleStyle(.button)
                .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .hermesHairline()
    }

    @ViewBuilder private var content: some View {
        if let lines {
            let shown = search.filter(lines)
            if shown.isEmpty {
                ContentUnavailableView(lines.isEmpty ? "No logs loaded yet." : "No matching lines",
                                       systemImage: lines.isEmpty ? "doc.text" : Theme.Icon.search,
                                       description: error.map { Text($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if search.isActive {
                                Text("\(shown.count) of \(lines.count) lines")
                                    .hermesText(.meta)
                                    .foregroundStyle(Theme.Text.tertiary)
                                    .padding(.bottom, Theme.Spacing.xs)
                            }
                            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Self.color(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id(Self.bottomID)
                        }
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.md)
                    }
                    .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    .onChange(of: lines) { _, _ in
                        if follow { withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
                    }
                    .onChange(of: follow) { _, on in
                        if on { withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
                    }
                }
                .refreshable { await load() }
            }
        } else if let error {
            ContentUnavailableView {
                Label("Couldn't load logs", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Error lines read red, warnings amber.
    private static func color(_ line: String) -> Color {
        if line.contains(" ERROR ") || line.contains("[ERROR]") || line.contains(" CRITICAL ") { return Theme.destructive }
        if line.contains(" WARNING ") || line.contains("[WARNING]") { return Theme.Semantic.attention }
        return Theme.Text.secondary
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let next = try await client.logLines(file: file, level: level, profile: profile)
            guard !Task.isCancelled else { return }
            lines = next
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.dashboardMessage
        }
    }
}
