import XCTest
@testable import HermesVoice

final class GatewayDecodingTests: XCTestCase {
    func testEventPayloadOutsideTheContractIsUnknown() {
        XCTAssertEqual(GatewayEvent.decode(type: "message.delta", payload: ["text": "hi"]),
                       .messageDelta(StreamDeltaPayload(text: "hi")))
        XCTAssertEqual(GatewayEvent.decode(type: "message.delta", payload: ["text": 5]),
                       .unknown(type: "message.delta", payload: ["text": 5]))
        XCTAssertEqual(GatewayEvent.decode(type: "session.title", payload: nil),
                       .unknown(type: "session.title", payload: nil))
        XCTAssertEqual(GatewayEvent.decode(type: "future.thing", payload: ["x": 1]),
                       .unknown(type: "future.thing", payload: ["x": 1]))
        XCTAssertEqual(GatewayEvent.decode(type: "message.start", payload: nil), .messageStart)
        XCTAssertEqual(GatewayEvent.decode(type: "voice.status", payload: [:]).type, "voice.status", "stripped events stay unknown")
    }

    func testMessageCompleteTextIsReadAsString() {
        guard case let .messageComplete(payload) = GatewayEvent.decode(type: "message.complete", payload: ["text": "done", "status": "complete"]) else {
            return XCTFail()
        }
        XCTAssertEqual(payload.text?.stringValue, "done")
    }

    func testServerRequestOutsideTheContractKeepsItsID() {
        let request = ServerRequest.decode(id: "srq-1", method: "approval", params: ["session_id": "r1"])
        XCTAssertEqual(request, .unknown(id: "srq-1", method: "approval", params: ["session_id": "r1"]))
        XCTAssertEqual(request.id, "srq-1")
        XCTAssertEqual(request.sessionID, "r1")

        let sudo = ServerRequest.decode(id: "srq-2", method: "sudo", params: ["session_id": "", "command": "ls"])
        guard case .sudo = sudo else { return XCTFail("\(sudo)") }
        XCTAssertNil(sudo.sessionID, "an empty session is app-level")
    }

    func testEnvelope() throws {
        let envelope = try XCTUnwrap(EventEnvelope(params: ["type": "message.delta", "session_id": "r1", "seq": 4, "payload": ["text": "a"]]))
        XCTAssertEqual(envelope.sessionID, "r1")
        XCTAssertEqual(envelope.seq, 4)
        XCTAssertEqual(envelope.event, .messageDelta(StreamDeltaPayload(text: "a")))

        let broadcast = try XCTUnwrap(EventEnvelope(params: ["type": "sessions.changed", "session_id": ""]))
        XCTAssertNil(broadcast.sessionID)
        XCTAssertNil(broadcast.seq)
        XCTAssertNil(EventEnvelope(params: ["session_id": "r1"]), "no type, no event")

        let decoded = try JSONDecoder().decode(EventEnvelope.self, from: Data(#"{"type":"notice","session_id":"","seq":"x"}"#.utf8))
        XCTAssertEqual(decoded, EventEnvelope(type: "notice"))
    }

    func testIntegersBeyondIntBecomeDoubles() throws {
        XCTAssertEqual(try JSONValue(jsonData: Data("9223372036854775807".utf8)), .int(.max))
        XCTAssertEqual(try JSONValue(jsonData: Data("-9223372036854775808".utf8)), .int(.min))
        XCTAssertEqual(try JSONValue(jsonData: Data("12345678901234567890".utf8)), .double(Double(UInt64(12_345_678_901_234_567_890))))
        XCTAssertEqual(try JSONValue(jsonData: Data(#"{"id": 18446744073709551615}"#.utf8)), ["id": .double(Double(UInt64.max))])
        XCTAssertEqual(try JSONValue(jsonData: Data("2.5".utf8)), .double(2.5))
        XCTAssertEqual(try JSONValue.encode(3.0), .int(3), "JSONEncoder writes an integral double as an integer")
    }

    func testEncoderOmitsNilKeys() throws {
        XCTAssertEqual(try JSONValue.encode(SessionResumeParams(sessionId: "s1")), ["session_id": "s1"])
        XCTAssertEqual(try JSONValue.encode(SessionActivateParams(sessionId: "r1", cols: 96, omitMessages: true)),
                       ["session_id": "r1", "cols": 96, "omit_messages": true])
        XCTAssertEqual(try JSONValue.encode(PromptSubmitParams(sessionId: "r1", text: "hi")), ["session_id": "r1", "text": "hi"])
        XCTAssertEqual(try JSONValue.encode(ApprovalResult(choice: .once)), ["choice": "once"])
        XCTAssertEqual(try JSONValue.encode(ClarifyResult(answers: nil)), [:])
        XCTAssertEqual(try JSONValue.encode(ClarifyResult(answers: ["q0": nil])), ["answers": ["q0": .null]])
    }
}
