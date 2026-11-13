import Foundation

/// A stored session as the session lists return it (`SessionInfo` in the desktop's `types/hermes.ts`).
/// Rows decode leniently: a missing or mistyped field keeps its default.
struct SessionInfo: Identifiable, Hashable {
    let id: String
    var title: String?
    var preview: String?
    var source: String?
    var model: String?
    /// The profile whose store holds it; the cross-profile lists tag every row ("default" for the root profile).
    var profile: String?
    var startedAt: Date?
    var lastActive: Date?
    var messageCount = 0
    var inputTokens = 0
    var outputTokens = 0
    /// Provider-reported spend, else Hermes' own estimate; 0 on subscription auth.
    var costUSD: Double = 0
    var archived = false
    var pinned = false
    /// Marked unread, or a reply landed after it was last read (the backend's read watermark).
    var unread = false
    var hidden = false
    var cwd: String?
    var gitRepoRoot: String?
    var gitBranch: String?
    /// Every id on its compression chain when the row is the chain's tip, so state kept under an older id finds it.
    var lineageIDs: [String] = []

    init(id: String, title: String? = nil, preview: String? = nil, source: String? = nil, profile: String? = nil,
         startedAt: Date? = nil, lastActive: Date? = nil) {
        self.id = id
        self.title = title
        self.preview = preview
        self.source = source
        self.profile = profile
        self.startedAt = startedAt
        self.lastActive = lastActive
    }

    init?(row: JSON) {
        guard let id = (row["id"] ?? row["session_id"]).flatMap(DashboardClient.string), !id.isEmpty else { return nil }
        self.id = id
        title = Self.text(row["title"])
        preview = Self.text(row["preview"])
        source = Self.text(row["source"])
        model = Self.text(row["model"])
        profile = Self.text(row["profile"])
        startedAt = row["started_at"].flatMap(DashboardClient.date)
        lastActive = row["last_active"].flatMap(DashboardClient.date) ?? startedAt
        messageCount = Self.int(row["message_count"])
        inputTokens = Self.int(row["input_tokens"])
        outputTokens = Self.int(row["output_tokens"])
        let actual = Self.double(row["actual_cost_usd"])
        costUSD = actual > 0 ? actual : Self.double(row["estimated_cost_usd"])
        archived = Self.bool(row["archived"])
        pinned = Self.bool(row["pinned"])
        unread = Self.bool(row["unread"])
        hidden = Self.bool(row["hidden"])
        cwd = Self.text(row["cwd"])
        gitRepoRoot = Self.text(row["git_repo_root"])
        gitBranch = Self.text(row["git_branch"])
        lineageIDs = (row["_lineage_ids"] as? [Any])?.compactMap(DashboardClient.string).filter { $0 != id } ?? []
        if let root = row["_lineage_root_id"].flatMap(DashboardClient.string), root != id, !lineageIDs.contains(root) {
            lineageIDs.append(root)
        }
    }

    /// The title, else the first message, as the desktop names a row.
    var displayTitle: String { title ?? preview ?? "Untitled session" }
    /// When it was last active, for ordering and date groups.
    var recency: Date { lastActive ?? startedAt ?? .distantPast }
    var tokens: Int { inputTokens + outputTokens }
    /// The row's id and every older id of its chain.
    var allIDs: [String] { [id] + lineageIDs }
    /// What `AppModel.chat(for:)` opens it from.
    var summary: SessionSummary { SessionSummary(id: id, title: displayTitle, lastActive: lastActive, profile: profile) }

    fileprivate static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    fileprivate static func double(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    fileprivate static func bool(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }
}

/// One `/api/sessions/search` hit: the matched conversation (resume by its id, the compression tip) and the
/// matched text.
struct SessionSearchHit: Hashable {
    var session: SessionInfo
    var snippet: String?

    init?(row: JSON) {
        guard let id = (row["session_id"] ?? row["id"]).flatMap(DashboardClient.string), !id.isEmpty else { return nil }
        let started = row["session_started"].flatMap(DashboardClient.date) ?? row["started_at"].flatMap(DashboardClient.date)
        var session = SessionInfo(
            id: id, title: SessionInfo.text(row["title"]), source: SessionInfo.text(row["source"]),
            profile: SessionInfo.text(row["profile"]), startedAt: started,
            lastActive: row["last_active"].flatMap(DashboardClient.date) ?? started
        )
        session.model = SessionInfo.text(row["model"])
        session.archived = SessionInfo.bool(row["archived"])
        session.messageCount = SessionInfo.int(row["message_count"])
        if let root = row["lineage_root"].flatMap(DashboardClient.string), root != id { session.lineageIDs = [root] }
        snippet = SessionInfo.text(Self.stripMarkers(row["snippet"] as? String ?? ""))
        session.preview = snippet ?? SessionInfo.text(row["preview"])
        self.session = session
    }

    /// FTS wraps matched terms in `>>>` / `<<<`.
    static func stripMarkers(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: ">>>", with: "").replacingOccurrences(of: "<<<", with: "")
    }
}

/// The sidebar's session slices (`GET /api/profiles/sessions/sidebar`).
struct SidebarSessions {
    var recents: [SessionInfo] = []
    /// Conversations from messaging platforms, which get their own sections.
    var messaging: [SessionInfo] = []
    /// Some profile filled its window, so more recents exist on disk.
    var truncated = false
    /// Profiles whose store couldn't be read this time; their rows are missing, not gone.
    var unreadable: [String] = []
    /// The whole answer is a failed load, not an empty list.
    var failed = false

    init() {}

    init(response: JSON) {
        let recentsSlice = response["recents"] as? JSON ?? [:]
        let messagingSlice = response["messaging"] as? JSON ?? [:]
        recents = Self.rows(recentsSlice["sessions"])
        messaging = Self.rows(messagingSlice["sessions"])
        truncated = (recentsSlice["profiles_truncated"] as? [String: Any])?.values.contains { ($0 as? Bool) == true } ?? false
        failed = (recentsSlice["failed"] as? Bool) == true
        var unreadable = Set((response["errors"] as? [JSON] ?? []).compactMap { $0["profile"] as? String })
        unreadable.formUnion((response["storage"] as? [String: Any] ?? [:]).keys)
        self.unreadable = unreadable.sorted()
    }

    static func rows(_ value: Any?) -> [SessionInfo] {
        (value as? [JSON] ?? []).compactMap(SessionInfo.init(row:)).filter { !$0.hidden }
    }
}

/// Session sources as the desktop sorts them (`lib/session-source.ts`).
enum SessionSource {
    /// Sources that run on the Hermes host rather than on a messaging platform.
    static let local = ["acp", "cli", "codex", "desktop", "gateway", "kanban", "local", "oneshot", "tui"]
    static let messaging = [
        "telegram", "discord", "slack", "mattermost", "matrix", "signal", "whatsapp", "bluebubbles", "photon",
        "homeassistant", "email", "sms", "webhook", "api_server", "weixin", "wecom", "qqbot", "yuanbao", "dingtalk",
        "feishu",
    ]
    /// Kept out of recents: cron and messaging have their own sections, and editor, kanban, one-shot, subagent and
    /// tool runs aren't conversations.
    static let recentsExcluded = ["acp", "cron", "kanban", "oneshot", "subagent", "tool"] + messaging
    static let messagingExcluded = ["cron"] + local

    private static let labels = [
        "acp": "ACP", "api_server": "API", "bluebubbles": "iMessage", "cli": "CLI", "codex": "Codex",
        "desktop": "Desktop", "discord": "Discord", "email": "Email", "gateway": "Gateway", "kanban": "Kanban",
        "local": "Local", "matrix": "Matrix", "mattermost": "Mattermost", "oneshot": "One-shot", "photon": "Photon",
        "qqbot": "QQ", "signal": "Signal", "slack": "Slack", "sms": "SMS", "telegram": "Telegram", "tui": "TUI",
        "webhook": "Webhook", "weixin": "WeChat", "whatsapp": "WhatsApp", "yuanbao": "Yuanbao",
    ]

    static func label(_ source: String?) -> String {
        guard let source = source?.lowercased(), !source.isEmpty else { return "Other" }
        return labels[source] ?? source.prefix(1).uppercased() + source.dropFirst()
    }
}

extension DashboardClient {
    /// Recents and messaging slices in one request. `profile` scopes the whole answer; "all" spans every profile.
    /// An older backend without the batched route gets the per-slice list twice instead.
    func sidebarSessions(profile: String, recentsLimit: Int, messagingLimit: Int = 100) async throws -> SidebarSessions {
        let query = [
            "recents_profile": profile, "recents_limit": String(max(1, recentsLimit)), "cron_limit": "1",
            "messaging_limit": String(max(1, messagingLimit)),
            "recents_exclude": SessionSource.recentsExcluded.joined(separator: ","),
            "messaging_exclude": SessionSource.messagingExcluded.joined(separator: ","),
        ]
        do {
            let result = try await request("GET", "/api/profiles/sessions/sidebar", query: query) as? JSON
            return SidebarSessions(response: result ?? [:])
        } catch let DashboardError.http(code, _) where code == 404 {
            var slices = SidebarSessions()
            let recents = try await profileSessions(profile: profile, limit: recentsLimit, minMessages: 1,
                                                    excludeSources: SessionSource.recentsExcluded)
            slices.recents = recents.rows
            slices.truncated = recents.rows.count >= recentsLimit
            slices.unreadable = recents.unreadable
            slices.messaging = try await profileSessions(profile: profile, limit: messagingLimit, minMessages: 1,
                                                         excludeSources: SessionSource.messagingExcluded).rows
            return slices
        }
    }

    /// One page of the cross-profile list (`GET /api/profiles/sessions`), newest activity first.
    /// `archived`: "exclude", "only" or "include".
    func profileSessions(profile: String, limit: Int, minMessages: Int = 0, archived: String = "exclude",
                         excludeSources: [String] = []) async throws -> (rows: [SessionInfo], unreadable: [String]) {
        var query = [
            "limit": String(limit), "offset": "0", "min_messages": String(minMessages), "archived": archived,
            "order": "recent", "profile": profile,
        ]
        if !excludeSources.isEmpty { query["exclude_sources"] = excludeSources.joined(separator: ",") }
        let result = try await request("GET", "/api/profiles/sessions", query: query) as? JSON ?? [:]
        let unreadable = (result["errors"] as? [JSON] ?? []).compactMap { $0["profile"] as? String }
        return (SidebarSessions.rows(result["sessions"]), unreadable)
    }

    /// The archived sessions, a list of their own: the sidebar lists leave them out.
    func archivedSessions(profile: String, limit: Int = 200) async throws -> [SessionInfo] {
        try await profileSessions(profile: profile, limit: limit, archived: "only").rows
    }

    /// Searches one profile's sessions by id, then message text. Ranked: id matches first. nil searches the
    /// dashboard's own profile.
    func searchSessions(_ text: String, profile: String? = nil, limit: Int = 20) async throws -> [SessionSearchHit] {
        var query = ["q": text, "limit": String(limit)]
        if let profile { query["profile"] = profile }
        let result = try await request("GET", "/api/sessions/search", query: query) as? JSON
        return (result?["results"] as? [JSON] ?? []).compactMap(SessionSearchHit.init(row:))
    }

    /// Renames (an empty title clears it) or flags a session (`PATCH /api/sessions/:id`). `profile` names the
    /// store that holds it; the handler reads its database from the body. Returns the stored title when the answer
    /// carries one.
    @discardableResult
    func updateSession(_ id: String, profile: String?, title: String? = nil, pinned: Bool? = nil,
                       archived: Bool? = nil, unread: Bool? = nil) async throws -> String? {
        var body: JSON = [:]
        if let title { body["title"] = title }
        if let pinned { body["pinned"] = pinned }
        if let archived { body["archived"] = archived }
        if let unread { body["unread"] = unread }
        return try await mutateSession("PATCH", id: id, profile: profile, payload: body)?["title"] as? String
    }

    /// Deletes a session and its transcript for good. Already gone counts as done.
    func deleteSession(_ id: String, profile: String?) async throws {
        _ = try await mutateSession("DELETE", id: id, profile: profile)
    }

    /// One edit of a stored session: `PATCH` (title and sidebar flags) or `DELETE`, the way the desktop sends it
    /// (`apps/shared/src/session-http-mutations.ts`, `apps/desktop/src/api/sessions.ts`). Since Hermes 0.22.3 an
    /// edit must say which state of the session it applies to, or it is refused with 409
    /// `client_upgrade_required`: the app reads `GET /api/sessions/:id/mutation-snapshot` and sends its
    /// `runtime_revision` (and `runtime_generation`) back as `expected_revision` / `expected_generation` with a
    /// `request_id`, in the body of a `PATCH` and in the query of a `DELETE`.
    ///
    /// - An edit whose answer never arrived keeps its `request_id`, so trying the same edit again can't apply twice.
    /// - A session that changed between the snapshot and the edit (`revision_conflict`, `stale_generation`) is read
    ///   and sent once more: a rename or a flag the user just chose is meant for the session as it is now.
    /// - A Hermes without the snapshot route (before 0.22.3) takes the plain edit.
    @discardableResult
    func mutateSession(_ method: String, id: String, profile: String?, payload: JSON = [:]) async throws -> JSON? {
        let path = "/api/sessions/\(try Self.segment(id))"
        let scope = profile.map { ["profile": $0] } ?? [:]
        let key = SessionMutationLedger.key(profile: profile, id: id, method: method, payload: payload)

        func send(_ identity: SessionMutationIdentity?) async throws -> JSON? {
            if method == "DELETE" {
                return try await request("DELETE", path, query: scope.merging(identity?.query ?? [:]) { $1 }) as? JSON
            }
            var body = payload.merging(identity?.fields ?? [:]) { $1 }
            if let profile { body["profile"] = profile }
            return try await request(method, path, body: body) as? JSON
        }

        for attempt in 0..<2 {
            var identity = sessionMutations.pending(key)
            if identity == nil {
                let row: JSON?
                do {
                    row = try await request("GET", "\(path)/mutation-snapshot", query: scope) as? JSON
                } catch let error where SessionMutationLedger.isMissingRoute(error) {
                    return try await send(nil)
                }
                guard let snapshot = row.flatMap(SessionMutationSnapshot.init(row:)) else {
                    throw DashboardError.rpc("Hermes couldn't say what state this conversation is in. Refresh and try again.")
                }
                guard snapshot.exists else {
                    if method == "DELETE" { return ["ok": true, "already_absent": true] }
                    throw DashboardError.rpc("This conversation is no longer on Hermes.")
                }
                identity = SessionMutationIdentity(snapshot: snapshot)
                sessionMutations.keep(identity!, for: key)
            }
            do {
                let result = try await send(identity)
                sessionMutations.settle(key)
                return result
            } catch {
                // Hermes refused it: the identity is spent. A lost answer keeps it for the next try of the same edit.
                if error.isRefusal { sessionMutations.drop(key) }
                if attempt == 0, SessionMutationLedger.isConflict(error) { continue }
                throw SessionMutationLedger.explained(error)
            }
        }
        throw DashboardError.rpc("This conversation keeps changing on Hermes. Try again in a moment.")
    }
}

/// What Hermes holds of a stored session before an edit (`GET /api/sessions/:id/mutation-snapshot`).
struct SessionMutationSnapshot: Equatable {
    let exists: Bool
    let revision: Int
    let generation: Int?

    /// nil when the row isn't a usable snapshot (the desktop refuses those too: `createSessionMutationClient`).
    init?(row: JSON) {
        guard let exists = row["exists"] as? Bool, let revision = Self.count(row["runtime_revision"]) else { return nil }
        let generation = Self.count(row["runtime_generation"])
        if exists, generation == nil { return nil }
        self.exists = exists
        self.revision = revision
        self.generation = exists ? generation : nil
    }

    /// A whole number of zero or more; JSON true/false is not one.
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double == double.rounded(), double < 9_007_199_254_740_992 else { return nil }
        return number.intValue
    }
}

/// What an edit carries so Hermes applies it once, and only to the session the app read.
struct SessionMutationIdentity: Equatable {
    let requestID: String
    let expectedRevision: Int
    let expectedGeneration: Int?

    init(snapshot: SessionMutationSnapshot, requestID: String = UUID().uuidString.lowercased()) {
        self.requestID = requestID
        expectedRevision = snapshot.revision
        expectedGeneration = snapshot.generation
    }

    /// The fields of a `PATCH` body.
    var fields: JSON {
        var fields: JSON = ["request_id": requestID, "expected_revision": expectedRevision]
        if let expectedGeneration { fields["expected_generation"] = expectedGeneration }
        return fields
    }

    /// The same as query items, for a `DELETE`.
    var query: [String: String] {
        var query = ["request_id": requestID, "expected_revision": String(expectedRevision)]
        if let expectedGeneration { query["expected_generation"] = String(expectedGeneration) }
        return query
    }
}

/// The identities of session edits whose answer never arrived, by what the edit was. Used from any task.
final class SessionMutationLedger {
    private let lock = NSLock()
    private var identities: [String: SessionMutationIdentity] = [:]

    /// One edit: the store, the session, the method and what it changes.
    static func key(profile: String?, id: String, method: String, payload: JSON) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return scope(profile: profile, id: id) + "\(method)\u{1F}" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    private static func scope(profile: String?, id: String) -> String { "\(profile ?? "")\u{1F}\(id)\u{1F}" }

    func pending(_ key: String) -> SessionMutationIdentity? { lock.withLock { identities[key] } }

    func keep(_ identity: SessionMutationIdentity, for key: String) { lock.withLock { identities[key] = identity } }

    func drop(_ key: String) { lock.withLock { _ = identities.removeValue(forKey: key) } }

    /// The edit went through: it and every other edit kept for that session are spent (their revision is behind).
    func settle(_ key: String) {
        let parts = key.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
        let scope = parts.count == 3 ? "\(parts[0])\u{1F}\(parts[1])\u{1F}" : key
        lock.withLock { identities = identities.filter { !$0.key.hasPrefix(scope) } }
    }

    /// The dashboard has no such route (a Hermes before the fenced edits): its own 404 for an unknown API path, or
    /// headless `hermes serve`'s fixed body. A plain `{"detail": "Not Found"}` is not that verdict.
    static func isMissingRoute(_ error: Error) -> Bool {
        guard case let .http(404, body)? = error as? DashboardError else { return false }
        let text = body.lowercased()
        return text.contains("no such api endpoint") || text.contains("endpoint is likely missing")
            || text.contains("headless backend (hermes serve): web ui disabled")
    }

    /// The session changed between the snapshot and the edit.
    static func isConflict(_ error: Error) -> Bool {
        guard case let .http(409, body)? = error as? DashboardError else { return false }
        return body.contains("revision_conflict") || body.contains("stale_generation")
    }

    /// Hermes' refusal codes in words the user can act on; anything else as it came.
    static func explained(_ error: Error) -> Error {
        guard case let .http(code, body)? = error as? DashboardError, (400..<500).contains(code) else { return error }
        let reasons: [(String, String)] = [
            ("client_upgrade_required", "This Hermes needs a newer HermesVoice to edit conversations. Update the app."),
            ("revision_conflict", "This conversation changed on Hermes meanwhile. Try again."),
            ("stale_generation", "This conversation changed on Hermes meanwhile. Try again."),
            ("session_busy", "Hermes is busy with this conversation. Stop its turn, or try again in a moment."),
            ("admission_conflict", "Hermes is busy with this conversation. Stop its turn, or try again in a moment."),
            ("runtime_coordination_required",
             "This conversation is open in another Hermes window or terminal. Close it there, then try again."),
            ("permission_denied", "This sign-in isn't allowed to edit that conversation."),
            ("profile_mismatch", "That conversation belongs to another profile."),
        ]
        for (reason, message) in reasons where body.contains(reason) { return DashboardError.rpc(message) }
        return error
    }
}
