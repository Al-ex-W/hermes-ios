import Foundation

/// What a session row's dot says (`SessionStatusBucket` in `store/session-dot-state.ts`), loudest first.
enum SessionStatus: String, CaseIterable, Codable, Hashable {
    /// An approval, question or password is blocking its turn.
    case needsInput = "needs-input"
    case working
    /// A reply landed that hasn't been read.
    case unread
    /// Nothing has been sent yet.
    case draft
    case idle

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// A turn of its own is live: running, or waiting on an answer.
    var hasLiveTurn: Bool { self == .needsInput || self == .working }

    var label: String {
        switch self {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .unread: return "Unread"
        case .draft: return "Draft"
        case .idle: return "Idle"
        }
    }

    /// The dot's spoken meaning; nil for idle.
    var accessibilityLabel: String? {
        switch self {
        case .needsInput: return "Needs your input"
        case .working: return "Session running"
        case .unread: return "Finished, unread"
        case .draft: return "Draft, nothing sent yet"
        case .idle: return nil
        }
    }
}

/// How the sessions list is divided (`SIDEBAR_GROUPING_ORDER`).
enum SidebarGrouping: String, CaseIterable, Codable, Identifiable {
    case date, project, status, profile

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: return "Date"
        case .project: return "Project"
        case .status: return "Status"
        case .profile: return "Profile"
        }
    }
}

/// What ranks rows within the grouping (`SidebarSortKey`).
enum SidebarOrdering: String, CaseIterable, Codable, Identifiable {
    case updated, created, status, tokens, cost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .updated: return "Updated"
        case .created: return "Created"
        case .status: return "Status"
        case .tokens: return "Tokens"
        case .cost: return "Cost"
        }
    }

    /// Ranking by size is a question about the whole list, so it drops the dividers.
    var ranksGlobally: Bool { self == .tokens || self == .cost }
}

/// A run of rows under one divider. The first run of a list carries no label.
struct SessionGroup: Identifiable, Equatable {
    let id: String
    var title: String?
    var sessions: [SessionInfo]
}

/// The sidebar's ordering and grouping rules, ported from the desktop (`lib/session-date-groups.ts`,
/// `lib/time.ts`, `store/layout.ts`).
enum SessionGroups {
    /// The day ends at 4 AM: a 12:30 AM session belongs to the evening before.
    static let dayRolloverHour = 4
    /// The unlabelled head aims at about this many sessions, cut only at a pause of at least `minRunBreak`;
    /// a silence longer than `maxRunGap` always ends the run.
    static let targetHeadSessions = 5
    static let minRunBreak: TimeInterval = 30 * 60
    static let maxRunGap: TimeInterval = 8 * 3600

    // MARK: Ordering

    static func sorted(_ sessions: [SessionInfo], by ordering: SidebarOrdering,
                       status: (SessionInfo) -> SessionStatus) -> [SessionInfo] {
        func newer(_ a: SessionInfo, _ b: SessionInfo) -> Bool {
            a.recency != b.recency ? a.recency > b.recency : a.id > b.id
        }
        switch ordering {
        case .updated:
            return sessions.sorted(by: newer)
        case .created:
            return sessions.sorted { a, b in
                let first = a.startedAt ?? a.recency, second = b.startedAt ?? b.recency
                return first != second ? first > second : newer(a, b)
            }
        case .status:
            let ranks = Dictionary(sessions.map { ($0.id, status($0).rank) }, uniquingKeysWith: { first, _ in first })
            return sessions.sorted { a, b in
                let first = ranks[a.id] ?? 0, second = ranks[b.id] ?? 0
                return first != second ? first < second : newer(a, b)
            }
        case .tokens:
            return sessions.sorted { a, b in a.tokens != b.tokens ? a.tokens > b.tokens : newer(a, b) }
        case .cost:
            return sessions.sorted { a, b in a.costUSD != b.costUSD ? a.costUSD > b.costUSD : newer(a, b) }
        }
    }

    // MARK: Date groups

    /// Coarse calendar ranges that coarsen with age: earlier today, yesterday, earlier this week, last week,
    /// earlier this month, then the month, then month and year. Never one divider per day.
    struct Bucket: Equatable {
        let key: String
        let label: String
    }

    /// Divides rows (already ordered) under date dividers. The head is the newest run of sessions, cut at a real
    /// pause, and has no label; neither does whatever group renders first.
    static func byRecency(_ sessions: [SessionInfo], now: Date = Date(), calendar: Calendar = .current) -> [SessionGroup] {
        let cutoff = headCutoff(sessions, now: now, calendar: calendar)
        var groups: [SessionGroup] = []
        var emitted: Set<String> = []
        var lastKey: String?
        for session in sessions {
            let time = session.recency.timeIntervalSince1970
            if time >= cutoff {
                lastKey = "recent"
            } else {
                let bucket = calendarBucket(session.recency, now: now, calendar: calendar)
                if bucket.key != lastKey {
                    lastKey = bucket.key
                    // Marked even when not labelled, so an out-of-order row can't label it later.
                    let alreadyEmitted = !emitted.insert(bucket.key).inserted
                    if !groups.isEmpty, !alreadyEmitted {
                        groups.append(SessionGroup(id: bucket.key, title: bucket.label, sessions: []))
                    }
                }
            }
            if groups.isEmpty { groups.append(SessionGroup(id: "recent", title: nil, sessions: [])) }
            groups[groups.count - 1].sessions.append(session)
        }
        return groups
    }

    /// The oldest time (seconds since 1970) still inside the unlabelled head: −∞ when the whole list is one run,
    /// +∞ when there is no head (the calendar groups own it all). Of the cut points (every pause of at least
    /// `minRunBreak` within the run, and the run's end) the one whose head size is closest, on a log scale, to
    /// `targetHeadSessions` wins. A cut at the run's end above rows of the head's own bucket dissolves the head.
    static func headCutoff(_ sessions: [SessionInfo], now: Date = Date(), calendar: Calendar = .current) -> Double {
        let times = sessions.map { $0.recency.timeIntervalSince1970 }.sorted(by: >)
        var best = -1
        var bestScore = Double.infinity
        var runEnded = false
        for index in times.indices.dropFirst() {
            let gap = times[index - 1] - times[index]
            let endsRun = gap > maxRunGap
            if gap >= minRunBreak || endsRun {
                let score = abs(log(Double(index) / Double(targetHeadSessions)))
                if score < bestScore {
                    bestScore = score
                    best = index
                    runEnded = endsRun
                }
            }
            if endsRun { break }
        }
        guard best > 0 else { return -.infinity }
        if runEnded {
            let head = calendarBucket(Date(timeIntervalSince1970: times[0]), now: now, calendar: calendar)
            let below = calendarBucket(Date(timeIntervalSince1970: times[best]), now: now, calendar: calendar)
            if head == below { return .infinity }
        }
        return times[best - 1]
    }

    static func calendarBucket(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bucket {
        let nominal = nominalDayStart(date, calendar: calendar)
        let today = nominalDayStart(now, calendar: calendar)
        let days = calendar.dateComponents([.day], from: nominal, to: today).day ?? 0
        if days <= 0 { return Bucket(key: "today", label: "Earlier today") }
        if days == 1 { return Bucket(key: "yesterday", label: "Yesterday") }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        if nominal >= weekStart { return Bucket(key: "this-week", label: "Earlier this week") }
        if let lastWeek = calendar.date(byAdding: .day, value: -7, to: weekStart), nominal >= lastWeek {
            return Bucket(key: "last-week", label: "Last week")
        }
        let month = calendar.dateComponents([.year, .month], from: nominal)
        let current = calendar.dateComponents([.year, .month], from: today)
        let sameYear = month.year == current.year
        if sameYear, month.month == current.month { return Bucket(key: "this-month", label: "Earlier this month") }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMMyyyy")
        let key = "\(sameYear ? "m" : "my")-\(month.year ?? 0)-\(month.month ?? 0)"
        return Bucket(key: key, label: formatter.string(from: nominal))
    }

    /// The start of the day `date` belongs to, by the wall clock (so a DST change can't move the boundary).
    static func nominalDayStart(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        guard calendar.component(.hour, from: date) < dayRolloverHour else { return start }
        return calendar.date(byAdding: .day, value: -1, to: start) ?? start
    }

    // MARK: Other groupings

    /// Rows with a live turn, then the rest, under Working and Done.
    static func byStatus(_ sessions: [SessionInfo], isWorking: (SessionInfo) -> Bool) -> [SessionGroup] {
        let working = sessions.filter(isWorking)
        let done = sessions.filter { !isWorking($0) }
        return [
            SessionGroup(id: "status:working", title: "Working", sessions: working),
            SessionGroup(id: "status:done", title: "Done", sessions: done),
        ].filter { !$0.sessions.isEmpty }
    }

    /// One group per repository (or working directory), the most recently used first; sessions without one
    /// go under Home.
    static func byProject(_ sessions: [SessionInfo]) -> [SessionGroup] {
        grouped(sessions) { session in
            guard let path = session.gitRepoRoot ?? session.cwd else { return ("project:home", "Home") }
            let name = (path as NSString).lastPathComponent
            return ("project:\(path)", name.isEmpty ? path : name)
        }
    }

    /// One group per owning profile, the default profile first.
    static func byProfile(_ sessions: [SessionInfo], label: (String) -> String) -> [SessionGroup] {
        let groups = grouped(sessions) { session in
            let name = session.profile ?? "default"
            return ("profile:\(name)", label(name))
        }
        return groups.filter { $0.id == "profile:default" } + groups.filter { $0.id != "profile:default" }
    }

    /// One group per messaging platform, the most recently used first.
    static func bySource(_ sessions: [SessionInfo]) -> [SessionGroup] {
        grouped(sessions) { session in
            let source = session.source?.lowercased() ?? "other"
            return ("messaging:\(source)", SessionSource.label(source))
        }
    }

    /// Groups in order of first appearance, keeping the rows' order inside each.
    private static func grouped(_ sessions: [SessionInfo], by key: (SessionInfo) -> (id: String, title: String)) -> [SessionGroup] {
        var groups: [SessionGroup] = []
        var index: [String: Int] = [:]
        for session in sessions {
            let (id, title) = key(session)
            if let position = index[id] {
                groups[position].sessions.append(session)
            } else {
                index[id] = groups.count
                groups.append(SessionGroup(id: id, title: title, sessions: [session]))
            }
        }
        return groups
    }

    // MARK: Rows

    /// The row's compact age: "now", "5m", "3h", "2d".
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    /// A loaded row matches a search on its title, first message, id, folder or branch.
    static func matches(_ session: SessionInfo, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return [session.title, session.preview, session.id, session.cwd, session.gitBranch].contains { field in
            field?.localizedCaseInsensitiveContains(query) == true
        }
    }
}
