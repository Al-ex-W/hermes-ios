import Foundation

/// How long a pause ends the user's turn. Both speech recognizers honour it; "Send now" on the call screen ends a
/// turn at once, so a long pause doesn't have to be waited out.
enum EndOfSpeech: String, CaseIterable, Identifiable {
    case quick, normal, patient
    case veryPatient = "very_patient"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .quick: return "Quick"
        case .normal: return "Normal"
        case .patient: return "Patient"
        case .veryPatient: return "Very patient"
        }
    }

    /// Seconds of silence that end the turn. Normal outlasts a thinking pause of two to three seconds in the
    /// middle of a sentence (at 1.2 s such a pause sent half sentences to Hermes).
    var pause: TimeInterval {
        switch self {
        case .quick: return 1.5
        case .normal: return 3.5
        case .patient: return 5
        case .veryPatient: return 8
        }
    }

    /// The name with its pause, for Settings: "Normal (3.5 s)".
    func label(locale: Locale = .current) -> String { "\(name) (\(Self.seconds(pause, locale: locale)))" }

    /// "3.5 s", "5 s".
    static func seconds(_ value: TimeInterval, locale: Locale = .current) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) s"
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
