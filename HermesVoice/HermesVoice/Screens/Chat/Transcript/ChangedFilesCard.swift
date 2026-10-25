import SwiftUI

/// "N files changed" closing a turn (`ChangedFilesCard`): one row per edited file with its +/-; a row opens that
/// file's diffs in place.
struct ChangedFilesCard: View {
    let changes: ChangedFiles
    @State private var openPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(changes.files.count == 1 ? "1 file changed" : "\(changes.files.count) files changed")
                .foregroundStyle(Theme.Text.primary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(changes.files) { file in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { openPath = openPath == file.path ? nil : file.path }
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.Text.tertiary)
                            Text(file.name).foregroundStyle(Theme.Text.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Theme.Spacing.sm)
                            HStack(spacing: Theme.Spacing.xs) {
                                if file.added > 0 { Text("+\(file.added)").foregroundStyle(Theme.Semantic.diffAddForeground) }
                                if file.removed > 0 { Text("−\(file.removed)").foregroundStyle(Theme.Semantic.diffRemoveForeground) }
                            }
                            .font(.system(size: 10, design: .monospaced))
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs + 1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Copy path", systemImage: Theme.Icon.copy) { UIPasteboard.general.string = file.path }
                    }
                    if openPath == file.path {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text(file.path).hermesText(.meta).foregroundStyle(Theme.Text.tertiary).textSelection(.enabled)
                            ForEach(Array(file.diffs.enumerated()), id: \.offset) { _, diff in DiffView(diff: diff) }
                        }
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.bottom, Theme.Spacing.sm)
                    }
                }
            }
        }
        .hermesText(.tool)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hermesCard()
    }
}
