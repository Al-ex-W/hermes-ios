import Foundation

/// Any JSON value, kept exactly: the gateway's opaque fields, unknown keys and untyped frames.
/// Integers and fractions stay distinct (`int` vs `double`) so values round-trip unchanged.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Access

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value): return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .int(value): return Double(value)
        case let .double(value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }

    /// This object with `key` set to `value`; any other value is returned unchanged.
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case var .object(object) = self else { return self }
        object[key] = value
        return .object(object)
    }
}

// MARK: - Bridging

extension JSONValue {
    /// From a `JSONSerialization` object (or plain Swift values); anything that isn't JSON becomes `null`.
    init(any value: Any) {
        switch value {
        case let value as JSONValue:
            self = value
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// The `JSONSerialization` form: `NSNull`, `Bool`, `Int`, `Double`, `String`, `[Any]`, `[String: Any]`.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .int(value): return value
        case let .double(value): return value
        case let .string(value): return value
        case let .array(value): return value.map(\.anyValue)
        case let .object(value): return value.mapValues(\.anyValue)
        }
    }

    init(jsonData: Data) throws {
        self.init(any: try JSONSerialization.jsonObject(with: jsonData, options: .fragmentsAllowed))
    }

    func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONValue(jsonData: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: jsonData())
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Open objects

/// A coding key for any string: the unknown keys of an open (`additionalProperties`) object.
struct AnyCodingKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Decoder {
    /// The object's members outside `known`: an open schema's `extras`.
    func extraValues<Value: Decodable>(_ type: Value.Type = JSONValue.self, excluding known: Set<String>) throws -> [String: Value] {
        let container = try self.container(keyedBy: AnyCodingKey.self)
        var extras: [String: Value] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(Value.self, forKey: key)
        }
        return extras
    }
}

extension Encoder {
    /// Writes `extras` beside the typed members; a key that is also a typed member is skipped.
    func encodeExtras<Value: Encodable>(_ extras: [String: Value], excluding known: Set<String>) throws {
        var container = self.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extras where !known.contains(key) {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}
