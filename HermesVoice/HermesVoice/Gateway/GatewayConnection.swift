import Foundation
import os

private let connectionLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesVoice", category: "GatewayConnection")

/// One socket's text frames: the dashboard WebSocket in the app, a scripted peer in tests.
@MainActor
protocol GatewayTransport: AnyObject {
    /// False once the socket ended, even before its failure was reported.
    var isOpen: Bool { get }
    /// Starts reading: `onFrame` gets each text frame in order, `onClose` runs once if the socket ends by itself.
    func start(onFrame: @escaping (String) -> Void, onClose: @escaping (Error?) -> Void)
    /// Writes one frame; `completion` gets the write's error, if any.
    func send(_ text: String, completion: @escaping (Error?) -> Void)
    /// Closes the socket; `onClose` doesn't run.
    func close()
}

/// The dashboard's `/api/ws` socket.
@MainActor
final class WebSocketTransport: GatewayTransport {
    private let task: URLSessionWebSocketTask
    private var onFrame: ((String) -> Void)?
    private var onClose: ((Error?) -> Void)?
    private var ended = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    /// Mints a fresh ws-ticket (each works for one connection) and dials the gateway with it.
    static func dial(_ client: DashboardClient) async throws -> WebSocketTransport {
        let ticket = try await client.webSocketTicket()
        var components = URLComponents(url: client.url("/api/ws", query: ["ticket": ticket]), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("hermes-voice", forHTTPHeaderField: "X-Conduit-Client")
        return WebSocketTransport(task: client.session.webSocketTask(with: request))
    }

    var isOpen: Bool { !ended && task.state == .running }

    func start(onFrame: @escaping (String) -> Void, onClose: @escaping (Error?) -> Void) {
        self.onFrame = onFrame
        self.onClose = onClose
        task.resume()
        receive()
    }

    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        task.send(.string(text)) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func close() {
        guard !ended else { return }
        ended = true
        onFrame = nil
        onClose = nil
        task.cancel(with: .goingAway, reason: nil)
    }

    /// One read at a time: the next starts once this frame was handled, so frames are handled in order.
    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.ended else { return }
                switch result {
                case let .success(.string(text)):
                    self.onFrame?(text)
                case let .success(.data(data)):
                    self.onFrame?(String(decoding: data, as: UTF8.self))
                case .success:
                    break
                case let .failure(error):
                    let onClose = self.onClose
                    self.close()
                    onClose?(error)
                    return
                }
                if !self.ended { self.receive() }
            }
        }
    }
}

/// Hermes answered a call with a JSON-RPC error (4001 session not found, 4007 not live, -32601 no such method, …).
struct GatewayRPCError: LocalizedError, Equatable {
    let code: Int
    let message: String

    var errorDescription: String? { message }
}

/// Hermes won't re-attach a session while it settles the interrupt it sent the session's turn when its last client
/// went away (4009 from resume and activate). Within seconds the session is reaped or freed, so asking again helps.
struct SessionSettlingError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// What the app reads from a `session.create` / `session.resume` / `session.activate` result. A result outside
/// the contract (another Hermes version) is read from its raw form, so attaching never fails on shape alone.
struct LiveSession: Equatable {
    /// The id events and prompts carry. A resume after Hermes reaped the session returns a new one.
    var runtimeID: String
    /// `stored_session_id` when the result has it (create does, resume doesn't).
    var storedID: String?
    var running = false
    /// The running turn as Hermes holds it (its prompt, the reply so far, the corrections steered into it, a
    /// failure kept for a client that missed it), the prompt queued after it, and the session's task list.
    var inflight: InflightTurn?
    var queuedPrompt: String?
    var todos: TodoState?

    var inflightPrompt: String? { inflight?.user }
    var corrections: [String] { inflight?.corrections ?? [] }

    init(runtimeID: String, storedID: String? = nil, running: Bool = false, inflight: InflightTurn? = nil,
         queuedPrompt: String? = nil, todos: TodoState? = nil) {
        self.runtimeID = runtimeID
        self.storedID = storedID
        self.running = running
        self.inflight = inflight
        self.queuedPrompt = queuedPrompt
        self.todos = todos
    }

    init(runtimeID: String, storedID: String? = nil, running: Bool = false, inflightPrompt: String?,
         corrections: [String] = [], queuedPrompt: String? = nil) {
        let inflight = inflightPrompt == nil && corrections.isEmpty
            ? nil : InflightTurn(user: inflightPrompt, corrections: corrections.isEmpty ? nil : corrections)
        self.init(runtimeID: runtimeID, storedID: storedID, running: running, inflight: inflight, queuedPrompt: queuedPrompt)
    }

    init(_ result: SessionResumeResult) {
        self.init(runtimeID: result.sessionId, storedID: result.storedSessionId, running: result.running ?? false,
                  inflight: result.inflight, queuedPrompt: result.queued?.user, todos: result.todoState)
    }

    init(_ result: SessionActivateResult) {
        self.init(runtimeID: result.sessionId, storedID: result.storedSessionId, running: result.running ?? false,
                  inflight: result.inflight, queuedPrompt: result.queued?.user, todos: result.todoState)
    }

    init(_ result: SessionCreateResult) {
        self.init(runtimeID: result.sessionId, storedID: result.storedSessionId)
    }

    init(raw: JSONValue) throws {
        guard let runtimeID = raw["session_id"]?.stringValue, !runtimeID.isEmpty else {
            throw DashboardError.rpc("Hermes didn't open the session.")
        }
        var inflight = try? raw["inflight"]?.decode(InflightTurn.self)
        if inflight == nil, let user = raw["inflight"]?["user"]?.stringValue {
            inflight = InflightTurn(user: user, corrections: raw["inflight"]?["corrections"]?.arrayValue?.compactMap(\.stringValue))
        }
        self.init(runtimeID: runtimeID, storedID: raw["stored_session_id"]?.stringValue,
                  running: raw["running"]?.boolValue ?? false, inflight: inflight,
                  queuedPrompt: raw["queued"]?["user"]?.stringValue, todos: try? raw["todo_state"]?.decode(TodoState.self))
    }

    /// Runs a typed attach call; a result that doesn't match the contract is read from its raw form instead.
    /// A 4009 refusal throws `SessionSettlingError`.
    static func attach<Result>(_ call: () async throws -> Result, _ typed: (Result) -> LiveSession) async throws -> LiveSession {
        do {
            return typed(try await call())
        } catch let error as GatewayDecodingError {
            connectionLog.error("\(error.method, privacy: .public) result outside the contract: \(String(describing: error.underlying), privacy: .public)")
            return try LiveSession(raw: error.raw)
        } catch let error as GatewayRPCError where error.code == 4009 {
            throw SessionSettlingError(message: error.message)
        }
    }
}

/// Owns a live session the connection keeps attached across reconnects (a chat).
@MainActor
protocol GatewaySessionOwner: AnyObject {
    /// Re-attached on a new socket; `session.runtimeID` is new when Hermes reaped the old runtime meanwhile.
    func gatewayReattached(_ session: LiveSession)
    /// Events were lost (new runtime, Hermes restarted, replay truncated or unavailable): refetch the transcript.
    func gatewayNeedsRefetch()
    /// Hermes refused to re-attach; the session is no longer tracked.
    func gatewayReattachFailed(_ error: Error)
}

/// Takes the server→client requests (PromptCenter).
@MainActor
protocol ServerRequestHandling: AnyObject {
    /// A request, live or re-delivered from a result's `open_requests` (`replayed`). `arrival` orders it against
    /// `reconcile`.
    func receive(_ request: ServerRequest, replayed: Bool, arrival: Int)
    /// A resume/activate/events.since result listed every request still open for `sessionID`; one that arrived
    /// before `arrival` (when that call went out) and isn't listed has ended.
    func reconcile(_ sessionID: String, open: Set<String>, asOf arrival: Int)
    /// A resume/activate result's `pending_approval` (nil: none); `listed` holds the queue ids of the approval
    /// requests the same result's `open_requests` re-delivered.
    func restore(pendingApproval: PendingApproval?, sessionID: String, listed: Set<String>)
    /// The runtime `old` was reaped and resume made `new`: prompts of `old` went with it.
    func sessionReplaced(_ old: String, by new: String)
}

/// JSON-RPC 2.0 over the dashboard's `/api/ws?ticket=…` WebSocket, with the desktop client's reconnect contract.
/// Each connect mints a fresh ticket, waits for `gateway.ready` (the replay epoch), advertises
/// `client.capabilities {server_requests}` and pings every 15 s (no frame for 45 s drops the socket). After a
/// reconnect every tracked session is re-attached (`session.activate`, else `session.resume` with the stored id) and
/// what it missed is replayed from `session.events.since`, deduplicated by `seq`, before live frames resume. A
/// session Hermes is still settling (4009) is re-attached again shortly after.
/// Calls have deadlines; a lost answer drops the socket and listeners hear `.disconnected`.
@MainActor
final class GatewayConnection: GatewayCalling {
    enum State: Equatable { case disconnected, connecting, connected }

    struct Options {
        /// Deadline of a call without its own; session.resume/create/activate get `attachTimeout`.
        var callTimeout: TimeInterval = 30
        var attachTimeout: TimeInterval = 60
        var readyTimeout: TimeInterval = 10
        var replayTimeout: TimeInterval = 10
        var heartbeatInterval: TimeInterval = 15
        /// No inbound frame (any counts) for this long drops the socket.
        var heartbeatDeadline: TimeInterval = 45
        var probeTimeout: TimeInterval = 5
        /// Waits before automatic reconnects while sessions are tracked (the last repeats); empty: none.
        var reconnectDelays: [TimeInterval] = [1, 2, 5, 10, 30]
        /// Waits before re-attaching a session Hermes refused while settling it (about the reaper's minute of
        /// interrupt polls in all); still refused after the last, the re-attach failed.
        var settleRetryDelays: [TimeInterval] = [1, 2, 3, 5, 10, 10, 15, 30]
    }

    typealias Listener = (_ event: GatewayEvent, _ sessionID: String?, _ seq: Int?) -> Void

    /// Typed calls over this connection. Made on demand: a stored client would retain the connection.
    var client: GatewayClient { GatewayClient(transport: self) }
    private(set) var state: State = .disconnected
    var isConnected: Bool { state == .connected && socket?.isOpen == true }
    /// The backend counts a 4404 as one client declining a window-owned request (from `client.capabilities`).
    private(set) var declinesNotShown = false
    /// The server process's seq numbering (`gateway.ready`); a new one means Hermes restarted.
    private(set) var replayEpoch: String?
    /// The highest seq delivered per runtime session id.
    private(set) var watermarks: [String: Int] = [:]
    weak var requests: ServerRequestHandling?

    /// A call waiting for its answer. `sent` turns true once its frame was written to the socket.
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let socket: GatewayTransport
        let method: String
        /// The call's `session_id` param.
        let sessionID: String?
        /// Frames received before it went out.
        let arrival: Int
        let dropsOnTimeout: Bool
        var sent = false
        var deadline: Task<Void, Never>?
    }

    private struct Ready {
        /// `replay_epoch`; nil from a backend without replay.
        let epoch: String?
    }

    private struct Tracked {
        weak var owner: GatewaySessionOwner?
        var runtimeID: String
        var storedID: String?
        var profile: String?
    }

    private static let attachMethods: Set<String> = ["session.resume", "session.activate"]
    /// Activate refusals that mean the runtime is gone: resume the stored id instead.
    private static let sessionGone: Set<Int> = [4001, 4007]

    private let options: Options
    private let dial: () async throws -> GatewayTransport
    private var socket: GatewayTransport?
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var connecting: Task<Void, Error>?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var listeners: [UUID: Listener] = [:]
    private var stateListeners: [UUID: (State) -> Void] = [:]
    private var tracked: [ObjectIdentifier: Tracked] = [:]
    /// Tracked sessions Hermes refused to re-attach while settling them, and the task re-attaching them.
    private var settling: Set<ObjectIdentifier> = []
    private var settleRetry: Task<Void, Never>?
    /// Event frames parked during the handshake, and the replays fetched in it; delivered when it ends.
    private var held: [EventEnvelope]?
    private var replays: [String: [EventEnvelope]] = [:]
    /// `gateway.ready` of the current socket, once it came.
    private var ready: Ready?
    private var readyWaiter: CheckedContinuation<Ready?, Never>?
    private var generation = 0
    private var lastInbound = Date()
    private var arrivals = 0
    private var pings = 0
    /// Set by disconnect(): the connection never reconnects (signed out).
    private var closed = false

    init(options: Options = Options(), dial: @escaping () async throws -> GatewayTransport) {
        self.options = options
        self.dial = dial
    }

    convenience init(client: DashboardClient) {
        self.init { try await WebSocketTransport.dial(client) }
    }

    // MARK: Listeners and sessions

    func addListener(_ listener: @escaping Listener) -> UUID {
        let id = UUID()
        listeners[id] = listener
        return id
    }

    func addStateListener(_ listener: @escaping (State) -> Void) -> UUID {
        let id = UUID()
        stateListeners[id] = listener
        return id
    }

    func removeListener(_ id: UUID) {
        listeners[id] = nil
        stateListeners[id] = nil
    }

    /// Keeps `runtimeID` attached for `owner` across reconnects, replacing what it tracked before.
    func track(_ owner: GatewaySessionOwner, runtimeID: String, storedID: String?, profile: String?) {
        let key = ObjectIdentifier(owner)
        if let old = tracked[key]?.runtimeID, old != runtimeID { watermarks[old] = nil }
        tracked[key] = Tracked(owner: owner, runtimeID: runtimeID, storedID: storedID, profile: profile)
        settling.remove(key)
    }

    func untrack(_ owner: GatewaySessionOwner) {
        let key = ObjectIdentifier(owner)
        settling.remove(key)
        guard let entry = tracked.removeValue(forKey: key) else { return }
        watermarks[entry.runtimeID] = nil
    }

    // MARK: Connecting

    /// Connects (single flight) and finishes the handshake, re-attaching tracked sessions.
    func connect() async throws {
        guard !closed else { throw DashboardError.disconnected }
        if isConnected { return }
        if let connecting { return try await connecting.value }
        // A socket that ended without its failure being seen yet: drop it so its calls and listeners hear about it.
        if let stale = socket { drop(stale) }
        let attempt = Task { @MainActor in
            defer { self.connecting = nil }
            try await self.open()
        }
        connecting = attempt
        do {
            try await attempt.value
        } catch {
            scheduleReconnect()
            throw error
        }
    }

    /// Closes for good (sign-out): fails every waiting call and refuses to reconnect.
    func disconnect() {
        closed = true
        reconnect?.cancel()
        reconnect = nil
        heartbeat?.cancel()
        heartbeat = nil
        settleRetry?.cancel()
        settleRetry = nil
        settling.removeAll()
        socket?.close()
        socket = nil
        settleReady(nil)
        state = .disconnected
        tracked.removeAll()
        let waiting = pending
        pending.removeAll()
        for entry in waiting.values {
            entry.deadline?.cancel()
            entry.continuation.resume(throwing: DashboardError.disconnected)
        }
    }

    /// Checks the connection now (the app is back in the foreground): a dead socket is dropped within
    /// `probeTimeout`, and a dropped one with sessions to keep is redialled at once.
    func probe() {
        if state == .disconnected {
            pruneTracked()
            guard !closed, !tracked.isEmpty else { return }
            reconnect?.cancel()
            reconnect = nil
            reconnectAttempt = 0
            Task { try? await connect() }
            return
        }
        guard let socket, state == .connected else { return }
        Task { _ = try? await send("gateway.ping", [:], on: socket, timeout: options.probeTimeout) }
    }

    private func open() async throws {
        let socket = try await dial()
        guard !closed else {
            socket.close()
            throw DashboardError.disconnected
        }
        generation += 1
        self.socket = socket
        ready = nil
        declinesNotShown = false
        held = []
        replays = [:]
        lastInbound = Date()
        setState(.connecting)
        socket.start(onFrame: { [weak self, weak socket] text in
            guard let self, let socket else { return }
            self.receive(text, on: socket)
        }, onClose: { [weak self, weak socket] _ in
            guard let self, let socket else { return }
            self.drop(socket)
        })
        startHeartbeat(on: socket)
        do {
            let ready = await waitForReady()
            try ensureCurrent(socket)
            let epochChanged = ready?.epoch.map(adopt) ?? false
            let calls = GatewayClient(transport: SocketCaller(connection: self, socket: socket))
            do {
                declinesNotShown = try await calls.clientCapabilities(.init(serverRequests: true)).declinesNotShown == true
            } catch let error as GatewayDecodingError {
                declinesNotShown = error.raw["declines_not_shown"]?.boolValue == true
            } catch is GatewayRPCError {
                // A backend older than server→client requests.
            }
            try await reattachAll(on: socket, replays: !epochChanged)
            try ensureCurrent(socket)
            flushHeld()
            reconnectAttempt = 0
            setState(.connected)
            retrySettling(on: socket)
        } catch {
            drop(socket)
            throw error
        }
    }

    private func ensureCurrent(_ socket: GatewayTransport) throws {
        guard self.socket === socket, socket.isOpen else { throw DashboardError.disconnected }
    }

    /// The socket's `gateway.ready`; nil when none came in time (an older backend) or the socket dropped.
    private func waitForReady() async -> Ready? {
        if let ready { return ready }
        let generation = generation
        let timeout = options.readyTimeout
        return await withCheckedContinuation { continuation in
            readyWaiter = continuation
            Task { [weak self] in
                await Self.sleep(timeout)
                guard let self, self.generation == generation else { return }
                self.settleReady(nil)
            }
        }
    }

    private func settleReady(_ value: Ready?) {
        if let value { ready = value }
        let waiter = readyWaiter
        readyWaiter = nil
        waiter?.resume(returning: value)
    }

    /// Records the server's seq numbering; a new one (Hermes restarted) voids every watermark. True when it changed.
    private func adopt(_ epoch: String) -> Bool {
        defer { replayEpoch = epoch }
        guard let replayEpoch, replayEpoch != epoch else { return false }
        watermarks.removeAll()
        return true
    }

    // MARK: Re-attaching

    private func reattachAll(on socket: GatewayTransport, replays: Bool) async throws {
        pruneTracked()
        settling.removeAll()
        let keys = Array(tracked.keys)
        guard !keys.isEmpty else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { @MainActor in try await self.reattach(key, on: socket, replays: replays) }
            }
            try await group.waitForAll()
        }
    }

    /// `session.activate` with the runtime id; when Hermes reaped it (4001/4007), `session.resume` with the stored
    /// id, which may mint a new runtime id. Only a surviving runtime replays, and only when `replays` (else what it
    /// missed is refetched). Socket failures propagate (the handshake fails); a session Hermes is settling (4009)
    /// stays tracked for `retrySettling`; any other refusal ends the tracking and tells the owner.
    private func reattach(_ key: ObjectIdentifier, on socket: GatewayTransport, replays: Bool) async throws {
        guard let entry = tracked[key] else { return }
        let calls = GatewayClient(transport: SocketCaller(connection: self, socket: socket))
        let old = entry.runtimeID
        let session: LiveSession
        do {
            do {
                session = try await LiveSession.attach({
                    try await calls.sessionActivate(.init(sessionId: old, profile: entry.profile, cols: 96, omitMessages: true))
                }, LiveSession.init)
            } catch let error as GatewayRPCError where Self.sessionGone.contains(error.code) {
                guard let storedID = entry.storedID else { throw error }
                connectionLog.notice("Session \(old, privacy: .public) is gone (\(error.code)): resuming \(storedID, privacy: .public)")
                session = try await LiveSession.attach({
                    try await calls.sessionResume(.init(sessionId: storedID, profile: entry.profile, cols: 96, source: "desktop", omitMessages: true))
                }, LiveSession.init)
            }
        } catch where error.isConnectionLoss {
            throw error
        } catch let error as SessionSettlingError {
            connectionLog.notice("Session \(old, privacy: .public) is settling: \(error.message, privacy: .public)")
            if tracked[key] != nil { settling.insert(key) }
            return
        } catch {
            guard let owner = tracked.removeValue(forKey: key)?.owner else { return }
            watermarks[old] = nil
            owner.gatewayReattachFailed(error)
            return
        }
        guard tracked[key] != nil else { return }
        let survived = session.runtimeID == old
        if !survived {
            watermarks[old] = nil
            tracked[key]?.runtimeID = session.runtimeID
            requests?.sessionReplaced(old, by: session.runtimeID)
        }
        tracked[key]?.owner?.gatewayReattached(session)
        guard survived, replays else {
            tracked[key]?.owner?.gatewayNeedsRefetch()
            return
        }
        try await replay(key, runtimeID: old, profile: entry.profile, on: socket)
    }

    /// Re-attaches, with backoff, the sessions Hermes refused while settling. Live frames flow as soon as one is
    /// attached, so what it missed is refetched, not replayed. Still settling after the last try: the re-attach failed.
    private func retrySettling(on socket: GatewayTransport) {
        guard settleRetry == nil, !settling.isEmpty else { return }
        let delays = options.settleRetryDelays
        settleRetry = Task { [weak self] in
            for delay in delays {
                await Self.sleep(delay)
                guard let self, !Task.isCancelled, self.socket === socket, self.state == .connected else { return }
                for key in Array(self.settling) {
                    // Re-attached by its owner meanwhile.
                    guard self.settling.remove(key) != nil else { continue }
                    try? await self.reattach(key, on: socket, replays: false)
                }
                if self.settling.isEmpty { break }
            }
            guard let self, !Task.isCancelled else { return }
            self.settleRetry = nil
            let stuck = self.settling
            self.settling.removeAll()
            for key in stuck {
                guard let entry = self.tracked.removeValue(forKey: key) else { continue }
                self.watermarks[entry.runtimeID] = nil
                entry.owner?.gatewayReattachFailed(SessionSettlingError(message: "Hermes is still settling this session."))
            }
        }
    }

    /// Fetches what the runtime emitted after its watermark; delivered with the parked live frames when the
    /// handshake ends. Asks for a refetch when the replay can't be trusted.
    private func replay(_ key: ObjectIdentifier, runtimeID: String, profile: String?, on socket: GatewayTransport) async throws {
        let known = watermarks[runtimeID]
        let raw: JSONValue
        do {
            let params = try JSONValue.encode(SessionEventsSinceParams(sessionId: runtimeID, profile: profile, lastSeen: known ?? 0))
            raw = try await send("session.events.since", params, on: socket, timeout: options.replayTimeout, dropsOnTimeout: false)
        } catch DashboardError.timeout {
            tracked[key]?.owner?.gatewayNeedsRefetch()
            return
        } catch where error.isConnectionLoss {
            throw error
        } catch {
            // A backend without replay.
            tracked[key]?.owner?.gatewayNeedsRefetch()
            return
        }
        guard tracked[key] != nil else { return }
        if let epoch = raw["epoch"]?.stringValue, !epoch.isEmpty, adopt(epoch) {
            tracked[key]?.owner?.gatewayNeedsRefetch()
            return
        }
        guard known != nil else {
            // Nothing seen from this runtime since attaching: what it emitted meanwhile can't be told apart from
            // what the transcript already holds.
            if (raw["latest_seq"]?.intValue ?? 0) > 0 { tracked[key]?.owner?.gatewayNeedsRefetch() }
            return
        }
        replays[runtimeID, default: []] += (raw["events"]?.arrayValue ?? []).compactMap(EventEnvelope.init(params:))
        if raw["truncated"]?.boolValue == true { tracked[key]?.owner?.gatewayNeedsRefetch() }
    }

    /// Ends the handshake's hold: each replay in order, then the live frames parked meanwhile, all seq-gated.
    private func flushHeld() {
        let replayed = replays
        let parked = held ?? []
        replays = [:]
        held = nil
        for events in replayed.values {
            for envelope in events { dispatchIfNewer(envelope) }
        }
        for envelope in parked { dispatchIfNewer(envelope) }
    }

    private func pruneTracked() {
        tracked = tracked.filter { $0.value.owner != nil }
    }

    // MARK: Calls

    /// Calls a gateway method. Throws `DashboardError.notSent` when the frame never left the phone,
    /// `GatewayRPCError` when Hermes refused, and `.timeout` / `.disconnected` when the answer was lost.
    @discardableResult
    func call(_ method: String, params: JSONValue, timeout: TimeInterval?) async throws -> JSONValue {
        do {
            try await connect()
        } catch {
            throw error.wasNotSent ? error : DashboardError.notSent(error)
        }
        guard let socket, state == .connected else { throw DashboardError.notSent(DashboardError.disconnected) }
        return try await send(method, params, on: socket, timeout: timeout ?? deadline(for: method))
    }

    fileprivate func deadline(for method: String) -> TimeInterval {
        Self.attachMethods.contains(method) || method == "session.create" ? options.attachTimeout : options.callTimeout
    }

    fileprivate func send(_ method: String, _ params: JSONValue, on socket: GatewayTransport, timeout: TimeInterval,
                          dropsOnTimeout: Bool = true) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params.anyValue]
        guard JSONSerialization.isValidJSONObject(frame), let data = try? JSONSerialization.data(withJSONObject: frame) else {
            throw DashboardError.notSent(DashboardError.rpc("\(method) params aren't valid JSON."))
        }
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = Pending(continuation: continuation, socket: socket, method: method,
                                  sessionID: params["session_id"]?.stringValue, arrival: arrivals,
                                  dropsOnTimeout: dropsOnTimeout, deadline: expiry(for: id, after: timeout))
            socket.send(text) { [weak self] error in self?.didSend(id, error: error) }
        }
    }

    private func expiry(for id: Int, after seconds: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            await Self.sleep(seconds)
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
        } else if entry.socket !== socket {
            // Written, but the socket was dropped meanwhile: the answer is lost.
            pending[id] = nil
            entry.deadline?.cancel()
            entry.continuation.resume(throwing: DashboardError.disconnected)
        } else {
            entry.sent = true
            pending[id] = entry
        }
    }

    /// No answer in time: the connection is presumed dead (except for a replay, which may just be slow).
    private func expire(_ id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: DashboardError.timeout)
        if entry.dropsOnTimeout { drop(entry.socket) }
    }

    /// Answers a server→client request on the open socket (Hermes matches the answer by id, whichever socket
    /// asked). False when no socket is open.
    @discardableResult
    func respond(to id: String, result: JSONValue) -> Bool {
        write(["jsonrpc": "2.0", "id": .string(id), "result": result])
    }

    @discardableResult
    func respond(to id: String, errorCode code: Int, message: String) -> Bool {
        write(["jsonrpc": "2.0", "id": .string(id), "error": ["code": .int(code), "message": .string(message)]])
    }

    private func write(_ frame: JSONValue) -> Bool {
        guard let socket, socket.isOpen, let data = try? JSONSerialization.data(withJSONObject: frame.anyValue) else { return false }
        socket.send(String(decoding: data, as: UTF8.self)) { [weak self, weak socket] error in
            guard error != nil, let self, let socket else { return }
            self.drop(socket)
        }
        return true
    }

    // MARK: Socket lifecycle

    /// Gives up on `socket`: closes it, fails the calls whose frames went out, and tells the listeners.
    /// Calls still being written are settled by their send completion (or a short deadline).
    private func drop(_ socket: GatewayTransport) {
        guard self.socket === socket else { return }
        self.socket = nil
        heartbeat?.cancel()
        heartbeat = nil
        settleRetry?.cancel()
        settleRetry = nil
        held = nil
        replays = [:]
        socket.close()
        settleReady(nil)
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
        setState(.disconnected)
        scheduleReconnect()
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        for listener in Array(stateListeners.values) { listener(next) }
    }

    /// Redials after a drop while sessions are tracked, with backoff.
    private func scheduleReconnect() {
        pruneTracked()
        guard !closed, reconnect == nil, state == .disconnected, !tracked.isEmpty, !options.reconnectDelays.isEmpty else { return }
        let delays = options.reconnectDelays
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnect = Task { [weak self] in
            await Self.sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnect = nil
            try? await self.connect()
        }
    }

    /// Pings every `heartbeatInterval` and drops the socket after `heartbeatDeadline` without any inbound frame.
    /// Pings go out whether or not `gateway.ready` advertised `heartbeat`: an error answer is inbound too.
    private func startHeartbeat(on socket: GatewayTransport) {
        heartbeat?.cancel()
        let interval = options.heartbeatInterval, deadline = options.heartbeatDeadline
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await Self.sleep(interval)
                guard !Task.isCancelled, let self, self.socket === socket else { return }
                guard Date().timeIntervalSince(self.lastInbound) < deadline else {
                    connectionLog.notice("No frame from the gateway for \(Int(deadline)) s: reconnecting")
                    self.drop(socket)
                    return
                }
                self.pings += 1
                let ping = #"{"jsonrpc":"2.0","id":"heartbeat-\#(self.pings)","method":"gateway.ping","params":{}}"#
                socket.send(ping) { [weak self] error in
                    if error != nil { self?.drop(socket) }
                }
            }
        }
    }

    private nonisolated static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // MARK: Inbound

    private func receive(_ text: String, on socket: GatewayTransport) {
        guard socket === self.socket else { return }
        lastInbound = Date()
        arrivals += 1
        guard let object = (try? JSONValue(jsonData: Data(text.utf8)))?.objectValue else { return }
        let method = object["method"]?.stringValue
        if let method, method != "event", let id = object["id"]?.stringValue {
            deliver(ServerRequest.decode(id: id, method: method, params: object["params"]), replayed: false)
            return
        }
        if method == nil, let id = object["id"] {
            // String ids are heartbeat pongs.
            if let id = id.intValue { settle(id, object) }
            return
        }
        guard method == "event", let params = object["params"], let envelope = EventEnvelope(params: params) else { return }
        if envelope.type == "gateway.ready" {
            let epoch = envelope.payload?["replay_epoch"]?.stringValue
            settleReady(Ready(epoch: epoch?.isEmpty == false ? epoch : nil))
            return
        }
        if held != nil {
            held?.append(envelope)
        } else {
            dispatchIfNewer(envelope)
        }
    }

    private func settle(_ id: Int, _ object: [String: JSONValue]) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.deadline?.cancel()
        if let error = object["error"] {
            entry.continuation.resume(throwing: GatewayRPCError(
                code: error["code"]?.intValue ?? 0,
                message: error["message"]?.stringValue ?? "Hermes returned an error."
            ))
            return
        }
        let result = object["result"] ?? [:]
        noteOpenRequests(result, of: entry)
        entry.continuation.resume(returning: result)
    }

    /// Resume, activate and events.since answers list the server→client requests still waiting on the session
    /// (the replay ring can't carry them): they are re-delivered before the caller sees the result.
    private func noteOpenRequests(_ result: JSONValue, of entry: Pending) {
        let attach = Self.attachMethods.contains(entry.method)
        guard attach || entry.method == "session.events.since",
              let sessionID = result["session_id"]?.stringValue ?? entry.sessionID else { return }
        var open: Set<String> = [], approvals: Set<String> = []
        for item in result["open_requests"]?.arrayValue ?? [] {
            guard let id = item["id"]?.stringValue, let method = item["method"]?.stringValue else { continue }
            open.insert(id)
            let request = ServerRequest.decode(id: id, method: method, params: item["params"])
            if case let .approval(_, params) = request { approvals.insert(params.requestId) }
            deliver(request, replayed: true)
        }
        requests?.reconcile(sessionID, open: open, asOf: entry.arrival)
        if attach {
            requests?.restore(pendingApproval: try? result["pending_approval"]?.decode(PendingApproval.self),
                              sessionID: sessionID, listed: approvals)
        }
    }

    private func deliver(_ request: ServerRequest, replayed: Bool) {
        guard let requests else {
            // Nobody here can answer: say so now rather than leave the agent waiting out its deadline.
            respond(to: request.id, errorCode: -32601, message: "no handler for server request: \(request.method)")
            return
        }
        requests.receive(request, replayed: replayed, arrival: arrivals)
    }

    private func dispatchIfNewer(_ envelope: EventEnvelope) {
        if let sid = envelope.sessionID, let seq = envelope.seq {
            if let seen = watermarks[sid], seq <= seen { return }
            watermarks[sid] = seq
        }
        let event = envelope.event
        for listener in Array(listeners.values) { listener(event, envelope.sessionID, envelope.seq) }
    }
}

/// Sends on one socket without connecting first: the handshake's own calls.
@MainActor
private final class SocketCaller: GatewayCalling {
    private unowned let connection: GatewayConnection
    private let socket: GatewayTransport

    init(connection: GatewayConnection, socket: GatewayTransport) {
        self.connection = connection
        self.socket = socket
    }

    func call(_ method: String, params: JSONValue, timeout: TimeInterval?) async throws -> JSONValue {
        try await connection.send(method, params, on: socket, timeout: timeout ?? connection.deadline(for: method))
    }
}
