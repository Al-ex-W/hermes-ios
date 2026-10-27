import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = ConnectionSettings.load()
    @Published private(set) var signedIn = false
    @Published var error: String?
    /// How calls listen (provider, language, end of speech).
    @Published var callSettings = CallSettings.load() {
        didSet { callSettings.save() }
    }

    let calls = CallController()
    /// VoIP pushes, so Hermes can ring this phone (`start_call`), and the alert token beside them.
    let push = PushRegistration()
    /// Background alerts (approval, question, turn done): their actions, taps and foreground banners.
    let notifications = AlertNotifications()
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
        notifications.attach(to: self)
        push.onIncoming = { [weak self] call, completion in
            guard let self else { return completion() }
            guard let call else { return self.calls.reportUnusablePush(completion: completion) }
            self.calls.reportIncoming(call, completion: completion) { [weak self] call in
                guard let self else { throw CancellationError() }
                return try await self.incomingCall(call)
            }
        }
    }

    /// At launch, before any VoIP push or notification action can be delivered.
    func startPush() {
        push.start()
        notifications.start()
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

    /// Hangs up, closes the gateway connection for good, and logs out of the dashboard. The plugin is first told to
    /// send this phone no more alerts (while the cookie still works), so a signed-out lock screen shows no commands
    /// or questions; the next sign-in registers the opt-ins again.
    func signOut() {
        calls.end()
        connection?.disconnect()
        if let leaving = client {
            push.setAlerts(.none)
            let push = push
            Task {
                await Self.waiting(atMost: 5) { await push.send(to: leaving) }
                leaving.signOut()
            }
        }
        notifications.signedOut()
        connection = nil
        prompts = nil
        client = nil
        chats.removeAll()
        generation += 1
        settings.password = ""
        settings.save()
        error = nil
        signedIn = false
    }

    /// The app is back in the foreground: check the gateway connection and catch up the chats in use.
    func didBecomeActive() {
        guard signedIn else { return }
        connection?.probe()
        for chat in chats.values { chat.wake() }
        calls.active?.chat.wake()
    }

    /// The chat for a stored session (always the same model for one session), or a new chat in `profile` when
    /// `summary` is nil.
    func chat(for summary: SessionSummary?, profile: String? = nil) -> ChatModel? {
        guard let client, let connection else { return nil }
        if let summary {
            if let existing = chats[summary.id] { return existing }
            if let call = calls.active?.chat, call.storedID == summary.id {
                chats[summary.id] = call
                return call
            }
        }
        let chat = ChatModel(client: client, connection: connection, prompts: prompts, summary: summary, profile: profile)
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

    /// The chat already open for a stored session, if any.
    func existingChat(_ storedID: String) -> ChatModel? {
        if let chat = chats[storedID] { return chat }
        guard let call = calls.active?.chat, call.storedID == storedID else { return nil }
        return call
    }

    /// The session was deleted: its chat lets go of the live session and leaves the cache.
    func forget(_ storedID: String) {
        existingChat(storedID)?.sessionGone()
        chats[storedID] = nil
    }

    func startCall(in chat: ChatModel) async {
        guard let client else { return }
        await calls.start(chat: chat, client: client, settings: callSettings)
    }

    /// Runs `work`, giving up on waiting for it after `seconds` (it keeps running).
    static func waiting(atMost seconds: Double, for work: @escaping @MainActor () async -> Void) async {
        final class Once {
            var continuation: CheckedContinuation<Void, Never>?
            func resume() {
                continuation?.resume()
                continuation = nil
            }
        }
        let once = Once()
        await withCheckedContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                await work()
                once.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume()
            }
        }
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
