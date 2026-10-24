import XCTest
@testable import HermesVoice

/// Decodes frames recorded from servers (`devtools/record_fixtures.py`): every result, event and server request
/// the app reads must land in its generated type, not in `.unknown` or a `GatewayDecodingError`.
final class GatewayFixtureTests: XCTestCase {
    private static let results: [String: Decodable.Type] = [
        "client.capabilities": ClientCapabilitiesResult.self,
        "session.create": SessionCreateResult.self,
        "session.resume": SessionResumeResult.self,
        "session.activate": SessionActivateResult.self,
        "session.events.since": SessionEventsSinceResult.self,
        "session.interrupt": SessionInterruptResult.self,
        "prompt.submit": PromptSubmitResult.self,
    ]

    private struct Fixture: Decodable {
        let source: String
        let frames: [JSONValue]
    }

    private func fixtures() throws -> [Fixture] {
        let urls = Bundle(for: Self.self).urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let fixtures = try urls.map { try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: $0)) }
        XCTAssertTrue(fixtures.contains { $0.source == "devtools/fake_hermes.py" }, "the fake's frames are bundled")
        return fixtures
    }

    func testRecordedFramesDecodeIntoTheirTypes() throws {
        var seen: Set<String> = []
        for fixture in try fixtures() {
            for frame in fixture.frames {
                let at = "\(fixture.source): \(frame)".prefix(300)
                switch frame["kind"]?.stringValue {
                case "result":
                    let method = try XCTUnwrap(frame["method"]?.stringValue)
                    guard let type = Self.results[method] else { continue }
                    let result = try XCTUnwrap(frame["result"])
                    XCTAssertNoThrow(try decode(type, result), "\(at)")
                    if method == "session.events.since" {
                        for event in result["events"]?.arrayValue ?? [] { check(event: event, at) }
                    }
                    seen.insert(method)
                case "event":
                    let params = try XCTUnwrap(frame["params"])
                    check(event: params, at)
                    seen.insert(params["type"]?.stringValue ?? "")
                case "request":
                    let request = try XCTUnwrap(frame["frame"])
                    let decoded = ServerRequest.decode(id: request["id"]?.stringValue ?? "",
                                                       method: request["method"]?.stringValue ?? "", params: request["params"])
                    if case .unknown = decoded { XCTFail("request outside the contract: \(at)") }
                    seen.insert(decoded.method)
                default:
                    XCTFail("unknown frame kind: \(at)")
                }
            }
        }
        for name in ["session.create", "session.resume", "session.activate", "session.events.since", "prompt.submit",
                     "gateway.ready", "message.delta", "message.complete", "approval", "clarify"] {
            XCTAssertTrue(seen.contains(name), "no recorded \(name)")
        }
    }

    func testRecordedAttachResultsReadAsLiveSessions() throws {
        for fixture in try fixtures() {
            for frame in fixture.frames where frame["kind"] == "result" {
                guard let result = frame["result"] else { continue }
                switch frame["method"]?.stringValue {
                case "session.resume":
                    XCTAssertEqual(LiveSession(try result.decode(SessionResumeResult.self)), try LiveSession(raw: result))
                case "session.activate":
                    XCTAssertEqual(LiveSession(try result.decode(SessionActivateResult.self)), try LiveSession(raw: result))
                default:
                    break
                }
            }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws {
        _ = try value.decode(type)
    }

    private func check(event params: JSONValue, _ at: Substring) {
        guard let envelope = EventEnvelope(params: params) else { return XCTFail("no envelope: \(at)") }
        if case let .unknown(type, payload) = envelope.event {
            XCTFail("event outside the contract: \(type) \(String(describing: payload)) in \(at)")
        }
    }
}
