import Foundation

/// Sends one JSON-RPC call over the gateway socket and returns its raw `result`.
/// `timeout` nil means the transport's default deadline.
protocol GatewayCalling: AnyObject {
    func call(_ method: String, params: JSONValue, timeout: TimeInterval?) async throws -> JSONValue
}

extension GatewayCalling {
    func call(_ method: String, params: JSONValue = [:]) async throws -> JSONValue {
        try await call(method, params: params, timeout: nil)
    }
}

/// A call succeeded but its result didn't match the contract; `raw` keeps what Hermes sent.
struct GatewayDecodingError: LocalizedError {
    let method: String
    let raw: JSONValue
    let underlying: Error

    var errorDescription: String? {
        "Hermes answered \(method) in an unexpected shape (\(underlying))."
    }
}
