import AVFoundation

/// User turns from ElevenLabs Scribe realtime: the call's microphone, converted to 16 kHz PCM16, streams to Scribe
/// over a WebSocket opened with a single-use token from the Hermes Voice plugin; Scribe's VAD commits end turns.
/// While paused the stream carries silence (Scribe closes a session that gets no audio for 15 s).
@MainActor
final class ScribeSpeechProvider: SpeechProvider {
    enum Failure: LocalizedError {
        case rejected(String)
        case keepsFailing(String)

        var errorDescription: String? {
            switch self {
            case let .rejected(message): return "ElevenLabs Scribe refused the session: \(message)"
            case let .keepsFailing(message): return "ElevenLabs Scribe keeps failing: \(message)"
            }
        }
    }

    let id = SpeechProviderID.scribe
    let events: AsyncStream<SpeechEvent>
    var hasPartial: Bool { assembler.hasText }
    private let continuation: AsyncStream<SpeechEvent>.Continuation
    private let callID: String
    private let language: String?
    private let silence: TimeInterval
    private let mintToken: () async throws -> String
    private var assembler = ScribeTurnAssembler()
    private let pump = ScribeAudioPump()
    private var input: AudioInputTap?
    private var socket: URLSessionWebSocketTask?
    private var sessionLanguage: String?
    private var paused = false
    /// After a flush or a pause, commits of the words before it are dropped until new speech is heard.
    private var quarantined = false
    private var stopped = false
    private var failures = 0
    private var lastError = ""
    private var reconnectTask: Task<Void, Never>?
    private var ticker: Timer?
    private static let reconnectDelays: [Double] = [0.5, 1, 2, 4, 8]

    /// `language`: ISO 639-1 code, or nil to let Scribe detect it. `mintToken` gets a single-use token per session.
    init(callID: String, language: String?, silence: TimeInterval, mintToken: @escaping () async throws -> String) {
        self.callID = callID
        self.language = language
        self.silence = silence
        self.mintToken = mintToken
        (events, continuation) = AsyncStream.makeStream(of: SpeechEvent.self)
    }

    func start(input: AudioInputTap) async throws {
        self.input = input
        let pump = pump
        input.setSink { buffer in pump.append(buffer) }
        try await open()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func setPaused(_ value: Bool) {
        guard value != paused else { return }
        paused = value
        pump.setPaused(value)
        if value {
            // Whatever was half heard was flushed by the caller, or is dropped now.
            quarantined = true
            if assembler.hasText {
                assembler.reset()
                continuation.yield(.partial(""))
            }
        }
    }

    func flush(_ ending: TurnEnding) -> UserTurn? {
        quarantined = true
        guard let finished = assembler.take(at: Date()) else { return nil }
        continuation.yield(.partial(""))
        return turn(finished, ending: ending)
    }

    func audioRestarted() {
        // The pump makes a new converter when the input format changes.
    }

    func stop() {
        stopped = true
        ticker?.invalidate()
        ticker = nil
        reconnectTask?.cancel()
        input?.setSink(nil)
        input = nil
        pump.attach(nil)
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation.finish()
    }

    // MARK: Session

    private func open() async throws {
        let token = try await mintToken()
        guard !stopped else { return }
        let task = URLSession.shared.webSocketTask(with: Scribe.url(token: token, silence: silence, language: language))
        socket = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.socket === task, !self.stopped else { return }
                switch result {
                case let .success(.string(text)):
                    if let message = ScribeMessage.parse(text) { self.handle(message, on: task) }
                case let .success(.data(data)):
                    if let message = ScribeMessage.parse(String(decoding: data, as: UTF8.self)) { self.handle(message, on: task) }
                case let .failure(error):
                    if self.lastError.isEmpty { self.lastError = error.localizedDescription }
                    return self.sessionEnded()
                @unknown default:
                    break
                }
                if self.socket === task { self.receive(on: task) }
            }
        }
    }

    private func handle(_ message: ScribeMessage, on task: URLSessionWebSocketTask) {
        let now = Date()
        switch message {
        case let .sessionStarted(language):
            failures = 0
            lastError = ""
            sessionLanguage = language
            pump.attach(task)
            continuation.yield(.status(nil))
        case let .partial(text):
            guard !paused else { return }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { quarantined = false }
            assembler.partial(text, at: now)
            continuation.yield(.partial(assembler.text))
        case let .committed(text, language, timestamps):
            guard !paused, !quarantined else { return }
            if let finished = assembler.commit(text, language: language, timestamps: timestamps, at: now) {
                continuation.yield(.partial(""))
                continuation.yield(.turn(turn(finished, ending: .endOfSpeech(detector: "scribe_vad", detail: silence))))
            } else {
                continuation.yield(.partial(assembler.text))
            }
        case let .error(kind, text):
            lastError = text.isEmpty ? kind : text
            if Scribe.fatalErrors.contains(kind) { fail(.rejected(lastError)) }
        case .warning, .other:
            break
        }
    }

    /// The session closed under the call (time limit, network, idle): send what was heard, then a new session.
    private func sessionEnded() {
        socket = nil
        pump.attach(nil)
        if let finished = assembler.take(at: Date()) {
            continuation.yield(.partial(""))
            continuation.yield(.turn(turn(finished, ending: .dropped)))
        }
        failures += 1
        guard failures <= Self.reconnectDelays.count else { return fail(.keepsFailing(lastError)) }
        if failures > 1 { continuation.yield(.status("Reconnecting to ElevenLabs Scribe…")) }
        let delay = Self.reconnectDelays[failures - 1]
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.stopped else { return }
            do {
                try await self.open()
            } catch {
                self.lastError = error.localizedDescription
                self.sessionEnded()
            }
        }
    }

    private func fail(_ failure: Failure) {
        guard !stopped else { return }
        stopped = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        pump.attach(nil)
        continuation.yield(.failed(failure))
    }

    private func tick() {
        guard !paused, let finished = assembler.tick(at: Date()) else { return }
        continuation.yield(.partial(""))
        continuation.yield(.turn(turn(finished, ending: .endOfSpeech(detector: "scribe_vad", detail: silence))))
    }

    private func turn(_ finished: ScribeTurnAssembler.Finished, ending: TurnEnding) -> UserTurn {
        UserTurn(callID: callID, text: finished.text, ending: ending, provider: .scribe,
                 language: finished.language ?? language ?? sessionLanguage,
                 startedAt: finished.startedAt, endedAt: finished.endedAt)
    }
}

/// The audio-thread half: converts the engine's microphone buffers to 16 kHz mono PCM16 and sends them to the
/// session in 100 ms chunks, silence while paused.
final class ScribeAudioPump: @unchecked Sendable {
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var paused = false
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pending = Data()
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Scribe.sampleRate), channels: 1, interleaved: true)!
    private let chunkBytes = Scribe.sampleRate / 10 * 2

    /// The session audio goes to, or nil (none yet, or it ended): audio is dropped meanwhile.
    func attach(_ socket: URLSessionWebSocketTask?) {
        lock.withLock {
            self.socket = socket
            pending.removeAll()
        }
    }

    func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let socket, var pcm = convert(buffer) else { return }
        if paused { pcm = Data(count: pcm.count) }
        pending.append(pcm)
        while pending.count >= chunkBytes {
            let chunk = pending.prefix(chunkBytes)
            pending.removeFirst(chunkBytes)
            socket.send(.string(Scribe.audioChunk(Data(chunk)))) { _ in }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            inputFormat = buffer.format
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(out.frameLength) * 2)
    }
}
