import Foundation

/// One `/events` socket: text frames until it ends.
@MainActor
protocol KanbanEventConnection: AnyObject, Sendable {
    /// The next text frame; throws once the socket ended.
    func receive() async throws -> String
    /// Resolves once the handshake succeeded (a pong came back); throws when it didn't.
    func confirmOpen() async throws
    /// How the socket ended, read after `receive` threw.
    var ending: KanbanSocketEnding { get }
    func close()
    /// Ends the socket from any thread (a cancelled task: a pending `receive` throws).
    nonisolated func abort()
}

/// Why a socket ended: refused at the handshake (credentials, or the plugin is off), closed by the host as a
/// policy violation once open (the board was archived or deleted), or dropped (network, host restart).
enum KanbanSocketEnding: Equatable {
    case refused
    case policy
    case dropped
}

/// Opens `/events` sockets pinned to a board.
@MainActor
protocol KanbanEventDialing {
    func dial(board: String?, since: Int?) async throws -> KanbanEventConnection
}

/// The dashboard's `/api/plugins/kanban/events` socket, authenticated with a fresh one-use ws-ticket per dial
/// (the same credential the app's gateway socket uses; browsers can't set headers on an upgrade).
@MainActor
struct KanbanSocketDialer: KanbanEventDialing {
    let client: DashboardClient

    func dial(board: String?, since: Int?) async throws -> KanbanEventConnection {
        let ticket = try await client.webSocketTicket()
        let query = KanbanAPI.eventsQuery(board: board, since: since, ticket: ticket)
        var components = URLComponents(url: client.url(KanbanAPI.root + "/events", query: query), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!)
        request.setValue("hermes-voice", forHTTPHeaderField: "X-Conduit-Client")
        let task = client.session.webSocketTask(with: request)
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
        return KanbanSocketConnection(task: task)
    }
}

@MainActor
final class KanbanSocketConnection: KanbanEventConnection {
    private let task: URLSessionWebSocketTask
    private var closed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func confirmOpen() async throws {
        let task = task
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    var ending: KanbanSocketEnding {
        if let status = (task.response as? HTTPURLResponse)?.statusCode, [401, 403, 404].contains(status) { return .refused }
        if task.closeCode == .policyViolation { return .policy }
        return .dropped
    }

    func close() {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
    }

    nonisolated func abort() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
