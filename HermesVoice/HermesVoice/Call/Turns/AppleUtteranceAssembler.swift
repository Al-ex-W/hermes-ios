import Foundation

/// Builds one utterance from Apple speech recognition results, across the pauses inside it. On-device recognition
/// closes a segment after a short pause of its own and then starts its text over with only the new words, and a
/// request can finish by itself (`isFinal`: the recognizer's own end of speech, or the one-minute limit of Apple's
/// servers) while the user's pause is still running. Neither ends the utterance or loses its words: text the
/// recognizer has let go of is kept as finished segments, in front of what it says next. Only the pause the user
/// set (counted from `lastWordsAt`), Send now, or a flush ends it.
struct AppleUtteranceAssembler {
    /// Segments the recognizer finished or dropped, oldest first.
    private(set) var segments: [String] = []
    /// The text of the segment the recognizer is working on; it may still change.
    private(set) var current = ""
    /// When the first words were heard.
    private(set) var startedAt: Date?
    /// When the words last changed: the pause that ends the utterance counts from here. A change of punctuation or
    /// capitals alone (the recognizer tidying up a segment it closes) doesn't move it.
    private(set) var lastWordsAt: Date?
    /// The recognizer closed the open segment. Whether it keeps that text or starts over shows in its next result.
    private var closed = false

    /// Everything heard so far: the finished segments, then the open one.
    var text: String {
        (segments + [current]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    var hasText: Bool { !segments.isEmpty || !current.isEmpty }

    /// A recognition result: the recognizer's whole text for its open segment. `closesSegment`: the result carries
    /// `speechRecognitionMetadata`, which marks the end of a segment. Returns whether `text` changed.
    @discardableResult
    mutating func result(_ text: String, closesSegment: Bool, at now: Date) -> Bool {
        let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = self.text
        if new.isEmpty {
            // The recognizer has nothing any more (it started over, or took a word back): what was heard stays.
            commit()
        } else {
            let startedOver = closed ? !Self.continues(current, new) : Self.restarted(current, new)
            if startedOver { commit() }
            current = new
        }
        closed = closesSegment && !current.isEmpty
        let after = self.text
        if startedAt == nil, !after.isEmpty { startedAt = now }
        if Self.letters(after) != Self.letters(before) { lastWordsAt = now }
        return after != before
    }

    /// The recognition request finished (`isFinal`), or is being replaced: the next request starts from nothing, so
    /// what this one heard becomes a finished segment. The pause goes on counting.
    mutating func requestEnded() {
        commit()
    }

    /// When the utterance ends for a pause of `pause` seconds, if no more words come; nil when nothing was heard.
    func silenceDue(pause: TimeInterval) -> Date? {
        hasText ? lastWordsAt?.addingTimeInterval(pause) : nil
    }

    /// Ends the utterance now and returns it; nil when nothing was heard.
    mutating func take() -> (text: String, startedAt: Date?)? {
        let taken = hasText ? (text, startedAt) : nil
        discard()
        return taken
    }

    /// Drops the utterance (listening paused): nothing is left to end, and no pause is counted.
    mutating func discard() {
        self = AppleUtteranceAssembler()
    }

    private mutating func commit() {
        if !current.isEmpty { segments.append(current) }
        current = ""
        closed = false
    }

    /// After the recognizer closed a segment: `new` still holds the closed text, so the recognizer kept it (as it
    /// did before it started segments over) and nothing must be added in front.
    private static func continues(_ old: String, _ new: String) -> Bool {
        letters(new).hasPrefix(letters(old))
    }

    /// With no sign that a segment closed: `new` is no revision of `old` but a text that started over. A revision
    /// keeps or grows the text; a restart begins with a word or two that have nothing to do with how `old` began.
    /// (A one-word text replaced by another single word can't be told apart from a revision, and counts as one.)
    private static func restarted(_ old: String, _ new: String) -> Bool {
        let was = words(old), now = words(new)
        guard let first = now.first, !was.isEmpty else { return false }
        return now.count * 2 <= was.count && first != was[0]
    }

    /// The text's letters and digits, lowercased: what stays the same when only punctuation, capitals or spacing change.
    private static func letters(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { letters(String($0)) }.filter { !$0.isEmpty }
    }
}
