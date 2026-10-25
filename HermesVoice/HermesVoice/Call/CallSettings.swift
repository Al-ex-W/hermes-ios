import Foundation

/// How long a pause ends the user's turn.
enum EndOfSpeech: String, CaseIterable, Identifiable {
    case quick, normal, patient

    var id: String { rawValue }

    var name: String {
        switch self {
        case .quick: return "Quick"
        case .normal: return "Normal"
        case .patient: return "Patient"
        }
    }

    /// Seconds of silence after which Apple speech recognition ends the turn.
    var appleSilence: TimeInterval {
        switch self {
        case .quick: return 0.8
        case .normal: return 1.2
        case .patient: return 2.0
        }
    }

    /// Scribe's `vad_silence_threshold_secs`.
    var scribeSilence: TimeInterval {
        switch self {
        case .quick: return 0.5
        case .normal: return 0.8
        case .patient: return 1.5
        }
    }
}

/// How calls listen: the speech provider, the language spoken, and how long a pause ends a turn. In UserDefaults.
struct CallSettings: Equatable {
    var provider: SpeechProviderID
    /// Speech recognition locale for calls; "" chooses one from the preferred languages (Apple) or detects it (Scribe).
    var speechLocale: String
    var endOfSpeech: EndOfSpeech

    static func load(_ defaults: UserDefaults = .standard) -> CallSettings {
        CallSettings(
            provider: defaults.string(forKey: "callProvider").flatMap(SpeechProviderID.init(rawValue:)) ?? .apple,
            speechLocale: defaults.string(forKey: "speechLocale") ?? "",
            endOfSpeech: defaults.string(forKey: "endOfSpeech").flatMap(EndOfSpeech.init(rawValue:)) ?? .normal
        )
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: "callProvider")
        defaults.set(speechLocale, forKey: "speechLocale")
        defaults.set(endOfSpeech.rawValue, forKey: "endOfSpeech")
    }

    /// The ISO 639-1 code of `speechLocale` ("sv" for "sv-SE"), or nil for automatic.
    var languageCode: String? {
        guard !speechLocale.isEmpty else { return nil }
        return Locale(identifier: speechLocale).language.languageCode?.identifier
    }
}
