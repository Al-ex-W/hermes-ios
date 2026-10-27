import SwiftUI
import UIKit

/// One rendered diff row (`DiffLine` in the desktop's `diff-lines.tsx`).
struct WorkspaceDiffLine: Hashable {
    enum Kind: Hashable { case add, context, remove }

    var kind: Kind
    var text: String
    /// 1-based line numbers in the new and old file; absent on the other side of an add or remove, and on the blank
    /// row between hunks.
    var newNumber: Int?
    var oldNumber: Int?

    init(kind: Kind, text: String, newNumber: Int? = nil, oldNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.newNumber = newNumber
        self.oldNumber = oldNumber
    }
}

/// The desktop's unified-diff parse: the git file header and `@@` lines are dropped (a blank row stays between
/// hunks), the `+`/`-`/space gutter is stripped so changes read by color, and line numbers are tracked from each hunk
/// header.
enum WorkspaceDiffParser {
    private struct Hunk {
        var oldStart: Int
        var newStart: Int
        var lines: [(kind: WorkspaceDiffLine.Kind, text: String)] = []
    }

    private static let headerPrefixes = ["diff --git", "index ", "--- ", "+++ ", "similarity ", "rename ", "new file", "deleted file"]
    private static let hunkHeader = try! NSRegularExpression(pattern: #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)

    static func kind(_ line: Substring) -> WorkspaceDiffLine.Kind {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return .add }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return .remove }
        return .context
    }

    /// The line without its `+`/`-`/space marker; indentation after it stays.
    static func stripMarker(_ line: Substring) -> String {
        if kind(line) != .context || line.hasPrefix(" ") { return String(line.dropFirst()) }
        return String(line)
    }

    /// Hermes' own `a/path → b/path` header line.
    private static func isArrowHeader(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("→"), let first = trimmed.first, !first.isWhitespace, !"+-@".contains(first) else { return false }
        return trimmed.range(of: #"^\S.*→\s*\S+$"#, options: .regularExpression) != nil
    }

    /// The diff with its leading file-header zone removed (up to the first hunk).
    static func stripFileHeaders(_ diff: String) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var start = 0
        while start < lines.count {
            let line = lines[start]
            if line.hasPrefix("@@") { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty || isArrowHeader(line)
                || headerPrefixes.contains(where: { line.hasPrefix($0) }) {
                start += 1
                continue
            }
            break
        }
        return lines[start...].joined(separator: "\n")
    }

    private static func hunks(_ diff: String) -> [Hunk] {
        var hunks: [Hunk] = []
        var active = false
        for line in stripFileHeaders(diff).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                let text = String(line)
                guard let match = hunkHeader.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let old = Range(match.range(at: 1), in: text).flatMap({ Int(text[$0]) }),
                      let new = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }) else {
                    active = false
                    continue
                }
                hunks.append(Hunk(oldStart: old, newStart: new))
                active = true
                continue
            }
            guard active, !line.hasPrefix("\\") else { continue }
            hunks[hunks.count - 1].lines.append((kind(line), stripMarker(line)))
        }
        return hunks
    }

    /// The compact view: changed hunks only.
    static func parse(_ diff: String) -> [WorkspaceDiffLine] {
        let hunks = hunks(diff)
        guard !hunks.isEmpty else {
            // Not a hunked diff: show it as it is, tinted by marker.
            return stripFileHeaders(diff).split(separator: "\n", omittingEmptySubsequences: false)
                .map { WorkspaceDiffLine(kind: kind($0), text: stripMarker($0)) }
        }
        var out: [WorkspaceDiffLine] = []
        for hunk in hunks {
            var old = hunk.oldStart, new = hunk.newStart
            if !out.isEmpty { out.append(WorkspaceDiffLine(kind: .context, text: "")) }
            for line in hunk.lines {
                switch line.kind {
                case .add:
                    out.append(WorkspaceDiffLine(kind: .add, text: line.text, newNumber: new))
                    new += 1
                case .remove:
                    out.append(WorkspaceDiffLine(kind: .remove, text: line.text, oldNumber: old))
                    old += 1
                case .context:
                    out.append(WorkspaceDiffLine(kind: .context, text: line.text, newNumber: new, oldNumber: old))
                    old += 1
                    new += 1
                }
            }
        }
        return out
    }

    /// The whole current file with the diff laid over it (the preview's diff view): every line of `fullText` keeps
    /// its real line number, added ones are tinted, and removed rows sit where they were.
    static func parseFullFile(_ diff: String, fullText: String) -> [WorkspaceDiffLine] {
        let hunks = hunks(diff)
        let fullLines = fullText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !hunks.isEmpty else {
            return fullLines.enumerated().map { WorkspaceDiffLine(kind: .context, text: $1, newNumber: $0 + 1, oldNumber: $0 + 1) }
        }
        var added = Set<Int>()
        var oldByNew: [Int: Int] = [:]
        var removals: [Int: [WorkspaceDiffLine]] = [:]
        for hunk in hunks {
            var old = hunk.oldStart, new = hunk.newStart
            for line in hunk.lines {
                switch line.kind {
                case .add:
                    added.insert(new)
                    new += 1
                case .remove:
                    let anchor = max(1, min(new, fullLines.count + 1))
                    removals[anchor, default: []].append(WorkspaceDiffLine(kind: .remove, text: line.text, oldNumber: old))
                    old += 1
                case .context:
                    oldByNew[new] = old
                    old += 1
                    new += 1
                }
            }
        }
        var out: [WorkspaceDiffLine] = []
        for (index, text) in fullLines.enumerated() {
            let number = index + 1
            out += removals[number] ?? []
            out.append(WorkspaceDiffLine(kind: added.contains(number) ? .add : .context, text: text,
                                         newNumber: number, oldNumber: oldByNew[number]))
        }
        out += removals[fullLines.count + 1] ?? []
        return out
    }

    /// `+added` and `-removed` counted from the rows.
    static func counts(_ lines: [WorkspaceDiffLine]) -> (added: Int, removed: Int) {
        lines.reduce(into: (0, 0)) { total, line in
            if line.kind == .add { total.0 += 1 } else if line.kind == .remove { total.1 += 1 }
        }
    }
}

/// The desktop's diff styling: a 2 pt gutter accent and a 12% tint per change, add/remove text in the diff colors,
/// monospaced rows that scroll sideways together; optional new-file line numbers.
struct WorkspaceDiffView: View {
    let lines: [WorkspaceDiffLine]
    var showLineNumbers = false

    static let fontSize: CGFloat = 11.2
    static let rowHeight: CGFloat = 18

    var body: some View {
        let shown = Array(lines.prefix(WorkspaceLimits.diffLines))
        let width = Self.contentWidth(shown)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    WorkspaceDiffRow(line: line, width: width, showLineNumbers: showLineNumbers)
                }
                if lines.count > shown.count {
                    Text("\(lines.count - shown.count) more lines not shown")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .padding(Theme.Spacing.md)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .font(.system(size: Self.fontSize, design: .monospaced))
        .background(Theme.card)
        .overlay(alignment: .trailing) { OverviewRuler(lines: shown) }
    }

    /// Wide enough for the longest row, so every tint spans the scrolled width.
    static func contentWidth(_ lines: [WorkspaceDiffLine]) -> CGFloat {
        let longest = lines.reduce(0) { max($0, $1.text.count) }
        let glyph = ("M" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)]).width
        return min(CGFloat(longest) * glyph + 64, 40_000)
    }

    static func border(_ kind: WorkspaceDiffLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.Semantic.green
        case .remove: return Theme.Semantic.red
        case .context: return .clear
        }
    }

    static func background(_ kind: WorkspaceDiffLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.Semantic.diffAddBackground
        case .remove: return Theme.Semantic.diffRemoveBackground
        case .context: return .clear
        }
    }

    static func foreground(_ kind: WorkspaceDiffLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.Semantic.diffAddForeground
        case .remove: return Theme.Semantic.diffRemoveForeground
        case .context: return Theme.Text.secondary
        }
    }

    static func accessibilityLabel(_ line: WorkspaceDiffLine) -> String {
        switch line.kind {
        case .add: return "Added: \(line.text)"
        case .remove: return "Removed: \(line.text)"
        case .context: return line.text
        }
    }
}

/// One diff row: the gutter accent, an optional line number, the text in its tint.
struct WorkspaceDiffRow: View {
    let line: WorkspaceDiffLine
    let width: CGFloat
    var showLineNumbers = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(WorkspaceDiffView.border(line.kind)).frame(width: 2)
            if showLineNumbers {
                Text(line.newNumber.map(String.init) ?? "")
                    .foregroundStyle(Theme.Text.quaternary)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.trailing, Theme.Spacing.md)
            }
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(WorkspaceDiffView.foreground(line.kind))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .font(.system(size: WorkspaceDiffView.fontSize, design: .monospaced))
        .frame(minWidth: width, minHeight: WorkspaceDiffView.rowHeight, alignment: .leading)
        .background(WorkspaceDiffView.background(line.kind))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(WorkspaceDiffView.accessibilityLabel(line))
    }
}

/// The overview strip on the diff's right edge: a green or red tick per run of changes, placed by line fraction.
private struct OverviewRuler: View {
    let lines: [WorkspaceDiffLine]

    var body: some View {
        let runs = Self.runs(lines)
        if !runs.isEmpty {
            GeometryReader { geometry in
                let height = min(geometry.size.height, CGFloat(lines.count) * 18)
                ZStack(alignment: .top) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        Rectangle()
                            .fill(run.kind == .add ? Theme.Semantic.green : Theme.Semantic.red)
                            .frame(height: max(2, height * run.size))
                            .offset(y: height * run.start)
                    }
                }
                .frame(width: 6, height: height, alignment: .top)
            }
            .frame(width: 6)
            .opacity(0.8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Consecutive same-kind changed rows coalesced, as fractions of the whole.
    static func runs(_ lines: [WorkspaceDiffLine]) -> [(kind: WorkspaceDiffLine.Kind, start: CGFloat, size: CGFloat)] {
        let total = CGFloat(max(lines.count, 1))
        var runs: [(WorkspaceDiffLine.Kind, CGFloat, CGFloat)] = []
        var index = 0
        while index < lines.count {
            let kind = lines[index].kind
            guard kind != .context else { index += 1; continue }
            var end = index + 1
            while end < lines.count, lines[end].kind == kind { end += 1 }
            runs.append((kind, CGFloat(index) / total, CGFloat(end - index) / total))
            index = end
        }
        return runs
    }
}

/// `+12 −3` in the diff colors (`DiffCount`).
struct WorkspaceDiffCount: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if added > 0 { Text("+\(added)").foregroundStyle(Theme.Semantic.diffAddForeground) }
            if removed > 0 { Text("−\(removed)").foregroundStyle(Theme.Semantic.diffRemoveForeground) }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}
