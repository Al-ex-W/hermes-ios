import SwiftUI

/// `GET /api/delegation/routing`: how each subagent gets its model (`delegation.backend`): Default (the subagent
/// model), or a plugin backend such as the Advanced Delegation plugin's model routes or profile routes. Read
/// leniently; route editing stays on the desktop.
struct DelegationRouting: Equatable {
    struct Backend: Equatable {
        var name: String
        var label: String
        var description: String
        var available: Bool
        var reason: String
    }

    /// A model route or profile route, as the list shows it.
    struct Route: Equatable {
        var name: String
        var detail: String
    }

    /// The saved backend (`default` when unset).
    var configured: String
    /// Why the saved backend can't run here; Hermes then refuses every subagent rather than run Default.
    var blockedReason: String?
    var backends: [Backend]
    var modelRoutes: [Route]
    var modelDefault: String?
    var profileRoutes: [Route]
    var profileDefault: String?

    init(_ json: JSONValue) {
        configured = json["configured"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        blockedReason = json["blocked_reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        backends = (json["backends"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            return Backend(name: name, label: row["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? Self.label(name),
                           description: row["description"]?.stringValue ?? "", available: row["available"]?.boolValue ?? true,
                           reason: row["reason"]?.stringValue ?? "")
        }
        modelRoutes = (json["model_map"]?["options"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            let model = row["model"]?.stringValue ?? "", provider = row["provider"]?.stringValue ?? ""
            return Route(name: name, detail: provider.isEmpty ? model : "\(model) · \(provider)")
        }
        modelDefault = json["model_map"]?["default"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        profileRoutes = (json["profile_routes"]?["profiles"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            return Route(name: name, detail: row["description"]?.stringValue ?? "")
        }
        profileDefault = json["profile_routes"]?["default"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func label(_ mode: String) -> String {
        switch mode {
        case "default": return "Default"
        case "model_map": return "Model routes"
        case "profile_routes": return "Profile routes"
        default: return SettingsText.prettyName(mode)
        }
    }

    func label(_ mode: String) -> String {
        backends.first { $0.name == mode }?.label ?? Self.label(mode)
    }

    /// Any mode but Default picks each subagent's model itself, so the subagent model doesn't apply
    /// (`routesOwnSubagentModel`).
    var ownsSubagentModel: Bool { configured != "default" }

    /// The modes to offer: Default, every backend that can run, and the saved one (never blocked from showing).
    var modes: [String] {
        var modes = ["default"]
        for backend in backends where backend.name != "default" && (backend.available || backend.name == configured) {
            modes.append(backend.name)
        }
        if !modes.contains(configured) { modes.append(configured) }
        return modes
    }

    /// Why the subagent model doesn't apply in the saved mode (`inactiveReason`).
    var inactiveReason: String {
        switch configured {
        case "model_map":
            return modelDefault.map { "Model routes pick each subagent's model. Subagents that pick no route use “\($0)”." }
                ?? "Model routes pick each subagent's model. Subagents that pick no route use the main agent's model."
        case "profile_routes":
            return profileDefault.map { "Profile routes pick each subagent's profile. Subagents that pick no profile run as “\($0)”." }
                ?? "Profile routes pick each subagent's profile. Subagents that pick no profile use the main agent's model."
        default:
            return "\(label(configured)) decides each subagent's model, so this setting does not apply."
        }
    }
}

extension ConfigAPI {
    /// The profile's subagent routing; nil when the host has no routing routes (an older Hermes).
    func delegationRouting() async throws -> DelegationRouting? {
        do {
            return DelegationRouting(JSONValue(any: try await client.request("GET", "/api/delegation/routing",
                                                                              query: profile.map { ["profile": $0] } ?? [:])))
        } catch DashboardError.http(404, _) {
            return nil
        }
    }

    /// `PUT /api/delegation/backend`: only Default or a backend that can run for this profile.
    func selectDelegationBackend(_ backend: String) async throws {
        _ = try await client.request("PUT", "/api/delegation/backend", query: profile.map { ["profile": $0] } ?? [:],
                                     body: ["backend": backend])
    }
}

/// The routing of one settings scope, shared by the Routing section and the Subagent Model row it gates.
@MainActor
final class DelegationRoutingModel: ObservableObject {
    @Published private(set) var routing: DelegationRouting?
    @Published private(set) var busy = false
    @Published var failure: String?
    let api: ConfigAPI

    init(api: ConfigAPI) {
        self.api = api
    }

    func load() async {
        do {
            routing = try await api.delegationRouting()
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
        }
    }

    func choose(_ mode: String) async {
        guard let routing, mode != routing.configured else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await api.selectDelegationBackend(mode)
        } catch {
            failure = "Could not change subagent routing: \(error.dashboardMessage)"
        }
        await load()
    }
}

/// Settings > Model > Subagents > Routing (`DelegationRoutingSlot`): the mode, why a saved mode can't run, and the
/// routes it uses. Hidden on a host without routing.
struct DelegationRoutingSection: View {
    @EnvironmentObject private var model: DelegationRoutingModel

    var body: some View {
        Group {
            if let routing = model.routing {
                Section {
                    Picker("Mode", selection: Binding(get: { routing.configured }, set: { mode in
                        Task { await model.choose(mode) }
                    })) {
                        ForEach(routing.modes, id: \.self) { Text(routing.label($0)).tag($0) }
                    }
                    .disabled(model.busy)
                    if let blocked = routing.blockedReason {
                        Label { Text("Not running: \(blocked) Hermes refuses every subagent until this is fixed or you pick Default.") }
                            icon: { Image(systemName: Theme.Icon.warning) }
                            .hermesText(.caption)
                            .foregroundStyle(Theme.destructive)
                    }
                    if routing.configured == "model_map" {
                        routes(routing.modelRoutes, default: routing.modelDefault,
                               empty: "No routes yet. Until you add one, subagents use the main agent's model.")
                    } else if routing.configured == "profile_routes" {
                        routes(routing.profileRoutes, default: routing.profileDefault, empty: "No profile routes yet.")
                    }
                } header: {
                    FormNote("Routing")
                } footer: {
                    if let failure = model.failure {
                        FormNote(failure, color: Theme.destructive)
                    } else {
                        FormNote(Self.footer(routing))
                    }
                }
                .hermesFormRows()
                .id("model.delegation-routing")
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private func routes(_ routes: [DelegationRouting.Route], default chosen: String?, empty: String) -> some View {
        if routes.isEmpty {
            Text(empty).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
        }
        ForEach(routes, id: \.name) { route in
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack {
                    Text(route.name).foregroundStyle(Theme.Text.primary)
                    if route.name == chosen {
                        Text("Default").hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                    }
                }
                if !route.detail.isEmpty {
                    Text(route.detail).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(2)
                }
            }
        }
    }

    static func footer(_ routing: DelegationRouting) -> String {
        switch routing.configured {
        case "default": return "Every subagent runs on the subagent model below."
        case "model_map", "profile_routes": return "The agent picks a route for each subagent. Edit the routes in the Hermes desktop app."
        default: return routing.backends.first { $0.name == routing.configured }?.description ?? ""
        }
    }
}
