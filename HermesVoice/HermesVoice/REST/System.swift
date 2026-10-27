import Foundation

// The Command Center's routes: status and stats (`web_routers/status.py`), logs (`/api/logs`), usage
// (`web_routers/analytics.py`), and the maintenance actions (`web_routers/ops.py`, `actions.py`), whose long-running
// ones are spawned on the host and tailed through `GET /api/actions/{name}/status`.

/// `GET /api/status`: version, gateway state and health. Host paths and PIDs only come on an unauthenticated bind,
/// so nothing here relies on them.
struct HermesStatus: Hashable {
    struct Platform: Hashable, Identifiable {
        var name: String
        var state: String
        var errorMessage: String?
        var id: String { name }
    }

    struct Component: Hashable, Identifiable {
        var name: String
        var status: String
        var id: String { name }
        var isOK: Bool { status == "ok" }
    }

    var version = ""
    var releaseDate = ""
    var configVersion: Int?
    var latestConfigVersion: Int?
    var canUpdateHermes = true
    var gatewayRunning = false
    var gatewayState: String?
    var gatewayExitReason: String?
    /// Seconds since the gateway's heartbeat while its process is alive but the heartbeat is stale.
    var gatewayHeartbeatStale: Double?
    /// Every profile the shared multiplexer serves, when the polled profile runs in it: restarting restarts them all.
    var sharedWith: [String]?
    var platforms: [Platform] = []
    var activeSessions = 0
    var activeAgents = 0
    var gatewayBusy = false
    /// "ok" or "degraded".
    var overall: String?
    var components: [Component] = []

    init() {}

    init(response: JSON) {
        version = LenientField.text(response["version"]) ?? ""
        releaseDate = LenientField.text(response["release_date"]) ?? ""
        configVersion = LenientField.optionalInt(response["config_version"])
        latestConfigVersion = LenientField.optionalInt(response["latest_config_version"])
        canUpdateHermes = LenientField.optionalBool(response["can_update_hermes"]) ?? true
        gatewayRunning = LenientField.bool(response["gateway_running"])
        gatewayState = LenientField.text(response["gateway_state"])
        gatewayExitReason = LenientField.text(response["gateway_exit_reason"])
        gatewayHeartbeatStale = (response["gateway_heartbeat_stale_s"] as? NSNumber)?.doubleValue
        sharedWith = Self.sharedProfiles(response["gateway_shared_with"])
        platforms = (response["gateway_platforms"] as? JSON ?? [:]).compactMap { name, value in
            guard let row = value as? JSON else { return nil }
            return Platform(name: name, state: LenientField.text(row["state"]) ?? LenientField.text(row["status"]) ?? "unknown",
                            errorMessage: LenientField.text(row["error_message"]))
        }
        .sorted { $0.name < $1.name }
        activeSessions = max(0, LenientField.int(response["active_sessions"]))
        activeAgents = max(0, LenientField.int(response["active_agents"]))
        gatewayBusy = LenientField.bool(response["gateway_busy"])
        overall = LenientField.text(response["overall"])
        components = (response["components"] as? JSON ?? [:]).compactMap { name, value in
            guard let row = value as? JSON, let status = LenientField.text(row["status"]) else { return nil }
            return Component(name: name, status: status)
        }
        .sorted { $0.name < $1.name }
    }

    /// The shared gateway's profiles, or nil for a gateway of its own (fewer than two names; `sharedGatewayProfiles`).
    static func sharedProfiles(_ value: Any?) -> [String]? {
        guard let list = value as? [Any] else { return nil }
        var seen = Set<String>()
        let names = list.compactMap { DashboardClient.string($0)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return names.count < 2 ? nil : names
    }
}

/// `GET /api/system/stats`: the host's identity and, with psutil, CPU, memory, disk and uptime.
struct SystemStats: Hashable {
    struct Usage: Hashable {
        var total: Double
        var used: Double
        var percent: Double
    }

    var os: String?
    var arch: String?
    var hostname: String?
    var pythonVersion: String?
    var hermesVersion: String?
    var cpuCount: Int?
    var cpuPercent: Double?
    var loadAverage: [Double] = []
    var memory: Usage?
    var disk: Usage?
    var uptime: TimeInterval?
    var processRSS: Double?

    init(response: JSON) {
        // `_display_system_platform`: "Linux" + "6.8.0", else the platform label.
        os = LenientField.text(response["os"])
            .map { [$0, LenientField.text(response["os_release"])].compactMap { $0 }.joined(separator: " ") }
            ?? LenientField.text(response["platform"])
        arch = LenientField.text(response["arch"])
        hostname = LenientField.text(response["hostname"])
        pythonVersion = LenientField.text(response["python_version"])
        hermesVersion = LenientField.text(response["hermes_version"])
        cpuCount = LenientField.optionalInt(response["cpu_count"])
        cpuPercent = (response["cpu_percent"] as? NSNumber)?.doubleValue
        loadAverage = (response["load_avg"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        memory = Self.usage(response["memory"])
        disk = Self.usage(response["disk"])
        uptime = (response["uptime_seconds"] as? NSNumber)?.doubleValue
        processRSS = ((response["process"] as? JSON)?["rss"] as? NSNumber)?.doubleValue
    }

    private static func usage(_ value: Any?) -> Usage? {
        guard let row = value as? JSON, let total = (row["total"] as? NSNumber)?.doubleValue, total > 0 else { return nil }
        let used = (row["used"] as? NSNumber)?.doubleValue ?? 0
        let percent = (row["percent"] as? NSNumber)?.doubleValue ?? used / total * 100
        return Usage(total: total, used: used, percent: percent)
    }
}

/// The log viewer's choices (`LOG_FILES`, `LOG_LEVELS`). The desktop's own `desktop` log lives with the desktop
/// app, not on the host, so it isn't offered.
enum LogFile: String, CaseIterable, Identifiable {
    case agent, errors, gateway
    var id: String { rawValue }
}

enum LogLevel: String, CaseIterable, Identifiable {
    case all = "ALL", info = "INFO", warning = "WARNING", error = "ERROR"
    var id: String { rawValue }
    var label: String { self == .all ? "all" : rawValue.lowercased() }
}

/// A log search: which lines match, case-insensitively (the desktop's `useLogSearch`).
struct LogSearch: Hashable {
    var query: String

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func matches(_ line: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || line.localizedCaseInsensitiveContains(needle)
    }

    func filter(_ lines: [String]) -> [String] {
        isActive ? lines.filter(matches) : lines
    }
}

/// `GET /api/analytics/usage?days=`: sessions, tokens and cost over a period, per day and per model, and skill use.
struct UsageAnalytics: Hashable {
    struct Day: Hashable, Identifiable {
        var day: String
        var inputTokens: Int
        var outputTokens: Int
        var sessions: Int
        var apiCalls: Int
        var estimatedCost: Double
        var actualCost: Double
        var id: String { day }
        var tokens: Int { inputTokens + outputTokens }
    }

    struct Model: Hashable, Identifiable {
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var sessions: Int
        var apiCalls: Int
        var estimatedCost: Double
        var id: String { model }
        var tokens: Int { inputTokens + outputTokens }
    }

    struct Skill: Hashable, Identifiable {
        var skill: String
        var totalCount: Int
        var id: String { skill }
    }

    struct Totals: Hashable {
        var sessions = 0
        var apiCalls = 0
        var input = 0
        var output = 0
        var estimatedCost: Double = 0
        var actualCost: Double = 0
    }

    var periodDays: Int
    var daily: [Day]
    var byModel: [Model]
    var topSkills: [Skill]
    /// Nil when the backend sent none (no usage to show).
    var totals: Totals?

    init(response: JSON, days: Int) {
        periodDays = LenientField.optionalInt(response["period_days"]) ?? days
        daily = (response["daily"] as? [JSON] ?? []).compactMap { row in
            guard let day = LenientField.text(row["day"]) else { return nil }
            return Day(day: day, inputTokens: LenientField.int(row["input_tokens"]),
                       outputTokens: LenientField.int(row["output_tokens"]), sessions: LenientField.int(row["sessions"]),
                       apiCalls: LenientField.int(row["api_calls"]), estimatedCost: Self.number(row["estimated_cost"]),
                       actualCost: Self.number(row["actual_cost"]))
        }
        byModel = (response["by_model"] as? [JSON] ?? []).compactMap { row in
            guard let model = LenientField.text(row["model"]) else { return nil }
            return Model(model: model, inputTokens: LenientField.int(row["input_tokens"]),
                         outputTokens: LenientField.int(row["output_tokens"]), sessions: LenientField.int(row["sessions"]),
                         apiCalls: LenientField.int(row["api_calls"]), estimatedCost: Self.number(row["estimated_cost"]))
        }
        topSkills = ((response["skills"] as? JSON)?["top_skills"] as? [JSON] ?? []).compactMap { row in
            guard let skill = LenientField.text(row["skill"]) else { return nil }
            return Skill(skill: skill, totalCount: LenientField.int(row["total_count"]))
        }
        if let row = response["totals"] as? JSON {
            totals = Totals(sessions: LenientField.int(row["total_sessions"]), apiCalls: LenientField.int(row["total_api_calls"]),
                            input: LenientField.int(row["total_input"]), output: LenientField.int(row["total_output"]),
                            estimatedCost: Self.number(row["total_estimated_cost"]),
                            actualCost: Self.number(row["total_actual_cost"]))
        }
    }

    /// The tallest day's tokens, for the chart's scale (at least 1).
    var maxDailyTokens: Int { max(1, daily.map(\.tokens).max() ?? 0) }

    private static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
}

/// What a spawned action answered when it started (`ActionResponse`). A refused update answers `ok: false` with the
/// reason.
struct OpsActionStart: Hashable {
    var name: String
    var ok: Bool
    var pid: Int?
    var alreadyRunning = false
    var message: String?
    /// `POST /api/ops/backup`: where the archive is being written on the host.
    var archive: String?

    init(response: JSON, fallbackName: String) {
        name = LenientField.text(response["name"]) ?? fallbackName
        ok = LenientField.optionalBool(response["ok"]) ?? true
        pid = LenientField.optionalInt(response["pid"])
        alreadyRunning = LenientField.bool(response["already_running"])
        message = LenientField.text(response["message"]) ?? LenientField.text(response["error"])
        archive = LenientField.text(response["archive"])
    }
}

/// `GET /api/actions/{name}/status`: whether the spawned action still runs, its exit code and the log tail.
struct OpsActionStatus: Hashable {
    var name: String
    var running: Bool
    var exitCode: Int?
    var lines: [String]
    /// `hermes-update` only: the durable update receipt's outcome ("success", "partial", "failed", …).
    var receiptOutcome: String?

    init(name: String, running: Bool, exitCode: Int? = nil, lines: [String] = []) {
        self.name = name
        self.running = running
        self.exitCode = exitCode
        self.lines = lines
    }

    init(response: JSON, fallbackName: String) {
        name = LenientField.text(response["name"]) ?? fallbackName
        running = LenientField.bool(response["running"])
        exitCode = LenientField.optionalInt(response["exit_code"])
        lines = (response["lines"] as? [Any] ?? []).compactMap { $0 as? String }
        receiptOutcome = LenientField.text((response["receipt"] as? JSON)?["outcome"])
    }

    enum Outcome: Equatable { case running, done, failed }

    /// Running, done (exit 0) or failed (`actionRunning` / `actionDone` / `actionFailed`).
    var outcome: Outcome {
        if running { return .running }
        if let receiptOutcome { return receiptOutcome == "success" ? .done : .failed }
        return exitCode == 0 ? .done : .failed
    }

    var outcomeLabel: String {
        switch outcome {
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// The polling of one spawned action: every 1.2 s until it stops running or the poll budget runs out (the desktop's
/// `ACTION_POLL_MS` / `ACTION_POLL_LIMIT`, ~5 minutes; a gateway restart or update polls 18 times). A failed status
/// read is tolerated a few times in a row, since an update restarts the dashboard under the poll.
struct OpsActionPoll: Equatable {
    static let interval: TimeInterval = 1.2

    enum Step: Equatable {
        /// Ask again after `interval`.
        case wait
        /// The action finished (or the budget ran out while it still runs).
        case finished
        /// Status reads kept failing; stop tailing.
        case gaveUp
    }

    let limit: Int
    var maxConsecutiveFailures = 5
    private(set) var polls = 0
    private(set) var failures = 0
    private(set) var latest: OpsActionStatus?

    init(limit: Int = 240, maxConsecutiveFailures: Int = 5) {
        self.limit = limit
        self.maxConsecutiveFailures = maxConsecutiveFailures
    }

    /// Records a status read.
    mutating func record(_ status: OpsActionStatus) -> Step {
        polls += 1
        failures = 0
        latest = status
        return status.running && polls < limit ? .wait : .finished
    }

    /// Records a failed status read.
    mutating func recordFailure() -> Step {
        polls += 1
        failures += 1
        if failures >= maxConsecutiveFailures { return .gaveUp }
        return polls < limit ? .wait : .gaveUp
    }
}

/// `GET /api/curator`: the background skill curator.
struct CuratorStatus: Hashable {
    var enabled: Bool
    var paused: Bool
    var lastRunAt: String?
    var intervalHours: Double?

    init(response: JSON) {
        enabled = LenientField.optionalBool(response["enabled"]) ?? true
        paused = LenientField.bool(response["paused"])
        lastRunAt = LenientField.text(response["last_run_at"])
        intervalHours = (response["interval_hours"] as? NSNumber)?.doubleValue
    }

    var stateLabel: String { !enabled ? "Disabled" : paused ? "Paused" : "Active" }
}

/// `GET /api/memory`: the active memory provider and the built-in memory files' sizes.
struct MemoryStatus: Hashable {
    var active: String?
    var memoryBytes: Int
    var userBytes: Int

    init(response: JSON) {
        active = LenientField.text(response["active"])
        let files = response["builtin_files"] as? JSON ?? [:]
        memoryBytes = max(0, LenientField.int(files["memory"]))
        userBytes = max(0, LenientField.int(files["user"]))
    }
}

/// `POST /api/ops/debug-share`: the paste links of the uploaded, redacted report and logs.
struct DebugShareResult: Hashable {
    var urls: [(key: String, url: String)]
    var failures: [(key: String, reason: String)]
    var redacted: Bool
    var autoDeleteSeconds: Int?

    init(response: JSON) {
        urls = (response["urls"] as? JSON ?? [:]).compactMap { key, value in (value as? String).map { (key, $0) } }
            .sorted { $0.key < $1.key }
        failures = (response["failures"] as? JSON ?? [:]).compactMap { key, value in (value as? String).map { (key, $0) } }
            .sorted { $0.key < $1.key }
        redacted = LenientField.optionalBool(response["redacted"]) ?? true
        autoDeleteSeconds = LenientField.optionalInt(response["auto_delete_seconds"])
    }

    static func == (lhs: DebugShareResult, rhs: DebugShareResult) -> Bool {
        lhs.urls.map(\.key) == rhs.urls.map(\.key) && lhs.urls.map(\.url) == rhs.urls.map(\.url)
            && lhs.failures.map(\.key) == rhs.failures.map(\.key) && lhs.redacted == rhs.redacted
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(urls.map(\.url))
    }
}

/// `GET /api/hermes/update/check`: whether the host's Hermes can update, and how.
struct UpdateCheck: Hashable {
    struct Commit: Hashable, Identifiable {
        var sha: String
        var summary: String
        var id: String { sha }
    }

    var installMethod: String
    var currentVersion: String
    /// Commits behind: 0 up to date, -1 an unknown count, nil when the check couldn't run.
    var behind: Int?
    var updateAvailable: Bool
    /// The dashboard can apply it in place (git installs).
    var canApply: Bool
    var updateCommand: String?
    var message: String?
    var rollbackTo: String?
    var commits: [Commit]

    init(response: JSON) {
        installMethod = LenientField.text(response["install_method"]) ?? "unknown"
        currentVersion = LenientField.text(response["current_version"]) ?? ""
        behind = LenientField.optionalInt(response["behind"])
        updateAvailable = LenientField.bool(response["update_available"])
        canApply = LenientField.bool(response["can_apply"])
        updateCommand = LenientField.text(response["update_command"])
        message = LenientField.text(response["message"])
        rollbackTo = LenientField.text(response["rollback_to"])
        commits = (response["commits"] as? [JSON] ?? []).compactMap { row in
            guard let sha = LenientField.text(row["sha"]) else { return nil }
            return Commit(sha: sha, summary: LenientField.text(row["summary"]) ?? "")
        }
    }

    /// The one line under the version: the host's own message, else the behind count.
    var summary: String {
        if let message { return message }
        switch behind {
        case nil: return "Couldn't check for updates."
        case 0?: return "You're on the latest version."
        case let count? where count > 0: return "\(count) \(count == 1 ? "commit" : "commits") behind."
        default: return "An update is available."
        }
    }
}

/// `GET /api/ops/checkpoints`: the `/rollback` shadow-store, which a prune reclaims.
struct CheckpointsSummary: Hashable {
    var sessions: Int
    var totalBytes: Int

    init(response: JSON) {
        sessions = (response["sessions"] as? [Any])?.count ?? 0
        totalBytes = max(0, LenientField.int(response["total_bytes"]))
    }
}

/// Byte sizes as the desktop prints them (`formatBytes`): "" for nothing, then B, KB, MB, GB.
enum ByteSize {
    static func format(_ size: Double) -> String {
        guard size > 0 else { return "" }
        if size >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", size / (1024 * 1024 * 1024)) }
        if size >= 1024 * 1024 { return String(format: "%.1f MB", size / (1024 * 1024)) }
        if size >= 1024 { return String(format: "%.1f KB", size / 1024) }
        return "\(Int(size)) B"
    }
}

/// Counts as the desktop's `compactNumber` prints them: 950, 1.2K, 3.4M, 1.1B.
enum CompactNumber {
    static func format(_ value: Int) -> String {
        let magnitude = abs(Double(value))
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let number = Double(value) / divisor
            let text = abs(number) >= 100 ? String(format: "%.0f", number) : String(format: "%.1f", number)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        if magnitude >= 1e9 { return scaled(1e9, "B") }
        if magnitude >= 1e6 { return scaled(1e6, "M") }
        if magnitude >= 1e3 { return scaled(1e3, "K") }
        return "\(value)"
    }
}

/// Dollar amounts: two decimals, four under a cent.
enum Cost {
    static func format(_ value: Double) -> String {
        guard value > 0 else { return "$0.00" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}

extension DashboardClient {
    // MARK: Status, stats, logs, usage

    /// `profile` nil reads the dashboard's own profile.
    func hermesStatus(profile: String?) async throws -> HermesStatus {
        HermesStatus(response: try await request("GET", "/api/status", query: Self.profileQuery(profile)) as? JSON ?? [:])
    }

    func systemStats() async throws -> SystemStats {
        SystemStats(response: try await request("GET", "/api/system/stats") as? JSON ?? [:])
    }

    func logLines(file: LogFile, level: LogLevel, lines: Int = 200, profile: String?) async throws -> [String] {
        let query = Self.logsQuery(file: file, level: level, lines: lines, profile: profile)
        let result = try await request("GET", "/api/logs", query: query) as? JSON
        return (result?["lines"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    static func logsQuery(file: LogFile, level: LogLevel, lines: Int, profile: String?) -> [String: String] {
        var query = ["file": file.rawValue, "lines": String(max(1, min(lines, 500)))]
        if level != .all { query["level"] = level.rawValue }
        return query.merging(profileQuery(profile)) { _, new in new }
    }

    func usageAnalytics(days: Int, profile: String?) async throws -> UsageAnalytics {
        let days = max(1, min(days, 365))
        let query = ["days": String(days)].merging(Self.profileQuery(profile)) { _, new in new }
        return UsageAnalytics(response: try await request("GET", "/api/analytics/usage", query: query) as? JSON ?? [:],
                              days: days)
    }

    // MARK: Actions

    /// Starts a spawned action (`POST` to `path`) and names it for the status poll.
    func startOpsAction(_ path: String, name: String, profile: String?, body: JSON = [:]) async throws -> OpsActionStart {
        let result = try await request("POST", path, query: Self.profileQuery(profile), body: body) as? JSON ?? [:]
        return OpsActionStart(response: result, fallbackName: name)
    }

    func opsActionStatus(_ name: String, lines: Int = 200) async throws -> OpsActionStatus {
        let path = "/api/actions/\(try Self.segment(name))/status"
        let result = try await request("GET", path, query: ["lines": String(max(1, lines))]) as? JSON ?? [:]
        return OpsActionStatus(response: result, fallbackName: name)
    }

    func restartGateway(profile: String?) async throws -> OpsActionStart {
        try await startOpsAction("/api/gateway/restart", name: "gateway-restart", profile: profile)
    }

    func updateHermes() async throws -> OpsActionStart {
        try await startOpsAction("/api/hermes/update", name: "hermes-update", profile: nil)
    }

    /// `force` skips the host's 24-hour cache.
    func checkHermesUpdate(force: Bool, profile: String?) async throws -> UpdateCheck {
        var query = Self.profileQuery(profile)
        if force { query["force"] = "true" }
        return UpdateCheck(response: try await request("GET", "/api/hermes/update/check", query: query) as? JSON ?? [:])
    }

    // MARK: Maintenance

    func curatorStatus(profile: String?) async throws -> CuratorStatus {
        CuratorStatus(response: try await request("GET", "/api/curator", query: Self.profileQuery(profile)) as? JSON ?? [:])
    }

    func setCuratorPaused(_ paused: Bool, profile: String?) async throws {
        _ = try await request("PUT", "/api/curator/paused", query: Self.profileQuery(profile), body: ["paused": paused])
    }

    func memoryStatus(profile: String?) async throws -> MemoryStatus {
        MemoryStatus(response: try await request("GET", "/api/memory", query: Self.profileQuery(profile)) as? JSON ?? [:])
    }

    /// Deletes MEMORY.md ("memory"), USER.md ("user") or both ("all"). Returns the deleted files' names.
    func resetMemory(_ target: String, profile: String) async throws -> [String] {
        let result = try await request("POST", "/api/memory/reset", query: ["profile": profile], body: ["target": target]) as? JSON
        return LenientField.strings(result?["deleted"])
    }

    func checkpoints(profile: String?) async throws -> CheckpointsSummary {
        CheckpointsSummary(response: try await request("GET", "/api/ops/checkpoints", query: Self.profileQuery(profile)) as? JSON ?? [:])
    }

    /// Uploads a redacted report and the logs to the paste service and returns the links. Synchronous on the host.
    func debugShare(profile: String?) async throws -> DebugShareResult {
        let result = try await opsRequest("POST", "/api/ops/debug-share", query: Self.profileQuery(profile),
                                          body: ["redact": true], timeout: 180) as? JSON
        return DebugShareResult(response: result ?? [:])
    }

    /// The finished backup archive, written to a temporary file to share. The archive holds the profile's config and
    /// credentials, so the caller deletes the file once the share sheet closes.
    func downloadBackup(archive: String, profile: String?) async throws -> URL {
        let query = ["archive": archive].merging(Self.profileQuery(profile)) { _, new in new }
        let data = try await opsData("/api/ops/backup/download", query: query, timeout: 600)
        let name = (archive as NSString).lastPathComponent
        return try Self.temporaryFile(data, name: name.isEmpty ? "hermes-backup.zip" : name)
    }

    // MARK: Transport

    /// Like `request`, with a longer wait for routes the host answers only when the work is done.
    func opsRequest(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil,
                    timeout: TimeInterval) async throws -> Any {
        let data = try await opsSend(method, path, query: query, body: body, timeout: timeout)
        return data.isEmpty ? JSON() : try JSONSerialization.jsonObject(with: data)
    }

    /// The raw bytes of a GET (a download), signing in once if the cookie is gone.
    func opsData(_ path: String, query: [String: String] = [:], timeout: TimeInterval = 120) async throws -> Data {
        try await opsSend("GET", path, query: query, body: nil, timeout: timeout)
    }

    private func opsSend(_ method: String, _ path: String, query: [String: String], body: JSON?,
                         timeout: TimeInterval) async throws -> Data {
        for attempt in 0..<2 {
            var request = URLRequest(url: url(path, query: query))
            request.httpMethod = method
            request.timeoutInterval = timeout
            if method != "GET" { request.setValue(Self.origin(of: base), forHTTPHeaderField: "Origin") }
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let redirectedAway = http?.url.map { $0.host != base.host || $0.path.contains("login") } ?? false
            if code == 401 || code == 403 || redirectedAway {
                if attempt == 0 { try await signIn(); continue }
                throw DashboardError.signedOut
            }
            guard (200..<300).contains(code) else { throw DashboardError.http(code, String(decoding: data, as: UTF8.self)) }
            return data
        }
        throw DashboardError.signedOut
    }

    static func origin(of base: URL) -> String {
        var value = "\(base.scheme ?? "https")://\(base.host ?? "")"
        if let port = base.port { value += ":\(port)" }
        return value
    }

    /// Writes `data` to a fresh temporary folder under `name` (path components stripped).
    static func temporaryFile(_ data: Data, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var safe = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        if safe.isEmpty || safe == "." || safe == ".." { safe = "file" }
        let url = folder.appendingPathComponent(safe)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// Removes a file `temporaryFile` wrote, with its folder.
    static func removeTemporaryFile(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix("hermes-share-") else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

extension Error {
    /// The request ran out of time waiting for an answer (the work may still be going on the host).
    var isTimeout: Bool {
        if case .timeout? = self as? DashboardError { return true }
        return (self as? URLError)?.code == .timedOut
    }
}
