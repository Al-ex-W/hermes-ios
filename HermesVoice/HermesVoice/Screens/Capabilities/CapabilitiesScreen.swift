import SwiftUI

/// What the Capabilities tabs talk to, for the profile they configure: the dashboard's REST routes and the
/// gateway's RPCs. `profile` nil is the dashboard's own profile. The Connectors tab (`ConnectorsScreen`) gets the
/// same context, also as an environment object.
@MainActor
final class CapabilitiesContext: ObservableObject {
    let client: DashboardClient
    let gateway: GatewayClient?
    /// The profile every tab reads and writes (`?profile=` / `profile`); nil is the dashboard's own.
    let profile: String?
    /// How the profile is named in copy ("Agent in Work"); the default profile reads "Hermes (default)".
    let profileLabel: String

    init(client: DashboardClient, gateway: GatewayClient?, profile: String?, profileLabel: String? = nil) {
        self.client = client
        self.gateway = gateway
        self.profile = profile
        self.profileLabel = profileLabel ?? profile ?? "Hermes (default)"
    }

    /// The same connection, configuring `profile`.
    func scoped(to profile: String?, label: String? = nil) -> CapabilitiesContext {
        CapabilitiesContext(client: client, gateway: gateway, profile: profile, profileLabel: label)
    }

    var skills: SkillsAPI { SkillsAPI(transport: client, profile: profile) }
    var toolsets: ToolsetsAPI { ToolsetsAPI(transport: client, profile: profile) }
    var actions: CapabilityActionsAPI { CapabilityActionsAPI(transport: client) }
    var pluginCatalog: PluginCatalogAPI { PluginCatalogAPI(transport: client) }
    var config: ConfigAPI { ConfigAPI(client: client, profile: profile) }
    /// Nil while the gateway socket isn't up: the Plugins tab says so.
    var plugins: PluginsAPI? { gateway.map { PluginsAPI(gateway: $0.transport, profile: profile) } }
}

/// The desktop's tabs (`CAPABILITY_MODES`), in its order; the Tools tab is the `toolsets` mode.
enum CapabilityTab: String, CaseIterable, Identifiable {
    case skills, plugins, connectors, tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skills: return "Skills"
        case .plugins: return "Plugins"
        case .connectors: return "Connectors"
        case .tools: return "Tools"
        }
    }
}

/// Capabilities for the signed-in dashboard: an entry point that needs no client of its own. `profile` is the one
/// the sidebar shows (nil: all profiles, so the dashboard's own). Place it inside a `NavigationStack`.
struct CapabilitiesView: View {
    @EnvironmentObject private var model: AppModel
    var profile: String?

    var body: some View {
        if let client = model.client {
            CapabilitiesScreen(context: CapabilitiesContext(client: client, gateway: model.connection?.client, profile: profile))
        } else {
            ContentUnavailableView("Signed out", systemImage: "network.slash",
                                   description: Text("Sign in to the Hermes dashboard to manage its capabilities."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationTitle("Capabilities")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Capabilities (`app/capabilities/index.tsx`): Skills, Plugins, Connectors and Tools for one profile, with the
/// profile scope ("Configuring") above them. Starts on `context.profile` (the sidebar's); picking another profile
/// rebuilds the tabs for it, so nothing of one profile's edits or pending writes reaches another. The search
/// query is shared by the tabs, like the desktop's. Place it inside a `NavigationStack`; it pushes its detail
/// pages onto that stack.
struct CapabilitiesScreen: View {
    let context: CapabilitiesContext
    @StateObject private var scopes = ProfileScopeModel()
    @SceneStorage("capabilities.tab") private var tab: CapabilityTab = .skills
    /// A profile picked here; nil follows `context.profile`.
    @State private var picked: String?
    @State private var query = ""

    init(context: CapabilitiesContext) {
        self.context = context
    }

    var body: some View {
        let profile = picked ?? context.profile
        let scoped = context.scoped(to: profile, label: label(for: profile))
        tabContent(scoped)
            .id("\(tab.rawValue)|\(profile ?? "")")
            .environmentObject(scoped)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .background(Theme.sidebar)
            .navigationTitle("Capabilities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .task { await scopes.load(context.client) }
    }

    @ViewBuilder private func tabContent(_ scoped: CapabilitiesContext) -> some View {
        switch tab {
        case .skills:
            SkillsTab(context: scoped, query: $query)
        case .plugins:
            PluginsTab(context: scoped, query: $query)
        case .connectors:
            // MARK: Connectors slot
            // The Connectors tab (MCP servers and connector accounts) is built by the connectors role in
            // Screens/Capabilities/Connectors/ as `ConnectorsScreen(context:)`. It gets the scoped context (also
            // as an environment object), owns its own search and toolbar, and pushes onto this navigation stack.
            ConnectorsScreen(context: scoped)
        case .tools:
            ToolsetsTab(context: scoped, query: $query)
        }
    }

    /// The tab picker and, with two or more profiles, the profile the tabs configure.
    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            Picker("Capabilities", selection: $tab) {
                ForEach(CapabilityTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            if scopes.profiles.count > 1 {
                HStack(spacing: Theme.Spacing.md) {
                    Text("Configuring")
                        .hermesText(.label)
                        .foregroundStyle(Theme.Text.tertiary)
                    Spacer(minLength: 0)
                    Picker("Configuring", selection: scopeSelection) {
                        ForEach(scopes.profiles) { profile in
                            Text(ProfileScopeSection.label(profile)).tag(profile.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.Text.primary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.md)
        .background(Theme.sidebar)
        .hermesHairline()
    }

    /// The selected profile's name; the dashboard's own when nothing is scoped. Picking the starting profile
    /// again drops the override.
    private var scopeSelection: Binding<String> {
        Binding(get: { picked ?? context.profile ?? scopes.dashboardProfile },
                set: { picked = $0 == (context.profile ?? scopes.dashboardProfile) ? nil : $0 })
    }

    private func label(for profile: String?) -> String? {
        let name = profile ?? scopes.dashboardProfile
        guard let info = scopes.profiles.first(where: { $0.name.lowercased() == name.lowercased() }) else { return profile }
        return info.isDefault ? "Hermes (default)" : ProfileScopeSection.label(info)
    }
}
