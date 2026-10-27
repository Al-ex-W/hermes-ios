import Foundation

/// Lower and upper limits of a number field, and how its text becomes a value.
struct NumberBounds: Hashable {
    var min: Double?
    var max: Double?
    /// Whole numbers only (the current value is an integer, or the limits are).
    var integral: Bool

    static let unbounded = NumberBounds(min: nil, max: nil, integral: false)

    /// The value typed text stands for, or why it can't be saved. Empty text is 0 (the desktop's rule).
    func parse(_ text: String) -> Result<JSONValue, NumberInputError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let number: Double
        if trimmed.isEmpty {
            number = 0
        } else if let parsed = Double(trimmed), parsed.isFinite {
            number = parsed
        } else {
            return .failure(.notANumber)
        }
        if let min, number < min { return .failure(.belowMinimum(min)) }
        if let max, number > max { return .failure(.aboveMaximum(max)) }
        let whole = number == number.rounded() && abs(number) < 1e15
        if integral {
            guard whole else { return .failure(.notWhole) }
            return .success(.int(Int(number)))
        }
        // A whole number typed without a decimal point stays an integer; "0.5" or "1.0" is a fraction.
        if whole, !trimmed.contains("."), !trimmed.lowercased().contains("e") { return .success(.int(Int(number))) }
        return .success(.double(number))
    }

    /// "0 – 1", "at least 1", or nil.
    var summary: String? {
        func text(_ value: Double) -> String { JSONValue.double(value).displayText }
        switch (min, max) {
        case let (min?, max?): return "\(text(min)) – \(text(max))"
        case let (min?, nil): return "At least \(text(min))"
        case let (nil, max?): return "At most \(text(max))"
        default: return nil
        }
    }
}

enum NumberInputError: Error, Equatable, LocalizedError {
    case notANumber
    case notWhole
    case belowMinimum(Double)
    case aboveMaximum(Double)

    var errorDescription: String? {
        switch self {
        case .notANumber: return "Enter a number."
        case .notWhole: return "Enter a whole number."
        case let .belowMinimum(min): return "Must be at least \(JSONValue.double(min).displayText)."
        case let .aboveMaximum(max): return "Must be at most \(JSONValue.double(max).displayText)."
        }
    }
}

/// The control a config field renders as, picked from its schema the way the desktop's `ConfigField` does:
/// a switch for booleans, a menu for selects (a searchable list for large ones), a number field with limits,
/// list and JSON editors, a secure field for secrets, and text otherwise. Two keys have editors of their own.
/// (The desktop's free-input combobox serves only voice fields, which are stripped here.)
enum FieldControl: Equatable {
    case toggle
    case picker(options: [String])
    case searchablePicker(options: [String], clearable: Bool)
    case number(NumberBounds)
    case text(multiline: Bool)
    case secret
    case list
    case json
    /// `fallback_providers`: an ordered chain of `{provider, model}` entries.
    case fallbackModels
    /// `delegation.model` with `delegation.provider`: the subagent route.
    case delegationRoute

    /// Keys whose values are credentials even though their schema says string.
    static func looksSecret(_ key: String) -> Bool {
        let last = key.split(separator: ".").last.map(String.init)?.lowercased() ?? key.lowercased()
        return last == "api_key" || last.hasSuffix("_api_key") || last == "token" || last.hasSuffix("_token")
            || last == "password" || last.hasSuffix("_secret") || last == "secret"
    }

    static func resolve(key: String, field: ConfigFieldSchema, value: JSONValue?, config: JSONValue) -> FieldControl {
        if key == "fallback_providers" { return .fallbackModels }
        if key == "delegation.model" { return .delegationRoute }
        if field.kind == .boolean { return .toggle }

        if let options = SettingsCatalog.options(for: key, field: field, value: value, config: config) {
            if field.searchable {
                return .searchablePicker(options: options.filter { !$0.isEmpty }, clearable: field.clearable)
            }
            return .picker(options: options)
        }

        // A numeric setting whose default is null (`agent.max_turns`) reaches the schema as a string; the curated
        // limits say it's a number.
        if field.kind == .string, SettingsCatalog.bounds[key] != nil, value?.isNumberOrEmpty ?? true {
            return .number(bounds(for: key, field: field, value: value))
        }
        switch field.kind {
        case .number: return .number(bounds(for: key, field: field, value: value))
        case .list: return .list
        case .object: return .json
        case .secret: return .secret
        default: break
        }
        if case .object? = value { return .json }
        if case .array? = value { return .list }
        if looksSecret(key) { return .secret }
        let long = field.kind == .text || (value?.stringValue?.count ?? 0) > 100
        return .text(multiline: long)
    }

    static func bounds(for key: String, field: ConfigFieldSchema, value: JSONValue?) -> NumberBounds {
        let curated = SettingsCatalog.bounds[key]
        let min = field.minimum ?? curated?.min
        let max = field.maximum ?? curated?.max
        let fractionalLimits = [min, max].contains { $0.map { $0 != $0.rounded() } ?? false }
        let wholeLimits = !fractionalLimits && max.map { $0 > 1 } ?? true
        let integral: Bool
        switch value {
        case .double?: integral = false
        case .int?: integral = wholeLimits
        // No value to go by: whole when the limits say so (a count or a timeout, not a ratio).
        default: integral = wholeLimits && (min != nil || max != nil)
        }
        return NumberBounds(min: min, max: max, integral: integral)
    }
}

private extension JSONValue {
    var isNumberOrEmpty: Bool {
        switch self {
        case .int, .double, .null: return true
        case let .string(text): return text.isEmpty || Double(text) != nil
        default: return false
        }
    }
}
