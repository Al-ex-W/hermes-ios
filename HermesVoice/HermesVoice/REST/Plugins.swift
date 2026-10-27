import Foundation

// Agent plugins as the desktop's Capabilities ▸ Plugins tab manages them: the gateway's `plugins.manage` RPC
// (`tui_gateway/methods_tools.py`; list, toggle, install, update, remove, settings) for the scoped profile, and the curated
// catalog the dashboard serves (`GET /api/dashboard/plugins/catalog`). The desktop half of a unified package runs
// in the desktop app only, so the phone manages the agent half. Results are decoded leniently from the raw
// JSON instead of the generated strict rows, so an older or newer backend's rows still list.

// MARK: - Installed plugins

/// One application-backed MCP server a plugin declares (`AgentPluginServer`).
struct AgentPluginServer: Identifiable, Hashable {
    var name: String
    /// connected, app_not_running, hermes_not_connected, endpoint_unavailable, … (unknown states read as unknown).
    var state: String
    /// What is missing, in a sentence.
    var sentence: String

    var id: String { name }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        state = LenientField.text(row["state"]) ?? "unknown"
        sentence = LenientField.text(row["sentence"]) ?? ""
    }

    var connected: Bool { state == "connected" }

    /// `serverStates`.
    var stateLabel: String {
        switch state {
        case "connected": return "connected"
        case "app_not_running": return "app not running"
        case "hermes_not_connected": return "MCP connection missing"
        case "endpoint_unavailable": return "endpoint unavailable"
        case "no_interactive_session": return "no interactive session"
        case "version_too_old": return "version too old"
        case "missing_app": return "app missing"
        case "unsupported_gpu": return "GPU not supported"
        default: return "status unknown"
        }
    }

    /// `SERVER_TONE`: red for states the user can't fix by starting something.
    var blocking: Bool { ["version_too_old", "missing_app", "unsupported_gpu"].contains(state) }
}

/// One `plugins.manage list` row (`AgentPluginRow`).
struct AgentPlugin: Identifiable, Hashable {
    var name: String
    /// Canonical registry key (`image_gen/fal`); absent on backends that predate key-addressed toggles.
    var key: String?
    var version: String
    var description: String
    /// bundled, user, git, project, entrypoint.
    var source: String
    /// enabled, disabled, not enabled.
    var status: String
    /// An Agent Plugins v1 package (portable skills / MCP format).
    var portable: Bool
    var catalogName: String?
    var catalogTier: String?
    var installedSha: String?
    var catalogSha: String?
    var catalogVersion: String?
    var updateAvailable: Bool
    var updateTarget: String?
    var pinnedSha: String?
    /// Ships `desktop/plugin.js` too, which only the desktop app loads.
    var hasDesktopHalf: Bool
    var servers: [AgentPluginServer]
    /// The manifest's `config_schema` with each current value (secrets only as "set").
    var settings: [PluginSetting]
    var settingsCount: Int { settings.count }

    var id: String { key ?? name }

    init(name: String, key: String? = nil, source: String = "user", status: String = "enabled") {
        self.name = name
        self.key = key
        version = ""
        description = ""
        self.source = source
        self.status = status
        portable = false
        updateAvailable = false
        hasDesktopHalf = false
        servers = []
        settings = []
    }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        key = LenientField.text(row["key"])
        version = LenientField.text(row["version"]) ?? ""
        description = LenientField.text(row["description"]) ?? ""
        source = LenientField.text(row["source"]) ?? "user"
        status = LenientField.text(row["status"])?.lowercased() ?? "not enabled"
        portable = LenientField.bool(row["portable"])
        catalogName = LenientField.text(row["catalog_name"])
        catalogTier = LenientField.text(row["catalog_tier"])
        installedSha = LenientField.text(row["installed_sha"])
        catalogSha = LenientField.text(row["catalog_sha"])
        catalogVersion = LenientField.text(row["catalog_version"])
        updateAvailable = LenientField.bool(row["update_available"])
        updateTarget = LenientField.text(row["update_target"])
        pinnedSha = LenientField.text(row["pinned_sha"])
        hasDesktopHalf = LenientField.bool(row["has_desktop_half"])
        servers = (row["servers"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(AgentPluginServer.init(row:)) }
        settings = (row["settings_schema"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(PluginSetting.init(row:)) }
    }

    init?(_ value: JSONValue?) {
        guard let row = value?.anyValue as? JSON else { return nil }
        self.init(row: row)
    }

    var enabled: Bool { status == "enabled" }
    /// Toggles are addressed by key only: bare names collide across category dirs.
    var toggleable: Bool { key != nil }
    /// Only what lives under the profile's plugins dir can be uninstalled here; bundled plugins are refused and
    /// pip (entrypoint) ones go with their package.
    var removable: Bool { source == "user" || source == "git" }

    /// The provenance tag (`ProvenancePill`): the catalog tier, a pin, else where it came from.
    var provenance: String {
        if catalogName != nil {
            switch catalogTier ?? "" {
            case "official": return "Official"
            case "verified": return "Verified"
            default: return "Community"
            }
        }
        if let pinnedSha { return "pinned @ \(pinnedSha.prefix(8))" }
        return source
    }

    /// What the Update button moves to (`updateTargetLabel`).
    var updateLabel: String {
        if let catalogVersion { return catalogVersion }
        if let catalogSha { return String(catalogSha.prefix(8)) }
        guard let updateTarget else { return "" }
        let isCommit = updateTarget.count == 40 && updateTarget.allSatisfy(\.isHexDigit)
        return isCommit ? String(updateTarget.prefix(8)) : updateTarget
    }
}

/// One manifest-declared setting (`plugins_settings.py plugin_settings_fields`). A secret carries only the `.env`
/// variable it lives in and whether it is set, never its value.
struct PluginSetting: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case string, number, boolean, choice = "enum", json, secret
    }

    var key: String
    var kind: Kind
    var label: String
    var description: String
    var required: Bool
    var choices: [String]
    var value: JSONValue?
    /// Secrets: the `.env` variable the value is stored in.
    var env: String?
    var hasValue: Bool

    var id: String { key }

    init(key: String, kind: Kind, label: String? = nil, description: String = "", required: Bool = false,
         choices: [String] = [], value: JSONValue? = nil, env: String? = nil, hasValue: Bool = false) {
        self.key = key
        self.kind = kind
        self.label = label ?? key
        self.description = description
        self.required = required
        self.choices = choices
        self.value = value
        self.env = env
        self.hasValue = hasValue
    }

    init?(row: JSON) {
        guard let key = LenientField.text(row["key"]) else { return nil }
        self.key = key
        // An unknown type renders as text, like the backend's own fallback.
        kind = LenientField.text(row["type"]).flatMap(Kind.init(rawValue:)) ?? .string
        label = LenientField.text(row["label"]) ?? key
        description = LenientField.text(row["description"]) ?? ""
        required = LenientField.bool(row["required"])
        choices = LenientField.strings(row["choices"])
        value = row["value"].map(JSONValue.init(any:))
        env = LenientField.text(row["env"])
        hasValue = LenientField.bool(row["has_value"])
        if kind == .choice, choices.isEmpty { kind = .string }
    }

    /// What the control shows before the user touches it (`INITIAL_TEXT`): every non-secret value is edited as text
    /// and coerced on save, so a half-typed number never fights the input.
    var initialText: String {
        switch kind {
        case .boolean: return value?.boolValue == true ? "true" : "false"
        case .choice: return Self.text(value) ?? choices.first ?? ""
        case .json:
            guard let value, !value.isNull,
                  let data = try? JSONSerialization.data(withJSONObject: value.anyValue, options: [.prettyPrinted, .sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        case .number, .string: return Self.text(value) ?? ""
        case .secret: return ""
        }
    }

    private static func text(_ value: JSONValue?) -> String? {
        switch value {
        case let .string(text)?: return text
        case let .int(number)?: return String(number)
        case let .double(number)?: return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case let .bool(flag)?: return flag ? "true" : "false"
        default: return nil
        }
    }

    /// The draft text as its wire value (`COERCE`); throws the field's validation message.
    func coerce(_ raw: String) throws -> JSONValue {
        switch kind {
        case .boolean: return .bool(raw == "true")
        case .choice:
            guard choices.contains(raw) else { throw DashboardError.rpc("\(label): not one of \(choices.joined(separator: ", "))") }
            return .string(raw)
        case .json:
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = (text.isEmpty ? "null" : text).data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
                  parsed is [Any] || parsed is JSON else {
                throw DashboardError.rpc("\(label): expected a JSON list or object")
            }
            return JSONValue(any: parsed)
        case .number:
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let number = Double(text), number.isFinite else {
                throw DashboardError.rpc("\(label): expected a number")
            }
            if let whole = Int(exactly: number) { return .int(whole) }
            return .double(number)
        case .string, .secret: return .string(raw)
        }
    }
}

/// A plugin settings form's two payloads (`collectChanges`): coerced non-secret values that changed, for
/// `plugins.manage settings`, and non-blank secrets by their `.env` name, for the profile's credential route.
struct PluginSettingsChanges: Equatable {
    var values: [String: JSONValue] = [:]
    var secrets: [String: String] = [:]

    var isEmpty: Bool { values.isEmpty && secrets.isEmpty }

    static func initialDraft(_ fields: [PluginSetting]) -> [String: String] {
        Dictionary(fields.map { ($0.key, $0.initialText) }, uniquingKeysWith: { first, _ in first })
    }

    /// Throws the first field's validation message.
    static func collect(_ fields: [PluginSetting], draft: [String: String]) throws -> PluginSettingsChanges {
        var changes = PluginSettingsChanges()
        for field in fields {
            let raw = draft[field.key] ?? ""
            if field.kind == .secret {
                let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !secret.isEmpty, let env = field.env { changes.secrets[env] = secret }
                continue
            }
            if raw != field.initialText { changes.values[field.key] = try field.coerce(raw) }
        }
        return changes
    }
}

/// Which installed plugins the Plugins tab lists (`isDesktopRelevantPlugin`): what the user installed, plus the
/// bundled lifecycle plugins with no settings surface of their own. Other built-ins configure from their own pages.
enum PluginCuration {
    static let hiddenKeyPrefixes = ["dashboard_auth/", "model-providers/", "platforms/"]
    static let manageableBundled: Set<String> = ["disk-cleanup", "security-guidance"]

    static func isListed(_ plugin: AgentPlugin) -> Bool {
        if plugin.source == "bundled" { return manageableBundled.contains(plugin.key ?? plugin.name) }
        guard let key = plugin.key else { return true }
        return !hiddenKeyPrefixes.contains { key.hasPrefix($0) }
    }

    /// Listed plugins matching `query` (name, key, description, source), A–Z.
    static func filter(_ plugins: [AgentPlugin], query: String) -> [AgentPlugin] {
        plugins.filter { isListed($0) && CapabilitySearch.matches(query, [$0.name, $0.key ?? "", $0.description, $0.source]) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Catalog entries to offer: not installed in the profile, usable from the phone, matching `query`.
    ///
    /// Whether an entry is installed comes from the scoped profile's own `plugins.manage list` rows (catalog name,
    /// name, key). The catalog's `installed` flag describes the dashboard's own profile only (the route takes no
    /// `?profile=`), so it counts only when `catalogDescribesScope` (the tabs configure the dashboard's profile).
    static func available(_ entries: [PluginCatalogEntry], installed: [AgentPlugin], query: String,
                          catalogDescribesScope: Bool = false) -> [PluginCatalogEntry] {
        let names = Set(installed.flatMap { [$0.catalogName, $0.name, $0.key].compactMap { $0 } })
        return entries
            .filter { !(catalogDescribesScope && $0.installed) && !names.contains($0.name) }
            .filter(isOffered)
            .filter { CapabilitySearch.matches(query, [$0.name, $0.title, $0.description, $0.maintainer, $0.category] + $0.tools) }
    }

    /// Left out of the catalog on the phone: a renderer-only desktop package (category `desktop` with no agent tools,
    /// hooks, middleware or keys: it runs in the desktop app only), and voice packages (speech, TTS, STT, live
    /// voice, wake word), which the strip rule keeps out like the voice toolsets and settings.
    static func isOffered(_ entry: PluginCatalogEntry) -> Bool {
        switch entry.category.lowercased() {
        case "voice": return false
        case "desktop": return entry.hasAgentHalf
        default: return true
        }
    }
}

// MARK: - Results

/// What an install answered (`installAgentPlugin`).
struct PluginInstallOutcome: Hashable {
    var pluginName: String?
    var warnings: [String]
    /// Env vars the plugin needs that the profile doesn't have yet.
    var missingEnv: [String]
    var enabled: Bool
    /// Skills the model can load now (`activation.live_now.skills`).
    var liveSkills: [String]
    /// Tools of connected MCP servers, live in open chats from their next turn.
    var liveTools: Int
    /// Python tools or prompt sections that wait for the next chat (`activation.deferred`).
    var nextChat: Bool

    init(result: JSONValue) {
        pluginName = result["plugin_name"]?.stringValue
        warnings = result["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
        missingEnv = result["missing_env"]?.arrayValue?.compactMap(\.stringValue) ?? []
        enabled = result["enabled"]?.boolValue ?? false
        let live = result["activation"]?["live_now"]
        liveSkills = (live?["skills"]?.arrayValue ?? []).compactMap { skill in
            (skill["name"]?.stringValue ?? skill.stringValue).map { $0.split(separator: ":").last.map(String.init) ?? $0 }
        }
        liveTools = (live?["mcp_servers"]?.arrayValue ?? []).reduce(0) { total, server in
            server["connected"]?.boolValue == true ? total + (server["tools"]?.arrayValue?.count ?? 0) : total
        }
        nextChat = !(result["activation"]?["deferred"]?.objectValue?.isEmpty ?? true)
    }

    /// The success line (`agentSuccess` + `installOutcome`).
    func summary(fallbackName: String) -> String {
        var parts = ["\(pluginName ?? fallbackName) installed"]
        if liveTools > 0 { parts.append(liveTools == 1 ? "1 tool connected" : "\(liveTools) tools connected") }
        if !liveSkills.isEmpty { parts.append(liveSkills.count == 1 ? "skill \(liveSkills[0]) ready" : "\(liveSkills.count) skills ready") }
        if nextChat { parts.append("more tools available in your next chat") }
        return parts.joined(separator: " · ")
    }
}

/// What an update answered (`AgentPluginUpdateOutcome`). The backend changed nothing for `consent` and `scan`.
enum PluginUpdateOutcome: Hashable {
    case applied
    case unchanged
    /// A new catalog pin widens what the plugin may do; retry with `acceptCapabilities` once the user agrees.
    case consent(sha: String, deltaLines: [String])
    /// The security scan blocked the new code; a `caution` verdict can be retried with `force`.
    case scan(verdict: String, findings: [String])

    init(result: JSONValue) throws {
        if result["consent_required"]?.boolValue == true {
            self = .consent(sha: String((result["sha"]?.stringValue ?? "").prefix(8)),
                            deltaLines: result["delta_lines"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        } else if result["scan_blocked"]?.boolValue == true {
            let findings = (result["scan_findings"]?.arrayValue ?? []).map { finding in
                [finding["severity"]?.stringValue, finding["file"]?.stringValue, finding["description"]?.stringValue]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            self = .scan(verdict: result["scan_verdict"]?.stringValue ?? "dangerous", findings: findings)
        } else if result["ok"]?.boolValue == true {
            self = result["unchanged"]?.boolValue == true ? .unchanged : .applied
        } else {
            throw DashboardError.rpc(result["error"]?.stringValue ?? "Hermes didn't update the plugin.")
        }
    }
}

// MARK: - Gateway routes

/// `plugins.manage` for one profile (nil: the backend's launch profile).
struct PluginsAPI {
    let gateway: GatewayCalling
    let profile: String?

    /// Installs can clone a repository and resolve Python dependencies; the desktop waits up to two minutes.
    static let installTimeout: TimeInterval = 120

    static func params(_ action: String, _ fields: [String: JSONValue] = [:], profile: String?) -> JSONValue {
        var object = fields
        object["action"] = .string(action)
        if let profile { object["profile"] = .string(profile) }
        return .object(object)
    }

    private func call(_ action: String, _ fields: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await gateway.call("plugins.manage", params: Self.params(action, fields, profile: profile), timeout: timeout)
    }

    func list() async throws -> [AgentPlugin] {
        Self.plugins(try await call("list"))
    }

    static func plugins(_ result: JSONValue) -> [AgentPlugin] {
        (result["plugins"]?.arrayValue ?? []).compactMap { AgentPlugin($0) }
    }

    /// Flips a plugin on or off by its key; answers the refreshed row when the backend sends one.
    func toggle(key: String, enable: Bool) async throws -> AgentPlugin? {
        let result = try await call("toggle", ["key": .string(key), "enable": .bool(enable)])
        guard result["ok"]?.boolValue == true else {
            throw DashboardError.rpc(result["error"]?.stringValue ?? "Hermes didn't change the plugin.")
        }
        return AgentPlugin(result["plugin"])
    }

    /// Installs from a git URL (`owner/repo`, `https://…`, `repo#subdir`) or, with `catalogName`, the catalog's
    /// reviewed pin. `ref` pins a custom source to one full commit.
    func install(identifier: String, catalogName: String? = nil, enable: Bool = true, force: Bool = false,
                 ref: String? = nil) async throws -> PluginInstallOutcome {
        let result = try await call("install", Self.installFields(identifier: identifier, catalogName: catalogName, enable: enable,
                                                                  force: force, ref: ref), timeout: Self.installTimeout)
        guard result["ok"]?.boolValue == true else {
            throw DashboardError.rpc(result["error"]?.stringValue ?? "Install failed")
        }
        return PluginInstallOutcome(result: result)
    }

    static func installFields(identifier: String, catalogName: String?, enable: Bool, force: Bool, ref: String?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["identifier": .string(identifier.trimmingCharacters(in: .whitespacesAndNewlines)),
                                           "force": .bool(force), "enable": .bool(enable)]
        if let catalogName { fields["catalog_name"] = .string(catalogName) }
        if let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty { fields["ref"] = .string(ref) }
        return fields
    }

    /// Re-pins a catalog install or pulls a git one.
    func update(name: String, acceptCapabilities: Bool = false, force: Bool = false) async throws -> PluginUpdateOutcome {
        var fields: [String: JSONValue] = ["name": .string(name)]
        if acceptCapabilities { fields["accept_capabilities"] = true }
        if force { fields["force"] = true }
        return try PluginUpdateOutcome(result: try await call("update", fields, timeout: Self.installTimeout))
    }

    /// Writes manifest-declared settings (`values`: non-secret schema keys only; secrets go to the profile's
    /// `.env` through the credential route). Answers the refreshed row when the backend sends one.
    func saveSettings(key: String, values: [String: JSONValue]) async throws -> AgentPlugin? {
        let result = try await call("settings", ["key": .string(key), "values": .object(values)])
        guard result["ok"]?.boolValue == true else {
            throw DashboardError.rpc(result["error"]?.stringValue ?? "Hermes didn't save the settings.")
        }
        return AgentPlugin(result["plugin"])
    }

    /// Deletes a user install's folder and metadata from the profile.
    func remove(name: String) async throws {
        let result = try await call("remove", ["name": .string(name)])
        guard result["ok"]?.boolValue == true else {
            throw DashboardError.rpc(result["error"]?.stringValue ?? "Hermes didn't uninstall \(name).")
        }
    }

    /// A full 40-hex commit: what a `--ref` pin must be (branches and tags are refused).
    static func isCommit(_ ref: String) -> Bool {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.count == 40 && ref.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Catalog

/// One curated catalog plugin (`PluginCatalogEntry.to_dict` + installed state).
struct PluginCatalogEntry: Identifiable, Hashable {
    var name: String
    var title: String
    var repo: String
    var sha: String
    var subdir: String
    var description: String
    var maintainer: String
    /// official, verified, community.
    var tier: String
    var category: String
    var version: String
    var docsURL: String?
    var platforms: [String]
    var tools: [String]
    var hooks: [String]
    var middleware: [String]
    var requiresEnv: [String]
    var knownIssues: [String]
    /// What installing grants, in a paragraph (`entry_capability_summary`).
    var summary: String
    var installed: Bool
    var updateAvailable: Bool

    var id: String { name }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]), let repo = LenientField.text(row["repo"]) else { return nil }
        self.name = name
        title = LenientField.text(row["title"]) ?? EnvVar.prettyName(name.replacingOccurrences(of: "-", with: " "))
        self.repo = repo
        sha = LenientField.text(row["sha"]) ?? ""
        subdir = LenientField.text(row["subdir"]) ?? ""
        description = LenientField.text(row["description"]) ?? ""
        maintainer = LenientField.text(row["maintainer"]) ?? ""
        tier = LenientField.text(row["tier"])?.lowercased() ?? "community"
        category = LenientField.text(row["category"]) ?? ""
        version = LenientField.text(row["version"]) ?? ""
        docsURL = LenientField.text(row["docs_url"])
        platforms = LenientField.strings(row["platforms"])
        let capabilities = row["capabilities"] as? JSON ?? [:]
        tools = LenientField.strings(capabilities["provides_tools"])
        hooks = LenientField.strings(capabilities["provides_hooks"])
        middleware = LenientField.strings(capabilities["provides_middleware"])
        requiresEnv = LenientField.strings(capabilities["requires_env"])
        knownIssues = LenientField.strings(row["known_issues"])
        summary = LenientField.text(row["capability_summary"]) ?? ""
        installed = LenientField.bool(row["installed"])
        updateAvailable = LenientField.bool(row["update_available"])
    }

    static func list(_ response: Any) -> [PluginCatalogEntry] {
        let rows = (response as? JSON)?["entries"] as? [Any] ?? response as? [Any] ?? []
        return rows.compactMap { ($0 as? JSON).flatMap(PluginCatalogEntry.init(row:)) }
    }

    /// Something the agent loads: tools, hooks, middleware or keys. A package without any is renderer-only.
    var hasAgentHalf: Bool { !(tools.isEmpty && hooks.isEmpty && middleware.isEmpty && requiresEnv.isEmpty) }

    /// What `plugins.manage install` clones (`repo#subdir` for monorepo entries).
    var installIdentifier: String { subdir.isEmpty ? repo : "\(repo)#\(subdir)" }

    var tierLabel: String {
        switch tier {
        case "official": return "Official"
        case "verified": return "Verified"
        default: return "Community"
        }
    }
}

/// The dashboard's curated plugin catalog (host route; the backend resolves pins and installed state).
struct PluginCatalogAPI {
    let transport: CapabilitiesTransport

    func entries() async throws -> [PluginCatalogEntry] {
        PluginCatalogEntry.list(try await transport.request("GET", "/api/dashboard/plugins/catalog", query: [:], body: nil))
    }
}
