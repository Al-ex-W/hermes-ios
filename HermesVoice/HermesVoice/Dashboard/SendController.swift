import Combine
import Foundation

/// An attachment in the composer or a queued prompt: what was picked, before Hermes has it.
struct ComposerAttachment: Identifiable, Hashable {
    let id: UUID
    let pending: PendingAttachment
    /// A small JPEG of a photo, for its chip.
    var thumbnail: Data?

    init(id: UUID = UUID(), pending: PendingAttachment, thumbnail: Data? = nil) {
        self.id = id
        self.pending = pending
        self.thumbnail = thumbnail
    }

    var name: String { pending.filename }
}

/// The composer's send decision tree and its local queue, as the desktop composer has them
/// (`use-composer-submit.ts`, `use-composer-queue.ts`, `use-prompt-actions`):
/// - idle: the draft is submitted (a slash command runs); an empty send drains the next queued prompt;
/// - a clarify card waits: it is skipped ("none of these"), then the words are routed as below;
/// - busy, slash command: it runs now;
/// - busy, plain text: it redirects the live turn; refused or failed, it joins the local queue;
/// - busy with attachments, or a blocking prompt (approval, sudo, secret): it joins the local queue;
/// - busy, nothing typed: Stop interrupts the turn (and parks the queue).
/// The queue drains one prompt at a time whenever the chat is idle and not parked, retrying a failed send a few
/// times before reporting it stuck.
@MainActor
final class SendController: ObservableObject {
    struct QueuedPrompt: Identifiable, Equatable {
        let id: UUID
        var text: String
        var attachments: [ComposerAttachment]
        /// What the queue shows instead of `text` (a skill invocation, not its expanded body).
        var display: String?

        init(id: UUID = UUID(), text: String, attachments: [ComposerAttachment] = [], display: String? = nil) {
            self.id = id
            self.text = text
            self.attachments = attachments
            self.display = display
        }

        /// A redirect can carry it: text the user typed, without attachments, and not a slash command.
        var isSteerable: Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && display == nil
                && !SendController.isSlashCommand(text)
        }
    }

    /// How a send went. Everything but `kept` used up the draft.
    enum Result: Equatable {
        case submitted
        case ranSlash
        /// The live turn took it as a correction.
        case redirected
        /// It waits in the local queue.
        case queued
        /// Stop: the running turn was interrupted.
        case interrupted
        /// The next queued prompt was sent.
        case drained
        /// The queued prompt being edited was saved.
        case savedEdit
        /// Nothing went out: the composer keeps the draft.
        case kept

        var consumesDraft: Bool { self != .kept }
    }

    static let maxDrainAttempts = 4
    static let slashWithAttachments = "Slash commands cannot be combined with attachments. Remove the attachment or send the command separately."
    static let queueStuck = "A queued turn kept failing to send. It is still in the queue — try sending it again."

    @Published private(set) var queue: [QueuedPrompt] = []
    /// Stop halted the run while prompts waited: they wait for Resume, a send or an edit.
    @Published private(set) var parked = false
    /// The queued prompt loaded into the composer for editing; the drain passes it over.
    @Published private(set) var editingID: UUID?
    /// A warning for the composer to show.
    @Published var notice: String?

    /// The chat it routes for. A chat that owns its controller (`ChatModel`) is held weakly, so neither keeps the
    /// other alive; once it is gone nothing is busy and nothing is sent.
    var chat: ChatSending { heldChat ?? owner ?? GoneChat.shared }
    private let heldChat: ChatSending?
    private weak var owner: ChatSending?
    private let retryDelay: TimeInterval
    private var draining = false
    private var failures: [UUID: Int] = [:]
    private var retry: Task<Void, Never>?
    private var observation: AnyCancellable?

    /// `retryDelay` times the failure count is the wait before a failed queued send is tried again. `ownedByChat`:
    /// the chat holds this controller, so the controller doesn't hold it back.
    init(chat: ChatSending, retryDelay: TimeInterval = 0.75, ownedByChat: Bool = false) {
        heldChat = ownedByChat ? nil : chat
        owner = chat
        self.retryDelay = retryDelay
        if let observable = chat as? any ObservableObject {
            observation = Self.watch(observable) { [weak self] in self?.chatChanged() }
        }
    }

    deinit { retry?.cancel() }

    private static func watch<Object: ObservableObject>(_ object: Object, _ changed: @escaping @MainActor () -> Void) -> AnyCancellable {
        // objectWillChange fires before the change lands; read the chat once it has.
        object.objectWillChange.receive(on: DispatchQueue.main).sink { _ in MainActor.assumeIsolated { changed() } }
    }

    /// The chat changed (it observes an `ObservableObject` chat by itself): drain when it went idle.
    func chatChanged() {
        guard !chat.isBusy, !parked, !queue.isEmpty, !draining, retry == nil else { return }
        Task { await drainIfIdle() }
    }

    // MARK: Sending

    /// Routes the composer's draft. Clear the draft before awaiting this, and restore it on `.kept`.
    func send(_ text: String, attachments: [ComposerAttachment] = []) async -> Result {
        if editingID != nil { return saveEdit(text, attachments) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = !trimmed.isEmpty || !attachments.isEmpty
        let slash = Self.isSlashCommand(text)
        // A side question runs beside the turn and answers no parked card. With attachments it isn't routed as a
        // command, so it counts as an ordinary message.
        let sideTask = attachments.isEmpty && Self.isSideTask(text)
        if payload, !sideTask, chat.hasPendingClarify { await chat.skipPendingClarify() }
        if chat.isBusy {
            if slash {
                guard attachments.isEmpty else { return refuse(Self.slashWithAttachments) }
                return await chat.runSlash(text) ? .ranSlash : .kept
            }
            if !chat.hasBlockingPrompt, attachments.isEmpty, !trimmed.isEmpty { return await steer(text) }
            if payload { return enqueue(text, attachments) ? .queued : .kept }
            await stop()
            return .interrupted
        }
        guard payload else {
            guard let head else { return .kept }
            return await drain(head.id) == true ? .drained : .kept
        }
        return await deliver(text, attachments) ? (slash ? .ranSlash : .submitted) : .kept
    }

    /// The queue button while a turn runs: holds the draft for the next turn.
    func queueDraft(_ text: String, attachments: [ComposerAttachment] = []) -> Result {
        guard chat.isBusy else { return .kept }
        return enqueue(text, attachments) ? .queued : .kept
    }

    /// Queues a prompt a slash command produced while a turn runs (a skill's body, a `/goal` kickoff), shown as
    /// `display`; it is sent when the turn settles.
    func queuePrompt(_ text: String, display: String?) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        queue.append(QueuedPrompt(text: text, display: display))
        parked = false
        return true
    }

    /// Stop: parks the queue (a halt mustn't roll into the next queued prompt) and interrupts the turn.
    func stop() async {
        if !queue.isEmpty { parked = true }
        await chat.interrupt()
    }

    /// A correction for the live turn. The draft is gone already, so a refused or failed one is kept in the queue.
    private func steer(_ text: String) async -> Result {
        if await chat.redirect(text).delivered { return .redirected }
        _ = enqueue(text, [])
        await drainIfIdle()
        return .queued
    }

    /// Stages the attachments, then submits; a slash command runs instead.
    private func deliver(_ text: String, _ attachments: [ComposerAttachment]) async -> Bool {
        if Self.isSlashCommand(text) {
            guard attachments.isEmpty else {
                notice = Self.slashWithAttachments
                return false
            }
            return await chat.runSlash(text)
        }
        var staged: [StagedAttachment] = []
        for attachment in attachments {
            do {
                staged.append(try await chat.stage(attachment.pending))
            } catch {
                if !error.isCancellation { notice = error.localizedDescription }
                return false
            }
        }
        return await chat.submit(text, attachments: staged)
    }

    private func refuse(_ message: String) -> Result {
        notice = message
        return .kept
    }

    // MARK: Queue

    private var head: QueuedPrompt? { queue.first { $0.id != editingID } }

    private func enqueue(_ text: String, _ attachments: [ComposerAttachment]) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        // The drain would refuse it on every attempt.
        if Self.isSlashCommand(text), !attachments.isEmpty {
            notice = Self.slashWithAttachments
            return false
        }
        queue.append(QueuedPrompt(text: text, attachments: attachments))
        // Fresh intent to keep the conversation moving: lift a park and the failure budget.
        failures.removeAll()
        parked = false
        return true
    }

    /// Sends the next queued prompt if the chat is idle and the queue isn't parked. A failed send is retried after
    /// a growing wait, up to `maxDrainAttempts`, then reported.
    func drainIfIdle() async {
        guard !chat.isBusy, !parked, !draining, let entry = head,
              failures[entry.id, default: 0] < Self.maxDrainAttempts else { return }
        guard await drain(entry.id) == false else { return }
        let fails = failures[entry.id, default: 0] + 1
        failures[entry.id] = fails
        if fails >= Self.maxDrainAttempts {
            notice = Self.queueStuck
            return
        }
        let delay = retryDelay * Double(fails)
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.retry = nil
            await self.drainIfIdle()
        }
    }

    /// Sends one queued prompt, removing it once accepted; nil when it's gone or a drain runs.
    private func drain(_ id: UUID) async -> Bool? {
        guard !draining, let entry = queue.first(where: { $0.id == id }) else { return nil }
        draining = true
        defer { draining = false }
        guard await deliver(entry.text, entry.attachments) else { return false }
        failures[id] = nil
        queue.removeAll { $0.id == id }
        // The queue flows again: what's left follows.
        parked = false
        return true
    }

    /// The row's send button. While busy it moves the prompt to the front and interrupts the turn, whose settle
    /// sends it; idle it goes now.
    func sendNow(_ id: UUID) async {
        guard id != editingID, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        if chat.isBusy {
            queue.insert(queue.remove(at: index), at: 0)
            // This interrupt exists to reach the queue, so the settle must drain (unlike Stop, which parks).
            parked = false
            await chat.interrupt()
            return
        }
        failures[id] = nil
        _ = await drain(id)
    }

    /// The row's steer button: redirects the live turn with a text-only prompt. Refused, the prompt stays put.
    @discardableResult
    func steerNow(_ id: UUID) async -> Bool {
        guard chat.isBusy, id != editingID, let entry = queue.first(where: { $0.id == id }), entry.isSteerable else { return false }
        guard await chat.redirect(entry.text).delivered else { return false }
        failures[id] = nil
        queue.removeAll { $0.id == id }
        parked = false
        return true
    }

    func remove(_ id: UUID) {
        queue.removeAll { $0.id == id }
        failures[id] = nil
        if editingID == id { editingID = nil }
        if queue.isEmpty { parked = false }
    }

    /// Lifts a park and lets the queue flow.
    func resume() async {
        parked = false
        failures.removeAll()
        await drainIfIdle()
    }

    // MARK: Editing a queued prompt

    /// Loads a queued prompt for editing in the composer; its place in the queue is kept.
    func beginEdit(_ id: UUID) -> QueuedPrompt? {
        guard editingID == nil, let entry = queue.first(where: { $0.id == id }) else { return nil }
        editingID = id
        return entry
    }

    func cancelEdit() {
        editingID = nil
        if !chat.isBusy { Task { await drainIfIdle() } }
    }

    private func saveEdit(_ text: String, _ attachments: [ComposerAttachment]) -> Result {
        guard let id = editingID, let index = queue.firstIndex(where: { $0.id == id }) else {
            editingID = nil
            return .kept
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return .kept }
        if Self.isSlashCommand(text), !attachments.isEmpty { return refuse(Self.slashWithAttachments) }
        queue[index].text = text
        queue[index].attachments = attachments
        // The edit replaced what was shown (a skill invocation) with what is sent.
        queue[index].display = nil
        failures[id] = nil
        editingID = nil
        if !chat.isBusy { Task { await drainIfIdle() } }
        return .savedEdit
    }

    // MARK: Text

    /// `/name` at the start, followed by whitespace or the end (the desktop's `^/[^\s/]*(\s|$)`): `/usr/bin` is a path.
    nonisolated static func isSlashCommand(_ text: String) -> Bool {
        let text = text.drop { $0.isWhitespace }
        guard text.first == "/" else { return false }
        let rest = text.dropFirst()
        guard let end = rest.firstIndex(where: { $0.isWhitespace || $0 == "/" }) else { return true }
        return rest[end] != "/"
    }

    /// A command that runs beside the live turn (`/btw`, `/bg`, `/background`).
    nonisolated static func isSideTask(_ text: String) -> Bool {
        guard isSlashCommand(text) else { return false }
        let name = text.drop { $0.isWhitespace }.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        return ["btw", "bg", "background"].contains(name)
    }
}

/// The chat of a controller whose owning chat is gone.
@MainActor
private final class GoneChat: ChatSending {
    static let shared = GoneChat()

    var runtimeSessionID: String? { nil }
    var isBusy: Bool { false }
    var hasPendingClarify: Bool { false }
    var hasBlockingPrompt: Bool { false }
    func skipPendingClarify() async {}
    func submit(_ text: String, attachments: [StagedAttachment]) async -> Bool { false }
    func redirect(_ text: String) async -> RedirectOutcome { .failed }
    func interrupt() async {}
    func runSlash(_ command: String) async -> Bool { false }
    func stage(_ attachment: PendingAttachment) async throws -> StagedAttachment { throw CancellationError() }
}
