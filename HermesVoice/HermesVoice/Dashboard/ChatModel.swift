import Foundation

/// One conversation: its stored transcript from REST and its live turns over the gateway connection, folded into one
/// `Transcript`, with the composer, send queue and status stack that act on it.
/// While the chat is in use (on screen, or in a call) the connection re-attaches its session after a reconnect and
/// replays what it missed, and when events were lost anyway the stored transcript is fetched again by itself. A chat
/// not in use catches up when it is next opened or sends.
@MainActor
final class ChatModel: ObservableObject, Identifiable, GatewaySessionOwner {
    /// Where the chat asks the app to go (a slash command, an error card's recovery).
    enum Route: Equatable {
        case newChat
        case sessions
        case session(SessionSummary)
        /// The subagent tree (the status stack's Agents button).
        case agents
        /// The memory graph (`/journey`, `/learning`, `/memory-graph`).
        case memoryGraph
    }

    @Published private(set) var transcript = Transcript()
    @Published private(set) var busy = false
    @Published private(set) var title: String
    @Published var error: String?
    /// Every runtime id the session had, and its stored id: the sessions this chat's prompts can name.
    @Published private(set) var sessionIDs: Set<String> = []
    /// The live session prompts go out with; nil until attached, and once Hermes reclaimed it.
    @Published private(set) var runtimeID: String?
    /// Stored rows older than the ones shown exist (`loadOlder`).
    @Published private(set) var hasOlderHistory = false
    @Published private(set) var loadingOlder = false
    /// Which rows the host's display settings show (`display.show_reasoning`, `display.tool_progress`).
    @Published private(set) var display = TranscriptDisplay()

    let id = UUID()
    /// The profile whose store holds this chat; nil for the dashboard's own.
    let profile: String?
    private(set) var storedID: String?
    /// Told the stored key of a new chat once it has one and a prompt went through, so empty drafts aren't kept.
    var onStoredID: ((String) -> Void)?
    /// Opens what the chat asks for; set by the screen showing it.
    var navigate: ((Route) -> Void)?
    /// The folder a new chat's session starts in (a worktree's "New chat here"); nil uses the profile's default
    /// project folder, or the host's.
    var startFolder: String?

    /// The folder the session works in as far as this chat knows: the start folder of a new chat.
    var workingFolder: String? { startFolder ?? DefaultProjectFolder.dir(base: client.base, profile: profile) }

    /// The send decision tree and its local queue. They live with the chat, so the queue outlives the screen.
    private(set) lazy var sender = SendController(chat: self, ownedByChat: true)
    private(set) lazy var composer: ComposerModel = {
        let composer = ComposerModel(sender: sender, connection: connection, profile: profile)
        composer.rewind = { [weak self] message, text in await self?.rewind(message, to: text) ?? false }
        composer.promptsAfter = { [weak self] message in self?.promptsAfter(message) ?? 0 }
        return composer
    }()
    private(set) lazy var status = StatusStackModel(connection: connection, chat: self, profile: profile)

    /// The socket dropped since the session was attached: `runtimeID` waits for the connection's re-attach.
    private var detached = false
    private let client: DashboardClient
    private let connection: GatewayConnection
    private weak var prompts: PromptCenter?
    private let isNew: Bool
    private var listeners: [UUID] = []
    private var attaching: Task<LiveSession?, Error>?
    private var resyncing: Task<Void, Never>?
    private var lastSend: Task<Delivery, Never>?
    private var users: Set<String> = []
    private var loaded: Bool
    /// Events were lost: the stored transcript must be fetched again.
    private var needsResync = false
    /// Bumped when the socket drops, so an attach answered on the old socket isn't trusted.
    private var epoch = 0
    /// Bumped on every finished turn, so a history fetch that raced one is redone.
    private var completions = 0
    /// open() asked for the stored transcript again (another client may have added to it).
    private var wantsReload = false
    /// The stored rows shown, oldest first, and how many rows back from the newest they reach.
    private var storedRows: [JSONValue] = []
    private var pagedThrough = 0
    /// The oldest stored page came back short: nothing older exists.
    private var olderExhausted = false
    /// The transcript rows the stored rows made; every other row is local or live.
    private var storedItems: Set<String> = []
    /// The text each local prompt row sent (a row shows the projection, or a command's display text).
    private var localPrompts: [String: String] = [:]
    /// Local prompt rows Hermes may not have stored yet: delivery in flight, or it couldn't be confirmed.
    /// A history reload keeps them until it finds their text.
    private var unconfirmed: Set<String> = []
    /// Unconfirmed rows that are corrections the running turn took: Hermes stores one when it applies it, so one
    /// still missing once the turn is over was never applied.
    private var corrections: Set<String> = []
    /// The session was deleted: nothing attaches it again.
    private var deleted = false
    /// The newest stored row id seen in a fetched transcript (ids only grow).
    private var newestStored = 0
    /// Per local prompt row, `newestStored` when it was sent: Hermes' stored copy of it can only be newer.
    /// Missing when nothing stored had been fetched yet for a chat that has some.
    private var sentAfter: [String: Int] = [:]
    /// Prompts that didn't get through, by text. Sending the same text again reuses the row, and when it is
    /// unknown whether Hermes got the first one (`maybeArrived`), checks before sending it a second time.
    private var undelivered: [String: (row: String, maybeArrived: Bool)] = [:]
    /// A prompt went through (or the chat was stored already), so a new chat is worth keeping.
    private var hasPrompt: Bool
    private var reportedID: String?
    /// The slash command running, for the label of its output rows.
    private var slashCommand = ""
    /// A command rewrote the stored transcript: the reload keeps its output rows.
    private var keepingSlashOutput = false
    /// A turn this chat didn't watch runs (attached mid-turn): the next reload draws it from Hermes' snapshot.
    private var projection: LiveTurnSnapshot?
    /// Rows drawn from a snapshot or a rewind stand in for Hermes' stored copy: fetch it once the turn ends.
    private var reloadAfterTurn = false
    /// Why the last delivery failed (a rewind tells a stale target from other refusals).
    private var lastDeliveryError: Error?
    /// The stored row Hermes reported for the prompt just delivered (`user_row_id`).
    private var acceptedRowID: Int?
    /// When Stop last interrupted a turn here.
    private var lastInterrupt: Date?

    /// How a prompt's delivery ended.
    private enum Delivery { case delivered, failed, unknown }

    /// A user prompt in a stored page: its `messages.id` and text.
    private typealias StoredPrompt = (id: Int, text: String)

    static let pageSize = 200
    /// The most rows the dashboard returns in one page.
    static let maxPage = 500

    /// `profile` is where a new chat (`summary` nil) is created; a stored one lives in its summary's profile.
    init(client: DashboardClient, connection: GatewayConnection, prompts: PromptCenter? = nil, summary: SessionSummary?,
         profile: String? = nil) {
        self.client = client
        self.connection = connection
        self.prompts = prompts
        storedID = summary?.id
        self.profile = summary.map(\.profile) ?? profile
        title = summary?.title ?? "New chat"
        isNew = summary == nil
        loaded = summary == nil
        hasPrompt = summary != nil
        if let storedID { sessionIDs = [storedID] }
        listeners = [
            connection.addListener { [weak self] event, sessionID, seq in self?.handle(event, sessionID: sessionID, seq: seq) },
            connection.addStateListener { [weak self] state in
                if state == .disconnected { self?.socketClosed() }
            },
        ]
    }

    deinit {
        let connection = connection, listeners = listeners
        Task { @MainActor in for listener in listeners { connection.removeListener(listener) } }
    }

    private var isInUse: Bool { !users.isEmpty }

    /// Attached on the live socket, so prompts can go out with `runtimeID`.
    private var isAttached: Bool { runtimeID != nil && !detached && connection.isConnected }

    /// The live session while attached; nil while the chat waits for a re-attach (an id from before may be gone).
    var attachedRuntimeID: String? { isAttached ? runtimeID : nil }

    /// Something was sent or shown in it, so it's no longer an empty draft.
    var hasContent: Bool { !transcript.items.isEmpty }

    /// Started here rather than opened from the list.
    var isNewChat: Bool { isNew }

    /// The session menu's actions, over this chat's client and connection.
    var sessionActions: SessionActions { SessionActions(client: client, connection: connection) }

    /// Marks the chat in use by `key` ("view", or "call-<call id>" per call, so one call's late release can't end
    /// another's hold). While in use, a dropped socket is caught up on by itself.
    func setInUse(_ key: String, _ inUse: Bool) {
        if inUse { users.insert(key) } else { users.remove(key) }
        updateTracking()
        if inUse, needsResync || detached { scheduleResync() }
    }

    /// Only a chat in use has the connection re-attach its session after a drop. Any other stays detached until it
    /// is next attached, so Hermes reaps its idle runtime and nothing rebuilds one for a chat nobody looks at.
    private func updateTracking() {
        if isInUse, let runtimeID {
            connection.track(self, runtimeID: runtimeID, storedID: storedID, profile: profile)
        } else {
            connection.untrack(self)
        }
    }

    /// Shows the stored transcript and attaches to the live session. The transcript is fetched again on every open
    /// while no turn is running (another client may have added to it), and after a disconnect.
    func open() async {
        wantsReload = true
        await resync()
        await refreshDisplay()
    }

    /// Reads the host's display settings for the transcript (`config.get full`).
    func refreshDisplay() async {
        guard let config = try? await connection.client.configGet(.init(profile: profile, key: "full")).config,
              let settings = config["display"]?.objectValue else { return }
        let next = TranscriptDisplay(showReasoning: settings["show_reasoning"], toolProgress: settings["tool_progress"])
        if next != display { display = next }
    }

    /// The app is back in the foreground: catch up if the chat is in use and lost its session meanwhile.
    func wake() {
        guard isInUse, runtimeID == nil || detached || needsResync else { return }
        scheduleResync()
    }

    /// Attaches now (a call's hello needs the stored key); afterwards `storedID` is set.
    func ensureAttached() async throws {
        try await attach()
        if needsResync, isInUse { scheduleResync() }
    }

    // MARK: Attaching

    /// Resumes the stored session on the gateway (or creates one) and keeps the runtime id prompts need.
    /// Connecting first lets the connection re-attach the session the chat had before a drop. Single flight;
    /// returns the resume/create result, or nil when already attached. `fresh` always asks Hermes again.
    @discardableResult
    private func attach(fresh: Bool = false) async throws -> LiveSession? {
        if deleted { throw DashboardError.rpc("This session was deleted.") }
        if !fresh, isAttached { return nil }
        if let attaching {
            let result = try await attaching.value
            if !fresh || result != nil { return result }
            return try await attach(fresh: true)
        }
        let task = Task { () throws -> LiveSession? in
            defer { attaching = nil }
            for _ in 0..<2 {
                let epoch = self.epoch
                do {
                    try await connection.connect()
                } catch {
                    throw error.wasNotSent ? error : DashboardError.notSent(error)
                }
                if !fresh, isAttached { return nil }
                let session: LiveSession
                if let storedID {
                    session = try await LiveSession.attach({
                        try await connection.client.sessionResume(.init(
                            sessionId: storedID, profile: profile, cols: 96, source: "desktop", omitMessages: true
                        ))
                    }, LiveSession.init)
                } else {
                    // A model, effort or Fast picked before the session existed runs from its first turn. A retried
                    // create whose answer was lost gets the same session back.
                    let pick = composer.pendingModel, effort = composer.pendingEffort, fast = composer.pendingFast
                    session = try await LiveSession.attach({
                        try await connection.client.sessionCreate(.init(
                            profile: profile, cols: 96, source: "desktop",
                            cwd: workingFolder,
                            model: pick?.model, provider: pick?.provider,
                            reasoningEffort: effort, fast: fast, idempotencyKey: id.uuidString
                        ))
                    }, LiveSession.init)
                    composer.pendingApplied(pick, effort: effort, fast: fast)
                }
                // The socket dropped while this was answered: ask again on the new one.
                guard epoch == self.epoch else { continue }
                apply(session)
                return session
            }
            throw DashboardError.disconnected
        }
        attaching = task
        return try await task.value
    }

    /// Takes the attached session. `replays`: the connection re-attached it and replays what it missed, so a turn
    /// that was streaming is finished by the replay (or a refetch is asked for).
    private func apply(_ session: LiveSession, replays: Bool = false) {
        runtimeID = session.runtimeID
        detached = false
        if let key = session.storedID ?? (storedID == nil ? session.runtimeID : nil), key != storedID {
            storedID = key
            reportStoredID()
        }
        for id in [session.runtimeID, storedID].compactMap({ $0 }) where !sessionIDs.contains(id) { sessionIDs.insert(id) }
        updateTracking()
        busy = session.running
        if !replays, !transcript.turnRunning, session.running || session.inflight?.error != nil {
            // A turn this chat didn't see run (or a failure Hermes kept for a client that missed it): the next
            // reload draws it from the snapshot.
            projection = LiveTurnSnapshot(session.inflight, queued: session.queuedPrompt)
            needsResync = true
        }
        if session.running || session.todos != nil { status.restoreTodos(session.todos, running: session.running) }
        if session.running, !transcript.turnRunning {
            transcript.apply(.sessionInfo(SessionLiveInfo(running: true)))
        } else if !replays, !session.running, transcript.turnRunning {
            // The turn that was streaming ended while detached; the stored copy replaces it.
            endLiveTurn()
            needsResync = true
        }
    }

    /// The transcript stops waiting for a turn that won't report its end.
    private func endLiveTurn() {
        guard transcript.turnRunning else { return }
        transcript.apply(.sessionInfo(SessionLiveInfo(running: false)))
    }

    // MARK: Reconnects

    func gatewayReattached(_ session: LiveSession) {
        apply(session, replays: true)
    }

    func gatewayNeedsRefetch() {
        // A turn cut short by the lost events is replaced by the stored copy.
        if !busy { endLiveTurn() }
        needsResync = true
        if isInUse { scheduleResync() }
    }

    func gatewayReattachFailed(_ error: Error) {
        runtimeID = nil
        detached = false
        needsResync = true
        if isInUse { scheduleResync() }
    }

    /// Hermes keeps the turn running but sends its events nowhere until the connection re-attaches the session.
    private func socketClosed() {
        epoch += 1
        guard runtimeID != nil, !detached else { return }
        detached = true
        if isInUse { scheduleResync(after: 1) }
    }

    // MARK: Catching up

    /// Attaches, then reloads the stored transcript when it may be stale (first open, or events lost while
    /// detached). Single flight; retries with backoff while the chat is in use.
    func resync() async {
        if let resyncing { return await resyncing.value }
        let task = Task {
            defer { resyncing = nil }
            await runResync()
        }
        resyncing = task
        await task.value
    }

    private func runResync() async {
        let delays: [UInt64] = [0, 2, 5, 10]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * NSEC_PER_SEC)
                guard isInUse else { return }
            }
            let epoch = self.epoch
            do {
                var attachError: Error?
                do { try await attach() } catch { attachError = error }
                // Show what is stored even when the live session can't be reached. A reopen while a turn
                // streams keeps what it has: the stored copy lacks the reply in progress.
                if !loaded || needsResync || projection != nil || (wantsReload && !transcript.turnRunning && !busy) {
                    try await reloadHistory()
                }
                wantsReload = false
                if let attachError { throw attachError }
                guard epoch == self.epoch else { continue }
                needsResync = false
                return
            } catch {
                if error.isCancellation { return }
                if error.isRefusal || attempt == delays.count - 1 {
                    // Nothing will report how a turn that was running ends until the session is attached again.
                    if runtimeID == nil || detached {
                        busy = false
                        endLiveTurn()
                    }
                    if users.contains("view") { self.error = error.localizedDescription }
                    return
                }
            }
        }
    }

    private func scheduleResync(after seconds: UInt64 = 0) {
        Task {
            if seconds > 0 { try? await Task.sleep(nanoseconds: seconds * NSEC_PER_SEC) }
            guard isInUse, needsResync || runtimeID == nil || detached else { return }
            await resync()
        }
    }

    /// Replaces the transcript with the stored one (as far back as was paged), keeping the turn still running,
    /// rows that arrived during the fetch, and prompts Hermes may not have stored yet.
    private func reloadHistory() async throws {
        guard let storedID else { loaded = true; return }
        for attempt in 0..<2 {
            let before = Set(transcript.items.map(\.id))
            let pending = unconfirmed
            let finished = completions
            let limit = min(Self.maxPage, max(Self.pageSize, pagedThrough))
            let page: [JSONValue]
            do {
                page = try await client.messageRows(sessionID: storedID, profile: profile, limit: limit)
            } catch DashboardError.http(404, _) where isNew {
                // A new chat has no stored rows until its first prompt.
                loaded = true
                return
            }
            // A turn that ended during the fetch may or may not be in this copy: fetch once more.
            if finished != completions, attempt == 0 { continue }
            if page.count < limit {
                storedRows = page
                olderExhausted = true
            } else {
                // Pages paged in before stay; the newest page replaces whatever they share.
                let oldest = page.first.flatMap(Self.rowID) ?? .min
                storedRows = storedRows.filter { (Self.rowID($0) ?? .max) < oldest } + page
            }
            pagedThrough = max(pagedThrough, limit)
            hasOlderHistory = !olderExhausted
            show(storedRows, before: before, pending: pending)
            loaded = true
            return
        }
    }

    /// Shows the stored page before the oldest one shown.
    func loadOlder() async {
        guard hasOlderHistory, !loadingOlder, let storedID else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await client.messageRows(sessionID: storedID, profile: profile, limit: Self.pageSize, offset: pagedThrough)
            // New rows stored since shift the pages: what overlaps is already shown.
            let oldest = storedRows.first.flatMap(Self.rowID) ?? .max
            let older = page.filter { (Self.rowID($0) ?? .min) < oldest }
            pagedThrough += Self.pageSize
            if page.count < Self.pageSize { olderExhausted = true }
            hasOlderHistory = !olderExhausted
            guard !older.isEmpty else { return }
            storedRows = older + storedRows
            let keep = Set(transcript.items.map(\.id)).subtracting(storedItems)
            transcript.load(history: storedRows, keeping: keep)
            storedItems = Set(transcript.items.map(\.id)).subtracting(keep)
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    /// Lays `rows` under the local and live rows: a local prompt stays while it may be unstored (and isn't found
    /// in `rows`), and a row of the running turn or one that arrived during the fetch (not in `before`) stays.
    private func show(_ rows: [JSONValue], before: Set<String>, pending: Set<String>) {
        noteStored(rows)
        let local = transcript.rows.compactMap { item in localPrompts[item.id].map { (row: item.id, text: $0) } }
        let stored = storedPrompts(Self.prompts(in: rows), local)
        let running = transcript.runningTurnIDs
        // A prompt held for the next turn stays until Hermes stored it.
        for prompt in transcript.nextPrompts where stored.contains(prompt.id) {
            transcript.remove(id: prompt.id)
            unconfirmed.remove(prompt.id)
        }
        var keep: Set<String> = []
        for item in transcript.items where !storedItems.contains(item.id) {
            guard localPrompts[item.id] != nil else {
                if running.contains(item.id) || !before.contains(item.id) || (keepingSlashOutput && Self.isSlashOutput(item)) {
                    keep.insert(item.id)
                }
                continue
            }
            guard pending.contains(item.id) || unconfirmed.contains(item.id) || !before.contains(item.id) else { continue }
            if stored.contains(item.id) {
                unconfirmed.remove(item.id)
                corrections.remove(item.id)
                continue
            }
            if corrections.contains(item.id), !busy, !transcript.turnRunning {
                unconfirmed.remove(item.id)
                corrections.remove(item.id)
                continue
            }
            keep.insert(item.id)
        }
        // A turn this chat didn't watch is drawn from Hermes' snapshot, unless it ended meanwhile.
        let live = projection.flatMap { busy || $0.error != nil ? $0 : nil }
        projection = nil
        let projected = transcript.load(history: rows, keeping: keep, projecting: live, key: "live-\(runtimeID ?? "session")")
        if live != nil, busy { reloadAfterTurn = true }
        storedItems = Set(transcript.items.map(\.id)).subtracting(keep).subtracting(projected)
        let waiting = Set(transcript.nextPrompts.map(\.id))
        localPrompts = localPrompts.filter { keep.contains($0.key) || waiting.contains($0.key) }
        sentAfter = sentAfter.filter { keep.contains($0.key) || waiting.contains($0.key) }
    }

    private nonisolated static func isSlashOutput(_ item: TranscriptItem) -> Bool {
        if case let .system(note) = item, case .slash = note.kind { return true }
        return false
    }

    private func noteStored(_ rows: [JSONValue]) {
        newestStored = max(newestStored, rows.compactMap(Self.rowID).max() ?? 0)
    }

    /// The local prompt rows (oldest first, delivered ones included) that Hermes has stored. Each claims, in the
    /// order they were sent, the first stored user row newer than what was known when it went out that holds it
    /// as a whole run of lines (Hermes merges prompts into one row: queued ones with a blank line between them,
    /// corrections steered in during one tool batch with a newline). So the stored copy of a delivered prompt
    /// can't stand in for a later one with the same words, and only the rows still awaiting confirmation are left
    /// to match the newest stored ones.
    private func storedPrompts(_ users: [StoredPrompt], _ local: [(row: String, text: String)]) -> Set<String> {
        let have = users.enumerated().flatMap { index, user in Self.parts(user.text).map { (user: index, id: user.id, text: $0) } }
        var next = 0
        var stored: Set<String> = []
        for (index, row) in local.enumerated() {
            let wanted = Self.parts(row.text)
            guard !wanted.isEmpty, have.count - next >= wanted.count else { continue }
            let after = sentAfter[row.row]
            // Sent before anything stored was known: only the newest stored rows, one per prompt sent since, qualify.
            let recent = after == nil ? Set(users.indices.suffix(local.count - index)) : []
            let match = (next...(have.count - wanted.count)).first { start in
                let run = have[start..<(start + wanted.count)]
                guard run.allSatisfy({ $0.user == have[start].user }), run.map(\.text) == wanted else { return false }
                if let after { return have[start].id > after }
                return recent.contains(have[start].user)
            }
            guard let match else { continue }
            stored.insert(row.row)
            next = match + wanted.count
        }
        return stored
    }

    /// The user prompts of stored rows, oldest first, as Hermes stored their text.
    private nonisolated static func prompts(in rows: [JSONValue]) -> [StoredPrompt] {
        rows.compactMap { row in
            guard let object = row.objectValue, object["role"]?.stringValue == "user",
                  object["display_kind"]?.stringValue != "hidden" else { return nil }
            return (Transcript.rowID(object) ?? .max, Transcript.text(object["display_content"] ?? object["content"]))
        }
    }

    private nonisolated static func rowID(_ row: JSONValue) -> Int? {
        row.objectValue.flatMap(Transcript.rowID)
    }

    /// A prompt's non-empty lines, trimmed: the parts Hermes' merges (blank line or newline between prompts) keep whole.
    private nonisolated static func parts(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether `held` (a queued, running or stored prompt, possibly several merged) holds `text` as a whole run of lines.
    private nonisolated static func holds(_ held: String, _ text: String) -> Bool {
        let have = parts(held), wanted = parts(text)
        guard !wanted.isEmpty, have.count >= wanted.count else { return false }
        return (0...(have.count - wanted.count)).contains { Array(have[$0..<($0 + wanted.count)]) == wanted }
    }

    // MARK: Prompts

    /// The newest prompt row: the user's message, or a call marker standing for one.
    private var lastPromptID: String? {
        transcript.items.last { item in
            switch item {
            case .user: return true
            case let .system(note): return note.kind == .call
            default: return false
            }
        }?.id
    }

    /// Sends a prompt; true once Hermes accepted it. `queued` has Hermes run it after the current turn
    /// instead of steering or interrupting it. Prompts go out one at a time, in order. `display` is what its
    /// bubble shows instead of the text (a skill command, not its expanded body).
    @discardableResult
    func send(_ text: String, queued: Bool = false, display: String? = nil) async -> Bool {
        await sendPrompt(text, queued: queued, display: display) == .delivered
    }

    /// `send`, saying how the delivery ended. `truncate`: the stored prompt this one replaces, with everything after
    /// it (a rewind); `rebind`: the stored ids shown, for Hermes to say what they became.
    private func sendPrompt(_ text: String, queued: Bool = false, display: String? = nil, truncate: Int? = nil,
                            rebind: [Int]? = nil) async -> Delivery {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failed }
        // Sending again what didn't get through keeps its bubble while that is still the newest prompt.
        let retry = undelivered.removeValue(forKey: text)
        let row: String
        let after: Int?
        if let retry, lastPromptID == retry.row {
            row = retry.row
            // What was known at its first send, which may have arrived.
            after = sentAfter[row]
        } else {
            row = UUID().uuidString
            transcript.appendUser(display ?? text, id: row)
            localPrompts[row] = text
            after = isNew || newestStored > 0 ? newestStored : nil
            sentAfter[row] = after
        }
        unconfirmed.insert(row)
        let checkFirst = retry?.maybeArrived == true
        let previous = lastSend
        let task = Task { () -> Delivery in
            _ = await previous?.value
            acceptedRowID = nil
            let outcome = await deliver(text, queued: queued, checkFirst: checkFirst, after: after, truncate: truncate,
                                        rebind: rebind)
            switch outcome {
            case .delivered:
                // Hermes said which stored row holds the prompt: the bubble can be edited or restored at once.
                if let stored = acceptedRowID { transcript.bindRowID(stored, to: row) }
                unconfirmed.remove(row)
                undelivered.removeAll()
                hasPrompt = true
                reportStoredID()
            case .failed:
                unconfirmed.remove(row)
                undelivered[text] = (row, false)
            case .unknown:
                // Stays unconfirmed, so reloads keep the row until Hermes shows it.
                undelivered[text] = (row, true)
            }
            return outcome
        }
        lastSend = task
        return await task.value
    }

    /// Retries only what can't become a duplicate: a prompt that never left the phone, or one Hermes is shown
    /// not to have. Retries are queued so they never interrupt a running turn. `checkFirst`: an earlier send of
    /// this text may have arrived, so look before sending it again. `after`: the newest stored row id when it was sent.
    /// `truncate`: a rewind to before that stored prompt, which is never queued and rides out a turn still winding
    /// down ("session busy", 4009) as the desktop does: one more interrupt, then a retry every 150 ms for 6 s. Its
    /// answer's survivor ids rebind the rows shown (`rebind` lists the ones it asked about).
    private func deliver(_ text: String, queued: Bool, checkFirst: Bool, after: Int?, truncate: Int? = nil,
                         rebind: [Int]? = nil) async -> Delivery {
        if checkFirst {
            switch await wasDelivered(text, after: after) {
            case true?:
                if needsResync { scheduleResync() }
                return .delivered
            case false?:
                break
            case nil:
                return fail(DashboardError.disconnected, .unknown)
            }
        }
        var queued = queued && truncate == nil
        var attempt = 1
        var busySince: Date?
        while true {
            var sent = false
            do {
                try await attach()
                guard let runtimeID else { throw DashboardError.rpc("Hermes didn't open the session.") }
                let wasBusy = busy
                busy = true
                do {
                    let asked = truncate == nil ? nil : rebind.flatMap { $0.isEmpty ? nil : $0 }
                    do {
                        let result = try await connection.client.promptSubmit(.init(
                            sessionId: runtimeID, text: .string(text), queued: queued ? true : nil,
                            truncateBeforeRowId: truncate, confirmTruncate: truncate.map { _ in true },
                            confirmEmptyTruncate: truncate.map { _ in true }, rebindSurvivorRowIds: asked
                        ))
                        accepted(result, truncated: truncate != nil, asked: asked)
                    } catch let error as GatewayDecodingError {
                        // Accepted; only the answer is outside the contract.
                        if let result = try? error.raw.decode(PromptSubmitResult.self) {
                            accepted(result, truncated: truncate != nil, asked: asked)
                        } else if let id = error.raw["user_row_id"]?.intValue, id > 0 {
                            acceptedRowID = id
                        }
                    }
                } catch {
                    busy = wasBusy
                    sent = !error.wasNotSent
                    throw error
                }
                if needsResync { scheduleResync() }
                return .delivered
            } catch let error as GatewayRPCError where error.code == 4009 && truncate != nil
                        && Date().timeIntervalSince(busySince ?? Date()) < Self.busyRetryWindow {
                // The stopped turn still runs its post-turn hooks; a rewind must not land in it.
                if busySince == nil {
                    busySince = Date()
                    if let runtimeID { _ = try? await connection.client.sessionInterrupt(.init(sessionId: runtimeID)) }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                if error.isRefusal { return fail(error) }
                if sent {
                    // The prompt went out but its answer was lost.
                    guard let delivered = await wasDelivered(text, after: after) else { return fail(error, .unknown) }
                    if delivered {
                        if needsResync { scheduleResync() }
                        return .delivered
                    }
                }
                if attempt == 3 { return fail(error) }
                queued = truncate == nil
                try? await Task.sleep(nanoseconds: UInt64(attempt) * NSEC_PER_SEC)
                attempt += 1
            }
        }
    }

    /// After prompt.submit's answer was lost: re-attach and look for the prompt in the running turn (as its prompt,
    /// or among the corrections steered into it), in the queued one, or in the newest stored user message if that
    /// is newer than `after` (Hermes stores it before answering). Hermes merges prompts queued together, and
    /// corrections steered in during one tool batch, so any of these may hold it as a run of its lines. nil when
    /// Hermes can't be asked.
    private func wasDelivered(_ text: String, after: Int?) async -> Bool? {
        guard let session = try? await attach(fresh: true) else { return nil }
        var live = [session.inflightPrompt, session.queuedPrompt].compactMap { $0 }
        live += session.corrections
        if live.contains(where: { Self.holds($0, text) }) { return true }
        guard let storedID, let rows = try? await client.messageRows(sessionID: storedID, profile: profile) else { return nil }
        noteStored(rows)
        guard let lastUser = Self.prompts(in: rows).last else { return false }
        if let after, lastUser.id <= after { return false }
        return Self.holds(lastUser.text, text)
    }

    private func fail(_ error: Error, _ outcome: Delivery = .failed) -> Delivery {
        lastDeliveryError = error
        if runtimeID == nil || detached { busy = false }
        if !error.isCancellation { self.error = error.localizedDescription }
        return outcome
    }

    /// Tells `onStoredID` the key once the chat has one and holds a prompt.
    private func reportStoredID() {
        guard hasPrompt, let storedID, storedID != reportedID else { return }
        reportedID = storedID
        onStoredID?(storedID)
    }

    func interrupt() async {
        if !isAttached { await resync() }
        guard let runtimeID else {
            busy = false
            return
        }
        guard busy else { return }
        // Busy clears here before Hermes has wound the turn down: an edit or restore right after still interrupts
        // first (the desktop's cooldown).
        lastInterrupt = Date()
        do {
            _ = try await connection.client.sessionInterrupt(.init(sessionId: runtimeID))
        } catch is GatewayDecodingError {
            // Interrupted; only the answer is outside the contract.
        } catch {
            busy = false
        }
    }

    // MARK: Rewinding

    /// What a rewind is for, and the message it fails with ("Edit failed", "Restore failed", "Regenerate failed").
    enum RewindKind {
        /// The prompt runs again with new text (Edit, then send).
        case edit
        /// The prompt runs again as it was (Restore checkpoint).
        case restore
        /// The reply after the prompt is written again (Regenerate).
        case regenerate

        var failure: String {
            switch self {
            case .edit: return "Edit failed"
            case .restore: return "Restore failed"
            case .regenerate: return "Regenerate failed"
            }
        }
    }

    /// How long after Stop an edit or restore still interrupts first: Hermes may still be winding the turn down.
    static let interruptCooldown: TimeInterval = 3
    /// How long a rewind keeps retrying while Hermes says the session is busy.
    static let busyRetryWindow: TimeInterval = 6

    /// Re-runs the conversation from a stored prompt with `text` in its place (the desktop's edit, restore and
    /// regenerate): `prompt.submit` with `truncate_before_row_id` drops that prompt and everything after it, and
    /// `text` runs from there. As on the desktop:
    /// - a running turn is stopped first and the queue parked; one stopped moments ago is interrupted again, and
    ///   "session busy" is retried for a few seconds;
    /// - a prompt that never reached Hermes (its send failed) is replaced and sent as a new turn, and so is one
    ///   whose stored row can't be found (nothing is cut on a guess);
    /// - a stored id gone stale (compression, another client's rewind) is looked up again in a fresh copy and the
    ///   rewind tried once more;
    /// - the stored rows Hermes rewrote take their new ids from the answer (`rebind_survivor_row_ids`);
    /// - a rewind that fails puts the transcript back as it was.
    /// False when nothing changed.
    @discardableResult
    func rewind(_ message: UserMessage, to text: String, kind: RewindKind = .edit) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = kind.failure
        guard !text.isEmpty else { return false }
        guard transcript.items.contains(where: { $0.id == message.id }) || message.rowID != nil else {
            error = "\(failure): couldn't find the message to restore."
            return false
        }
        let stoppedRecently = lastInterrupt.map { Date().timeIntervalSince($0) < Self.interruptCooldown } ?? false
        if busy {
            await sender.stop()
            for _ in 0..<40 where busy { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard !busy else {
                error = "\(failure): the reply didn't stop, so the message wasn't changed."
                return false
            }
        } else if stoppedRecently, let runtimeID {
            _ = try? await connection.client.sessionInterrupt(.init(sessionId: runtimeID))
        }
        // A prompt whose send failed never reached Hermes: there is nothing stored to cut.
        let neverSent = message.rowID == nil && undelivered.values.contains { $0.row == message.id && !$0.maybeArrived }
        let rowID = neverSent ? nil : await storedRowID(of: message)
        var outcome = await rewindSubmit(message, text: text, rowID: rowID)
        if outcome == .failed, rowID != nil, Self.isStaleTarget(lastDeliveryError) {
            // The stored id went stale: find the prompt in a fresh copy and try once more.
            try? await reloadHistory()
            if let fresh = await storedRowID(of: message, fresh: true) {
                outcome = await rewindSubmit(message, text: text, rowID: fresh)
                if outcome == .failed, Self.isStaleTarget(lastDeliveryError) {
                    error = "\(failure): this turn is no longer in server history (it may have been compressed away)."
                    return false
                }
            } else {
                error = "\(failure): this turn is no longer in server history (it may have been compressed away)."
                return false
            }
        }
        switch outcome {
        case .delivered:
            reloadAfterTurn = true
            return true
        case .failed:
            if let lastDeliveryError, !lastDeliveryError.isCancellation {
                error = "\(failure): \(lastDeliveryError.localizedDescription)"
            }
            return false
        case .unknown:
            needsResync = true
            return false
        }
    }

    /// Cuts the shown transcript at the prompt and sends `text` in its place: with `rowID`, a rewind of the stored
    /// transcript to before it; without, a plain new turn. A failed send puts the transcript back.
    private func rewindSubmit(_ message: UserMessage, text: String, rowID: Int?) async -> Delivery {
        let anchor = rowID.flatMap { id in
            transcript.items.first { if case let .user(prompt) = $0 { return prompt.rowID == id }; return false }
        } ?? transcript.items.first { $0.id == message.id }
        let saved = (transcript, storedRows, storedItems, localPrompts, unconfirmed, sentAfter)
        let rebind = transcript.durableRowIDs
        if let anchor { transcript.truncate(from: anchor.id) }
        if let rowID { storedRows = storedRows.filter { (Self.rowID($0) ?? .max) < rowID } }
        let remaining = Set(transcript.items.map(\.id))
        storedItems.formIntersection(remaining)
        localPrompts = localPrompts.filter { remaining.contains($0.key) }
        unconfirmed.formIntersection(remaining)
        sentAfter = sentAfter.filter { remaining.contains($0.key) }
        // The turns dropped may have set a task list and started background processes; they belong to the
        // abandoned timeline.
        status.clearTodos()
        status.resetBackground()
        lastDeliveryError = nil
        let outcome = await sendPrompt(text, truncate: rowID, rebind: rowID == nil ? nil : rebind)
        if outcome == .failed { (transcript, storedRows, storedItems, localPrompts, unconfirmed, sentAfter) = saved }
        return outcome
    }

    /// What `prompt.submit`'s answer says: the stored row of the prompt (`user_row_id`), and after a rewind the new
    /// ids of the rows it kept.
    private func accepted(_ result: PromptSubmitResult, truncated: Bool, asked: [Int]?) {
        if let id = result.userRowId, id > 0 { acceptedRowID = id }
        if truncated { rebindSurvivors(Self.survivorMap(result, asked: asked ?? [], shown: transcript)) }
    }

    /// Hermes refused the cut because its target isn't in the session's history any more.
    nonisolated static func isStaleTarget(_ error: Error?) -> Bool {
        guard let error = error as? GatewayRPCError else { return false }
        let message = error.message.lowercased()
        return error.code == 4018 || message.contains("no longer in session history") || message.contains("not in session history")
    }

    /// How a rewind's answer renumbers the stored rows shown: `survivor_row_id_map` (old id → new id, nil: forget
    /// it), or from an older Hermes `survivor_user_row_ids`, the new ids of the prompts kept, in order.
    nonisolated static func survivorMap(_ result: PromptSubmitResult, asked: [Int], shown: Transcript) -> [Int: Int?] {
        if let map = result.survivorRowIdMap {
            var parsed: [Int: Int?] = [:]
            for (old, new) in map {
                guard let old = Int(old) else { continue }
                parsed[old] = .some(new)
            }
            return parsed
        }
        guard let ids = result.survivorUserRowIds else { return [:] }
        let asked = Set(asked)
        let kept = shown.items.compactMap { item -> Int? in
            if case let .user(prompt) = item, let id = prompt.rowID, asked.contains(id) { return id }
            return nil
        }
        var parsed: [Int: Int?] = [:]
        for (index, old) in kept.enumerated() {
            parsed[old] = .some(index < ids.count ? ids[index] : nil)
        }
        return parsed
    }

    /// The stored rows a rewind rewrote take their new ids, here and in the stored page the transcript came from.
    private func rebindSurvivors(_ map: [Int: Int?]) {
        guard !map.isEmpty else { return }
        transcript.rebindRowIDs(map)
        storedRows = storedRows.compactMap { row in
            guard let old = Self.rowID(row), let new = map[old] else { return row }
            return new.map { row.setting("id", .int($0)) }
        }
        let newest = map.values.compactMap { $0 }.max() ?? 0
        newestStored = max(newestStored, newest)
    }

    /// Runs the prompt before `reply` again in its place.
    func regenerate(_ reply: AssistantText) async {
        guard let index = transcript.items.firstIndex(where: { $0.id == reply.id }),
              case let .user(prompt)? = transcript.items[..<index].last(where: \.isUser) else { return }
        await rewind(prompt, to: Self.promptText(prompt), kind: .regenerate)
    }

    /// How many prompts come after `message`: the turns a rewind there also drops.
    func promptsAfter(_ message: UserMessage) -> Int {
        guard let index = transcript.items.firstIndex(where: { $0.id == message.id }) else { return 0 }
        return transcript.items[(index + 1)...].filter(\.isUser).count
    }

    /// The prompt whose turn runs now: its bubble offers Stop instead of Restore checkpoint.
    var runningPromptID: String? { busy ? transcript.items.last(where: \.isUser)?.id : nil }

    /// What a shown prompt sent: its reference chips (not its images, which Hermes held apart) before the text.
    nonisolated static func promptText(_ message: UserMessage) -> String {
        let refs = message.attachments.filter { $0.kind != .image }.map(\.ref).joined(separator: "\n")
        return [refs, message.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The stored id of a shown prompt; a prompt sent from here learns it from a fresh copy of the transcript
    /// (`fresh` reads the copy just fetched instead of fetching again).
    private func storedRowID(of message: UserMessage, fresh: Bool = false) async -> Int? {
        if !fresh, let rowID = message.rowID { return rowID }
        if !fresh { try? await reloadHistory() }
        let text = Transcript.normalized(message.text)
        for case let .user(stored) in transcript.items.reversed() where stored.rowID != nil && Transcript.normalized(stored.text) == text {
            return stored.rowID
        }
        return nil
    }

    // MARK: Session actions

    /// The whole conversation continues in a new session, which opens.
    func branch() async {
        guard let storedID else { return }
        let target = SessionMenuTarget(storedID: storedID, runtimeID: attachedRuntimeID, title: title, profile: profile)
        do {
            if case let .branched(stored, _, branchTitle) = try await sessionActions.branch(target) {
                navigate?(.session(SessionSummary(id: stored, title: branchTitle.isEmpty ? title : branchTitle,
                                                  lastActive: nil, profile: profile)))
            }
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    /// The conversation up to `reply` continues in a new session, which opens (`session.branch` with the count
    /// of stored user and assistant messages it keeps).
    func branch(from reply: AssistantText) async {
        guard let rowID = reply.rowID, let end = storedRows.firstIndex(where: { Self.rowID($0) == rowID }) else {
            error = "Only a saved reply can start a branch."
            return
        }
        guard !busy else {
            error = "Stop the reply first, then branch."
            return
        }
        let count = storedRows[...end].filter { row in
            guard let object = row.objectValue, ["user", "assistant"].contains(object["role"]?.stringValue) else { return false }
            return !Transcript.text(object["content"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        do {
            try await attach()
            guard let runtimeID else { throw DashboardError.rpc("Hermes didn't open the session.") }
            let key = UUID().uuidString
            let branched: (id: String, title: String)
            do {
                let result = try await connection.client.sessionBranch(.init(sessionId: runtimeID, profile: profile, count: count,
                                                                             idempotencyKey: key))
                branched = (result.storedSessionId, result.title)
            } catch let error as GatewayDecodingError {
                guard let id = error.raw["stored_session_id"]?.stringValue else { throw error }
                branched = (id, error.raw["title"]?.stringValue ?? "")
            }
            navigate?(.session(SessionSummary(id: branched.id, title: branched.title.isEmpty ? title : branched.title,
                                              lastActive: nil, profile: profile)))
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
    }

    /// The session was deleted: nothing re-attaches it, and its prompts are let go.
    func sessionGone() {
        deleted = true
        runtimeID = nil
        detached = false
        busy = false
        endLiveTurn()
        connection.untrack(self)
    }

    /// The session menu renamed it.
    func renamed(_ title: String) {
        if !title.isEmpty { self.title = title }
    }

    /// The image behind a `MEDIA:` chip, from the gateway host (`GET /api/media`).
    func media(_ ref: MediaRef) async throws -> Data {
        let result = try await client.request("GET", "/api/media", query: ["path": ref.path]) as? JSON
        guard let url = result?["data_url"] as? String, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
            throw DashboardError.rpc("Hermes didn't send \(ref.name).")
        }
        return data
    }

    // MARK: Events

    private func handle(_ event: GatewayEvent, sessionID: String?, seq: Int?) {
        if case let .unknown(type, payload) = event {
            // Outside the contract (another Hermes version): the fields this chat reads.
            if let salvaged = Self.salvage(type, payload) ?? Transcript.salvage(type, payload) {
                handle(salvaged, sessionID: sessionID, seq: seq)
            }
            return
        }
        if case let .sessionReclaimed(payload) = event {
            if payload.sessionId == runtimeID {
                runtimeID = nil
                detached = false
                busy = false
                endLiveTurn()
                connection.untrack(self)
            }
            return
        }
        guard let runtimeID, sessionID == runtimeID || sessionID == storedID else { return }
        transcript.apply(event, seq: seq)
        switch event {
        case .messageStart:
            busy = true
        case .messageComplete:
            busy = false
            completions += 1
            if reloadAfterTurn {
                // Hermes' stored copy of the turn replaces what stood in for it.
                reloadAfterTurn = false
                needsResync = true
                if isInUse { scheduleResync() }
            }
        case let .sessionInfo(info):
            if let running = info.running { busy = running }
        case let .sessionTitle(payload):
            if !payload.title.isEmpty { title = payload.title }
        case .error:
            // The transcript shows it as an error card.
            busy = false
        default:
            break
        }
    }

    /// The session events this chat reads beyond the transcript's, rebuilt from a payload outside the contract.
    private static func salvage(_ type: String, _ payload: JSONValue?) -> GatewayEvent? {
        let payload = payload ?? [:]
        switch type {
        case "session.info":
            return .sessionInfo(SessionLiveInfo(running: payload["running"]?.boolValue))
        case "session.title":
            return payload["title"]?.stringValue.map { .sessionTitle(SessionTitlePayload(sessionId: payload["session_id"]?.stringValue ?? "", title: $0)) }
        case "session.reclaimed":
            return payload["session_id"]?.stringValue.map {
                .sessionReclaimed(SessionReclaimedPayload(sessionId: $0, storedSessionId: payload["stored_session_id"]?.stringValue ?? "", reason: ""))
            }
        default:
            return nil
        }
    }
}

// MARK: - Composer

extension ChatModel: ChatSending {
    var runtimeSessionID: String? { runtimeID }
    var isBusy: Bool { busy }

    /// The prompts Hermes holds open on this chat's session.
    private var openPrompts: [PromptCenter.Prompt] {
        prompts?.prompts.filter { $0.sessionID.map(sessionIDs.contains) == true } ?? []
    }

    var hasPendingClarify: Bool {
        openPrompts.contains { if case .clarify = $0.kind { return true }; return false }
    }

    var hasBlockingPrompt: Bool {
        openPrompts.contains { if case .clarify = $0.kind { return false }; return true }
    }

    func skipPendingClarify() async {
        for prompt in openPrompts {
            if case .clarify = prompt.kind { await prompts?.answerClarify(prompt.id, answers: nil) }
        }
    }

    /// The bubble shows the photos sent with it as chips at once, the way Hermes' stored copy will.
    func submit(_ text: String, attachments: [StagedAttachment], queued: Bool, display: String?) async -> Bool {
        let prompt = StagedAttachment.promptText(text, attachments)
        let images = StagedAttachment.imageLines(attachments)
        let shown = images.isEmpty ? display : "\(images)\n\(display ?? prompt)"
        return await send(prompt, queued: queued, display: shown)
    }

    func unstage(_ staged: StagedAttachment) async {
        guard let path = staged.path, let session = staged.sessionID, session == runtimeID else { return }
        _ = try? await connection.client.imageDetach(.init(sessionId: session, profile: profile, path: path))
    }

    /// Shows the correction as the user's message at once (Hermes stores it as one), and takes it back if the turn
    /// refused it. One Hermes holds for the next turn moves below the running turn, which goes on above it. It
    /// stays unconfirmed until a stored copy holds it, so reloads keep it meanwhile.
    func redirect(_ text: String) async -> RedirectOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isAttached, let runtimeID else { return .rejected }
        let row = UUID().uuidString
        transcript.appendCorrection(text, id: row)
        localPrompts[row] = text
        sentAfter[row] = newestStored
        unconfirmed.insert(row)
        let outcome: RedirectOutcome
        do {
            outcome = RedirectOutcome(try await connection.client.sessionRedirect(.init(sessionId: runtimeID, text: text)).status)
        } catch let error as GatewayDecodingError {
            outcome = error.raw["status"]?.stringValue.map { RedirectOutcome(CorrectionStatus(rawValue: $0)) } ?? .failed
        } catch {
            outcome = .failed
        }
        switch outcome {
        case .redirected:
            corrections.insert(row)
        case .queued:
            transcript.withdrawCorrection(row)
            transcript.appendNextPrompt(text, id: row)
        case .rejected, .failed:
            unconfirmed.remove(row)
            transcript.withdrawCorrection(row)
            localPrompts[row] = nil
            sentAfter[row] = nil
        }
        return outcome
    }

    func runSlash(_ command: String) async -> Bool {
        let name = SlashCommand(command).name
        slashCommand = name.isEmpty ? "/" : "/\(name)"
        let runner = SlashCommandRunner(client: connection.client, profile: profile, host: self,
                                        catalog: await composer.commandsCatalog())
        return await runner.run(command)
    }

    /// Stages on the live session. A session Hermes no longer has (4001, 4007) is resumed and tried once more.
    func stage(_ attachment: PendingAttachment) async throws -> StagedAttachment {
        var fresh = false
        while true {
            try await attach(fresh: fresh)
            guard let runtimeID else { throw DashboardError.rpc("Hermes didn't open the session.") }
            do {
                return try await connection.client.stage(attachment, sessionID: runtimeID, profile: profile)
            } catch let error as GatewayRPCError where !fresh && (error.code == 4001 || error.code == 4007) {
                fresh = true
            }
        }
    }
}

extension ChatModel: SlashCommandHost {
    func slashSessionID() async throws -> String {
        try await attach()
        guard let runtimeID else { throw DashboardError.rpc("Hermes didn't open the session.") }
        return runtimeID
    }

    func showSlashOutput(_ text: String) {
        transcript.appendSlashOutput(command: slashCommand, output: text)
    }

    func sendSlashPrompt(_ text: String, display: String?) async -> Bool {
        if busy { return sender.queuePrompt(text, display: display) }
        return await send(text, display: display)
    }

    func prefillComposer(_ text: String) {
        composer.prefill(text)
    }

    func performSlashAction(_ action: SlashAction) async {
        switch action {
        case .newChat: navigate?(.newChat)
        case .chooseSession: navigate?(.sessions)
        case .chooseModel: composer.modelMenuRequested = true
        case .branch: await branch()
        case .openMemoryGraph: navigate?(.memoryGraph)
        }
    }

    func transcriptChanged() async {
        keepingSlashOutput = true
        defer { keepingSlashOutput = false }
        do {
            try await reloadHistory()
        } catch {
            needsResync = true
            if isInUse { scheduleResync() }
        }
        await status.refreshContext()
    }
}

extension ChatModel: Hashable {
    nonisolated static func == (lhs: ChatModel, rhs: ChatModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
