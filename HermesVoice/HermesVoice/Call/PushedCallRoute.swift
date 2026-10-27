import Foundation

/// Where a call Hermes rang runs: in its session's chat, or on its own under the push's title.
enum PushedCallRoute: Equatable {
    case chat(SessionSummary)
    case standalone
}

/// Picks the route for a VoIP push. Since calls can come from any session (M6b), a push's `session_id` may name a
/// conversation the dashboard can't open: a messaging chat run by the messaging gateway, a CLI or TUI session, or a
/// gateway-local one (`local-…`). The call is always reported and run; it opens a chat only when the session is
/// one this app can resume over `/api/ws`:
/// - a chat this app already holds for it,
/// - else a session the dashboard stores (`GET /api/sessions/:id`; the row gives its title and profile),
/// - else a session live in the dashboard process (`session.active_list`, by stored or runtime id).
///
/// Anything else runs standalone, with no `session.resume` at all: probing an unknown key that way would make
/// Hermes mint an empty row for it, and a chat that can't attach would retry its resume for the whole call.
/// Each lookup is bounded by `timeout`; one that fails or runs out counts as "not found".
@MainActor
struct PushedCallRouter {
    /// A chat the app already has open (or cached) for a stored id.
    var openChat: (String) -> SessionSummary?
    /// The stored session (`GET /api/sessions/:id`, `profile` its store); nil when the dashboard has no such row.
    var stored: (String, String?) async throws -> SessionInfo?
    /// A session live in the dashboard process (`session.active_list`).
    struct LiveRow: Equatable {
        var runtime: String
        var stored: String
        var title: String = ""
    }

    /// The dashboard's live sessions.
    var live: () async throws -> [LiveRow]
    var timeout: TimeInterval = 8

    func route(_ push: CallPush) async -> PushedCallRoute {
        guard let id = push.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return .standalone }
        if let summary = openChat(id) { return .chat(summary) }
        let title = push.title ?? "Hermes"
        let stored = self.stored
        if let found = await Self.within(timeout, { try await stored(id, push.profile) }) ?? nil {
            let name = found.title ?? found.preview ?? title
            return .chat(SessionSummary(id: found.id, title: name, lastActive: found.lastActive, profile: found.profile ?? push.profile))
        }
        let live = self.live
        if let sessions = await Self.within(timeout, { try await live() }),
           let match = sessions.first(where: { $0.stored == id || $0.runtime == id }), !match.stored.isEmpty {
            return .chat(SessionSummary(id: match.stored, title: match.title.isEmpty ? title : match.title,
                                        lastActive: nil, profile: push.profile))
        }
        return .standalone
    }

    /// `work`'s result, or nil when it fails or takes longer than `seconds` (it is cancelled then).
    static func within<T>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async throws -> T) async -> T? {
        let race = DeadlineRace<T>()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.task = Task { @MainActor in
                let value = try? await work()
                race.finish(value)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                race.task?.cancel()
                race.finish(nil)
            }
        }
    }
}

/// A lookup against its deadline: whichever ends first answers, once.
@MainActor
private final class DeadlineRace<T> {
    var continuation: CheckedContinuation<T?, Never>?
    var task: Task<Void, Never>?

    func finish(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

extension PushedCallRouter {
    /// Looks over this sign-in's dashboard and gateway.
    static func live(client: DashboardClient, connection: GatewayConnection,
                     openChat: @escaping (String) -> SessionSummary?) -> PushedCallRouter {
        PushedCallRouter(
            openChat: openChat,
            stored: { id, profile in try await client.storedSession(id, profile: profile) },
            live: {
                try await connection.client.sessionActiveList().sessions.map {
                    LiveRow(runtime: $0.id, stored: $0.sessionKey, title: $0.title)
                }
            }
        )
    }
}

extension DashboardClient {
    /// One stored session (`GET /api/sessions/:id`); nil when the store holds no such session.
    func storedSession(_ id: String, profile: String?) async throws -> SessionInfo? {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        do {
            let row = try await request("GET", "/api/sessions/\(encoded)", query: profile.map { ["profile": $0] } ?? [:]) as? JSON
            return row.flatMap(SessionInfo.init(row:))
        } catch DashboardError.http(404, _) {
            return nil
        }
    }
}
