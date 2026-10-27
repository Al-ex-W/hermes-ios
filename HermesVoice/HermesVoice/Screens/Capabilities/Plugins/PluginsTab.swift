import SwiftUI

/// The Plugins tab's state for one profile (`store/agent-plugins.ts`): the profile's agent plugins over the
/// gateway's `plugins.manage`, and the curated catalog to install from.
@MainActor
final class PluginsStore: ObservableObject {
    @Published private(set) var plugins: [AgentPlugin]?
    @Published private(set) var loadError: String?
    @Published private(set) var catalog: [PluginCatalogEntry]?
    @Published private(set) var catalogError: String?
    /// The plugin (key or name) whose RPC is in flight.
    @Published private(set) var busy: String?
    @Published private(set) var installing = false
    @Published var failure: String?
    @Published var notice: String?
    /// What an install that went through still asks of the user (missing keys, warnings), shown once its sheet
    /// has closed.
    @Published var report: String?

    let api: PluginsAPI?
    let catalogAPI: PluginCatalogAPI
    /// Stores one secret setting in the scoped profile's `.env` (`PUT /api/env`): secrets never ride the
    /// `plugins.manage settings` RPC, and the phone keeps no copy.
    let writeSecret: ((_ env: String, _ value: String) async throws -> Void)?
    private var loaded = false

    init(api: PluginsAPI?, catalogAPI: PluginCatalogAPI,
         writeSecret: ((_ env: String, _ value: String) async throws -> Void)? = nil) {
        self.api = api
        self.catalogAPI = catalogAPI
        self.writeSecret = writeSecret
    }

    func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        await load()
    }

    func load() async {
        async let installed: Void = reloadPlugins()
        async let curated: Void = reloadCatalog()
        _ = await (installed, curated)
    }

    func reloadPlugins() async {
        guard let api else { return }
        do {
            plugins = try await api.list()
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if plugins == nil { loadError = error.dashboardMessage } else { failure = "Could not load agent plugins. \(error.dashboardMessage)" }
        }
    }

    func reloadCatalog() async {
        do {
            catalog = try await catalogAPI.entries()
            catalogError = nil
        } catch {
            guard !error.isCancellation else { return }
            catalogError = error.dashboardMessage
        }
    }

    func plugin(_ id: String) -> AgentPlugin? {
        plugins?.first { $0.id == id }
    }

    func isBusy(_ plugin: AgentPlugin) -> Bool { busy == plugin.id || busy == plugin.name }

    /// Flips a plugin by key and takes the refreshed row the backend answers with.
    func toggle(_ plugin: AgentPlugin, enable: Bool) async {
        guard let api, let key = plugin.key, busy == nil else { return }
        busy = plugin.id
        defer { busy = nil }
        do {
            if let refreshed = try await api.toggle(key: key, enable: enable), let index = plugins?.firstIndex(where: { $0.key == key }) {
                plugins?[index] = refreshed
            } else {
                await reloadPlugins()
            }
        } catch {
            failure = "Could not toggle \(plugin.name). \(error.dashboardMessage)"
        }
    }

    /// Installs into the scoped profile and reports what became usable, what still needs a key, and warnings.
    func install(identifier: String, catalogName: String? = nil, enable: Bool = true, force: Bool = false,
                 ref: String? = nil) async -> Bool {
        guard let api, !installing else { return false }
        installing = true
        defer { installing = false }
        do {
            let outcome = try await api.install(identifier: identifier, catalogName: catalogName, enable: enable, force: force, ref: ref)
            notice = outcome.summary(fallbackName: catalogName ?? identifier)
            var extra: [String] = []
            if !outcome.missingEnv.isEmpty {
                extra.append("It needs \(outcome.missingEnv.joined(separator: ", ")): set it in Settings ▸ API keys.")
            }
            extra += outcome.warnings
            report = extra.isEmpty ? nil : ([notice ?? ""] + extra).joined(separator: "\n\n")
            await load()
            return true
        } catch {
            guard !error.isCancellation else { return false }
            if error.isConnectionLoss {
                failure = "Hermes didn't answer in time. The install may still finish on the host; pull to refresh in a minute."
            } else {
                failure = "Install failed. \(error.dashboardMessage)"
            }
            return false
        }
    }

    /// Updates a plugin; a `consent` or `scan` answer changed nothing and comes back for the user to decide on.
    func update(_ plugin: AgentPlugin, acceptCapabilities: Bool = false, force: Bool = false) async -> PluginUpdateOutcome? {
        guard let api, busy == nil else { return nil }
        busy = plugin.id
        defer { busy = nil }
        do {
            let outcome = try await api.update(name: plugin.name, acceptCapabilities: acceptCapabilities, force: force)
            switch outcome {
            case .applied:
                notice = "\(plugin.name) updated. Restart the gateway to load the new code."
                await reloadPlugins()
            case .unchanged:
                notice = "\(plugin.name) is already up to date."
                await reloadPlugins()
            case .consent, .scan:
                break
            }
            return outcome
        } catch {
            failure = "Could not update \(plugin.name). \(error.dashboardMessage)"
            return nil
        }
    }

    /// Saves a plugin's settings form (`saveAgentPluginSettings`): secrets first through the credential route,
    /// then the values over `plugins.manage settings`. A secret-only save still makes the (empty) settings call,
    /// which is what tells the plugin its settings changed. Answers whether everything landed.
    func saveSettings(_ plugin: AgentPlugin, _ changes: PluginSettingsChanges) async -> Bool {
        guard let api, busy == nil, !changes.isEmpty else { return false }
        busy = plugin.id
        defer { busy = nil }
        do {
            if !changes.secrets.isEmpty {
                guard let writeSecret else { throw DashboardError.rpc("Secrets can't be saved from here.") }
                for (env, value) in changes.secrets.sorted(by: { $0.key < $1.key }) { try await writeSecret(env, value) }
            }
            let refreshed = try await api.saveSettings(key: plugin.key ?? plugin.name, values: changes.values)
            if let refreshed, let index = plugins?.firstIndex(where: { $0.id == plugin.id }) {
                plugins?[index] = refreshed
            } else {
                await reloadPlugins()
            }
            notice = "\(plugin.name) settings saved."
            return true
        } catch {
            guard !error.isCancellation else { return false }
            failure = "Could not save \(plugin.name)'s settings. \(error.dashboardMessage)"
            return false
        }
    }

    func remove(_ plugin: AgentPlugin) async -> Bool {
        guard let api, busy == nil else { return false }
        busy = plugin.id
        defer { busy = nil }
        do {
            try await api.remove(name: plugin.name)
            plugins?.removeAll { $0.id == plugin.id }
            notice = "\(plugin.name) uninstalled. Restart the gateway to unload it."
            await load()
            return true
        } catch {
            failure = "Could not uninstall \(plugin.name). \(error.dashboardMessage)"
            return false
        }
    }
}

/// Capabilities ▸ Plugins (`plugins/plugins-tab.tsx`): the profile's agent plugins with their switches and the
/// curated catalog. The phone manages a package's agent half; a desktop half runs in the desktop app only.
struct PluginsTab: View {
    let context: CapabilitiesContext
    @Binding var query: String
    @StateObject private var store: PluginsStore
    @State private var opened: String?
    @State private var reviewing: PluginCatalogEntry?
    @State private var installingFromGit = false
    @State private var confirmation: CapabilityConfirmation?
    @State private var shownReport: String?

    init(context: CapabilitiesContext, query: Binding<String>) {
        self.context = context
        _query = query
        let client = context.client, profile = context.profile
        _store = StateObject(wrappedValue: PluginsStore(api: context.plugins, catalogAPI: context.pluginCatalog) { env, value in
            try await client.setEnv(env, value: value, profile: profile)
        })
    }

    var body: some View {
        List {
            if store.api == nil {
                ContentUnavailableView("Not connected to Hermes", systemImage: "bolt.horizontal.circle",
                                       description: Text("Plugins are managed over the live connection to Hermes. Reconnect, then pull to refresh."))
                    .listRowBackground(Color.clear)
            } else if let plugins = store.plugins {
                content(plugins)
            } else if let error = store.loadError {
                CapabilityLoadFailure(title: "Could not load agent plugins", message: error) { Task { await store.load() } }
            } else {
                CapabilityLoader()
            }
        }
        .capabilityList()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search plugins")
        .refreshable { await store.load() }
        .task { await store.loadOnce() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { installingFromGit = true } label: { Label("Install from Git", systemImage: "arrow.down.circle") }
                        .disabled(store.api == nil)
                    Button { Task { await store.load() } } label: { Label("Rescan", systemImage: Theme.Icon.retry) }
                } label: {
                    if store.installing || store.busy != nil { ProgressView() } else { Image(systemName: Theme.Icon.more) }
                }
                .accessibilityLabel("Plugin actions")
            }
        }
        .navigationDestination(item: $opened) { id in
            PluginDetailScreen(store: store, id: id, profileLabel: context.profileLabel)
        }
        .sheet(item: $reviewing, onDismiss: showReport) { entry in
            NavigationStack { PluginCatalogSheet(store: store, entry: entry, profileLabel: context.profileLabel) }
        }
        .sheet(isPresented: $installingFromGit, onDismiss: showReport) {
            NavigationStack { PluginGitInstallSheet(store: store, profileLabel: context.profileLabel) }
        }
        .alert("Installed", isPresented: Binding(get: { shownReport != nil }, set: { if !$0 { shownReport = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shownReport ?? "")
        }
        .capabilityConfirmation($confirmation)
        .failureAlert($store.failure)
        .capabilityNotice($store.notice)
    }

    @ViewBuilder private func content(_ plugins: [AgentPlugin]) -> some View {
        let installed = PluginCuration.filter(plugins, query: query)
        let available = PluginCuration.available(store.catalog ?? [], installed: plugins, query: query,
                                                 catalogDescribesScope: context.profile == nil)
        Section {
            if installed.isEmpty {
                if CapabilitySearch.normalize(query).isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("No agent plugins installed for this profile.").foregroundStyle(Theme.Text.secondary)
                        Text("Browse the catalog below and install a reviewed plugin.").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                    }
                } else {
                    Text("Nothing matches “\(query.trimmingCharacters(in: .whitespaces))”.").foregroundStyle(Theme.Text.tertiary)
                }
            }
            ForEach(installed) { plugin in row(plugin) }
        } header: {
            FormNote("Agent in \(context.profileLabel)")
        } footer: {
            FormNote("Extend the agent for the selected profile — tools, hooks, providers.")
        }
        .hermesFormRows()
        Section {
            if store.catalog == nil, store.catalogError == nil {
                CapabilityLoader()
            } else if let error = store.catalogError {
                FormNote("Could not load the catalog. \(error)", color: Theme.destructive)
                Button("Try again") { Task { await store.reloadCatalog() } }
            } else if available.isEmpty {
                FormNote(CapabilitySearch.normalize(query).isEmpty ? "Every catalog plugin is installed." : "No matches in the catalog.")
            } else {
                ForEach(available) { entry in
                    CapabilityRow(label: CapabilityRowLabel(title: entry.title, subtitle: entry.description,
                                                            tags: [tierTag(entry.tier)], meta: entry.version.isEmpty ? nil : "v\(entry.version)"),
                                  open: { reviewing = entry }) {
                        Button("Add") { reviewing = entry }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Add \(entry.title)")
                    }
                }
            }
        } header: {
            FormNote("Available to install")
        } footer: {
            FormNote("From the Hermes catalog: reviewed packages pinned to a commit. Packages that only change the desktop app aren't listed here.")
        }
        .hermesFormRows()
    }

    private func row(_ plugin: AgentPlugin) -> some View {
        CapabilityRow(label: CapabilityRowLabel(title: plugin.name, subtitle: plugin.description, tags: Self.tags(plugin),
                                                meta: plugin.version.isEmpty ? nil : "v\(plugin.version)"),
                      open: { opened = plugin.id }) {
            if store.isBusy(plugin) {
                ProgressView()
            } else {
                Toggle(plugin.name, isOn: Binding(get: { plugin.enabled }, set: { on in Task { await store.toggle(plugin, enable: on) } }))
                    .labelsHidden()
                    .disabled(!plugin.toggleable || store.busy != nil)
            }
        }
        .swipeActions(edge: .trailing) {
            if plugin.removable {
                Button("Uninstall", role: .destructive) { confirmRemove(plugin) }
            }
            if plugin.toggleable {
                Button(plugin.enabled ? "Disable" : "Enable") { Task { await store.toggle(plugin, enable: !plugin.enabled) } }
                    .tint(plugin.enabled ? Theme.Text.tertiary : Theme.primary)
            }
        }
        .contextMenu {
            Button { opened = plugin.id } label: { Label("Open", systemImage: "shippingbox") }
            if plugin.toggleable {
                Button { Task { await store.toggle(plugin, enable: !plugin.enabled) } } label: {
                    Label(plugin.enabled ? "Disable" : "Enable", systemImage: plugin.enabled ? "pause.circle" : "play.circle")
                }
            }
            if plugin.removable {
                Button(role: .destructive) { confirmRemove(plugin) } label: { Label("Uninstall", systemImage: Theme.Icon.delete) }
            }
        }
    }

    /// An install's follow-ups wait for its sheet to close, so the alert has somewhere to show.
    private func showReport() {
        shownReport = store.report
        store.report = nil
    }

    private func confirmRemove(_ plugin: AgentPlugin) {
        confirmation = PluginDetailScreen.removeConfirmation(plugin, profileLabel: context.profileLabel) {
            _ = await store.remove(plugin)
        }
    }

    /// The row's pills: kind, provenance, portable, and each declared server's state (`PackageRow`).
    static func tags(_ plugin: AgentPlugin) -> [CapabilityTag] {
        var tags = [CapabilityTag(text: plugin.hasDesktopHalf ? "Agent + Desktop" : "Agent"),
                    CapabilityTag(text: plugin.provenance, tone: plugin.catalogTier == "official" ? .accent : plugin.catalogTier == "verified" ? .good : .muted)]
        if plugin.portable { tags.append(CapabilityTag(text: "portable")) }
        for server in plugin.servers {
            tags.append(CapabilityTag(text: "\(server.name): \(server.stateLabel)", tone: server.connected ? .good : .warning))
        }
        return tags
    }

    private func tierTag(_ tier: String) -> CapabilityTag {
        switch tier {
        case "official": return CapabilityTag(text: "Official", tone: .accent)
        case "verified": return CapabilityTag(text: "Verified", tone: .good, systemImage: "checkmark.circle")
        default: return CapabilityTag(text: "Community")
        }
    }
}
