import Foundation

/// ElevenLabs Scribe realtime speech to text: the socket URL, its messages, and how commits become turns.
enum Scribe {
    static let model = "scribe_v2_realtime"
    static let sampleRate = 16_000

    /// `wss://api.elevenlabs.io/v1/speech-to-text/realtime?…` for a single-use `token`. `language` nil lets Scribe detect it.
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

/// Builds turns from Scribe's partials and commits. A VAD commit ends the turn. Scribe also commits by itself
/// when a segment runs long (about 36 s) while the user is still talking: a commit after a segment that long is held
/// and merged with what follows, and only ends the turn when no more speech comes within `holdFor`.
struct ScribeTurnAssembler {
    /// A segment at least this long was most likely cut by Scribe's own limit, not by a pause.
    var autoCommitAfter: TimeInterval = 30
    /// How long a held auto-commit waits for the speech to go on.
    var holdFor: TimeInterval = 2.5

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
    private var heldSince: Date?
    private var language: String?
    /// The last commit, so the `…_with_timestamps` copy of it isn't counted twice.
    private var lastCommit: (text: String, at: Date)?

    /// The words of the turn in progress: merged segments, then the partial.
    var text: String {
        (segments + [partial]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    var hasText: Bool { !text.isEmpty }

    var isHolding: Bool { heldSince != nil }

    mutating func partial(_ text: String, at now: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = trimmed
        guard !trimmed.isEmpty else { return }
        if startedAt == nil { startedAt = now }
        if segmentStartedAt == nil { segmentStartedAt = now }
        // The user went on talking after an auto-commit: it is part of this turn.
        heldSince = nil
    }

    /// A commit; returns the finished turn unless the commit is held (or was empty, or a repeat).
    mutating func commit(_ text: String, language: String?, timestamps: Bool, at now: Date) -> Finished? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if timestamps, let lastCommit, lastCommit.text == trimmed, now.timeIntervalSince(lastCommit.at) < 3 { return nil }
        lastCommit = (trimmed, now)
        if let language { self.language = language }
        partial = ""
        // A commit with no partial before it (since the last one) is a segment of no length.
        let segmentStart = segmentStartedAt ?? heldSince ?? now
        segmentStartedAt = nil
        if !trimmed.isEmpty {
            if startedAt == nil { startedAt = now }
            segments.append(trimmed)
        }
        guard !segments.isEmpty else { return nil }
        if !trimmed.isEmpty, now.timeIntervalSince(segmentStart) >= autoCommitAfter {
            heldSince = now
            return nil
        }
        return finish(at: now)
    }

    /// Ends a held auto-commit once no more speech came for `holdFor`.
    mutating func tick(at now: Date) -> Finished? {
        guard let heldSince, partial.isEmpty, now.timeIntervalSince(heldSince) >= holdFor else { return nil }
        return finish(at: now)
    }

    /// Ends the turn in progress now (cut off, hung up, dropped…); nil when nothing was heard.
    mutating func take(at now: Date) -> Finished? {
        guard hasText else {
            reset()
            return nil
        }
        return finish(at: now)
    }

    mutating func reset() {
        segments = []
        partial = ""
        startedAt = nil
        segmentStartedAt = nil
        heldSince = nil
    }

    private mutating func finish(at now: Date) -> Finished? {
        let text = self.text
        let finished = Finished(text: text, startedAt: startedAt ?? now, endedAt: now, language: language,
                                segments: segments.count + (partial.isEmpty ? 0 : 1))
        reset()
        return text.isEmpty ? nil : finished
    }
}
