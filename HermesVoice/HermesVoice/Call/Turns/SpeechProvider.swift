import AVFoundation

/// What a speech provider reports while it listens.
enum SpeechEvent {
    /// The words heard so far in the turn in progress ("" once they became a turn or were dropped).
    case partial(String)
    /// A finished turn.
    case turn(UserTurn)
    /// A notice for the user (reconnecting, using Apple's servers…), or nil when there is nothing to say.
    case status(String?)
    /// The provider can't go on (no token, rejected, kept failing); the call may switch to another one.
    case failed(Error)
}

/// Turns the call's microphone audio into user turns. One provider per call; it only listens while not paused.
@MainActor
protocol SpeechProvider: AnyObject {
    var id: SpeechProviderID { get }
    var events: AsyncStream<SpeechEvent> { get }
    /// Words of the turn in progress have been heard and not yet sent.
    var hasPartial: Bool { get }
    /// Starts listening to `input`. Throws when the provider can't start at all.
    func start(input: AudioInputTap) async throws
    /// While paused (Hermes speaks, the call is muted or not live yet) nothing becomes a turn.
    func setPaused(_ paused: Bool)
    /// Ends the turn in progress now and returns it with `ending` (nil when nothing was heard). It is returned
    /// rather than reported through `events`, so the caller can send it before whatever comes next (a bye).
    func flush(_ ending: TurnEnding) -> UserTurn?
    /// The call's audio engine was rebuilt; the microphone format may have changed.
    func audioRestarted()
    /// Stops for good; `events` finishes.
    func stop()
}

/// The call engine's microphone buffers, passed on to whichever provider listens. `feed` runs on the audio thread.
final class AudioInputTap: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer) -> Void)?

    func setSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {
        lock.withLock { self.sink = sink }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let sink = lock.withLock { self.sink }
        sink?(buffer)
    }
}
