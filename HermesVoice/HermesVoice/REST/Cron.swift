import Foundation

/// A scheduled job as `GET /api/cron/jobs` lists it (`CronJob` in the desktop's `types/hermes.ts`), stamped with the
/// profile whose store holds it (`web_server_cron._annotate_cron_job`). Rows decode leniently.
struct CronJob: Identifiable, Hashable {
    let id: String
    /// Trimmed; nil when unnamed.
    var name: String?
    /// As stored (the editor round-trips it).
    var prompt = ""
    var script: String?
    var noAgent = false
    var enabled = true
    /// The stored state ("scheduled", "paused", "running", "error", "completed", …); nil when the row has none.
    var state: String?
    var scheduleExpr: String?
    var scheduleDisplay: String?
    /// Comma-separated delivery targets; nil reads as "local".
    var deliver: String?
    var model: String?
    var provider: String?
    var lastRunAt: String?
    var nextRunAt: String?
    var lastError: String?
    var profile: String?

    init(id: String, name: String? = nil, prompt: String = "", state: String? = nil, profile: String? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.state = state
        self.profile = profile
    }

    init?(row: JSON) {
        guard let id = (row["id"] ?? row["job_id"]).flatMap(DashboardClient.string), !id.isEmpty else { return nil }
        self.id = id
        name = LenientField.text(row["name"])
        prompt = row["prompt"] as? String ?? ""
        script = row["script"] as? String
        noAgent = LenientField.bool(row["no_agent"])
        enabled = LenientField.optionalBool(row["enabled"]) ?? true
        state = LenientField.text(row["state"])
        let schedule = row["schedule"] as? JSON
        scheduleExpr = LenientField.text(schedule?["expr"])
        scheduleDisplay = LenientField.text(row["schedule_display"]) ?? LenientField.text(schedule?["display"])
        deliver = LenientField.text(row["deliver"])
        model = LenientField.text(row["model"])
        provider = LenientField.text(row["provider"])
        lastRunAt = LenientField.text(row["last_run_at"])
        nextRunAt = LenientField.text(row["next_run_at"])
        lastError = LenientField.text(row["last_error"])
        profile = LenientField.text(row["profile"]) ?? LenientField.text(row["profile_name"])
    }

    /// The explicit state, else one inferred from `enabled` (`jobState`).
    var effectiveState: String { state ?? (enabled ? "scheduled" : "disabled") }
    var isPaused: Bool { effectiveState == "paused" }

    /// Name, else the first 60 characters of the prompt, else of the script, else the id (`jobTitle`).
    var title: String {
        if let name { return name }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { return CronText.truncate(prompt, 60) }
        let script = (script ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !script.isEmpty { return CronText.truncate(script, 60) }
        return id
    }

    /// Runs a shell script with no agent prompt (`jobIsScriptOnly`).
    var isScriptOnly: Bool { noAgent && !(script ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// The prompt, or the script for a script-only job (`jobDescription`).
    var descriptionText: String { prompt.isEmpty ? (script ?? "") : prompt }
    /// What the schedule reads as (`jobScheduleDisplay`).
    var scheduleLabel: String { scheduleDisplay ?? scheduleExpr ?? "—" }
    /// The expression the editor starts from (`jobScheduleExpr`).
    var editableSchedule: String { scheduleExpr ?? scheduleDisplay ?? "" }
    var deliverValue: String { deliver ?? CronDelivery.local }

    /// How long the stored next run has sat in the past beyond the scheduler's grace, or nil while it is upcoming,
    /// within grace, unparseable, or the job isn't expected to fire (`nextRunOverdueMs`). A slot parked in the past
    /// is the only visible trace of a scheduler that stopped ticking.
    func overdue(now: Date = Date()) -> TimeInterval? {
        guard !["paused", "completed", "disabled"].contains(effectiveState), let nextRunAt,
              let at = CronTime.date(nextRunAt) else { return nil }
        let overdue = now.timeIntervalSince(at)
        return overdue > CronTime.overdueGrace ? overdue : nil
    }

    /// Search over title, prompt, schedule and delivery (`matchesQuery`).
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return [title, prompt, scheduleLabel, editableSchedule, deliverValue].contains { $0.lowercased().contains(needle) }
    }
}

/// One row of a job's run history (`GET /api/cron/jobs/{id}/runs`): an agent run's session (`source: "cron"`), or a
/// script-only fire's output document (`source: "cron_output"`), which has no session to open.
struct CronRun: Identifiable, Hashable {
    let id: String
    var title: String?
    var preview: String?
    var source: String?
    var startedAt: Date?
    var lastActive: Date?
    var endedAt: Date?
    /// The scheduler still holds the run's execution (newer backends).
    var schedulerOwned: Bool?
    var isActive: Bool?
    var profile: String?

    init?(row: JSON) {
        let started = row["started_at"].flatMap(DashboardClient.date)
        guard let id = (row["id"] ?? row["session_id"]).flatMap(DashboardClient.string)
            ?? started.map({ "run-\(Int($0.timeIntervalSince1970))" }) else { return nil }
        self.id = id
        title = LenientField.text(row["title"])
        preview = LenientField.text(row["preview"])
        source = LenientField.text(row["source"])
        startedAt = started
        lastActive = row["last_active"].flatMap(DashboardClient.date)
        endedAt = row["ended_at"].flatMap(DashboardClient.date)
        schedulerOwned = LenientField.optionalBool(row["scheduler_owned"])
        isActive = LenientField.optionalBool(row["is_active"])
        profile = LenientField.text(row["profile"])
    }

    var label: String { title ?? preview ?? id }
    /// When the run last did something, else when it started.
    var time: Date? { lastActive ?? startedAt }
    /// A session the scheduler wrote, which opens as a chat (`isCronRunRow`).
    var hasSession: Bool { source == "cron" }

    /// The run is live (the scheduler owns it) or was closed properly, so writing into it is safe; a run that never
    /// got its `end_session` and nobody owns is a zombie, view-only (`isResumableCronRun`). Older backends without
    /// `scheduler_owned` fall back to the five-minute activity window.
    func isResumable(now: Date = Date()) -> Bool {
        if endedAt != nil { return true }
        if let schedulerOwned { return schedulerOwned }
        if let isActive { return isActive }
        guard let lastActive else { return false }
        return now.timeIntervalSince(lastActive) < 300
    }

    /// The run a trigger at `requestedAt` produced: one that started after the click, allowing for clock skew
    /// between phone and host (`PENDING_RUN_START_SLACK_MS`).
    static func settles(_ runs: [CronRun], triggeredAt requestedAt: Date) -> Bool {
        runs.contains { run in
            guard let started = run.startedAt ?? run.lastActive else { return false }
            return started >= requestedAt.addingTimeInterval(-CronTime.pendingRunSlack)
        }
    }
}

/// Where a job can deliver (`GET /api/cron/delivery-targets`): "local" plus the configured gateway platforms. A
/// platform without a home channel is listed with `homeTargetSet` false.
struct CronDeliveryTarget: Identifiable, Hashable {
    let id: String
    var name: String
    var homeTargetSet = true
    var homeEnvVar: String?

    init(id: String, name: String, homeTargetSet: Bool = true) {
        self.id = id
        self.name = name
        self.homeTargetSet = homeTargetSet
    }

    init?(row: JSON) {
        guard let id = LenientField.text(row["id"]) else { return nil }
        self.id = id
        name = LenientField.text(row["name"]) ?? id
        homeTargetSet = LenientField.optionalBool(row["home_target_set"]) ?? true
        homeEnvVar = LenientField.text(row["home_env_var"])
    }

    /// "Local (save only)" for the host itself, known platforms by name, else what Hermes calls it; a platform
    /// without a home channel says so (`deliverTargetLabel`).
    var label: String {
        let base = CronDelivery.label(id, fallback: name)
        return id != CronDelivery.local && !homeTargetSet ? "\(base) — set a home channel first" : base
    }
}

/// A ready-made automation (`AutomationBlueprint`, `cron/blueprint_catalog.py`): typed slots the backend turns into
/// a prompt and schedule.
struct CronBlueprint: Identifiable, Hashable {
    struct Field: Identifiable, Hashable {
        enum Kind: String { case text, time, `enum`, weekdays }

        var name: String
        var kind: Kind
        var label: String
        var defaultValue: String?
        var options: [String]
        var optional: Bool
        /// When false the options are suggestions and any value is accepted.
        var strict: Bool
        var help: String

        var id: String { name }

        init(name: String, kind: Kind, label: String, defaultValue: String? = nil, options: [String] = [],
             optional: Bool = false, strict: Bool = true, help: String = "") {
            self.name = name
            self.kind = kind
            self.label = label
            self.defaultValue = defaultValue
            self.options = options
            self.optional = optional
            self.strict = strict
            self.help = help
        }

        init?(row: JSON) {
            guard let name = LenientField.text(row["name"]) else { return nil }
            self.name = name
            kind = Kind(rawValue: LenientField.text(row["type"]) ?? "") ?? .text
            label = LenientField.text(row["label"]) ?? name
            defaultValue = row["default"] as? String
            options = LenientField.strings(row["options"])
            optional = LenientField.bool(row["optional"])
            strict = LenientField.optionalBool(row["strict"]) ?? true
            help = LenientField.text(row["help"]) ?? ""
        }

        var isDeliver: Bool { name == CronBlueprint.deliverField }

        /// Help shown under the control: never for text slots (it is their placeholder) or the delivery slot, whose
        /// backend help is dashboard-centric (`blueprintSlotHelp`).
        var slotHelp: String? {
            guard !help.isEmpty, kind != .text, !isDeliver else { return nil }
            return help
        }
    }

    static let deliverField = "deliver"

    let key: String
    var title: String
    var description: String
    var category: String?
    var fields: [Field]
    /// The registering plugin, for plugin blueprints.
    var plugin: String?
    var scheduleHuman: String?

    var id: String { key }

    init(key: String, title: String, description: String = "", fields: [Field] = [], plugin: String? = nil) {
        self.key = key
        self.title = title
        self.description = description
        self.fields = fields
        self.plugin = plugin
    }

    init?(row: JSON) {
        guard let key = LenientField.text(row["key"]) else { return nil }
        self.key = key
        title = LenientField.text(row["title"]) ?? key
        description = LenientField.text(row["description"]) ?? ""
        category = LenientField.text(row["category"])
        fields = (row["fields"] as? [JSON] ?? []).compactMap(Field.init(row:))
        plugin = LenientField.text(row["plugin"])
        scheduleHuman = LenientField.text(row["scheduleHuman"])
    }

    /// The form's starting values: each slot's default, with the delivery slot's "origin" (the chat a dashboard or
    /// gateway job was created from, which a phone doesn't have) or empty default seeded to "local"
    /// (`initialBlueprintValues`).
    var initialValues: [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            let seeded = field.defaultValue ?? ""
            values[field.name] = field.isDeliver && (seeded.isEmpty || seeded == "origin") ? CronDelivery.local : seeded
        }
        return values
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty || "\(title) \(description)".lowercased().contains(needle)
    }

    /// A slot-level error arrives as "422: <message>"; the code goes (`cleanBlueprintFieldError`).
    static func cleanFieldError(_ message: String) -> String {
        message.replacingOccurrences(of: #"^\d+:\s*"#, with: "", options: .regularExpression)
    }
}

/// Delivery target lists: the scheduler takes comma-separated targets, so results can stay local while also going to
/// a connected platform.
enum CronDelivery {
    static let local = "local"

    private static let labels = ["local": "Local (save only)", "telegram": "Telegram", "discord": "Discord",
                                 "slack": "Slack", "email": "Email"]

    static func label(_ id: String, fallback: String? = nil) -> String {
        labels[id] ?? fallback ?? id
    }

    /// A stored value as a label list ("local,telegram" → "Local (save only), Telegram").
    static func summary(_ value: String) -> String {
        parse(value).map { label($0) }.joined(separator: ", ")
    }

    /// The selected targets, deduplicated in order; "local" when none (`parseCronDeliveryTargets`).
    static func parse(_ value: String) -> [String] {
        var seen = Set<String>()
        let targets = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return targets.isEmpty ? [local] : targets
    }

    /// Adds or removes a target; the last one can't be removed (`toggleCronDeliveryTarget`).
    static func toggle(_ value: String, _ target: String, on: Bool) -> String {
        let targets = parse(value)
        if on { return (targets.contains(target) ? targets : targets + [target]).joined(separator: ",") }
        guard targets.contains(target), targets.count > 1 else { return targets.joined(separator: ",") }
        return targets.filter { $0 != target }.joined(separator: ",")
    }

    /// The discovered targets plus any selected one discovery didn't return, so editing never drops a saved route.
    static func options(_ targets: [CronDeliveryTarget], selected value: String) -> [CronDeliveryTarget] {
        let known = Set(targets.map(\.id))
        return targets + parse(value).filter { !known.contains($0) }.map { CronDeliveryTarget(id: $0, name: $0) }
    }
}

/// The editor's frequency presets (`SCHEDULE_OPTIONS`) and the plain-language summary under them.
enum CronSchedule: String, CaseIterable, Identifiable {
    case daily, weekdays, weekly, monthly, hourly
    case every15Minutes = "every-15-minutes"
    case custom

    var id: String { rawValue }

    var expression: String? {
        switch self {
        case .daily: return "0 9 * * *"
        case .weekdays: return "0 9 * * 1-5"
        case .weekly: return "0 9 * * 1"
        case .monthly: return "0 9 1 * *"
        case .hourly: return "0 * * * *"
        case .every15Minutes: return "*/15 * * * *"
        case .custom: return nil
        }
    }

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .hourly: return "Hourly"
        case .every15Minutes: return "Every 15 minutes"
        case .custom: return "Custom"
        }
    }

    /// The fallback summary when the expression doesn't parse (`scheduleHints`).
    var hint: String {
        switch self {
        case .daily: return "Every day at 9:00 AM"
        case .weekdays: return "Monday through Friday at 9:00 AM"
        case .weekly: return "Every Monday at 9:00 AM"
        case .monthly: return "The first day of each month at 9:00 AM"
        case .hourly: return "At the top of every hour"
        case .every15Minutes: return "Every 15 minutes"
        case .custom: return "Cron syntax or natural language"
        }
    }

    /// The preset an expression belongs to: an exact preset, or the same shape at another time (`scheduleOptionForExpr`).
    static func preset(for expression: String) -> CronSchedule {
        let normalized = normalize(expression)
        if let exact = allCases.first(where: { $0.expression == normalized }) { return exact }
        guard let parts = parts(normalized) else { return .custom }
        let (minute, hour, day, month, weekday) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        let timed = isInteger(minute) && isInteger(hour)
        if day == "*", month == "*", weekday == "*", timed { return .daily }
        if day == "*", month == "*", weekday == "1-5", timed { return .weekdays }
        if day == "*", month == "*", isInteger(weekday), timed { return .weekly }
        if month == "*", weekday == "*", isInteger(day), timed { return .monthly }
        if hour == "*", day == "*", month == "*", weekday == "*", isInteger(minute) { return .hourly }
        return .custom
    }

    /// What picking this preset does to the expression field: a preset writes its expression; Custom keeps a custom
    /// expression and clears one a preset wrote (`handleSchedulePresetChange`).
    func applied(to current: String) -> String {
        if let expression { return expression }
        return Self.preset(for: current) == .custom ? current : ""
    }

    /// "Every day at 9:00 AM", "Every Monday at 7:30 AM", … (`scheduleSummary`).
    func summary(_ expression: String, locale: Locale = .current) -> String {
        guard let parts = Self.parts(Self.normalize(expression)) else { return hint }
        let (minute, hour, day, weekday) = (parts[0], parts[1], parts[2], parts[4])
        let time = { Self.time(minute: minute, hour: hour, locale: locale) }
        switch self {
        case .daily: return "Every day at \(time())"
        case .weekdays: return "Weekdays at \(time())"
        case .weekly: return "Every \(Self.dayName(weekday)) at \(time())"
        case .monthly: return "Monthly on day \(day) at \(time())"
        case .hourly:
            return minute == "0" ? "At the top of every hour" : "Every hour at :\(minute.count < 2 ? "0" + minute : minute)"
        case .every15Minutes, .custom: return hint
        }
    }

    static func dayName(_ value: String) -> String {
        let names = ["0": "Sunday", "1": "Monday", "2": "Tuesday", "3": "Wednesday", "4": "Thursday", "5": "Friday",
                     "6": "Saturday", "7": "Sunday"]
        return names[value] ?? "day \(value)"
    }

    /// A cron hour and minute as a local time ("9:00 AM"); tokens that aren't integers stay as written.
    static func time(minute: String, hour: String, locale: Locale = .current) -> String {
        guard let hourValue = Int(hour), let minuteValue = Int(minute),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2000, month: 1, day: 1,
                                                                                    hour: hourValue, minute: minuteValue))
        else { return "\(hour):\(minute)" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    private static func normalize(_ expression: String) -> String {
        expression.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func parts(_ normalized: String) -> [String]? {
        let parts = normalized.split(separator: " ").map(String.init)
        return parts.count == 5 ? parts : nil
    }

    private static func isInteger(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isASCII) && token.allSatisfy(\.isNumber)
    }
}

/// What the job editor saves (`EditorValues`), and the request bodies built from it.
struct CronEditorValues: Hashable {
    var name = ""
    var prompt = ""
    var schedule = ""
    var deliver = CronDelivery.local
    /// The per-job model override; empty follows the global model at fire time.
    var model = ""
    /// The override's provider; empty with no override.
    var provider = ""

    enum ValidationError: Equatable {
        case prompt, schedule, promptAndSchedule

        var message: String {
            switch self {
            case .prompt: return "Prompt is required."
            case .schedule: return "Schedule is required."
            case .promptAndSchedule: return "Prompt and schedule are required."
            }
        }
    }

    /// Script-only jobs need no prompt; everything else needs both (`validateCronEditor`).
    func validate(scriptOnly: Bool) -> ValidationError? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = schedule.trimmingCharacters(in: .whitespacesAndNewlines)
        if schedule.isEmpty, prompt.isEmpty, !scriptOnly { return .promptAndSchedule }
        if schedule.isEmpty { return .schedule }
        if !scriptOnly, prompt.isEmpty { return .prompt }
        return nil
    }

    /// `POST /api/cron/jobs` (`CronJobCreate`): an unnamed job sends no name, and a model override carries its
    /// provider.
    var createBody: JSON {
        var body: JSON = [
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "schedule": schedule.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { body["name"] = name }
        let deliver = deliver.trimmingCharacters(in: .whitespaces)
        body["deliver"] = deliver.isEmpty ? CronDelivery.local : deliver
        let model = model.trimmingCharacters(in: .whitespaces)
        if !model.isEmpty {
            body["model"] = model
            let provider = provider.trimmingCharacters(in: .whitespaces)
            if !provider.isEmpty { body["provider"] = provider }
        }
        return body
    }

    /// The `updates` of `PUT /api/cron/jobs/{id}` (`cronEditorUpdates`): a script-only job keeps an empty prompt and
    /// its stored model; an agent job always writes both model axes, so choosing the default clears a pin.
    func updates(scriptOnly: Bool) -> JSON {
        var updates: JSON = [
            "deliver": deliver,
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "schedule": schedule.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scriptOnly || !prompt.isEmpty { updates["prompt"] = prompt }
        if !scriptOnly {
            let model = model.trimmingCharacters(in: .whitespaces)
            let provider = provider.trimmingCharacters(in: .whitespaces)
            updates["model"] = model.isEmpty ? NSNull() : model
            updates["provider"] = provider.isEmpty ? NSNull() : provider
        }
        return updates
    }

    /// The editor's starting values for a job.
    init(job: CronJob) {
        name = job.name ?? ""
        prompt = job.prompt
        schedule = job.editableSchedule
        deliver = job.deliverValue
        model = job.model ?? ""
        provider = job.model == nil ? "" : (job.provider ?? "")
    }

    init(name: String = "", prompt: String = "", schedule: String = CronSchedule.daily.expression ?? "",
         deliver: String = CronDelivery.local, model: String = "", provider: String = "") {
        self.name = name
        self.prompt = prompt
        self.schedule = schedule
        self.deliver = deliver
        self.model = model
        self.provider = provider
    }
}

/// Text helpers for job rows and errors.
enum CronText {
    /// At most `max` characters (grapheme clusters), with an ellipsis when cut (`truncateText`).
    static func truncate(_ value: String, _ max: Int) -> String {
        value.count > max ? String(value.prefix(max)) + "…" : value
    }

    /// The first plain sentence of a stored `last_error`, without the exception class, `[marker]` or warning emoji
    /// the scheduler wraps it in, at most 200 characters (`lastErrorSummary`).
    static func errorSummary(_ lastError: String?) -> String {
        var text = (lastError ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = [#"^\[[a-z_]+(?::[a-z_]+)?\]\s*"#, #"^(?:\x{26A0}\x{FE0F}?|\x{1F6D1}|\x{274C}|\x{1F6AB})\s*"#,
                        #"^(?:[A-Za-z_][\w.]*(?:Error|Exception)|Exception):\s*"#]
        var previous = ""
        while previous != text {
            previous = text
            for pattern in wrappers {
                text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            text = String(text.drop(while: { $0.isWhitespace }))
        }
        var sentence = text
        if let end = text.range(of: #"\. |\n"#, options: .regularExpression) {
            sentence = String(text[..<text.index(after: end.lowerBound)])
        }
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count > 200 ? truncate(sentence, 199) : sentence
    }
}

/// Cron timestamps: ISO-8601 from Python's `isoformat()` (offset or naive, any fractional digits).
enum CronTime {
    /// `hermes_cli/cron.py` `_OVERDUE_GRACE_SECONDS`: a busy tick can dispatch a few minutes late.
    static let overdueGrace: TimeInterval = 15 * 60
    static let pendingRunSlack: TimeInterval = 2
    /// The queued-run row lasts at most this long, even if the host never shows the run.
    static let pendingRunTimeout: TimeInterval = 90

    private static let lock = NSLock()
    private static let withOffset: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeWithOffset = ISO8601DateFormatter()
    private static let naive: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespaces)
        guard value.count >= 19 else { return nil }
        if value[value.index(value.startIndex, offsetBy: 10)] == " " {
            value.replaceSubrange(value.index(value.startIndex, offsetBy: 10)...value.index(value.startIndex, offsetBy: 10),
                                  with: "T")
        }
        // Three fractional digits, whatever Python wrote (microseconds, or none).
        if let fraction = value.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = value[fraction].dropFirst()
            value.replaceSubrange(fraction, with: "." + String((digits + "000").prefix(3)))
        } else {
            let secondsEnd = value.index(value.startIndex, offsetBy: 19)
            value.insert(contentsOf: ".000", at: secondsEnd)
        }
        return lock.withLock {
            if let date = withOffset.date(from: value) ?? wholeWithOffset.date(from: value) { return date }
            naive.timeZone = .current
            return naive.date(from: value)
        }
    }

    /// A stored time for display; the text as stored when it doesn't parse, "—" when missing (`formatTime`).
    static func display(_ text: String?) -> String {
        guard let text else { return "—" }
        guard let date = date(text) else { return text }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension DashboardClient {
    // MARK: Jobs

    /// The jobs of one profile, or of every profile when `profile` is "all" (`GET /api/cron/jobs`).
    func cronJobs(profile: String) async throws -> [CronJob] {
        let result = try await request("GET", "/api/cron/jobs", query: ["profile": profile])
        let rows = result as? [JSON] ?? (result as? JSON)?["jobs"] as? [JSON] ?? []
        return rows.compactMap(CronJob.init(row:))
    }

    /// A job's runs, newest first (at most 100).
    func cronJobRuns(_ job: CronJob, limit: Int = 20) async throws -> [CronRun] {
        var query = ["limit": String(max(1, min(limit, 100)))]
        if let profile = job.profile { query["profile"] = profile }
        let result = try await request("GET", "/api/cron/jobs/\(try Self.segment(job.id))/runs", query: query) as? JSON
        return (result?["runs"] as? [JSON] ?? []).compactMap(CronRun.init(row:))
    }

    /// Delivery targets for a profile's jobs (nil: the dashboard's own).
    func cronDeliveryTargets(profile: String?) async throws -> [CronDeliveryTarget] {
        let result = try await request("GET", "/api/cron/delivery-targets", query: Self.profileQuery(profile)) as? JSON
        return (result?["targets"] as? [JSON] ?? []).compactMap(CronDeliveryTarget.init(row:))
    }

    /// Creates a job in `profile` (nil: the dashboard's own).
    @discardableResult
    func createCronJob(_ values: CronEditorValues, profile: String?) async throws -> CronJob {
        let result = try await request("POST", "/api/cron/jobs", query: Self.profileQuery(profile), body: values.createBody)
        return try Self.cronJob(result)
    }

    @discardableResult
    func updateCronJob(_ job: CronJob, _ values: CronEditorValues) async throws -> CronJob {
        let body: JSON = ["updates": values.updates(scriptOnly: job.isScriptOnly)]
        let result = try await request("PUT", "/api/cron/jobs/\(try Self.segment(job.id))", query: Self.profileQuery(job.profile),
                                       body: body)
        return try Self.cronJob(result)
    }

    @discardableResult
    func setCronJobPaused(_ job: CronJob, _ paused: Bool) async throws -> CronJob {
        let path = "/api/cron/jobs/\(try Self.segment(job.id))/\(paused ? "pause" : "resume")"
        return try Self.cronJob(try await request("POST", path, query: Self.profileQuery(job.profile)))
    }

    /// Runs the job now. The host answers when the run has finished, which can take far longer than an ordinary
    /// request: the wait is long, and a timeout means the run is still going on the host, not that it failed.
    @discardableResult
    func triggerCronJob(_ job: CronJob) async throws -> CronJob? {
        let result = try await opsRequest("POST", "/api/cron/jobs/\(try Self.segment(job.id))/trigger",
                                          query: Self.profileQuery(job.profile), timeout: 60 * 60)
        return (result as? JSON).flatMap(CronJob.init(row:))
    }

    /// Deletes a job for good; it stops firing at once.
    func deleteCronJob(_ job: CronJob) async throws {
        _ = try await request("DELETE", "/api/cron/jobs/\(try Self.segment(job.id))", query: Self.profileQuery(job.profile))
    }

    // MARK: Blueprints

    /// The blueprint gallery of one profile (built-ins plus its plugins' blueprints).
    func cronBlueprints(profile: String) async throws -> [CronBlueprint] {
        let result = try await request("GET", "/api/cron/blueprints", query: ["profile": profile]) as? JSON
        return (result?["blueprints"] as? [JSON] ?? []).compactMap(CronBlueprint.init(row:))
    }

    /// Fills a blueprint's slots and creates the job in `profile`. A slot error comes back as a 422.
    @discardableResult
    func instantiateCronBlueprint(_ blueprint: CronBlueprint, values: [String: String], profile: String) async throws -> CronJob {
        let result = try await request("POST", "/api/cron/blueprints/instantiate", query: ["profile": profile],
                                       body: Self.blueprintBody(blueprint, values: values))
        return try Self.cronJob(result)
    }

    static func blueprintBody(_ blueprint: CronBlueprint, values: [String: String]) -> JSON {
        ["blueprint": blueprint.key, "values": values]
    }

    private static func cronJob(_ result: Any) throws -> CronJob {
        guard let job = (result as? JSON).flatMap(CronJob.init(row:)) else {
            throw DashboardError.rpc("Hermes didn't return the job.")
        }
        return job
    }
}
