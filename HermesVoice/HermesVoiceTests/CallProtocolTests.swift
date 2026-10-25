import XCTest
@testable import HermesVoice

/// The phone's wire format with the Hermes Voice plugin: user turns, phone messages, plugin messages, pushes, call ids.
final class CallProtocolTests: XCTestCase {
    private let callID = "0123456789abcdef0123456789abcdef"

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: User turns

    func testUserTurnEncodesSnakeCaseWithISODates() throws {
        let started = Date(timeIntervalSince1970: 1_790_000_000.25)
        let turn = UserTurn(callID: callID, text: "Hej Hermes", ending: .endOfSpeech(detector: "apple_silence", detail: 1.2),
                            provider: .apple, language: "sv-SE", startedAt: started, endedAt: started.addingTimeInterval(2))
        let json = try object(PhoneMessage.userTurn(turn).encoded())

        XCTAssertEqual(json["type"] as? String, "user_turn")
        XCTAssertEqual(json["call_id"] as? String, callID)
        XCTAssertEqual(json["text"] as? String, "Hej Hermes")
        XCTAssertEqual(json["provider"] as? String, "apple")
        XCTAssertEqual(json["language"] as? String, "sv-SE")
        XCTAssertEqual(json["started_at"] as? String, "2026-09-21T14:13:20.250Z")
        XCTAssertEqual(json["ended_at"] as? String, "2026-09-21T14:13:22.250Z")
        let ending = try XCTUnwrap(json["ending"] as? [String: Any])
        XCTAssertEqual(ending["kind"] as? String, "end_of_speech")
        XCTAssertEqual(ending["detector"] as? String, "apple_silence")
        XCTAssertEqual(ending["detail"] as? Double, 1.2)
        XCTAssertNil(ending["error"])
    }

    func testEveryEndingRoundTrips() throws {
        let endings: [TurnEnding] = [
            .endOfSpeech(detector: "scribe_vad", detail: 0.8), .endOfSpeech(detector: "typed", detail: nil),
            .cutOff, .hangUp, .muted, .dropped, .providerError("Recognition failed"),
        ]
        let now = Date(timeIntervalSince1970: 1_790_000_000.5)
        for ending in endings {
            let turn = UserTurn(callID: callID, text: "x", ending: ending, provider: .scribe, language: nil, startedAt: now, endedAt: now)
            let data = try JSONEncoder().encode(turn)
            XCTAssertEqual(try JSONDecoder().decode(UserTurn.self, from: data), turn, "\(ending)")
        }
    }

    func testEndingKindsAndOptionalFields() throws {
        func kind(_ ending: TurnEnding) throws -> [String: Any] {
            try object(String(decoding: JSONEncoder().encode(ending), as: UTF8.self))
        }
        XCTAssertEqual(try kind(.cutOff) as NSDictionary, ["kind": "cut_off"])
        XCTAssertEqual(try kind(.hangUp) as NSDictionary, ["kind": "hang_up"])
        XCTAssertEqual(try kind(.muted) as NSDictionary, ["kind": "muted"])
        XCTAssertEqual(try kind(.dropped) as NSDictionary, ["kind": "dropped"])
        XCTAssertEqual(try kind(.providerError("boom")) as NSDictionary, ["kind": "provider_error", "error": "boom"])
        XCTAssertEqual(try kind(.endOfSpeech(detector: "typed", detail: nil)) as NSDictionary, ["kind": "end_of_speech", "detector": "typed"])
    }

    func testDecodesDatesWithoutFractionAndRejectsUnknownEndings() throws {
        let text = """
        {"type":"user_turn","call_id":"\(callID)","text":"hi","ending":{"kind":"end_of_speech"},"provider":"scribe",
         "started_at":"2026-10-25T09:41:07Z","ended_at":"2026-10-25T09:41:09.5Z"}
        """
        let turn = try JSONDecoder().decode(UserTurn.self, from: Data(text.utf8))
        XCTAssertEqual(turn.ending, .endOfSpeech(detector: "unknown", detail: nil))
        XCTAssertNil(turn.language)
        XCTAssertEqual(turn.endedAt.timeIntervalSince(turn.startedAt), 2.5, accuracy: 0.001)

        let bad = text.replacingOccurrences(of: "end_of_speech", with: "shouted")
        XCTAssertThrowsError(try JSONDecoder().decode(UserTurn.self, from: Data(bad.utf8)))
    }

    // MARK: Phone and plugin messages

    func testPhoneMessages() throws {
        let hello = PhoneHello(callID: callID, sessionID: "s1", title: "Groceries", initiatedBy: .push, appVersion: "0.1.0 (1)")
        XCTAssertEqual(try object(PhoneMessage.hello(hello).encoded()) as NSDictionary, [
            "type": "hello", "call_id": callID, "session_id": "s1", "title": "Groceries", "initiated_by": "push", "app_version": "0.1.0 (1)",
        ])
        let bare = PhoneHello(callID: callID, sessionID: nil, title: nil, initiatedBy: .user, appVersion: "1")
        XCTAssertEqual(try object(PhoneMessage.hello(bare).encoded()) as NSDictionary, [
            "type": "hello", "call_id": callID, "initiated_by": "user", "app_version": "1",
        ])
        XCTAssertEqual(try object(PhoneMessage.ringing.encoded()) as NSDictionary, ["type": "ringing"])
        XCTAssertEqual(try object(PhoneMessage.answered.encoded()) as NSDictionary, ["type": "answered"])
        XCTAssertEqual(try object(PhoneMessage.declined.encoded()) as NSDictionary, ["type": "declined"])
        XCTAssertEqual(try object(PhoneMessage.played("u1").encoded()) as NSDictionary, ["type": "played", "id": "u1"])
        XCTAssertEqual(try object(PhoneMessage.ping.encoded()) as NSDictionary, ["type": "ping"])
        XCTAssertEqual(try object(PhoneMessage.bye("hang_up").encoded()) as NSDictionary, ["type": "bye", "reason": "hang_up"])
        XCTAssertEqual(try object(PhoneMessage.bye(nil).encoded()) as NSDictionary, ["type": "bye"])
    }

    func testPluginMessages() {
        XCTAssertEqual(PluginMessage.parse(#"{"type":"ready","call_id":"\#(callID)","state":"ringing"}"#), .ready(callID: callID, ringing: true))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"ready","call_id":"\#(callID)","state":"live"}"#), .ready(callID: callID, ringing: false))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"cancel","reason":"no_answer"}"#), .cancel("no_answer"))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"speech_start","id":"u1","text":"Hi","sample_rate":24000,"format":"pcm_s16le"}"#),
                       .speechStart(id: "u1", text: "Hi", sampleRate: 24_000))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"speech_end","id":"u1"}"#), .speechEnd(id: "u1", cancelled: false, error: nil))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"speech_end","id":"u1","cancelled":true}"#), .speechEnd(id: "u1", cancelled: true, error: nil))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"speech_end","id":"u1","error":"tts down"}"#), .speechEnd(id: "u1", cancelled: false, error: "tts down"))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"pong"}"#), .pong)
        XCTAssertEqual(PluginMessage.parse(#"{"type":"ended","outcome":"ended_by_agent"}"#), .ended(.endedByAgent))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"ended","outcome":"busy"}"#), .ended(.busy))
        XCTAssertEqual(PluginMessage.parse(#"{"type":"ended","outcome":"brand_new"}"#), .ended(.other("brand_new")))
        XCTAssertNil(PluginMessage.parse(#"{"type":"mystery"}"#))
        XCTAssertNil(PluginMessage.parse("not json"))
    }

    func testOutcomes() {
        let all = ["answered", "no_answer", "declined", "push_failed", "unreachable", "lost", "tts_failed",
                   "ended_by_user", "ended_by_agent", "busy", "not_allowed"]
        for raw in all {
            if case .other = CallOutcome(raw) { XCTFail("\(raw) isn't known") }
        }
        XCTAssertNil(CallOutcome.endedByAgent.message)
        XCTAssertNotNil(CallOutcome.busy.message)
        XCTAssertNotNil(CallOutcome.notAllowed.message)
    }

    func testPluginStatus() {
        let status = VoicePluginStatus(["calls": 1, "tts": "elevenlabs", "h2": true, "apns_configured": true, "scribe_configured": false])
        XCTAssertEqual(status, VoicePluginStatus(calls: 1, tts: "elevenlabs", h2: true, apnsConfigured: true, scribeConfigured: false))
        XCTAssertTrue(status.canRing)
        XCTAssertFalse(VoicePluginStatus(["apns_configured": true]).canRing)
        XCTAssertNil(status.activeCall)
    }

    /// The texts the plugin's inject.py puts into the conversation.
    func testVoiceTranscript() {
        let hint = "(Reply out loud with start_call; your text replies are not spoken.)"
        XCTAssertEqual(VoiceTranscript.spoken("[Voice] the blue one \(hint)"), "the blue one")
        XCTAssertEqual(VoiceTranscript.spoken("[Voice, cut off] wait no \(hint)"), "wait no (cut off)")
        XCTAssertEqual(VoiceTranscript.spoken("[Voice, hung up] bye (The user hung up, so the call is over; reply in text.)"),
                       "bye (hung up)")
        XCTAssertNil(VoiceTranscript.spoken("[Voice] one\n\n[Voice] two"))
        XCTAssertNil(VoiceTranscript.spoken("hello"))
        XCTAssertNil(VoiceTranscript.spoken("[Voice call started] The user is calling you"))
        XCTAssertEqual(VoiceTranscript.notice("[Voice call started] The user is calling you (call ab)."), "Voice call started")
        XCTAssertEqual(VoiceTranscript.notice("[Voice call ended by user] Reply in text from now on."), "Voice call ended by user")
        XCTAssertEqual(VoiceTranscript.notice("[Voice line not delivered: the phone couldn't be rung (no key)] Reply in text."),
                       "Voice line not delivered")
        XCTAssertEqual(VoiceTranscript.notice("[Voice, speech recognition failed: offline] \(hint)"), "Voice: speech recognition failed")
        XCTAssertNil(VoiceTranscript.notice("[Voice] hi \(hint)"))
    }

    func testPluginStatusActiveCall() {
        let id = String(repeating: "ab", count: 16)
        let status = VoicePluginStatus(["calls": 0, "active_call": [
            "call_id": id.uppercased(), "session_id": "s1", "title": "Deploy", "state": "ringing", "initiated_by": "push",
        ]])
        XCTAssertEqual(status.activeCall?.callID, id)
        XCTAssertEqual(status.activeCall?.sessionID, "s1")
        XCTAssertEqual(status.activeCall?.state, "ringing")
        XCTAssertEqual(status.activeCall?.initiatedBy, .push)
        XCTAssertNil(VoicePluginStatus(["active_call": NSNull()]).activeCall)
        XCTAssertNil(VoicePluginStatus(["active_call": ["call_id": "nope"]]).activeCall)
    }

    // MARK: Pushes and call ids

    func testPushPayload() {
        let push = CallPush(payload: ["call_id": callID.uppercased(), "session_id": "20261025_1", "profile": "",
                                      "mode": "sync", "title": "Groceries", "aps": [:]])
        XCTAssertEqual(push, CallPush(callID: callID, sessionID: "20261025_1", profile: nil, mode: "sync", title: "Groceries"))
        XCTAssertNil(CallPush(payload: ["call_id": "nope", "session_id": "s"]))
        XCTAssertNil(CallPush(payload: ["session_id": "s"]))
    }

    func testCallIDAndUUID() throws {
        let uuid = try XCTUnwrap(CallID.uuid(from: callID))
        XCTAssertEqual(uuid.uuidString, "01234567-89AB-CDEF-0123-456789ABCDEF")
        XCTAssertEqual(CallID.string(from: uuid), callID)
        XCTAssertEqual(CallID.uuid(from: callID.uppercased()), uuid)

        let fresh = CallID.make()
        XCTAssertEqual(fresh.count, 32)
        XCTAssertEqual(fresh, fresh.lowercased())
        XCTAssertEqual(CallID.uuid(from: fresh).map(CallID.string), fresh)

        XCTAssertNil(CallID.uuid(from: "0123456789abcdef0123456789abcde"))
        XCTAssertNil(CallID.uuid(from: "0123456789abcdef0123456789abcdeg"))
        XCTAssertNil(CallID.uuid(from: "01234567-89ab-cdef-0123-456789abcdef"))
        XCTAssertNil(CallID.normalize("٠١٢٣٤٥٦٧٨٩abcdef0123456789abcdef"))
    }

    func testCallSettingsLanguageCode() {
        var settings = CallSettings(provider: .scribe, speechLocale: "sv-SE", endOfSpeech: .normal)
        XCTAssertEqual(settings.languageCode, "sv")
        settings.speechLocale = ""
        XCTAssertNil(settings.languageCode)
    }
}
