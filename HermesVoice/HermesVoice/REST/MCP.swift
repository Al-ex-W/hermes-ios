import Foundation

// The dashboard's MCP routes (`hermes_cli/web_routers/mcp.py`, helpers in `web_server_mcp.py`) and the pure rules
// the Connectors screens share with the desktop (`apps/desktop/src/lib/mcp-*.ts`,
// `app/capabilities/connectors/add-server-draft.ts`). Values the user types for env vars, headers or a bearer
// token go to the user's own dashboard in a request body only: nothing here logs, stores or echoes them.

// MARK: - Servers

/// How a server is reached (`_mcp_server_summary`'s `transport`).
enum MCPTransportKind: String, Hashable {
    case http, stdio, unknown
}

/// A server's per-tool gate: `tools.include` (a whitelist, even when empty) wins over `tools.exclude` (a denylist);
/// no filter means every tool. Mirrors `tools/mcp_tool_registration.py` and the desktop's `mcp-tool-filter.ts`.
struct MCPToolFilter: Hashable {
    var include: [String]?
    var exclude: [String]?

    init(include: [String]? = nil, exclude: [String]? = nil) {
        self.include = include
        self.exclude = exclude
    }

    /// From an entry's `tools` value; anything but an object is no filter, and non-string names are dropped.
    init(_ value: JSONValue?) {
        let object = value?.objectValue ?? [:]
        include = object["include"]?.arrayValue.map { $0.compactMap(\.stringValue) }
        exclude = object["exclude"]?.arrayValue.map { $0.compactMap(\.stringValue) }
    }

    func isEnabled(_ tool: String) -> Bool {
        if let include { return include.contains(tool) }
        return !(exclude ?? []).contains(tool)
    }

    func enabledCount(_ tools: [String]) -> Int {
        tools.filter(isEnabled).count
    }
}

/// An env var of a configured server as the host shows it: the name and its masked value.
struct MCPEnvPreview: Hashable {
    var key: String
    var value: String
}

/// One server of `GET /api/mcp/servers` (`_mcp_server_summary`). The host masks every env value
/// (`redact_key`), so `env` only ever holds previews.
struct MCPServerSummary: Identifiable, Hashable {
    enum Source: String, Hashable { case config, plugin }

    var name: String
    var transport: MCPTransportKind
    var url: String?
    var command: String?
    var args: [String]
    /// Env names with the host's masked values.
    var env: [MCPEnvPreview]
    /// `oauth`, `header` (an `Authorization` header), another mode, or nil.
    var auth: String?
    var enabled: Bool
    var tools: MCPToolFilter
    var source: Source
    /// The plugin that provides the server (it can't be edited, toggled or removed here).
    var plugin: String?

    var id: String { name }
    var isPlugin: Bool { source == .plugin }

    init(name: String, transport: MCPTransportKind = .stdio, url: String? = nil, command: String? = nil, args: [String] = [],
         env: [MCPEnvPreview] = [], auth: String? = nil, enabled: Bool = true, tools: MCPToolFilter = .init(),
         source: Source = .config, plugin: String? = nil) {
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.auth = auth
        self.enabled = enabled
        self.tools = tools
        self.source = source
        self.plugin = plugin
    }

    /// Lenient: a missing or mistyped member keeps its default; a row without a name is dropped.
    init?(row: JSONValue) {
        guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        url = MCPText.nonBlank(row["url"]?.stringValue)
        command = MCPText.nonBlank(row["command"]?.stringValue)
        transport = MCPTransportKind(rawValue: row["transport"]?.stringValue ?? "")
            ?? (url != nil ? .http : command != nil ? .stdio : .unknown)
        args = row["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        env = (row["env"]?.objectValue ?? [:]).map { MCPEnvPreview(key: $0.key, value: $0.value.stringValue ?? "") }
            .sorted { $0.key < $1.key }
        auth = MCPText.nonBlank(row["auth"]?.stringValue)
        enabled = row["enabled"]?.boolValue ?? true
        tools = MCPToolFilter(row["tools"])
        source = row["source"]?.stringValue == "plugin" ? .plugin : .config
        plugin = MCPText.nonBlank(row["plugin"]?.stringValue)
        if source == .plugin, plugin == nil { plugin = "" }
    }

    /// What it runs: the URL, else the command line (`join.ts` `targetOf`).
    var target: String {
        if let url { return url }
        return ([command ?? ""] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// What a cached probe is valid for (`serverFingerprint`): a same-name edit misses the cache.
    var fingerprint: String {
        [url ?? "", command ?? "", args.joined(separator: "\u{1}"),
         env.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}"), auth ?? ""].joined(separator: "\u{2}")
    }
}

// MARK: - Probes

/// One tool a probe found. `schema_chars` (the registry schema's size) is additive; older hosts omit it.
struct MCPProbedTool: Hashable {
    var name: String
    var description: String
    var schemaChars: Int?
}

/// `POST /api/mcp/servers/{name}/test`: connect, list tools, disconnect.
struct MCPTestResult: Hashable {
    var ok: Bool
    var error: String?
    var tools: [MCPProbedTool]
    var prompts: Int
    var resources: Int

    init(ok: Bool, error: String? = nil, tools: [MCPProbedTool] = [], prompts: Int = 0, resources: Int = 0) {
        self.ok = ok
        self.error = error
        self.tools = tools
        self.prompts = prompts
        self.resources = resources
    }

    init(response: JSONValue) {
        ok = response["ok"]?.boolValue ?? false
        error = MCPText.nonBlank(response["error"]?.stringValue)
        tools = (response["tools"]?.arrayValue ?? []).compactMap { row in
            guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
            let chars = row["schema_chars"]?.intValue
            return MCPProbedTool(name: name, description: row["description"]?.stringValue ?? "",
                                 schemaChars: chars.flatMap { $0 > 0 ? $0 : nil })
        }
        prompts = max(0, response["prompts"]?.intValue ?? 0)
        resources = max(0, response["resources"]?.intValue ?? 0)
    }

    /// The probe's verdict as the status dot shows it (`classifyProbe`).
    var status: MCPServerStatus {
        if ok { return .ok }
        return MCPServerStatus.needsAuth(error) ? .needsAuth : .error
    }
}

/// A configured server's state (`mcp-status.ts` `ServerStatus`).
enum MCPServerStatus: String, Hashable {
    case error, needsAuth, off, ok, probing, unknown

    private static let needsAuthPattern = try? NSRegularExpression(
        pattern: #"\b(401|unauthorized|forbidden|invalid[_ ]?token|authentication|oauth)\b"#, options: [.caseInsensitive])

    /// Whether a probe error reads as "sign in first" (`NEEDS_AUTH_RE`).
    static func needsAuth(_ error: String?) -> Bool {
        guard let error, let pattern = needsAuthPattern else { return false }
        return pattern.firstMatch(in: error, range: NSRange(error.startIndex..., in: error)) != nil
    }

    /// `statusOf`: off when disabled, else what the last probe said (`nil`: none yet).
    static func of(enabled: Bool, probing: Bool, probe: MCPTestResult?) -> MCPServerStatus {
        guard enabled else { return .off }
        if probing { return .probing }
        return probe?.status ?? .unknown
    }

    /// `canAuthenticate`: an HTTP server without header auth, whose probe asks for a sign-in (or an OAuth server
    /// whose probe failed).
    static func canAuthenticate(_ server: MCPServerSummary, status: MCPServerStatus) -> Bool {
        guard server.url != nil, server.auth != "header", !server.isPlugin else { return false }
        if server.auth == "oauth" { return status == .needsAuth || status == .error }
        return server.auth == nil && status == .needsAuth
    }
}

/// The desktop's cost overlay (`mcp-cost.ts`): display only.
enum MCPCost {
    /// `~N tok/call`: `ceil(schema_chars / 4)` over the enabled tools; nil when none carries a size.
    static func tokensPerCall(_ tools: [MCPProbedTool], filter: MCPToolFilter) -> Int? {
        var total = 0, saw = false
        for tool in tools {
            guard let chars = tool.schemaChars, chars > 0, filter.isEnabled(tool.name) else { continue }
            saw = true
            total += (chars + 3) / 4
        }
        return saw ? total : nil
    }

    /// `sanitize_mcp_name_component`: anything outside `[A-Za-z0-9_]` becomes `_`.
    static func sanitized(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            let ok = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            return ok ? Character(scalar) : "_"
        })
    }

    /// 30-day calls of one server's tools: registry names are `mcp__<server>__<tool>`.
    static func uses(_ server: String, calls: [String: Int]) -> Int {
        let prefix = "mcp__\(sanitized(server))__"
        return calls.reduce(0) { $0 + ($1.key.hasPrefix(prefix) ? max(0, $1.value) : 0) }
    }

    /// `compactNumber`: 950, 1.2k, 3.4M.
    static func compact(_ value: Int) -> String {
        func trim(_ number: Double, _ suffix: String) -> String {
            let text = number >= 100 ? String(Int(number.rounded())) : String(format: "%.1f", number)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        switch abs(value) {
        case ..<1000: return String(value)
        case ..<1_000_000: return trim(Double(value) / 1000, "k")
        default: return trim(Double(value) / 1_000_000, "M")
        }
    }
}

// MARK: - Raw entries

/// Edits of one raw `mcp_servers.<name>` entry as the host stores it. The whole-map save (`PUT /api/mcp/servers`)
/// writes these back, so every function keeps the keys it doesn't own.
enum MCPEntry {
    private static let offWords: Set<String> = ["false", "0", "no", "off"]

    /// `serverEnabled` / `mcp_server_enabled`: false, 0 and the off words are off; absent, null and junk are on.
    static func isEnabled(_ entry: [String: JSONValue]) -> Bool {
        switch entry["enabled"] {
        case let .bool(flag)?: return flag
        case let .int(number)?: return number != 0
        case let .double(number)?: return number != 0
        case let .string(text)?: return !offWords.contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        default: return true
        }
    }

    /// `setDisabledTools`: the discovered tools in `disabled` are off, in the entry's own mode (an `include`
    /// whitelist stays one, else an `exclude` denylist); stored names the probe didn't see are kept.
    static func settingDisabledTools(_ entry: [String: JSONValue], disabled: [String], discovered: [String]) -> [String: JSONValue] {
        let filter = MCPToolFilter(entry["tools"])
        let off = Set(disabled), seen = Set(discovered)
        var tools = entry["tools"]?.objectValue ?? [:]
        func kept(_ stored: [String]?) -> [String] { (stored ?? []).filter { !seen.contains($0) } }
        if let include = filter.include {
            tools["include"] = .array((discovered.filter { !off.contains($0) } + kept(include)).map(JSONValue.string))
        } else {
            let names = discovered.filter { off.contains($0) } + kept(filter.exclude)
            tools["exclude"] = names.isEmpty ? nil : .array(names.map(JSONValue.string))
        }
        var next = entry
        next["tools"] = tools.isEmpty ? nil : .object(tools)
        return next
    }

    /// The entries of a config record's `mcp_servers` that are objects (a hand-edited `name:` without a value
    /// parses as null; the whole-map save refuses non-objects).
    static func servers(inConfig config: JSONValue) -> [String: JSONValue] {
        (config["mcp_servers"]?.objectValue ?? [:]).filter { $0.value.objectValue != nil }
    }
}

// MARK: - Add / edit draft

/// The add-server form (`add-server-draft.ts`), also the structured edit form. Rows keep a stable id for the list.
struct MCPServerDraft: Hashable {
    enum Transport: String, CaseIterable, Hashable { case stdio, http }
    enum Auth: String, CaseIterable, Hashable { case none, oauth, bearer }

    struct Value: Identifiable, Hashable {
        let id: UUID
        var value: String
        init(_ value: String = "", id: UUID = UUID()) {
            self.id = id
            self.value = value
        }
    }

    /// A key/value row. While editing a saved server, `kept` is the stored value's mask and the value is empty: the
    /// save keeps whatever the host has under `originalKey`, so the secret never travels to the phone and back.
    struct Pair: Identifiable, Hashable {
        let id: UUID
        var key: String
        var value: String
        var kept: String?
        var originalKey: String?

        init(_ key: String = "", _ value: String = "", kept: String? = nil, originalKey: String? = nil, id: UUID = UUID()) {
            self.id = id
            self.key = key
            self.value = value
            self.kept = kept
            self.originalKey = originalKey
        }

        /// The row's value is the saved one.
        var keepsStored: Bool { kept != nil && value.isEmpty }
    }

    var name = ""
    var transport: Transport = .stdio
    var command = ""
    var args: [Value] = []
    var env: [Pair] = []
    var passthrough: [Value] = []
    var cwd = ""
    var url = ""
    var headers: [Pair] = []
    var auth: Auth = .none
    /// Typed on the phone, sent once; empty while editing means "keep the saved token".
    var bearer = ""
    /// Editing: the server already has a bearer token in the host's `.env`.
    var hasStoredBearer = false

    init() {}

    /// `isDraftComplete`: a name and the transport's command or URL.
    var isComplete: Bool {
        !Self.trim(name).isEmpty && (transport == .stdio ? !Self.trim(command).isEmpty : !Self.trim(url).isEmpty)
    }

    /// The name already names a server (config or plugin).
    func nameTaken(in names: some Sequence<String>) -> Bool {
        let name = Self.trim(name)
        return !name.isEmpty && names.contains(name)
    }

    var filledArgs: [String] { args.map { Self.trim($0.value) }.filter { !$0.isEmpty } }
    var filledPassthrough: [String] { passthrough.map { Self.trim($0.value) }.filter { !$0.isEmpty } }

    /// `${NAME}`: a passthrough of the host's own variable.
    static func reference(_ name: String) -> String { "${\(name)}" }

    /// The env map a new server sends: typed pairs (key trimmed, value as typed) plus the passthrough references.
    var envMap: [String: String] {
        var map: [String: String] = [:]
        for pair in env where !Self.trim(pair.key).isEmpty { map[Self.trim(pair.key)] = pair.value }
        for name in filledPassthrough { map[name] = Self.reference(name) }
        return map
    }

    var headerMap: [String: String] {
        var map: [String: String] = [:]
        for pair in headers where !Self.trim(pair.key).isEmpty { map[Self.trim(pair.key)] = pair.value }
        return map
    }

    var typedBearer: String? {
        let token = Self.trim(bearer)
        return transport == .http && auth == .bearer && !token.isEmpty ? token : nil
    }

    /// `POST /api/mcp/servers` (`MCPServerCreate`): exactly one of command or URL; args and env only for stdio;
    /// `auth` only for HTTP, `header` with the typed bearer token (the host keeps it in `.env`).
    func createBody(profile: String?) -> JSON {
        var body: JSON = ["name": Self.trim(name)]
        if let profile { body["profile"] = profile }
        switch transport {
        case .stdio:
            body["command"] = Self.trim(command)
            if !filledArgs.isEmpty { body["args"] = filledArgs }
            if !envMap.isEmpty { body["env"] = envMap }
        case .http:
            body["url"] = Self.trim(url)
            if let token = typedBearer {
                body["auth"] = "header"
                body["bearer_token"] = token
            } else {
                body["auth"] = auth == .oauth ? "oauth" : "none"
            }
        }
        return body
    }

    /// What the create route can't carry (a working directory, custom headers), written by a follow-up save.
    var needsFollowUp: Bool {
        transport == .stdio ? !Self.trim(cwd).isEmpty : !headerMap.isEmpty
    }

    /// The entry the draft describes, over `stored` (the host's current entry, or nil for a new server): keys the
    /// form doesn't own (`tools`, `enabled`, timeouts, `oauth`, …) stay as they are; kept rows take the stored value.
    /// `bearerHeader` is the `Authorization` template of a bearer-token server.
    func entry(over stored: [String: JSONValue]? = nil, bearerHeader: String? = nil) -> [String: JSONValue] {
        var entry = stored ?? [:]
        let storedEnv = stored?["env"]?.objectValue ?? [:]
        let storedHeaders = stored?["headers"]?.objectValue ?? [:]
        func pairs(_ rows: [Pair], stored: [String: JSONValue]) -> [String: JSONValue] {
            var map: [String: JSONValue] = [:]
            for row in rows where !Self.trim(row.key).isEmpty {
                if row.keepsStored, let original = row.originalKey, let value = stored[original] {
                    map[Self.trim(row.key)] = value
                } else if !row.keepsStored {
                    map[Self.trim(row.key)] = .string(row.value)
                }
            }
            return map
        }
        switch transport {
        case .stdio:
            for key in ["url", "headers", "auth", "transport", "type"] { entry[key] = nil }
            entry["command"] = .string(Self.trim(command))
            entry["args"] = filledArgs.isEmpty ? nil : .array(filledArgs.map(JSONValue.string))
            var env = pairs(self.env, stored: storedEnv)
            for name in filledPassthrough { env[name] = .string(Self.reference(name)) }
            entry["env"] = env.isEmpty ? nil : .object(env)
            entry["cwd"] = Self.trim(cwd).isEmpty ? nil : .string(Self.trim(cwd))
        case .http:
            for key in ["command", "args", "env", "cwd"] { entry[key] = nil }
            entry["url"] = .string(Self.trim(url))
            var headers = pairs(self.headers, stored: storedHeaders)
            if auth == .bearer, let bearerHeader {
                headers = headers.filter { $0.key.lowercased() != "authorization" }
                headers["Authorization"] = .string(bearerHeader)
            }
            entry["headers"] = headers.isEmpty ? nil : .object(headers)
            entry["auth"] = auth == .oauth ? "oauth" : nil
        }
        return entry
    }

    /// The edit form for a saved entry: every env and header value shows as the host's mask (`mask_secret`) and
    /// stays on the host unless replaced; `${NAME}` env values are passthroughs; a bearer template is the bearer mode.
    init(editing name: String, entry raw: [String: JSONValue]) {
        self.name = name
        let entry = raw
        if let url = entry["url"]?.stringValue, !Self.trim(url).isEmpty {
            transport = .http
            self.url = url
            auth = entry["auth"]?.stringValue == "oauth" ? .oauth : .none
            let template = MCPServerDraft.bearerTemplate(for: name)
            for (key, value) in (entry["headers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                if key.lowercased() == "authorization", value.stringValue == template {
                    auth = .bearer
                    hasStoredBearer = true
                    continue
                }
                headers.append(Pair(key, "", kept: Self.mask(value), originalKey: key))
            }
            return
        }
        transport = .stdio
        command = entry["command"]?.stringValue ?? ""
        args = (entry["args"]?.arrayValue ?? []).map { Value($0.stringValue ?? "") }
        cwd = entry["cwd"]?.stringValue ?? ""
        for (key, value) in (entry["env"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            if value.stringValue == Self.reference(key) {
                passthrough.append(Value(key))
            } else {
                env.append(Pair(key, "", kept: Self.mask(value), originalKey: key))
            }
        }
    }

    /// `_env_key_for_server`: `MCP_<NAME>_API_KEY`, the `.env` key a bearer token lives under.
    static func bearerEnvKey(for name: String) -> String {
        let upper = name.uppercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_") ? Character(scalar) : "_"
        }
        let suffix = String(upper).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "MCP_\(suffix)_API_KEY"
    }

    /// `_bearer_auth_headers`: the persisted `Authorization` value.
    static func bearerTemplate(for name: String) -> String {
        "Bearer ${\(bearerEnvKey(for: name))}"
    }

    /// `_strip_bearer_prefix`: a token pasted with its own `Bearer ` would be sent as `Bearer Bearer …`.
    static func strippedBearer(_ token: String) -> String {
        let trimmed = trim(token)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return trimmed }
        return trim(String(trimmed.dropFirst(7)))
    }

    /// The host's display mask for a stored value (`redact_key` → `mask_secret`).
    static func mask(_ value: JSONValue) -> String {
        let text: String
        switch value {
        case let .string(string): text = string
        case .null: text = ""
        case let .int(number): text = String(number)
        case let .double(number): text = String(number)
        case let .bool(flag): text = flag ? "True" : "False"
        case .array, .object: text = "***"
        }
        return text.isEmpty ? "" : CredentialMask.localPreview(text)
    }

    static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Catalog

/// One curated server of `GET /api/mcp/catalog` (`_catalog_entry_json`). Command, args, URL and bootstrap are shown
/// on purpose: the trust model asks the user to inspect them before installing.
struct MCPCatalogEntry: Identifiable, Hashable {
    struct EnvField: Hashable {
        var name: String
        var prompt: String
        var required: Bool
    }

    var name: String
    var description: String
    var connectorSlug: String?
    var source: String
    var transport: String
    /// `none`, `api_key`, `oauth`.
    var authType: String
    var requiredEnv: [EnvField]
    var command: String?
    var args: [String]
    var url: String?
    var installURL: String?
    var installRef: String?
    var bootstrap: [String]
    var postInstall: String
    var needsInstall: Bool
    var installed: Bool
    var enabled: Bool

    var id: String { name }

    init?(row: JSONValue) {
        guard let name = row["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        description = row["description"]?.stringValue ?? ""
        connectorSlug = MCPText.nonBlank(row["connector_slug"]?.stringValue)
        source = row["source"]?.stringValue ?? ""
        transport = row["transport"]?.stringValue ?? ""
        authType = row["auth_type"]?.stringValue ?? "none"
        requiredEnv = (row["required_env"]?.arrayValue ?? []).compactMap { field in
            guard let name = field["name"]?.stringValue, !name.isEmpty else { return nil }
            return EnvField(name: name, prompt: field["prompt"]?.stringValue ?? "", required: field["required"]?.boolValue ?? false)
        }
        command = MCPText.nonBlank(row["command"]?.stringValue)
        args = row["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        url = MCPText.nonBlank(row["url"]?.stringValue)
        installURL = MCPText.nonBlank(row["install_url"]?.stringValue)
        installRef = MCPText.nonBlank(row["install_ref"]?.stringValue)
        bootstrap = row["bootstrap"]?.arrayValue?.compactMap(\.stringValue) ?? []
        postInstall = row["post_install"]?.stringValue ?? ""
        needsInstall = row["needs_install"]?.boolValue ?? false
        installed = row["installed"]?.boolValue ?? false
        enabled = row["enabled"]?.boolValue ?? false
    }

    /// Some declared value must be filled before installing.
    var needsEnv: Bool { requiredEnv.contains(where: \.required) }

    /// The `POST /api/mcp/catalog/install` body: only declared names, blank values left out.
    func installBody(_ values: [String: String], profile: String?) -> JSON {
        let declared = Set(requiredEnv.map(\.name))
        var env: [String: String] = [:]
        for (key, value) in values where declared.contains(key) {
            let trimmed = MCPServerDraft.trim(value)
            if !trimmed.isEmpty { env[key] = trimmed }
        }
        var body: JSON = ["name": name, "env": env, "enable": true]
        if let profile { body["profile"] = profile }
        return body
    }

    /// Every required value is filled.
    func canInstall(with values: [String: String]) -> Bool {
        requiredEnv.allSatisfy { !$0.required || !MCPServerDraft.trim(values[$0.name] ?? "").isEmpty }
    }
}

struct MCPCatalog: Hashable {
    struct Diagnostic: Hashable {
        var name: String
        var kind: String
        var message: String
    }

    var entries: [MCPCatalogEntry]
    var diagnostics: [Diagnostic]

    init(entries: [MCPCatalogEntry] = [], diagnostics: [Diagnostic] = []) {
        self.entries = entries
        self.diagnostics = diagnostics
    }

    init(response: JSONValue) {
        entries = (response["entries"]?.arrayValue ?? []).compactMap(MCPCatalogEntry.init(row:))
        diagnostics = (response["diagnostics"]?.arrayValue ?? []).map {
            Diagnostic(name: $0["name"]?.stringValue ?? "", kind: $0["kind"]?.stringValue ?? "", message: $0["message"]?.stringValue ?? "")
        }
    }
}

/// `POST /api/mcp/catalog/install`: a git-bootstrap entry runs as a background action the client polls.
struct MCPInstallResult: Hashable {
    var ok: Bool
    var background: Bool
    var action: String?

    init(response: JSONValue) {
        ok = response["ok"]?.boolValue ?? true
        background = response["background"]?.boolValue ?? false
        action = MCPText.nonBlank(response["action"]?.stringValue)
    }
}

// MARK: - OAuth

/// A dashboard OAuth flow (`DashboardOAuthFlow.snapshot`): the host runs the PKCE flow and catches the provider's
/// redirect at `/api/mcp/oauth/callback/<name>` on its own address.
struct MCPOAuthFlow: Hashable {
    enum Status: Hashable {
        case starting, authorizationRequired, approved, error
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "starting": self = .starting
            case "authorization_required": self = .authorizationRequired
            case "approved": self = .approved
            case "error": self = .error
            default: self = .other(raw)
            }
        }
    }

    var flowID: String
    var serverName: String
    var status: Status
    var authorizationURL: URL?
    var error: String?
    /// The tools the approving probe found (poll answers only).
    var tools: [MCPProbedTool]

    init(flowID: String, serverName: String = "", status: Status, authorizationURL: URL? = nil, error: String? = nil,
         tools: [MCPProbedTool] = []) {
        self.flowID = flowID
        self.serverName = serverName
        self.status = status
        self.authorizationURL = authorizationURL
        self.error = error
        self.tools = tools
    }

    init?(response: JSONValue) {
        guard let flowID = response["flow_id"]?.stringValue, !flowID.isEmpty else { return nil }
        self.flowID = flowID
        serverName = response["server_name"]?.stringValue ?? ""
        status = Status(response["status"]?.stringValue ?? "")
        authorizationURL = MCPText.nonBlank(response["authorization_url"]?.stringValue).flatMap(URL.init(string:))
        error = MCPText.nonBlank(response["error"]?.stringValue)
        tools = (response["tools"]?.arrayValue ?? []).compactMap { row in
            row["name"]?.stringValue.map { MCPProbedTool(name: $0, description: row["description"]?.stringValue ?? "") }
        }
    }

    /// Where the provider sends the browser back: the authorization URL's `redirect_uri`.
    var redirectURI: URL? { authorizationURL.flatMap(Self.redirect(in:)) }

    static func redirect(in authorizationURL: URL) -> URL? {
        let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "redirect_uri" }?.value.flatMap(URL.init(string:))
    }

    /// The redirect's origin when it names the dashboard's host on another scheme or port (a proxy in front of the
    /// host that it can't see, like Tailscale Serve without `dashboard.public_url`): it may not load on the phone.
    static func mismatchedOrigin(_ redirect: URL, dashboard: URL) -> String? {
        guard let host = redirect.host?.lowercased(), host == dashboard.host?.lowercased() else { return nil }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        guard redirect.scheme?.lowercased() != dashboard.scheme?.lowercased() || port(redirect) != port(dashboard) else { return nil }
        var origin = "\(redirect.scheme ?? "http")://\(redirect.host ?? "")"
        if let value = redirect.port { origin += ":\(value)" }
        return origin
    }

    /// The redirect can't reach the host from this phone: it names a loopback address (the host has no
    /// `dashboard.public_url` and reconstructed its own `127.0.0.1` address) while the phone reaches the dashboard
    /// some other way. A redirect the URL doesn't name, or any other host, is assumed reachable.
    func callbackUnreachable(from dashboard: URL) -> Bool {
        guard let host = redirectURI?.host else { return false }
        return MCPText.isLoopback(host) && !MCPText.isLoopback(dashboard.host ?? "")
    }
}

// MARK: - Logs

enum MCPLogSource: String, CaseIterable, Hashable {
    case stdio, agent
}

enum MCPLogs {
    /// `filterStdioSections`: the lines of `mcp.log` from each `===== starting MCP server '<name>' =====` banner of
    /// `server` up to the next banner.
    static func stdioSections(_ lines: [String], server: String) -> [String] {
        var out: [String] = []
        var inside = false
        for line in lines {
            if let name = bannerServer(line.trimmingCharacters(in: .whitespaces)) { inside = name == server }
            if inside { out.append(line) }
        }
        return out
    }

    private static let banner = try? NSRegularExpression(
        pattern: #"^(?:\d{4}-\d{2}-\d{2} [\d:,]+ )?===== (?:\[.*\] )?starting MCP server '(.+)' =====$"#)

    private static func bannerServer(_ line: String) -> String? {
        guard let banner,
              let match = banner.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }
}

// MARK: - Transport

/// What the MCP routes need from the dashboard. `timeout` is for the routes that connect for real (a test spawns
/// the server; an OAuth start waits up to 30 s for the provider), well past the client's usual 30 s.
protocol MCPTransport: AnyObject {
    func mcpRequest(_ method: String, _ path: String, query: [String: String], body: JSON?, timeout: TimeInterval?) async throws -> Any
    /// The dashboard address the phone uses (for the OAuth callback check).
    var dashboardBase: URL { get }
}

extension DashboardClient: MCPTransport {
    var dashboardBase: URL { base }

    func mcpRequest(_ method: String, _ path: String, query: [String: String], body: JSON?, timeout: TimeInterval?) async throws -> Any {
        guard let timeout else { return try await request(method, path, query: query, body: body) }
        return try await slowRequest(method, path, query: query, body: body, timeout: timeout)
    }

    /// One session for the slow routes, sharing the client's cookie jar, with a longer idle timeout.
    private static let slowSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    /// `request`, on the slow session: signs in once and retries when the cookie is gone.
    private func slowRequest(_ method: String, _ path: String, query: [String: String], body: JSON?, timeout: TimeInterval) async throws -> Any {
        var origin = "\(base.scheme ?? "https")://\(base.host ?? "")"
        if let port = base.port { origin += ":\(port)" }
        for attempt in 0..<2 {
            var request = URLRequest(url: url(path, query: query))
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if method != "GET" { request.setValue(origin, forHTTPHeaderField: "Origin") }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await Self.slowSession.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let redirectedAway = http?.url.map { $0.host != base.host || $0.path.contains("login") } ?? false
            if code == 401 || code == 403 || redirectedAway {
                if attempt == 0 { try await signIn(); continue }
                throw DashboardError.signedOut
            }
            guard (200..<300).contains(code) else { throw DashboardError.http(code, String(decoding: data, as: UTF8.self)) }
            return data.isEmpty ? JSON() : try JSONSerialization.jsonObject(with: data)
        }
        throw DashboardError.signedOut
    }
}

/// The MCP routes for one profile (`?profile=`; nil is the dashboard's own).
final class MCPAPI {
    let transport: MCPTransport
    let profile: String?

    /// A probe spawns or handshakes the server for real.
    static let testTimeout: TimeInterval = 75
    /// The host waits up to 30 s for the provider's authorization URL.
    static let authTimeout: TimeInterval = 50
    static let installTimeout: TimeInterval = 75

    init(transport: MCPTransport, profile: String? = nil) {
        self.transport = transport
        self.profile = profile
    }

    private var scope: [String: String] { profile.map { ["profile": $0] } ?? [:] }

    private func call(_ method: String, _ path: String, body: JSON? = nil, query: [String: String] = [:],
                      timeout: TimeInterval? = nil) async throws -> JSONValue {
        let merged = scope.merging(query) { _, new in new }
        return JSONValue(any: try await transport.mcpRequest(method, path, query: merged, body: body, timeout: timeout))
    }

    /// A path segment for a server name (the routes take `{name}` without slashes).
    static func segment(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("/") else { throw DashboardError.rpc("“\(name)” can't be addressed on the dashboard.") }
        return name
    }

    // MARK: Servers

    func servers() async throws -> [MCPServerSummary] {
        let result = try await call("GET", "/api/mcp/servers")
        return (result["servers"]?.arrayValue ?? []).compactMap(MCPServerSummary.init(row:))
    }

    /// The profile's raw `mcp_servers` (secrets as stored), read only to write the whole map back.
    func storedServers() async throws -> [String: JSONValue] {
        let record = try await call("GET", "/api/config", query: ["include_defaults": "false"])
        guard record.objectValue != nil else { throw DashboardError.rpc("The dashboard sent no configuration.") }
        return MCPEntry.servers(inConfig: record)
    }

    /// `PUT /api/mcp/servers`: replaces the whole map (the deep-merging config save can't delete or re-enable).
    func replaceServers(_ servers: [String: JSONValue]) async throws {
        var body: JSON = ["servers": servers.mapValues(\.anyValue)]
        if let profile { body["profile"] = profile }
        _ = try await call("PUT", "/api/mcp/servers", body: body)
    }

    /// Reads the stored map, changes one entry, writes the map back.
    private func rewrite(_ name: String, _ change: ([String: JSONValue]) throws -> [String: JSONValue]) async throws {
        var servers = try await storedServers()
        guard let entry = servers[name]?.objectValue else { throw DashboardError.rpc("Server ‘\(name)’ is no longer configured.") }
        servers[name] = .object(try change(entry))
        try await replaceServers(servers)
    }

    /// Adds a server: the create route, then a follow-up save for what it can't carry (working directory, custom
    /// headers). The bearer token goes in the create body once and lands in the host's `.env`.
    @discardableResult
    func create(_ draft: MCPServerDraft) async throws -> MCPServerSummary? {
        let name = MCPServerDraft.trim(draft.name)
        let token = draft.typedBearer
        let result: JSONValue
        do {
            result = try await call("POST", "/api/mcp/servers", body: draft.createBody(profile: profile))
        } catch {
            throw Self.scrubbed(error, secrets: [token].compactMap { $0 } + draft.env.map(\.value) + draft.headers.map(\.value))
        }
        if draft.needsFollowUp {
            do {
                try await rewrite(name) { stored in
                    draft.entry(over: stored, bearerHeader: stored["headers"]?["Authorization"]?.stringValue)
                }
            } catch {
                let what = draft.transport == .stdio ? "working directory wasn't" : "headers weren't"
                let detail = Self.scrubbed(error, secrets: draft.headers.map(\.value)).dashboardMessage
                throw DashboardError.rpc("Added \(name), but its \(what) saved. Edit the server to add them. \(detail)")
            }
        }
        return MCPServerSummary(row: result)
    }

    /// Saves the edit form over the stored entry. A typed bearer token goes to `.env` first (`MCP_<NAME>_API_KEY`),
    /// so the config never points at a key that isn't there.
    func update(_ name: String, draft: MCPServerDraft) async throws {
        var secrets = draft.env.map(\.value) + draft.headers.map(\.value)
        if draft.transport == .http, draft.auth == .bearer {
            let token = MCPServerDraft.strippedBearer(draft.bearer)
            if !token.isEmpty {
                secrets.append(token)
                try await setEnv(MCPServerDraft.bearerEnvKey(for: name), value: token)
            } else if !draft.hasStoredBearer {
                throw DashboardError.rpc("Enter the bearer token.")
            }
        }
        do {
            try await rewrite(name) { stored in
                draft.entry(over: stored, bearerHeader: MCPServerDraft.bearerTemplate(for: name))
            }
        } catch {
            throw Self.scrubbed(error, secrets: secrets)
        }
    }

    /// `PUT /api/env`: one credential into the profile's `.env`.
    private func setEnv(_ key: String, value: String) async throws {
        guard !CredentialMask.isPreview(value) else {
            throw DashboardError.rpc("That's the saved token's preview. Paste the full token to replace it.")
        }
        var body: JSON = ["key": key, "value": value]
        if let profile { body["profile"] = profile }
        do {
            _ = try await call("PUT", "/api/env", body: body)
        } catch {
            throw Self.scrubbed(error, secrets: [value])
        }
    }

    /// Takes effect on the next session (or after an MCP reload); the entry stays so it can come back.
    func setEnabled(_ name: String, _ enabled: Bool) async throws {
        var body: JSON = ["enabled": enabled]
        if let profile { body["profile"] = profile }
        _ = try await call("PUT", "/api/mcp/servers/\(try Self.segment(name))/enabled", body: body)
    }

    func remove(_ name: String) async throws {
        _ = try await call("DELETE", "/api/mcp/servers/\(try Self.segment(name))")
    }

    func test(_ name: String) async throws -> MCPTestResult {
        MCPTestResult(response: try await call("POST", "/api/mcp/servers/\(try Self.segment(name))/test",
                                               timeout: Self.testTimeout))
    }

    /// The discovered tools in `disabled` off, the rest on (`setServerTools`).
    func setDisabledTools(_ name: String, disabled: [String], discovered: [String]) async throws {
        try await rewrite(name) { MCPEntry.settingDisabledTools($0, disabled: disabled, discovered: discovered) }
    }

    // MARK: Catalog

    func catalog() async throws -> MCPCatalog {
        MCPCatalog(response: try await call("GET", "/api/mcp/catalog"))
    }

    func install(_ entry: MCPCatalogEntry, env: [String: String]) async throws -> MCPInstallResult {
        let values = Array(env.values)
        do {
            return MCPInstallResult(response: try await call("POST", "/api/mcp/catalog/install",
                                                             body: entry.installBody(env, profile: profile),
                                                             timeout: Self.installTimeout))
        } catch {
            throw Self.scrubbed(error, secrets: values)
        }
    }

    /// A background install's state (`GET /api/actions/{name}/status`).
    func actionStatus(_ action: String) async throws -> (running: Bool, exitCode: Int?) {
        let result = try await call("GET", "/api/actions/\(try Self.segment(action))/status", query: ["lines": "1"])
        return (result["running"]?.boolValue ?? false, result["exit_code"]?.intValue)
    }

    // MARK: OAuth

    func startOAuth(_ name: String) async throws -> MCPOAuthFlow {
        let result = try await call("POST", "/api/mcp/servers/\(try Self.segment(name))/auth", timeout: Self.authTimeout)
        guard let flow = MCPOAuthFlow(response: result) else { throw DashboardError.rpc("Hermes didn't start the sign-in.") }
        return flow
    }

    /// The flow's state; nil when the host no longer knows it (expired after 15 minutes, or restarted).
    func pollOAuth(_ flowID: String) async throws -> MCPOAuthFlow? {
        do {
            let result = try await transport.mcpRequest("GET", "/api/mcp/oauth/flows/\(try Self.segment(flowID))",
                                                        query: [:], body: nil, timeout: nil)
            return MCPOAuthFlow(response: JSONValue(any: result))
        } catch let DashboardError.http(code, _) where code == 404 {
            return nil
        }
    }

    /// Frees the host's per-server slot so a retry doesn't answer "already in progress". Best effort.
    func cancelOAuth(_ flowID: String) async {
        guard let segment = try? Self.segment(flowID) else { return }
        _ = try? await transport.mcpRequest("DELETE", "/api/mcp/oauth/flows/\(segment)", query: [:], body: nil, timeout: nil)
    }

    // MARK: Usage and logs

    /// 30-day calls per registry tool name (`GET /api/analytics/usage`); nil when the host has no analytics.
    func toolCalls30d() async -> [String: Int]? {
        guard let result = try? await call("GET", "/api/analytics/usage", query: ["days": "30"]),
              let rows = result["tools"]?.arrayValue else { return nil }
        var calls: [String: Int] = [:]
        for row in rows {
            if let tool = row["tool"]?.stringValue, let count = row["count"]?.intValue { calls[tool, default: 0] += count }
        }
        return calls
    }

    /// The server's lines of `mcp.log` (stdio output), or the agent log searched for it.
    func logs(_ source: MCPLogSource, server: String) async throws -> [String] {
        let query = source == .stdio ? ["file": "mcp", "lines": "500"] : ["file": "agent", "lines": "300", "search": server]
        let lines = (try await call("GET", "/api/logs", query: query))["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return source == .stdio ? MCPLogs.stdioSections(lines, server: server) : lines
    }

    // MARK: Errors

    /// `error` with every typed secret blanked out of what the dashboard sent back.
    static func scrubbed(_ error: Error, secrets: [String]) -> Error {
        guard case let .http(code, body)? = error as? DashboardError else { return error }
        var text = body
        for secret in secrets where secret.count >= 4 { text = CredentialMask.scrub(text, secret: secret) }
        return DashboardError.http(code, text)
    }
}

// MARK: - Text

enum MCPText {
    static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// localhost, `*.localhost`, 127.0.0.0/8, ::1 and the unspecified addresses.
    static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" || host == "::" { return true }
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.first == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// `connectorTitle`: the brands plain capitalisation gets wrong, else words capitalised with `MCP` kept upper case.
    static func title(_ slug: String) -> String {
        let brands = ["googlecalendar": "Google Calendar", "googledrive": "Google Drive", "googledocs": "Google Docs",
                      "github": "GitHub", "stripe_mcp": "Stripe"]
        if let brand = brands[slug] { return brand }
        let words = slug.replacingOccurrences(of: #"[_-]+"#, with: " ", options: .regularExpression)
        var out = ""
        var atWordStart = true
        for character in words {
            let isWord = character.isLetter || character.isNumber || character == "_"
            out.append(atWordStart && isWord ? Character(character.uppercased()) : character)
            atWordStart = !isWord
        }
        return out.replacingOccurrences(of: #"\bMcp\b"#, with: "MCP", options: .regularExpression)
    }
}
