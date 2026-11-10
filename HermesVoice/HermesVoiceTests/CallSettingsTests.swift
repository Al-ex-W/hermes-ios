import XCTest
@testable import HermesVoice

/// The Calls settings: how long a pause ends the user's turn, what Settings says about it, and how it is stored.
@MainActor
final class CallSettingsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    private func defaults() throws -> UserDefaults {
        let suite = "CallSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testPauses() {
        XCTAssertEqual(EndOfSpeech.allCases, [.quick, .normal, .patient, .veryPatient])
        XCTAssertEqual(EndOfSpeech.allCases.map(\.pause), [1.5, 3.5, 5, 8])
        // The default outlasts a thinking pause of two to three seconds in the middle of a sentence.
        XCTAssertGreaterThan(EndOfSpeech.normal.pause, 3)
        // Each step is longer than the one before.
        XCTAssertEqual(EndOfSpeech.allCases.map(\.pause), EndOfSpeech.allCases.map(\.pause).sorted())
        XCTAssertEqual(Set(EndOfSpeech.allCases.map(\.pause)).count, EndOfSpeech.allCases.count)
    }

    func testLabelsShowTheSeconds() {
        XCTAssertEqual(EndOfSpeech.allCases.map { $0.label(locale: english) },
                       ["Quick (1.5 s)", "Normal (3.5 s)", "Patient (5 s)", "Very patient (8 s)"])
        XCTAssertEqual(EndOfSpeech.seconds(3.5, locale: Locale(identifier: "sv_SE")), "3,5 s")
    }

    func testListeningFooterSaysThePauseOfEitherRecognizer() {
        for provider in SpeechProviderID.allCases {
            for level in EndOfSpeech.allCases {
                let footer = CallsSettingsView.listeningFooter(
                    CallSettings(provider: provider, speechLocale: "", endOfSpeech: level), locale: english)
                XCTAssertTrue(footer.contains("A pause of \(EndOfSpeech.seconds(level.pause, locale: english)) ends what you say"),
                              "\(provider) \(level): \(footer)")
                XCTAssertTrue(footer.contains("Send now"), footer)
            }
        }
    }

    func testDefaultsToNormal() throws {
        let settings = CallSettings.load(try defaults())
        XCTAssertEqual(settings, CallSettings(provider: .apple, speechLocale: "", endOfSpeech: .normal))
        XCTAssertEqual(settings.endOfSpeech.pause, 3.5)
    }

    func testEveryPauseSettingPersists() throws {
        let defaults = try defaults()
        for level in EndOfSpeech.allCases {
            CallSettings(provider: .scribe, speechLocale: "sv-SE", endOfSpeech: level).save(defaults)
            XCTAssertEqual(CallSettings.load(defaults), CallSettings(provider: .scribe, speechLocale: "sv-SE", endOfSpeech: level))
        }
        XCTAssertEqual(defaults.string(forKey: "endOfSpeech"), "very_patient")
    }

    func testStoredNamesFromBeforeKeepTheirSetting() throws {
        let defaults = try defaults()
        // What the app stored when Normal was 1.2 s: the same setting, with today's pause.
        for (stored, level) in [("quick", EndOfSpeech.quick), ("normal", .normal), ("patient", .patient)] {
            defaults.set(stored, forKey: "endOfSpeech")
            XCTAssertEqual(CallSettings.load(defaults).endOfSpeech, level)
        }
        defaults.set("normal", forKey: "endOfSpeech")
        XCTAssertEqual(CallSettings.load(defaults).endOfSpeech.pause, 3.5)
        // A value this version doesn't know falls back to Normal.
        defaults.set("glacial", forKey: "endOfSpeech")
        XCTAssertEqual(CallSettings.load(defaults).endOfSpeech, .normal)
    }

    func testHermesWaitsLongerThanEveryPauseBeforeCuttingIn() throws {
        for level in EndOfSpeech.allCases {
            let grace = VoiceCall.Environment.cutOffGrace(pause: level.pause)
            // A turn ends `pause` after the last word: the grace covers that, and time to finish the sentence.
            XCTAssertGreaterThanOrEqual(grace, level.pause + 2, level.rawValue)
            // Under the plugin's 15 s margin for the phone's `played`.
            XCTAssertLessThanOrEqual(grace, 10, level.rawValue)
        }
        XCTAssertEqual(EndOfSpeech.allCases.map { VoiceCall.Environment.cutOffGrace(pause: $0.pause) }, [3.5, 5.5, 7, 10])
        XCTAssertEqual(VoiceCall.Environment.cutOffGrace(pause: 0.5), 3)
        XCTAssertEqual(VoiceCall.Environment.cutOffGrace(pause: 30), 10)

        let client = try DashboardClient(settings: ConnectionSettings(dashboardURL: "http://127.0.0.1:9", username: "u", password: "p"))
        let patient = CallSettings(provider: .apple, speechLocale: "", endOfSpeech: .patient)
        XCTAssertEqual(VoiceCall.Environment.live(client: client, settings: patient).cutOffGrace, 7)
    }
}
