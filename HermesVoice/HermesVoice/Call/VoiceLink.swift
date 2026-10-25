import Foundation

/// The call's socket to the plugin as VoiceCall sees it: the real one, or a scripted one in tests.
@MainActor
protocol CallLink: AnyObject {
    var onEvent: ((VoiceLink.Event) -> Void)? { get set }
    /// Opens the socket with a fresh ws-ticket and sends the hello. When it can't, `.closed` is reported.
    func connect() async
    /// `completion` gets whether the frame was written.
    func send(_ message: PhoneMessage, completion: ((Bool) -> Void)?)
    /// Sends `final` (a bye, say) and then closes. No event is reported for this close.
    func close(after final: [PhoneMessage])
}

extension CallLink {
    func send(_ message: PhoneMessage) {
        send(message, completion: nil)
    }
}

/// The call's socket to the Hermes Voice plugin (`/api/plugins/hermes_voice/phone` on the dashboard): rings and
/// answers, carries the speech `start_call` streams and the user's turns, and confirms each utterance was heard.
@MainActor
final class VoiceLink: CallLink {
    enum Event: Equatable {
        case message(PluginMessage)
        case closed(Close)
    }

    /// Why the socket went away.
    enum Close: Equatable {
        /// The plugin rejected the ticket twice (4401), the handshake got 401/403, or the dashboard signed us out.
        case unauthorized
        /// The plugin didn't accept the hello (4400).
        case badHello
        /// A newer connection with the same call_id replaced this one (4409).
        case replaced
        /// Another session holds Hermes' one call slot (4429).
        case busy
        /// Network drop, stall (1011) or server restart: worth reconnecting.
        case dropped
    }

    var onEvent: ((Event) -> Void)?
    private let client: DashboardClient
    private let hello: PhoneHello
    private var task: URLSessionWebSocketTask?
    private var keepalive: Timer?
    private var lastHeard = Date()
    /// A 4401 was answered by minting a new ticket once; the next one is final. Reset by `ready`.
    private var reminted = false
    /// Bumped by every connect and close, so callbacks from an earlier socket or ticket request are ignored.
    private var generation = 0
    /// A socket that hears nothing (not even a pong) for this long has stalled.
    private static let stallAfter: TimeInterval = 50

    init(client: DashboardClient, hello: PhoneHello) {
        self.client = client
        self.hello = hello
    }

    func connect() async {
        reminted = false
        await dial()
    }

    func send(_ message: PhoneMessage, completion: ((Bool) -> Void)?) {
        guard let task, let text = try? message.encoded() else {
            completion?(false)
            return
        }
        task.send(.string(text)) { error in
            Task { @MainActor in completion?(error == nil) }
        }
    }

    func close(after final: [PhoneMessage]) {
        guard let task else { return drop() }
        // Closes once the last frame was written (or after a moment), so the bye isn't lost to the close.
        let finish: @Sendable () -> Void = { task.cancel(with: .normalClosure, reason: nil) }
        drop(cancelling: false)
        guard !final.isEmpty else { return finish() }
        for (index, message) in final.enumerated() {
            guard let text = try? message.encoded() else { continue }
            task.send(.string(text)) { _ in if index == final.count - 1 { finish() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: finish)
    }

    // MARK: Socket

    /// A fresh ticket (each admits one connection), then the socket.
    private func dial() async {
        drop()
        let generation = generation
        let ticket: String
        do {
            ticket = try await client.webSocketTicket()
        } catch {
            guard generation == self.generation else { return }
            if case .signedOut? = error as? DashboardError { return report(.closed(.unauthorized)) }
            return report(.closed(.dropped))
        }
        guard generation == self.generation else { return }
        open(ticket: ticket)
    }

    private func open(ticket: String) {
        var components = URLComponents(url: client.url("\(VoicePluginAPI.path)/phone", query: ["ticket": ticket]), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("hermes-voice", forHTTPHeaderField: "X-Conduit-Client")
        let socket = client.session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        task = socket
        lastHeard = Date()
        socket.resume()
        send(.hello(hello))
        receive(on: socket)
        keepalive = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard let task else { return }
        if Date().timeIntervalSince(lastHeard) > Self.stallAfter {
            // Half-open path: nothing arrives, not even pongs. A fresh socket is the way back.
            task.cancel(with: .goingAway, reason: nil)
            drop()
            return report(.closed(.dropped))
        }
        send(.ping)
    }

    /// Forgets the current socket (cancelling it unless the caller closes it itself) and its callbacks.
    private func drop(cancelling: Bool = true) {
        generation += 1
        keepalive?.invalidate()
        keepalive = nil
        if cancelling { task?.cancel(with: .goingAway, reason: nil) }
        task = nil
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.task === socket else { return }
                self.lastHeard = Date()
                switch result {
                case let .success(.data(data)):
                    self.report(.message(.audio(data)))
                case let .success(.string(text)):
                    if let message = PluginMessage.parse(text) {
                        if case .ready = message { self.reminted = false }
                        self.report(.message(message))
                    }
                case .failure:
                    return self.closed(socket)
                @unknown default:
                    break
                }
                // The handler may have closed or replaced the socket.
                if self.task === socket { self.receive(on: socket) }
            }
        }
    }

    private func closed(_ socket: URLSessionWebSocketTask) {
        let status = (socket.response as? HTTPURLResponse)?.statusCode
        let code = socket.closeCode.rawValue
        drop()
        let reason: Close
        switch code {
        case 4401: reason = .unauthorized
        case 4400: reason = .badHello
        case 4409: reason = .replaced
        case 4429: reason = .busy
        default: reason = status == 401 || status == 403 ? .unauthorized : .dropped
        }
        if reason == .unauthorized, !reminted {
            // Tickets are single-use and short-lived: one more, freshly minted, before giving up.
            reminted = true
            Task { await dial() }
            return
        }
        report(.closed(reason))
    }

    private func report(_ event: Event) {
        onEvent?(event)
    }
}
