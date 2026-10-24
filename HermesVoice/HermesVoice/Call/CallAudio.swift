import AVFoundation

/// One voice-processing AVAudioEngine for the call: echo-cancelled microphone input, and a player for
/// Hermes' speech (16-bit PCM from ElevenLabs, via the Hermes Voice server).
///
/// iOS stops the engine underneath the call on a route change (AirPods, a car), an interruption or a
/// media-services reset. Each time the graph is rebuilt on a fresh engine against the new hardware
/// format; speech queued on the old one is dropped and its played-back callbacks complete at once.
@MainActor
final class CallAudio {
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
    private var format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var onInput: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// CallKit deactivated the session; only the next `start` brings the engine back.
    private var suspended = false
    /// An interruption is in progress.
    private var interrupted = false
    private var engineObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var rebuildTask: Task<Void, Never>?
    /// Played-back callbacks still waiting, by marker number.
    private var markers: [UInt64: () -> Void] = [:]
    private var nextMarker: UInt64 = 0
    /// When everything scheduled so far should have finished playing.
    private var queuedUntil: Date?
    /// Slack past the scheduled audio before a played-back callback is forced.
    private let drainGrace: TimeInterval = 10

    private var wantsAudio: Bool { onInput != nil && !suspended && !interrupted }

    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // No .defaultToSpeaker: with it, clearing the speaker override goes back to the loudspeaker,
        // so the call could never move to the earpiece. VoiceCall puts the call on the speaker instead.
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

    /// Starts the engine, or restarts it after CallKit took the audio away. `onInput` gets microphone
    /// buffers on the audio thread. Failures are reported through `onEvent`.
    func start(onInput: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onInput = onInput
        suspended = false
        interrupted = false
        observeSession()
        guard engine?.isRunning != true else { return }
        rebuild(fatal: true)
    }

    /// CallKit deactivated the audio session: drop the engine until the next `start`.
    func suspend() {
        suspended = true
        cancelRebuild()
        tearDownEngine()
    }

    func stop() {
        onInput = nil
        cancelRebuild()
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        tearDownEngine()
    }

    func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != format.sampleRate,
              let next = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return }
        format = next
        guard let engine, let player else { return }
        // Reconnecting drops what the player holds in the old format.
        flush()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        play(player)
    }

    /// Queues little-endian Int16 samples. Dropped while the engine is down.
    func enqueue(pcm16 data: Data) {
        guard let engine, let player, engine.isRunning else { return recoverIfStopped() }
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames { out[index] = Float(Int16(littleEndian: samples[index])) / 32768 }
        }
        let now = Date()
        queuedUntil = max(queuedUntil ?? now, now).addingTimeInterval(Double(frames) / format.sampleRate)
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { play(player) }
    }

    /// Calls `done` on the main actor once everything queued so far has been heard, or dropped
    /// (flush, engine restart, stop). If playback stalls, the queue is dropped after its length plus a grace.
    func whenPlayedBack(_ done: @escaping () -> Void) {
        guard let engine, let player, engine.isRunning,
              let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else { return done() }
        marker.frameLength = 1
        marker.floatChannelData?[0][0] = 0
        nextMarker &+= 1
        let id = nextMarker
        markers[id] = done
        player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.completeMarker(id) }
        }
        if !player.isPlaying { play(player) }
        let wait = max(0, (queuedUntil ?? Date()).timeIntervalSinceNow) + drainGrace
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, self.markers[id] != nil else { return }
            // Playback never finished (the engine died without telling us): drop the queue.
            self.flush()
        }
    }

    /// Drops anything still queued (the speech was cancelled, or the link went away) and completes
    /// every pending played-back callback.
    func flush() {
        queuedUntil = nil
        if let engine, let player, engine.isRunning {
            player.stop()
            play(player)
        }
        completeMarkers()
    }

    // MARK: Engine

    /// Tears down the old engine and starts a fresh one, retrying while the input reports no format
    /// (common in the middle of a route switch). `fatal`: a final failure ends the call.
    private func rebuild(fatal: Bool, attempt: Int = 0) {
        cancelRebuild()
        guard wantsAudio else { return }
        tearDownEngine()
        do {
            try buildEngine()
            onEvent?(.running)
        } catch {
            let delays: [Double] = [0.2, 0.4, 0.8, 1.6]
            guard attempt < delays.count else {
                if fatal { onEvent?(.failed(error)) } else { onEvent?(.interrupted) }
                return
            }
            rebuildTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delays[attempt] * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.rebuild(fatal: fatal, attempt: attempt + 1)
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
    }

    /// Drops the engine and everything queued on it; pending played-back callbacks complete.
    private func tearDownEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            if engine.isRunning { player?.stop() }
            if Self.usesMicrophone { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        engine = nil
        player = nil
        queuedUntil = nil
        completeMarkers()
    }

    /// AVAudioPlayerNode.play() raises an exception when the engine isn't running.
    private func play(_ player: AVAudioPlayerNode) {
        guard engine?.isRunning == true else { return }
        if #available(iOS 27.0, *) {
            try? player.playAudio()
        } else {
            player.play()
        }
    }

    /// The engine stopped without a notification reaching us yet: rebuild it.
    private func recoverIfStopped() {
        guard wantsAudio, rebuildTask == nil, engine?.isRunning != true else { return }
        rebuild(fatal: true)
    }

    private func completeMarker(_ id: UInt64) {
        markers.removeValue(forKey: id)?()
    }

    private func completeMarkers() {
        let pending = markers.sorted { $0.key < $1.key }.map(\.value)
        markers.removeAll()
        pending.forEach { $0() }
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
        rebuild(fatal: true)
    }

    private func interruption(began: Bool) {
        guard onInput != nil, !suspended else { return }
        if began {
            interrupted = true
            cancelRebuild()
            tearDownEngine()
            onEvent?(.interrupted)
        } else if interrupted {
            interrupted = false
            // Under CallKit the session may come back only with the next activation; stay down until then.
            rebuild(fatal: false)
        }
    }

    /// Every audio object is invalid after a reset: re-apply the session policy and build anew.
    private func mediaServicesReset() {
        guard onInput != nil, !suspended else { return }
        interrupted = false
        cancelRebuild()
        tearDownEngine()
        try? Self.configureSession()
        rebuild(fatal: true)
    }

    private func routeChanged() {
        guard onInput != nil else { return }
        onEvent?(.routeChanged)
        // Belt and braces next to the engine's own notification.
        recoverIfStopped()
    }
}

/// The input reported no usable format (sample rate or channel count 0), usually mid route switch.
private struct AudioUnavailable: LocalizedError {
    var errorDescription: String? { "The microphone is unavailable." }
}
