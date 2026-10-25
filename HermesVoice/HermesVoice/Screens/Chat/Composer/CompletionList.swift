import SwiftUI

/// The `/` and `@` popover above the composer: rows grouped under their headers; tapping one completes the token.
struct CompletionList: View {
    @ObservedObject var composer: ComposerModel

    private var groups: [(name: String?, rows: [CompletionRow])] {
        var out: [(name: String?, rows: [CompletionRow])] = []
        for row in composer.completions {
            if let last = out.last, last.name == row.group {
                out[out.count - 1].rows.append(row)
            } else {
                out.append((row.group, [row]))
            }
        }
        return out
    }

    var body: some View {
        if !composer.completions.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if let name = group.name, !name.isEmpty {
                            Text(name.uppercased())
                                .hermesText(.meta)
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.Text.tertiary)
                                .padding(.horizontal, Theme.Spacing.lg)
                                .padding(.top, Theme.Spacing.md)
                                .padding(.bottom, Theme.Spacing.xxs)
                        }
                        ForEach(group.rows) { row in
                            Button { composer.accept(row) } label: { label(row) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .hermesFloating(radius: Theme.Radius.menu)
            .accessibilityLabel(composer.trigger == .slash ? "Commands" : "References")
        }
    }

    private func label(_ row: CompletionRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(row.title)
                .hermesText(composer.trigger == .path ? .code : .caption)
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = row.detail, !detail.isEmpty {
                Text(detail)
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
