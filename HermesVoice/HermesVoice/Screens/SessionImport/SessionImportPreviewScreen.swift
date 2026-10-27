import SwiftUI

/// One conversation before it comes into Hermes (the importer's right pane): its last 40 messages, then "Continue in
/// Hermes", which copies it into the destination profile and opens the new session ("Open in Hermes" when that
/// profile already holds a copy).
struct SessionImportPreviewScreen: View {
    @ObservedObject var store: SessionImportStore
    let row: ForeignSessionRow
    let openSession: (_ sessionID: String, _ profile: String?) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                heading
                content
            }
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .navigationTitle(row.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.loadPreview(row.id, force: true) } } label: { Image(systemName: Theme.Icon.retry) }
                    .accessibilityLabel("Refresh preview")
                    .disabled(store.previews[row.id] == .loading)
            }
        }
        .task(id: "\(row.id)|\(store.destination ?? "")") { await store.loadPreview(row.id) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(row.displayTitle)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(row.label) · \(row.messages) messages")
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch store.previews[row.id] {
        case .loading?, nil:
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Opening preview").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xxl)
        case let .failed(message)?:
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: Theme.Icon.error)
            } description: {
                Text("The source may have moved or changed. Refresh the list and try again.\n\(message)")
            } actions: {
                Button("Retry") { Task { await store.loadPreview(row.id, force: true) } }
            }
        case let .loaded(preview)?:
            if preview.truncated == true {
                Text("Preview shortened for readability. The complete conversation is imported.")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            ForEach(Array((preview.messages ?? []).enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(message.role == "user" ? "You" : row.label)
                        .hermesText(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Text.secondary)
                    MarkdownView(markdown: message.content, style: .body)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var footer: some View {
        let preview = store.previews[row.id]?.result
        let importing = store.importing == row.id
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                Text(preview?.alreadyImported != nil
                     ? "This conversation is already in Hermes. Open your existing copy to continue."
                     : "Copies conversation text. Source files stay unchanged. Tool output and reasoning are not carried over.")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    Task { await continueSession() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        if importing { ProgressView().controlSize(.small) }
                        Text(importing ? "Importing…" : preview?.alreadyImported != nil ? "Open in Hermes" : "Continue in Hermes")
                        if !importing { Image(systemName: "arrow.right") }
                    }
                    .hermesText(.button)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.importing != nil || preview == nil)
            }
            if let error = store.importErrors[row.id] {
                Text("Could not import this conversation. \(error)")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.destructive)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.lg)
        .background(Theme.background)
        .hermesHairline(edges: .top)
    }

    private func continueSession() async {
        let profile = store.destination
        guard let result = await store.importSession(row.id) else { return }
        openSession(result.sessionId, profile)
    }
}
