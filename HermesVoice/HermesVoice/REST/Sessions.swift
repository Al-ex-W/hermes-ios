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
    /// store that holds it; the handler reads its database from the body. Returns the stored title.
    @discardableResult
    func updateSession(_ id: String, profile: String?, title: String? = nil, pinned: Bool? = nil,
                       archived: Bool? = nil, unread: Bool? = nil) async throws -> String? {
        var body: JSON = [:]
        if let title { body["title"] = title }
        if let pinned { body["pinned"] = pinned }
        if let archived { body["archived"] = archived }
        if let unread { body["unread"] = unread }
        if let profile { body["profile"] = profile }
        let result = try await request("PATCH", "/api/sessions/\(id)", body: body) as? JSON
        return result?["title"] as? String
    }

    /// Deletes a session and its transcript for good. Already gone counts as done.
    func deleteSession(_ id: String, profile: String?) async throws {
        _ = try await request("DELETE", "/api/sessions/\(id)", query: profile.map { ["profile": $0] } ?? [:])
    }
}
