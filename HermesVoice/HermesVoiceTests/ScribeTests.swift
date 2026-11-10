import XCTest
@testable import HermesVoice

/// ElevenLabs Scribe realtime: the socket URL, server messages, and how commits become turns.
final class ScribeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testURL() throws {
        let url = Scribe.url(token: "tok", silence: 0.8, language: "sv")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.elevenlabs.io")
        XCTAssertEqual(components.path, "/v1/speech-to-text/realtime")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "model_id": "scribe_v2_realtime", "audio_format": "pcm_16000", "commit_strategy": "vad",
            "vad_silence_threshold_secs": "0.80", "language_code": "sv", "token": "tok",
        ])
        let automatic = Scribe.url(token: "tok", silence: 1.5, language: nil)
        XCTAssertFalse(automatic.absoluteString.contains("language_code"))
    }

    func testVADSilenceStaysWithinWhatScribeAccepts() {
        // Scribe takes 0.192 to 3.0 s; every Calls setting asks for a pause it can't wait out by itself, or just can.
        for level in EndOfSpeech.allCases {
            let silence = Scribe.vadSilence(pause: level.pause)
            XCTAssertGreaterThanOrEqual(silence, 0.192, level.rawValue)
            XCTAssertLessThanOrEqual(silence, 3.0, level.rawValue)
            XCTAssertLessThanOrEqual(silence, level.pause, level.rawValue)
        }
        XCTAssertEqual(Scribe.vadSilence(pause: 1.5), 1.5)
        XCTAssertEqual(Scribe.vadSilence(pause: 3.5), 1.5)
        XCTAssertEqual(Scribe.vadSilence(pause: 8), 1.5)
        XCTAssertEqual(Scribe.vadSilence(pause: 0.5), 0.5)
        XCTAssertEqual(Scribe.vadSilence(pause: 0), 0.2)
        let url = Scribe.url(token: "tok", silence: ScribeTurnAssembler(pause: EndOfSpeech.veryPatient.pause).vadSilence, language: nil)
        XCTAssertTrue(url.absoluteString.contains("vad_silence_threshold_secs=1.50"))
    }

    func testAudioChunk() throws {
        let chunk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Scribe.audioChunk(Data([1, 0, 255, 127])).utf8)) as? [String: Any])
        XCTAssertEqual(chunk["message_type"] as? String, "input_audio_chunk")
        XCTAssertEqual(chunk["audio_base_64"] as? String, "AQD/fw==")
        XCTAssertEqual(chunk["commit"] as? Bool, false)
        XCTAssertEqual(chunk["sample_rate"] as? Int, 16_000)
    }

    func testMessages() {
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"session_started","session_id":"x","config":{"language_code":"en","sample_rate":16000}}"#),
                       .sessionStarted(language: "en"))
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"partial_transcript","text":"hello wor"}"#), .partial("hello wor"))
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"committed_transcript","text":"hello world"}"#),
                       .committed(text: "hello world", language: nil, timestamps: false))
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"committed_transcript_with_timestamps","text":"hej","language_code":"sv","words":[]}"#),
                       .committed(text: "hej", language: "sv", timestamps: true))
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"auth_error","error":"bad token"}"#), .error(kind: "auth_error", message: "bad token"))
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"session_time_limit_exceeded","error":"limit"}"#),
                       .error(kind: "session_time_limit_exceeded", message: "limit"))
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"warning","warning":"slow"}"#), .warning("slow"))
        XCTAssertEqual(ScribeMessage.parse(#"{"message_type":"edited_transcript","text":"a","edited_text":"b"}"#), .other("edited_transcript"))
        XCTAssertNil(ScribeMessage.parse(#"{"text":"no type"}"#))
        XCTAssertTrue(Scribe.fatalErrors.contains("auth_error"))
        XCTAssertFalse(Scribe.fatalErrors.contains("session_time_limit_exceeded"))
    }

    // MARK: The pause that ends a turn

    func testVADCommitEndsTheTurnWhenScribeWaitedTheWholePause() {
        // Quick: Scribe's own VAD waits the 1.5 s.
        var turns = ScribeTurnAssembler(pause: EndOfSpeech.quick.pause)
        XCTAssertEqual(turns.vadSilence, 1.5)
        turns.partial("hello", at: at(1))
        turns.partial("hello there", at: at(1.5))
        XCTAssertEqual(turns.text, "hello there")
        XCTAssertTrue(turns.hasText)
        let finished = turns.commit("Hello there.", language: nil, timestamps: false, at: at(3))
        XCTAssertEqual(finished, .init(text: "Hello there.", startedAt: at(1), endedAt: at(3), language: nil, segments: 1))
        XCTAssertFalse(turns.hasText)
        // The timestamped copy of the same commit isn't a second turn.
        XCTAssertNil(turns.commit("Hello there.", language: "en", timestamps: true, at: at(3.1)))
    }

    func testCommitIsHeldUntilThePauseHasPassed() {
        var turns = ScribeTurnAssembler()
        XCTAssertEqual(turns.pause, 3.5)
        turns.partial("I think we should", at: at(1))
        // Scribe commits 1.5 s after the last word; the turn ends 3.5 s after it.
        XCTAssertNil(turns.commit("I think we should", language: "en", timestamps: false, at: at(3)))
        XCTAssertTrue(turns.isHolding)
        XCTAssertTrue(turns.hasText, "the turn is still in progress: Hermes' speech waits for it")
        XCTAssertEqual(turns.text, "I think we should")
        XCTAssertNil(turns.tick(at: at(4.9)))
        let finished = turns.tick(at: at(5))
        XCTAssertEqual(finished, .init(text: "I think we should", startedAt: at(1), endedAt: at(5), language: "en", segments: 1))
        XCTAssertFalse(turns.hasText)
        XCTAssertNil(turns.tick(at: at(6)))
    }

    func testAThinkingPauseDoesNotSplitTheTurn() {
        var turns = ScribeTurnAssembler()
        turns.partial("I think we should", at: at(1))
        turns.partial("I think we should", at: at(2))
        XCTAssertNil(turns.commit("I think we should", language: nil, timestamps: false, at: at(3.5)))
        // 2.7 s after the last word the user goes on.
        turns.partial("go", at: at(4.7))
        XCTAssertFalse(turns.isHolding)
        XCTAssertEqual(turns.text, "I think we should go")
        XCTAssertNil(turns.tick(at: at(30)), "no turn while the user is talking")
        XCTAssertNil(turns.commit("go tomorrow.", language: "en", timestamps: false, at: at(7)))
        XCTAssertNil(turns.tick(at: at(8.9)))
        let finished = turns.tick(at: at(9))
        XCTAssertEqual(finished, .init(text: "I think we should go tomorrow.", startedAt: at(1), endedAt: at(9), language: "en", segments: 2))
    }

    func testEverySettingsPauseIsWaitedOut() {
        for level in EndOfSpeech.allCases {
            var turns = ScribeTurnAssembler(pause: level.pause)
            turns.partial("okay", at: at(0))
            // The commit comes `vadSilence` after the last word, so the turn is due `pause` after it.
            let committed = turns.vadSilence
            let early = turns.commit("Okay.", language: nil, timestamps: false, at: at(committed))
            if level.pause <= turns.vadSilence {
                XCTAssertEqual(early?.text, "Okay.", level.rawValue)
                continue
            }
            XCTAssertNil(early, level.rawValue)
            XCTAssertNil(turns.tick(at: at(level.pause - 0.05)), level.rawValue)
            XCTAssertEqual(turns.tick(at: at(level.pause))?.text, "Okay.", level.rawValue)
        }
    }

    func testEmptyCommitsAreIgnored() {
        var turns = ScribeTurnAssembler()
        XCTAssertNil(turns.commit("  ", language: nil, timestamps: false, at: at(1)))
        XCTAssertNil(turns.tick(at: at(10)))
        XCTAssertNil(turns.take(at: at(10)))
    }

    func testEmptyCommitDoesNotExtendTheHold() {
        var turns = ScribeTurnAssembler()
        turns.partial("that is all", at: at(1))
        XCTAssertNil(turns.commit("That is all.", language: nil, timestamps: false, at: at(3)))
        XCTAssertNil(turns.commit("", language: nil, timestamps: false, at: at(4)))
        XCTAssertEqual(turns.tick(at: at(5))?.text, "That is all.")
    }

    func testANoiseThatScribeTakesBackStartsThePauseAgain() {
        var turns = ScribeTurnAssembler()
        turns.partial("that is all", at: at(1))
        XCTAssertNil(turns.commit("That is all.", language: nil, timestamps: false, at: at(3)))
        // Something like speech ends the hold; Scribe then commits nothing for it.
        turns.partial("uh", at: at(4))
        XCTAssertFalse(turns.isHolding)
        XCTAssertNil(turns.commit("", language: nil, timestamps: false, at: at(5.5)))
        XCTAssertTrue(turns.isHolding)
        XCTAssertNil(turns.tick(at: at(7.4)))
        XCTAssertEqual(turns.tick(at: at(7.5))?.text, "That is all.")
    }

    // MARK: Segments Scribe cuts by itself

    func testLongSegmentCommitIsMergedWithWhatFollows() {
        var turns = ScribeTurnAssembler(pause: EndOfSpeech.quick.pause)
        turns.partial("one long", at: at(0))
        turns.partial("one long story", at: at(20))
        // Scribe cut the segment at ~36 s while the user kept talking: held, not a turn.
        XCTAssertNil(turns.commit("One long story,", language: nil, timestamps: false, at: at(36)))
        XCTAssertTrue(turns.isHolding)
        XCTAssertEqual(turns.text, "One long story,")
        XCTAssertNil(turns.tick(at: at(37)))
        turns.partial("and then", at: at(37))
        XCTAssertEqual(turns.text, "One long story, and then")
        let finished = turns.commit("and then it ended.", language: "en", timestamps: false, at: at(39))
        XCTAssertEqual(finished, .init(text: "One long story, and then it ended.", startedAt: at(0), endedAt: at(39), language: "en", segments: 2))
    }

    func testLongSegmentCommitEndsAfterAWholePause() {
        // No silence has passed when Scribe cuts a segment, so the whole pause is waited (at least `autoCommitHold`).
        var quick = ScribeTurnAssembler(pause: EndOfSpeech.quick.pause)
        quick.partial("a very long monologue", at: at(0))
        XCTAssertNil(quick.commit("A very long monologue.", language: nil, timestamps: false, at: at(35)))
        XCTAssertNil(quick.tick(at: at(36)))
        let finished = quick.tick(at: at(35 + quick.autoCommitHold))
        XCTAssertEqual(finished?.text, "A very long monologue.")
        XCTAssertEqual(finished?.startedAt, at(0))
        XCTAssertFalse(quick.hasText)

        var patient = ScribeTurnAssembler(pause: EndOfSpeech.patient.pause)
        patient.partial("a very long monologue", at: at(0))
        XCTAssertNil(patient.commit("A very long monologue.", language: nil, timestamps: false, at: at(35)))
        XCTAssertNil(patient.tick(at: at(39.9)))
        XCTAssertEqual(patient.tick(at: at(40))?.text, "A very long monologue.")
    }

    func testCommitWithoutPartialAfterAHoldIsShort() {
        var turns = ScribeTurnAssembler(pause: EndOfSpeech.quick.pause)
        turns.partial("first", at: at(0))
        XCTAssertNil(turns.commit("First part", language: nil, timestamps: false, at: at(36)))
        // A commit that arrives with no partial before it is a short segment, so it ends the turn.
        let finished = turns.commit("second part.", language: nil, timestamps: false, at: at(37))
        XCTAssertEqual(finished?.text, "First part second part.")
        XCTAssertEqual(finished?.segments, 2)
    }

    // MARK: Turns taken or dropped early

    func testTakeFlushesHeldAndPartial() {
        var turns = ScribeTurnAssembler()
        turns.partial("start", at: at(0))
        XCTAssertNil(turns.commit("Start of it", language: nil, timestamps: false, at: at(40)))
        turns.partial("and the rest", at: at(41))
        let finished = turns.take(at: at(42))
        XCTAssertEqual(finished, .init(text: "Start of it and the rest", startedAt: at(0), endedAt: at(42), language: nil, segments: 2))
        XCTAssertNil(turns.take(at: at(43)))
    }

    func testSendNowTakesAHeldCommitAtOnce() {
        var turns = ScribeTurnAssembler(pause: EndOfSpeech.veryPatient.pause)
        turns.partial("yes please", at: at(1))
        XCTAssertNil(turns.commit("Yes, please.", language: "en", timestamps: false, at: at(3)))
        let finished = turns.take(at: at(3.4))
        XCTAssertEqual(finished, .init(text: "Yes, please.", startedAt: at(1), endedAt: at(3.4), language: "en", segments: 1))
        XCTAssertFalse(turns.hasText)
        XCTAssertNil(turns.tick(at: at(60)), "the turn was sent: nothing is left to end")
        // What is said next is a new turn.
        turns.partial("and another thing", at: at(20))
        XCTAssertNil(turns.commit("And another thing.", language: "en", timestamps: false, at: at(23)))
        XCTAssertEqual(turns.tick(at: at(29.5))?.text, "And another thing.")
    }

    func testWordsTakenFromAnOpenSegmentAreNotHeardAgain() {
        var turns = ScribeTurnAssembler()
        turns.partial("hello there", at: at(1))
        XCTAssertEqual(turns.take(at: at(1.2))?.text, "hello there")
        // Scribe's segment is still open: it repeats the words, then commits them.
        turns.partial("hello there", at: at(1.4))
        XCTAssertFalse(turns.hasText)
        XCTAssertNil(turns.commit("Hello there.", language: nil, timestamps: false, at: at(2.7)))
        XCTAssertFalse(turns.hasText)
        XCTAssertNil(turns.tick(at: at(30)))
        // The next segment is heard in full.
        turns.partial("next thing", at: at(40))
        XCTAssertEqual(turns.text, "next thing")
        XCTAssertNil(turns.commit("Next thing.", language: nil, timestamps: false, at: at(42)))
        XCTAssertEqual(turns.tick(at: at(44))?.text, "Next thing.")
    }

    func testSpeechThatGoesOnInATakenSegmentKeepsOnlyItsNewWords() {
        var turns = ScribeTurnAssembler()
        turns.partial("hello there", at: at(1))
        XCTAssertEqual(turns.take(at: at(1.2))?.text, "hello there")
        turns.partial("Hello there and", at: at(1.6))
        XCTAssertEqual(turns.text, "and")
        turns.partial("Hello there and more", at: at(2))
        XCTAssertEqual(turns.text, "and more")
        XCTAssertNil(turns.commit("Hello there and more words.", language: nil, timestamps: false, at: at(4)))
        XCTAssertEqual(turns.text, "and more words.")
        // The timestamped copy of that commit, in full, isn't counted again.
        XCTAssertNil(turns.commit("Hello there and more words.", language: nil, timestamps: true, at: at(4.1)))
        XCTAssertEqual(turns.text, "and more words.")
        let finished = turns.tick(at: at(6))
        XCTAssertEqual(finished, .init(text: "and more words.", startedAt: at(1.6), endedAt: at(6), language: nil, segments: 1))
        // The segment after it is whole again.
        turns.partial("one two three", at: at(10))
        XCTAssertEqual(turns.text, "one two three")
    }

    func testNoPauseIsCountedWhileListeningIsPaused() {
        var turns = ScribeTurnAssembler()
        turns.partial("I was saying", at: at(1))
        XCTAssertNil(turns.commit("I was saying", language: nil, timestamps: false, at: at(3)))
        turns.partial("that", at: at(3.5))
        // Hermes speaks: the provider drops what is held (the call flushed it as cut off first).
        turns.discard()
        XCTAssertFalse(turns.hasText)
        XCTAssertFalse(turns.isHolding)
        XCTAssertNil(turns.tick(at: at(60)))
        // Scribe hears silence meanwhile and closes the open segment; it is not a turn afterwards.
        turns.segmentClosed()
        XCTAssertNil(turns.commit("That.", language: nil, timestamps: false, at: at(61)))
        XCTAssertNil(turns.tick(at: at(90)))
        turns.partial("now my answer", at: at(100))
        XCTAssertEqual(turns.text, "now my answer")
    }

    func testASegmentLeftOpenByAShortPauseKeepsOnlyItsNewWords() {
        var turns = ScribeTurnAssembler()
        turns.partial("one two", at: at(1))
        turns.discard()
        // Listening resumed before Scribe committed: the same segment goes on.
        turns.partial("one two", at: at(2))
        XCTAssertFalse(turns.hasText)
        turns.partial("one two three four", at: at(3))
        XCTAssertEqual(turns.text, "three four")
        XCTAssertNil(turns.commit("One two three four.", language: nil, timestamps: false, at: at(5)))
        XCTAssertEqual(turns.tick(at: at(7))?.text, "three four.")
    }

    func testANewSessionForgetsTakenWords() {
        var turns = ScribeTurnAssembler()
        turns.partial("lost with the session", at: at(1))
        XCTAssertEqual(turns.take(at: at(2))?.text, "lost with the session")
        turns.sessionStarted()
        turns.partial("a b c d e", at: at(5))
        XCTAssertEqual(turns.text, "a b c d e")
        // A commit that comes without a partial counts in a fresh session.
        var fresh = ScribeTurnAssembler(pause: EndOfSpeech.quick.pause)
        fresh.discard()
        fresh.sessionStarted()
        XCTAssertEqual(fresh.commit("Hi.", language: nil, timestamps: false, at: at(1))?.text, "Hi.")
    }
}
