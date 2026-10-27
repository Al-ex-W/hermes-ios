import Foundation

// The dashboard's messaging routes (`hermes_cli/web_routers/messaging.py`: the platform list, per-platform setup,
// the connection test, Telegram and WhatsApp QR onboarding) and the pairing and gateway routes of `ops.py` /
// `actions.py`, as the desktop's Messaging page (`app/messaging/`, `api/messaging.ts`) and the web dashboard's
// Channels page use them. Every decoder is lenient: a missing or mistyped field falls back, unknown fields are
// ignored. Values the user types (bot tokens, app passwords) go to the dashboard in a request body only: they are
// never logged or kept, and an error that echoes one has it blanked.

// MARK: - Platforms

/// How a platform's state reads at a glance (`platformStatusTone`): connected, off, failed, or waiting on something
/// (connecting, retrying, restart needed, gateway stopped, needs setup).
enum MessagingTone: String, CaseIterable, Identifiable, Hashable {
    case bad, warn, good, muted

    var id: String { rawValue }

    /// The status filter's order: what needs you first, then what's fine, then what's off.
    static let filterOrder: [MessagingTone] = [.bad, .warn, .good, .muted]

    /// The status filter's label (`statusFilter`).
    var filterLabel: String {
        switch self {
        case .bad: return "Errors"
        case .warn: return "Needs attention"
        case .good: return "Connected"
        case .muted: return "Inactive"
        }
    }

    /// `platformStatusTone`: off is muted; connected good; failed bad; anything else enabled waits on something.
    static func of(enabled: Bool, state: String?) -> MessagingTone {
        guard enabled else { return .muted }
        switch state {
        case "connected": return .good
        case "disabled": return .muted
        case "fatal", "startup_failed": return .bad
        default: return .warn
        }
    }
}

/// One env variable a platform's setup form edits (`MessagingEnvVarInfo`).
struct MessagingEnvField: Hashable, Identifiable {
    var key: String
    var required = false
    var isSet = false
    /// The dashboard's display-only sentinel (`«redacted:abcd...wxyz»`); never a value to send back.
    var redactedValue: String?
    /// The saved value, sent for allowlists only (they are IDs, not secrets).
    var value: String?
    var description = ""
    var prompt = ""
    var help = ""
    var url: URL?
    var isPassword = false
    /// A comma-separated allowlist, edited one entry per row (absent on older backends: a plain field).
    var isList = false
    var advanced = false

    var id: String { key }

    init(key: String) {
        self.key = key
    }

    init?(row: JSON) {
        guard let key = LenientField.text(row["key"]) else { return nil }
        self.key = key
        required = LenientField.bool(row["required"])
        isSet = LenientField.bool(row["is_set"])
        redactedValue = LenientField.text(row["redacted_value"])
        value = row["value"] as? String
        description = LenientField.text(row["description"]) ?? ""
        prompt = LenientField.text(row["prompt"]) ?? ""
        help = LenientField.text(row["help"]) ?? ""
        url = LenientField.text(row["url"]).flatMap(MessagingLinks.web)
        isPassword = LenientField.bool(row["is_password"])
        isList = !isPassword && LenientField.bool(row["is_list"])
        advanced = LenientField.bool(row["advanced"])
    }

    /// The masked preview a saved value shows in its empty input (`credentialPreview`); nil when unset.
    var savedPreview: String? {
        guard isSet else { return nil }
        return CredentialMask.display(redactedValue)
    }

    /// The official voice features are stripped from this app (`SettingsCatalog.isStripped`): an env key is read as
    /// its config path (`TTS_PROVIDER` → `tts.provider`), so a voice knob on a platform card never shows.
    var isStripped: Bool {
        let lowered = key.lowercased()
        guard let underscore = lowered.firstIndex(of: "_") else { return SettingsCatalog.isStripped(lowered + ".") }
        return SettingsCatalog.isStripped(lowered.replacingCharacters(in: underscore...underscore, with: "."))
    }
}

/// Where the platform sends proactive messages (cron output, reminders).
struct MessagingHomeChannel: Hashable {
    var platform: String
    var chatID: String
    var name: String
    var threadID: String?

    init?(row: Any?) {
        guard let row = row as? JSON else { return nil }
        guard let chatID = LenientField.text(row["chat_id"]) ?? (row["chat_id"] as? NSNumber)?.stringValue else { return nil }
        self.chatID = chatID
        platform = LenientField.text(row["platform"]) ?? ""
        name = LenientField.text(row["name"]) ?? chatID
        threadID = LenientField.text(row["thread_id"])
    }
}

/// How WhatsApp is set up (`whatsapp_setup`, WhatsApp only).
struct WhatsAppSetupInfo: Hashable {
    var mode: WhatsAppMode?
    var allowedUsersSet: Bool
    var homeChannelSet: Bool

    init?(row: Any?) {
        guard let row = row as? JSON else { return nil }
        mode = LenientField.text(row["mode"]).flatMap(WhatsAppMode.init(rawValue:))
        allowedUsersSet = LenientField.bool(row["allowed_users_set"])
        homeChannelSet = LenientField.bool(row["home_channel_set"])
    }
}

/// One messaging platform (`MessagingPlatformInfo`): its setup, whether it's on, and what the gateway says about it.
struct MessagingPlatform: Hashable, Identifiable {
    var id: String
    var name: String
    var description = ""
    var docsURL: URL?
    var enabled = false
    var configured = false
    var gatewayRunning = false
    /// `connected`, `connecting`, `retrying`, `fatal`, `disabled`, `not_configured`, `pending_restart`,
    /// `gateway_stopped`, `startup_failed`, or nil.
    var state: String?
    var errorCode: String?
    var errorMessage: String?
    var homeChannel: MessagingHomeChannel?
    var envVars: [MessagingEnvField] = []
    /// A profile served on a multiplexed gateway's shared listener: the `/p/<profile>/` URL to point the client at.
    var ingressURL: String?
    var whatsappSetup: WhatsAppSetupInfo?

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init?(row: JSON) {
        guard let id = LenientField.text(row["id"]) else { return nil }
        self.id = id
        name = LenientField.text(row["name"]) ?? id
        description = LenientField.text(row["description"]) ?? ""
        docsURL = LenientField.text(row["docs_url"]).flatMap(MessagingLinks.web)
        enabled = LenientField.bool(row["enabled"])
        configured = LenientField.bool(row["configured"])
        gatewayRunning = LenientField.bool(row["gateway_running"])
        state = LenientField.text(row["state"])
        errorCode = LenientField.text(row["error_code"])
        errorMessage = LenientField.text(row["error_message"])
        homeChannel = MessagingHomeChannel(row: row["home_channel"])
        envVars = (row["env_vars"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(MessagingEnvField.init(row:)) }
            .filter { !$0.isStripped }
        ingressURL = LenientField.text(row["ingress_url"])
        whatsappSetup = WhatsAppSetupInfo(row: row["whatsapp_setup"])
    }

    var tone: MessagingTone { MessagingTone.of(enabled: enabled, state: state) }

    func field(_ key: String) -> MessagingEnvField? { envVars.first { $0.key == key } }

    /// The search and the status filter (`platformMatches`): id, name, description and state.
    func matches(tone filter: MessagingTone?, query: String) -> Bool {
        if let filter, tone != filter { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return [id, name, description, state ?? ""].contains { $0.lowercased().contains(q) }
    }
}

// MARK: - Setup edits

/// A platform write (`MessagingPlatformUpdate`): values to store, keys to remove, and the enabled flag.
struct MessagingPlatformUpdate: Equatable {
    var env: [String: String] = [:]
    var clearEnv: [String] = []
    var enabled: Bool?

    var hasChanges: Bool { !env.isEmpty || !clearEnv.isEmpty }

    /// The request body; keys left out keep what is saved.
    var body: JSON {
        var body: JSON = [:]
        if !env.isEmpty { body["env"] = env }
        if !clearEnv.isEmpty { body["clear_env"] = clearEnv }
        if let enabled { body["enabled"] = enabled }
        return body
    }

    /// The write a platform's unsaved draft makes (`platformChanges`): every non-blank value is stored (trimmed);
    /// a saved allowlist emptied in its editor is cleared (a blank value alone reads as untouched).
    static func changes(_ platform: MessagingPlatform, draft: [String: String]) -> MessagingPlatformUpdate {
        var update = MessagingPlatformUpdate()
        for (key, value) in draft {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { update.env[key] = trimmed }
        }
        update.clearEnv = platform.envVars
            .filter { $0.isList && $0.isSet && draft[$0.key]?.trimmingCharacters(in: .whitespacesAndNewlines) == "" }
            .map(\.key)
        return update
    }
}

/// Allowlists are stored as one comma-separated env value; a pasted list may also use newlines.
enum MessagingAllowlist {
    static func split(_ raw: String?) -> [String] {
        (raw ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Trimmed, blanks and repeats dropped, first occurrence kept.
    static func join(_ entries: [String]) -> String {
        var seen = Set<String>()
        return entries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ",")
    }
}

/// `PUT /api/messaging/platforms/{id}`: `hotServed` when a live multiplexer serving the profile rebuilt its adapters
/// from the new config at once (no restart needed).
struct MessagingUpdateResult: Hashable {
    var ok: Bool
    var hotServed: Bool

    init(response: JSON) {
        ok = LenientField.optionalBool(response["ok"]) ?? true
        hotServed = LenientField.bool(response["hot_served"])
    }
}

/// `POST /api/messaging/platforms/{id}/test`: whether the platform is connected, and what to fix if not. A connected
/// platform also says who can reach the bot (`auth_posture`: open, allowlist, pairing or deny_all).
struct MessagingTestResult: Hashable {
    var ok: Bool
    var state: String?
    var message: String
    var authPosture: String?

    init(response: JSON) {
        ok = LenientField.bool(response["ok"])
        state = LenientField.text(response["state"])
        message = LenientField.text(response["message"]) ?? (ok ? "Connected." : "The test didn't pass.")
        authPosture = LenientField.text(response["auth_posture"])
    }

    /// Connected, but no sender can get through: worth a warning rather than a plain success.
    var unreachable: Bool { ok && authPosture == "deny_all" }
}

// MARK: - Pairing

/// A pending pairing request, or an already-approved user, on one platform (`PairingUser`).
struct PairingUser: Hashable, Identifiable {
    var platform: String
    var userID: String
    var userName: String?
    /// Pending rows only: what approval grants on (the requester's code is never returned).
    var requestID: String?
    var ageMinutes: Int?

    init(platform: String, userID: String, userName: String? = nil, requestID: String? = nil, ageMinutes: Int? = nil) {
        self.platform = platform
        self.userID = userID
        self.userName = userName
        self.requestID = requestID
        self.ageMinutes = ageMinutes
    }

    init?(row: JSON) {
        guard let platform = LenientField.text(row["platform"]),
              let userID = LenientField.text(row["user_id"]) ?? (row["user_id"] as? NSNumber)?.stringValue else { return nil }
        self.platform = platform
        self.userID = userID
        userName = LenientField.text(row["user_name"])
        requestID = LenientField.text(row["request_id"])
        ageMinutes = LenientField.optionalInt(row["age_minutes"])
    }

    /// A user id is only unique within its platform.
    var id: String { "\(platform):\(userID)" }

    var label: String { userName ?? userID }

    /// The row's second line: the id when a name is the title, and how long a request has waited.
    var detail: String {
        var parts: [String] = []
        if userName != nil { parts.append(userID) }
        if let ageMinutes { parts.append(ageMinutes < 1 ? "just now" : "\(ageMinutes)m ago") }
        return parts.joined(separator: " · ")
    }
}

/// `GET /api/pairing`: who waits to be let in and who already is, for every platform of the profile.
struct PairingLists: Hashable {
    var pending: [PairingUser] = []
    var approved: [PairingUser] = []

    init() {}

    init(response: JSON) {
        pending = (response["pending"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(PairingUser.init(row:)) }
        approved = (response["approved"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(PairingUser.init(row:)) }
    }

    func pending(for platform: String) -> [PairingUser] { pending.filter { $0.platform == platform } }
    func approved(for platform: String) -> [PairingUser] { approved.filter { $0.platform == platform } }
}

// MARK: - QR onboarding

/// What a Telegram or WhatsApp onboarding's apply answered: the setup is saved, and the gateway restart the host
/// started (or why it couldn't).
struct OnboardingApplyResult: Hashable {
    var ok: Bool
    var botUsername: String?
    var needsRestart: Bool
    var restartStarted: Bool
    var restartError: String?
    /// The restart was refused because sessions are running.
    var restartBusy: Bool

    init(response: JSON) {
        ok = LenientField.optionalBool(response["ok"]) ?? true
        botUsername = LenientField.text(response["bot_username"])
        restartStarted = LenientField.bool(response["restart_started"])
        needsRestart = LenientField.optionalBool(response["needs_restart"]) ?? !restartStarted
        restartError = LenientField.text(response["restart_error"])
        restartBusy = LenientField.bool(response["restart_busy"])
    }
}

/// `POST /api/messaging/telegram/onboarding/start`: the pairing the Nous setup service minted. `deepLink` opens
/// Telegram (on this phone); `qrPayload` is the same link for another device to scan.
struct TelegramOnboardingStart: Hashable {
    var pairingID: String
    var suggestedUsername: String?
    var deepLink: URL
    var qrPayload: String
    var expiresAt: String

    init?(response: JSON) {
        guard let pairingID = LenientField.text(response["pairing_id"]),
              let link = LenientField.text(response["deep_link"]), let deepLink = MessagingLinks.telegram(link) else { return nil }
        self.pairingID = pairingID
        self.deepLink = deepLink
        suggestedUsername = LenientField.text(response["suggested_username"])
        qrPayload = LenientField.text(response["qr_payload"]) ?? link
        expiresAt = LenientField.text(response["expires_at"]) ?? ""
    }
}

/// `GET /api/messaging/telegram/onboarding/{id}`: still waiting, or the bot exists.
enum TelegramOnboardingStatus: Hashable {
    case waiting
    case ready(botUsername: String?, ownerUserID: String?)

    init(response: JSON) {
        if LenientField.text(response["status"]) == "ready" {
            let owner = LenientField.text(response["owner_user_id"]) ?? (response["owner_user_id"] as? NSNumber)?.stringValue
            self = .ready(botUsername: LenientField.text(response["bot_username"]), ownerUserID: owner)
        } else {
            self = .waiting
        }
    }
}

/// WhatsApp's bridge modes: a separate bot number, or the user's own number answering in "Message yourself".
enum WhatsAppMode: String, CaseIterable, Identifiable, Hashable {
    case bot
    case selfChat = "self-chat"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bot: return "Bot"
        case .selfChat: return "Self-chat"
        }
    }
}

/// A WhatsApp pairing on the host (`WhatsAppOnboardingStartResponse`): the bridge's state, its current QR code and,
/// once linked, the account that scanned it.
struct WhatsAppOnboardingSession: Hashable {
    /// `starting`, `installing`, `waiting`, `connected`, `error`, `expired` or `cancelled`.
    var pairingID: String
    var status: String
    var qrPayload: String?
    var expiresAt: String
    var mode: WhatsAppMode
    var allowedUsers: String
    var accountID: String?
    var accountName: String?
    var accountPhone: String?
    var error: String?

    init?(response: JSON) {
        guard let pairingID = LenientField.text(response["pairing_id"]) else { return nil }
        self.pairingID = pairingID
        status = LenientField.text(response["status"]) ?? "starting"
        qrPayload = LenientField.text(response["qr_payload"])
        expiresAt = LenientField.text(response["expires_at"]) ?? ""
        mode = LenientField.text(response["mode"]).flatMap(WhatsAppMode.init(rawValue:)) ?? .bot
        allowedUsers = LenientField.text(response["allowed_users"]) ?? ""
        accountID = LenientField.text(response["account_id"])
        accountName = LenientField.text(response["account_name"])
        accountPhone = LenientField.text(response["account_phone"])
        error = LenientField.text(response["error"])
    }

    /// How the linked account is named: its number, else its name, else its id.
    var linkedAccountLabel: String? {
        if let accountPhone { return "+\(accountPhone)" }
        return accountName ?? accountID
    }

    /// A chat with the linked account (`wa.me`), when its number is known.
    var chatURL: URL? {
        guard let accountPhone, accountPhone.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://wa.me/\(accountPhone)")
    }
}

/// The QR onboardings' expiry and error readings, shared by Telegram and WhatsApp.
enum OnboardingTiming {
    /// `m:ss` until `expiresAt`, or nil once it has passed (or can't be read) (`formatExpiry`).
    static func remaining(_ expiresAt: String, now: Date = Date()) -> String? {
        guard let date = date(expiresAt) else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        let seconds = Int(interval.rounded(.up))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    static func isExpired(_ expiresAt: String, now: Date = Date()) -> Bool {
        guard let date = date(expiresAt) else { return false }
        return now >= date
    }

    /// ISO-8601 with or without fractional seconds (the host writes microseconds) or an offset.
    static func date(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // Drop a fraction the formatter won't read (more than three digits), keeping the zone.
        guard let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].first?.isNumber == true else {
            return plain.date(from: text + "Z")
        }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        let trimmed = String(text[..<dot]) + String(text[end...])
        return plain.date(from: trimmed) ?? plain.date(from: trimmed + "Z")
    }

    /// A 410 from a status poll: the pairing is gone for good (expired, claimed), so polling stops.
    static func isTerminal(_ error: Error) -> Bool {
        if case let .http(code, _)? = error as? DashboardError { return code == 410 }
        return false
    }
}

/// Links the platform cards carry: only web addresses are opened (and Telegram's own scheme for its setup link).
enum MessagingLinks {
    static func web(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// The setup service's deep link: `https://t.me/…`, or `tg://…`.
    static func telegram(_ text: String) -> URL? {
        if let url = web(text) { return url }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "tg" else {
            return nil
        }
        return url
    }
}

// MARK: - Routes

/// The messaging, pairing and gateway routes for one profile (`?profile=`; nil is the dashboard's own). Approve,
/// revoke and the onboarding applies also carry the profile in the body, where the host reads it.
struct MessagingAPI: CapabilityRoutes {
    let transport: CapabilitiesTransport
    let profile: String?

    /// The onboarding service can take a while to answer (it talks to Telegram, or installs the WhatsApp bridge).
    static let onboardingTimeout: TimeInterval = 120

    private var bodyProfile: JSON { profile.map { ["profile": $0] } ?? [:] }

    // MARK: Platforms

    func platforms() async throws -> [MessagingPlatform] {
        let result = try await get("/api/messaging/platforms") as? JSON ?? [:]
        return (result["platforms"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(MessagingPlatform.init(row:)) }
    }

    /// Stores, clears and switches. A typed value never comes back in an error.
    func update(_ platformID: String, _ update: MessagingPlatformUpdate) async throws -> MessagingUpdateResult {
        let path = "/api/messaging/platforms/\(try Self.segment(platformID))"
        do {
            return MessagingUpdateResult(response: try await send("PUT", path, update.body) as? JSON ?? [:])
        } catch {
            throw Self.scrubbed(error, secrets: Array(update.env.values))
        }
    }

    func test(_ platformID: String) async throws -> MessagingTestResult {
        let path = "/api/messaging/platforms/\(try Self.segment(platformID))/test"
        return MessagingTestResult(response: try await transport.request("POST", path, query: scopeQuery, body: nil) as? JSON ?? [:])
    }

    // MARK: Pairing

    func pairing() async throws -> PairingLists {
        PairingLists(response: try await get("/api/pairing") as? JSON ?? [:])
    }

    /// Grants on the row's request id, never on a code.
    func approve(_ user: PairingUser) async throws {
        guard let requestID = user.requestID else { throw DashboardError.rpc("This request can't be approved from here.") }
        _ = try await send("POST", "/api/pairing/approve", Self.approveBody(user, requestID: requestID, profile: profile))
    }

    func revoke(_ user: PairingUser) async throws {
        _ = try await send("POST", "/api/pairing/revoke", Self.revokeBody(user, profile: profile))
    }

    /// Clears every platform's pending requests; answers how many went.
    func clearPending() async throws -> Int {
        let result = try await transport.request("POST", "/api/pairing/clear-pending", query: scopeQuery, body: nil) as? JSON
        return LenientField.int(result?["cleared"])
    }

    static func approveBody(_ user: PairingUser, requestID: String, profile: String?) -> JSON {
        var body: JSON = ["platform": user.platform, "request_id": requestID]
        if let profile { body["profile"] = profile }
        return body
    }

    static func revokeBody(_ user: PairingUser, profile: String?) -> JSON {
        var body: JSON = ["platform": user.platform, "user_id": user.userID]
        if let profile { body["profile"] = profile }
        return body
    }

    // MARK: Telegram

    // Pairing state lives in the memory of the process that started it, so every call of one flow carries the same
    // profile scope.

    func startTelegram(botName: String? = nil) async throws -> TelegramOnboardingStart {
        let body: JSON = botName.map { ["bot_name": $0] } ?? [:]
        let result = try await transport.request("POST", "/api/messaging/telegram/onboarding/start", query: scopeQuery,
                                                 body: body, timeout: Self.onboardingTimeout) as? JSON ?? [:]
        guard let start = TelegramOnboardingStart(response: result) else {
            throw DashboardError.rpc("Telegram setup service returned an incomplete response.")
        }
        return start
    }

    func telegramStatus(_ pairingID: String) async throws -> TelegramOnboardingStatus {
        TelegramOnboardingStatus(response: try await get("/api/messaging/telegram/onboarding/\(try Self.segment(pairingID))") as? JSON ?? [:])
    }

    func applyTelegram(_ pairingID: String, allowedUserIDs: [String]) async throws -> OnboardingApplyResult {
        let path = "/api/messaging/telegram/onboarding/\(try Self.segment(pairingID))/apply"
        let result = try await transport.request("POST", path, query: scopeQuery,
                                                 body: Self.telegramApplyBody(allowedUserIDs, profile: profile),
                                                 timeout: Self.onboardingTimeout) as? JSON
        return OnboardingApplyResult(response: result ?? [:])
    }

    /// Best effort: the host prunes expired pairings itself.
    func cancelTelegram(_ pairingID: String) async {
        guard let segment = try? Self.segment(pairingID) else { return }
        _ = try? await transport.request("DELETE", "/api/messaging/telegram/onboarding/\(segment)", query: scopeQuery, body: nil)
    }

    static func telegramApplyBody(_ ids: [String], profile: String?) -> JSON {
        var body: JSON = ["allowed_user_ids": ids]
        if let profile { body["profile"] = profile }
        return body
    }

    // MARK: WhatsApp

    /// `resetSession` backs up the saved link and pairs anew (re-pair); otherwise saved credentials answer
    /// `connected` without a QR code.
    func startWhatsApp(mode: WhatsAppMode, allowedUsers: String, resetSession: Bool) async throws -> WhatsAppOnboardingSession {
        let result = try await transport.request("POST", "/api/messaging/whatsapp/onboarding/start", query: scopeQuery,
                                                 body: Self.whatsappStartBody(mode: mode, allowedUsers: allowedUsers,
                                                                              resetSession: resetSession, profile: profile),
                                                 timeout: Self.onboardingTimeout) as? JSON ?? [:]
        guard let session = WhatsAppOnboardingSession(response: result) else {
            throw DashboardError.rpc("WhatsApp setup didn't start.")
        }
        return session
    }

    func whatsappStatus(_ pairingID: String) async throws -> WhatsAppOnboardingSession {
        let result = try await get("/api/messaging/whatsapp/onboarding/\(try Self.segment(pairingID))") as? JSON ?? [:]
        guard let session = WhatsAppOnboardingSession(response: result) else {
            throw DashboardError.rpc("WhatsApp setup session was not found. Start a new setup.")
        }
        return session
    }

    func applyWhatsApp(_ pairingID: String, mode: WhatsAppMode, allowedUsers: String) async throws -> OnboardingApplyResult {
        let path = "/api/messaging/whatsapp/onboarding/\(try Self.segment(pairingID))/apply"
        let result = try await transport.request("POST", path, query: scopeQuery,
                                                 body: Self.whatsappApplyBody(mode: mode, allowedUsers: allowedUsers, profile: profile),
                                                 timeout: Self.onboardingTimeout) as? JSON
        return OnboardingApplyResult(response: result ?? [:])
    }

    func cancelWhatsApp(_ pairingID: String) async {
        guard let segment = try? Self.segment(pairingID) else { return }
        _ = try? await transport.request("DELETE", "/api/messaging/whatsapp/onboarding/\(segment)", query: scopeQuery, body: nil)
    }

    static func whatsappStartBody(mode: WhatsAppMode, allowedUsers: String, resetSession: Bool, profile: String?) -> JSON {
        var body: JSON = ["mode": mode.rawValue, "allowed_users": allowedUsers.trimmingCharacters(in: .whitespacesAndNewlines),
                          "reset_session": resetSession]
        if let profile { body["profile"] = profile }
        return body
    }

    static func whatsappApplyBody(mode: WhatsAppMode, allowedUsers: String, profile: String?) -> JSON {
        var body: JSON = ["mode": mode.rawValue, "allowed_users": allowedUsers.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let profile { body["profile"] = profile }
        return body
    }

    // MARK: Gateway

    /// `hermes gateway start` for the profile, spawned on the host (`gateway-start`). A multiplexed profile refuses
    /// with 409 and the reason.
    func startGateway() async throws -> OpsActionStart {
        OpsActionStart(response: try await transport.request("POST", "/api/gateway/start", query: scopeQuery, body: nil) as? JSON ?? [:],
                       fallbackName: "gateway-start")
    }

    /// `hermes gateway restart --interrupt` for the profile, spawned on the host (`gateway-restart`).
    func restartGateway() async throws -> OpsActionStart {
        OpsActionStart(response: try await transport.request("POST", "/api/gateway/restart", query: scopeQuery, body: nil) as? JSON ?? [:],
                       fallbackName: "gateway-restart")
    }

    func actionStatus(_ name: String) async throws -> OpsActionStatus {
        let result = try await transport.request("GET", "/api/actions/\(try Self.segment(name))/status",
                                                 query: ["lines": "40"], body: nil) as? JSON ?? [:]
        return OpsActionStatus(response: result, fallbackName: name)
    }

    /// The profile's gateway status, for whether a restart restarts a shared multiplexer.
    func gatewayStatus() async throws -> HermesStatus {
        HermesStatus(response: try await get("/api/status") as? JSON ?? [:])
    }

    // MARK: Helpers

    static func segment(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains("/"), !value.contains("?"), !value.contains("#") else {
            throw DashboardError.rpc("“\(value)” can't be addressed on the dashboard.")
        }
        return value
    }

    /// `error` with every typed value blanked out of whatever the dashboard sent back.
    static func scrubbed(_ error: Error, secrets: [String]) -> Error {
        guard case let .http(code, body)? = error as? DashboardError else { return error }
        return DashboardError.http(code, secrets.reduce(body) { CredentialMask.scrub($0, secret: $1) })
    }
}

/// Watching a gateway action the app (or the host, after an onboarding) started: polled every 1.2 s, 18 times
/// (`awaitAction`). While the gateway restarts, failed reads and a fresh process that never saw the action
/// (stopped, no exit code) are the restart window itself. Only an answered poll proves the gateway came back; a
/// recorded non-zero exit is a failure; still running when the window closes counts as done (a no-service install's
/// child becomes the gateway and never exits).
enum GatewayActionWatch {
    static let polls = 18

    static func poll() -> OpsActionPoll {
        OpsActionPoll(limit: polls, maxConsecutiveFailures: polls)
    }

    static func succeeded(_ poll: OpsActionPoll) -> Bool {
        guard let latest = poll.latest else { return false }
        return latest.outcome != .failed
    }
}
