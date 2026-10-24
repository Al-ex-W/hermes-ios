import Foundation

/// JSON-RPC 2.0 over the dashboard's `/api/ws?ticket=…` WebSocket: session.resume, prompt.submit, and the event stream.
/// A `gateway.ping` heartbeat and a deadline on every call catch a dead connection; the socket is then dropped
/// and listeners get a synthetic "socket.closed" event.
@MainActor
final class GatewaySocket {
    struct Event {
        let type: String
        let sessionID: String?
        let payload: JSON
    }

    /// A call waiting for its answer. `sent` turns true once its frame was written to the socket.
    private struct Pending {
        let continuation: CheckedContinuation<JSON, Error>
        let socket: URLSessionWebSocketTask
        var sent = false
        var deadline: Task<Void, Never>?
    }

    private let client: DashboardClient
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var connecting: Task<Void, Error>?
    private var heartbeat: Task<Void, Never>?
    private var listeners: [UUID: (Event) -> Void] = [:]
    /// Set by disconnect(): the socket never reconnects (signed out).
    private var closed = false

    init(client: DashboardClient) {
        self.client = client
    }

    var isConnected: Bool { task?.state == .running }

    func addListener(_ listener: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    func connect() async throws {
        guard !closed else { throw DashboardError.disconnected }
        if isConnected { return }
        if let connecting { return try await connecting.value }
        // A socket that ended without its failure being seen yet: drop it so its calls and listeners hear about it.
        if let stale = task { drop(stale) }
        let attempt = Task { @MainActor in
            let ticket = try await client.webSocketTicket()
            guard !closed else { throw DashboardError.disconnected }
            var components = URLComponents(url: client.url("/api/ws", query: ["ticket": ticket]), resolvingAgainstBaseURL: false)!
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            var request = URLRequest(url: components.url!)
            request.setValue("hermes-voice", forHTTPHeaderField: "X-Conduit-Client")
            let socket = client.session.webSocketTask(with: request)
            socket.maximumMessageSize = 16 * 1024 * 1024
            task = socket
            socket.resume()
            receive(on: socket)
            startHeartbeat(on: socket)
        }
        connecting = attempt
        defer { connecting = nil }
        try await attempt.value
    }

    /// Closes for good (sign-out): fails every waiting call and refuses to reconnect.
    func disconnect() {
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let waiting = pending
        pending.removeAll()
        for entry in waiting.values {
            entry.deadline?.cancel()
            entry.continuation.resume(throwing: DashboardError.disconnected)
        }
    }

    /// Checks the connection now (the app is back in the foreground); a dead socket is dropped within seconds.
    func probe() {
        guard let socket = task, socket.state == .running else { return }
        Task { _ = try? await send("gateway.ping", [:], on: socket, timeout: 5) }
    }

    /// Calls a gateway method. Throws `DashboardError.notSent` when the frame never left the phone,
    /// `.rpc` when Hermes refused, and `.timeout` / `.disconnected` when the answer was lost.
    @discardableResult
    func call(_ method: String, _ params: JSON = [:], timeout: TimeInterval? = nil) async throws -> JSON {
        do {
            try await connect()
        } catch {
            throw error.wasNotSent ? error : DashboardError.notSent(error)
        }
        guard let task else { throw DashboardError.notSent(DashboardError.disconnected) }
        let deadline = timeout ?? (method == "session.resume" || method == "session.create" ? 60 : 30)
        return try await send(method, params, on: task, timeout: deadline)
    }

    private func send(_ method: String, _ params: JSON, on socket: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> JSON {
        let id = nextID
        nextID += 1
        let frame: JSON = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: frame)
        } catch {
            throw DashboardError.notSent(error)
        }
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(continuation: continuation, socket: socket, deadline: expiry(for: id, after: timeout))
            socket.send(.string(text)) { [weak self] error in
                Task { @MainActor in self?.didSend(id, error: error) }
            }
        }
    }

    private func expiry(for id: Int, after seconds: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expire(id)
        }
    }

    private func didSend(_ id: Int, error: Error?) {
        guard var entry = pending[id] else { return }
        if let error {
            pending[id] = nil
            entry.deadline?.cancel()
            entry.continuation.resume(throwing: DashboardError.notSent(error))
            drop(entry.socket)
        } else if entry.socket !== task {
            // Written, but the socket was dropped meanwhile: the answer is lost.
            pending[id] = nil
            entry.deadline?.cancel()
            entry.continuation.resume(throwing: DashboardError.disconnected)
        } else {
            entry.sent = true
            pending[id] = entry
        }
    }

    /// No answer in time: the connection is presumed dead.
    private func expire(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: DashboardError.timeout)
        drop(entry.socket)
    }

    /// Gives up on `socket`: cancels it, fails the calls whose frames went out, and tells the listeners.
    /// Calls still being written are settled by their send completion (or a short deadline).
    private func drop(_ socket: URLSessionWebSocketTask) {
        guard task === socket else { return }
        task = nil
        heartbeat?.cancel()
        heartbeat = nil
        socket.cancel(with: .goingAway, reason: nil)
        for (id, var entry) in pending where entry.socket === socket {
            entry.deadline?.cancel()
            if entry.sent {
                pending[id] = nil
                entry.continuation.resume(throwing: DashboardError.disconnected)
            } else {
                entry.deadline = expiry(for: id, after: 5)
                pending[id] = entry
            }
        }
        emit(Event(type: "socket.closed", sessionID: nil, payload: [:]))
    }

    /// Pings the gateway every 15 s; no answer within 10 s drops the socket (Hermes answers pings on its read loop).
    private func startHeartbeat(on socket: URLSessionWebSocketTask) {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * NSEC_PER_SEC)
                guard !Task.isCancelled, let self, self.task === socket else { return }
                _ = try? await self.send("gateway.ping", [:], on: socket, timeout: 10)
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === socket else { return }
                switch result {
                case let .success(.string(text)):
                    self.handle(text)
                    self.receive(on: socket)
                case .success:
                    self.receive(on: socket)
                case .failure:
                    self.drop(socket)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON else { return }
        if let id = object["id"] as? Int, object["method"] == nil {
            guard let entry = pending.removeValue(forKey: id) else { return }
            entry.deadline?.cancel()
            if let error = object["error"] as? JSON {
                entry.continuation.resume(throwing: DashboardError.rpc(error["message"] as? String ?? "Hermes returned an error."))
            } else {
                entry.continuation.resume(returning: object["result"] as? JSON ?? [:])
            }
            return
        }
        guard object["method"] as? String == "event", let params = object["params"] as? JSON else { return }
        emit(Event(
            type: params["type"] as? String ?? "",
            sessionID: params["session_id"] as? String,
            payload: params["payload"] as? JSON ?? [:]
        ))
    }

    private func emit(_ event: Event) {
        for listener in listeners.values { listener(event) }
    }
}
