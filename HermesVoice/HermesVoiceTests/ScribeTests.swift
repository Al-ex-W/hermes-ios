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

    func testVADCommitEndsTheTurn() {
        var turns = ScribeTurnAssembler()
        turns.partial("hello", at: at(1))
        turns.partial("hello there", at: at(1.5))
        XCTAssertEqual(turns.text, "hello there")
        XCTAssertTrue(turns.hasText)
        let finished = turns.commit("Hello there.", language: nil, timestamps: false, at: at(2.5))
        XCTAssertEqual(finished, .init(text: "Hello there.", startedAt: at(1), endedAt: at(2.5), language: nil, segments: 1))
        XCTAssertFalse(turns.hasText)
        // The timestamped copy of the same commit isn't a second turn.
        XCTAssertNil(turns.commit("Hello there.", language: "en", timestamps: true, at: at(2.6)))
    }

    func testEmptyCommitsAreIgnored() {
        var turns = ScribeTurnAssembler()
        XCTAssertNil(turns.commit("  ", language: nil, timestamps: false, at: at(1)))
        XCTAssertNil(turns.tick(at: at(10)))
        XCTAssertNil(turns.take(at: at(10)))
    }

    func testLongSegmentCommitIsMergedWithWhatFollows() {
        var turns = ScribeTurnAssembler()
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

    func testHeldCommitEndsAfterTheHold() {
        var turns = ScribeTurnAssembler()
        turns.partial("a very long monologue", at: at(0))
        XCTAssertNil(turns.commit("A very long monologue.", language: nil, timestamps: false, at: at(35)))
        XCTAssertNil(turns.tick(at: at(36)))
        let finished = turns.tick(at: at(35 + turns.holdFor))
        XCTAssertEqual(finished?.text, "A very long monologue.")
        XCTAssertEqual(finished?.startedAt, at(0))
        XCTAssertFalse(turns.hasText)
    }

    func testCommitWithoutPartialAfterAHoldIsShort() {
        var turns = ScribeTurnAssembler()
        turns.partial("first", at: at(0))
        XCTAssertNil(turns.commit("First part", language: nil, timestamps: false, at: at(36)))
        // A commit that arrives with no partial before it is a short segment, so it ends the turn.
        let finished = turns.commit("second part.", language: nil, timestamps: false, at: at(37))
        XCTAssertEqual(finished?.text, "First part second part.")
        XCTAssertEqual(finished?.segments, 2)
    }

    func testTakeFlushesHeldAndPartial() {
        var turns = ScribeTurnAssembler()
        turns.partial("start", at: at(0))
        XCTAssertNil(turns.commit("Start of it", language: nil, timestamps: false, at: at(40)))
        turns.partial("and the rest", at: at(41))
        let finished = turns.take(at: at(42))
        XCTAssertEqual(finished, .init(text: "Start of it and the rest", startedAt: at(0), endedAt: at(42), language: nil, segments: 2))
        XCTAssertNil(turns.take(at: at(43)))
    }
}
