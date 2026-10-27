import Foundation

// The dashboard's skill routes (`hermes_cli/web_routers/skills.py`, the archive half of `status.py`'s learning
// routes, and `actions.py`'s background-action log), as the desktop's Capabilities ▸ Skills tab uses them. Every
// decoder is lenient: a missing or mistyped field falls back, unknown fields and kinds are ignored.

// MARK: - Transport

/// The REST calls the Capabilities screens make (`DashboardClient.request`), so tests can record them.
protocol CapabilitiesTransport: AnyObject {
    func request(_ method: String, _ path: String, query: [String: String], body: JSON?) async throws -> Any
    /// The same, waiting up to `timeout` for the answer: for routes the host answers only once the work is done
    /// (a hub search across every source, a bundle fetched and scanned), past the client's usual 30 s.
    func request(_ method: String, _ path: String, query: [String: String], body: JSON?,
                 timeout: TimeInterval) async throws -> Any
}

extension CapabilitiesTransport {
    func request(_ method: String, _ path: String, query: [String: String], body: JSON?,
                 timeout: TimeInterval) async throws -> Any {
        try await request(method, path, query: query, body: body)
    }
}

extension DashboardClient: CapabilitiesTransport {
    func request(_ method: String, _ path: String, query: [String: String], body: JSON?,
                 timeout: TimeInterval) async throws -> Any {
        try await opsRequest(method, path, query: query, body: body, timeout: timeout)
    }
}

/// A route family scoped to one profile: `?profile=` on every call when `profile` is set (nil is the dashboard's
/// own profile), like the desktop's `capabilityScoped`.
protocol CapabilityRoutes {
    var transport: CapabilitiesTransport { get }
    var profile: String? { get }
}

extension CapabilityRoutes {
    var scopeQuery: [String: String] { profile.map { ["profile": $0] } ?? [:] }

    func get(_ path: String, _ query: [String: String] = [:]) async throws -> Any {
        try await transport.request("GET", path, query: scopeQuery.merging(query) { _, new in new }, body: nil)
    }

    func get(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval) async throws -> Any {
        try await transport.request("GET", path, query: scopeQuery.merging(query) { _, new in new }, body: nil, timeout: timeout)
    }

    func send(_ method: String, _ path: String, _ body: JSON) async throws -> Any {
        try await transport.request(method, path, query: scopeQuery, body: body)
    }
}

// MARK: - Background actions

/// A spawned `hermes …` action (`spawn_profile_action`: `{ok, pid, name}`): its log is tailed by `name`.
struct CapabilityAction: Hashable {
    var name: String
    var ok: Bool

    init(name: String, ok: Bool = true) {
        self.name = name
        self.ok = ok
    }

    init(response: Any, fallbackName: String) {
        let row = response as? JSON ?? [:]
        name = LenientField.text(row["name"]) ?? fallbackName
        ok = LenientField.optionalBool(row["ok"]) ?? true
    }
}

/// `GET /api/actions/{name}/status`: the action's log tail and whether it still runs.
struct CapabilityActionStatus: Hashable {
    var name: String
    var running: Bool
    var exitCode: Int?
    var lines: [String]

    init(name: String, running: Bool, exitCode: Int? = nil, lines: [String] = []) {
        self.name = name
        self.running = running
        self.exitCode = exitCode
        self.lines = lines
    }

    init(response: Any, name: String) {
        let row = response as? JSON ?? [:]
        self.name = LenientField.text(row["name"]) ?? name
        running = LenientField.bool(row["running"])
        exitCode = LenientField.optionalInt(row["exit_code"])
        lines = (row["lines"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// Finished with exit code 0.
    var succeeded: Bool { !running && exitCode == 0 }
    /// Finished with a non-zero exit code.
    var failed: Bool { !running && exitCode.map { $0 != 0 } == true }
}

/// The action-log route, shared by the skill hub and the toolset post-setup runner.
struct CapabilityActionsAPI {
    let transport: CapabilitiesTransport

    func status(_ name: String, lines: Int = 200) async throws -> CapabilityActionStatus {
        let result = try await transport.request("GET", "/api/actions/\(name)/status", query: ["lines": "\(max(1, lines))"], body: nil)
        return CapabilityActionStatus(response: result, name: name)
    }

    /// Polls the log every `interval` until the action stops (or `attempts` polls), reporting each tail. A failed
    /// status read (a timeout on a phone network, a proxy's 502) is retried; `tolerance` failures in a row give up
    /// with `CapabilityActionLost`, since the action itself keeps running on the host.
    func follow(_ name: String, interval: Duration = .milliseconds(1200), attempts: Int = 150, tolerance: Int = 5,
                onUpdate: @MainActor (CapabilityActionStatus) -> Void) async throws -> CapabilityActionStatus {
        var last = CapabilityActionStatus(name: name, running: true)
        var failures = 0
        for _ in 0..<attempts {
            try await Task.sleep(for: interval)
            do {
                last = try await status(name)
            } catch {
                if error.isCancellation { throw error }
                failures += 1
                if failures >= max(1, tolerance) { throw CapabilityActionLost(name: name, reason: error.dashboardMessage) }
                continue
            }
            failures = 0
            await onUpdate(last)
            if !last.running { break }
        }
        return last
    }
}

/// The status of a background action couldn't be read several times in a row. The action itself isn't stopped:
/// it may still finish on the host.
struct CapabilityActionLost: LocalizedError, Equatable {
    let name: String
    let reason: String

    var errorDescription: String? {
        "Lost track of it, but it may still be running on the host. \(reason)"
    }
}

// MARK: - Installed skills

/// Where an installed skill came from (`GET /api/skills` `provenance`).
enum SkillProvenance: String, Hashable, CaseIterable {
    /// Learned or hand-made in the profile: the user's to edit or archive.
    case agent
    case bundled
    case hub
    /// Mounted from `skills.external_dirs`: externally authored, still editable in place.
    case external

    init(raw: Any?) {
        self = (LenientField.text(raw)?.lowercased()).flatMap(SkillProvenance.init(rawValue:)) ?? .agent
    }

    /// The source badge (`skills.provenance`, `catalogSourceFor`).
    var label: String {
        switch self {
        case .agent: return "Learned"
        case .bundled: return "Built-in"
        case .hub: return "Hub"
        case .external: return "External"
        }
    }

    /// Only learned and external skills are the user's to rewrite or archive (`isEditableProvenance`).
    var editable: Bool { self == .agent || self == .external }
}

/// One row of `GET /api/skills` (`SkillInfo`).
struct CapabilitySkill: Identifiable, Hashable {
    var name: String
    var description: String
    var category: String
    var enabled: Bool
    /// Observed activity (use + view + patch); 0 on older backends.
    var usage: Int
    var provenance: SkillProvenance

    var id: String { name }

    init(name: String, description: String = "", category: String = "general", enabled: Bool = true, usage: Int = 0,
         provenance: SkillProvenance = .agent) {
        self.name = name
        self.description = description
        self.category = category
        self.enabled = enabled
        self.usage = usage
        self.provenance = provenance
    }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        description = LenientField.text(row["description"]) ?? ""
        // `categoryFor`: blank → general.
        category = LenientField.text(row["category"]) ?? "general"
        enabled = LenientField.optionalBool(row["enabled"]) ?? true
        usage = max(0, LenientField.int(row["usage"]))
        provenance = SkillProvenance(raw: row["provenance"])
    }

    static func list(_ response: Any) -> [CapabilitySkill] {
        let rows = response as? [Any] ?? (response as? JSON)?["skills"] as? [Any] ?? []
        return rows.compactMap { ($0 as? JSON).flatMap(CapabilitySkill.init(row:)) }
    }

    /// The category heading (`catalogLabel`): `software-development` reads as "Software Development".
    var categoryLabel: String { CapabilitySearch.label(category) }
}

/// A skill's raw SKILL.md (`GET /api/skills/content`).
struct SkillDocument: Hashable {
    var name: String
    var content: String

    init(name: String, content: String) {
        self.name = name
        self.content = content
    }

    init(response: Any, name: String) {
        let row = response as? JSON ?? [:]
        self.name = LenientField.text(row["name"]) ?? name
        content = row["content"] as? String ?? ""
    }
}

/// The YAML block between a SKILL.md's leading `---` fences, flattened to top-level `key: value` rows, and the
/// body after it (`parseFrontmatter`). Display only: never sent back.
struct SkillFrontmatter: Hashable {
    var meta: [Field]
    var body: String

    struct Field: Hashable {
        var key: String
        var value: String
    }

    init(_ content: String) {
        let text = content.replacingOccurrences(of: "\r\n", with: "\n")
        // `^---\n(yaml)\n---\n?`: the first closing fence after the opening line.
        guard text.hasPrefix("---\n"),
              let close = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            meta = []
            body = content
            return
        }
        let open = text.index(text.startIndex, offsetBy: 4)
        let yaml = close.lowerBound > open ? text[open..<close.lowerBound] : ""
        var rest = text[close.upperBound...]
        if rest.first == "\n" { rest = rest.dropFirst() }
        var fields: [Field] = []
        var key: String?
        var block: [String] = []
        func flush() {
            if let key { fields.append(Field(key: key, value: block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
            key = nil
            block = []
        }
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            if let colon = line.firstIndex(of: ":"), let first = line.first, first.isLetter || first.isNumber || first == "_",
               line[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                flush()
                key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                block = value.isEmpty ? [] : [value]
            } else if key != nil {
                block.append(line.hasPrefix("  ") ? String(line.dropFirst(2)) : String(line))
            }
        }
        flush()
        meta = fields
        body = String(rest)
    }
}

// MARK: - Skills hub

/// One row of the built-in optional-skills catalog (`GET /api/skills/hub/official`, `OfficialSkillInfo`).
struct OfficialSkill: Identifiable, Hashable {
    var name: String
    var description: String
    var identifier: String
    var category: String
    var installed: Bool
    var tags: [String]

    var id: String { identifier }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        description = LenientField.text(row["description"]) ?? ""
        identifier = LenientField.text(row["identifier"]) ?? "official/\(name)"
        category = LenientField.text(row["category"]) ?? "general"
        installed = LenientField.bool(row["installed"])
        tags = LenientField.strings(row["tags"])
    }

    static func list(_ response: Any) -> [OfficialSkill] {
        ((response as? JSON)?["skills"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(OfficialSkill.init(row:)) }
    }

    var categoryLabel: String { CapabilitySearch.label(category) }
}

/// One hub search result (`SkillHubResult`).
struct HubSkill: Identifiable, Hashable {
    var name: String
    var description: String
    var source: String
    var identifier: String
    /// builtin / trusted / community.
    var trustLevel: String
    var repo: String?
    var tags: [String]

    var id: String { identifier }

    init(name: String, description: String = "", source: String = "", identifier: String, trustLevel: String = "community",
         repo: String? = nil, tags: [String] = []) {
        self.name = name
        self.description = description
        self.source = source
        self.identifier = identifier
        self.trustLevel = trustLevel
        self.repo = repo
        self.tags = tags
    }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        description = LenientField.text(row["description"]) ?? ""
        source = LenientField.text(row["source"]) ?? ""
        identifier = LenientField.text(row["identifier"]) ?? name
        trustLevel = LenientField.text(row["trust_level"]) ?? "community"
        repo = LenientField.text(row["repo"])
        tags = LenientField.strings(row["tags"])
    }

    init(official: OfficialSkill) {
        self.init(name: official.name, description: official.description, source: "official",
                  identifier: official.identifier, trustLevel: "builtin", tags: official.tags)
    }
}

/// `GET /api/skills/hub/search`.
struct HubSearchResponse: Hashable {
    var results: [HubSkill]
    /// Sources that didn't answer within the server's 30 s budget.
    var timedOut: [String]
    /// Hub identifiers already installed in the profile.
    var installed: Set<String>

    init(results: [HubSkill] = [], timedOut: [String] = [], installed: Set<String> = []) {
        self.results = results
        self.timedOut = timedOut
        self.installed = installed
    }

    init(response: Any) {
        let row = response as? JSON ?? [:]
        results = (row["results"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(HubSkill.init(row:)) }
        timedOut = LenientField.strings(row["timed_out"])
        installed = Set((row["installed"] as? JSON ?? [:]).keys)
    }
}

/// A hub skill's SKILL.md and file list, read without installing it (`GET /api/skills/hub/preview`).
struct HubSkillPreview: Hashable {
    var skill: HubSkill
    var skillMarkdown: String
    var files: [String]

    init(response: Any, identifier: String) {
        let row = response as? JSON ?? [:]
        skill = HubSkill(row: row) ?? HubSkill(name: identifier, identifier: identifier)
        skillMarkdown = row["skill_md"] as? String ?? ""
        files = LenientField.strings(row["files"])
    }
}

/// The install-time security scan of a hub skill, run without installing it (`GET /api/skills/hub/scan`).
struct HubSkillScan: Hashable {
    enum Policy: String { case allow, ask, block }

    struct Finding: Hashable {
        var severity: String
        var category: String
        var file: String
        var line: Int?
        var description: String
    }

    /// safe / caution / dangerous.
    var verdict: String
    var summary: String
    var policy: Policy
    var policyReason: String?
    var findings: [Finding]

    init(response: Any) {
        let row = response as? JSON ?? [:]
        verdict = LenientField.text(row["verdict"])?.lowercased() ?? "unknown"
        summary = LenientField.text(row["summary"]) ?? ""
        policy = LenientField.text(row["policy"]).flatMap(Policy.init(rawValue:)) ?? .ask
        policyReason = LenientField.text(row["policy_reason"])
        findings = (row["findings"] as? [Any] ?? []).compactMap { item in
            guard let item = item as? JSON else { return nil }
            return Finding(severity: LenientField.text(item["severity"]) ?? "low",
                           category: LenientField.text(item["category"]) ?? "",
                           file: LenientField.text(item["file"]) ?? "",
                           line: LenientField.optionalInt(item["line"]),
                           description: LenientField.text(item["description"]) ?? "")
        }
    }

    /// The verdict as the desktop words it.
    var verdictLabel: String {
        switch verdict {
        case "safe": return "Safe"
        case "caution": return "Caution"
        case "dangerous": return "Dangerous"
        default: return verdict.capitalized
        }
    }

    var policyLabel: String {
        switch policy {
        case .allow: return "Install allowed"
        case .ask: return "Review before installing"
        case .block: return "Install blocked by policy"
        }
    }
}

// MARK: - Routes

/// The skill routes for one profile.
struct SkillsAPI: CapabilityRoutes {
    let transport: CapabilitiesTransport
    let profile: String?

    init(transport: CapabilitiesTransport, profile: String?) {
        self.transport = transport
        self.profile = profile
    }

    /// The profile's installed skills, enabled flag, usage and provenance.
    func skills() async throws -> [CapabilitySkill] {
        CapabilitySkill.list(try await get("/api/skills"))
    }

    /// Turns one skill on or off for new sessions (`PUT /api/skills/toggle`).
    func setEnabled(_ name: String, _ enabled: Bool) async throws {
        _ = try await send("PUT", "/api/skills/toggle", Self.toggleBody(name, enabled))
    }

    static func toggleBody(_ name: String, _ enabled: Bool) -> JSON { ["name": name, "enabled": enabled] }

    func content(_ name: String) async throws -> SkillDocument {
        SkillDocument(response: try await get("/api/skills/content", ["name": name]), name: name)
    }

    /// Replaces a skill's whole SKILL.md (`PUT /api/skills/content`); Hermes checks the frontmatter.
    func saveContent(_ name: String, _ content: String) async throws {
        _ = try await send("PUT", "/api/skills/content", Self.contentBody(name, content))
    }

    static func contentBody(_ name: String, _ content: String) -> JSON { ["name": name, "content": content] }

    /// Creates a skill through the agent's own write path (`POST /api/skills`).
    func create(name: String, content: String, category: String?) async throws {
        _ = try await send("POST", "/api/skills", Self.createBody(name: name, content: content, category: category))
    }

    static func createBody(name: String, content: String, category: String?) -> JSON {
        var body: JSON = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines), "content": content]
        if let category = category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty { body["category"] = category }
        return body
    }

    /// Archives a learned skill (`DELETE /api/learning/node`); `hermes curator restore` brings it back.
    func archive(_ name: String) async throws {
        let result = try await send("DELETE", "/api/learning/node", ["id": name]) as? JSON ?? [:]
        if LenientField.optionalBool(result["ok"]) == false {
            throw DashboardError.rpc(LenientField.text(result["message"]) ?? "Hermes didn't archive \(name).")
        }
    }

    // MARK: Hub

    /// The host answers a hub search only once every source has answered (its own budget is 30 s, after building
    /// the source router), and a preview or scan once the bundle is fetched, quarantined and scanned; the desktop
    /// waits 45 s for these (`HUB_REQUEST_TIMEOUT_MS`).
    static let hubTimeout: TimeInterval = 60

    func official() async throws -> [OfficialSkill] {
        OfficialSkill.list(try await get("/api/skills/hub/official"))
    }

    func search(_ query: String, limit: Int = 20) async throws -> HubSearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return HubSearchResponse() }
        return HubSearchResponse(response: try await get("/api/skills/hub/search", ["q": query, "source": "all", "limit": "\(limit)"],
                                                         timeout: Self.hubTimeout))
    }

    func preview(_ identifier: String) async throws -> HubSkillPreview {
        HubSkillPreview(response: try await get("/api/skills/hub/preview", ["identifier": identifier], timeout: Self.hubTimeout),
                        identifier: identifier)
    }

    func scan(_ identifier: String) async throws -> HubSkillScan {
        HubSkillScan(response: try await get("/api/skills/hub/scan", ["identifier": identifier], timeout: Self.hubTimeout))
    }

    /// Spawns `hermes skills install <identifier> --yes`; follow its log with `CapabilityActionsAPI`.
    func install(_ identifier: String) async throws -> CapabilityAction {
        CapabilityAction(response: try await send("POST", "/api/skills/hub/install", ["identifier": identifier]), fallbackName: "skills-install")
    }

    func uninstall(_ name: String) async throws -> CapabilityAction {
        CapabilityAction(response: try await send("POST", "/api/skills/hub/uninstall", ["name": name]), fallbackName: "skills-uninstall")
    }

    /// `hermes skills update`: every hub-installed skill to its source's latest.
    func updateAll() async throws -> CapabilityAction {
        CapabilityAction(response: try await send("POST", "/api/skills/hub/update", [:]), fallbackName: "skills-update")
    }
}

// MARK: - Search

/// The Capabilities search (`normalize` + `includesQuery`): trimmed, case-insensitive substring over a row's fields.
enum CapabilitySearch {
    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let query = normalize(query)
        return query.isEmpty || fields.contains { $0.lowercased().contains(query) }
    }

    /// `catalogLabel`: domains stay verbatim (`browse.sh`), slugs read as words.
    static func label(_ value: String) -> String {
        guard !value.contains(".") else { return value }
        let words = value.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { word in word.prefix(1).uppercased() + word.dropFirst() }
        return words.joined(separator: " ")
    }

    /// Installed skills matching `query` (name, description, category), most used first, then A–Z
    /// (`filteredSkills`, descending).
    static func skills(_ skills: [CapabilitySkill], query: String) -> [CapabilitySkill] {
        skills.filter { matches(query, [$0.name, $0.description, $0.category]) }
            .sorted { $0.usage != $1.usage ? $0.usage > $1.usage : $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Catalog rows matching `query` (name, description, category, tags), A–Z (`filteredOfficial`).
    static func official(_ skills: [OfficialSkill], query: String) -> [OfficialSkill] {
        skills.filter { matches(query, [$0.name, $0.description, $0.category] + $0.tags) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// The user's busiest categories, for the search prompt's "Try …" nudges (`skillSearchTerms`).
    static func skillHints(_ skills: [CapabilitySkill]) -> [String] {
        var counts: [String: Int] = [:]
        for skill in skills { counts[skill.category, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(5).map { $0.key.lowercased() }
    }
}
