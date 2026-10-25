import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = ConnectionSettings.load()
    @Published private(set) var signedIn = false
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var error: String?
    /// How calls listen (provider, language, end of speech).
    @Published var callSettings = CallSettings.load() {
        didSet { callSettings.save() }
    }

    let calls = CallController()
    /// VoIP pushes, so Hermes can ring this phone (`start_call`).
    let push = PushRegistration()
    private(set) var client: DashboardClient?
    private(set) var connection: GatewayConnection?
    /// Approvals, questions and passwords Hermes is waiting on, for every chat.
    private(set) var prompts: PromptCenter?
    /// One model per stored session, so the list, the chat screen and a call share its state.
    private var chats: [String: ChatModel] = [:]
    /// Bumped on sign-in and sign-out, so a chat from an earlier sign-in can't enter the cache.
    private var generation = 0
    /// The launch sign-in, shared by the window and a VoIP push that launched the app.
    private var restoring: Task<Void, Never>?

    init() {
        push.onToken = { [weak self] _ in self?.sendPushToken() }
        push.onIncoming = { [weak self] call, completion in
            guard let self else { return completion() }
            guard let call else { return self.calls.reportUnusablePush(completion: completion) }
            self.calls.reportIncoming(call, completion: completion) { [weak self] call in
                guard let self else { throw CancellationError() }
                return try await self.incomingCall(call)
            }
        }
    }

    /// At launch, before any VoIP push can be delivered.
    func startPush() {
        push.start()
    }

    func restore() async {
        if let restoring { return await restoring.value }
        guard !signedIn, !settings.dashboardURL.isEmpty, !settings.password.isEmpty else { return }
        let task = Task { await signIn(settings) }
        restoring = task
        await task.value
        restoring = nil
    }

    func signIn(_ next: ConnectionSettings) async {
        do {
            let client = try DashboardClient(settings: next)
            try await client.signIn()
            next.save()
            settings = next
            connection?.disconnect()
            self.client = client
            let connection = GatewayConnection(client: client)
            self.connection = connection
            prompts = PromptCenter(connection: connection)
            chats.removeAll()
            generation += 1
            signedIn = true
            error = nil
            sendPushToken()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Hangs up, closes the gateway connection for good, and logs out of the dashboard.
    func signOut() {
        calls.end()
        connection?.disconnect()
        client?.signOut()
        connection = nil
        prompts = nil
        client = nil
        chats.removeAll()
        generation += 1
        sessions = []
        settings.password = ""
        settings.save()
        error = nil
        signedIn = false
    }

    func refresh() async {
        guard let client else { return }
        do {
            let sessions = try await client.sessions()
            guard client === self.client else { return }
            self.sessions = sessions
            error = nil
        } catch {
            guard client === self.client, !error.isCancellation else { return }
            self.error = error.localizedDescription
        }
    }

    /// The app is back in the foreground: check the gateway connection, catch up the chats in use, refresh the list.
    func didBecomeActive() {
        guard signedIn else { return }
        connection?.probe()
        for chat in chats.values { chat.wake() }
        calls.active?.chat.wake()
        Task { await refresh() }
    }

    /// The chat for a stored session (always the same model for one session), or a new chat when `summary` is nil.
    func chat(for summary: SessionSummary?) -> ChatModel? {
        guard let client, let connection else { return nil }
        if let summary {
            if let existing = chats[summary.id] { return existing }
            if let call = calls.active?.chat, call.storedID == summary.id {
                chats[summary.id] = call
                return call
            }
        }
        let chat = ChatModel(client: client, connection: connection, summary: summary)
        if let summary {
            chats[summary.id] = chat
        } else {
            // Cache a new chat once Hermes has stored it (its first prompt went through), so reopening it
            // from the list finds this model; a draft left empty is let go with its view.
            let generation = generation
            chat.onStoredID = { [weak self, weak chat] key in
                guard let self, let chat, self.generation == generation, self.chats[key] == nil else { return }
                self.chats[key] = chat
            }
        }
        return chat
    }

    func startCall(in chat: ChatModel) async {
        guard let client else { return }
        await calls.start(chat: chat, client: client, settings: callSettings)
    }

    /// Tells the Hermes Voice plugin where to ring this phone.
    func sendPushToken() {
        guard let client else { return }
        Task { await push.send(to: client) }
    }

    /// The call a VoIP push rang: its chat, signing in first when the push launched the app.
    private func incomingCall(_ call: CallPush) async throws -> VoiceCall {
        if !signedIn { await restore() }
        guard signedIn, let client else { throw DashboardError.signedOut }
        let summary = call.sessionID.map { SessionSummary(id: $0, title: call.title ?? "Hermes", lastActive: nil, profile: call.profile) }
        guard let chat = chat(for: summary) else { throw DashboardError.signedOut }
        return VoiceCall(chat: chat, settings: callSettings, initiatedBy: .push, callID: call.callID, push: call,
                         environment: .live(client: client, settings: callSettings))
    }
}
