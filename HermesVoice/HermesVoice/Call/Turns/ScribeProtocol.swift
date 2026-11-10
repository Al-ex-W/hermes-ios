import Foundation

/// ElevenLabs Scribe realtime speech to text: the socket URL, its messages, and how commits become turns.
enum Scribe {
    static let model = "scribe_v2_realtime"
    static let sampleRate = 16_000
    /// The longest silence Scribe's own VAD is asked to wait before it commits a segment. The API takes 0.192 to
    /// 3.0 s for `vad_silence_threshold_secs` (ElevenLabs' guide "Transcripts and commit strategies"; what a larger
    /// value does isn't documented), less than the Calls setting can ask for. So Scribe commits after a short
    /// silence, and ScribeTurnAssembler holds the commits on the phone until the setting's whole pause has passed.
    /// Shorter than the API's limit, so the final text of a segment arrives sooner (Send now sends it) and words
    /// that were already sent or dropped leave Scribe's open segment sooner.
    static let maxVADSilence: TimeInterval = 1.5

    /// The `vad_silence_threshold_secs` for turns that end after `pause` seconds of silence.
    static func vadSilence(pause: TimeInterval) -> TimeInterval {
        min(max(pause, 0.2), maxVADSilence)
    }

    /// `wss://api.elevenlabs.io/v1/speech-to-text/realtime?…` for a single-use `token`. `silence` is Scribe's own
    /// VAD threshold (see `vadSilence`). `language` nil lets Scribe detect it.
    static func url(token: String, silence: TimeInterval, language: String?) -> URL {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: String(format: "%.2f", silence)),
        ]
        if let language { items.append(URLQueryItem(name: "language_code", value: language)) }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url!
    }

    /// One `input_audio_chunk` frame: 16 kHz mono PCM16LE, base64.
    static func audioChunk(_ pcm: Data) -> String {
        "{\"message_type\":\"input_audio_chunk\",\"audio_base_64\":\"\(pcm.base64EncodedString())\",\"commit\":false,\"sample_rate\":\(sampleRate)}"
    }

    /// Errors after which another session won't help (a bad or used-up key, terms not accepted, a bad request).
    static let fatalErrors: Set<String> = ["auth_error", "quota_exceeded", "unaccepted_terms", "invalid_request"]
}

/// A Scribe server message.
enum ScribeMessage: Equatable {
    case sessionStarted(language: String?)
    /// Interim text of the segment being spoken; it may still change.
    case partial(String)
    /// The final text of a segment. `timestamps`: the `…_with_timestamps` variant, which may repeat a plain commit.
    case committed(text: String, language: String?, timestamps: Bool)
    case warning(String)
    /// `kind` is the message_type (auth_error, quota_exceeded, rate_limited, …).
    case error(kind: String, message: String)
    case other(String)

    static func parse(_ text: String) -> ScribeMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON,
              let type = object["message_type"] as? String else { return nil }
        let text = object["text"] as? String ?? ""
        let language = (object["language_code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch type {
        case "session_started":
            let config = object["config"] as? JSON
            return .sessionStarted(language: (config?["language_code"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "partial_transcript":
            return .partial(text)
        case "committed_transcript":
            return .committed(text: text, language: language, timestamps: false)
        case "committed_transcript_with_timestamps":
            return .committed(text: text, language: language, timestamps: true)
        case "warning":
            return .warning(object["warning"] as? String ?? "")
        default:
            if let error = object["error"] as? String { return .error(kind: type, message: error) }
            return .other(type)
        }
    }
}

/// Builds turns from Scribe's partials and commits. Scribe's VAD commits a segment after `vadSilence` of silence,
/// which may be shorter than the `pause` that ends a turn: a commit is held, and merged with what the user says
/// next, until `pause` has passed with no more speech. Scribe also commits by itself when a segment runs long
/// (about 36 s) while the user is still talking: a commit after a segment that long is held the same way, for a
/// whole pause.
///
/// When a turn is taken or dropped while Scribe's segment is still open (Send now, Hermes cutting in, mute), Scribe
/// goes on with that segment: what it says of the words already taken is skipped, and its commit is dropped unless
/// new words were heard first.
struct ScribeTurnAssembler {
    /// Silence that ends the turn (the Calls setting).
    var pause: TimeInterval
    /// The silence Scribe's VAD waited before a commit (`vad_silence_threshold_secs`).
    var vadSilence: TimeInterval
    /// A segment at least this long was most likely cut by Scribe's own limit, not by a pause.
    var autoCommitAfter: TimeInterval = 30
    /// The least time a held auto-commit waits for the speech to go on (the next partial takes a moment).
    var autoCommitHold: TimeInterval = 2.5

    struct Finished: Equatable {
        let text: String
        let startedAt: Date
        let endedAt: Date
        let language: String?
        /// How many commits the turn merged.
        let segments: Int
    }

    private(set) var segments: [String] = []
    private(set) var partial = ""
    private(set) var startedAt: Date?
    private var segmentStartedAt: Date?
    /// When the held commits become a turn, unless the user goes on talking.
    private(set) var heldUntil: Date?
    private var language: String?
    /// The last commit as Scribe sent it, so the `…_with_timestamps` copy of it isn't counted twice.
    private var lastCommit: (text: String, at: Date)?
    /// Words at the start of Scribe's open segment that were already taken or dropped.
    private var skipWords = 0
    /// After a turn was taken or dropped: commits are dropped until new words are heard.
    private var quarantined = false

    /// `vadSilence` nil: what `Scribe.vadSilence` asks Scribe for with this `pause`.
    init(pause: TimeInterval = EndOfSpeech.normal.pause, vadSilence: TimeInterval? = nil) {
        self.pause = pause
        self.vadSilence = vadSilence ?? Scribe.vadSilence(pause: pause)
    }

    /// The words of the turn in progress: merged segments, then the partial.
    var text: String {
        (segments + [partial]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var hasText: Bool { !text.isEmpty }

    var isHolding: Bool { heldUntil != nil }

    mutating func partial(_ text: String, at now: Date) {
        let trimmed = Self.dropWords(skipWords, from: text)
        // Scribe repeating words that were already taken: not new speech.
        if quarantined, trimmed.isEmpty { return }
        partial = trimmed
        guard !trimmed.isEmpty else { return }
        quarantined = false
        if startedAt == nil { startedAt = now }
        if segmentStartedAt == nil { segmentStartedAt = now }
        // The user went on talking: the held commits are part of this turn.
        heldUntil = nil
    }

    /// A commit; returns the finished turn unless the commit is held (or was dropped, empty, or a repeat).
    mutating func commit(_ text: String, language: String?, timestamps: Bool, at now: Date) -> Finished? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if timestamps, let lastCommit, lastCommit.text == raw, now.timeIntervalSince(lastCommit.at) < 3 { return nil }
        lastCommit = (raw, now)
        let trimmed = Self.dropWords(skipWords, from: raw)
        // This commit closes the segment whose first words were taken.
        skipWords = 0
        if quarantined { return nil }
        if let language { self.language = language }
        partial = ""
        // A commit with no partial before it (since the last one) is a segment of no length.
        let segmentStart = segmentStartedAt ?? now
        segmentStartedAt = nil
        if !trimmed.isEmpty {
            if startedAt == nil { startedAt = now }
            segments.append(trimmed)
        }
        guard !segments.isEmpty else { return nil }
        if trimmed.isEmpty {
            // Nothing new was said. If a partial (revised away since) had ended the hold, the silence counts again.
            if heldUntil == nil { heldUntil = now.addingTimeInterval(max(0, pause - vadSilence)) }
        } else if now.timeIntervalSince(segmentStart) >= autoCommitAfter {
            // Cut by Scribe's limit with the user still talking: no silence has passed yet.
            heldUntil = now.addingTimeInterval(max(pause, autoCommitHold))
        } else {
            // Scribe's VAD already waited `vadSilence`; the rest of the pause is waited here.
            heldUntil = now.addingTimeInterval(max(0, pause - vadSilence))
        }
        return tick(at: now)
    }

    /// Ends the held commits as a turn once the pause has passed with no more speech.
    mutating func tick(at now: Date) -> Finished? {
        guard let heldUntil, partial.isEmpty, now >= heldUntil else { return nil }
        let finished = current(at: now)
        reset()
        return finished
    }

    /// Ends the turn in progress now (Send now, cut off, hung up, dropped…); nil when nothing was heard.
    mutating func take(at now: Date) -> Finished? {
        let finished = current(at: now)
        discard()
        return finished
    }

    /// Drops the turn in progress (listening paused). Scribe goes on with its open segment: what it still says of
    /// the words dropped here is skipped.
    mutating func discard() {
        skipWords += Self.words(partial).count
        quarantined = true
        reset()
    }

    /// Scribe committed a segment while nothing was listened to: the words taken or dropped before are behind it.
    mutating func segmentClosed() {
        skipWords = 0
    }

    /// A new Scribe session knows nothing of the segments before it.
    mutating func sessionStarted() {
        skipWords = 0
        quarantined = false
        lastCommit = nil
    }

    private mutating func reset() {
        segments = []
        partial = ""
        startedAt = nil
        segmentStartedAt = nil
        heldUntil = nil
    }

    /// The turn in progress as it would end now; nil when nothing was heard.
    private func current(at now: Date) -> Finished? {
        let text = self.text
        guard !text.isEmpty else { return nil }
        return Finished(text: text, startedAt: startedAt ?? now, endedAt: now, language: language,
                        segments: segments.count + (partial.isEmpty ? 0 : 1))
    }

    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    /// `text`, trimmed, without its first `count` words.
    private static func dropWords(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return words(text).dropFirst(count).joined(separator: " ")
    }
}
