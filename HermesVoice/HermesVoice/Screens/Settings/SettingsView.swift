import SwiftUI
import UniformTypeIdentifiers

/// Where Settings navigates: a page (its subpage list, or its content when it has one), or a subpage with the
/// row to scroll to.
enum SettingsRoute: Hashable {
    case page(SettingsPageID)
    case subpage(SettingsPageID, String?, anchor: String?)

    init(_ target: SettingsTarget) {
        self = .subpage(target.page, target.subpage, anchor: target.anchor)
    }
}

/// What the settings pages talk to: the dashboard's REST routes and the gateway's RPCs, for the profile the
/// pages edit (the shared "Applies to" scope).
@MainActor
final class SettingsContext: ObservableObject {
    let client: DashboardClient
    let gateway: GatewayClient?
    let api: ConfigAPI
    /// The profile the config, key, vault and memory pages edit, sent as `?profile=` / `profile`; nil is the
    /// dashboard's own.
    let profile: String?
    /// "Changes on this page apply to the … profile." while the pages edit a profile other than the default one.
    @Published var scopeNote: String?

    init(client: DashboardClient, gateway: GatewayClient?, profile: String? = nil) {
        self.client = client
        self.gateway = gateway
        self.profile = profile
        api = ConfigAPI(client: client, profile: profile)
    }

    /// The scope note (`SettingsProfileScope`): shown with two or more profiles while the pages edit one that isn't
    /// the default (root) profile, naming it as its chip does.
    static func scopeNote(profile: String?, profiles: [ProfileInfo], dashboardProfile: String) -> String? {
        guard profiles.count > 1 else { return nil }
        let name = profile ?? dashboardProfile
        let root = profiles.first(where: \.isDefault)?.name ?? "default"
        guard name.lowercased() != root.lowercased() else { return nil }
        let label = profiles.first { $0.name.lowercased() == name.lowercased() }.map(ProfileScopeSection.label) ?? name
        return "Changes on this page apply to the “\(label)” profile."
    }
}

/// Settings (`app/settings/index.tsx`): the desktop's pages in its order, a search over every field and row,
/// and the app's own Connection and Calls pages.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The profile new chats start in (the sidebar's), which the pages edit until another is picked; nil is the
    /// dashboard's own.
    var profile: String?

    var body: some View {
        Group {
            if let client = model.client {
                SettingsScope(client: client, gateway: model.connection?.client, inUse: profile)
            } else {
                ContentUnavailableView("Signed out", systemImage: "network.slash",
                                       description: Text("Sign in to the Hermes dashboard to change its settings."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// The shared "Applies to" scope (`SettingsProfileScope`): the profile the config-backed pages edit, following
/// the sidebar's profile until another is picked. Picking one rebuilds the pages for it.
private struct SettingsScope: View {
    let client: DashboardClient
    let gateway: GatewayClient?
    let inUse: String?
    @StateObject private var scopes = ProfileScopeModel()
    /// A profile picked here; nil follows `inUse`.
    @State private var picked: String?

    var body: some View {
        let profile = picked ?? inUse
        SettingsRoot(context: SettingsContext(client: client, gateway: gateway, profile: profile), scopes: scopes,
                     selection: Binding(get: { profile ?? scopes.dashboardProfile },
                                        set: { picked = $0 == (inUse ?? scopes.dashboardProfile) ? nil : $0 }))
            .id(profile ?? "")
            .task { await scopes.load(client) }
    }
}

private struct SettingsRoot: View {
    @StateObject private var context: SettingsContext
    @StateObject private var store: SettingsStore
    @StateObject private var catalog: ModelCatalog
    @StateObject private var routing: DelegationRoutingModel
    @ObservedObject var scopes: ProfileScopeModel
    @Binding var selection: String
    @State private var query = ""
    @State private var credentials: [SettingsSearchEntry] = []
    @State private var exported: URL?
    @State private var importing = false
    /// An imported record waiting for a yes (it clears every enabled toolset).
    @State private var pendingImport: JSONValue?
    @State private var confirmingReset = false
    @State private var configFailure: String?

    init(context: SettingsContext, scopes: ProfileScopeModel, selection: Binding<String>) {
        _context = StateObject(wrappedValue: context)
        _store = StateObject(wrappedValue: SettingsStore(transport: context.api))
        _catalog = StateObject(wrappedValue: ModelCatalog(api: context.api))
        _routing = StateObject(wrappedValue: DelegationRoutingModel(api: context.api))
        self.scopes = scopes
        _selection = selection
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            if searching {
                results
            } else {
                if scopes.profiles.count > 1 {
                    Section {
                        Picker("Applies to", selection: $selection) {
                            ForEach(scopes.profiles) { profile in
                                Text(ProfileScopeSection.label(profile)).tag(profile.name)
                            }
                        }
                    } footer: {
                        FormNote(context.scopeNote ?? "Model, chat, workspace, safety, memory, keys and passwords are kept per profile.")
                    }
                    .hermesFormRows()
                }
                ForEach(Array(SettingsPageID.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { page in
                            NavigationLink(value: SettingsRoute.page(page)) {
                                Label(page.title, systemImage: page.icon).foregroundStyle(Theme.Text.primary)
                            }
                        }
                    }
                    .hermesFormRows()
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
        .task(id: searching) {
            // Credential rows join the index the first time a search starts.
            guard searching, credentials.isEmpty, let catalog = try? await context.client.envVars(profile: context.profile) else { return }
            credentials = SettingsSearch.credentialEntries(catalog)
        }
        .onChange(of: [scopes.profiles.map(\.name), [scopes.dashboardProfile]], initial: true) {
            context.scopeNote = SettingsContext.scopeNote(profile: context.profile, profiles: scopes.profiles,
                                                          dashboardProfile: scopes.dashboardProfile)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { configMenu }
        }
        .sheet(item: Binding(get: { exported.map(SharedFile.init) }, set: { if $0 == nil { finishExport() } })) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task { await importConfig(result) }
        }
        .confirmationDialog("Reset all settings to Hermes defaults?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset to defaults", role: .destructive) { Task { await resetConfig() } }
        } message: {
            Text(context.scopeNote ?? "Keys, accounts and chats stay.")
        }
        .alert("Remove all enabled toolsets?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
               presenting: pendingImport) { record in
            Button("Cancel", role: .cancel) {}
            Button("Import", role: .destructive) { Task { await save(record) } }
        } message: { _ in
            Text("The imported config enables no toolsets: memory, terminal, web search, delegation and most other tools stay off until you re-enable them.")
        }
        .alert("Settings", isPresented: Binding(get: { configFailure != nil }, set: { if !$0 { configFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(configFailure ?? "")
        }
        .hermesForm()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .navigationDestination(for: SettingsRoute.self) { route in
            Group {
                switch route {
                case let .page(page): SettingsPageView(page: page)
                case let .subpage(page, subpage, anchor): SettingsContentView(page: page, subpage: subpage, anchor: anchor)
                }
            }
            .environmentObject(context)
            .environmentObject(store)
            .environmentObject(catalog)
            .environmentObject(routing)
        }
        .task { await store.load() }
    }

    // MARK: Export, import, reset (the desktop's settings footer)

    private var configMenu: some View {
        Menu {
            Button { Task { await exportConfig() } } label: { Label("Export config", systemImage: "square.and.arrow.up") }
            Button { importing = true } label: { Label("Import config", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) { confirmingReset = true } label: {
                Label("Reset to defaults", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Config actions")
    }

    /// The scoped profile's record as `hermes-config.json`, handed to the share sheet and deleted after it.
    private func exportConfig() async {
        do {
            let record = try await context.api.config()
            let data = try JSONSerialization.data(withJSONObject: record.anyValue, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-config.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exported = url
        } catch {
            configFailure = "Couldn't export the config: \(error.localizedDescription)"
        }
    }

    private func finishExport() {
        if let exported { try? FileManager.default.removeItem(at: exported) }
        exported = nil
    }

    /// Saves an imported JSON record (a sparse `PUT /api/config` deep-merges it), asking first when it would
    /// clear every enabled toolset.
    private func importConfig(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let record = try JSONValue(jsonData: Data(contentsOf: url))
            guard record.objectValue != nil else { throw DashboardError.rpc("The file isn't a Hermes config (a JSON object).") }
            if let toolsets = record["toolsets"], SettingsStore.clearsToolsets(from: store.value("toolsets"), to: toolsets) {
                pendingImport = record
                return
            }
            await save(record)
        } catch {
            configFailure = "Couldn't import the config: \(error.localizedDescription)"
        }
    }

    private func resetConfig() async {
        do {
            await save(try await context.api.defaults())
        } catch {
            configFailure = "Couldn't reset the settings: \(error.localizedDescription)"
        }
    }

    private func save(_ record: JSONValue) async {
        do {
            try await context.api.save(record)
            await store.load()
            NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
        } catch {
            configFailure = error.localizedDescription
        }
    }

    @ViewBuilder private var results: some View {
        let hits = SettingsSearch.filter(store.searchEntries() + SettingsManifest.entries + credentials, query: query)
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(hits) { hit in
                    NavigationLink(value: SettingsRoute(hit.target)) {
                        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                            Image(systemName: hit.icon).foregroundStyle(Theme.Text.tertiary).frame(width: 20)
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(hit.label).foregroundStyle(Theme.Text.primary)
                                Text(hit.context).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                }
            }
            .hermesFormRows()
        }
    }
}

/// A page: its subpages to pick from, or its content when it has at most one.
struct SettingsPageView: View {
    let page: SettingsPageID

    var body: some View {
        let subpages = SettingsCatalog.subpages(page)
        if subpages.count > 1 {
            List {
                Section {
                    ForEach(subpages) { subpage in
                        NavigationLink(value: SettingsRoute.subpage(page, subpage.id, anchor: nil)) {
                            Label(subpage.title, systemImage: subpage.icon).foregroundStyle(Theme.Text.primary)
                        }
                    }
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
        } else {
            SettingsContentView(page: page, subpage: subpages.first?.id, anchor: nil)
        }
    }
}

/// The scope note on a page that edits the scoped profile (nothing while it edits the default one).
struct SettingsScopeNote: View {
    @EnvironmentObject private var context: SettingsContext

    var body: some View {
        if let note = context.scopeNote {
            Section {
                Label { Text(note) } icon: { Image(systemName: "person.crop.circle") }
                    .hermesText(.caption)
                    .foregroundStyle(Theme.primary)
            }
            .hermesFormRows()
        }
    }
}

/// The content of one page or subpage.
struct SettingsContentView: View {
    @EnvironmentObject private var context: SettingsContext
    let page: SettingsPageID
    let subpage: String?
    let anchor: String?

    private var title: String {
        SettingsCatalog.subpages(page).first { $0.id == subpage }?.title ?? page.title
    }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .model, .chat, .workspace, .safety, .browser, .memory, .advanced:
            if let section = SettingsCatalog.section(page) {
                ConfigSubpageView(section: section, subpage: section.subpages.first { $0.id == subpage }, anchor: anchor)
            }
        case .appearance: AppearanceSettingsView(subpage: subpage, anchor: anchor)
        case .vault: VaultSettingsView(subpage: subpage)
        case .notifications: NotificationsSettingsView(anchor: anchor)
        case .billing: BillingSettingsView()
        case .providers: ProvidersPage(scope: context.profile)
        case .profiles: ProfilesPage()
        case .connection: ConnectionSettingsView()
        case .calls: CallsSettingsView()
        case .apiKeys: KeysSettingsView(view: subpage ?? "tools", anchor: anchor)
        case .sessions: SessionsSettingsView(subpage: subpage, anchor: anchor)
        case .about: AboutSettingsView()
        }
    }
}

/// Scrolls to `anchor` once the page has rows, and tints that row for a moment (the desktop's deep-link flash).
struct SettingsAnchor: ViewModifier {
    let anchor: String?
    let ready: Bool
    @State private var done = false

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: ready, initial: true) { _, isReady in
                guard isReady, !done, let anchor else { return }
                done = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    withAnimation { proxy.scrollTo(anchor, anchor: .center) }
                }
            }
        }
    }
}

extension View {
    func settingsAnchor(_ anchor: String?, ready: Bool = true) -> some View {
        modifier(SettingsAnchor(anchor: anchor, ready: ready))
    }
}

/// A schema section's subpage (`ConfigSettings`): its fields, rendered by type, with the model page's own
/// panels and the memory provider's settings in their places.
struct ConfigSubpageView: View {
    @EnvironmentObject private var store: SettingsStore
    let section: SettingsSection
    let subpage: SettingsSubpage?
    let anchor: String?
    @State private var modelInfo: ConfigAPI.ModelInfo?
    @EnvironmentObject private var catalog: ModelCatalog

    private var subpageID: String? { subpage?.id }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Settings didn't load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await store.load() } }
                }
            case .loaded:
                form
            }
        }
        .background(Theme.sidebar)
        .alert(store.confirmation?.title ?? "", isPresented: Binding(get: { store.confirmation != nil },
                                                                      set: { if !$0 { store.confirmation = nil } }),
               presenting: store.confirmation) { confirmation in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { store.confirm(confirmation) }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var form: some View {
        let fields = store.fields(in: section, subpage: subpage)
        let embedded = section.page == .model && ["main", "auxiliary", "moa"].contains(subpageID)
        // Safety > Privacy also carries the shared-metrics consent (`showSharedMetrics`).
        let sharedMetrics = section.page == .safety && subpageID == "privacy"
        return Form {
            SettingsScopeNote()
            if section.page == .model {
                switch subpageID {
                case "main"?: MainModelSection()
                case "auxiliary"?: AuxiliaryModelsSection()
                case "moa"?: MoaSection()
                case "delegation"?: DelegationRoutingSection()
                default: EmptyView()
                }
            }
            if !fields.isEmpty {
                Section {
                    ForEach(fields, id: \.key) { key, _ in
                        ConfigFieldRow(key: key, note: key == "model_context_length" ? MainModelSection.contextNote(modelInfo) : nil)
                            .id(key)
                        if key == "memory.provider", SettingsCatalog.isExternalMemoryProvider(store.value(key)),
                           let name = store.value(key)?.stringValue {
                            MemoryProviderPanel(provider: name).id("memory.provider.\(name)")
                        }
                    }
                } footer: {
                    if let hint = restartHint(fields.map(\.key)) { FormNote(hint, color: Theme.Text.secondary) }
                }
                .hermesFormRows()
            } else if !embedded && !sharedMetrics {
                Section {
                    ContentUnavailableView("Nothing to change here", systemImage: section.page.icon,
                                           description: Text("This Hermes host has none of these settings."))
                }
                .listRowBackground(Color.clear)
            }
            if sharedMetrics { SharedMetricsRow() }
        }
        .hermesForm()
        .settingsAnchor(anchor)
        .refreshable { await store.load() }
        .task(id: subpageID) {
            if section.page == .model, subpageID == "main" { modelInfo = try? await catalog.api.modelInfo() }
        }
    }

    /// "Restart Hermes to apply …" for the fields saved here whose schema asks for a restart.
    private func restartHint(_ keys: [String]) -> String? {
        let pending = keys.filter { store.restartPending.contains($0) }
        guard !pending.isEmpty else { return nil }
        let hints = Set(pending.compactMap { store.field($0)?.restartHint })
        if hints.count == 1, let hint = hints.first { return hint }
        let names = pending.map(SettingsCatalog.label(for:)).joined(separator: ", ")
        return "Restart Hermes to apply \(names)."
    }
}
