import Foundation

// The workspace's file routes: `/api/fs/*`, the session's folder on the host (profile- and SSH-aware, the desktop's
// remote file tree). The `/api/files/*` writes (new folder, upload, delete) aren't used: they act on the dashboard's
// own disk whatever the profile's backend, and the desktop offers none of them on a remote backend.

// MARK: - Transport

/// Query strings for the workspace routes, each value encoded exactly once and strictly: everything but the RFC 3986
/// unreserved characters is percent-encoded. `URLQueryItem` leaves `+` alone, which the dashboard reads as a space,
/// so a file called `a+b.txt` would arrive as `a b.txt`.
enum WorkspaceQuery {
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `name=value` pairs in order; a nil value is left out.
    static func string(_ items: [(String, String?)]) -> String {
        items.compactMap { name, value in value.map { "\(encode(name))=\(encode($0))" } }.joined(separator: "&")
    }

    static func url(base: URL, route: String, query: [(String, String?)]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = components.path.trimmingSuffix("/") + route
        let query = string(query)
        components.percentEncodedQuery = query.isEmpty ? nil : query
        return components.url
    }
}

/// One request to a workspace route: method, route, query and JSON body. Built by `WorkspaceCalls` and `GitCalls`
/// so tests can read exactly what goes out.
struct WorkspaceCall {
    var method = "GET"
    var route: String
    var query: [(String, String?)] = []
    var body: JSON?
    /// Git and gh can take a while (fetch, push, `gh pr create`); reads answer quickly.
    var timeout: TimeInterval = 30

    func url(base: URL) -> URL? { WorkspaceQuery.url(base: base, route: route, query: query) }

    /// The body as sorted JSON text.
    var bodyText: String? {
        guard let body, let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension DashboardClient {
    /// Sends `call`, signing in once if the cookie is gone; the parsed JSON answer.
    func workspace(_ call: WorkspaceCall) async throws -> Any {
        let data = try await workspaceData(call)
        return data.isEmpty ? JSON() : try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// The raw answer to `call`.
    func workspaceData(_ call: WorkspaceCall) async throws -> Data {
        guard let url = call.url(base: base) else { throw DashboardError.badURL }
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.httpMethod = call.method
            request.timeoutInterval = call.timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if call.method != "GET" { request.setValue(Self.origin(of: base), forHTTPHeaderField: "Origin") }
            if let body = call.body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 || code == 403 && Self.isAuthRefusal(data) || isSignInRedirect(http, for: request) {
                if attempt == 0 { try await signIn(); continue }
                throw DashboardError.signedOut
            }
            guard (200..<300).contains(code) else { throw DashboardError.http(code, String(decoding: data, as: UTF8.self)) }
            return data
        }
        throw DashboardError.signedOut
    }

    /// A 403 from the file routes is usually a refusal about the file ("Access to sensitive files is not allowed"),
    /// not a lost session: only a bare or auth-worded 403 signs in again.
    static func isAuthRefusal(_ body: Data) -> Bool {
        guard let detail = DashboardDetail.message(String(decoding: body, as: UTF8.self)) else { return true }
        let lowered = detail.lowercased()
        return ["unauthorized", "not authenticated", "forbidden", "token", "login", "csrf", "origin"].contains { lowered.contains($0) }
    }

    /// Downloads `call` to a temporary file named `name` (the share-sheet folder `removeTemporaryFile` cleans up).
    /// The bytes go straight to disk, so a large file never sits in memory.
    func workspaceDownload(_ call: WorkspaceCall, name: String) async throws -> URL {
        guard let url = call.url(base: base) else { throw DashboardError.badURL }
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = call.timeout
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code == 401 || isSignInRedirect(http, for: request) {
                if attempt == 0 { try await signIn(); continue }
                throw DashboardError.signedOut
            }
            guard (200..<300).contains(code) else {
                let body = (try? Data(contentsOf: temporary)).map { String(decoding: $0.prefix(4096), as: UTF8.self) } ?? ""
                throw DashboardError.http(code, body)
            }
            return try Self.moveToShareFolder(temporary, name: name)
        }
        throw DashboardError.signedOut
    }

    /// Moves a downloaded file into a fresh `hermes-share-` folder under `name` (path components stripped).
    static func moveToShareFolder(_ file: URL, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(WorkspacePath.safeFileName(name))
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

/// The host's caps, mirrored so the phone says so before sending.
enum WorkspaceLimits {
    /// `_FS_TEXT_PREVIEW_MAX_BYTES`: `/api/fs/read-text` sends at most this much of a file.
    static let previewBytes = 512 * 1024
    /// `_FS_DATA_URL_MAX_BYTES` (`WEBAPP_ATTACHMENT_MAX_BYTES`): the largest image `/api/fs/read-data-url` sends.
    static let imageBytes = 16 * 1024 * 1024
    /// Source lines the preview lays out; the rest is a share away.
    static let previewLines = 20_000
    /// Diff rows the review lays out.
    static let diffLines = 20_000
}

// MARK: - Requests

enum WorkspaceCalls {
    static func profiled(_ query: [(String, String?)], profile: String?) -> [(String, String?)] {
        query + [("profile", WorkspacePath.nonBlank(profile))]
    }

    /// A folder's entries (`GET /api/fs/list`): noise folders (.git, node_modules, build …) and credential files
    /// are left out by the host.
    static func list(_ path: String, profile: String?) -> WorkspaceCall {
        WorkspaceCall(route: "/api/fs/list", query: profiled([("path", path)], profile: profile))
    }

    /// A text file's first 512 KB, its language and whether it looks binary (`GET /api/fs/read-text`).
    static func readText(_ path: String, profile: String?) -> WorkspaceCall {
        WorkspaceCall(route: "/api/fs/read-text", query: profiled([("path", path)], profile: profile))
    }

    /// A file as a `data:` URL, up to 16 MB (`GET /api/fs/read-data-url`).
    static func readDataURL(_ path: String, profile: String?, sessionID: String?) -> WorkspaceCall {
        WorkspaceCall(route: "/api/fs/read-data-url",
                      query: profiled([("path", path)], profile: profile) + [("session_id", WorkspacePath.nonBlank(sessionID))], timeout: 120)
    }

    /// The whole file as an attachment (`GET /api/fs/download`).
    static func download(_ path: String, profile: String?, sessionID: String?) -> WorkspaceCall {
        WorkspaceCall(route: "/api/fs/download",
                      query: profiled([("path", path)], profile: profile) + [("session_id", WorkspacePath.nonBlank(sessionID))], timeout: 600)
    }

    /// The repository root holding `path`, or null (`GET /api/fs/git-root`).
    static func gitRoot(_ path: String, profile: String?) -> WorkspaceCall {
        WorkspaceCall(route: "/api/fs/git-root", query: profiled([("path", path)], profile: profile))
    }

    /// The folder a new session of the profile starts in, and its branch (`GET /api/fs/default-cwd`).
    static func defaultCwd(profile: String?) -> WorkspaceCall {
        WorkspaceCall(route: "/api/fs/default-cwd", query: profiled([], profile: profile))
    }
}

// MARK: - Answers

/// One row of `GET /api/fs/list` (`HermesReadDirEntry`).
struct WorkspaceEntry: Identifiable, Hashable {
    let name: String
    /// Absolute path on the host.
    let path: String
    let isDirectory: Bool

    var id: String { path }

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    init?(row: JSON) {
        guard let path = row["path"] as? String, !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.path = path
        name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? WorkspacePath.name(path)
        isDirectory = LenientField.bool(row["isDirectory"] ?? row["is_directory"])
    }
}

/// A folder listing. The host answers a failed read with an empty list and an errno-like code (`ENOENT`, `EACCES`).
struct WorkspaceListing: Hashable {
    var entries: [WorkspaceEntry]
    var error: String?

    init(entries: [WorkspaceEntry], error: String? = nil) {
        self.entries = entries
        self.error = error
    }

    init(response: JSON) {
        entries = (response["entries"] as? [JSON] ?? []).compactMap(WorkspaceEntry.init(row:))
        error = LenientField.text(response["error"])
    }

    /// What a failed read means, in words.
    static func describe(_ code: String) -> String {
        switch code {
        case "ENOENT": return "The folder doesn't exist on the host."
        case "ENOTDIR": return "That path is a file, not a folder."
        case "EACCES": return "The host isn't allowed to read this folder."
        default: return code
        }
    }
}

/// `GET /api/fs/read-text` (`HermesReadFileTextResult`).
struct WorkspaceTextFile: Hashable {
    var text: String
    var language: String
    var binary: Bool
    var truncated: Bool
    var byteSize: Int
    var mimeType: String?
    var path: String?

    init(response: JSON) {
        text = response["text"] as? String ?? ""
        language = LenientField.text(response["language"]) ?? "text"
        binary = LenientField.bool(response["binary"])
        truncated = LenientField.bool(response["truncated"])
        byteSize = max(0, LenientField.int(response["byteSize"]))
        mimeType = LenientField.text(response["mimeType"])
        path = LenientField.text(response["path"])
    }
}

struct WorkspaceDefaultCwd: Hashable {
    var cwd: String
    var branch: String?

    init?(response: JSON) {
        guard let cwd = LenientField.text(response["cwd"]) else { return nil }
        self.cwd = cwd
        branch = LenientField.text(response["branch"])
    }
}

extension DashboardClient {
    func workspaceList(_ path: String, profile: String?) async throws -> WorkspaceListing {
        WorkspaceListing(response: try await workspace(WorkspaceCalls.list(path, profile: profile)) as? JSON ?? [:])
    }

    func workspaceReadText(_ path: String, profile: String?) async throws -> WorkspaceTextFile {
        WorkspaceTextFile(response: try await workspace(WorkspaceCalls.readText(path, profile: profile)) as? JSON ?? [:])
    }

    /// The file's bytes through `/api/fs/read-data-url` (images; capped at 16 MB by the host).
    func workspaceFileData(_ path: String, profile: String?, sessionID: String?) async throws -> Data {
        let result = try await workspace(WorkspaceCalls.readDataURL(path, profile: profile, sessionID: sessionID))
        let dataURL = (result as? JSON).flatMap { ($0["dataUrl"] ?? $0["data_url"]) as? String } ?? result as? String
        guard let dataURL, let data = Self.decodeDataURL(dataURL) else {
            throw DashboardError.rpc("Hermes didn't send \(WorkspacePath.name(path)).")
        }
        return data
    }

    /// The whole file in a temporary folder, to share or open.
    func workspaceDownloadFile(_ path: String, profile: String?, sessionID: String?) async throws -> URL {
        try await workspaceDownload(WorkspaceCalls.download(path, profile: profile, sessionID: sessionID), name: WorkspacePath.name(path))
    }

    func workspaceGitRoot(_ path: String, profile: String?) async throws -> String? {
        LenientField.text((try await workspace(WorkspaceCalls.gitRoot(path, profile: profile)) as? JSON)?["root"])
    }

    func workspaceDefaultCwd(profile: String?) async throws -> WorkspaceDefaultCwd? {
        WorkspaceDefaultCwd(response: try await workspace(WorkspaceCalls.defaultCwd(profile: profile)) as? JSON ?? [:])
    }
}

// MARK: - Paths

/// Host paths as the workspace handles them: absolute paths from the host, POSIX or Windows separators, never
/// re-encoded (the transport encodes once). A name the user types is one path component, so it can't climb out
/// of the folder it is created in.
enum WorkspacePath {
    struct Crumb: Hashable {
        var name: String
        var path: String
    }

    private static func isSeparator(_ character: Character) -> Bool { character == "/" || character == "\\" }

    /// The separator `path` uses (`\` for a Windows path without forward slashes).
    static func separator(of path: String) -> String {
        path.contains("\\") && !path.contains("/") ? "\\" : "/"
    }

    /// Trimmed, without trailing separators (a bare root stays as is).
    static func clean(_ path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.count > 1, let last = text.last, isSeparator(last) {
            if text.count == 3, text.dropLast().last == ":" { break } // "C:\"
            text.removeLast()
        }
        return text
    }

    /// The last component (the path itself when it has none).
    static func name(_ path: String) -> String {
        let cleaned = clean(path)
        return cleaned.split(whereSeparator: isSeparator).last.map(String.init) ?? cleaned
    }

    /// The containing folder, or nil at a root.
    static func parent(_ path: String) -> String? {
        let cleaned = clean(path)
        guard let index = cleaned.lastIndex(where: isSeparator) else { return nil }
        // A bare root ("/", "C:\\") has no parent.
        if cleaned.index(after: index) == cleaned.endIndex { return nil }
        let head = String(cleaned[..<index])
        if head.isEmpty { return String(cleaned[index]) }
        if head.count == 2, head.hasSuffix(":") { return head + String(cleaned[index]) }
        return head
    }

    /// A name the user typed for a new file or folder: one component, not `.` or `..`, no separators or NUL.
    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, trimmed != ".", trimmed != ".." else { return false }
        return !trimmed.contains(where: { isSeparator($0) || $0 == "\0" || $0.isNewline })
    }

    /// `dir` joined with one validated component; nil when `name` isn't one.
    static func join(_ dir: String, _ name: String) -> String? {
        guard isValidName(name) else { return nil }
        let base = clean(dir)
        if let last = base.last, isSeparator(last) { return base + name }
        return base + separator(of: base) + name
    }

    /// Path components for comparing: separators unified, empty and `.` parts dropped.
    private static func comparable(_ path: String) -> String {
        clean(path).replacingOccurrences(of: "\\", with: "/")
    }

    /// `path` relative to `root` ("" when they are the same, nil when outside it). A `..` component never
    /// counts as inside.
    static func relative(_ path: String, to root: String) -> String? {
        let rootKey = comparable(root), pathKey = comparable(path)
        guard !rootKey.isEmpty else { return nil }
        if pathKey == rootKey { return "" }
        let prefix = rootKey.hasSuffix("/") ? rootKey : rootKey + "/"
        guard pathKey.hasPrefix(prefix) else { return nil }
        let rest = String(pathKey.dropFirst(prefix.count))
        guard !rest.split(separator: "/").contains("..") else { return nil }
        return rest
    }

    static func isUnder(_ root: String, _ path: String) -> Bool { relative(path, to: root) != nil }

    /// The desktop's `contextPath`: relative to the session folder when inside it, else the path as is.
    static func contextPath(_ path: String, cwd: String?) -> String {
        guard let cwd = nonBlank(cwd) else { return path }
        let normalized = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return path.hasPrefix(normalized) ? String(path.dropFirst(normalized.count)) : path
    }

    /// The breadcrumb trail from `root` down to `path`. A path outside `root` trails from the filesystem root.
    static func crumbs(root: String, path: String) -> [Crumb] {
        let root = clean(root), path = clean(path)
        if let rest = relative(path, to: root) {
            var trail = [Crumb(name: name(root), path: root)]
            var current = root
            for part in rest.split(separator: "/") where !part.isEmpty {
                current = join(current, String(part)) ?? current
                trail.append(Crumb(name: String(part), path: current))
            }
            return trail
        }
        var trail: [Crumb] = []
        var current: String? = path
        while let at = current {
            trail.insert(Crumb(name: name(at), path: at), at: 0)
            current = parent(at)
        }
        return trail
    }

    /// What the composer gets for a file or folder: the desktop's `@file:` / `@folder:` ref, relative to the
    /// session's folder, quoted when it holds spaces or brackets.
    static func refText(path: String, isDirectory: Bool, cwd: String?) -> String {
        "@\(isDirectory ? "folder" : "file"):\(formatRefValue(contextPath(path, cwd: cwd)))"
    }

    /// The desktop's `formatRefValue`: bare when safe, else wrapped in the first quote it doesn't contain.
    static func formatRefValue(_ value: String) -> String {
        let special: Set<Character> = ["(", ")", "[", "]", "{", "}", "<", ">", "\"", "'", "`"]
        guard value.contains(where: { $0.isWhitespace || special.contains($0) }) else { return value }
        for quote in ["`", "\"", "'"] where !value.contains(quote) {
            return quote + value + quote
        }
        return value
    }

    /// nil when empty or only whitespace.
    static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A local file name for a host file: path components and NUL stripped.
    static func safeFileName(_ name: String) -> String {
        var safe = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "\0", with: "")
        if safe.isEmpty || safe == "." || safe == ".." || safe == "/" { safe = "file" }
        return safe
    }
}

