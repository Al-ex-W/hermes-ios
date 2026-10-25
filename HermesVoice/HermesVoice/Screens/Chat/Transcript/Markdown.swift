import SwiftUI

/// A markdown document split into the blocks the transcript draws. Inline markup (emphasis, code, links) stays in
/// each block's text for `AttributedString` to read. A fence still open while a reply streams runs to the end.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String?, code: String)
    case quote([MarkdownBlock])
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var parser = MarkdownParser(lines: markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return parser.blocks()
    }
}

struct MarkdownListItem: Hashable {
    /// Nesting depth, from the item's indentation.
    var level: Int
    /// "•", or the item's number ("3.").
    var marker: String
    var text: String
    /// A task item's box: false unchecked, true checked, nil for a plain item.
    var checked: Bool?
}

enum MarkdownAlignment: Hashable { case leading, center, trailing }

private struct MarkdownParser {
    let lines: [String]
    var index = 0

    init(lines: [String]) {
        self.lines = lines
    }

    mutating func blocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
            } else if let fence = Self.fence(line) {
                blocks.append(code(fence))
            } else if let heading = Self.heading(trimmed) {
                blocks.append(heading)
                index += 1
            } else if Self.isRule(trimmed) {
                blocks.append(.rule)
                index += 1
            } else if trimmed.hasPrefix(">") {
                blocks.append(quote())
            } else if Self.listItem(line) != nil {
                blocks.append(list())
            } else if index + 1 < lines.count, line.contains("|"), Self.delimiter(lines[index + 1]) != nil {
                blocks.append(table())
            } else {
                blocks.append(paragraph())
            }
        }
        return blocks
    }

    private mutating func code(_ fence: (marker: String, language: String?)) -> MarkdownBlock {
        index += 1
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.marker), trimmed.allSatisfy({ $0 == fence.marker.first }) {
                index += 1
                break
            }
            body.append(lines[index])
            index += 1
        }
        return .code(language: fence.language, code: body.joined(separator: "\n"))
    }

    private mutating func quote() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var rest = trimmed.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            body.append(String(rest))
            index += 1
        }
        var inner = MarkdownParser(lines: body)
        return .quote(inner.blocks())
    }

    private mutating func list() -> MarkdownBlock {
        var items: [MarkdownListItem] = []
        var indents: [Int] = []
        while index < lines.count {
            let line = lines[index]
            if let item = Self.listItem(line) {
                // A bullet list and a numbered one next to each other are two lists.
                if let first = items.first, let base = indents.first, item.indent <= base, (item.marker == "•") != (first.marker == "•") { break }
                while let last = indents.last, last > item.indent { indents.removeLast() }
                if indents.last.map({ $0 < item.indent }) ?? true { indents.append(item.indent) }
                var text = item.text
                var checked: Bool?
                if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                    checked = !text.hasPrefix("[ ]")
                    text = String(text.dropFirst(4))
                }
                items.append(MarkdownListItem(level: indents.count - 1, marker: item.marker, text: text, checked: checked))
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line ends the list unless an item (or an indented continuation) follows.
                guard index + 1 < lines.count, Self.listItem(lines[index + 1]) != nil || lines[index + 1].hasPrefix("  ") else { break }
                index += 1
            } else if (line.hasPrefix("  ") || line.hasPrefix("\t")) && !items.isEmpty, Self.fence(line) == nil {
                items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else if !items.isEmpty, Self.startsBlock(line, next: index + 1 < lines.count ? lines[index + 1] : nil) == false,
                      !lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                // A lazy continuation of the item above.
                items[items.count - 1].text += "\n" + line.trimmingCharacters(in: .whitespaces)
                index += 1
            } else {
                break
            }
        }
        return .list(items)
    }

    private mutating func table() -> MarkdownBlock {
        let header = Self.cells(lines[index])
        let alignments = Self.delimiter(lines[index + 1]) ?? []
        index += 2
        var rows: [[String]] = []
        while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            var row = Self.cells(lines[index])
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        return .table(header: header, alignments: (0..<header.count).map { alignments.indices.contains($0) ? alignments[$0] : .leading },
                      rows: rows)
    }

    private mutating func paragraph() -> MarkdownBlock {
        var body: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if !body.isEmpty, Self.startsBlock(line, next: index + 1 < lines.count ? lines[index + 1] : nil) { break }
            body.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return .paragraph(body.joined(separator: "\n"))
    }

    // MARK: Line kinds

    private static func startsBlock(_ line: String, next: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return fence(line) != nil || heading(trimmed) != nil || isRule(trimmed) || trimmed.hasPrefix(">") || listItem(line) != nil
            || (line.contains("|") && next.flatMap(delimiter) != nil)
    }

    private static func fence(_ line: String) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for mark in ["```", "~~~"] where trimmed.hasPrefix(mark) {
            let marker = String(trimmed.prefix { $0 == mark.first })
            let info = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            let language = info.split(separator: " ").first.map(String.init)
            return (marker, language?.isEmpty == false ? language : nil)
        }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes.count, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2)
            // "* * *" is a rule, not an item.
            if isRule(String(rest)) { return nil }
            return (indent, "•", String(text))
        }
        let digits = rest.prefix { $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        return (indent, "\(digits).", String(after.dropFirst(2)))
    }

    private static func delimiter(_ line: String) -> [MarkdownAlignment]? {
        let cells = cells(line)
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var alignments: [MarkdownAlignment] = []
        for cell in cells {
            let cell = cell.trimmingCharacters(in: .whitespaces)
            guard cell.count >= 1, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

// MARK: - Inline text

enum MarkdownInline {
    /// Inline markdown as styled text: emphasis, strikethrough, links (tappable), and code in the mono face on a
    /// soft fill. Text that doesn't parse is shown as written.
    static func attributed(_ text: String, codeSize: CGFloat = Theme.TextStyle.code.size) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var string = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in string.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                string[run.range].swiftUI.font = Font.system(size: codeSize, design: .monospaced)
                string[run.range].swiftUI.foregroundColor = Theme.Text.inlineCode
                string[run.range].swiftUI.backgroundColor = Theme.Fill.inlineCode
            }
        }
        for run in string.runs where run.link != nil {
            string[run.range].swiftUI.foregroundColor = Theme.primary
        }
        return string
    }
}

// MARK: - Views

/// A reply's markdown: headings, paragraphs, lists, code blocks with copy, tables, quotes and rules.
struct AssistantMarkdown: View {
    let text: AssistantText

    var body: some View {
        MarkdownView(markdown: text.markdown)
    }
}

struct MarkdownView: View {
    let markdown: String
    var style: Theme.TextStyle = .prose
    var color: Color = Theme.Text.primary

    var body: some View {
        let blocks = MarkdownBlock.parse(markdown)
        VStack(alignment: .leading, spacing: Theme.Spacing.paragraph) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, style: style, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: Theme.TextStyle
    let color: Color

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownInline.attributed(text))
                .font(.system(size: style.size * Self.headingScale(level), weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, level <= 2 ? Theme.Spacing.xs : 0)
                .textSelection(.enabled)
        case let .paragraph(text):
            Text(MarkdownInline.attributed(text))
                .hermesText(style)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .list(items):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        if let checked = item.checked {
                            Image(systemName: checked ? "checkmark.square" : "square")
                                .font(.system(size: style.size * 0.9))
                                .foregroundStyle(Theme.Text.tertiary)
                        } else {
                            Text(item.marker)
                                .hermesText(style)
                                .foregroundStyle(Theme.Text.tertiary)
                                .monospacedDigit()
                                .frame(minWidth: item.marker == "•" ? 8 : 16, alignment: .trailing)
                        }
                        Text(MarkdownInline.attributed(item.text))
                            .hermesText(style)
                            .foregroundStyle(color)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 16)
                }
            }
        case let .code(language, code):
            CodeBlock(language: language, code: code)
        case let .quote(blocks):
            HStack(spacing: Theme.Spacing.md) {
                Rectangle().fill(Theme.Hairline.primary).frame(width: 2)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block, style: style, color: Theme.Text.secondary)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .table(header, alignments, rows):
            MarkdownTable(header: header, alignments: alignments, rows: rows, style: style)
        case .rule:
            Rectangle().fill(Theme.Hairline.tertiary).frame(height: Theme.hairlineWidth).padding(.vertical, Theme.Spacing.xs)
        }
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.35
        case 2: return 1.2
        case 3: return 1.1
        default: return 1
        }
    }
}

/// A fenced code block: language label and copy on top, monospaced text that scrolls sideways.
struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
                Spacer()
                TranscriptCopyButton(text: code, label: "Copy code")
            }
            .padding(.leading, Theme.Spacing.md)
            .padding(.trailing, Theme.Spacing.xs)
            .padding(.vertical, 2)
            .hermesHairline()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .hermesText(.code)
                    .foregroundStyle(Theme.Text.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(Theme.Spacing.md)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
        .hermesOutline()
    }
}

/// A markdown table in a bordered grid; wide tables scroll sideways.
private struct MarkdownTable: View {
    let header: [String]
    let alignments: [MarkdownAlignment]
    let rows: [[String]]
    let style: Theme.TextStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column).fontWeight(.semibold)
                    }
                }
                .background(Theme.Fill.quinary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().overlay(Theme.Hairline.tertiary)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            self.cell(cell, column: column)
                        }
                    }
                }
            }
            .hermesOutline()
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment = alignments.indices.contains(column) ? alignments[column] : .leading
        return Text(MarkdownInline.attributed(text))
            .hermesText(.caption)
            .foregroundStyle(Theme.Text.primary)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .frame(minWidth: 60, maxWidth: 260, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .gridColumnAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }
}
