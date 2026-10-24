import Foundation

/// One conversation: its history from REST, and live turns over the gateway connection.
/// While the chat is in use (on screen, or in a call) the connection re-attaches its session after a reconnect and
/// replays what it missed, and when events were lost anyway the stored transcript is fetched again by itself. A chat
/// not in use catches up when it is next opened or sends.
@MainActor
final class ChatModel: ObservableObject, Identifiable, GatewaySessionOwner {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var busy = false
    @Published private(set) var title: String
    @Published var error: String?
    /// Every runtime id the session had, and its stored id: the sessions this chat's prompts can name.
    @Published private(set) var sessionIDs: Set<String> = []

    let id = UUID()
    /// The profile whose store holds this chat; nil for the dashboard's own.
    let profile: String?
    private(set) var storedID: String?
    /// Told the stored key of a new chat once it has one and a prompt went through, so empty drafts aren't kept.
    var onStoredID: ((String) -> Void)?

    private var runtimeID: String?
    /// The socket dropped since the session was attached: `runtimeID` waits for the connection's re-attach.
    private var detached = false
    private let client: DashboardClient
    private let connection: GatewayConnection
    private let isNew: Bool
    private var listeners: [UUID] = []
    private var liveMessageID: String?
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

    /// How a prompt's delivery ended.
    private enum Delivery { case delivered, failed, unknown }

    init(client: DashboardClient, connection: GatewayConnection, summary: SessionSummary?) {
        self.client = client
        self.connection = connection
        storedID = summary?.id
        profile = summary?.profile
        title = summary?.title ?? "New chat"
        isNew = summary == nil
        loaded = summary == nil
        hasPrompt = summary != nil
        if let storedID { sessionIDs = [storedID] }
        listeners = [
            connection.addListener { [weak self] event, sessionID, _ in self?.handle(event, sessionID: sessionID) },
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
                    // A retried create whose answer was lost gets the same session back.
                    session = try await LiveSession.attach({
                        try await connection.client.sessionCreate(.init(cols: 96, source: "desktop", idempotencyKey: id.uuidString))
                    }, LiveSession.init)
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

    /// Takes the attached session. `replays`: the connection re-attached it and replays what it missed, so a reply
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
        if !replays, !session.running, liveMessageID != nil {
            // The reply that was streaming ended while detached; the stored copy replaces it.
            liveMessageID = nil
            needsResync = true
        }
    }

    // MARK: Reconnects

    func gatewayReattached(_ session: LiveSession) {
        apply(session, replays: true)
    }

    func gatewayNeedsRefetch() {
        // A reply cut short by the lost events is replaced by the stored copy.
        if !busy { liveMessageID = nil }
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
                if !loaded || needsResync || (wantsReload && liveMessageID == nil && !busy) { try await reloadHistory() }
                wantsReload = false
                if let attachError { throw attachError }
                guard epoch == self.epoch else { continue }
                needsResync = false
                return
            } catch {
                if error.isCancellation { return }
                if error.isRefusal || attempt == delays.count - 1 {
                    // Nothing will report how a turn that was running ends until the session is attached again.
                    if runtimeID == nil || detached { busy = false }
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

    /// Replaces the transcript with the stored one, keeping the reply still streaming, rows that arrived during the
    /// fetch, and prompts Hermes may not have stored yet.
    private func reloadHistory() async throws {
        guard let storedID else { loaded = true; return }
        for attempt in 0..<2 {
            let before = Set(messages.map(\.id))
            let pending = unconfirmed
            let finished = completions
            let history: [ChatMessage]
            do {
                history = try await client.messages(sessionID: storedID, profile: profile)
            } catch DashboardError.http(404, _) where isNew {
                // A new chat has no stored rows until its first prompt.
                loaded = true
                return
            }
            // A turn that ended during the fetch may or may not be in this copy: fetch once more.
            if finished != completions, attempt == 0 { continue }
            let known = Set(history.map(\.id))
            let live = liveMessageID
            noteStored(history)
            let stored = storedPrompts(history, messages.filter { $0.role == .user && !known.contains($0.id) })
            messages = history + messages.filter { row in
                guard !known.contains(row.id) else { return false }
                guard row.role == .user else { return row.id == live || !before.contains(row.id) }
                guard pending.contains(row.id) || unconfirmed.contains(row.id) || !before.contains(row.id) else { return false }
                if stored.contains(row.id) {
                    unconfirmed.remove(row.id)
                    return false
                }
                return true
            }
            let rows = Set(messages.map(\.id))
            sentAfter = sentAfter.filter { rows.contains($0.key) }
            loaded = true
            return
        }
    }

    private func noteStored(_ history: [ChatMessage]) {
        newestStored = max(newestStored, history.compactMap { Int($0.id) }.max() ?? 0)
    }

    /// The local prompt rows (oldest first, delivered ones included) that Hermes has stored. Each claims, in the
    /// order they were sent, the first stored user row newer than what was known when it went out that holds it
    /// as a whole run of lines (Hermes merges prompts into one row: queued ones with a blank line between them,
    /// corrections steered in during one tool batch with a newline). So the stored copy of a delivered prompt
    /// can't stand in for a later one with the same words, and only the rows still awaiting confirmation are left
    /// to match the newest stored ones.
    private func storedPrompts(_ history: [ChatMessage], _ local: [ChatMessage]) -> Set<String> {
        let users = history.filter { $0.role == .user }
        let have = users.flatMap { row in Self.parts(row.text).map { (row: row.id, id: Int(row.id) ?? .max, text: $0) } }
        var next = 0
        var stored: Set<String> = []
        for (index, row) in local.enumerated() {
            let wanted = Self.parts(row.text)
            guard !wanted.isEmpty, have.count - next >= wanted.count else { continue }
            let after = sentAfter[row.id]
            // Sent before anything stored was known: only the newest stored rows, one per prompt sent since, qualify.
            let recent = after == nil ? Set(users.suffix(local.count - index).map(\.id)) : []
            let match = (next...(have.count - wanted.count)).first { start in
                let run = have[start..<(start + wanted.count)]
                guard run.allSatisfy({ $0.row == have[start].row }), run.map(\.text) == wanted else { return false }
                if let after { return have[start].id > after }
                return recent.contains(have[start].row)
            }
            guard let match else { continue }
            stored.insert(row.id)
            next = match + wanted.count
        }
        return stored
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

    /// Sends a prompt; true once Hermes accepted it. `queued` has Hermes run it after the current turn
    /// instead of steering or interrupting it. Prompts go out one at a time, in order.
    @discardableResult
    func send(_ text: String, queued: Bool = false) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // Sending again what didn't get through keeps its bubble while that is still the newest prompt.
        let retry = undelivered.removeValue(forKey: text)
        let row: String
        let after: Int?
        if let retry, messages.last(where: { $0.role == .user })?.id == retry.row {
            row = retry.row
            // What was known at its first send, which may have arrived.
            after = sentAfter[row]
        } else {
            row = UUID().uuidString
            messages.append(ChatMessage(id: row, role: .user, text: text))
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
        guard let storedID, let history = try? await client.messages(sessionID: storedID, profile: profile) else { return nil }
        noteStored(history)
        guard let lastUser = history.last(where: { $0.role == .user }) else { return false }
        if let after, (Int(lastUser.id) ?? .max) <= after { return false }
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

    // MARK: Events

    private func handle(_ event: GatewayEvent, sessionID: String?) {
        if case let .unknown(type, payload) = event {
            // Outside the contract (another Hermes version): the fields this chat reads, as before.
            if let salvaged = Self.salvage(type, payload) { handle(salvaged, sessionID: sessionID) }
            return
        }
        if case let .sessionReclaimed(payload) = event {
            if payload.sessionId == runtimeID {
                runtimeID = nil
                detached = false
                busy = false
                liveMessageID = nil
                connection.untrack(self)
            }
            return
        }
        guard let runtimeID, sessionID == runtimeID || sessionID == storedID else { return }
        switch event {
        case .messageStart:
            busy = true
            liveMessageID = nil
        case let .messageDelta(payload):
            appendLive(payload.text)
        case let .messageInterim(payload):
            // Commentary beside tool calls, sealed as its own row; streamed already unless told otherwise.
            if !payload.alreadyStreamed, !payload.text.isEmpty {
                messages.append(ChatMessage(id: UUID().uuidString, role: .assistant, text: payload.text))
            }
            liveMessageID = nil
        case let .messageComplete(payload):
            let final = payload.text?.stringValue ?? ""
            if !final.isEmpty {
                if let index = liveIndex { messages[index].text = final } else { startLive(final) }
            } else if let index = liveIndex, messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.remove(at: index)
            }
            liveMessageID = nil
            busy = false
            completions += 1
        case let .toolStart(payload):
            var tool: JSON = ["name": payload.name]
            tool["args"] = payload.args.map { JSONValue.object($0).anyValue }
            tool["args_text"] = payload.argsText
            if let row = Self.toolRow(tool) {
                messages.append(ChatMessage(id: UUID().uuidString, role: .tool, text: row))
            }
            liveMessageID = nil
        case let .sessionInfo(info):
            if let running = info.running { busy = running }
        case let .sessionTitle(payload):
            if !payload.title.isEmpty { title = payload.title }
        case let .error(payload):
            busy = false
            liveMessageID = nil
            error = payload.message.isEmpty ? nil : payload.message
        default:
            break
        }
    }

    /// The events this chat handles, rebuilt from a payload that didn't match the contract.
    private static func salvage(_ type: String, _ payload: JSONValue?) -> GatewayEvent? {
        let payload = payload ?? [:]
        let text = payload["text"]?.stringValue
        switch type {
        case "message.delta":
            return text.map { .messageDelta(StreamDeltaPayload(text: $0)) }
        case "message.interim":
            return text.map { .messageInterim(MessageInterimPayload(text: $0, alreadyStreamed: payload["already_streamed"]?.boolValue ?? false)) }
        case "message.complete":
            return .messageComplete(MessageCompletePayload(text: text.map(JSONValue.string)))
        case "tool.start":
            guard let name = payload["name"]?.stringValue ?? payload["tool_name"]?.stringValue else { return nil }
            return .toolStart(ToolStartPayload(toolId: payload["tool_id"]?.stringValue ?? "", name: name,
                                               args: payload["args"]?.objectValue, argsText: payload["args_text"]?.stringValue))
        case "session.info":
            return .sessionInfo(SessionLiveInfo(running: payload["running"]?.boolValue))
        case "session.title":
            return payload["title"]?.stringValue.map { .sessionTitle(SessionTitlePayload(sessionId: payload["session_id"]?.stringValue ?? "", title: $0)) }
        case "session.reclaimed":
            return payload["session_id"]?.stringValue.map {
                .sessionReclaimed(SessionReclaimedPayload(sessionId: $0, storedSessionId: payload["stored_session_id"]?.stringValue ?? "", reason: ""))
            }
        case "error":
            return .error(ErrorPayload(message: payload["message"]?.stringValue ?? ""))
        default:
            return nil
        }
    }

    private var liveIndex: Int? {
        guard let liveMessageID else { return nil }
        return messages.lastIndex { $0.id == liveMessageID }
    }

    /// Adds streamed text to the reply being written. Its row is made with the first text, so a turn that
    /// starts with a tool call (such as speak) leaves no empty row.
    private func appendLive(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let index = liveIndex { messages[index].text += delta } else { startLive(delta) }
    }

    private func startLive(_ text: String) {
        let id = UUID().uuidString
        liveMessageID = id
        messages.append(ChatMessage(id: id, role: .assistant, text: text))
    }

    /// "🔊 …" for what Hermes said out loud through the speak tool, "🔧 name" for any other tool.
    /// Takes a tool.start payload or a stored tool call (`arguments` as a JSON string).
    nonisolated static func toolRow(_ payload: JSON) -> String? {
        guard let name = (payload["name"] as? String) ?? (payload["tool_name"] as? String) else { return nil }
        if name.hasSuffix("speak") {
            let raw = ["args", "arguments", "input", "args_text"].lazy.compactMap { payload[$0] }.first
            var args = raw as? JSON
            if args == nil, let string = raw as? String {
                args = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? JSON
            }
            if let text = args?["text"] as? String { return "🔊 \(text)" }
            return "🔊 speaking…"
        }
        return "🔧 \(name)"
    }
}
