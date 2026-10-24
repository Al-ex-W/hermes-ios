import Foundation

typealias JSON = [String: Any]

enum DashboardError: LocalizedError {
    case badURL
    case signedOut
    case http(Int, String)
    case rpc(String)
    /// The socket dropped before Hermes answered; the request may or may not have arrived.
    case disconnected
    /// Hermes didn't answer in time; the request may or may not have arrived.
    case timeout
    /// The request never left the phone (no socket, or the write failed), so sending it again is safe.
    case notSent(Error)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The dashboard address isn't a valid URL."
        case .signedOut: return "Signed out of the Hermes dashboard. Check the username and password."
        case let .http(code, body): return "Dashboard returned \(code). \(body.prefix(160))"
        case let .rpc(message): return message
        case .disconnected: return "Lost the connection to Hermes."
        case .timeout: return "Hermes didn't answer in time."
        case let .notSent(error): return error.localizedDescription
        }
    }
}

extension Error {
    /// A cancelled task or request: nothing to report.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }

    /// The request never reached Hermes, so it can be sent again without a duplicate.
    var wasNotSent: Bool {
        if case .notSent? = self as? DashboardError { return true }
        return false
    }

    /// The connection failed under the call (never sent, dropped, or no answer in time), not Hermes.
    var isConnectionLoss: Bool {
        switch self as? DashboardError {
        case .disconnected?, .timeout?, .notSent?: return true
        default: return false
        }
    }

    /// Hermes or the dashboard answered with a refusal, so sending the same request again won't help.
    /// A 5xx (Tailscale Serve answers 502 while the dashboard restarts), 408 or 429 is worth retrying.
    /// A gateway error answer, or a result outside the contract, is one too.
    var isRefusal: Bool {
        if self is GatewayRPCError || self is GatewayDecodingError { return true }
        switch self as? DashboardError {
        case .badURL?, .signedOut?, .rpc?: return true
        case let .http(code, _)?: return (400..<500).contains(code) && code != 408 && code != 429
        case let .notSent(inner)?: return inner.isRefusal
        default: return false
        }
    }
}

struct SessionSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let lastActive: Date?
    /// The profile whose store holds the session (the list spans every profile on the host).
    let profile: String?
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, tool, system }
    let id: String
    var role: Role
    var text: String
}

/// REST side of the Hermes dashboard (port 9119): cookie sign-in, sessions, messages, socket tickets.
final class DashboardClient {
    let base: URL
    private let username: String
    private let password: String
    let session: URLSession
    /// Set by signOut(): every later request fails instead of signing in again. Read from any task.
    private let closedLock = NSLock()
    private var closedFlag = false
    private var closed: Bool { closedLock.withLock { closedFlag } }

    init(settings: ConnectionSettings) throws {
        guard let base = settings.dashboardBase, base.scheme?.hasPrefix("http") == true else { throw DashboardError.badURL }
        self.base = base
        username = settings.username
        password = settings.password
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    private var origin: String {
        var value = "\(base.scheme ?? "https")://\(base.host ?? "")"
        if let port = base.port { value += ":\(port)" }
        return value
    }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = (components.path.trimmingSuffix("/")) + path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    func signIn() async throws {
        guard !closed else { throw DashboardError.signedOut }
        var request = URLRequest(url: url("/auth/password-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["provider": "basic", "username": username, "password": password])
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw DashboardError.signedOut }
        guard (200..<300).contains(code) else { throw DashboardError.http(code, String(decoding: data, as: UTF8.self)) }
    }

    /// Ends this client for good, at once: later requests fail, and the dashboard's cookies leave the shared jar
    /// before this returns, so no session outlives the sign-out on disk and a quick re-sign-in keeps its own.
    /// Then a best-effort POST /auth/logout, carrying the removed cookies itself, ends the session on the dashboard.
    func signOut() {
        closedLock.withLock { closedFlag = true }
        let request = url("/auth/logout")
        let storage = HTTPCookieStorage.shared
        let sent = storage.cookies(for: request) ?? []
        if let host = base.host?.lowercased() {
            for cookie in storage.cookies ?? [] {
                var domain = cookie.domain.lowercased()
                if domain.hasPrefix(".") { domain.removeFirst() }
                if host == domain || host.hasSuffix(".\(domain)") { storage.deleteCookie(cookie) }
            }
        }
        guard !sent.isEmpty else { return }
        var logout = URLRequest(url: request)
        logout.httpMethod = "POST"
        logout.timeoutInterval = 5
        // Cookies go in by hand and the answer's are ignored, so the shared jar is never touched again.
        logout.httpShouldHandleCookies = false
        logout.setValue(origin, forHTTPHeaderField: "Origin")
        for (field, value) in HTTPCookie.requestHeaderFields(with: sent) { logout.setValue(value, forHTTPHeaderField: field) }
        let session = session
        Task.detached { _ = try? await session.data(for: logout) }
    }

    /// Sends a request, signing in once and retrying if the dashboard says the cookie is gone.
    func request(_ method: String, _ path: String, query: [String: String] = [:], body: JSON? = nil) async throws -> Any {
        for attempt in 0..<2 {
            guard !closed else { throw DashboardError.signedOut }
            var request = URLRequest(url: url(path, query: query))
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if method != "GET" { request.setValue(origin, forHTTPHeaderField: "Origin") }
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
            return data.isEmpty ? JSON() : try JSONSerialization.jsonObject(with: data)
        }
        throw DashboardError.signedOut
    }

    func webSocketTicket() async throws -> String {
        let result = try await request("POST", "/api/auth/ws-ticket") as? JSON
        guard let ticket = result?["ticket"] as? String else { throw DashboardError.rpc("No WebSocket ticket from the dashboard.") }
        return ticket
    }

    func sessions() async throws -> [SessionSummary] {
        let result = try await request("GET", "/api/profiles/sessions", query: [
            "limit": "100", "offset": "0", "min_messages": "1", "archived": "exclude",
            "order": "recent", "exclude_sources": "cron",
        ]) as? JSON
        let rows = result?["sessions"] as? [JSON] ?? []
        return rows.compactMap { row in
            if (row["hidden"] as? Bool) == true { return nil }
            guard let id = (row["id"] ?? row["session_id"]).flatMap(Self.string) else { return nil }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (row["preview"] as? String) ?? "Untitled"
            let stamp = ["last_active", "updated_at", "last_message_at", "created_at"].lazy.compactMap { row[$0] }.first
            let profile = (row["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return SessionSummary(id: id, title: title, lastActive: stamp.flatMap(Self.date), profile: profile)
        }
    }

    /// The stored transcript, oldest first. `profile` picks the store; nil reads the dashboard's own.
    func messages(sessionID: String, profile: String? = nil) async throws -> [ChatMessage] {
        let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
        var query = ["limit": "200", "offset": "0", "order": "latest", "include_compacted": "true", "inline_images": "false"]
        if let profile { query["profile"] = profile }
        let result = try await request("GET", "/api/sessions/\(encoded)/messages", query: query) as? JSON
        var rows = (result?["messages"] ?? result?["data"]) as? [JSON] ?? []
        if let first = rows.first?["id"] as? Int, let last = rows.last?["id"] as? Int, first > last { rows.reverse() }
        return rows.flatMap(Self.message)
    }

    /// One stored row as chat rows: its text, then for an assistant row one tool row per tool call,
    /// so "🔊 …" rows (what Hermes said out loud) survive reopening the chat.
    static func message(_ row: JSON) -> [ChatMessage] {
        if (row["display_kind"] as? String) == "hidden" { return [] }
        guard let role = (row["role"] as? String).flatMap(ChatMessage.Role.init(rawValue:)), role != .system, role != .tool else { return [] }
        let id = string(row["id"] as Any) ?? UUID().uuidString
        let text = (row["display_content"] as? String) ?? text(from: row["content"])
        var result: [ChatMessage] = []
        if !text.isEmpty { result.append(ChatMessage(id: id, role: role, text: text)) }
        if role == .assistant, let calls = row["tool_calls"] as? [JSON] {
            for (index, call) in calls.enumerated() {
                let function = call["function"] as? JSON ?? [:]
                var payload: JSON = [:]
                payload["name"] = function["name"]
                payload["arguments"] = function["arguments"]
                guard let line = ChatModel.toolRow(payload) else { continue }
                result.append(ChatMessage(id: "\(id)-tool-\(index)", role: .tool, text: line))
            }
        }
        return result
    }

    static func text(from content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [JSON] { return parts.compactMap { $0["text"] as? String }.joined() }
        return ""
    }

    static func string(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// Epoch timestamps arrive in s, ms, µs or ns; ISO strings also occur.
    static func date(_ value: Any) -> Date? {
        if var seconds = (value as? NSNumber)?.doubleValue {
            while seconds > 1e11 { seconds /= 1000 }
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }
}
