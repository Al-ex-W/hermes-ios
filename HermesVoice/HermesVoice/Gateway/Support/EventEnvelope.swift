import Foundation

/// The params of an `event` notification, `{type, session_id, seq, payload}`; replayed `events[]` entries have
/// the same shape. `seq` counts per runtime session (session-less broadcasts have none).
struct EventEnvelope: Codable, Hashable, Sendable {
    var type: String
    /// nil for a session-less frame (Hermes sends those with an empty id).
    var sessionID: String?
    var seq: Int?
    var payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case seq
        case payload
    }

    init(type: String, sessionID: String? = nil, seq: Int? = nil, payload: JSONValue? = nil) {
        self.type = type
        self.sessionID = sessionID?.isEmpty == false ? sessionID : nil
        self.seq = seq
        self.payload = payload
    }

    /// From an event frame's params (or a replayed entry); nil without a string `type`.
    init?(params: JSONValue) {
        guard let type = params["type"]?.stringValue else { return nil }
        self.init(type: type, sessionID: params["session_id"]?.stringValue, seq: params["seq"]?.intValue,
                  payload: params["payload"])
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try container.decode(String.self, forKey: .type),
                  sessionID: try? container.decodeIfPresent(String.self, forKey: .sessionID),
                  seq: try? container.decodeIfPresent(Int.self, forKey: .seq),
                  payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload))
    }

    /// The typed event; a payload outside the contract is `.unknown` (logged).
    var event: GatewayEvent { GatewayEvent.decode(type: type, payload: payload) }
}

extension GatewayClient {
    /// `gateway.ping`, answered on the gateway's read loop (not part of the contract).
    @discardableResult
    func gatewayPing(timeout: TimeInterval? = nil) async throws -> JSONValue {
        try await transport.call("gateway.ping", params: [:], timeout: timeout)
    }
}
