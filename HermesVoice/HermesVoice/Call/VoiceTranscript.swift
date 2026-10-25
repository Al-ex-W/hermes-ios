import Foundation

/// How a chat shows what the Hermes Voice plugin puts into a call's conversation (the plugin's `inject.py`):
/// the user's turns (`[Voice] …`, `[Voice, cut off] …`, `[Voice, hung up] …`, each followed by a hint for Hermes)
/// and its call notices (`[Voice call started] …`, `[Voice call not answered] …`, `[Voice line not delivered: …] …`).
/// Hermes reads the markers and hints; the chat shows what was said, or a short notice.
enum VoiceTranscript {
    /// The hints the plugin appends to a turn, for Hermes only.
    static let hints = [
        "(Reply out loud with start_call; your text replies are not spoken.)",
        "(The user hung up, so the call is over; reply in text.)",
    ]

    /// What the user said on a call, with how the turn ended when it didn't end on its own ("cut off", "hung up"…);
    /// nil for anything else. Merged queue slots (several prompts joined by blank lines) are left as they are.
    static func spoken(_ text: String) -> String? {
        guard let turn = turn(text), !turn.said.isEmpty else { return nil }
        return turn.marker.map { "\(turn.said) (\($0))" } ?? turn.said
    }

    /// A short label for a call notice ("Voice call started", "Voice line not delivered"…), else nil.
    static func notice(_ text: String) -> String? {
        if text.hasPrefix("[Voice call ") || text.hasPrefix("[Voice line ") {
            return label(text.dropFirst())
        }
        // A turn with nothing heard, such as "[Voice, speech recognition failed: …]".
        if let turn = turn(text), turn.said.isEmpty, let marker = turn.marker {
            return "Voice: \(marker)"
        }
        return nil
    }

    private static func turn(_ text: String) -> (said: String, marker: String?)? {
        guard !text.contains("\n\n") else { return nil }
        var marker: String?
        var body: Substring
        if text.hasPrefix("[Voice] ") {
            body = text.dropFirst("[Voice] ".count)
        } else if text.hasPrefix("[Voice, "), let close = text.firstIndex(of: "]") {
            marker = label(text[text.index(text.startIndex, offsetBy: "[Voice, ".count)..<close])
            body = text[text.index(after: close)...]
        } else {
            return nil
        }
        var said = body.trimmingCharacters(in: .whitespaces)
        for hint in hints where said.hasSuffix(hint) {
            said = String(said.dropLast(hint.count)).trimmingCharacters(in: .whitespaces)
        }
        return (said, marker)
    }

    /// The text up to the closing bracket and before any ": detail".
    private static func label(_ text: Substring) -> String {
        let inside = text.prefix { $0 != "]" }
        return String(inside.split(separator: ":", maxSplits: 1).first ?? inside).trimmingCharacters(in: .whitespaces)
    }
}
