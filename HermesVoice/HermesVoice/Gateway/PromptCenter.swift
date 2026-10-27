import Foundation
import os

private let promptLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesVoice", category: "PromptCenter")

/// The server→client requests waiting on the user (approval, clarify, sudo, secret, vault, …), per session, and
/// their answers. Window-owned bridges (preview, terminal and window reads, the tour) aren't shown here: they are
/// declined with 4404 where the backend counts declines, else left to the desktop window showing the session. An
/// answer goes back as the request's JSON-RPC response; while no socket is open it goes through `request.answer`
/// once reconnected. An approval restored from a resume snapshot (no open request) is answered through
/// `approval.respond`.
@MainActor
final class PromptCenter: ObservableObject, ServerRequestHandling {
    struct Prompt: Identifiable, Equatable {
        enum Kind: Equatable {
            case approval(Approval)
            case clarify(ClarifyRequestParams)
            case value(ValueRequest)
        }

        /// The server-request id (a restored approval's is local).
        let id: String
        /// The runtime session it blocks; nil for an app-level prompt.
        let sessionID: String?
        var kind: Kind
        /// Its answer is on the way.
        var answering = false
        /// Why the last answer didn't get through.
        var failure: String?
        /// The connection's frame count when it arrived (see `reconcile`).
        fileprivate var arrival: Int

        var isRestoredApproval: Bool {
            if case let .approval(approval) = kind { return approval.restored }
            return false
        }
    }

    struct Approval: Equatable {
        var command: String
        var description: String
        /// The buttons to offer; `deny` is always among them.
        var choices: [ApprovalChoice]
        /// The approval queue entry, which `approval.respond` takes.
        var requestID: String?
        /// Restored from a resume snapshot: no open request, so `approval.respond` answers it.
        var restored = false
    }

    /// A string-valued request: a password, a secret, a one-time code or a login to save.
    struct ValueRequest: Equatable {
        enum Field: Equatable {
            case secret
            case code
            /// Identifier and password, answered as JSON `{identifier, password}`.
            case login
        }

        let method: String
        let title: String
        let message: String?
        let field: Field
    }

    /// `approval.respond` can wait behind a long stream before Hermes reads it (the desktop's deadline).
    static let approvalRespondTimeout: TimeInterval = 330

    @Published private(set) var prompts: [Prompt] = []

    private let connection: GatewayConnection
    private var listener: UUID?
    /// Answers sent as response frames, newest last. A request re-delivered after a reconnect (the answer was lost
    /// with its socket) gets the same answer again; Hermes drops one for a request that already ended.
    private var sent: [(id: String, result: JSONValue)] = []

    init(connection: GatewayConnection) {
        self.connection = connection
        connection.requests = self
        listener = connection.addListener { [weak self] event, _, _ in self?.handle(event) }
    }

    deinit {
        let connection = connection, listener = listener
        Task { @MainActor in if let listener { connection.removeListener(listener) } }
    }

    /// A chat's prompts: those of any runtime id its session had, and the app-level ones.
    func prompts(for sessionIDs: Set<String>) -> [Prompt] {
        prompts.filter { prompt in prompt.sessionID.map(sessionIDs.contains) ?? true }
    }

    /// Answered only by the desktop window showing the session (its preview, terminal or tour panes).
    nonisolated static func isWindowOwned(_ method: String) -> Bool {
        method.hasPrefix("preview.") || ["terminal.read", "window.read", "tour"].contains(method)
    }

    // MARK: Answering

    /// Answers an approval card: `once`, `session`, `always` or `deny`; `all` resolves every queued approval.
    func approve(_ id: String, _ choice: ApprovalChoice, all: Bool = false) async {
        guard let prompt = begin(id), case let .approval(approval) = prompt.kind else { return }
        guard approval.restored else {
            return await answer(id, ApprovalResult(choice: choice, all: all ? true : nil))
        }
        do {
            _ = try await connection.client.approvalRespond(
                .init(sessionId: prompt.sessionID ?? "", choice: choice.rawValue, all: all, requestId: approval.requestID),
                timeout: Self.approvalRespondTimeout
            )
            remove(id)
        } catch is GatewayDecodingError {
            remove(id)
        } catch {
            fail(id, error)
        }
    }

    /// Answers a clarify card: per question id an answer, or nil to skip it. `nil` cancels every question.
    func answerClarify(_ id: String, answers: [String: String?]?) async {
        guard begin(id) != nil else { return }
        await answer(id, ClarifyResult(answers: answers))
    }

    /// Answers a value prompt; "" declines it.
    func answerValue(_ id: String, _ value: String) async {
        guard begin(id) != nil else { return }
        await answer(id, ValueResult(value: value))
    }

    /// The request was answered outside its card (from a notification), or Hermes no longer waits for it: the card
    /// goes, unless an answer from it is on the way. `id` is the server-request id, or an approval's queue entry.
    func answeredOutside(_ id: String) {
        prompts.removeAll { prompt in
            guard !prompt.answering else { return false }
            if prompt.id == id { return true }
            if case let .approval(approval) = prompt.kind { return approval.requestID == id }
            return false
        }
    }

    private func answer<Result: Encodable>(_ id: String, _ result: Result) async {
        let value: JSONValue
        do {
            value = try JSONValue.encode(result)
        } catch {
            return fail(id, error)
        }
        if connection.respond(to: id, result: value) {
            sent.append((id, value))
            if sent.count > 32 { sent.removeFirst(sent.count - 32) }
            remove(id)
            return
        }
        // No socket now: answer out of band once reconnected (the reconnect re-delivers the request meanwhile).
        do {
            // `expired`: the request ended meanwhile; either way there is nothing left to answer.
            _ = try await connection.client.requestAnswer(.init(id: id, result: value.objectValue ?? [:]))
            remove(id)
        } catch is GatewayDecodingError {
            remove(id)
        } catch {
            fail(id, error)
        }
    }

    private func begin(_ id: String) -> Prompt? {
        guard let index = prompts.firstIndex(where: { $0.id == id }), !prompts[index].answering else { return nil }
        prompts[index].answering = true
        prompts[index].failure = nil
        return prompts[index]
    }

    private func fail(_ id: String, _ error: Error) {
        guard let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        prompts[index].answering = false
        if !error.isCancellation { prompts[index].failure = error.localizedDescription }
    }

    private func remove(_ id: String) {
        prompts.removeAll { $0.id == id }
    }

    // MARK: ServerRequestHandling

    func receive(_ request: ServerRequest, replayed: Bool, arrival: Int) {
        let id = request.id
        if let answer = sent.last(where: { $0.id == id }) {
            connection.respond(to: id, result: answer.result)
            return
        }
        if Self.isWindowOwned(request.method) {
            // Hermes counts a 4404 as one client declining. An older backend takes the first error as the answer,
            // so there the window that shows the session answers alone.
            if connection.declinesNotShown {
                connection.respond(to: id, errorCode: 4404, message: "HermesVoice doesn't show this session's desktop panes.")
            }
            return
        }
        guard let kind = Self.kind(of: request) else {
            promptLog.error("Can't answer server request \(request.method, privacy: .public)")
            connection.respond(to: id, errorCode: -32601, message: "HermesVoice can't answer \(request.method).")
            return
        }
        if let index = prompts.firstIndex(where: { $0.id == id }) {
            prompts[index].kind = kind
            prompts[index].arrival = arrival
            return
        }
        if case let .approval(approval) = kind {
            // The live request replaces the copy restored from a resume snapshot.
            prompts.removeAll { prompt in
                guard prompt.sessionID == request.sessionID, case let .approval(restored) = prompt.kind, restored.restored else { return false }
                return restored.requestID == nil || restored.requestID == approval.requestID
            }
        }
        prompts.append(Prompt(id: id, sessionID: request.sessionID, kind: kind, arrival: arrival))
    }

    func reconcile(_ sessionID: String, open: Set<String>, asOf arrival: Int) {
        prompts.removeAll { prompt in
            prompt.sessionID == sessionID && prompt.arrival <= arrival && !prompt.answering && !prompt.isRestoredApproval
                && !open.contains(prompt.id)
        }
    }

    func restore(pendingApproval pending: PendingApproval?, sessionID: String, listed: Set<String>) {
        guard let pending else {
            prompts.removeAll { $0.sessionID == sessionID && $0.isRestoredApproval && !$0.answering }
            return
        }
        // The live request listed in the same result covers it, whether it shows a card or was just answered again.
        if !listed.isEmpty, pending.requestId.map(listed.contains) ?? true {
            prompts.removeAll { prompt in
                guard prompt.sessionID == sessionID, !prompt.answering, case let .approval(approval) = prompt.kind,
                      approval.restored else { return false }
                return approval.requestID.map(listed.contains) ?? true
            }
            return
        }
        // A live request delivered earlier shows it.
        let shown = prompts.contains { prompt in
            guard prompt.sessionID == sessionID, case let .approval(approval) = prompt.kind else { return false }
            return approval.requestID == nil || pending.requestId == nil || approval.requestID == pending.requestId
        }
        guard !shown else { return }
        let approval = Approval(
            command: pending.command ?? "",
            description: pending.description ?? "Dangerous command",
            choices: Self.choices(pending.choices?.map(ApprovalChoice.init(rawValue:)),
                                  allowSession: pending.allowSession, allowPermanent: pending.allowPermanent),
            requestID: pending.requestId,
            restored: true
        )
        prompts.append(Prompt(id: "approval-\(sessionID)-\(pending.requestId ?? "pending")", sessionID: sessionID,
                              kind: .approval(approval), arrival: 0))
    }

    func sessionReplaced(_ old: String, by new: String) {
        prompts.removeAll { $0.sessionID == old && !$0.answering }
    }

    // MARK: Events

    private func handle(_ event: GatewayEvent) {
        switch event {
        case let .requestCancel(payload):
            remove(payload.id)
            sent.removeAll { $0.id == payload.id }
        case let .approvalCancelled(payload):
            let ids = Set(payload.requestIds)
            prompts.removeAll { prompt in
                guard prompt.sessionID == payload.sessionId, case let .approval(approval) = prompt.kind else { return false }
                return approval.requestID.map(ids.contains) ?? true
            }
        case let .sessionReclaimed(payload):
            prompts.removeAll { $0.sessionID == payload.sessionId }
        default:
            break
        }
    }

    // MARK: Mapping

    private static func kind(of request: ServerRequest) -> Prompt.Kind? {
        switch request {
        case let .approval(_, params):
            return .approval(Approval(
                command: params.command ?? "",
                description: params.description ?? "Dangerous command",
                choices: choices(params.choices, allowSession: params.allowSession, allowPermanent: params.allowPermanent),
                requestID: params.requestId
            ))
        case let .clarify(_, params):
            return .clarify(params)
        case let .sudo(_, params):
            return .value(ValueRequest(method: request.method, title: "Password for sudo", message: params.command, field: .secret))
        case let .secret(_, params):
            return .value(ValueRequest(method: request.method, title: params.envVar, message: params.prompt, field: .secret))
        case .displayInstallSudo:
            return .value(ValueRequest(method: request.method, title: "Password to install the screen packages",
                                       message: "Hermes needs sudo to install them.", field: .secret))
        case let .vaultCode(_, params):
            return .value(ValueRequest(method: request.method, title: "Code for \(params.site ?? "the site")",
                                       message: params.hint, field: .code))
        case let .vaultSaveLogin(_, params):
            return .value(ValueRequest(method: request.method, title: "Save a login for \(params.site)",
                                       message: params.origin, field: .login))
        case let .vaultUnlockPrompt(_, params):
            return .value(ValueRequest(method: request.method, title: "Unlock \(params.displayName)",
                                       message: "Master password", field: .secret))
        default:
            return nil
        }
    }

    /// The offered choices without the ones Hermes won't honor, and always `deny`.
    private static func choices(_ offered: [ApprovalChoice]?, allowSession: Bool?, allowPermanent: Bool?) -> [ApprovalChoice] {
        var choices = (offered ?? ApprovalChoice.allCases).filter { choice in
            switch choice {
            case .session: return allowSession != false
            case .always: return allowPermanent != false
            default: return true
            }
        }
        if !choices.contains(.deny) { choices.append(.deny) }
        return choices
    }
}
