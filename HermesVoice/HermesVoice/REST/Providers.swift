import Foundation

// MARK: - Accounts (`/api/providers/oauth`)

/// A provider account Hermes can sign in to (`OAuthProvider` in the desktop's `types/hermes.ts`,
/// `GET /api/providers/oauth`). The credentials stay on the host; the status carries a token preview at most.
struct OAuthAccount: Identifiable, Hashable {
    /// How the sign-in runs. Hermes' dashboard runs device-code flows itself (the user approves a code on the
    /// provider's page, from any device); `external` accounts are signed in with a CLI on the host.
    enum Flow: Hashable {
        case deviceCode
        case pkce
        case external
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "device_code"?: self = .deviceCode
            case "pkce"?: self = .pkce
            case "external"?, nil: self = .external
            case let value?: self = .other(value)
            }
        }
    }

    struct Status: Hashable {
        /// A token exists. For Nous it is also true on the free tier, which isn't an account.
        var loggedIn = false
        /// Nous only: the token belongs to a free-tier identity, not a signed-in account.
        var freeTier = false
        var accountTier: String?
        var source: String?
        var sourceLabel: String?
        /// The last few characters of the token, never the token.
        var tokenPreview: String?
        var error: String?

        init() {}

        init(row: JSON) {
            loggedIn = LenientField.bool(row["logged_in"])
            freeTier = LenientField.bool(row["free_tier"])
            accountTier = LenientField.text(row["account_tier"])
            source = LenientField.text(row["source"])
            sourceLabel = LenientField.text(row["source_label"])
            tokenPreview = LenientField.text(row["token_preview"])
            error = LenientField.text(row["error"])
        }
    }

    let id: String
    var name: String
    var flow: Flow
    /// What signs in on the host (`hermes auth add <id>`, `claude setup-token`, …).
    var cliCommand: String?
    var docsURL: URL?
    /// Why Hermes can't remove these credentials itself, and where they are removed instead.
    var disconnectHint: String?
    /// A shell command that clears an external provider's credentials on the host.
    var disconnectCommand: String?
    /// Nil on older backends.
    var disconnectable: Bool?
    var status = Status()

    init(id: String, name: String, flow: Flow, status: Status = Status()) {
        self.id = id
        self.name = name
        self.flow = flow
        self.status = status
    }

    init?(row: JSON) {
        guard let id = LenientField.text(row["id"]) else { return nil }
        self.id = id
        name = LenientField.text(row["name"]) ?? id
        flow = Flow(LenientField.text(row["flow"]))
        cliCommand = LenientField.text(row["cli_command"])
        docsURL = LenientField.text(row["docs_url"]).flatMap(URL.init(string:)).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        disconnectHint = LenientField.text(row["disconnect_hint"])
        disconnectCommand = LenientField.text(row["disconnect_command"])
        disconnectable = LenientField.optionalBool(row["disconnectable"])
        status = Status(row: row["status"] as? JSON ?? [:])
    }

    /// Signed in with an account: the free tier holds a token but is never "connected".
    var isConnected: Bool { status.loggedIn && !status.freeTier }

    /// The desktop's card title (`PROVIDER_DISPLAY_NAMES`), else the backend's name.
    var title: String { Self.displayNames[id] ?? name }

    /// Hermes can remove the stored credentials (`disconnectable ?? flow != external`).
    var canDisconnect: Bool { disconnectable ?? (flow != .external) }

    /// The phone can start this sign-in: the dashboard runs it and hands back a code to approve.
    var signsInFromPhone: Bool { flow == .deviceCode }

    /// One line on how the sign-in works from here.
    var flowSubtitle: String {
        switch flow {
        case .deviceCode: return "Opens a verification page — Hermes connects automatically"
        case .pkce, .external, .other: return "Sign in once on the Hermes host, then come back"
        }
    }

    static let featuredID = "nous"

    /// Titles the desktop shows for its curated cards (`model-status-label.ts`).
    static let displayNames: [String: String] = [
        "anthropic": "Anthropic Account",
        "claude-code": "Anthropic OAuth: Required Extra Usage Credits to Use Subscription",
        "minimax-oauth": "MiniMax",
        "nous": "Nous Portal",
        "openai-codex": "ChatGPT or Codex Subscription",
        "qwen-oauth": "Qwen Code",
        "xai": "xAI",
        "xai-oauth": "xAI Grok",
    ]

    /// The desktop's featured order (`PROVIDER_ORDER`), then name.
    static let order: [String: Int] = [
        "nous": 0, "openai-codex": 1, "minimax-oauth": 2, "qwen-oauth": 3, "xai-oauth": 4, "anthropic": 5, "claude-code": 6,
    ]

    static func sorted(_ accounts: [OAuthAccount]) -> [OAuthAccount] {
        accounts.sorted { lhs, rhs in
            let left = order[lhs.id] ?? 99, right = order[rhs.id] ?? 99
            return left != right ? left < right : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// What `POST /api/providers/oauth/:id/start` hands back for a device-code sign-in: the code to approve on the
/// provider's page. The dashboard polls the provider itself and saves the credentials when it is approved.
struct OAuthDeviceCode: Hashable {
    var sessionID: String
    var userCode: String
    var verificationURL: URL
    /// Seconds the code stays valid.
    var expiresIn: Int
    var pollInterval: Int

    init(sessionID: String, userCode: String, verificationURL: URL, expiresIn: Int = 900, pollInterval: Int = 5) {
        self.sessionID = sessionID
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresIn = expiresIn
        self.pollInterval = pollInterval
    }

    /// Nil unless the answer is a device-code start with a code and an http(s) page (a PKCE start, which needs a
    /// browser on the host, isn't one).
    init?(response: JSON) {
        guard LenientField.text(response["flow"]) ?? "device_code" == "device_code",
              let sessionID = LenientField.text(response["session_id"]),
              let userCode = LenientField.text(response["user_code"]),
              let page = LenientField.text(response["verification_url"]).flatMap(URL.init(string:)),
              page.scheme == "https" || page.scheme == "http" else { return nil }
        self.sessionID = sessionID
        self.userCode = userCode
        verificationURL = page
        expiresIn = LenientField.optionalInt(response["expires_in"]).flatMap { $0 > 0 ? $0 : nil } ?? 900
        pollInterval = max(1, LenientField.optionalInt(response["poll_interval"]) ?? 5)
    }
}

/// One answer of `GET /api/providers/oauth/:id/poll/:session`.
struct OAuthPoll: Hashable {
    enum State: Hashable {
        case pending, approved, denied, expired, error
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "pending"?, nil: self = .pending
            case "approved"?: self = .approved
            case "denied"?: self = .denied
            case "expired"?: self = .expired
            case "error"?: self = .error
            case let value?: self = .other(value)
            }
        }
    }

    var state: State
    var errorMessage: String?
    /// Approved sign-ins: the account the tokens belong to.
    var accountEmail: String?
    /// Approved sign-ins: the default model Hermes settled on (nil when the config kept the user's own).
    var model: String?
    /// Nous: the free tier's apps moving to the account, one line each.
    var handoffLines: [String] = []

    init(state: State, errorMessage: String? = nil) {
        self.state = state
        self.errorMessage = errorMessage
    }

    init(response: JSON) {
        state = State(LenientField.text(response["status"]))
        errorMessage = LenientField.text(response["error_message"])
        accountEmail = LenientField.text(response["account_email"])
        model = LenientField.text(response["model"])
        let handoff = response["handoff_status"] as? JSON
        handoffLines = LenientField.strings(handoff?["lines"] ?? response["handoff"])
    }

    var isFinished: Bool { state != .pending }

    /// What a sign-in that didn't go through says.
    var failureText: String {
        if let errorMessage { return errorMessage }
        switch state {
        case .denied: return "The sign-in was declined."
        case .expired: return "The code expired before it was approved. Try again."
        default: return "Sign-in failed. Try again."
        }
    }
}

// MARK: - Custom endpoints (`/api/providers/custom-endpoints`)

/// The transport a custom endpoint is pinned to; `.auto` lets the runtime detect it from the URL.
enum EndpointAPIMode: String, CaseIterable, Identifiable, Hashable {
    case auto = ""
    case chatCompletions = "chat_completions"
    case responses = "codex_responses"
    case anthropicMessages = "anthropic_messages"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto-detect"
        case .chatCompletions: return "Chat Completions"
        case .responses: return "Responses API"
        case .anthropicMessages: return "Anthropic Messages"
        }
    }

    init(lenient raw: String?) {
        self = raw.flatMap(EndpointAPIMode.init(rawValue:)) ?? .auto
    }
}

/// One `/v1/models` row, with the alias metadata a gateway may advertise (`gpt-x-high` → `gpt-x` at `high`).
struct EndpointModelDetail: Hashable {
    var id: String
    var canonicalModel: String?
    var reasoningEffort: String?

    init?(row: JSON) {
        guard let id = LenientField.text(row["id"]) else { return nil }
        self.id = id
        canonicalModel = LenientField.text(row["canonical_model"])
        reasoningEffort = LenientField.text(row["reasoning_effort"])
    }

    var json: JSON {
        var row: JSON = ["id": id]
        if let canonicalModel { row["canonical_model"] = canonicalModel }
        if let reasoningEffort { row["reasoning_effort"] = reasoningEffort }
        return row
    }
}

/// An OpenAI-compatible endpoint in the profile's config (`CustomEndpoint`). Its key lives in the host's `.env`;
/// only a preview (or the `${VAR}` it is read from) comes back.
struct CustomEndpoint: Identifiable, Hashable {
    let id: String
    var name: String
    var baseURL: String
    var model: String
    var models: [String]
    var apiMode: EndpointAPIMode
    var contextLength: Int?
    var discoverModels: Bool
    var hasAPIKey: Bool
    var apiKeyPreview: String?
    /// The main model runs on it.
    var isCurrent: Bool

    init?(row: JSON) {
        guard let id = LenientField.text(row["id"]), let baseURL = LenientField.text(row["base_url"]) else { return nil }
        self.id = id
        name = LenientField.text(row["name"]) ?? id
        self.baseURL = baseURL
        model = LenientField.text(row["model"]) ?? ""
        models = LenientField.strings(row["models"])
        apiMode = EndpointAPIMode(lenient: row["api_mode"] as? String)
        contextLength = LenientField.optionalInt(row["context_length"]).flatMap { $0 > 0 ? $0 : nil }
        discoverModels = LenientField.optionalBool(row["discover_models"]) ?? true
        hasAPIKey = LenientField.bool(row["has_api_key"])
        apiKeyPreview = LenientField.text(row["api_key_preview"])
        isCurrent = LenientField.bool(row["is_current"])
    }

    /// What the key row shows: the preview, the `${VAR}` it is read from, or nothing.
    var keyDisplay: String? {
        guard hasAPIKey else { return nil }
        guard let apiKeyPreview else { return CredentialMask.placeholder }
        return CredentialMask.isEnvReference(apiKeyPreview) ? apiKeyPreview : CredentialMask.display(apiKeyPreview)
    }
}

/// `GET /api/providers/custom-endpoints` and the answer of every write to it.
struct CustomEndpointList: Hashable {
    var endpoints: [CustomEndpoint]
    /// The main model's provider and model.
    var currentProvider: String
    var currentModel: String
    /// The id a save stored the endpoint under.
    var savedID: String?

    init(endpoints: [CustomEndpoint] = [], currentProvider: String = "", currentModel: String = "") {
        self.endpoints = endpoints
        self.currentProvider = currentProvider
        self.currentModel = currentModel
    }

    init(response: JSON) {
        endpoints = (response["endpoints"] as? [JSON] ?? []).compactMap(CustomEndpoint.init(row:))
        let current = response["current"] as? JSON ?? [:]
        currentProvider = LenientField.text(current["provider"]) ?? ""
        currentModel = LenientField.text(current["model"]) ?? ""
        savedID = LenientField.text(response["id"])
    }
}

/// The custom-endpoint form (`CustomEndpointUpdate`). `apiKey` stays empty unless the user types a new key; an
/// empty key keeps the stored one.
struct CustomEndpointDraft: Hashable {
    var id = ""
    var name = ""
    var baseURL = ""
    var model = ""
    var apiKey = ""
    var apiMode: EndpointAPIMode = .auto
    var contextLength = ""
    var discoverModels = true
    var makeDefault = true

    init() {}

    init(editing endpoint: CustomEndpoint) {
        id = endpoint.id
        name = endpoint.name
        baseURL = endpoint.baseURL
        model = endpoint.model
        apiMode = endpoint.apiMode
        contextLength = endpoint.contextLength.map(String.init) ?? ""
        discoverModels = endpoint.discoverModels
        makeDefault = endpoint.isCurrent
    }

    var isNew: Bool { id.isEmpty }

    /// Name, URL and model are required; the URL must be http(s).
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the endpoint a name." }
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: url), parsed.scheme == "http" || parsed.scheme == "https", parsed.host != nil else {
            return "Enter the endpoint's base URL, starting with http:// or https://."
        }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "Pick or type a model." }
        if !apiKey.isEmpty, CredentialMask.isPreview(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            || CredentialMask.isEnvReference(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return "That's the saved key's preview. Paste the full key to replace it, or leave the field empty."
        }
        return nil
    }

    /// The request body (`toPayload`): optional fields only when set, `models` and `model_details` from the last
    /// test.
    func payload(models: [String] = [], details: [EndpointModelDetail] = []) -> JSON {
        var body: JSON = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "base_url": baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
            "api_mode": apiMode.rawValue,
            "discover_models": discoverModels,
            "make_default": makeDefault,
        ]
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { body["id"] = id }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { body["api_key"] = key }
        if let length = Int(contextLength.trimmingCharacters(in: .whitespaces)), length > 0 { body["context_length"] = length }
        if !models.isEmpty { body["models"] = models }
        if !details.isEmpty { body["model_details"] = details.map(\.json) }
        return body
    }
}

/// What `POST /api/providers/custom-endpoints/validate` found at the endpoint.
struct EndpointProbe: Hashable {
    var ok: Bool
    var reachable: Bool
    var message: String?
    var models: [String]
    var details: [EndpointModelDetail]
    /// The base URL that served `/models` (the typed one or its `/v1` variant): the one to save.
    var resolvedBaseURL: String?
    var transportChecked: EndpointAPIMode?

    init(response: JSON) {
        ok = LenientField.bool(response["ok"])
        reachable = LenientField.optionalBool(response["reachable"]) ?? true
        message = LenientField.text(response["message"])
        models = LenientField.strings(response["models"])
        details = (response["model_details"] as? [JSON] ?? []).compactMap(EndpointModelDetail.init(row:))
        resolvedBaseURL = LenientField.text(response["resolved_base_url"])
        transportChecked = (response["transport_checked"] as? String).flatMap(EndpointAPIMode.init(rawValue:))
    }

    /// One line for the form.
    var summary: String {
        if !ok { return message ?? (reachable ? "The endpoint didn't answer as expected." : "Couldn't reach the endpoint.") }
        var text = "Reachable"
        if let transportChecked, transportChecked != .auto { text += " (\(transportChecked.title))" }
        if !models.isEmpty { text += " · \(models.count) \(models.count == 1 ? "model" : "models")" }
        return text + "."
    }
}

extension DashboardClient {
    // MARK: Accounts

    /// Every account Hermes can sign in to, with its status for `profile` (nil: the dashboard's own).
    func oauthAccounts(profile: String? = nil) async throws -> [OAuthAccount] {
        let result = try await request("GET", "/api/providers/oauth", query: Self.profileQuery(profile)) as? JSON
        return OAuthAccount.sorted((result?["providers"] as? [JSON] ?? []).compactMap(OAuthAccount.init(row:)))
    }

    /// Starts a device-code sign-in on the dashboard. Throws for accounts signed in on the host.
    func startOAuth(_ providerID: String, profile: String? = nil) async throws -> OAuthDeviceCode {
        let result = try await request("POST", "/api/providers/oauth/\(try Self.segment(providerID))/start",
                                       query: Self.profileQuery(profile), body: JSON())
        guard let code = OAuthDeviceCode(response: result as? JSON ?? [:]) else {
            throw DashboardError.rpc("Hermes can't run this sign-in from the phone. Sign in on the host instead.")
        }
        return code
    }

    /// The sign-in's state. With `wait` (seconds, the dashboard caps it at 25) it is a long-poll that answers as
    /// soon as the state leaves pending. A session the dashboard no longer knows reads as expired.
    func pollOAuth(_ providerID: String, session: String, profile: String? = nil, wait: Int = 0) async throws -> OAuthPoll {
        var query = Self.profileQuery(profile)
        if wait > 0 { query["wait"] = "\(wait)" }
        do {
            let result = try await request("GET", "/api/providers/oauth/\(try Self.segment(providerID))/poll/\(try Self.segment(session))",
                                           query: query)
            return OAuthPoll(response: result as? JSON ?? [:])
        } catch let DashboardError.http(code, _) where code == 404 {
            return OAuthPoll(state: .expired, errorMessage: "The sign-in expired. Start it again.")
        }
    }

    /// Stops a pending sign-in so the dashboard doesn't save it later. Best effort.
    func cancelOAuth(session: String, profile: String? = nil) async {
        guard let segment = try? Self.segment(session) else { return }
        _ = try? await request("DELETE", "/api/providers/oauth/sessions/\(segment)", query: Self.profileQuery(profile))
    }

    /// Removes the account's stored credentials on the host.
    func disconnectOAuth(_ providerID: String, profile: String? = nil) async throws {
        let result = try await request("DELETE", "/api/providers/oauth/\(try Self.segment(providerID))",
                                       query: Self.profileQuery(profile)) as? JSON
        if LenientField.optionalBool(result?["ok"]) == false {
            throw DashboardError.rpc("No stored credentials were removed.")
        }
    }

    // MARK: Custom endpoints

    func customEndpoints(profile: String? = nil) async throws -> CustomEndpointList {
        CustomEndpointList(response: try await request("GET", "/api/providers/custom-endpoints",
                                                       query: Self.profileQuery(profile)) as? JSON ?? [:])
    }

    /// Creates or updates an endpoint (its key goes to the host's `.env`). The answer lists every endpoint.
    func saveCustomEndpoint(_ draft: CustomEndpointDraft, models: [String] = [], details: [EndpointModelDetail] = [],
                            profile: String? = nil) async throws -> CustomEndpointList {
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await request("POST", "/api/providers/custom-endpoints", query: Self.profileQuery(profile),
                                           body: draft.payload(models: models, details: details))
            return CustomEndpointList(response: result as? JSON ?? [:])
        } catch {
            throw Self.scrubbed(error, secret: key)
        }
    }

    /// Asks the dashboard to try the endpoint's `/models` (with the typed key, if any) without saving anything.
    func probeCustomEndpoint(_ draft: CustomEndpointDraft, profile: String? = nil) async throws -> EndpointProbe {
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await request("POST", "/api/providers/custom-endpoints/validate", query: Self.profileQuery(profile),
                                           body: draft.payload())
            return EndpointProbe(response: result as? JSON ?? [:])
        } catch {
            throw Self.scrubbed(error, secret: key)
        }
    }

    /// Makes the endpoint's model the main model.
    func activateCustomEndpoint(_ id: String, profile: String? = nil) async throws {
        _ = try await request("POST", "/api/providers/custom-endpoints/\(try Self.segment(id))/activate",
                              query: Self.profileQuery(profile))
    }

    /// Removes the endpoint and its key; a main model that ran on it is detached.
    func deleteCustomEndpoint(_ id: String, profile: String? = nil) async throws -> CustomEndpointList {
        let result = try await request("DELETE", "/api/providers/custom-endpoints/\(try Self.segment(id))",
                                       query: Self.profileQuery(profile))
        return CustomEndpointList(response: result as? JSON ?? [:])
    }
}
