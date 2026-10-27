import Foundation

// The desktop's session importer (`app/session-import/api.ts`): Claude Code and Codex CLI conversations found on the
// Hermes host, read through the gateway's `session.foreign.*` methods (`hermes_cli/foreign_sessions_browser.py`).
// Only host-side logs: the methods take an opaque handle the host listed, never a path or an upload, so a file on the
// phone can't be imported.

/// The three calls the importer makes, so its flow can run against a fake.
protocol ForeignSessionCalls {
    /// One page of conversations (25), newest first; `source` nil lists both tools.
    func foreignList(source: ForeignSource?, offset: Int, profile: String?) async throws -> SessionForeignListResult
    /// The conversation's last 40 messages, and whether `profile` already holds a copy.
    func foreignPreview(id: String, profile: String?) async throws -> SessionForeignPreviewResult
    /// Copies the conversation into `profile`'s history (idempotent per source conversation).
    func foreignImport(id: String, profile: String?) async throws -> SessionForeignImportResult
}

extension GatewayClient: ForeignSessionCalls {
    /// The host reads and parses whole logs (up to 32 MB each): the desktop gives these a minute.
    static let foreignTimeout: TimeInterval = 60

    func foreignList(source: ForeignSource?, offset: Int, profile: String?) async throws -> SessionForeignListResult {
        try await sessionForeignList(.init(profile: profile, source: source, offset: offset), timeout: Self.foreignTimeout)
    }

    func foreignPreview(id: String, profile: String?) async throws -> SessionForeignPreviewResult {
        try await sessionForeignPreview(.init(profile: profile, id: id), timeout: Self.foreignTimeout)
    }

    func foreignImport(id: String, profile: String?) async throws -> SessionForeignImportResult {
        try await sessionForeignImport(.init(profile: profile, id: id), timeout: Self.foreignTimeout)
    }
}

/// The source tabs (All, Claude Code, Codex).
enum SessionImportSource: String, CaseIterable, Identifiable, Hashable {
    case all, claude, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The `source` param; nil lists every tool.
    var foreign: ForeignSource? {
        switch self {
        case .all: return nil
        case .claude: return .claude
        case .codex: return .codex
        }
    }
}

extension ForeignSessionRow: Identifiable {
    var displayTitle: String {
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? label : title
    }

    /// The working folder, else the opening excerpt.
    var detail: String {
        if let cwd, !cwd.isEmpty { return cwd }
        return excerpt ?? ""
    }

    var modified: Date { Date(timeIntervalSince1970: mtime) }
    var messages: Int { turnCount ?? 0 }
}

/// The list's pure parts: merging pages, the search, and the day headers.
enum SessionImportList {
    /// Pages appended, a conversation listed again (the logs moved between reads) kept once at its first place
    /// with its newest row.
    static func merge(_ rows: [ForeignSessionRow], _ page: [ForeignSessionRow]) -> [ForeignSessionRow] {
        var out = rows
        var index = Dictionary(out.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for row in page {
            if let at = index[row.id] {
                out[at] = row
            } else {
                index[row.id] = out.count
                out.append(row)
            }
        }
        return out
    }

    /// Title, folder and excerpt contain the query, ignoring case.
    static func filter(_ rows: [ForeignSessionRow], query: String) -> [ForeignSessionRow] {
        guard !query.isEmpty else { return rows }
        let needle = query.lowercased()
        return rows.filter { "\($0.displayTitle) \($0.cwd ?? "") \($0.excerpt ?? "")".lowercased().contains(needle) }
    }

    /// Consecutive rows of one calendar day under its date ("Oct 27").
    struct Day: Identifiable, Hashable {
        var id: String
        var title: String
        var rows: [ForeignSessionRow]
    }

    static func days(_ rows: [ForeignSessionRow], calendar: Calendar = .current, locale: Locale = .current) -> [Day] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        var days: [Day] = []
        for row in rows {
            let start = calendar.startOfDay(for: row.modified)
            let key = "\(Int(start.timeIntervalSince1970))-\(days.count)"
            if let last = days.last, let first = last.rows.first,
               calendar.isDate(first.modified, inSameDayAs: row.modified) {
                days[days.count - 1].rows.append(row)
            } else {
                days.append(Day(id: key, title: formatter.string(from: row.modified), rows: [row]))
            }
        }
        return days
    }
}
