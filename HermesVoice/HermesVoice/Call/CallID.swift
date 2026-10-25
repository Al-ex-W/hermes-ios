import Foundation

/// A call's id: 32 lowercase hex characters on the wire (`call_id`), the same 128 bits as the CallKit UUID.
enum CallID {
    /// A fresh call id for a call the user starts.
    static func make() -> String {
        string(from: UUID())
    }

    /// The call id as the plugin sends it, or nil when it isn't 32 hex characters.
    static func normalize(_ value: String) -> String? {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard id.count == 32, id.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return id
    }

    /// The CallKit UUID for a call id: dashes inserted as 8-4-4-4-12.
    static func uuid(from callID: String) -> UUID? {
        guard let id = normalize(callID) else { return nil }
        var text = ""
        for (index, character) in id.enumerated() {
            if [8, 12, 16, 20].contains(index) { text.append("-") }
            text.append(character)
        }
        return UUID(uuidString: text)
    }

    static func string(from uuid: UUID) -> String {
        uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
