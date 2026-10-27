import Combine
import SwiftUI

/// One row of the `/` or `@` popover.
struct CompletionRow: Identifiable, Hashable {
    let id: String
    /// What accepting it puts in the draft, in place of the token it completes.
    let insert: String
    let title: String
    let detail: String?
    /// The header it sits under (a catalog section, Commands, Skills, Options).
    let group: String?
}

/// A model on a provider.
struct ModelPick: Hashable {
    var provider: String
    var model: String
}

/// A switch Hermes wants confirmed first (an expensive model).
struct ModelConfirmation: Identifiable {
    let id = UUID()
    let pick: ModelPick
    let message: String
}

/// How Fast is offered for a model (the desktop's `resolveFastControl`): the speed parameter, or a separate
/// `…-fast` sibling model.
enum FastControl: Equatable {
    case none
    case parameter(on: Bool)
    case variant(base: String, fast: String, on: Bool)

    var isOn: Bool {
        switch self {
        case .none: return false
        case let .parameter(on), let .variant(_, _, on): return on
        }
    }
}

/// The composer's state: the draft and its attachments, the `/` and `@` completions, and the model, effort and
/// Fast controls of the chat's session (`model.options`, `config.get` / `config.set`, kept current from
/// `session.info`). Sending goes through `sender`, the desktop's decision tree.
@MainActor
final class ComposerModel: ObservableObject {
    enum Trigger: Equatable { case none, slash, path }

    @Published var draft = "" {
        didSet { if draft != oldValue { draftChanged() } }
    }
    @Published private(set) var attachments: [ComposerAttachment] = []
    @Published private(set) var completions: [CompletionRow] = []
    @Published private(set) var trigger: Trigger = .none
    @Published var notice: String?
    /// `/model` asked for the model menu.
    @Published var modelMenuRequested = false

    @Published private(set) var model: ModelPick?
    /// The session's reasoning effort; "none" is thinking off, nil until Hermes said.
    @Published private(set) var effort: String?
    @Published private(set) var fast = false
    @Published private(set) var options: ModelOptionsResult?
    /// A pick made before the chat had a session. `session.create` should carry it; it is also applied with
    /// `config.set` once the session exists.
    @Published private(set) var pendingModel: ModelPick?
    /// Effort and Fast chosen before the chat had a session, for `session.create` (or `config.set` once it exists).
    private(set) var pendingEffort: String?
    private(set) var pendingFast: Bool?
    @Published var modelConfirmation: ModelConfirmation?
    /// The stored prompt the draft replaces (Edit on a user bubble): sending it re-runs the conversation from there.
    @Published private(set) var editingMessage: UserMessage?
    /// Re-runs the conversation from a prompt with new text; true when it went out. Set by the chat.
    var rewind: ((UserMessage, String) async -> Bool)?
    /// How many prompts follow one in the chat (an edit there drops their turns too). Set by the chat.
    var promptsAfter: ((UserMessage) -> Int)?
    /// An edit of an older prompt waiting for the user to agree that the turns after it go (the desktop asks
    /// "Restore to this checkpoint?" before such a cut).
    @Published var deepEditConfirmation: UserMessage?

    let sender: SendController
    let profile: String?
    private let connection: GatewayConnection
    private var completionTask: Task<Void, Never>?
    private var catalog: (session: String?, result: CommandsCatalogResult)?
    private var listener: UUID?
    private var observation: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []
    private var sessionID: String?
    /// The draft and attachments set aside while a queued prompt is edited in their place.
    private var editStash: (draft: String, attachments: [ComposerAttachment])?
    /// The same, while a sent prompt is edited.
    private var messageStash: (draft: String, attachments: [ComposerAttachment])?
    /// The next draft change came from accepting a completion.
    private var accepting = false

    nonisolated static let efforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    nonisolated static let defaultEffort = "medium"
    private static let refStarters = ["file", "folder", "url", "image", "tool", "git"]

    init(sender: SendController, connection: GatewayConnection, profile: String?) {
        self.sender = sender
        self.connection = connection
        self.profile = profile
        sessionID = sender.chat.runtimeSessionID
        sender.$notice.compactMap { $0 }.sink { [weak self, weak sender] message in
            self?.notice = message
            sender?.notice = nil
        }.store(in: &cancellables)
        sender.$editingID.removeDuplicates().sink { [weak self] id in
            if id == nil { self?.restoreStash() }
        }.store(in: &cancellables)
        listener = connection.addListener { [weak self] event, sessionID, _ in
            guard let self, let sessionID, sessionID == self.sender.chat.runtimeSessionID else { return }
            if case let .sessionInfo(info) = event { self.apply(info) }
        }
        if let observable = sender.chat as? any ObservableObject {
            observation = Self.watch(observable) { [weak self] in self?.chatChanged() }
        }
        // A key, account or endpoint added in Settings > Providers, or a new default model: the model menu follows.
        NotificationCenter.default.publisher(for: .hermesModelOptionsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.refreshModel() } }
            .store(in: &cancellables)
    }

    deinit {
        let connection = connection, listener = listener
        completionTask?.cancel()
        Task { @MainActor in if let listener { connection.removeListener(listener) } }
    }

    private static func watch<Object: ObservableObject>(_ object: Object, _ changed: @escaping @MainActor () -> Void) -> AnyCancellable {
        object.objectWillChange.receive(on: DispatchQueue.main).sink { _ in MainActor.assumeIsolated { changed() } }
    }

    private var client: GatewayClient { connection.client }
    private var chat: ChatSending { sender.chat }

    var hasPayload: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var isEditingQueued: Bool { sender.editingID != nil }

    /// The chat got (or changed) its live session: read its model state and apply a pick made before it.
    private func chatChanged() {
        let current = chat.runtimeSessionID
        guard current != sessionID else { return }
        sessionID = current
        catalog = nil
        guard current != nil else { return }
        Task {
            if let effort = pendingEffort { await setEffort(effort) }
            if let fast = pendingFast { await setFast(fast) }
            if let pick = pendingModel {
                await select(pick)
            } else {
                await refreshModel()
            }
        }
    }

    // MARK: Sending

    /// Sends the draft (the composer clears it at once, and gets it back if nothing went out). Saving an edited
    /// queued prompt brings back the draft it set aside.
    func send() async {
        if let message = editingMessage { return await sendEdit(of: message) }
        let text = draft, picked = attachments
        clear()
        let result = await sender.send(text, attachments: picked)
        if result == .kept, draft.isEmpty, attachments.isEmpty {
            setDraft(text)
            attachments = picked
        }
    }

    /// Holds the draft for the next turn while one runs.
    func queue() {
        let text = draft, picked = attachments
        if sender.queueDraft(text, attachments: picked).consumesDraft { clear() }
    }

    func stop() async {
        await sender.stop()
    }

    private func clear() {
        setDraft("")
        attachments = []
    }

    private func setDraft(_ text: String) {
        accepting = true
        draft = text
        accepting = false
        completions = []
        trigger = .none
    }

    /// Puts text in the composer (a snippet, `/undo`'s prefill).
    func insert(_ text: String) {
        draft = draft.isEmpty ? text : "\(draft)\(draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " ")\(text)"
    }

    func prefill(_ text: String) {
        setDraft(text)
    }

    // MARK: Attachments

    func add(_ attachment: ComposerAttachment) {
        attachments.append(attachment)
    }

    func removeAttachment(_ id: UUID) {
        guard let removed = attachments.first(where: { $0.id == id }) else { return }
        attachments.removeAll { $0.id == id }
        Task { await sender.discard(removed) }
    }

    // MARK: Editing a sent prompt

    /// Loads a sent prompt into the composer (its reference chips as `@` lines); what was being typed waits.
    func editMessage(_ message: UserMessage) {
        if isEditingQueued { cancelEdit() }
        if editingMessage == nil { messageStash = (draft, attachments) }
        editingMessage = message
        setDraft(ChatModel.promptText(message))
        attachments = []
    }

    /// The user agreed to drop the turns after the edited prompt: the edit goes out. `message` is the prompt the
    /// question was about, captured when the button was tapped: the dialog has already cleared
    /// `deepEditConfirmation` by the time this runs.
    func confirmDeepEdit(_ message: UserMessage?) async {
        deepEditConfirmation = nil
        guard let message, editingMessage?.id == message.id else { return }
        await sendEdit(of: message, confirmed: true)
    }

    func cancelMessageEdit() {
        deepEditConfirmation = nil
        guard editingMessage != nil else { return }
        editingMessage = nil
        restoreMessageStash()
    }

    private func restoreMessageStash() {
        let stash = messageStash
        messageStash = nil
        setDraft(stash?.draft ?? "")
        attachments = stash?.attachments ?? []
    }

    /// Sends the edit as a rewind; refused, the edit stays in the composer. Unchanged text sends nothing and just
    /// closes the edit, and an edit that would drop later turns asks first (`deepEditConfirmation`), as on the
    /// desktop.
    private func sendEdit(of message: UserMessage, confirmed: Bool = false) async {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let rewind else { return }
        if Transcript.normalized(text) == Transcript.normalized(ChatModel.promptText(message)) {
            cancelMessageEdit()
            return
        }
        if !confirmed, (promptsAfter?(message) ?? 0) > 0 {
            deepEditConfirmation = message
            return
        }
        deepEditConfirmation = nil
        editingMessage = nil
        restoreMessageStash()
        guard await rewind(message, text) == false else { return }
        messageStash = (draft, attachments)
        editingMessage = message
        setDraft(text)
        attachments = []
    }

    // MARK: Editing a queued prompt

    func edit(_ id: UUID) {
        cancelMessageEdit()
        guard editStash == nil, let entry = sender.beginEdit(id) else { return }
        editStash = (draft, attachments)
        setDraft(entry.display ?? entry.text)
        attachments = entry.attachments
    }

    func cancelEdit() {
        sender.cancelEdit()
        restoreStash()
    }

    private func restoreStash() {
        guard let stash = editStash else { return }
        editStash = nil
        setDraft(stash.draft)
        attachments = stash.attachments
    }

    // MARK: Completions

    private func draftChanged() {
        completionTask?.cancel()
        guard !accepting else { return }
        let text = draft
        if text.hasPrefix("/"), !text.contains("\n") {
            trigger = .slash
            completionTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                await self?.loadSlash(text)
            }
        } else if let word = Self.pathToken(text) {
            trigger = .path
            completionTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                await self?.loadPath(word, in: text)
            }
        } else {
            trigger = .none
            completions = []
        }
    }

    /// The `@…` token the draft ends with.
    nonisolated static func pathToken(_ text: String) -> String? {
        guard let last = text.split(whereSeparator: \.isWhitespace).last, !text.last!.isWhitespace,
              last.hasPrefix("@") else { return nil }
        return String(last)
    }

    private func loadSlash(_ text: String) async {
        let rows: [CompletionRow]
        if text == "/" {
            guard let catalog = await commandsCatalog() else { return }
            rows = Self.catalogRows(catalog)
        } else {
            let session = chat.runtimeSessionID
            guard let result = try? await client.completeSlash(.init(text: text, sessionId: session, profile: session == nil ? profile : nil)) else {
                return
            }
            let catalog = await commandsCatalog()
            rows = Self.slashRows(result, text: text, catalog: catalog)
        }
        guard draft == text else { return }
        completions = rows
    }

    private func loadPath(_ token: String, in text: String) async {
        let query = String(token.dropFirst())
        let word = Self.refStarters.contains(query.lowercased()) ? "@\(query):" : token
        let items = (try? await client.completePath(.init(profile: profile, word: word, sessionId: chat.runtimeSessionID)))?.items ?? []
        guard draft == text else { return }
        var rows = items.enumerated().map { index, item in
            CompletionRow(id: "\(item.text)|\(index)", insert: item.text, title: item.display ?? item.text, detail: item.meta, group: nil)
        }
        if rows.isEmpty {
            rows = Self.refStarters.filter { query.isEmpty || $0.hasPrefix(query.lowercased()) }.map {
                CompletionRow(id: "starter:\($0)", insert: "@\($0):", title: "@\($0):", detail: Self.starterDetail($0), group: nil)
            }
        }
        completions = rows
    }

    private static func starterDetail(_ kind: String) -> String {
        switch kind {
        case "git": return "Attach git context"
        default: return "Attach a \(kind) reference"
        }
    }

    /// The commands catalog of the live session (cached per session); also gives the slash runner aliases and the
    /// commands this app can't offer.
    func commandsCatalog() async -> CommandsCatalogResult? {
        let session = chat.runtimeSessionID
        if let catalog, catalog.session == session { return catalog.result }
        guard let result = try? await client.commandsCatalog(.init(sessionId: session, profile: session == nil ? profile : nil)) else {
            return nil
        }
        catalog = (session, result)
        return result
    }

    /// Whether `command` (`/name`) may be offered here: not desktop-local, and offered on the desktop.
    nonisolated static func isOffered(_ command: String, catalog: CommandsCatalogResult?) -> Bool {
        let name = String(command.drop { $0 == "/" }.prefix { !$0.isWhitespace }).lowercased()
        guard !name.isEmpty, !SlashCommandRunner.unavailable.contains(name) else { return false }
        let canonical = catalog?.canon?["/\(name)"] ?? "/\(name)"
        return catalog?.commands?[canonical]?.desktop == nil && catalog?.commands?["/\(name)"]?.desktop == nil
    }

    /// The bare `/` list: the catalog by section, then the skills it lists outside them.
    nonisolated static func catalogRows(_ catalog: CommandsCatalogResult) -> [CompletionRow] {
        var rows: [CompletionRow] = []
        var seen: Set<String> = []
        let sections = catalog.categories?.isEmpty == false ? catalog.categories! : [CommandCategory(name: "", pairs: catalog.pairs)]
        for section in sections {
            for pair in section.pairs ?? [] {
                guard let command = pair.first, isOffered(command, catalog: catalog), seen.insert(command.lowercased()).inserted else { continue }
                rows.append(CompletionRow(id: "\(section.name)|\(command)", insert: "\(command) ", title: command,
                                          detail: pair.count > 1 ? pair[1] : nil, group: section.name.isEmpty ? nil : section.name))
            }
        }
        for pair in catalog.pairs ?? [] {
            guard let command = pair.first, isOffered(command, catalog: catalog), seen.insert(command.lowercased()).inserted else { continue }
            rows.append(CompletionRow(id: "Skills|\(command)", insert: "\(command) ", title: command,
                                      detail: pair.count > 1 ? pair[1] : nil, group: "Skills"))
        }
        return rows
    }

    /// `complete.slash` rows. An argument completion (`replace_from` past the command) carries only the argument,
    /// so its insert keeps the command before it.
    nonisolated static func slashRows(_ result: CompleteSlashResult, text: String, catalog: CommandsCatalogResult?) -> [CompletionRow] {
        let replaceFrom = result.replaceFrom ?? 1
        let isArgument = replaceFrom > 1
        let prefix = isArgument ? String(text.prefix(replaceFrom)) : ""
        let rows = (result.items ?? []).enumerated().compactMap { index, item -> CompletionRow? in
            if !isArgument, !isOffered(item.text, catalog: catalog) { return nil }
            let insert = isArgument ? prefix + item.text : item.text
            let group = isArgument ? "Options" : (item.kind == "skill" ? "Skills" : "Commands")
            return CompletionRow(id: "\(insert)|\(index)", insert: insert.hasSuffix(" ") ? insert : insert + " ",
                                 title: item.display ?? item.text, detail: item.meta, group: group)
        }
        let order = ["Commands", "Skills", "Options"]
        return rows.enumerated().sorted { a, b in
            let left = order.firstIndex(of: a.element.group ?? "") ?? 0, right = order.firstIndex(of: b.element.group ?? "") ?? 0
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
    }

    /// Puts the completion in place of the token it completes.
    func accept(_ row: CompletionRow) {
        var text = draft
        switch trigger {
        case .slash:
            text = row.insert
        case .path:
            if let token = Self.pathToken(text) { text.removeLast(token.count) }
            // A folder or a ref kind keeps going; anything else ends the token.
            text += row.insert.hasSuffix("/") || row.insert.hasSuffix(":") ? row.insert : row.insert + " "
        case .none:
            return
        }
        draft = text
        if trigger == .path, !(row.insert.hasSuffix("/") || row.insert.hasSuffix(":")) {
            completionTask?.cancel()
            completions = []
            trigger = .none
        }
    }

    func dismissCompletions() {
        completionTask?.cancel()
        completions = []
        trigger = .none
    }

    // MARK: Model, effort, Fast

    /// The catalog and the session's current model, effort and Fast.
    func refreshModel() async {
        let session = chat.runtimeSessionID
        if let result = try? await client.modelOptions(.init(profile: profile, sessionId: session)) {
            options = result
            if pendingModel == nil, let provider = result.provider, let model = result.model, !model.isEmpty {
                self.model = ModelPick(provider: provider, model: model)
            }
        }
        do {
            let value = try await client.configGet(.init(profile: profile, key: "reasoning", sessionId: session)).value
            if let value, !value.isEmpty { effort = value }
        } catch {
            // A Hermes that can't say runs its default.
            if effort == nil, !error.isCancellation { effort = Self.defaultEffort }
        }
        if let value = try? await client.configGet(.init(profile: profile, key: "fast", sessionId: session)).value {
            fast = value == "fast" || value == "ultrafast"
        }
    }

    private func apply(_ info: SessionLiveInfo) {
        if let provider = info.provider, let model = info.model, !model.isEmpty, pendingModel == nil {
            self.model = ModelPick(provider: provider, model: model)
        }
        if let effort = info.reasoningEffort, !effort.isEmpty { self.effort = effort }
        if let fast = info.fast { self.fast = fast }
    }

    /// The capabilities the catalog lists for the current model.
    var capabilities: ModelCapabilities? {
        guard let model, let provider = options?.providers.first(where: { $0.slug == model.provider }) else { return nil }
        return provider.capabilities?[model.model]
    }

    var supportsReasoning: Bool { capabilities?.reasoning ?? true }

    /// Thinking can be turned off (reasoning-mandatory routes can't).
    var canDisableReasoning: Bool { supportsReasoning && capabilities?.canDisableReasoning != false }

    var fastControl: FastControl {
        guard let model else { return fast ? .parameter(on: true) : .none }
        if capabilities?.fast == true { return .parameter(on: fast) }
        let models = options?.providers.first { $0.slug == model.provider }?.models ?? []
        if model.model.lowercased().hasSuffix("-fast") {
            let base = String(model.model.dropLast("-fast".count))
            return models.contains(base) ? .variant(base: base, fast: model.model, on: true) : .none
        }
        if models.contains("\(model.model)-fast") { return .variant(base: model.model, fast: "\(model.model)-fast", on: false) }
        // Carried over from another model: offered so it can be turned off.
        return fast ? .parameter(on: true) : .none
    }

    /// Switches the session's model (`config.set model "<model> --provider <p>"`). Session-only for a MoA preset;
    /// without a session the pick waits for it.
    func select(_ pick: ModelPick) async {
        let previous = model
        model = pick
        guard let session = chat.runtimeSessionID else {
            pendingModel = pick
            return
        }
        pendingModel = nil
        do {
            let result = try await client.configSet(.init(profile: profile, key: "model", value: .string(Self.switchValue(pick)),
                                                          sessionId: session))
            if result.confirmRequired == true {
                model = previous
                modelConfirmation = ModelConfirmation(pick: pick, message: result.confirmMessage ?? "This model may cost more. Switch anyway?")
                return
            }
            if let warning = result.warning, !warning.isEmpty { notice = warning }
            if result.deferred != true { await refreshModel() }
        } catch let error as GatewayRPCError where error.code == 4009 {
            // An older Hermes refuses a switch mid-turn; the next turn runs the pick anyway.
        } catch is GatewayDecodingError {
        } catch {
            model = previous
            notice = "Couldn't switch the model: \(error.localizedDescription)"
        }
    }

    /// `config.set model`'s value: `<model> --provider <p>`, session-only for a MoA preset (never saved as the default).
    nonisolated static func switchValue(_ pick: ModelPick) -> String {
        "\(pick.model) --provider \(pick.provider)\(pick.provider.lowercased() == "moa" ? " --session" : "")"
    }

    /// `session.create` carried what was picked before the session existed, so there is nothing left to apply.
    func pendingApplied(_ pick: ModelPick?, effort: String?, fast: Bool?) {
        if let pick, pendingModel == pick { pendingModel = nil }
        if let effort, pendingEffort == effort { pendingEffort = nil }
        if let fast, pendingFast == fast { pendingFast = nil }
    }

    /// Switches with a confirmation Hermes asked for (an expensive model).
    func confirmSelect(_ pick: ModelPick) async {
        guard let session = chat.runtimeSessionID else { return }
        model = pick
        _ = try? await client.configSet(.init(profile: profile, key: "model", value: .string(Self.switchValue(pick)),
                                             sessionId: session, confirmExpensiveModel: true))
        await refreshModel()
    }

    /// `config.set reasoning <level>`; "none" turns thinking off. Without a session the choice waits for it.
    func setEffort(_ level: String) async {
        let previous = effort
        effort = level
        guard let session = chat.runtimeSessionID else {
            pendingEffort = level
            return
        }
        pendingEffort = nil
        do {
            _ = try await client.configSet(.init(profile: profile, key: "reasoning", value: .string(level), sessionId: session))
        } catch is GatewayDecodingError {
        } catch {
            effort = previous
            notice = "Couldn't change the reasoning effort: \(error.localizedDescription)"
        }
    }

    /// Fast on or off: the speed parameter (`config.set fast fast|normal`), or a switch to the `-fast` sibling.
    func setFast(_ enabled: Bool) async {
        if case let .variant(base, fastModel, _) = fastControl, let model {
            await select(ModelPick(provider: model.provider, model: enabled ? fastModel : base))
            return
        }
        fast = enabled
        guard let session = chat.runtimeSessionID else {
            pendingFast = enabled
            return
        }
        pendingFast = nil
        do {
            _ = try await client.configSet(.init(profile: profile, key: "fast", value: .string(enabled ? "fast" : "normal"), sessionId: session))
        } catch is GatewayDecodingError {
        } catch {
            fast = !enabled
            notice = "Couldn't change Fast: \(error.localizedDescription)"
        }
    }

    /// The pill's short effort label (the desktop's `SHORT_LABELS`).
    nonisolated static func effortLabel(_ effort: String?) -> String {
        switch (effort ?? defaultEffort).lowercased() {
        case "none": return "Off"
        case "minimal": return "Min"
        case "low": return "Low"
        case "medium": return "Med"
        case "high": return "High"
        case "xhigh": return "XHigh"
        case "max": return "Max"
        case "ultra": return "Ultra"
        case let other: return other
        }
    }

    /// The model pill's label: the model id without its vendor path.
    nonisolated static func modelLabel(_ model: String, fast: Bool) -> String {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        return fast ? "\(name) · Fast" : name
    }
}
