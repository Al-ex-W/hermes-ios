import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = ConnectionSettings.load()
    @Published private(set) var signedIn = false
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var error: String?

    let calls = CallController()
    private(set) var client: DashboardClient?
    private(set) var connection: GatewayConnection?
    /// Approvals, questions and passwords Hermes is waiting on, for every chat.
    private(set) var prompts: PromptCenter?
    /// One model per stored session, so the list, the chat screen and a call share its state.
    private var chats: [String: ChatModel] = [:]
    /// Bumped on sign-in and sign-out, so a chat from an earlier sign-in can't enter the cache.
    private var generation = 0

    func restore() async {
        guard !settings.dashboardURL.isEmpty, !settings.password.isEmpty else { return }
        await signIn(settings)
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
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Voice settings can change without signing in again.
    func updateVoice(url: String, token: String, speechLocale: String) {
        settings.voiceServerURL = url
        settings.voiceToken = token
        settings.speechLocale = speechLocale
        settings.save()
    }

    /// Hangs up without telling Hermes, closes the gateway connection for good, and logs out of the dashboard.
    func signOut() {
        calls.end(notifyHermes: false)
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
        let address = settings.voiceServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !settings.voiceToken.isEmpty else {
            calls.lastError = "Add the Hermes Voice server address and token in Settings first."
            return
        }
        guard settings.hasVoiceServer else {
            calls.lastError = "The Hermes Voice server address isn't valid. Use one like \(ConnectionSettings.voiceAddressExample) in Settings."
            return
        }
        await calls.start(VoiceCall(chat: chat, settings: settings))
    }
}
