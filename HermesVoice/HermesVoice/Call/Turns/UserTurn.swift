import Foundation

/// Which speech recognizer heard a turn.
enum SpeechProviderID: String, Codable, CaseIterable, Identifiable {
    /// Apple speech recognition, on the iPhone when the language has an on-device model.
    case apple
    /// ElevenLabs Scribe realtime, with a single-use token the Hermes Voice plugin mints.
    case scribe

    var id: String { rawValue }

    var name: String {
        switch self {
        case .apple: return "Apple"
        case .scribe: return "ElevenLabs Scribe"
        }
    }
}

/// How a user turn ended. The plugin tells Hermes when a turn didn't end on its own (cut off, hung up…).
enum TurnEnding: Equatable {
    /// The recognizer decided the user stopped talking: `detector` names how ("apple_silence", "apple_final",
    /// "scribe_vad"), `detail` is its silence threshold in seconds, when it has one.
    case endOfSpeech(detector: String, detail: Double?)
    /// Hermes started speaking while the user was still talking; what was heard so far was sent.
    case cutOff
    /// The user hung up mid-sentence; what was heard so far was sent.
    case hangUp
    /// The user muted the call mid-sentence.
    case muted
    /// The recognizer's connection dropped mid-sentence.
    case dropped
    /// Recognition failed mid-sentence; the words heard before the error were sent.
    case providerError(String)

    var kind: String {
        switch self {
        case .endOfSpeech: return "end_of_speech"
        case .cutOff: return "cut_off"
        case .hangUp: return "hang_up"
        case .muted: return "muted"
        case .dropped: return "dropped"
        case .providerError: return "provider_error"
        }
    }
}

extension TurnEnding: Codable {
    private enum Keys: String, CodingKey { case kind, detector, detail, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "end_of_speech":
            self = .endOfSpeech(detector: try container.decodeIfPresent(String.self, forKey: .detector) ?? "unknown",
                                detail: try container.decodeIfPresent(Double.self, forKey: .detail))
        case "cut_off": self = .cutOff
        case "hang_up": self = .hangUp
        case "muted": self = .muted
        case "dropped": self = .dropped
        case "provider_error":
            self = .providerError(try container.decodeIfPresent(String.self, forKey: .error) ?? "")
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown turn ending \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .endOfSpeech(detector, detail):
            try container.encode(detector, forKey: .detector)
            try container.encodeIfPresent(detail, forKey: .detail)
        case let .providerError(error):
            try container.encode(error, forKey: .error)
        case .cutOff, .hangUp, .muted, .dropped:
            break
        }
    }
}

/// What the user said in one turn of a call, and how the turn ended. The phone sends it to the Hermes Voice
/// plugin as `{type: "user_turn", …}`; the plugin hands it to a waiting `start_call` or injects it into the session.
struct UserTurn: Equatable {
    let callID: String
    let text: String
    let ending: TurnEnding
    let provider: SpeechProviderID
    /// The language heard or asked for (BCP-47 or ISO 639), when known.
    let language: String?
    /// When the first words of the turn were heard, and when the turn ended.
    let startedAt: Date
    let endedAt: Date
}

extension UserTurn: Codable {
    private enum Keys: String, CodingKey {
        case type, text, ending, provider, language
        case callID = "call_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        callID = try container.decode(String.self, forKey: .callID)
        text = try container.decode(String.self, forKey: .text)
        ending = try container.decode(TurnEnding.self, forKey: .ending)
        provider = try container.decode(SpeechProviderID.self, forKey: .provider)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        startedAt = try Self.date(container, .startedAt)
        endedAt = try Self.date(container, .endedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode("user_turn", forKey: .type)
        try container.encode(callID, forKey: .callID)
        try container.encode(text, forKey: .text)
        try container.encode(ending, forKey: .ending)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(ISO8601.string(startedAt), forKey: .startedAt)
        try container.encode(ISO8601.string(endedAt), forKey: .endedAt)
    }

    private static func date(_ container: KeyedDecodingContainer<Keys>, _ key: Keys) throws -> Date {
        let text = try container.decode(String.self, forKey: key)
        guard let date = ISO8601.date(text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not an ISO-8601 date: \(text)")
        }
        return date
    }
}

/// ISO-8601 timestamps in UTC with milliseconds ("2026-10-25T09:41:07.250Z"); reading also takes them without.
enum ISO8601 {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()

    static func string(_ date: Date) -> String {
        lock.withLock { fractional.string(from: date) }
    }

    static func date(_ text: String) -> Date? {
        lock.withLock { fractional.date(from: text) ?? whole.date(from: text) }
    }
}
