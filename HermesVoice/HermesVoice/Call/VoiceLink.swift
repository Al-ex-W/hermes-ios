import Foundation

/// The call's socket to the Hermes Voice server (`/phone`): announces the call, receives the
/// speech the `speak` tool streams, and confirms when each utterance has been heard.
@MainActor
final class VoiceLink {
    enum Incoming {
        case ready
        case speechStart(id: String, text: String, sampleRate: Double)
        case audio(Data)
        /// `cancelled` or `error`: the utterance won't finish and its queued audio should be dropped.
        case speechEnd(id: String, cancelled: Bool, error: String?)
        case closed(Close, Error?)
    }

    /// Why the socket went away.
    enum Close {
        /// The server rejected the token (close code 4401, or HTTP 401/403 on the handshake). Don't retry.
        case unauthorized
        /// The server didn't accept the hello (4400).
        case badHello
        /// A newer connection with the same call_id replaced this one (4409).
        case replaced
        /// Network drop or server restart: worth reconnecting.
        case dropped
    }

    /// What the `/status` preflight found wrong.
    enum ServerError: LocalizedError {
        case wrongToken
        case unreachable(String)
        case unexpected(Int)

        var errorDescription: String? {
            switch self {
            case .wrongToken:
                return "Wrong voice server token: the Hermes Voice server rejected it. Check the token in Settings."
            case let .unreachable(detail):
                return "Can't reach the Hermes Voice server (\(detail)). Check the address in Settings and that Tailscale is connected."
            case let .unexpected(status):
                return "The Hermes Voice server answered HTTP \(status). Check the address in Settings."
            }
        }
    }

    var onMessage: ((Incoming) -> Void)?
    private let url: URL
    private let token: String
    private let hello: JSON
    private var task: URLSessionWebSocketTask?
    private var keepalive: Timer?

    init(base: URL, token: String, callID: String, sessionID: String?, title: String) {
        url = Self.url(base, path: "phone", websocket: true)
        self.token = token
        var hello: JSON = ["type": "hello", "call_id": callID, "title": title]
        hello["session_id"] = sessionID
        self.hello = hello
    }

    /// Checks the address and token before a call starts: `GET /status` with the bearer token.
    static func preflight(base: URL, token: String) async throws {
        var request = URLRequest(url: url(base, path: "status", websocket: false), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServerError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return
        case 401, 403: throw ServerError.wrongToken
        default: throw ServerError.unexpected(status)
        }
    }

    /// `base` + `path`, with the scheme the transport needs (ws/wss for the socket, http/https otherwise).
    private static func url(_ base: URL, path: String, websocket: Bool) -> URL {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let secure = components.scheme == "https" || components.scheme == "wss"
        components.scheme = websocket ? (secure ? "wss" : "ws") : (secure ? "https" : "http")
        return components.url!
    }

    func connect() {
        close(sendBye: false)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        task = socket
        socket.resume()
        send(hello)
        receive(on: socket)
        keepalive = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.send(["type": "ping"]) }
        }
    }

    func close(sendBye: Bool = true) {
        keepalive?.invalidate()
        keepalive = nil
        guard let task else { return }
        if sendBye { send(["type": "bye"]) }
        self.task = nil
        task.cancel(with: .normalClosure, reason: nil)
    }

    func played(_ id: String) {
        send(["type": "played", "id": id])
    }

    private func send(_ object: JSON) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === socket else { return }
                switch result {
                case let .success(.data(data)):
                    self.onMessage?(.audio(data))
                case let .success(.string(text)):
                    self.handle(text)
                case let .failure(error):
                    let reason = Self.reason(socket)
                    self.close(sendBye: false)
                    self.onMessage?(.closed(reason, error))
                    return
                @unknown default:
                    break
                }
                self.receive(on: socket)
            }
        }
    }

    private static func reason(_ socket: URLSessionWebSocketTask) -> Close {
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        switch socket.closeCode.rawValue {
        case 4401: return .unauthorized
        case 4400: return .badHello
        case 4409: return .replaced
        default: return status == 401 || status == 403 ? .unauthorized : .dropped
        }
    }

    private func handle(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON else { return }
        let id = object["id"] as? String ?? ""
        switch object["type"] as? String {
        case "ready":
            onMessage?(.ready)
        case "speech_start":
            let rate = (object["sample_rate"] as? NSNumber)?.doubleValue ?? 24_000
            onMessage?(.speechStart(id: id, text: object["text"] as? String ?? "", sampleRate: rate))
        case "speech_end":
            let cancelled = (object["cancelled"] as? Bool) ?? false
            onMessage?(.speechEnd(id: id, cancelled: cancelled, error: object["error"] as? String))
        default:
            break
        }
    }
}
