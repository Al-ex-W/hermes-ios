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

    let id = UUID()
    /// The profile whose store holds this chat; nil for the dashboard's own.
    let profile: String?
    private(set) var storedID: String?
    /// Told the stored key of a new chat once it has one and a prompt went through, so empty drafts aren't kept.
    var onStoredID: ((String) -> Void)?
    /// Opens what the chat asks for; set by the screen showing it.
    var navigate: ((Route) -> Void)?

    /// The send decision tree and its local queue. They live with the chat, so the queue outlives the screen.
    private(set) lazy var sender = SendController(chat: self, ownedByChat: true)
    private(set) lazy var composer = ComposerModel(sender: sender, connection: connection, profile: profile)
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
    private var lastSend: Task<Bool, Never>?
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
                    // A model picked before the session existed runs from its first turn. A retried create whose
                    // answer was lost gets the same session back.
                    let pick = composer.pendingModel
                    session = try await LiveSession.attach({
                        try await connection.client.sessionCreate(.init(
                            profile: profile, cols: 96, source: "desktop", model: pick?.model, provider: pick?.provider,
                            idempotencyKey: id.uuidString
                        ))
                    }, LiveSession.init)
                    if let pick { composer.pendingModelApplied(pick) }
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
                if !loaded || needsResync || (wantsReload && !transcript.turnRunning && !busy) { try await reloadHistory() }
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
        let local = transcript.items.compactMap { item in localPrompts[item.id].map { (row: item.id, text: $0) } }
        let stored = storedPrompts(Self.prompts(in: rows), local)
        let running = transcript.runningTurnIDs
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
                continue
            }
            keep.insert(item.id)
        }
        transcript.load(history: rows, keeping: keep)
        storedItems = Set(transcript.items.map(\.id)).subtracting(keep)
        localPrompts = localPrompts.filter { keep.contains($0.key) }
        sentAfter = sentAfter.filter { keep.contains($0.key) }
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
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
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
        let task = Task { () -> Bool in
            _ = await previous?.value
            let outcome = await deliver(text, queued: queued, checkFirst: checkFirst, after: after)
            switch outcome {
            case .delivered:
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
            return outcome == .delivered
        }
        lastSend = task
        return await task.value
    }

    /// Retries only what can't become a duplicate: a prompt that never left the phone, or one Hermes is shown
    /// not to have. Retries are queued so they never interrupt a running turn. `checkFirst`: an earlier send of
    /// this text may have arrived, so look before sending it again. `after`: the newest stored row id when it was sent.
    private func deliver(_ text: String, queued: Bool, checkFirst: Bool, after: Int?) async -> Delivery {
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
        var queued = queued
        for attempt in 1...3 {
            var sent = false
            do {
                try await attach()
                guard let runtimeID else { throw DashboardError.rpc("Hermes didn't open the session.") }
                let wasBusy = busy
                busy = true
                do {
                    do {
                        _ = try await connection.client.promptSubmit(.init(
                            sessionId: runtimeID, text: .string(text), queued: queued ? true : nil
                        ))
                    } catch is GatewayDecodingError {
                        // Accepted; only the answer is outside the contract.
                    }
                } catch {
                    busy = wasBusy
                    sent = !error.wasNotSent
                    throw error
                }
                if needsResync { scheduleResync() }
                return .delivered
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
                queued = true
                try? await Task.sleep(nanoseconds: UInt64(attempt) * NSEC_PER_SEC)
            }
        }
        return .failed
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
        do {
            _ = try await connection.client.sessionInterrupt(.init(sessionId: runtimeID))
        } catch is GatewayDecodingError {
            // Interrupted; only the answer is outside the contract.
        } catch {
            busy = false
        }
    }

    // MARK: Session actions

    /// The whole conversation continues in a new session, which opens.
    func branch() async {
        guard let storedID else { return }
        let target = SessionMenuTarget(storedID: storedID, runtimeID: isAttached ? runtimeID : nil, title: title, profile: profile)
        do {
            if case let .branched(stored, _, branchTitle) = try await sessionActions.branch(target) {
                navigate?(.session(SessionSummary(id: stored, title: branchTitle.isEmpty ? title : branchTitle,
                                                  lastActive: nil, profile: profile)))
            }
        } catch {
            if !error.isCancellation { self.error = error.localizedDescription }
        }
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

    func submit(_ text: String, attachments: [StagedAttachment]) async -> Bool {
        await send(StagedAttachment.promptText(text, attachments))
    }

    /// Shows the correction as the user's message at once (Hermes stores it as one), and takes it back if the turn
    /// refused it.
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
        unconfirmed.remove(row)
        if !outcome.delivered {
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
    }
}

extension ChatModel: Hashable {
    nonisolated static func == (lhs: ChatModel, rhs: ChatModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
