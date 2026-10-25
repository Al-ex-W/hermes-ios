import AVFoundation

/// User turns from Apple speech recognition (SpeechListener): on the iPhone when the language has an
/// on-device model, ended by a pause of `pause` seconds.
@MainActor
final class AppleSpeechProvider: SpeechProvider {
    let id = SpeechProviderID.apple
    let events: AsyncStream<SpeechEvent>
    private(set) var hasPartial = false
    private let continuation: AsyncStream<SpeechEvent>.Continuation
    private let listener: SpeechListener
    private let callID: String
    /// The recognizer's locale as BCP-47 ("sv-SE").
    private let language: String
    private var input: AudioInputTap?

    init(callID: String, localeIdentifier: String?, pause: TimeInterval) {
        self.callID = callID
        (events, continuation) = AsyncStream.makeStream(of: SpeechEvent.self)
        let listener = SpeechListener(localeIdentifier: localeIdentifier, pause: pause)
        self.listener = listener
        language = Locale(identifier: listener.localeIdentifier).identifier(.bcp47)
        listener.onPartial = { [weak self] text in
            self?.hasPartial = !text.isEmpty
            self?.continuation.yield(.partial(text))
        }
        listener.onStatus = { [weak self] note in self?.continuation.yield(.status(note)) }
        listener.onUtterance = { [weak self] utterance in
            guard let self else { return }
            let ending: TurnEnding = utterance.error.map(TurnEnding.providerError)
                ?? .endOfSpeech(detector: utterance.detector, detail: utterance.detector == "apple_silence" ? self.listener.pause : nil)
            self.continuation.yield(.turn(self.turn(utterance, ending: ending)))
        }
    }

    func start(input: AudioInputTap) async throws {
        self.input = input
        let listener = listener
        input.setSink { buffer in listener.append(buffer) }
        listener.start()
    }

    func setPaused(_ paused: Bool) {
        listener.setPaused(paused)
    }

    func flush(_ ending: TurnEnding) -> UserTurn? {
        guard let utterance = listener.takePartial() else { return nil }
        hasPartial = false
        return turn(utterance, ending: ending)
    }

    func audioRestarted() {
        listener.restart()
    }

    func stop() {
        input?.setSink(nil)
        input = nil
        listener.stop()
        continuation.finish()
    }

    private func turn(_ utterance: SpeechListener.Utterance, ending: TurnEnding) -> UserTurn {
        UserTurn(callID: callID, text: utterance.text, ending: ending, provider: .apple, language: language,
                 startedAt: utterance.startedAt, endedAt: utterance.endedAt)
    }
}
