import SwiftUI

/// Lines that aren't a turn (`SystemMessage`): session notices centered and small, slash output, steer notes,
/// background results that open to their report, review saves, call markers and "Response stopped".
struct SystemRow: View {
    let note: SystemNote
    @State private var open = false

    var body: some View {
        switch note.kind {
        case .notice:
            centered(Text(note.text))
        case let .slash(command):
            if note.text.contains("\n") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Text.tertiary)
                    Text(note.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.Text.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.xxl)
            } else {
                centered(Text(command).font(.system(size: 11, design: .monospaced))
                    + Text("  ·  ").foregroundStyle(Theme.Text.quaternary)
                    + Text(note.text))
            }
        case .steer:
            centered(Text(Image(systemName: "location.north.circle")) + Text(" steered") + Text("  ·  ").foregroundStyle(Theme.Text.quaternary)
                + Text(note.text))
        case let .background(report, process):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ScaffoldRow(open: open, onToggle: report == nil ? nil : { open.toggle() }) {
                    HStack(spacing: Theme.Spacing.sm) {
                        if process { ScaffoldGlyph(symbol: Theme.Icon.terminal) }
                        Text(note.text)
                    }
                }
                if open, let report {
                    ScrollView(.vertical) {
                        if process {
                            Text(report)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.Text.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownView(markdown: report, style: .caption)
                        }
                    }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, Theme.Spacing.messageIndent)
        case let .review(label):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                ScaffoldGlyph(symbol: "brain", color: Theme.Semantic.purple)
                Text(label).foregroundStyle(Theme.Semantic.purple).fontWeight(.medium)
                if !note.text.isEmpty {
                    Text(note.text).foregroundStyle(Theme.Semantic.purple.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .hermesText(.tool)
            .padding(.leading, Theme.Spacing.messageIndent)
        case .call:
            Label(note.text, systemImage: "phone.fill")
                .hermesText(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Semantic.green)
                .frame(maxWidth: .infinity)
        case .stopped:
            Label(note.text, systemImage: Theme.Icon.stop)
                .labelStyle(TightLabelStyle())
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.tertiary)
                .padding(.leading, Theme.Spacing.messageIndent)
        case .warning:
            Label(note.text, systemImage: Theme.Icon.warning)
                .labelStyle(TightLabelStyle())
                .hermesText(.caption)
                .foregroundStyle(Theme.Semantic.attention)
                .padding(.leading, Theme.Spacing.messageIndent)
        }
    }

    private func centered(_ text: Text) -> some View {
        text
            .hermesText(.meta)
            .foregroundStyle(Theme.Text.tertiary)
            .multilineTextAlignment(note.text.contains("\n") ? .leading : .center)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.xxl)
    }
}

/// A label whose glyph sits close to its text.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}
