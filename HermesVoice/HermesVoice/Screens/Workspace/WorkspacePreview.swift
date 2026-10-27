import SwiftUI
import UIKit

/// A file from the tree (the desktop's preview pane): source with line numbers, markdown rendered (or its source),
/// an image to zoom, anything else as a row to open or share. A changed file can show its diff against HEAD over
/// the whole file. Only the first 512 KB of a text file come over; sharing downloads all of it.
struct WorkspaceFilePreview: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var files: WorkspaceFilesModel
    let entry: WorkspaceEntry

    @State private var text: WorkspaceTextFile?
    @State private var image: UIImage?
    @State private var error: String?
    @State private var loading = true
    @State private var showsSource = false
    @State private var showsChanges = false
    @State private var diff: String?
    @State private var diffLoading = false

    private var kind: WorkspaceFileKind { WorkspaceFileKind(path: entry.path) }
    private var changed: Bool { files.changeKind(entry.path) != nil }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar { toolbar }
            .task(id: entry.path) { await load() }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().accessibilityLabel("Loading preview")
        } else if let error {
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Download") { Task { await model.share(entry.path) } }
                    .buttonStyle(.bordered)
            }
        } else if let image {
            WorkspaceZoomableImage(image: image)
        } else if let text, !text.binary {
            VStack(spacing: 0) {
                header(text)
                if showsChanges {
                    changes(text)
                } else if kind == .markdown, !showsSource {
                    ScrollView {
                        MarkdownView(markdown: text.text)
                            .textSelection(.enabled)
                            .padding(Theme.Spacing.xl)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    WorkspaceDiffView(lines: WorkspaceDiffParser.parseFullFile("", fullText: text.text), showLineNumbers: true)
                }
            }
        } else {
            fileRow
        }
    }

    private func header(_ file: WorkspaceTextFile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(model.relativePath(entry.path))
                    .font(Theme.TextStyle.code.font)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text([file.language == "text" ? nil : file.language, ByteSize.format(Double(file.byteSize))]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.quaternary)
            }
            if file.truncated {
                Text("Showing the first \(ByteSize.format(Double(WorkspaceLimits.previewBytes))) of "
                    + "\(ByteSize.format(Double(file.byteSize))). Download to get the whole file.")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .hermesHairline()
    }

    @ViewBuilder private func changes(_ file: WorkspaceTextFile) -> some View {
        if diffLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = file.truncated ? WorkspaceDiffParser.parse(diff) : WorkspaceDiffParser.parseFullFile(diff, fullText: file.text)
            WorkspaceDiffView(lines: lines, showLineNumbers: true)
        } else {
            ContentUnavailableView("No diff to show", systemImage: "checkmark.circle",
                                   description: Text("The file matches the last commit."))
        }
    }

    /// Anything the phone can't show inline: what it is, and how to get it.
    private var fileRow: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: kind == .pdf ? "doc.text.image" : "doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Text.tertiary)
            Text(entry.name).hermesText(.rowTitle).multilineTextAlignment(.center)
            Text(model.relativePath(entry.path))
                .font(Theme.TextStyle.code.font)
                .foregroundStyle(Theme.Text.tertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let text, text.byteSize > 0 {
                Text(ByteSize.format(Double(text.byteSize))).hermesText(.caption).foregroundStyle(Theme.Text.quaternary)
            }
            HStack(spacing: Theme.Spacing.md) {
                Button { Task { await model.openQuickLook(entry.path) } } label: { Label("Open", systemImage: "eye") }
                    .buttonStyle(.bordered)
                Button { Task { await model.share(entry.path) } } label: { Label("Download", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(model.downloading)
        }
        .padding(Theme.Spacing.xxl)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if kind == .markdown, text != nil, !showsChanges {
                Button { showsSource.toggle() } label: {
                    Image(systemName: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityLabel(showsSource ? "Show rendered" : "Show source")
            }
            if changed, let text, !text.binary {
                Button {
                    showsChanges.toggle()
                    if showsChanges, diff == nil { Task { await loadDiff() } }
                } label: {
                    Image(systemName: showsChanges ? "doc.plaintext" : "plusminus")
                }
                .accessibilityLabel(showsChanges ? "Show file" : "Show changes")
            }
            if model.downloading {
                ProgressView()
            } else {
                Button { Task { await model.share(entry.path) } } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Download or share")
            }
            Menu {
                Button { model.addToChat(path: entry.path, isDirectory: false) } label: {
                    Label("Add to chat", systemImage: "text.badge.plus")
                }
                Divider()
                Button { model.copy(entry.path) } label: { Label("Copy path", systemImage: Theme.Icon.copy) }
                Button { model.copy(model.relativePath(entry.path)) } label: {
                    Label("Copy relative path", systemImage: "doc.on.clipboard")
                }
                if let text = text?.text, !(self.text?.binary ?? true) {
                    Button { model.copy(text, label: "Copied") } label: { Label("Copy content", systemImage: "doc.on.doc") }
                }
                Button { Task { await model.openQuickLook(entry.path) } } label: { Label("Open in Quick Look", systemImage: "eye") }
                Divider()
                Button(role: .destructive) {
                    model.request(.deleteEntry(path: entry.path, isDirectory: false))
                } label: { Label("Delete", systemImage: Theme.Icon.delete) }
            } label: {
                Image(systemName: Theme.Icon.more)
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        error = nil
        do {
            switch kind {
            case .image:
                let data = try await model.client.workspaceFileData(entry.path, profile: model.context.profile,
                                                                     sessionID: model.context.sessionID)
                guard let decoded = UIImage(data: data) else { throw DashboardError.rpc("The image can't be shown on this phone.") }
                image = decoded
            case .pdf:
                return
            case .markdown, .text:
                text = try await model.client.workspaceReadText(entry.path, profile: model.context.profile)
            }
        } catch DashboardError.http(413, _) {
            error = "\(entry.name) is too large to preview. Download it to open it."
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }

    private func loadDiff() async {
        diffLoading = true
        defer { diffLoading = false }
        guard let repo = await model.review.resolveRepo() else {
            diff = ""
            return
        }
        do {
            diff = try await model.client.gitFileDiff(repo, file: entry.path)
        } catch {
            if !error.isCancellation {
                diff = ""
                model.failure = error.dashboardMessage
            }
        }
    }
}

/// An image that fits the pane and zooms with a pinch or a double tap.
struct WorkspaceZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width * scale * pinch, height: geometry.size.height * scale * pinch)
            }
            .gesture(MagnificationGesture()
                .updating($pinch) { value, state, _ in state = value }
                .onEnded { value in scale = min(max(scale * value, 1), 6) })
            .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5 } }
        }
        .accessibilityLabel("Image")
        .accessibilityAddTraits(.isImage)
    }
}
