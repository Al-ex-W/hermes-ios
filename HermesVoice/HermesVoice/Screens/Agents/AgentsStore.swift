import Combine
import Foundation

/// A chat the spawn tree knows about: the session the user is in (its finished subagents stay listed), and whose
/// title and profile the tree's actions use.
@MainActor
protocol AgentsSessionSource: AnyObject {
    /// The live session id `subagent.*` frames carry; nil until attached.
    var runtimeSessionID: String? { get }
    var storedSessionID: String? { get }
    var sessionTitle: String { get }
    var sessionProfile: String? { get }
}

extension ChatModel: AgentsSessionSource {
    var storedSessionID: String? { storedID }
    var sessionTitle: String { title }
    var sessionProfile: String? { profile }
}

/// The spawn tree's state for the whole app (the desktop's `$subagentsBySession`): it listens to the connection's
/// `subagent.*` frames from the moment it is made, so it should live as long as the signed-in shell (one per
/// connection), not only while the Agents screen shows. While the screen shows it also polls `subagent.list` every
/// 5 s (the desktop's safety net: a silent exit sends no frame), for the session the user is in and every session
/// with live rows; live frames stay authoritative over the roster.
@MainActor
final class AgentsStore: ObservableObject {
    @Published private(set) var roster = AgentRoster()
    /// The chat the user is in (`focus(_:)`); its runtime id is read when needed, since it changes on re-attach.
    @Published private(set) var focusRevision = 0
    @Published private(set) var refreshing = false
    /// The last control's outcome ("Stop requested", "Queued for the next checkpoint", or why it failed).
    @Published var notice: String?

    static let pollInterval: TimeInterval = 5
    /// A session whose roster read failed this many times in a row isn't asked again until refreshed by hand
    /// (an older backend without `subagent.list`, or a session no longer attached here).
    static let maxFailures = 3

    private let connection: GatewayConnection
    private let now: () -> Date
    private var listener: UUID?
    private var stateListener: UUID?
    private var polling: Task<Void, Never>?
    /// Trees on screen (`startPolling` minus `stopPolling`).
    private var viewers = 0
    private weak var focused: (any AgentsSessionSource)?
    /// Chats the store was told about, for titles and profiles.
    private var known: [WeakSource] = []
    private var failures: [String: Int] = [:]

    private struct WeakSource {
        weak var source: (any AgentsSessionSource)?
    }

    init(connection: GatewayConnection, now: @escaping () -> Date = Date.init) {
        self.connection = connection
        self.now = now
        listener = connection.addListener { [weak self] event, sessionID, _ in
            self?.handle(event, session: sessionID)
        }
        stateListener = connection.addStateListener { [weak self] state in
            guard let self, state == .connected, self.polling != nil else { return }
            Task { await self.refresh() }
        }
    }

    deinit {
        polling?.cancel()
        let connection = connection, ids = [listener, stateListener].compactMap { $0 }
        Task { @MainActor in ids.forEach(connection.removeListener) }
    }

    private var client: GatewayClient { connection.client }

    // MARK: Sessions

    /// The user is in `source`'s chat: its finished subagents show in the tree. Call when a chat shows.
    func focus(_ source: (any AgentsSessionSource)?) {
        if let source { note(source) }
        guard focused !== source else { return }
        focused = source
        focusRevision += 1
    }

    /// Remembers a chat's title and profile without moving the focus to it.
    func note(_ source: any AgentsSessionSource) {
        known.removeAll { $0.source == nil }
        if !known.contains(where: { $0.source === source }) { known.append(WeakSource(source: source)) }
    }

    /// The runtime session whose finished rows show: the focused chat's, else (nothing focused yet) the session
    /// with the newest subagent activity.
    var focusSession: String? {
        if let runtime = focused?.runtimeSessionID { return runtime }
        return roster.bySession.compactMap { session, agents in agents.map(\.updatedAt).max().map { (session, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// The chat that owns `runtimeID`, when the store was told about it.
    func source(for runtimeID: String) -> (any AgentsSessionSource)? {
        if let focused, focused.runtimeSessionID == runtimeID { return focused }
        return known.lazy.compactMap(\.source).first { $0.runtimeSessionID == runtimeID }
    }

    /// The profile a subagent's controls and sessions belong to (its parent chat's).
    func profile(of agent: AgentProgress) -> String? { source(for: agent.ownerSession)?.sessionProfile }

    /// The stored session of the chat that started it.
    func parentStoredSession(of agent: AgentProgress) -> String? { source(for: agent.ownerSession)?.storedSessionID }

    /// The tree in the panel's scope.
    var tree: [AgentNode] { AgentTree.build(roster.panel(focus: focusSession)) }

    // MARK: Frames

    func handle(_ event: GatewayEvent, session: String?) {
        guard let session else { return }
        switch event {
        case .messageStart:
            // A new turn: the last turn's finished rows go, background children that outlived it stay.
            roster.pruneFinished(session: session)
        case let .subagentSpawnRequested(payload):
            apply("subagent.spawn_requested", AgentPayload(payload), session: session)
        case let .subagentStart(payload):
            apply("subagent.start", AgentPayload(payload), session: session)
        case let .subagentProgress(payload):
            apply("subagent.progress", AgentPayload(payload), session: session)
        case let .subagentThinking(payload):
            apply("subagent.thinking", AgentPayload(payload), session: session)
        case let .subagentTool(payload):
            apply("subagent.tool", AgentPayload(payload), session: session)
        case let .subagentComplete(payload):
            apply("subagent.complete", AgentPayload(payload), session: session)
        case let .unknown(type, payload) where type.hasPrefix("subagent.") && type != "subagent.text":
            // A frame outside the contract (another Hermes version) still updates its row.
            apply(type, AgentPayload(json: payload ?? .null), session: session)
        default:
            break
        }
    }

    /// The desktop creates rows only on spawn/start; this phone often attaches mid-run (a resume after the
    /// background), so any live frame creates its row. A completion for a row never seen doesn't.
    private func apply(_ type: String, _ payload: AgentPayload, session: String) {
        roster.upsert(session: session, payload: payload, createIfMissing: type != "subagent.complete",
                      eventType: type, now: now())
    }

    // MARK: Roster

    /// Reads `subagent.list` for the focused session and every session with live rows. `manual` asks again
    /// sessions whose reads kept failing.
    func refresh(manual: Bool = false) async {
        if manual { failures = [:] }
        var sessions = Set(roster.bySession.filter { $0.value.contains(where: \.isLive) }.keys)
        if let focus = focused?.runtimeSessionID { sessions.insert(focus) }
        let due = sessions.filter { (failures[$0] ?? 0) < Self.maxFailures }.sorted()
        guard !due.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        for session in due {
            await refresh(session)
        }
    }

    private func refresh(_ session: String) async {
        let before = roster.agents(in: session)
        do {
            let result = try await client.subagentList(.init(sessionId: session, profile: source(for: session)?.sessionProfile))
            failures[session] = 0
            // A frame that landed while the read was out is newer than the roster: keep it.
            guard roster.agents(in: session) == before else { return }
            roster.reconcile(session: session, children: (result.subagents ?? []).map { AgentPayload($0) },
                             failed: (result.delegations ?? []).map { AgentPayload($0) }, now: now())
        } catch {
            guard !error.isCancellation else { return }
            failures[session, default: 0] += 1
        }
    }

    /// Polls while a tree is on screen; each `startPolling` is paired with a `stopPolling`. Two trees can show at
    /// once (iPad: one pushed on a chat, one in the bottom bar's overlay), and the one that appears runs its
    /// `onAppear` before the other's `onDisappear`, so the poll stops only when the last of them goes.
    func startPolling() {
        viewers += 1
        guard polling == nil else { return }
        polling = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        polling?.cancel()
        polling = nil
    }

    /// Whether the safety-net poll runs.
    var isPolling: Bool { polling != nil }

    // MARK: Controls (the desktop's `SubagentControls` and `SubagentTranscript`)

    /// Hard-interrupts one live child through the session that owns it; true once Hermes found it.
    @discardableResult
    func interrupt(_ agent: AgentProgress) async -> Bool {
        do {
            let result = try await client.subagentInterrupt(.init(sessionId: agent.ownerSession, profile: profile(of: agent),
                                                                  subagentId: agent.id))
            notice = result.found ? "Stop requested" : "The subagent did not accept the request"
            return result.found
        } catch {
            notice = "The subagent did not accept the request"
            return false
        }
    }

    /// Queues steering text for a live child; true once queued.
    @discardableResult
    func steer(_ agent: AgentProgress, _ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let result = try? await client.subagentSteer(.init(sessionId: agent.ownerSession, profile: profile(of: agent),
                                                           subagentId: agent.id, text: trimmed))
        let queued = result?.status == .queued
        notice = queued ? "Queued for the next checkpoint" : "The subagent did not accept the request"
        return queued
    }

    /// The last 16 KB of a live child's transcript.
    func tail(_ agent: AgentProgress) async throws -> SubagentTailResult {
        try await client.subagentTail(.init(sessionId: agent.ownerSession, profile: profile(of: agent), subagentId: agent.id))
    }
}
