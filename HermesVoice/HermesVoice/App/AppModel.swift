import Combine
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
    /// "Share location with Hermes": off by default; while on, Hermes may ask this iPhone where it is.
    let location: LocationSharing
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
    /// Closes the gateway connection while the app is in the background with no call, so alerts are pushed.
    let lifecycle: GatewayLifecycle
    private var subscriptions: Set<AnyCancellable> = []

    /// `phase`: where the app starts (tests); by default what iOS reports (a VoIP push launches it in the background).
    init(phase: GatewayLifecycle.Phase? = nil, location: LocationSharing? = nil) {
        lifecycle = GatewayLifecycle(phase: phase ?? GatewayLifecycle.currentPhase)
        self.location = location ?? LocationSharing()
        calls.$inCall.removeDuplicates().sink { [weak self] inCall in
            self?.lifecycle.setCallActive(inCall)
        }.store(in: &subscriptions)
        push.onToken = { [weak self] _ in self?.sendPushToken() }
        notifications.attach(to: self)
        attachLocation()
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
            lifecycle.use(connection)
            prompts = PromptCenter(connection: connection)
            chats.removeAll()
            generation += 1
            signedIn = true
            error = nil
            push.setLocation(location.registration)
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
            // Signed out, the phone can't answer a location request: the host hears that sharing is off.
            push.setLocation(["enabled": false, "background": false])
            let push = push
            Task {
                await Self.waiting(atMost: 5) { await push.send(to: leaving) }
                leaving.signOut()
            }
        }
        notifications.signedOut()
        connection = nil
        lifecycle.use(nil)
        prompts = nil
        client = nil
        chats.removeAll()
        generation += 1
        settings.password = ""
        settings.save()
        error = nil
        signedIn = false
    }

    /// The app is back in the foreground: the gateway connection reopens (re-attaching and catching up the chats
    /// in use), or is checked if it stayed open.
    func didBecomeActive() {
        lifecycle.setPhase(.foreground)
        guard signedIn else { return }
        connection?.probe()
        for chat in chats.values { chat.wake() }
        calls.active?.chat?.wake()
    }

    /// The app went to the background: without a call the gateway connection closes, so Hermes sees no client here
    /// and alerts this phone by push instead.
    func didEnterBackground() {
        let wasPaused = lifecycle.paused
        lifecycle.setPhase(.background)
        if lifecycle.paused, !wasPaused, connection != nil { GatewayLifecycle.lingerForClose() }
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

    /// Location sharing: its state goes with the device registration (again whenever the switch or the iOS
    /// permission changes), a call answers Hermes' requests on its socket, and a background push is answered through
    /// the dashboard, signing in first when the push woke the app.
    private func attachLocation() {
        push.setLocation(location.registration)
        location.onRegistrationChange = { [weak self] in
            guard let self, self.signedIn else { return }
            self.push.setLocation(self.location.registration)
            self.sendPushToken()
        }
        location.tokens = { [weak self] in (self?.push.token, self?.push.alertToken) }
        location.client = { [weak self] in
            guard let self else { throw DashboardError.signedOut }
            if !self.signedIn {
                // Launched in the background before the first unlock, the Keychain read came back empty.
                if self.settings.password.isEmpty { self.settings = ConnectionSettings.load() }
                await self.restore()
            }
            guard self.signedIn, let client = self.client else { throw DashboardError.signedOut }
            return client
        }
        calls.locate = { [weak self] in await self?.location.answerOnCall() ?? .failure(.off) }
    }

    /// Tells the Hermes Voice plugin where to ring this phone.
    func sendPushToken() {
        guard let client else { return }
        Task { await push.send(to: client) }
    }

    /// The call a VoIP push rang, signing in first when the push launched the app: in its session's chat when the
    /// app can open that session, else on its own (`PushedCallRouter`).
    private func incomingCall(_ call: CallPush) async throws -> VoiceCall {
        if !signedIn { await restore() }
        guard signedIn, let client, let connection else { throw DashboardError.signedOut }
        let environment = VoiceCall.Environment.live(client: client, settings: callSettings, locate: calls.locate)
        let router = PushedCallRouter.live(client: client, connection: connection) { [weak self] id in
            self?.existingChat(id).map { SessionSummary(id: id, title: $0.title, lastActive: nil, profile: $0.profile) }
        }
        let route = await router.route(call)
        // Signed out (or in again) while looking: this sign-in's chats are gone.
        guard self.client === client else { throw DashboardError.signedOut }
        switch route {
        case let .chat(summary):
            guard let chat = chat(for: summary) else { throw DashboardError.signedOut }
            return VoiceCall(chat: chat, settings: callSettings, initiatedBy: .push, callID: call.callID, push: call,
                             environment: environment)
        case .standalone:
            return VoiceCall(chat: nil, settings: callSettings, initiatedBy: .push, callID: call.callID, push: call,
                             environment: environment)
        }
    }
}
