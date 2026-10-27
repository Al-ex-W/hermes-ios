import Foundation

/// What the Artifacts page lists (`app/artifacts/artifact-utils.ts`): images, files and links that recent sessions
/// produced, found in their stored transcripts.
enum ArtifactKind: String, Hashable, CaseIterable {
    case image, file, link

    var label: String { rawValue }
}

/// The page's tabs (`ARTIFACT_FILTERS`).
enum ArtifactFilter: String, CaseIterable, Identifiable {
    case all, image, file, link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .image: return "Images"
        case .file: return "Files"
        case .link: return "Links"
        }
    }

    func includes(_ kind: ArtifactKind) -> Bool {
        self == .all || rawValue == kind.rawValue
    }
}

struct ArtifactRecord: Identifiable, Hashable {
    /// `<session id>:<value>`: one record per value per session.
    let id: String
    var kind: ArtifactKind
    /// The path or URL as the transcript names it.
    var value: String
    var label: String
    var sessionID: String
    var profile: String?
    var sessionTitle: String
    var timestamp: Date

    var isLink: Bool { kind == .link }
    /// A path on the Hermes host (read through the dashboard), not a URL.
    var isHostFile: Bool { ArtifactScanner.isFilePath(value) }
    /// The host path, `file://` URLs turned into their path.
    var hostPath: String { ArtifactScanner.hostPath(value) }
    var url: URL? { value.hasPrefix("http://") || value.hasPrefix("https://") ? URL(string: value) : nil }

    /// Search over label, value and session title (case-insensitive).
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return label.lowercased().contains(needle) || value.lowercased().contains(needle)
            || sessionTitle.lowercased().contains(needle)
    }

    /// The URL's host and path for a link (`hostPathLabel`), the value itself otherwise.
    var location: String {
        guard isLink, let components = URLComponents(string: value), let rawHost = components.host else { return value }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let path = components.path == "/" ? "" : components.path
        return host + path
    }

    /// How a file previews in the app.
    var preview: ArtifactPreviewKind { ArtifactPreviewKind(value: value, kind: kind) }
}

/// How the preview sheet shows an artifact: the image, rendered markdown, source text, or a file row to share.
enum ArtifactPreviewKind: Hashable {
    case image
    case markdown
    case code(language: String)
    case text
    case other

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let textExtensions: Set<String> = ["txt", "log", "csv", "tsv", "text", "out", "env", "ini", "cfg", "conf"]
    private static let codeLanguages: [String: String] = [
        "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "ts": "typescript",
        "tsx": "tsx", "jsx": "jsx", "swift": "swift", "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml",
        "sh": "bash", "bash": "bash", "zsh": "bash", "html": "html", "htm": "html", "css": "css", "scss": "scss",
        "xml": "xml", "svg": "xml", "sql": "sql", "rb": "ruby", "go": "go", "rs": "rust", "java": "java", "kt": "kotlin",
        "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "m": "objectivec", "mm": "objectivec",
        "cs": "csharp", "php": "php", "lua": "lua", "r": "r", "pl": "perl", "dockerfile": "dockerfile",
        "geojson": "json", "kml": "xml", "gpx": "xml", "ipynb": "json",
    ]

    init(value: String, kind: ArtifactKind) {
        if kind == .link {
            self = .other
            return
        }
        let ext = ArtifactScanner.pathExtension(value)
        if kind == .image, ext != "svg" {
            self = .image
        } else if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if let language = Self.codeLanguages[ext] {
            self = .code(language: language)
        } else if Self.textExtensions.contains(ext) {
            self = .text
        } else {
            self = .other
        }
    }

    /// Read as text through `/api/fs/read-text`.
    var isText: Bool {
        switch self {
        case .markdown, .code, .text: return true
        case .image, .other: return false
        }
    }
}

/// The transcript scan (`collectArtifactsForSession` and its helpers), kept to the desktop's rules: what an
/// assistant reply names, what an artifact-producing or terminal tool reports, and files delivered with `MEDIA:`.
enum ArtifactScanner {
    // MARK: Patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let markdownImage = regex(#"!\[([^\]]*)\]\(([^)\s]+)\)"#)
    private static let markdownLink = regex(#"\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let urlPattern = regex(#"https?://[^\s<>"')`]+"#)
    private static let pathPattern = regex(#"(^|[\s("'`])((?:/|~[\\/]|\.\.?[\\/]|\\\\)[^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)"#,
                                           .caseInsensitive)
    private static let windowsPathPattern = regex(#"(^|[\s("'`])([A-Za-z]:[\\/][^\s"'`<>]+(?:\.[a-z0-9]{1,8})?)"#,
                                                  .caseInsensitive)
    private static let imageExtension = regex(#"\.(?:png|jpe?g|gif|webp|svg|bmp)(?:\?.*)?$"#, .caseInsensitive)
    private static let fileExtension = regex(
        #"\.(?:png|jpe?g|gif|webp|svg|bmp|pdf|txt|json|md|csv|xlsx?|docx?|pptx?|html|zip|tar|gz|avi|flac|m4a|mkv|mp3|ogg|opus|wav|webm|mp4|mov)(?:\?.*)?$"#,
        .caseInsensitive)
    private static let producerTool = regex(
        #"(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write)(?:_|$)"#, .caseInsensitive)
    private static let strongKey = regex(
        #"^(?:artifact_(?:file|image|path|url)|files?_(?:created|modified|written)|generated_(?:file|image|path|url)|media_tag|output_(?:file|path|url)|result_(?:file|path|url)|saved_to|screenshot_path)$"#,
        .caseInsensitive)
    private static let producerKey = regex(
        #"^(?:artifact(?:s|_(?:file|image|path|url))?|attachment(?:s|_(?:file|image|path|url))?|download(?:s|_(?:file|path|url))?|(?:audio|image|video)(?:_(?:file|path|url))?|file_path|local_path|media(?:_(?:file|path|url))?|path)$"#,
        .caseInsensitive)
    private static let shellOutputKey = regex(#"^(?:output|stdout|path)$"#, .caseInsensitive)
    private static let screenshotPath = regex(#"Screenshot path:\s*([^\r\n<>]+)"#, .caseInsensitive)
    private static let pipCacheDir = regex(#"/(?:\.cache/pip|library/caches/pip|appdata/local/pip/cache)/"#)
    private static let wheel = regex(#"\.whl(?:\.metadata)?$"#)
    private static let packageIndexDist = regex(#"/packages/.+\.(?:tar\.gz|tar\.bz2|zip|egg)(?:\.metadata)?$"#)
    private static let untrustedOpen = regex(#"^<untrusted_tool_result\b[^>]*>\s*"#)

    /// `MEDIA_DELIVERY_EXTS` (`lib/chat-messages/parts.ts`), longest first.
    private static let mediaExtensions = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "svg", "mp4", "mov", "avi", "mkv", "webm", "3gp", "mp3",
        "m2a", "wav", "ogg", "opus", "m4a", "flac", "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub", "xlsx",
        "xls", "ods", "csv", "tsv", "json", "xml", "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp",
        "key", "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "apk", "ipa", "html", "htm",
    ].sorted { $0.count > $1.count }

    /// `MEDIA_TAG_RE`: a quoted value, an anchored path ending in a deliverable extension (spaces allowed), or a bare
    /// word.
    private static let mediaTag: NSRegularExpression = {
        let anchored = #"(?:~/|/|[A-Za-z]:[/\\])\S+?(?:[^\S\n]+\S+?)*?\.(?:"# + mediaExtensions.joined(separator: "|")
            + #")(?=[\s`"'*_,;:)\]}]|MEDIA:|$)"#
        let bare = #"[^\s`"]+"#
        return regex(#"[`"']?MEDIA:\s*(`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|"# + anchored + "|" + bare + #")[`"']?"#)
    }()

    private static let quotes: Set<Character> = ["\"", "'", "`"]

    // MARK: Matching helpers

    private static func test(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Each match's capture `group`, in order.
    private static func captures(_ pattern: NSRegularExpression, _ text: String, group: Int) -> [(value: String, start: String.Index)] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text) else { return nil }
            let range = match.range(at: group)
            guard range.location != NSNotFound, let value = Range(range, in: text) else { return ("", whole.lowerBound) }
            return (String(text[value]), whole.lowerBound)
        }
    }

    /// A host path: `file:`, absolute, home- or dot-relative, a drive letter or UNC (`isArtifactFilePath`).
    static func isFilePath(_ value: String) -> Bool {
        value.range(of: #"^(?:file:|/|[~.][\\/]|\.\.[\\/]|[a-z]:[\\/]|\\\\)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The path a request names: a `file://` URL as its path, anything else as is (`filePathFromMediaPath`).
    static func hostPath(_ value: String) -> String {
        guard value.lowercased().hasPrefix("file:") else { return value }
        if let url = URL(string: value), url.isFileURL { return url.path }
        return value.replacingOccurrences(of: "^file://", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// The lowercased extension of a path or URL, before any query or fragment.
    static func pathExtension(_ value: String) -> String {
        let path = value.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? value
        let name = (path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path).lowercased()
        if name == "dockerfile" { return name }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private static func isPathOrURL(_ value: String) -> Bool {
        value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") || isFilePath(value)
    }

    private static func filteringPath(_ value: String) -> String {
        if value.range(of: #"^(?:https?|file)://"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let components = URLComponents(string: value) {
            return (components.path.removingPercentEncoding ?? components.path).lowercased()
        }
        return value.replacingOccurrences(of: "\\", with: "/").lowercased()
    }

    /// pip's own traffic, not session output: wheel downloads and its cache dir.
    static func isPythonPackageDownload(_ value: String) -> Bool {
        let path = filteringPath(value)
        return test(pipCacheDir, path) || test(wheel, path)
            || (value.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil && test(packageIndexDist, path))
    }

    /// Worth listing: a URL or inline image, or a path with a known file extension. An explicit delivery (a `MEDIA:`
    /// tag) is listed whatever its extension (`looksLikeArtifact`).
    static func looksLikeArtifact(_ value: String, explicit: Bool = false) -> Bool {
        if !explicit, isPythonPackageDownload(value) { return false }
        if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("data:image/") { return true }
        guard isPathOrURL(value) else { return false }
        if explicit { return true }
        return test(imageExtension, value) || test(fileExtension, value)
    }

    static func kind(_ value: String) -> ArtifactKind {
        if value.hasPrefix("data:image/") || test(imageExtension, value) { return .image }
        return isFilePath(value) ? .file : .link
    }

    /// The last path segment of a URL or path.
    static func label(_ value: String) -> String {
        if value.hasPrefix("data:") { return "image" }
        if value.range(of: #"^(?:https?|file)://"#, options: [.regularExpression, .caseInsensitive]) != nil,
           let components = URLComponents(string: value) {
            let last = components.path.split(separator: "/").last.map(String.init)
            return (last?.removingPercentEncoding ?? last) ?? components.host ?? value
        }
        return value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? value
    }

    /// Strips wrapping quotes (three deep), then trailing markdown emphasis and prose punctuation (`normalizeValue`).
    static func normalize(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            guard trimmed.count >= 2, let first = trimmed.first, quotes.contains(first), trimmed.last == first else { break }
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = trimmed.replacingOccurrences(of: #"[`*]+$"#, with: "", options: .regularExpression)
        return trimmed.replacingOccurrences(of: #"[),.;]+$"#, with: "", options: .regularExpression)
    }

    /// Chat renders file refs as `[label](#media:<encoded path>)`: the path, not the href.
    static func decodeMediaHref(_ value: String) -> String {
        guard value.hasPrefix("#media:") else { return value }
        return String(value.dropFirst("#media:".count)).removingPercentEncoding ?? value
    }

    // MARK: MEDIA tags

    private static func unquoteMediaValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, let first = trimmed.first, quotes.contains(first), trimmed.last == first {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed.replacingOccurrences(of: #"[`"'*_]{1,3}$"#, with: "", options: .regularExpression)
    }

    private static func unquoteMediaPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, let first = trimmed.first, quotes.contains(first), trimmed.last == first {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed.last == "`" || trimmed.last == "\"" ? String(trimmed.dropLast()) : trimmed
    }

    private static func isPlausibleMediaPath(_ value: String) -> Bool {
        value.contains("/") || value.contains("\\") || value.range(of: #"\.[^.]"#, options: .regularExpression) != nil
    }

    /// Raw `MEDIA:` values, quotes intact; a bare capture sheds the sentence punctuation after it (`mediaTagValues`).
    static func mediaTagValues(_ text: String) -> [String] {
        guard text.contains("MEDIA:") else { return [] }
        return captures(mediaTag, text, group: 1).compactMap { capture in
            let value = capture.value
            var path = unquoteMediaPath(value)
            var punctuation = 0
            while let last = path.last, ".,;:!?".contains(last), isPlausibleMediaPath(String(path.dropLast())) {
                path.removeLast()
                punctuation += 1
            }
            guard isPlausibleMediaPath(path) else { return nil }
            return punctuation > 0 ? String(value.dropLast(punctuation)) : value
        }
    }

    // MARK: Transcript scan

    typealias Push = (_ value: String, _ explicit: Bool) -> Void

    private static func collectMediaValues(_ text: String, _ push: Push) {
        for value in mediaTagValues(text) { push(unquoteMediaValue(value), true) }
    }

    /// MEDIA tags, markdown images and links, URLs and absolute paths in prose.
    static func collectFromText(_ text: String, _ push: Push) {
        collectMediaValues(text, push)
        for capture in captures(markdownImage, text, group: 2) { push(capture.value, false) }
        for capture in captures(markdownLink, text, group: 2) {
            if capture.start > text.startIndex, text[text.index(before: capture.start)] == "!" { continue }
            let value = decodeMediaHref(capture.value)
            if looksLikeArtifact(value) { push(value, false) }
        }
        for capture in captures(urlPattern, text, group: 0) where looksLikeArtifact(capture.value) {
            push(capture.value, false)
        }
        for capture in captures(pathPattern, text, group: 2) { push(capture.value, false) }
        for capture in captures(windowsPathPattern, text, group: 2) { push(capture.value, false) }
    }

    private static func messageText(_ message: JSON) -> String {
        for key in ["content", "text", "context"] {
            if let text = message[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return ""
    }

    private static func parseJSON(_ text: String) -> Any? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// The payload inside an `<untrusted_tool_result>` wrapper, after its preamble paragraph.
    static func untrustedToolPayload(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = untrustedOpen.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let openRange = Range(open.range, in: trimmed),
              let close = trimmed.range(of: "</untrusted_tool_result>", options: .backwards),
              close.lowerBound > openRange.upperBound else { return nil }
        let wrapped = trimmed[openRange.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = wrapped.range(of: "\n\n") else { return wrapped }
        return wrapped[start.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func toolPayloads(_ text: String) -> [Any] {
        [text, untrustedToolPayload(text)].compactMap { $0 }.compactMap(parseJSON)
    }

    private static func structuredPayload(_ message: JSON) -> Any? {
        if let object = message["content"] as? JSON {
            return LenientField.bool(object["_multimodal"]) ? object["meta"] : object
        }
        return message["content"] as? [Any]
    }

    private static func collectStrings(_ value: Any, keyPath: String, _ collector: (String, String) -> Void) {
        if let string = value as? String {
            collector(string, keyPath)
        } else if let array = value as? [Any] {
            for (index, entry) in array.enumerated() { collectStrings(entry, keyPath: "\(keyPath).\(index)", collector) }
        } else if let object = value as? JSON {
            // JSON objects come unordered from JSONSerialization; sorting keeps the scan deterministic.
            for key in object.keys.sorted() {
                collectStrings(object[key]!, keyPath: keyPath.isEmpty ? key : "\(keyPath).\(key)", collector)
            }
        }
    }

    private static func keySegments(_ keyPath: String) -> [String] {
        keyPath.split(separator: ".").map(String.init).filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
    }

    /// A tool-result key that names an output (`explicitToolArtifactKey`).
    static func isArtifactKey(_ keyPath: String, producerTool: Bool) -> Bool {
        keySegments(keyPath).contains { segment in
            test(strongKey, segment) || (producerTool && test(producerKey, segment))
        }
    }

    static func isProducerTool(_ name: String) -> Bool {
        test(producerTool, name) || name.hasPrefix("bfl_flux3_")
    }

    private static func collectFromMessage(_ message: JSON, _ push: Push) {
        let role = message["role"] as? String
        let text = messageText(message)
        if role == "assistant", !text.isEmpty {
            collectFromText(text, push)
            return
        }
        guard role == "tool" else { return }
        let name = ((message["tool_name"] as? String) ?? (message["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let producer = isProducerTool(name)
        let terminal = name == "terminal"
        if !text.isEmpty, producer || terminal { collectFromText(text, push) }
        if name == "browser_vision", !text.isEmpty {
            for capture in captures(screenshotPath, text, group: 1) { push(capture.value, false) }
        }
        var payloads = toolPayloads(text)
        if let structured = structuredPayload(message) { payloads.append(structured) }
        for payload in payloads {
            collectStrings(payload, keyPath: "tool_result") { value, keyPath in
                let shellOutput = terminal && keySegments(keyPath).contains { test(shellOutputKey, $0) }
                guard shellOutput || isArtifactKey(keyPath, producerTool: producer) else { return }
                if shellOutput {
                    // Free text: scanned like prose, so only values with a file extension or a URL scheme survive.
                    if !value.isEmpty { collectFromText(value, push) }
                    return
                }
                collectMediaValues(value, push)
                let normalized = normalize(decodeMediaHref(value))
                if !normalized.isEmpty, looksLikeArtifact(normalized) { push(normalized, false) }
            }
        }
    }

    /// The session's artifacts in transcript order, one per value.
    static func collect(session: SessionInfo, messages: [JSON], now: Date = Date()) -> [ArtifactRecord] {
        var found: [ArtifactRecord] = []
        var seen = Set<String>()
        let title = session.title ?? session.preview ?? "Untitled session"
        for message in messages {
            guard let role = message["role"] as? String, role == "assistant" || role == "tool" else { continue }
            collectFromMessage(message) { candidate, explicit in
                let value = normalize(decodeMediaHref(candidate))
                guard !value.isEmpty, looksLikeArtifact(value, explicit: explicit) else { return }
                let key = "\(session.id):\(value)"
                guard seen.insert(key).inserted else { return }
                found.append(ArtifactRecord(id: key, kind: kind(value), value: value, label: label(value),
                                            sessionID: session.id, profile: session.profile, sessionTitle: title,
                                            timestamp: timestamp(message, session: session, now: now)))
            }
        }
        return found
    }

    /// Epoch seconds become dates; values past the plausible seconds range are already milliseconds. A missing or
    /// invalid stamp falls back to the session's activity, then its start, then now.
    static func timestamp(_ message: JSON, session: SessionInfo, now: Date = Date()) -> Date {
        if let number = message["timestamp"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let value = number.doubleValue
            if value.isFinite, value > 0 {
                return Date(timeIntervalSince1970: value < 10_000_000_000 ? value : value / 1000)
            }
        }
        return session.lastActive ?? session.startedAt ?? now
    }
}

/// Indexes recent sessions one transcript page at a time (`loadArtifactsForSessions`), so no whole transcript stays
/// in memory. A session whose page can't be read, or is too large to hold on a phone, is skipped and counted.
struct ArtifactIndex {
    static let pageSize = 100
    /// A transcript page past this is skipped rather than parsed.
    static let maxPageBytes = 16 * 1024 * 1024

    struct Result {
        var artifacts: [ArtifactRecord]
        var skipped: Int
        var tooLarge: Int
    }

    /// `loadPage(session, offset)` answers one page's rows and the page size the host applied (nil on a host that
    /// ignores paging and sends everything).
    static func load(_ sessions: [SessionInfo],
                     loadPage: (SessionInfo, Int) async throws -> (rows: [JSON], limit: Int?)) async -> Result {
        var artifacts: [ArtifactRecord] = []
        var skipped = 0, tooLarge = 0
        for session in sessions {
            do {
                var offset = 0
                var found: [ArtifactRecord] = []
                var seen = Set<String>()
                while true {
                    try Task.checkCancellation()
                    let page = try await loadPage(session, offset)
                    // The first sighting of a value wins.
                    for artifact in ArtifactScanner.collect(session: session, messages: page.rows) {
                        if seen.insert(artifact.id).inserted { found.append(artifact) }
                    }
                    guard let limit = page.limit, !page.rows.isEmpty, page.rows.count >= limit else { break }
                    offset += page.rows.count
                }
                artifacts += found
            } catch is CancellationError {
                break
            } catch ArtifactIndexError.pageTooLarge {
                skipped += 1
                tooLarge += 1
            } catch {
                skipped += 1
            }
        }
        return Result(artifacts: artifacts.sorted { $0.timestamp > $1.timestamp }, skipped: skipped, tooLarge: tooLarge)
    }
}

enum ArtifactIndexError: Error {
    case pageTooLarge
}

/// A text file read through the host (`GET /api/fs/read-text`).
struct HostTextFile: Hashable {
    var text: String
    var language: String
    var binary: Bool
    var truncated: Bool
    var byteSize: Int

    init(response: JSON) {
        text = response["text"] as? String ?? ""
        language = LenientField.text(response["language"]) ?? "text"
        binary = LenientField.bool(response["binary"])
        truncated = LenientField.bool(response["truncated"])
        byteSize = max(0, LenientField.int(response["byteSize"]))
    }
}

extension DashboardClient {
    /// The 30 most recently active sessions with messages, across `profile` ("all" spans every profile).
    func artifactSessions(profile: String = SidebarOptions.allProfiles, limit: Int = 30) async throws -> [SessionInfo] {
        try await profileSessions(profile: profile, limit: limit, minMessages: 1).rows
    }

    /// One oldest-first transcript page. Stored images come as `[image]` placeholders (`inline_images=false`): a
    /// phone indexes kilobytes instead of every attachment. A page over `ArtifactIndex.maxPageBytes` throws.
    func artifactMessagePage(_ session: SessionInfo, offset: Int, limit: Int = ArtifactIndex.pageSize) async throws
        -> (rows: [JSON], limit: Int?) {
        var query = ["limit": "\(limit)", "offset": "\(max(0, offset))", "order": "oldest", "include_compacted": "true",
                     "inline_images": "false"]
        if let profile = session.profile { query["profile"] = profile }
        let data = try await opsData("/api/sessions/\(try Self.segment(session.id))/messages", query: query, timeout: 60)
        guard data.count <= ArtifactIndex.maxPageBytes else { throw ArtifactIndexError.pageTooLarge }
        let object = try JSONSerialization.jsonObject(with: data)
        if let rows = object as? [JSON] { return (rows, nil) }
        let page = object as? JSON ?? [:]
        let rows = (page["messages"] ?? page["data"]) as? [JSON] ?? []
        return (rows, LenientField.optionalInt((page["pagination"] as? JSON)?["limit"]))
    }

    /// An image on the host as bytes (`GET /api/fs/read-data-url`, capped by the host).
    func hostImageData(_ artifact: ArtifactRecord) async throws -> Data {
        let result = try await request("GET", "/api/fs/read-data-url", query: Self.fileQuery(artifact)) as? JSON
        guard let dataURL = result?["dataUrl"] as? String ?? result?["data_url"] as? String,
              let data = Self.decodeDataURL(dataURL) else { throw DashboardError.rpc("Hermes didn't send \(artifact.label).") }
        return data
    }

    /// A text file on the host (`GET /api/fs/read-text`).
    func hostTextFile(_ artifact: ArtifactRecord) async throws -> HostTextFile {
        var query = ["path": artifact.hostPath]
        if let profile = artifact.profile { query["profile"] = profile }
        return HostTextFile(response: try await request("GET", "/api/fs/read-text", query: query) as? JSON ?? [:])
    }

    /// The whole file from the host (`GET /api/fs/download`), written to a temporary file to share or preview.
    func downloadHostFile(_ artifact: ArtifactRecord) async throws -> URL {
        let data = try await opsData("/api/fs/download", query: Self.fileQuery(artifact), timeout: 600)
        return try Self.temporaryFile(data, name: artifact.label)
    }

    /// Path, owning profile and session, so the host resolves a relative path against the session's folder.
    static func fileQuery(_ artifact: ArtifactRecord) -> [String: String] {
        var query = ["path": artifact.hostPath, "session_id": artifact.sessionID]
        if let profile = artifact.profile { query["profile"] = profile }
        return query
    }

    /// The bytes of a `data:` URL (base64 or percent-encoded).
    static func decodeDataURL(_ value: String) -> Data? {
        guard value.hasPrefix("data:"), let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[value.index(value.startIndex, offsetBy: 5)..<comma]
        let payload = String(value[value.index(after: comma)...])
        if header.hasSuffix(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
        return payload.removingPercentEncoding.map { Data($0.utf8) }
    }
}
