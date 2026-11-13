import AVFoundation
import os

private let audioLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesVoice", category: "CallAudio")

/// The call's audio as VoiceCall uses it: the microphone tap, and playback of Hermes' speech with a callback once
/// it has been heard. `CallAudio` in the app; tests script it.
@MainActor
protocol CallAudioPlayback: AnyObject {
    var onEvent: ((CallAudio.Event) -> Void)? { get set }
    func start(onInput: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func suspend()
    func stop()
    func setSampleRate(_ rate: Double)
    /// What is queued from here on is the line `id` (the plugin's utterance id): its playback facts are kept.
    func beginLine(_ id: String)
    /// Queues little-endian Int16 samples; false when they were dropped (the engine is down and not coming back).
    @discardableResult func enqueue(pcm16 data: Data) -> Bool
    /// Calls `done` once everything queued so far has played. `heard` is false when it didn't all reach the
    /// speaker: dropped while the engine was down, or flushed, or lost with the engine.
    func whenPlayedBack(_ done: @escaping (_ heard: Bool) -> Void)
    func flush()
    /// What happened to the line on this phone, as of now; its books are closed. Nil for a line nothing is known of.
    func takeFacts(for line: String) -> PlaybackFacts?
}

/// One voice-processing AVAudioEngine for the call: echo-cancelled microphone input, and a player for
/// Hermes' speech (16-bit PCM from ElevenLabs, via the Hermes Voice plugin).
///
/// iOS stops the engine underneath the call on a route change (AirPods, a car), an interruption or a
/// media-services reset. Each time the graph is rebuilt on a fresh engine against the new hardware format. Speech
/// that had not played yet is kept and scheduled again on the fresh engine (`SpeechQueue`), so the rest of a line
/// survives the Speaker button or AirPods connecting; only when the audio is taken away (an interruption, CallKit
/// deactivating the session) is it dropped, and its played-back callbacks complete as not heard. Rebuilds are
/// bounded (`RebuildBudget`), so a loop of configuration changes can't spin the engine.
@MainActor
final class CallAudio: CallAudioPlayback {
    enum Event {
        /// The engine (re)started; the microphone format may have changed.
        case running
        /// The system took the audio away (an interruption); it comes back on its own or with the next activation.
        case interrupted
        /// The output route changed (speaker, receiver, headset).
        case routeChanged
        /// The engine stopped and couldn't be restarted.
        case failed(Error)
    }

    var onEvent: ((Event) -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    /// Hermes' speech: queued, levelled, accounted for, and carried over a rebuild.
    private let speech = SpeechQueue()
    private var format: AVAudioFormat { speech.format }
    /// Engine rebuilds on this call (not its first start), and whether the engine ever ran.
    private var rebuilds = RebuildBudget()
    private var everBuilt = false
    private var onInput: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// CallKit deactivated the session; only the next `start` brings the engine back.
    private var suspended = false
    /// An interruption is in progress.
    private var interrupted = false
    private var engineObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var rebuildTask: Task<Void, Never>?

    private var wantsAudio: Bool { onInput != nil && !suspended && !interrupted }

    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // No .defaultToSpeaker: a call starts on the earpiece (or a headset) like a phone call, and with it clearing
        // the speaker override would go back to the loudspeaker, so the call could never move to the earpiece.
        if usesMicrophone {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setPreferredIOBufferDuration(0.02)
    }

    static var outputIsSpeaker: Bool { outputs(contain: .builtInSpeaker) }
    static var outputIsReceiver: Bool { outputs(contain: .builtInReceiver) }

    /// Moves the call to the loudspeaker, or back to the default route (the earpiece, or a connected headset).
    static func setSpeaker(_ on: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    private static func outputs(contain port: AVAudioSession.Port) -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == port }
    }

    /// Where the call's audio comes out now.
    static var outputRoute: AudioRoute {
        AVAudioSession.sharedInstance().currentRoute.outputs.first.map { AudioRoute(port: $0.portType.rawValue) } ?? .other
    }

    /// Starts the engine, or restarts it after CallKit took the audio away. `onInput` gets microphone
    /// buffers on the audio thread. Failures are reported through `onEvent`.
    func start(onInput: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onInput = onInput
        suspended = false
        interrupted = false
        observeSession()
        guard engine?.isRunning != true else { return }
        rebuild(fatal: true, why: "start")
    }

    /// CallKit deactivated the audio session: drop the engine until the next `start`.
    func suspend() {
        suspended = true
        cancelRebuild()
        tearDownEngine(keepingSpeech: false)
    }

    func stop() {
        onInput = nil
        cancelRebuild()
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        tearDownEngine(keepingSpeech: false)
    }

    func setSampleRate(_ rate: Double) {
        // A new rate drops what is queued in the old format.
        guard speech.setSampleRate(rate), let engine, let player else { return }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        play(player)
    }

    func beginLine(_ id: String) {
        speech.beginLine(id)
    }

    /// Queues little-endian Int16 samples. While the engine is being rebuilt they wait for the fresh one; while
    /// it is down for longer (before CallKit activated the audio, or while iOS has it) they are dropped, which
    /// the next played-back marker reports.
    @discardableResult
    func enqueue(pcm16 data: Data) -> Bool {
        if engine?.isRunning != true { recoverIfStopped() }
        speech.holds = awaitingEngine
        return speech.enqueue(pcm16: data)
    }

    /// Calls `done` on the main actor once everything queued so far has been heard (`true`), or dropped
    /// (`false`: flush, stop, the audio taken away, or audio lost before it). If playback stalls, the queue is
    /// dropped after its length plus a grace.
    func whenPlayedBack(_ done: @escaping (_ heard: Bool) -> Void) {
        if engine?.isRunning != true { recoverIfStopped() }
        speech.holds = awaitingEngine
        speech.whenPlayedBack(done)
    }

    /// Drops anything still queued (the speech was cancelled, or the link went away) and completes
    /// every pending played-back callback, as not heard. What is queued next starts clean.
    func flush() {
        speech.flush()
    }

    func takeFacts(for line: String) -> PlaybackFacts? {
        guard var facts = speech.takeFacts(for: line) else { return nil }
        facts.route = Self.outputRoute
        facts.volume = Double(AVAudioSession.sharedInstance().outputVolume)
        return facts
    }

    // MARK: Engine

    /// The engine is down, and a rebuild that will bring it back is under way: speech waits for it.
    private var awaitingEngine: Bool { wantsAudio && engine?.isRunning != true && rebuildTask != nil }

    /// Tears down the old engine and starts a fresh one, retrying while the input reports no format
    /// (common in the middle of a route switch). Speech that had not played is kept for the fresh engine.
    /// `fatal`: a final failure ends the call. Every rebuild after the call's first start is counted and logged,
    /// and too many of them wait or, in the end, fail the call (`RebuildBudget`).
    private func rebuild(fatal: Bool, attempt: Int = 0, why: String) {
        cancelRebuild()
        guard wantsAudio else { return }
        tearDownEngine(keepingSpeech: true)
        if everBuilt, attempt == 0 {
            switch rebuilds.next(at: ProcessInfo.processInfo.systemUptime) {
            case .now:
                audioLog.notice("call audio: rebuilding the engine (\(why, privacy: .public)), rebuild \(self.rebuilds.count) of this call")
            case let .after(delay):
                audioLog.error("call audio: too many engine rebuilds; the next one (\(why, privacy: .public)) waits \(delay, format: .fixed(precision: 1)) s")
                rebuildTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    self.rebuild(fatal: fatal, why: why)
                }
                return
            case .never:
                audioLog.error("call audio: \(RebuildBudget.perCall) engine rebuilds on one call; giving up")
                speech.detach(keeping: false)
                onEvent?(.failed(AudioKeepsRestarting()))
                return
            }
        }
        do {
            try buildEngine()
            everBuilt = true
            onEvent?(.running)
        } catch {
            let delays: [Double] = [0.2, 0.4, 0.8, 1.6]
            guard attempt < delays.count else {
                // No engine is coming for what was kept.
                speech.detach(keeping: false)
                if fatal { onEvent?(.failed(error)) } else { onEvent?(.interrupted) }
                return
            }
            rebuildTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delays[attempt] * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.rebuild(fatal: fatal, attempt: attempt + 1, why: why)
            }
        }
    }

    private func cancelRebuild() {
        rebuildTask?.cancel()
        rebuildTask = nil
    }

    /// The Simulator's audio server deadlocks initializing microphone input ("RPC timeout. Apparently
    /// deadlocked") and CoreAudio aborts the app, so there the call is output-only: Hermes can be heard,
    /// nothing is listened to.
    static var usesMicrophone: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private func buildEngine() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if Self.usesMicrophone {
            let input = engine.inputNode
            // Echo cancellation: switches input and output to the voice-processing unit before the graph starts.
            try? input.setVoiceProcessingEnabled(true)
            let hardware = input.inputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw AudioUnavailable() }
            // A tap whose rate disagrees with the hardware raises an exception: tap at the hardware format then.
            let output = input.outputFormat(forBus: 0)
            let tapFormat = output.sampleRate > 0 && output.channelCount > 0 && abs(output.sampleRate - hardware.sampleRate) < 0.5 ? output : hardware
            let onInput = onInput
            input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { @Sendable buffer, _ in
                onInput?(buffer)
            }
        }
        let id = ObjectIdentifier(engine)
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            // Posted on an internal queue; the engine must not be torn down there.
            Task { @MainActor [weak self] in self?.configurationChanged(engine: id) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
            engineObserver = nil
            if Self.usesMicrophone { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            throw error
        }
        self.engine = engine
        self.player = player
        play(player)
        // Speech kept from the engine before goes onto this one.
        speech.attach(NodePlayer(node: player, engine: engine))
    }

    /// Drops the engine. `keepingSpeech`: a fresh engine follows (a rebuild), so the speech that had not played
    /// waits for it. Else everything queued is dropped, and pending played-back callbacks complete, as not heard.
    private func tearDownEngine(keepingSpeech: Bool) {
        // Before the player stops: its stop calls every queued buffer's callback, which must not count as played.
        speech.detach(keeping: keepingSpeech)
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            if engine.isRunning { player?.stop() }
            if Self.usesMicrophone { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        engine = nil
        player = nil
    }

    /// AVAudioPlayerNode.play() raises an exception when the engine isn't running.
    private func play(_ player: AVAudioPlayerNode) {
        guard engine?.isRunning == true else { return }
        NodePlayer.play(player)
    }

    /// The engine stopped without a notification reaching us yet: rebuild it.
    private func recoverIfStopped() {
        guard wantsAudio, rebuildTask == nil, engine?.isRunning != true else { return }
        rebuild(fatal: true, why: "engine stopped")
    }

    // MARK: Notifications

    private func observeSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
                Task { @MainActor [weak self] in self?.interruption(began: began) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.mediaServicesReset() }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.routeChanged() }
            },
        ]
    }

    /// The hardware format changed (speaker to AirPods and back) and the engine stopped itself.
    private func configurationChanged(engine id: ObjectIdentifier) {
        guard let engine, ObjectIdentifier(engine) == id, !engine.isRunning, rebuildTask == nil else { return }
        rebuild(fatal: true, why: "configuration change")
    }

    private func interruption(began: Bool) {
        guard onInput != nil, !suspended else { return }
        if began {
            interrupted = true
            cancelRebuild()
            // Nobody knows when the audio comes back: what was queued would be stale by then.
            tearDownEngine(keepingSpeech: false)
            onEvent?(.interrupted)
        } else if interrupted {
            interrupted = false
            // Under CallKit the session may come back only with the next activation; stay down until then.
            rebuild(fatal: false, why: "interruption ended")
        }
    }

    /// Every audio object is invalid after a reset: re-apply the session policy and build anew.
    private func mediaServicesReset() {
        guard onInput != nil, !suspended else { return }
        interrupted = false
        cancelRebuild()
        tearDownEngine(keepingSpeech: true)
        try? Self.configureSession()
        rebuild(fatal: true, why: "media services reset")
    }

    private func routeChanged() {
        guard onInput != nil else { return }
        speech.routeChanged()
        onEvent?(.routeChanged)
        // Belt and braces next to the engine's own notification.
        recoverIfStopped()
    }
}

/// `AVAudioPlayerNode` as the speech queue's player.
@MainActor
private final class NodePlayer: SpeechPlayer {
    private let node: AVAudioPlayerNode
    private weak var engine: AVAudioEngine?

    init(node: AVAudioPlayerNode, engine: AVAudioEngine) {
        self.node = node
        self.engine = engine
    }

    func schedule(_ buffer: AVAudioPCMBuffer, played: (@Sendable () -> Void)?) {
        guard engine?.isRunning == true else { return }
        if let played {
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
        } else {
            node.scheduleBuffer(buffer, completionHandler: nil)
        }
        if !node.isPlaying { Self.play(node) }
    }

    func reset() {
        guard engine?.isRunning == true else { return }
        node.stop()
        Self.play(node)
    }

    static func play(_ node: AVAudioPlayerNode) {
        if #available(iOS 27.0, *) {
            try? node.playAudio()
        } else {
            node.play()
        }
    }
}

/// The input reported no usable format (sample rate or channel count 0), usually mid route switch.
private struct AudioUnavailable: LocalizedError {
    var errorDescription: String? { "The microphone is unavailable." }
}

/// The engine was rebuilt more often than a call gets (`RebuildBudget.perCall`).
private struct AudioKeepsRestarting: LocalizedError {
    var errorDescription: String? { "the audio kept restarting." }
}
