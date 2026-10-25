import SwiftUI
import UIKit

/// What transcript rows ask of the chat that shows them. The defaults do nothing, so rows also render in previews.
struct TranscriptActions {
    /// An error card's recovery button.
    var recover: (ErrorRecovery, TurnError) -> Void = { _, _ in }
    /// A `MEDIA:` chip; nil leaves the chip without a tap action.
    var openMedia: ((MediaRef) -> Void)?
}

private struct TranscriptActionsKey: EnvironmentKey {
    static let defaultValue = TranscriptActions()
}

extension EnvironmentValues {
    var transcriptActions: TranscriptActions {
        get { self[TranscriptActionsKey.self] }
        set { self[TranscriptActionsKey.self] = newValue }
    }
}

/// The transcript's rows with the desktop's block rhythm: prose to prose a paragraph apart, scaffolding (thinking,
/// tool rows) packed tight, a full block gap anywhere else, and more room before each prompt.
struct TranscriptList: View {
    let items: [TranscriptItem]

    var body: some View {
        let items = items.filter(\.isDrawn)
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                TranscriptRow(item: item)
                    .equatable()
                    .padding(.top, index == 0 ? 0 : Self.gap(items[index - 1], item))
                    .id(item.id)
            }
        }
    }

    static func gap(_ previous: TranscriptItem, _ item: TranscriptItem) -> CGFloat {
        switch (previous, item) {
        case (_, .user), (.user, _): return Theme.Spacing.xl
        case (.assistant, .assistant): return Theme.Spacing.paragraph
        case (.assistant, .media): return Theme.Spacing.sm
        default:
            return previous.isScaffold && item.isScaffold ? Theme.Spacing.scaffold : Theme.Spacing.turnBlock
        }
    }
}

extension TranscriptItem {
    /// False for a row that draws nothing, so it takes no gap either.
    var isDrawn: Bool {
        if case let .toolRun(run) = self { return run.calls.contains { !$0.drawsNothing } }
        return true
    }

    /// Thinking headers and tool rows: the quiet lines around the reply.
    var isScaffold: Bool {
        switch self {
        case .reasoning: return true
        case let .toolRun(run): return !(run.calls.count == 1 && run.calls[0].isFileEdit)
        default: return false
        }
    }
}

/// One transcript row. Equatable on its item, so a streaming row redraws alone.
struct TranscriptRow: View, Equatable {
    let item: TranscriptItem

    var body: some View {
        switch item {
        case let .user(message):
            UserBubble(message: message)
        case let .assistant(text):
            AssistantMarkdown(text: text).padding(.leading, Theme.Spacing.messageIndent)
        case let .reasoning(reasoning):
            ReasoningRow(reasoning: reasoning).padding(.leading, Theme.Spacing.messageIndent)
        case let .toolRun(run):
            ToolRunView(run: run).padding(.leading, Theme.Spacing.messageIndent)
        case let .subagent(delegation):
            DelegationCard(delegation: delegation).padding(.leading, Theme.Spacing.messageIndent)
        case let .system(note):
            SystemRow(note: note)
        case let .error(error):
            ErrorCard(error: error).padding(.leading, Theme.Spacing.messageIndent)
        case let .media(group):
            MediaChips(media: group.media).padding(.leading, Theme.Spacing.messageIndent)
        case let .changedFiles(files):
            ChangedFilesCard(changes: files).padding(.leading, Theme.Spacing.messageIndent)
        }
    }
}

// MARK: - Scaffolding

/// One scaffold line (`ScaffoldRow`): a label with optional leading glyph and trailing meta, a disclosure caret when
/// it opens, faded like the desktop's scaffolding until pressed.
struct ScaffoldRow<Label: View, Trailing: View>: View {
    var open = false
    var onToggle: (() -> Void)?
    @ViewBuilder var label: Label
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let row = HStack(spacing: Theme.Spacing.sm) {
            label
                .lineLimit(1)
                .hermesText(.tool)
                .foregroundStyle(Theme.Text.scaffold)
            if onToggle != nil {
                Image(systemName: Theme.Icon.disclosure)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Text.scaffoldMeta)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            Spacer(minLength: Theme.Spacing.xs)
            trailing
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.scaffoldMeta)
                .monospacedDigit()
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        if let onToggle {
            Button(action: { withAnimation(.easeInOut(duration: 0.18)) { onToggle() } }) { row }
                .buttonStyle(ScaffoldButtonStyle())
        } else {
            row.opacity(0.67)
        }
    }
}

extension ScaffoldRow where Trailing == EmptyView {
    init(open: Bool = false, onToggle: (() -> Void)? = nil, @ViewBuilder label: () -> Label) {
        self.init(open: open, onToggle: onToggle, label: label, trailing: { EmptyView() })
    }
}

/// Scaffolding rests at 67% and lifts while pressed (the desktop lifts on hover).
struct ScaffoldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 1 : 0.67)
    }
}

/// The fixed cell a scaffold line's leading glyph sits in, so labels share a left edge.
struct ScaffoldGlyph: View {
    let symbol: String
    var color: Color = Theme.Text.tertiary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .frame(width: Theme.IconSize.sm, height: Theme.IconSize.sm)
    }
}

/// A small spinner in the glyph cell, for work in progress.
struct ScaffoldSpinner: View {
    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: Theme.IconSize.sm, height: Theme.IconSize.sm)
    }
}

/// Seconds since `start`, ticking while shown (`ActivityTimerText`).
struct TranscriptElapsed: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
        }
    }

    /// "8s", "1m 05s", "1h 02m".
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }
}

/// A copy-to-clipboard icon that confirms with a check for a moment.
struct TranscriptCopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : Theme.Icon.copy)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Text.tertiary)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : label)
    }
}

/// Lays out chips left to right, wrapping onto new lines.
struct TranscriptFlowLayout: Layout {
    var spacing: CGFloat = Theme.Spacing.sm
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
