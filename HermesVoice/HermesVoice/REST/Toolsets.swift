import Foundation

// The dashboard's toolset routes (`hermes_cli/web_routers/tools.py`) and the per-tool call counts from
// `GET /api/analytics/usage`, as the desktop's Capabilities ▸ Tools tab uses them. Decoders are lenient.

// MARK: - Toolsets

/// One row of `GET /api/tools/toolsets` (`ToolsetInfo`).
struct CapabilityToolset: Identifiable, Hashable {
    var name: String
    var label: String
    var description: String
    var enabled: Bool
    /// Every key the toolset's active provider needs is set (false: "Needs keys").
    var configured: Bool
    var tools: [String]

    var id: String { name }

    init(name: String, label: String? = nil, description: String = "", enabled: Bool = false, configured: Bool = true,
         tools: [String] = []) {
        self.name = name
        self.label = ToolsetCuration.displayLabel(label ?? name)
        self.description = description
        self.enabled = enabled
        self.configured = configured
        self.tools = tools
    }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.init(name: name, label: LenientField.text(row["label"]), description: LenientField.text(row["description"]) ?? "",
                  enabled: LenientField.bool(row["enabled"]), configured: LenientField.optionalBool(row["configured"]) ?? true,
                  tools: LenientField.strings(row["tools"]))
    }

    static func list(_ response: Any) -> [CapabilityToolset] {
        let rows = response as? [Any] ?? (response as? JSON)?["toolsets"] as? [Any] ?? []
        return rows.compactMap { ($0 as? JSON).flatMap(CapabilityToolset.init(row:)) }
    }

    /// Calls of this toolset's tools in the analytics window.
    func calls(_ counts: [String: Int]) -> Int { tools.reduce(0) { $0 + (counts[$1] ?? 0) } }
}

/// A provider row's readiness (`ToolProviderStatus`); unknown strings read as ready, like a status-less backend.
enum ToolsetProviderStatus: String, Hashable {
    case ready
    case needsSetup = "needs_setup"
    case needsAuth = "needs_auth"
    case needsKeys = "needs_keys"
}

/// One `.env` key a provider needs (`ToolEnvVar`). Only whether it is set ever arrives, never its value.
struct ToolsetEnvKey: Identifiable, Hashable {
    var key: String
    var prompt: String
    var url: String?
    /// A non-secret value with a default (a URL, a region): typed in a plain field.
    var defaultValue: String?
    var isSet: Bool

    var id: String { key }

    init(key: String, prompt: String? = nil, url: String? = nil, defaultValue: String? = nil, isSet: Bool = false) {
        self.key = key
        self.prompt = prompt ?? key
        self.url = url
        self.defaultValue = defaultValue
        self.isSet = isSet
    }

    init?(row: JSON) {
        guard let key = LenientField.text(row["key"]) else { return nil }
        self.init(key: key, prompt: LenientField.text(row["prompt"]), url: LenientField.text(row["url"]),
                  defaultValue: LenientField.text(row["default"]), isSet: LenientField.bool(row["is_set"]))
    }
}

/// One backend a toolset can use (`ToolProvider`, the `hermes tools` picker row).
struct ToolsetProvider: Identifiable, Hashable {
    var name: String
    var badge: String
    var tag: String
    var envKeys: [ToolsetEnvKey]
    /// The one-time install hook (`hermes tools post-setup <key>`), if the backend has one.
    var postSetup: String?
    var requiresNousAuth: Bool
    /// The provider written to config now.
    var isActive: Bool
    /// The server's readiness (keys, Nous entitlement, post-setup install); nil on older backends.
    var status: ToolsetProviderStatus?
    /// Web only: the backend key and which of search / extract it can serve.
    var webBackend: String?
    var capabilities: [String]
    /// A "Nous Subscription" row served through the Nous Tool Gateway.
    var managedNousFeature: String?

    var id: String { name }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        badge = LenientField.text(row["badge"]) ?? ""
        tag = LenientField.text(row["tag"]) ?? ""
        envKeys = (row["env_vars"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(ToolsetEnvKey.init(row:)) }
        postSetup = LenientField.text(row["post_setup"])
        requiresNousAuth = LenientField.bool(row["requires_nous_auth"])
        isActive = LenientField.bool(row["is_active"])
        status = LenientField.text(row["status"]).map { ToolsetProviderStatus(rawValue: $0) ?? .ready }
        webBackend = LenientField.text(row["web_backend"])
        capabilities = LenientField.strings(row["capabilities"])
        managedNousFeature = LenientField.text(row["managed_nous_feature"])
    }

    /// `providerStatus`: keys set locally since the load win over the server's (stale) answer; without a server
    /// status, keys decide.
    func readiness(_ setKeys: [String: Bool]) -> ToolsetProviderStatus {
        if !envKeys.isEmpty {
            return envKeys.allSatisfy { setKeys[$0.key] ?? $0.isSet } ? .ready : .needsKeys
        }
        return status ?? .ready
    }
}

/// A toolset's configuration page (`GET /api/tools/toolsets/{name}/config`, `ToolsetConfig`).
struct ToolsetSetup: Hashable {
    var name: String
    /// False: the toolset has nothing to configure (the page shows only its switch and tools).
    var hasCategory: Bool
    var providers: [ToolsetProvider]
    var activeProvider: String?
    /// Web only: where web_search and web_extract resolve now, and whether through the Nous Tool Gateway.
    var activeSearchBackend: String?
    var activeExtractBackend: String?
    var searchViaNous: Bool
    var extractViaNous: Bool
    /// The response carried the web capability fields at all.
    var reportsWebBackends: Bool

    init(response: Any, name: String) {
        let row = response as? JSON ?? [:]
        self.name = LenientField.text(row["name"]) ?? name
        hasCategory = LenientField.bool(row["has_category"])
        providers = (row["providers"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(ToolsetProvider.init(row:)) }
        activeProvider = LenientField.text(row["active_provider"])
        activeSearchBackend = LenientField.text(row["active_search_backend"])
        activeExtractBackend = LenientField.text(row["active_extract_backend"])
        searchViaNous = LenientField.bool(row["search_via_nous"])
        extractViaNous = LenientField.bool(row["extract_via_nous"])
        reportsWebBackends = row.keys.contains("active_search_backend")
    }

    /// The provider rows to open first (`ToolsetConfigPanel`): the active one, then the first ready one, else the first.
    var initialProvider: String? {
        (providers.first(where: \.isActive) ?? providers.first { $0.name == activeProvider }
            ?? providers.first { $0.readiness([:]) == .ready } ?? providers.first)?.name
    }

    /// Whether `provider` serves a web capability now (`capabilityServedBy`).
    func serves(_ provider: ToolsetProvider, search: Bool) -> Bool {
        let viaNous = search ? searchViaNous : extractViaNous
        if provider.managedNousFeature != nil { return viaNous }
        let backend = search ? activeSearchBackend : activeExtractBackend
        return provider.webBackend != nil && backend == provider.webBackend && !viaNous && provider.isActive
    }

    /// The label for where a web capability resolves (`webSearchActive`).
    func webBackendLabel(search: Bool) -> String {
        let managed = providers.first { $0.managedNousFeature != nil }?.name
        if (search ? searchViaNous : extractViaNous), let managed { return managed }
        return (search ? activeSearchBackend : activeExtractBackend) ?? "not set"
    }
}

/// `PUT /api/tools/toolsets/{name}/provider`'s answer.
struct ToolsetProviderChoice: Hashable {
    /// A managed Nous row picked without a Portal entitlement: saved, but inactive until the user signs in.
    var needsNousAuth: Bool

    init(response: Any) {
        needsNousAuth = LenientField.bool((response as? JSON)?["needs_nous_auth"])
    }
}

/// One model of an image or video backend (`ToolsetModel`).
struct ToolsetModelOption: Identifiable, Hashable {
    var id: String
    var display: String
    var speed: String
    var strengths: String
    var price: String

    init?(row: JSON) {
        guard let id = LenientField.text(row["id"]) else { return nil }
        self.id = id
        display = LenientField.text(row["display"]) ?? id
        speed = LenientField.text(row["speed"]) ?? ""
        strengths = LenientField.text(row["strengths"]) ?? ""
        price = LenientField.text(row["price"]) ?? ""
    }
}

/// `GET /api/tools/toolsets/{name}/models` (`ToolsetModelsResponse`).
struct ToolsetModelCatalog: Hashable {
    var models: [ToolsetModelOption]
    var current: String?
    var defaultModel: String?

    init(models: [ToolsetModelOption] = [], current: String? = nil, defaultModel: String? = nil) {
        self.models = models
        self.current = current
        self.defaultModel = defaultModel
    }

    init(response: Any) {
        let row = response as? JSON ?? [:]
        let hasModels = LenientField.optionalBool(row["has_models"]) ?? true
        models = hasModels ? (row["models"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(ToolsetModelOption.init(row:)) } : []
        current = LenientField.text(row["current"])
        defaultModel = LenientField.text(row["default"])
    }

    var selected: String? { current ?? defaultModel }
}

/// One terminal execution backend (`TerminalBackendInfo`) with its health probe.
struct TerminalBackend: Identifiable, Hashable {
    enum Status: String { case ready, needsSetup = "needs_setup", unavailable }

    var name: String
    var label: String
    var description: String
    var active: Bool
    var status: Status
    /// Setup guidance for a backend that isn't ready.
    var detail: String

    var id: String { name }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        label = LenientField.text(row["label"]) ?? EnvVar.prettyName(name)
        description = LenientField.text(row["description"]) ?? ""
        active = LenientField.bool(row["active"])
        status = LenientField.text(row["status"]).flatMap(Status.init(rawValue:)) ?? .unavailable
        detail = LenientField.text(row["detail"]) ?? ""
    }

    static func list(_ response: Any) -> [TerminalBackend] {
        ((response as? JSON)?["backends"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(TerminalBackend.init(row:)) }
    }
}

/// Computer Use readiness on the Hermes host (`GET /api/tools/computer-use/status`), shown read-only: granting the
/// macOS permissions needs someone at the host's screen.
struct ComputerUseStatus: Hashable {
    var platform: String
    var platformSupported: Bool
    var installed: Bool
    var version: String?
    var ready: Bool?
    var accessibility: Bool?
    var screenRecording: Bool?
    var error: String?

    init(response: Any) {
        let row = response as? JSON ?? [:]
        platform = LenientField.text(row["platform"]) ?? ""
        platformSupported = LenientField.bool(row["platform_supported"])
        installed = LenientField.bool(row["installed"])
        version = LenientField.text(row["version"])
        ready = LenientField.optionalBool(row["ready"])
        accessibility = LenientField.optionalBool(row["accessibility"])
        screenRecording = LenientField.optionalBool(row["screen_recording"])
        error = LenientField.text(row["error"])
    }
}

// MARK: - Curation

/// Which toolsets the phone lists, and how the Tools tab groups them (`desktop-toolsets.ts`, `toolsets-data.ts`).
enum ToolsetCuration {
    /// Platform-coupled or internal plumbing (`DESKTOP_HIDDEN_TOOLSETS`).
    static let desktopHidden: Set<String> = ["discord", "discord_admin", "yuanbao", "context_engine", "moa"]

    /// The strip rule: voice features (`tts`, `stt`, wake word) are left out with the same prefixes Settings
    /// hides their config keys by, so neither the toolset nor its provider and config page appear.
    static func isStripped(_ name: String) -> Bool {
        SettingsCatalog.isStripped(name.lowercased() + ".")
    }

    static func isVisible(_ name: String) -> Bool {
        !desktopHidden.contains(name) && !isStripped(name)
    }

    /// The CLI registry prefixes labels with an emoji (`stripToolsetLabel`); the dashboard strips most already.
    static func displayLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let emoji = scalar.properties.isEmoji && scalar.value > 0x7F
            guard emoji || scalar.value == 0xFE0F || scalar.value == 0x200D || scalar.properties.isWhitespace else { break }
            index += 1
        }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: scalars[index...])
        return rest.isEmpty ? trimmed : String(rest)
    }

    /// Browsing groups by what a toolset lets the agent do (`TOOLSET_THEMES`); the rest go under "More tools".
    struct Shelf: Identifiable, Hashable {
        var id: String
        var label: String
        var blurb: String
        var names: [String]
    }

    static let shelves: [Shelf] = [
        Shelf(id: "work", label: "Browse, work and automate",
              blurb: "Drive the browser and desktop, edit files, run code and schedule work.",
              names: ["browser", "computer_use", "web", "terminal", "file", "code_execution", "cronjob", "kanban", "delegation", "todo", "clarify"]),
        Shelf(id: "create", label: "See, hear and create", blurb: "Look at images and video, transcribe voice and generate media.",
              names: ["vision", "video", "stt", "tts", "image_gen", "video_gen"]),
        Shelf(id: "recall", label: "Memory and knowledge", blurb: "What Hermes remembers, and the skills and history it can search.",
              names: ["memory", "session_search", "skills"]),
        Shelf(id: "connect", label: "Connect and reach out", blurb: "Accounts, other agents, the smart home and search beyond the web.",
              names: ["connections", "a2a", "homeassistant", "x_search", "messaging", "spotify"]),
    ]
    static let more = Shelf(id: "more", label: "More tools", blurb: "Everything else this profile can switch on.", names: [])

    static func shelf(for name: String) -> Shelf { shelves.first { $0.names.contains(name) } ?? more }

    /// The feature row: four toolsets, shown once a profile has at least eight.
    static let featureCount = 4
    static let featureMinimum = 8
    /// The feature row before there is usage to rank by.
    static let essentials = ["browser", "file", "code_execution", "memory"]
    /// Toolsets with a selectable backend model catalog (`_MODEL_CATALOG_TOOLSETS`).
    static let modelCatalogToolsets: Set<String> = ["image_gen", "video_gen"]

    /// Visible toolsets matching `query` (name, label, description, tool names), most called first, then A–Z
    /// (`filteredToolsets`).
    static func filter(_ toolsets: [CapabilityToolset], query: String, calls: [String: Int]) -> [CapabilityToolset] {
        toolsets
            .filter { isVisible($0.name) && CapabilitySearch.matches(query, [$0.name, $0.label, $0.description] + $0.tools) }
            .sorted { lhs, rhs in
                let left = lhs.calls(calls), right = rhs.calls(calls)
                return left != right ? left > right : lhs.label.localizedCompare(rhs.label) == .orderedAscending
            }
    }

    struct Section: Identifiable, Hashable {
        var id: String
        var label: String
        var blurb: String
        var toolsets: [CapabilityToolset]
    }

    /// The Tools tab's sections (`ToolsetsTab`): the feature row (the four most used once each has calls, else the
    /// essentials; none while searching or with fewer than eight toolsets), then the themed groups, empty ones left out.
    static func sections(_ visible: [CapabilityToolset], query: String, calls: [String: Int]?) -> [Section] {
        let used = Array(visible.prefix(featureCount))
        let ranked = calls.map { counts in used.count == featureCount && used.allSatisfy { $0.calls(counts) > 0 } } ?? false
        let featured: [CapabilityToolset]
        if !CapabilitySearch.normalize(query).isEmpty || visible.count <= featureMinimum {
            featured = []
        } else {
            featured = ranked ? used : visible.filter { essentials.contains($0.name) }
        }
        let featuredNames = Set(featured.map(\.name))
        let rest = visible.filter { !featuredNames.contains($0.name) }
        var sections: [Section] = []
        if !featured.isEmpty {
            sections.append(ranked
                ? Section(id: "featured", label: "Most used", blurb: "The toolsets Hermes reaches for most on this profile.", toolsets: featured)
                : Section(id: "featured", label: "Essentials", blurb: "What most Hermes work runs on.", toolsets: featured))
        }
        for shelf in shelves + [more] {
            let members = rest.filter { Self.shelf(for: $0.name).id == shelf.id }
            if !members.isEmpty { sections.append(Section(id: shelf.id, label: shelf.label, blurb: shelf.blurb, toolsets: members)) }
        }
        return sections
    }
}

// MARK: - Routes

/// The toolset routes for one profile.
struct ToolsetsAPI: CapabilityRoutes {
    let transport: CapabilitiesTransport
    let profile: String?

    init(transport: CapabilitiesTransport, profile: String?) {
        self.transport = transport
        self.profile = profile
    }

    func toolsets() async throws -> [CapabilityToolset] {
        CapabilityToolset.list(try await get("/api/tools/toolsets"))
    }

    /// Turns a toolset on or off for its platform (`PUT /api/tools/toolsets/{name}`). Turning one on may start its
    /// backend's install in the background (`post_setup_started`).
    @discardableResult
    func setEnabled(_ name: String, _ enabled: Bool) async throws -> String? {
        let result = try await send("PUT", "/api/tools/toolsets/\(name)", Self.toggleBody(enabled)) as? JSON
        return LenientField.text(result?["post_setup_started"])
    }

    static func toggleBody(_ enabled: Bool) -> JSON { ["enabled": enabled] }

    func setup(_ name: String) async throws -> ToolsetSetup {
        ToolsetSetup(response: try await get("/api/tools/toolsets/\(name)/config"), name: name)
    }

    /// Makes `provider` the toolset's backend; for `web`, `capability` (search / extract) picks it for one of them.
    func selectProvider(_ name: String, provider: String, capability: String? = nil) async throws -> ToolsetProviderChoice {
        ToolsetProviderChoice(response: try await send("PUT", "/api/tools/toolsets/\(name)/provider",
                                                       Self.providerBody(provider, capability: capability)))
    }

    static func providerBody(_ provider: String, capability: String?) -> JSON {
        var body: JSON = ["provider": provider]
        if let capability { body["capability"] = capability }
        return body
    }

    /// Saves keys the toolset's providers declare (`PUT /api/tools/toolsets/{name}/env`). Values go to the
    /// dashboard in this request body only: they aren't logged, kept or echoed back in an error.
    func saveKeys(_ name: String, _ values: [String: String]) async throws {
        let values = values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.value.isEmpty }
        guard !values.isEmpty else { throw DashboardError.rpc("Enter a value first.") }
        if values.values.contains(where: CredentialMask.isPreview) {
            throw DashboardError.rpc("That's the saved key's preview. Paste the full key to replace it.")
        }
        do {
            _ = try await send("PUT", "/api/tools/toolsets/\(name)/env", ["env": values])
        } catch {
            throw values.values.reduce(error) { DashboardClient.scrubbed($0, secret: $1) }
        }
    }

    /// Removes a key from the profile's `.env` (and every mirror of it). Already gone counts as done.
    func removeKey(_ key: String) async throws {
        var body: JSON = ["key": key]
        if let profile { body["profile"] = profile }
        do {
            _ = try await send("DELETE", "/api/env", body)
        } catch let DashboardError.http(code, _) where code == 404 {
            return
        }
    }

    /// Spawns `hermes tools post-setup <key>`; its log is `tools-post-setup`.
    func runPostSetup(_ name: String, key: String) async throws -> CapabilityAction {
        CapabilityAction(response: try await send("POST", "/api/tools/toolsets/\(name)/post-setup", ["key": key]),
                         fallbackName: "tools-post-setup")
    }

    func models(_ name: String, provider: String?) async throws -> ToolsetModelCatalog {
        ToolsetModelCatalog(response: try await get("/api/tools/toolsets/\(name)/models", provider.map { ["provider": $0] } ?? [:]))
    }

    func selectModel(_ name: String, model: String, provider: String?) async throws {
        var body: JSON = ["model": model]
        if let provider { body["provider"] = provider }
        _ = try await send("PUT", "/api/tools/toolsets/\(name)/model", body)
    }

    func terminalBackends() async throws -> [TerminalBackend] {
        TerminalBackend.list(try await get("/api/tools/terminal/backends"))
    }

    func selectTerminalBackend(_ backend: String) async throws {
        _ = try await send("PUT", "/api/tools/terminal/backend", ["backend": backend])
    }

    func computerUseStatus() async throws -> ComputerUseStatus {
        ComputerUseStatus(response: try await get("/api/tools/computer-use/status"))
    }

    /// Tool name → calls over the last year (`useToolCalls`; the analytics `tools` rows).
    func toolCalls() async throws -> [String: Int] {
        Self.toolCalls(try await get("/api/analytics/usage", ["days": "365"]))
    }

    static func toolCalls(_ response: Any) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in (response as? JSON)?["tools"] as? [Any] ?? [] {
            guard let row = row as? JSON, let tool = LenientField.text(row["tool"]) ?? LenientField.text(row["name"]) else { continue }
            counts[tool, default: 0] += max(0, LenientField.int(row["count"]))
        }
        return counts
    }
}
