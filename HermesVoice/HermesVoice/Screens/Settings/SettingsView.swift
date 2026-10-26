import SwiftUI

/// Where Settings navigates: a page (its subpage list, or its content when it has one), or a subpage with the
/// row to scroll to.
enum SettingsRoute: Hashable {
    case page(SettingsPageID)
    case subpage(SettingsPageID, String?, anchor: String?)

    init(_ target: SettingsTarget) {
        self = .subpage(target.page, target.subpage, anchor: target.anchor)
    }
}

/// What the settings pages talk to: the dashboard's REST routes and the gateway's RPCs.
@MainActor
final class SettingsContext: ObservableObject {
    let client: DashboardClient
    let gateway: GatewayClient?
    let api: ConfigAPI

    init(client: DashboardClient, gateway: GatewayClient?) {
        self.client = client
        self.gateway = gateway
        api = ConfigAPI(client: client)
    }
}

/// Settings (`app/settings/index.tsx`): the desktop's pages in its order, a search over every field and row,
/// and the app's own Connection and Calls pages.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let client = model.client {
                SettingsRoot(context: SettingsContext(client: client, gateway: model.connection?.client))
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

private struct SettingsRoot: View {
    @StateObject private var context: SettingsContext
    @StateObject private var store: SettingsStore
    @StateObject private var catalog: ModelCatalog
    @State private var query = ""
    @State private var credentials: [SettingsSearchEntry] = []

    init(context: SettingsContext) {
        _context = StateObject(wrappedValue: context)
        _store = StateObject(wrappedValue: SettingsStore(transport: context.api))
        _catalog = StateObject(wrappedValue: ModelCatalog(api: context.api))
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List {
            if searching {
                results
            } else {
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
            guard searching, credentials.isEmpty, let catalog = try? await context.client.envVars() else { return }
            credentials = SettingsSearch.credentialEntries(catalog)
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
        }
        .task { await store.load() }
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

/// The content of one page or subpage.
struct SettingsContentView: View {
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
        case .providers: ProvidersPage()
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
        return Form {
            if section.page == .model {
                switch subpageID {
                case "main"?: MainModelSection()
                case "auxiliary"?: AuxiliaryModelsSection()
                case "moa"?: MoaSection()
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
            } else if !embedded {
                Section {
                    ContentUnavailableView("Nothing to change here", systemImage: section.page.icon,
                                           description: Text("This Hermes host has none of these settings."))
                }
                .listRowBackground(Color.clear)
            }
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
