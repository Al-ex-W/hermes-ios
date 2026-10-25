import Foundation

/// How a tool row reads (`fallback-model`): its status, title, glyph, and what opening it shows.
enum ToolStatus: Hashable {
    case running
    case success
    /// Expected and harmless: a guessed path missing, grep finding nothing, a call the user stopped.
    case notice
    /// Not a failure, but not a clean result either (no result arrived, a memory write over budget).
    case warning
    case error
}

/// A web search hit, for the expanded `web_search` row.
struct ToolSearchHit: Hashable {
    var title: String
    var url: String?
    var snippet: String?
}

extension ToolCall {
    // MARK: Status

    /// Red only for a real failure: a non-zero exit with output, a missing file and a stopped call are not.
    var status: ToolStatus {
        if isPending { return .running }
        if result == nil { return interrupted ? .notice : .warning }
        let record = record
        if record["success"]?.boolValue == true || record["ok"]?.boolValue == true { return .success }
        guard let error = errorDescription else { return .success }
        if name == "read_file", error.lowercased().hasPrefix("file not found:") { return .notice }
        if name == "terminal", error == "Command failed with exit code 1." { return .notice }
        return name == "memory" ? .warning : .error
    }

    /// Why the call failed, when it did (`toolErrorText`). A non-zero exit code alone only counts when the command
    /// printed nothing: grep and diff exit 1 with useful output.
    var errorDescription: String? {
        if let text = Self.errorText(result) { return text }
        let record = record
        if record["success"]?.boolValue == false || record["ok"]?.boolValue == false {
            return Self.firstString(record, ["message", "reason", "detail"]) ?? "Tool returned success=false."
        }
        if let status = record["status"]?.stringValue,
           status.trimmingCharacters(in: .whitespaces).range(of: "^(error|failed|failure|fatal|exception)$", options: [.regularExpression, .caseInsensitive]) != nil {
            return Self.firstString(record, ["message", "reason", "detail"]) ?? "Tool returned status \"\(status)\"."
        }
        if let exit = exitCode, exit != 0 {
            let output = Self.firstString(record, ["output", "stdout", "stderr", "output_preview"])
            return output == nil ? "Command failed with exit code \(exit)." : nil
        }
        return nil
    }

    /// A settled edit without a diff: only `patch` keeps its diff in history, so the row would be a dead duplicate.
    var drawsNothing: Bool { isFileEdit && done && status != .error && diff == nil }

    // MARK: Title

    /// "Ran npm test", "Read Package.swift", "Searched “swift regex”", or the tool's done/pending title.
    var title: String {
        if done, result == nil { return interrupted ? "Interrupted" : "Result unavailable" }
        let running = isPending
        let record = record
        switch name {
        case "web_extract":
            if let host = Self.host(Self.firstURL(args) ?? Self.firstURL(record)) { return "\(running ? "Reading" : "Read") \(host)" }
        case "browser_navigate":
            if let host = Self.host(Self.firstURL(args) ?? Self.firstURL(record)) {
                if !running, failed { return "Failed to open \(host)" }
                return "\(running ? "Opening" : "Opened") \(host)"
            }
        case "web_search":
            if let query = Self.firstString(args, ["search_term", "query"]) ?? context {
                return "\(running ? "Searching" : "Searched") “\(Self.compact(query, 48))”"
            }
        case "read_file":
            if let path = Self.firstString(args, ["path", "file", "filepath"]) {
                return "\(running ? "Reading" : "Read") \(Self.basename(path))\(readLines.map { " \($0)" } ?? "")"
            }
        case "terminal", "execute_code":
            if let command = command {
                let verb = name == "execute_code" ? (running ? "Scripting" : "Ran code") : (running ? "Running" : "Ran")
                return "\(verb) \(Self.withoutLeadingWord(Self.compact(Self.summarizeCommand(command), 160), verb))"
            }
        default:
            if isFileEdit, let path = editPath { return Self.basename(path) }
        }
        let titles = Self.titles[name]
        if let titles { return running ? titles.pending : titles.done }
        let action = Self.displayName(name)
        if name.hasPrefix("browser_") { return running ? "Running browser \(action.lowercased())" : "Browser \(action)" }
        if name.hasPrefix("web_") { return running ? "Running web \(action.lowercased())" : "Web \(action)" }
        return running ? "Running \(action.lowercased())" : action
    }

    /// The SF Symbol standing in for the tool's codicon.
    var symbol: String {
        if isFileEdit { return "pencil" }
        switch name {
        case "terminal", "execute_code": return Theme.Icon.terminal
        case "read_file": return "doc.text"
        case "list_files": return "doc.on.doc"
        case "search_files", "web_search", "session_search_recall": return Theme.Icon.search
        case "web_extract": return "globe"
        case "memory": return "brain"
        case "clarify": return "questionmark.bubble"
        case "cronjob": return "clock"
        case "image_generate", "browser_take_screenshot": return "photo"
        case "vision_analyze": return "eye"
        case "delegate_task": return "person.2"
        default:
            if name.hasPrefix("browser_") { return "globe" }
            if name.hasPrefix("mcp__") { return "powerplug" }
            return Theme.Icon.tool
        }
    }

    /// The server of an MCP tool (`mcp__server__tool`), shown beside its title.
    var server: String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count > 1 ? parts[0].replacingOccurrences(of: "_", with: " ") : nil
    }

    // MARK: Body

    /// What a shell or code call ran.
    var command: String? {
        Self.firstString(args, ["command", "code"]) ?? Self.firstString(args, ["context", "preview"]) ?? context
    }

    var stdout: String? { Self.firstString(record, ["stdout"]) }
    var stderr: String? { Self.firstString(record, ["stderr"]) }

    /// The call's output as text: a shell's output, a file's content, a summary, or the result itself.
    var output: String? {
        let record = record
        if let text = Self.firstString(record, ["output", "content", "text", "output_preview", "message", "summary"]) { return text }
        if let lines = record["lines"]?.arrayValue?.compactMap(\.stringValue), !lines.isEmpty { return lines.joined(separator: "\n") }
        if let resultText, !resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return resultText }
        if case let .string(text)? = result, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return nil
    }

    var searchHits: [ToolSearchHit] {
        guard name == "web_search" else { return [] }
        let record = record
        let list = (record["results"] ?? record["items"] ?? record["data"].flatMap { Transcript.object($0)["web"] } ?? record["web"])?.arrayValue ?? []
        return list.prefix(6).compactMap { raw in
            let hit = Transcript.object(raw)
            let url = Self.firstString(hit, ["url", "link", "href"])
            let title = Self.firstString(hit, ["title", "name"]) ?? url ?? ""
            guard !title.isEmpty else { return nil }
            return ToolSearchHit(title: title, url: url, snippet: Self.firstString(hit, ["snippet", "description", "body"]))
        }
    }

    /// "1.2s" for the run's duration.
    var durationLabel: String? {
        guard let seconds = record["duration_s"]?.doubleValue, seconds >= 0 else { return nil }
        return Self.formatDuration(seconds)
    }

    var diffCounts: (added: Int, removed: Int)? {
        guard isFileEdit, let diff else { return nil }
        let stats = Self.diffStats(diff)
        return stats.added + stats.removed > 0 ? stats : nil
    }

    /// Arguments and result, pretty-printed, for the payload disclosure.
    var payloadText: String {
        var parts: [String] = []
        if !args.isEmpty { parts.append("Arguments:\n\(Self.pretty(.object(args)))") }
        if let result { parts.append("Result:\n\(Self.pretty(result))") }
        return Self.clamp(parts.joined(separator: "\n\n"))
    }

    // MARK: Helpers

    private var readLines: String? {
        let offset = args["offset"]?.intValue ?? args["start_line"]?.intValue
        let limit = args["limit"]?.intValue
        guard let offset else { return nil }
        return limit.map { "L\(offset)–\(offset + $0)" } ?? "from L\(offset)"
    }

    static let titles: [String: (done: String, pending: String)] = [
        "browser_click": ("Clicked page element", "Clicking page element"),
        "browser_fill": ("Filled form field", "Filling form field"),
        "browser_navigate": ("Opened page", "Opening page"),
        "browser_snapshot": ("Captured page snapshot", "Capturing page snapshot"),
        "browser_take_screenshot": ("Captured screenshot", "Capturing screenshot"),
        "browser_type": ("Typed on page", "Typing on page"),
        "clarify": ("Asked a question", "Asking a question"),
        "cronjob": ("Cron job", "Scheduling cron job"),
        "edit_file": ("Edited file", "Editing file"),
        "execute_code": ("Ran code", "Scripting"),
        "image_generate": ("Generated image", "Generating image"),
        "list_files": ("Listed files", "Listing files"),
        "memory": ("Saved to memory", "Saving to memory"),
        "patch": ("Patched file", "Patching file"),
        "read_file": ("Read file", "Reading file"),
        "search_files": ("Searched files", "Searching files"),
        "session_search_recall": ("Searched session history", "Searching session history"),
        "terminal": ("Ran command", "Running command"),
        "todo": ("Updated todos", "Updating todos"),
        "vision_analyze": ("Analyzed image", "Analyzing image"),
        "web_extract": ("Read webpage", "Reading webpage"),
        "web_search": ("Searched web", "Searching web"),
        "write_file": ("Edited file", "Editing file"),
        "delegate_task": ("Delegated task", "Delegating task"),
    ]

    /// "Read File" for `read_file`; an MCP tool by its own name.
    static func displayName(_ name: String) -> String {
        var base = name
        if base.hasPrefix("mcp__") { base = base.components(separatedBy: "__").last ?? base }
        base = base.replacingOccurrences(of: "^(browser_|web_)", with: "", options: .regularExpression)
        let words = base.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? name : words.joined(separator: " ")
    }

    static func basename(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespaces)
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    static func host(_ url: String?) -> String? {
        guard let url, let host = URL(string: url)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The first http(s) URL anywhere in `record`.
    static func firstURL(_ record: [String: JSONValue]) -> String? {
        if let url = firstString(record, ["url", "target"]), url.hasPrefix("http") { return url }
        for key in record.keys.sorted() {
            switch record[key] {
            case let .string(text)? where text.hasPrefix("http://") || text.hasPrefix("https://"): return text
            case let .array(items)?:
                if let url = items.lazy.compactMap({ $0.stringValue }).first(where: { $0.hasPrefix("http") }) { return url }
            default: continue
            }
        }
        return nil
    }

    /// A shell command as the title shows it: its first line, `cd … &&` prefixes dropped, whitespace collapsed.
    static func summarizeCommand(_ command: String) -> String {
        var line = command.split(separator: "\n").first.map(String.init) ?? command
        while let range = line.range(of: "^\\s*cd\\s+\\S+\\s*&&\\s*", options: .regularExpression) { line.removeSubrange(range) }
        return line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func compact(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// "Running running tests" reads once: a context that opens with the verb loses it.
    private static func withoutLeadingWord(_ text: String, _ verb: String) -> String {
        guard let space = text.firstIndex(of: " "), text[..<space].lowercased() == verb.lowercased() else { return text }
        return String(text[text.index(after: space)...])
    }

    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: seconds < 10 ? "%.1fs" : "%.0fs", seconds) }
        let total = Int(seconds.rounded())
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }

    static func pretty(_ value: JSONValue) -> String {
        if case let .string(text) = value {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let parsed = try? JSONValue(jsonData: Data(trimmed.utf8)) else { return text }
            return pretty(parsed)
        }
        guard let object = try? JSONSerialization.data(withJSONObject: value.anyValue, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return "\(value)" }
        return String(decoding: object, as: UTF8.self)
    }

    /// Long output is cut for display; Copy still takes all of it.
    static func clamp(_ text: String, _ limit: Int = 12_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n\n… \(text.count - limit) more characters"
    }
}

// MARK: - Run summary

enum ToolRunSummary {
    private enum Category: CaseIterable {
        case edit, explore, search, read, browse, interact, analyze, run, delegate, other

        var copy: (noun: (String, String), past: String, present: String) {
            switch self {
            case .analyze: return (("image", "images"), "Analyzed", "Analyzing")
            case .browse: return (("page", "pages"), "Opened", "Opening")
            case .delegate: return (("task", "tasks"), "Delegated", "Delegating")
            case .edit: return (("file", "files"), "Edited", "Editing")
            case .explore: return (("file", "files"), "Explored", "Exploring")
            case .interact: return (("browser action", "browser actions"), "Performed", "Performing")
            case .other: return (("tool", "tools"), "Used", "Using")
            case .read: return (("page", "pages"), "Read", "Reading")
            case .run: return (("command", "commands"), "Ran", "Running")
            case .search: return (("query", "queries"), "Searched", "Searching")
            }
        }
    }

    private static let categories: [String: Category] = [
        "browser_navigate": .browse, "delegate_task": .delegate, "execute_code": .run, "list_files": .explore,
        "read_file": .explore, "search_files": .explore, "session_search_recall": .search, "terminal": .run,
        "vision_analyze": .analyze, "web_extract": .read, "web_search": .search,
    ]

    private static func category(_ call: ToolCall) -> Category {
        if call.isFileEdit { return .edit }
        return categories[call.name] ?? (call.name.hasPrefix("browser_") ? .interact : .other)
    }

    /// The one grey line standing in for a run (`summarizeToolRun`): "Explored 3 files, ran 5 commands". While
    /// live, the clause holding the current call speaks in the present tense.
    static func summarize(_ calls: [ToolCall], live: Bool) -> String {
        let narrating = live ? (calls.first(where: \.isPending) ?? calls.last) : nil
        let liveCategory = narrating.map(category)
        var grouped: [Category: [ToolCall]] = [:]
        for call in calls { grouped[category(call), default: []].append(call) }
        var clauses = Category.allCases.compactMap { category -> String? in
            guard let group = grouped[category] else { return nil }
            return clause(category, group, live: category == liveCategory)
        }
        let failed = calls.filter(\.failed).count
        if failed > 0 { clauses.append("\(failed) tool call\(failed == 1 ? "" : "s") failed") }
        return clauses.enumerated().map { index, text in
            index == 0 ? text : text.prefix(1).lowercased() + text.dropFirst()
        }.joined(separator: ", ")
    }

    private static func clause(_ category: Category, _ calls: [ToolCall], live: Bool) -> String {
        let copy = category.copy
        let verb = live ? copy.present : copy.past
        let count = calls.reduce(0) { sum, call in
            sum + (call.name == "web_extract" ? max(1, call.args["urls"]?.arrayValue?.count ?? 1) : 1)
        }
        if count == 1, category != .interact, let target = target(calls[0], category), live || category != .run {
            return "\(verb) \(target)"
        }
        return "\(verb) \(count) \(count == 1 ? copy.noun.0 : copy.noun.1)"
    }

    private static func target(_ call: ToolCall, _ category: Category) -> String? {
        switch category {
        case .run:
            return call.command.map { ToolCall.summarizeCommand($0) }
        case .search:
            return (ToolCall.firstString(call.args, ["query", "search_term"])).map { "“\(ToolCall.compact($0, 48))”" }
        case .read, .browse:
            return ToolCall.host(ToolCall.firstURL(call.args))
        default:
            if let path = ToolCall.firstString(call.args, ["path", "file", "filepath"]) { return ToolCall.basename(path) }
            return ToolCall.firstString(call.args, ["query", "url"])
        }
    }
}
