import AVFoundation
import CallKit

/// CallKit for in-chat voice calls: the call shows in the Dynamic Island / Lock Screen, keeps running
/// in the background, and gets the system's call audio session.
@MainActor
final class CallController: NSObject, ObservableObject {
    @Published private(set) var active: VoiceCall?
    /// A call is being set up (permissions, voice server check) and isn't `active` yet.
    @Published private(set) var starting = false
    @Published var lastError: String?

    private let provider: CXProvider
    private let controller = CXCallController()
    /// `end` was asked for while a call was still starting.
    private var startCancelled = false

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

    func start(_ call: VoiceCall) async {
        // Set before the first await, so a second tap meanwhile can't start another call.
        guard active == nil, !starting else { return }
        starting = true
        startCancelled = false
        defer { starting = false }
        guard await SpeechListener.requestPermissions() else {
            lastError = "Hermes Voice needs the microphone and speech recognition. Allow them in Settings."
            return
        }
        guard let base = call.settings.voiceBase, !call.settings.voiceToken.isEmpty else {
            lastError = "Add the Hermes Voice server address and token in Settings first."
            return
        }
        // A wrong address or token fails here, before CallKit shows a call.
        do {
            try await VoiceLink.preflight(base: base, token: call.settings.voiceToken)
        } catch {
            if !startCancelled { lastError = error.localizedDescription }
            return
        }
        guard active == nil, !startCancelled else { return }
        active = call
        call.onGiveUp = { [weak self] reason in
            self?.lastError = reason
            self?.end()
        }
        #if targetEnvironment(simulator)
        // CallKit doesn't hand out audio sessions in the Simulator; run the call without it.
        do {
            try CallAudio.configureSession()
            try AVAudioSession.sharedInstance().setActive(true)
            call.audioDidActivate()
        } catch {
            fail(call, error)
        }
        #else
        call.onConnected = { [weak self, uuid = call.uuid] in
            self?.provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
        let action = CXStartCallAction(call: call.uuid, handle: Self.handle(for: call))
        action.contactIdentifier = "Hermes"
        do {
            try await controller.request(CXTransaction(action: action))
            provider.reportCall(with: call.uuid, updated: Self.update(for: call))
        } catch {
            fail(call, error)
        }
        #endif
    }

    /// Hangs up. `notifyHermes: false` skips the "[Voice call ended]" message (signing out).
    func end(notifyHermes: Bool = true) {
        guard let call = active else {
            if starting { startCancelled = true }
            return
        }
        if !notifyHermes { call.notifiesHermes = false }
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

    private func finish(_ call: VoiceCall, reason: String? = nil) {
        call.stop(reason: reason)
        if active === call { active = nil }
        #if targetEnvironment(simulator)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func fail(_ call: VoiceCall, _ error: Error) {
        lastError = "Couldn't start the call: \(error.localizedDescription)"
        finish(call, reason: lastError)
    }

    private static func handle(for call: VoiceCall) -> CXHandle {
        CXHandle(type: .generic, value: call.chat.title)
    }

    /// No hold, grouping or DTMF: iOS then offers "End & Accept" for an incoming call instead of
    /// holding this one, which would take its audio away with no way back.
    private static func update(for call: VoiceCall) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.localizedCallerName = "Hermes · \(call.chat.title)"
        update.remoteHandle = handle(for: call)
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
            if let call = active { finish(call) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            // Only the call this controller is starting; anything else would be left without an owner.
            guard let call = active, call.uuid == action.callUUID else { return action.fail() }
            do {
                try CallAudio.configureSession()
                provider.reportCall(with: action.callUUID, updated: Self.update(for: call))
                provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            active?.audioDidActivate()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            active?.audioDidDeactivate()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            if let call = active, call.uuid == action.callUUID { finish(call) }
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
