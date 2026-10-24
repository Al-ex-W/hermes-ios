import XCTest
@testable import HermesVoice

/// A scripted gateway peer: answers the client's calls from per-method handlers, records what it was sent, and
/// lets a test push frames or kill the socket.
@MainActor
final class ScriptedGateway {
    enum Reply {
        case result(JSONValue)
        case error(Int, String)
        /// Leave the call unanswered.
        case silent
    }

    /// One client→server call, with the index of the socket it came on.
    struct Call {
        let method: String
        let params: JSONValue
        let socket: Int
    }

    var epoch = "epoch-1"
    var declinesNotShown = true
    /// Answers `gateway.ping` (heartbeats and probes).
    var answersPings = true
    var sendsReady = true
    /// False: dialing fails.
    var reachable = true
    var handlers: [String: (JSONValue) -> Reply] = [:]
    /// Runs when a call arrives, just before its answer goes out (to race it with live frames).
    var beforeReply: [String: (ScriptedSocket) -> Void] = [:]
    private(set) var sockets: [ScriptedSocket] = []
    private(set) var calls: [Call] = []
    /// Frames the client sent without a method: its answers to server requests.
    private(set) var responses: [(frame: JSONValue, socket: Int)] = []

    var current: ScriptedSocket { sockets[sockets.count - 1] }

    func dial() async throws -> GatewayTransport {
        guard reachable else { throw URLError(.cannotConnectToHost) }
        let socket = ScriptedSocket(gateway: self, index: sockets.count)
        sockets.append(socket)
        return socket
    }

    func calls(_ method: String) -> [Call] {
        calls.filter { $0.method == method }
    }

    func responses(to id: String) -> [JSONValue] {
        responses.map(\.frame).filter { $0["id"]?.stringValue == id }
    }

    /// A connection to this gateway; reconnects and heartbeats are off unless `options` turn them on.
    func connection(_ configure: (inout GatewayConnection.Options) -> Void = { _ in }) -> GatewayConnection {
        var options = GatewayConnection.Options()
        options.heartbeatInterval = 3600
        options.reconnectDelays = []
        options.readyTimeout = 1
        configure(&options)
        return GatewayConnection(options: options) { [unowned self] in try await self.dial() }
    }

    fileprivate func opened(_ socket: ScriptedSocket) {
        guard sendsReady else { return }
        socket.push(event: "gateway.ready", payload: [
            "skin": [:], "change_events": true, "heartbeat": true, "replay_epoch": .string(epoch),
        ])
    }

    fileprivate func received(_ frame: JSONValue, on socket: ScriptedSocket) {
        guard let method = frame["method"]?.stringValue else {
            responses.append((frame, socket.index))
            return
        }
        let params = frame["params"] ?? [:]
        calls.append(Call(method: method, params: params, socket: socket.index))
        let reply: Reply
        if let handler = handlers[method] {
            reply = handler(params)
        } else if method == "gateway.ping" {
            reply = answersPings ? .result(["ok": true]) : .silent
        } else if method == "client.capabilities" {
            reply = .result(["server_requests": ["approval", "clarify"], "declines_not_shown": .bool(declinesNotShown)])
        } else {
            reply = .error(-32601, "unknown method: \(method)")
        }
        guard let id = frame["id"] else { return }
        let hook = beforeReply[method]
        Task { @MainActor in
            hook?(socket)
            switch reply {
            case let .result(result):
                socket.push(["jsonrpc": "2.0", "id": id, "result": result])
            case let .error(code, message):
                socket.push(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]])
            case .silent:
                break
            }
        }
    }
}

@MainActor
final class ScriptedSocket: GatewayTransport {
    let index: Int
    private unowned let gateway: ScriptedGateway
    private var onFrame: ((String) -> Void)?
    private var onClose: ((Error?) -> Void)?
    private(set) var isOpen = true
    /// The client closed it (a drop), as opposed to `kill()`.
    private(set) var closedByClient = false

    init(gateway: ScriptedGateway, index: Int) {
        self.gateway = gateway
        self.index = index
    }

    func start(onFrame: @escaping (String) -> Void, onClose: @escaping (Error?) -> Void) {
        self.onFrame = onFrame
        self.onClose = onClose
        Task { @MainActor in self.gateway.opened(self) }
    }

    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        guard isOpen, let frame = try? JSONValue(jsonData: Data(text.utf8)) else {
            Task { @MainActor in completion(URLError(.networkConnectionLost)) }
            return
        }
        Task { @MainActor in
            completion(nil)
            self.gateway.received(frame, on: self)
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        closedByClient = true
    }

    func push(_ frame: JSONValue) {
        guard isOpen, let data = try? frame.jsonData() else { return }
        onFrame?(String(decoding: data, as: UTF8.self))
    }

    func push(event type: String, session: String? = nil, seq: Int? = nil, payload: JSONValue = [:]) {
        var params: JSONValue = ["type": .string(type), "session_id": .string(session ?? ""), "payload": payload]
        if let seq { params = params.setting("seq", .int(seq)) }
        push(["jsonrpc": "2.0", "method": "event", "params": params])
    }

    func push(request id: String, method: String, params: JSONValue) {
        push(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params])
    }

    /// The network drops it: the client hears it close.
    func kill() {
        guard isOpen else { return }
        isOpen = false
        onClose?(URLError(.networkConnectionLost))
    }
}

/// Records what the connection tells a session's owner.
@MainActor
final class RecordingOwner: GatewaySessionOwner {
    private(set) var reattached: [LiveSession] = []
    private(set) var refetches = 0
    private(set) var failures: [Error] = []

    func gatewayReattached(_ session: LiveSession) { reattached.append(session) }
    func gatewayNeedsRefetch() { refetches += 1 }
    func gatewayReattachFailed(_ error: Error) { failures.append(error) }
}

/// Records delivered events as (type, session id, seq).
@MainActor
final class EventLog {
    private(set) var events: [(type: String, sessionID: String?, seq: Int?)] = []
    private(set) var decoded: [GatewayEvent] = []

    init(_ connection: GatewayConnection) {
        _ = connection.addListener { [weak self] event, sessionID, seq in
            self?.events.append((event.type, sessionID, seq))
            self?.decoded.append(event)
        }
    }

    func seqs(_ sessionID: String) -> [Int] {
        events.filter { $0.sessionID == sessionID }.compactMap(\.seq)
    }
}

/// A `session.activate` / `session.resume` result.
func liveResult(_ runtimeID: String, running: Bool = false, extra: [String: JSONValue] = [:]) -> JSONValue {
    var result: [String: JSONValue] = [
        "session_id": .string(runtimeID), "message_count": 0, "messages": [], "info": ["running": .bool(running)],
        "running": .bool(running), "status": running ? "working" : "idle",
    ]
    result.merge(extra) { _, new in new }
    return .object(result)
}

func eventsSince(_ events: [JSONValue], latest: Int, truncated: Bool = false, epoch: String = "epoch-1",
                 open: [JSONValue] = []) -> JSONValue {
    ["events": .array(events), "latest_seq": .int(latest), "truncated": .bool(truncated), "count": .int(events.count),
     "epoch": .string(epoch), "open_requests": .array(open)]
}

func replayed(_ type: String, session: String, seq: Int, payload: JSONValue = [:]) -> JSONValue {
    ["type": .string(type), "session_id": .string(session), "seq": .int(seq), "payload": payload]
}

/// Polls until `condition` holds (the main actor keeps running the connection meanwhile).
@MainActor
func waitUntil(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for the condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Lets queued main-actor work (frames in flight) run.
@MainActor
func settle(_ seconds: TimeInterval = 0.05) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}
