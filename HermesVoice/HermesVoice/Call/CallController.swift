import AVFoundation
import CallKit

/// CallKit for voice calls: calls the user starts in a chat, and calls Hermes rings through a VoIP push. The call
/// shows in the Dynamic Island / Lock Screen, keeps running in the background, and gets the system's call audio session.
@MainActor
final class CallController: NSObject, ObservableObject {
    @Published private(set) var active: VoiceCall? { didSet { updateInCall() } }
    /// A call is being set up (permissions, plugin check) and isn't `active` yet.
    @Published private(set) var starting = false { didSet { updateInCall() } }
    @Published var lastError: String?
    /// A call rings, is being set up or runs: the app keeps its gateway connection meanwhile, even in the background.
    @Published private(set) var inCall = false

    private let provider: CXProvider
    private let controller = CXCallController()
    /// `end` was asked for while a call was still starting.
    private var startCancelled = false
    /// A pushed call CallKit shows while its chat is still being opened (signing in after a cold launch).
    private var ringing: Ringing? { didSet { updateInCall() } }
    /// How long a pushed call may take to get its chat before it stops ringing; VoiceCall's own ring timeout matches.
    private let ringTimeout: TimeInterval = 45

    private struct Ringing {
        let uuid: UUID
        let since: Date
        var answered = false
        var ended = false
        var audioActive = false
    }

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// The call that rings, waiting for the user to answer.
    var isRinging: Bool { ringingUUID != nil }

    private func updateInCall() {
        let now = active != nil || ringing != nil || starting
        if now != inCall { inCall = now }
    }

    // MARK: Calls the user starts

    /// Starts a call in `chat`. The plugin is checked first, so a missing plugin or sign-in fails before CallKit
    /// shows a call.
    func start(chat: ChatModel, client: DashboardClient, settings: CallSettings) async {
        // Set before the first await, so a second tap meanwhile can't start another call.
        guard active == nil, ringing == nil, !starting else { return }
        starting = true
        startCancelled = false
        defer { starting = false }
        guard await Self.requestPermissions(for: settings.provider) else {
            lastError = settings.provider == .apple
                ? "Hermes Voice needs the microphone and speech recognition. Allow them in Settings."
                : "Hermes Voice needs the microphone. Allow it in Settings."
            return
        }
        let status: VoicePluginStatus
        do {
            status = try await VoicePluginAPI.status(client)
        } catch {
            if !startCancelled { lastError = error.localizedDescription }
            return
        }
        guard active == nil, ringing == nil, !startCancelled else { return }
        // Hermes has one call slot. A call it already holds for this chat (one `start_call` rang while the push
        // didn't get through, say) is joined under its own call_id; one for another chat makes this one busy.
        var callID = CallID.make()
        if let current = status.activeCall {
            guard current.sessionID != nil, current.sessionID == chat.storedID else {
                lastError = CallOutcome.busy.message
                return
            }
            callID = current.callID
        }
        let call = VoiceCall(chat: chat, settings: settings, initiatedBy: .user, callID: callID,
                             environment: .live(client: client, settings: settings))
        adopt(call)
        call.begin()
        #if targetEnvironment(simulator)
        // CallKit doesn't hand out audio sessions in the Simulator; run the call without it.
        activateSimulatorAudio(for: call)
        #else
        call.onConnected = { [weak self, uuid = call.uuid] in
            self?.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
        let action = CXStartCallAction(call: call.uuid, handle: Self.handle(title: chat.title))
        action.contactIdentifier = "Hermes"
        do {
            try await controller.request(CXTransaction(action: action))
            provider.reportCall(with: call.uuid, updated: Self.update(title: chat.title))
        } catch {
            fail(call, error)
        }
        #endif
    }

    static func requestPermissions(for provider: SpeechProviderID) async -> Bool {
        switch provider {
        case .apple: return await SpeechListener.requestPermissions()
        case .scribe: return await AVAudioApplication.requestRecordPermission()
        }
    }

    // MARK: Calls Hermes rings

    /// A VoIP push arrived: it is reported to CallKit at once (iOS requires that before the push is done), then
    /// `makeCall` opens the chat (signing in first after a cold launch) and the call rings on the plugin's side too.
    /// `completion` finishes the push.
    func reportIncoming(_ push: CallPush, completion: @escaping () -> Void,
                        makeCall: @escaping (CallPush) async throws -> VoiceCall) {
        guard let uuid = CallID.uuid(from: push.callID) else { return reportUnusablePush(completion: completion) }
        let update = Self.update(title: push.title ?? "Hermes")
        if active?.uuid == uuid || ringing?.uuid == uuid {
            // A repeat of the push for the call that rings: CallKit refuses the duplicate, which is fine.
            provider.reportNewIncomingCall(with: uuid, update: update) { _ in completion() }
            return
        }
        if active != nil || ringing != nil || starting {
            // One call at a time; the plugin hears nothing on this one and gives up on it.
            provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
                Task { @MainActor in
                    if error == nil { self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
                    completion()
                }
            }
            return
        }
        let since = Date()
        ringing = Ringing(uuid: uuid, since: since)
        #if targetEnvironment(simulator)
        // No VoIP pushes or CallKit audio in the Simulator: a debug push (`hermesvoice://ring`) rings in the app only.
        completion()
        #else
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            Task { @MainActor in
                defer { completion() }
                guard let self, error != nil else { return }
                // Do Not Disturb, a blocked caller, or another call: CallKit won't ring.
                if self.ringing?.uuid == uuid { self.ringing = nil }
                if let call = self.active, call.uuid == uuid { self.finish(call) }
            }
        }
        #endif
        let timeout = ringTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, let state = self.ringing, state.uuid == uuid, !state.answered else { return }
            self.ringing = nil
            self.provider.reportCall(with: uuid, endedAt: Date(), reason: .unanswered)
        }
        Task {
            let call: VoiceCall
            do {
                call = try await makeCall(push)
            } catch {
                guard let state = ringing, state.uuid == uuid else { return }
                ringing = nil
                if !state.ended { provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
                lastError = "Hermes called, but the chat couldn't be opened: \(error.localizedDescription)"
                return
            }
            guard let state = ringing, state.uuid == uuid else { return }
            // Adopted before the ring state goes, so `inCall` never dips (the gateway stays up in the background).
            adopt(call)
            ringing = nil
            call.begin(ringingSince: state.since)
            if state.answered { call.answer() }
            if state.ended {
                // Declined (or hung up) before the chat was open: the call tells the plugin, then goes.
                finish(call)
                return
            }
            #if targetEnvironment(simulator)
            if state.answered { activateSimulatorAudio(for: call) }
            #else
            if state.audioActive { call.audioDidActivate() }
            #endif
        }
    }

    /// A VoIP push without a usable call: iOS still requires a call to be reported for it, so one is, and ended.
    func reportUnusablePush(completion: @escaping () -> Void) {
        let uuid = UUID()
        provider.reportNewIncomingCall(with: uuid, update: Self.update(title: "Hermes")) { [weak self] error in
            Task { @MainActor in
                if error == nil { self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .failed) }
                completion()
            }
        }
    }

    /// Answers the call that rings (the in-app button; the system's own call screen answers through CallKit).
    func answer() {
        guard let uuid = ringingUUID else { return }
        #if targetEnvironment(simulator)
        guard let call = active, call.uuid == uuid else {
            ringing?.answered = true
            return
        }
        call.answer()
        activateSimulatorAudio(for: call)
        #else
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { _ in }
        #endif
    }

    private var ringingUUID: UUID? {
        if let call = active, call.state == .ringing { return call.uuid }
        return ringing?.uuid
    }

    // MARK: Hanging up

    /// Hangs up, or declines the call that rings.
    func end() {
        guard let call = active else {
            if starting { startCancelled = true }
            if let uuid = ringing?.uuid {
                #if targetEnvironment(simulator)
                ringing?.ended = true
                #else
                controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
                #endif
            }
            return
        }
        #if targetEnvironment(simulator)
        finish(call)
        #else
        controller.request(CXTransaction(action: CXEndCallAction(call: call.uuid))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.finish(call) }
        }
        #endif
    }

    func setMuted(_ muted: Bool) {
        guard let call = active else { return }
        #if targetEnvironment(simulator)
        call.setMuted(muted)
        #else
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: call.uuid, muted: muted))) { _ in }
        #endif
    }

    private func adopt(_ call: VoiceCall) {
        active = call
        call.onEnded = { [weak self, weak call] cause in
            guard let self, let call else { return }
            self.ended(call, cause)
        }
    }

    /// The call ended without the user hanging up here: CallKit is told why.
    private func ended(_ call: VoiceCall, _ cause: VoiceCall.EndCause) {
        let reason: CXCallEndedReason
        switch cause {
        case .local:
            return release(call)
        case .unanswered:
            reason = .unanswered
        case let .remote(message):
            reason = .remoteEnded
            if let message { lastError = message }
        case let .failed(message):
            reason = .failed
            lastError = message
        }
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
        release(call)
    }

    /// Hung up (or declined) here.
    private func finish(_ call: VoiceCall) {
        call.hangUp()
        release(call)
    }

    private func release(_ call: VoiceCall) {
        if active === call { active = nil }
        #if targetEnvironment(simulator)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func fail(_ call: VoiceCall, _ error: Error) {
        lastError = "Couldn't start the call: \(error.localizedDescription)"
        finish(call)
    }

    #if targetEnvironment(simulator)
    private func activateSimulatorAudio(for call: VoiceCall) {
        do {
            try CallAudio.configureSession()
            try AVAudioSession.sharedInstance().setActive(true)
            call.audioDidActivate()
        } catch {
            fail(call, error)
        }
    }
    #endif

    private static func handle(title: String) -> CXHandle {
        CXHandle(type: .generic, value: title)
    }

    /// No hold, grouping or DTMF: iOS then offers "End & Accept" for an incoming call instead of
    /// holding this one, which would take its audio away with no way back.
    private static func update(title: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.localizedCallerName = "Hermes · \(title)"
        update.remoteHandle = handle(title: title)
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }
}

extension CallController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            ringing = nil
            if let call = active { finish(call) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            // Only the call this controller is starting; anything else would be left without an owner.
            guard let call = active, call.uuid == action.callUUID else { return action.fail() }
            do {
                try CallAudio.configureSession()
                provider.reportCall(with: action.callUUID, updated: Self.update(title: call.title))
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            let call = active.flatMap { $0.uuid == action.callUUID ? $0 : nil }
            guard call != nil || ringing?.uuid == action.callUUID else { return action.fail() }
            do {
                try CallAudio.configureSession()
            } catch {
                return action.fail()
            }
            if let call { call.answer() } else { ringing?.answered = true }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            if let call = active { call.audioDidActivate() } else { ringing?.audioActive = true }
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            if let call = active { call.audioDidDeactivate() } else { ringing?.audioActive = false }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            if let call = active, call.uuid == action.callUUID {
                finish(call)
            } else if ringing?.uuid == action.callUUID {
                ringing?.ended = true
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            active?.setMuted(action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        action.fail()
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fail()
    }
}
