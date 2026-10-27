import Foundation

// MARK: - Schema

/// How a config field edits, from the `type` of its `GET /api/config/schema` entry. The backend builds the schema
/// from `DEFAULT_CONFIG` (`hermes_cli/web_server_config.py::_build_schema_from_config`: boolean, number, list,
/// object, string) plus `_SCHEMA_OVERRIDES` (select); `text` and `secret` are accepted for forward compatibility.
enum ConfigFieldKind: Hashable {
    case boolean
    case number
    case string
    /// Long free text (a textarea on the desktop).
    case text
    case select
    case list
    case object
    case secret
    /// A type this app doesn't know, kept as sent; edits as a string when the value is one.
    case unknown(String)

    init(type: String?) {
        switch type?.trimmingCharacters(in: .whitespaces).lowercased() ?? "" {
        case "boolean", "bool": self = .boolean
        case "number", "int", "integer", "float", "double": self = .number
        case "string", "": self = .string
        case "text", "textarea", "multiline": self = .text
        case "select", "enum": self = .select
        case "list", "array": self = .list
        case "object", "dict", "json", "map": self = .object
        case "secret", "password": self = .secret
        case let other: self = .unknown(other)
        }
    }

    /// The kind a value implies when the schema has no entry for its key (the desktop's `inferFieldSchema`;
    /// an object edits as JSON there too).
    init(inferredFrom value: JSONValue) {
        switch value {
        case .bool: self = .boolean
        case .int, .double: self = .number
        case .array: self = .list
        case .object: self = .object
        case .string, .null: self = .string
        }
    }
}

/// One field of the config schema (`ConfigFieldSchema` in the desktop's `types/hermes.ts`), decoded leniently:
/// a missing or mistyped member keeps its default.
struct ConfigFieldSchema: Hashable {
    var kind: ConfigFieldKind
    var description: String?
    var category: String?
    /// Select choices, as strings (the desktop stringifies them too). `""` is the "none" choice.
    var options: [String] = []
    /// Labels for choices sent as `{value, label}` objects.
    var optionLabels: [String: String] = [:]
    /// A large closed list (timezones) that wants a searchable picker.
    var searchable = false
    /// A searchable picker that offers clearing to `""` ("System default").
    var clearable = false
    var minimum: Double?
    var maximum: Double?
    var step: Double?
    /// The schema says a change only applies after Hermes restarts.
    var restartRequired = false
    /// The schema's own words on what to restart, if any.
    var restartHint: String?

    init(kind: ConfigFieldKind, description: String? = nil, category: String? = nil, options: [String] = []) {
        self.kind = kind
        self.description = description
        self.category = category
        self.options = options
    }

    init?(json: JSONValue) {
        guard let object = json.objectValue else { return nil }
        kind = ConfigFieldKind(type: object["type"]?.stringValue)
        description = Self.text(object["description"])
        category = Self.text(object["category"])
        for option in object["options"]?.arrayValue ?? [] {
            if let entry = option.objectValue, let value = entry["value"].flatMap(Self.optionString) {
                options.append(value)
                if let label = Self.text(entry["label"]) { optionLabels[value] = label }
            } else if let value = Self.optionString(option) {
                options.append(value)
            }
        }
        searchable = object["searchable"]?.boolValue ?? false
        clearable = object["clearable"]?.boolValue ?? false
        minimum = (object["min"] ?? object["minimum"])?.doubleValue
        maximum = (object["max"] ?? object["maximum"])?.doubleValue
        step = object["step"]?.doubleValue
        let restart = object["restart_required"] ?? object["requires_restart"] ?? object["restart"]
        switch restart {
        case let .bool(flag)?: restartRequired = flag
        case let .string(hint)? where !hint.trimmingCharacters(in: .whitespaces).isEmpty:
            restartRequired = true
            restartHint = hint
        default: break
        }
        if let hint = Self.text(object["restart_hint"]) {
            restartRequired = true
            restartHint = hint
        }
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }

    /// An option as the desktop's `String(option)` shows it; null is the empty choice.
    private static func optionString(_ value: JSONValue) -> String? {
        switch value {
        case let .string(string): return string
        case let .int(number): return String(number)
        case let .double(number): return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case let .bool(flag): return flag ? "true" : "false"
        case .null: return ""
        case .array, .object: return nil
        }
    }
}

/// `GET /api/config/schema`: `{fields: {dot.path: field}, category_order: [...]}`.
struct ConfigSchema: Hashable {
    var fields: [String: ConfigFieldSchema]
    var categoryOrder: [String]

    init(fields: [String: ConfigFieldSchema] = [:], categoryOrder: [String] = []) {
        self.fields = fields
        self.categoryOrder = categoryOrder
    }

    /// Lenient: entries that aren't objects are skipped; a bare `{key: field}` map (no `fields` wrapper) is read too.
    init(response: JSONValue) {
        let raw = response["fields"]?.objectValue
            ?? (response.objectValue?.values.contains { $0["type"] != nil } == true ? response.objectValue : nil)
            ?? [:]
        var fields: [String: ConfigFieldSchema] = [:]
        for (key, value) in raw where !key.isEmpty && !key.hasPrefix("_") {
            if let field = ConfigFieldSchema(json: value) { fields[key] = field }
        }
        self.fields = fields
        categoryOrder = response["category_order"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    subscript(key: String) -> ConfigFieldSchema? { fields[key] }

    /// The field for `key`: the schema's, else one inferred from the value in `config` (the backend leaves some
    /// declared keys out; presence in the config is what makes them editable). nil when neither has it.
    func resolvedField(_ key: String, in config: JSONValue) -> ConfigFieldSchema? {
        if let field = fields[key] { return field }
        guard let value = config.value(atPath: key), !value.isNull else { return nil }
        return ConfigFieldSchema(kind: ConfigFieldKind(inferredFrom: value))
    }
}

// MARK: - Config records

extension JSONValue {
    /// The value at a dot path (`agent.max_turns`), or nil when any step is missing or not an object.
    func value(atPath path: String) -> JSONValue? {
        var current: JSONValue? = self
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard let object = current?.objectValue, let next = object[String(part)] else { return nil }
            current = next
        }
        return current
    }

    /// This record with `value` at the dot path, creating (or replacing non-object) intermediate steps.
    /// A non-object root becomes an object.
    func settingPath(_ path: String, to value: JSONValue) -> JSONValue {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return Self.setting(parts[...], in: self, to: value)
    }

    private static func setting(_ parts: ArraySlice<String>, in node: JSONValue, to value: JSONValue) -> JSONValue {
        guard let head = parts.first else { return value }
        var object = node.objectValue ?? [:]
        object[head] = setting(parts.dropFirst(), in: object[head] ?? .object([:]), to: value)
        return .object(object)
    }

    /// A text form for display: strings as they are, numbers without a trailing `.0`, lists comma-joined.
    var displayText: String {
        switch self {
        case .null: return ""
        case let .bool(flag): return flag ? "true" : "false"
        case let .int(number): return String(number)
        case let .double(number):
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case let .string(string): return string
        case let .array(items): return items.map(\.displayText).joined(separator: ", ")
        case .object:
            guard let data = try? JSONSerialization.data(withJSONObject: anyValue, options: [.prettyPrinted, .sortedKeys]) else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Truthiness the way the gateway's `_norm_bool` reads a hand-written value.
    var truthy: Bool {
        switch self {
        case let .bool(flag): return flag
        case let .int(number): return number != 0
        case let .double(number): return number != 0
        case let .string(text): return ["true", "1", "yes", "on", "raw", "verbose"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
        default: return false
        }
    }
}

/// Sparse `PUT /api/config` bodies. The route deep-merges the body onto disk, so a patch carries only what changed
/// and a key another surface changed meanwhile is never sent back stale (the desktop's autosave does the same).
enum ConfigPatch {
    static func make(_ entries: [(path: String, value: JSONValue)]) -> JSONValue {
        entries.reduce(JSONValue.object([:])) { $0.settingPath($1.path, to: $1.value) }
    }

    static func make(_ path: String, _ value: JSONValue) -> JSONValue { make([(path, value)]) }
}

// MARK: - Transport

/// What the settings store needs from the dashboard: the schema, the record, and sparse saves.
protocol ConfigTransport: AnyObject {
    func schema() async throws -> ConfigSchema
    func config() async throws -> JSONValue
    func save(_ patch: JSONValue) async throws
}

/// The dashboard's settings routes (`hermes_cli/web_routers/config_env.py`, `models.py`, `memory_providers.py`,
/// `status.py`), scoped to one profile when `profile` is set (`?profile=`; nil means the dashboard's own).
/// Credentials (`/api/env`) go through `DashboardClient.setEnv` in `Env.swift`; nothing here logs a value.
final class ConfigAPI: ConfigTransport {
    let client: DashboardClient
    let profile: String?

    init(client: DashboardClient, profile: String? = nil) {
        self.client = client
        self.profile = profile
    }

    private var scope: [String: String] { profile.map { ["profile": $0] } ?? [:] }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> JSONValue {
        JSONValue(any: try await client.request("GET", path, query: scope.merging(query) { _, new in new }))
    }

    private func send(_ method: String, _ path: String, _ body: JSONValue, _ query: [String: String] = [:]) async throws -> JSONValue {
        let object = body.anyValue as? JSON ?? [:]
        return JSONValue(any: try await client.request(method, path, query: scope.merging(query) { _, new in new }, body: object))
    }

    // MARK: Config

    func schema() async throws -> ConfigSchema {
        ConfigSchema(response: try await get("/api/config/schema"))
    }

    /// The record with defaults filled in, model flattened to its name, plus `model_context_length`.
    func config() async throws -> JSONValue {
        let record = try await get("/api/config")
        guard record.objectValue != nil else { throw DashboardError.rpc("The dashboard sent no configuration.") }
        return record
    }

    func save(_ patch: JSONValue) async throws {
        let result = try await send("PUT", "/api/config", ["config": patch])
        if result["ok"]?.boolValue == false {
            throw DashboardError.rpc(result["detail"]?.stringValue ?? "The dashboard didn't save the change.")
        }
    }

    // MARK: Models (`/api/model/*`)

    /// `GET /api/model/info`: the main model and its detected versus configured context window.
    struct ModelInfo: Hashable {
        var model = ""
        var provider = ""
        var autoContextLength = 0
        var configContextLength = 0
        var effectiveContextLength = 0

        init(_ json: JSONValue) {
            model = json["model"]?.stringValue ?? ""
            provider = json["provider"]?.stringValue ?? ""
            autoContextLength = json["auto_context_length"]?.intValue ?? 0
            configContextLength = json["config_context_length"]?.intValue ?? 0
            effectiveContextLength = json["effective_context_length"]?.intValue ?? 0
        }
    }

    func modelInfo() async throws -> ModelInfo {
        ModelInfo(try await get("/api/model/info"))
    }

    /// `GET /api/model/options`: the same shape as the `model.options` RPC, and the models that offer Ultrafast
    /// (`capabilities[model].ultrafast`, which the pinned contract's `ModelCapabilities` doesn't carry yet).
    func modelOptions(refresh: Bool = false) async throws -> (result: ModelOptionsResult, ultrafast: Set<ModelRoute>) {
        var query = ["explicit_only": "1"]
        if refresh { query["refresh"] = "1" }
        let json = try await get("/api/model/options", query)
        return (try json.decode(ModelOptionsResult.self), Self.ultrafastRoutes(json))
    }

    /// The `{provider slug, model}` pairs whose capabilities say `ultrafast: true` (`inventory.py::_apply_capabilities`).
    static func ultrafastRoutes(_ options: JSONValue) -> Set<ModelRoute> {
        var routes: Set<ModelRoute> = []
        for row in options["providers"]?.arrayValue ?? [] {
            guard let slug = row["slug"]?.stringValue else { continue }
            for (model, caps) in row["capabilities"]?.objectValue ?? [:] where caps["ultrafast"]?.boolValue == true {
                routes.insert(ModelRoute(provider: slug, model: model))
            }
        }
        return routes
    }

    /// `POST /api/model/set` (`ModelAssignmentRequest`).
    struct ModelAssignment: Hashable {
        enum Scope: String { case main, auxiliary }
        var scope: Scope
        var provider: String
        var model: String
        var task: String?
        /// A user-defined provider's endpoint (`api_url` of its catalog row), so the slot resolves to it rather
        /// than to the main endpoint.
        var baseURL: String?
        /// Auxiliary only: nil leaves the task's effort alone, `.null` clears it (inherit), a level sets it.
        var reasoningEffort: JSONValue?
        var confirmExpensiveModel = false

        var body: JSONValue {
            var body: [String: JSONValue] = ["scope": .string(scope.rawValue), "provider": .string(provider),
                                              "model": .string(model)]
            if let task { body["task"] = .string(task) }
            if let baseURL, !baseURL.isEmpty { body["base_url"] = .string(baseURL) }
            if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
            if confirmExpensiveModel { body["confirm_expensive_model"] = true }
            return .object(body)
        }
    }

    struct ModelAssignmentResult: Hashable {
        var ok: Bool
        /// A pricing or data-use warning to confirm before the assignment is made.
        var confirmMessage: String?
        var notice: String?
        var provider: String?
        var model: String?

        init(_ json: JSONValue) {
            ok = json["ok"]?.boolValue ?? false
            confirmMessage = json["confirm_required"]?.boolValue == true
                ? (json["confirm_message"]?.stringValue ?? "This model has a selection warning.") : nil
            notice = json["notice"]?.stringValue
            provider = json["provider"]?.stringValue
            model = json["model"]?.stringValue
        }
    }

    func assignModel(_ assignment: ModelAssignment) async throws -> ModelAssignmentResult {
        ModelAssignmentResult(try await send("POST", "/api/model/set", assignment.body))
    }

    /// One auxiliary task slot (`AuxiliaryTaskAssignment`). `provider` "auto" with no model means "use main".
    struct AuxiliaryTask: Identifiable, Hashable {
        var task: String
        var provider: String
        var model: String
        var baseURL: String
        var reasoningEffort: String?
        var label: String?
        var hint: String?
        /// A plugin task that follows this base task until it is pinned itself.
        var inheritFrom: String?
        /// An inheriting task's route right now (the base's while it isn't pinned).
        var effective: ModelRoute?

        var id: String { task }
        /// Not pinned: provider auto (or none) follows the main model, or an inheriting task's base
        /// (`_layer_over_inherited`). The desktop reads it the same way, whatever the stored model.
        var isAuto: Bool { provider.isEmpty || provider.lowercased() == "auto" }
        /// The pinned route, nil while auto.
        var route: ModelRoute? { isAuto ? nil : ModelRoute(provider: provider, model: model) }

        init(_ json: JSONValue) {
            task = json["task"]?.stringValue ?? ""
            provider = json["provider"]?.stringValue ?? "auto"
            model = json["model"]?.stringValue ?? ""
            baseURL = json["base_url"]?.stringValue ?? ""
            reasoningEffort = json["reasoning_effort"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            label = json["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            hint = json["hint"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            inheritFrom = json["inherit_from"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            if let effective = json["effective"], effective.objectValue != nil {
                self.effective = ModelRoute(provider: effective["provider"]?.stringValue ?? "",
                                            model: effective["model"]?.stringValue ?? "")
            }
        }
    }

    func auxiliaryModels() async throws -> (tasks: [AuxiliaryTask], mainProvider: String, mainModel: String) {
        let json = try await get("/api/model/auxiliary")
        let tasks = (json["tasks"]?.arrayValue ?? []).map(AuxiliaryTask.init).filter { !$0.task.isEmpty }
        return (tasks, json["main"]?["provider"]?.stringValue ?? "", json["main"]?["model"]?.stringValue ?? "")
    }

    /// `GET /api/model/moa`, kept as JSON so a save round-trips every member this app doesn't edit.
    func moa() async throws -> JSONValue {
        try await get("/api/model/moa")
    }

    @discardableResult
    func saveMoa(_ config: JSONValue) async throws -> JSONValue {
        try await send("PUT", "/api/model/moa", config)
    }

    // MARK: Memory providers

    /// `GET /api/memory/providers/<name>/config?surface=declared` (`MemoryProviderConfig`).
    struct MemoryProvider: Hashable {
        struct Field: Identifiable, Hashable {
            enum Kind: String { case bool, json, number, secret, select, text }
            struct Option: Hashable {
                var value: String
                var label: String
            }

            var key: String
            var label: String
            var description: String
            var kind: Kind
            /// The stored value as text; always empty for a secret (write-only over the API).
            var value: String
            var isSet: Bool
            var placeholder: String
            var group: String
            var options: [Option]

            var id: String { key }

            init(_ json: JSONValue) {
                key = json["key"]?.stringValue ?? ""
                label = json["label"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? SettingsText.prettyName(key)
                description = json["description"]?.stringValue ?? ""
                kind = Kind(rawValue: json["kind"]?.stringValue ?? "") ?? .text
                value = json["value"].map(\.displayText) ?? ""
                isSet = json["is_set"]?.truthy ?? false
                placeholder = json["placeholder"]?.stringValue ?? ""
                group = json["group"]?.stringValue ?? ""
                options = (json["options"]?.arrayValue ?? []).compactMap { option in
                    guard let value = option["value"].map(\.displayText) else { return nil }
                    return Option(value: value, label: option["label"]?.stringValue ?? SettingsText.prettyName(value))
                }
            }
        }

        var name: String
        var label: String
        var docsURL: String?
        var fields: [Field]

        init(_ json: JSONValue) {
            name = json["name"]?.stringValue ?? ""
            label = json["label"]?.stringValue ?? name
            docsURL = json["docs_url"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            fields = (json["fields"]?.arrayValue ?? []).map(Field.init).filter { !$0.key.isEmpty }
        }
    }

    func memoryProvider(_ name: String) async throws -> MemoryProvider {
        MemoryProvider(try await get("/api/memory/providers/\(Self.pathSegment(name))/config", ["surface": "declared"]))
    }

    func saveMemoryProvider(_ name: String, values: [String: String]) async throws {
        _ = try await send("PUT", "/api/memory/providers/\(Self.pathSegment(name))/config",
                           ["values": .object(values.mapValues(JSONValue.string))], ["surface": "declared"])
    }

    // MARK: Status

    /// The versions and gateway state of `GET /api/status`.
    struct Status: Hashable {
        var version = ""
        var releaseDate = ""
        var configVersion: Int?
        var latestConfigVersion: Int?
        var gatewayRunning = false
        var gatewayState: String?
        var activeSessions: Int?
        var canUpdate: Bool?

        init(_ json: JSONValue) {
            version = json["version"]?.stringValue ?? ""
            releaseDate = json["release_date"]?.stringValue ?? ""
            configVersion = json["config_version"]?.intValue
            latestConfigVersion = json["latest_config_version"]?.intValue
            gatewayRunning = json["gateway_running"]?.truthy ?? false
            gatewayState = json["gateway_state"]?.stringValue
            activeSessions = json["active_sessions"]?.intValue
            canUpdate = json["can_update_hermes"]?.boolValue
        }
    }

    func status() async throws -> Status {
        Status(try await get("/api/status"))
    }

    private static func pathSegment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? text
    }
}

/// Text helpers shared by the settings screens and their tests.
enum SettingsText {
    /// The desktop's `prettyName` (one implementation, shared with the credential rows).
    static func prettyName(_ value: String) -> String { EnvVar.prettyName(value) }
}
