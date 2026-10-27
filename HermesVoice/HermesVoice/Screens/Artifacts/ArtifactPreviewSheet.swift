import QuickLook
import SwiftUI
import UIKit

/// One artifact in a sheet: an image to zoom, markdown rendered (or its source), code and text as source, anything
/// else as a file row. The share button downloads the whole file from the host and offers the share sheet, which
/// saves to Files, AirDrops or opens it elsewhere.
struct ArtifactPreviewSheet: View {
    let client: DashboardClient
    let artifact: ArtifactRecord
    /// Opens the session that made it (the sheet closes first).
    let openChat: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var text: HostTextFile?
    @State private var showsSource = false
    @State private var error: String?
    @State private var failure: String?
    @State private var downloading = false
    @State private var shared: SharedFile?
    @State private var quickLook: URL?

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationTitle(artifact.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        if artifact.preview == .markdown, text != nil {
                            Button { showsSource.toggle() } label: {
                                Image(systemName: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                            }
                            .accessibilityLabel(showsSource ? "Show rendered" : "Show source")
                        }
                        if downloading {
                            ProgressView()
                        } else {
                            Button { Task { await share() } } label: { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Share or save")
                        }
                        Menu {
                            Button { UIPasteboard.general.string = artifact.value } label: {
                                Label(artifact.url == nil ? "Copy path" : "Copy URL", systemImage: Theme.Icon.copy)
                            }
                            if let text = text?.text {
                                Button { UIPasteboard.general.string = text } label: {
                                    Label("Copy content", systemImage: "doc.on.clipboard")
                                }
                            }
                            Button {
                                dismiss()
                                openChat()
                            } label: {
                                Label("Chat", systemImage: "bubble.left")
                            }
                        } label: {
                            Image(systemName: Theme.Icon.more)
                        }
                        .accessibilityLabel("More")
                    }
                }
        }
        .task { await load() }
        .opsShareSheet($shared)
        .failureAlert($failure)
        .quickLookPreview($quickLook)
        .onChange(of: quickLook) { old, new in
            if let old, new == nil { DashboardClient.removeTemporaryFile(old) }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView {
                Label("Can't preview \(artifact.label)", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Share or save") { Task { await share() } }
            }
        } else {
            switch artifact.preview {
            case .image:
                if let image {
                    ZoomableImage(image: image)
                } else {
                    ProgressView()
                }
            case .markdown, .code, .text:
                if let text {
                    textContent(text)
                } else {
                    ProgressView()
                }
            case .other:
                fileRow
            }
        }
    }

    @ViewBuilder private func textContent(_ file: HostTextFile) -> some View {
        if file.binary {
            fileRow
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if file.truncated {
                        Label("Showing the start of \(ByteSize.format(Double(file.byteSize))). Share to get the whole file.",
                              systemImage: "info.circle")
                            .hermesText(.caption)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                    if artifact.preview == .markdown, !showsSource {
                        MarkdownView(markdown: file.text)
                            .textSelection(.enabled)
                    } else {
                        ScrollView(.horizontal) {
                            Text(file.text)
                                .hermesText(.code)
                                .foregroundStyle(Theme.Text.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                        }
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Anything the app can't render: what it is, where, and how to get it.
    private var fileRow: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.Text.tertiary)
            Text(artifact.label).hermesText(.rowTitle).multilineTextAlignment(.center)
            Text(artifact.value)
                .font(Theme.TextStyle.code.font)
                .foregroundStyle(Theme.Text.tertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Text("\(artifact.sessionTitle) · \(artifact.timestamp.formatted(date: .abbreviated, time: .shortened))")
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.quaternary)
            HStack(spacing: Theme.Spacing.md) {
                if artifact.isHostFile {
                    Button { Task { await openQuickLook() } } label: { Label("Open", systemImage: "eye") }
                        .buttonStyle(.bordered)
                }
                Button { Task { await share() } } label: { Label("Share or save", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(downloading)
        }
        .padding(Theme.Spacing.xxl)
    }

    // MARK: Loading

    private func load() async {
        do {
            switch artifact.preview {
            case .image:
                let data = try await client.artifactImageData(artifact)
                guard let decoded = UIImage(data: data) else { throw DashboardError.rpc("The image can't be shown.") }
                image = decoded
            case let .code(language) where !artifact.isHostFile:
                // A web or inline SVG: its bytes, read as source.
                let data = try await client.artifactImageData(artifact)
                text = HostTextFile(response: ["text": String(decoding: data, as: UTF8.self), "language": language,
                                               "byteSize": data.count])
            case .markdown, .code, .text:
                text = try await client.hostTextFile(artifact)
            case .other:
                return
            }
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }

    /// A web URL shares as itself; anything else is downloaded first.
    private func share() async {
        if let url = artifact.url {
            shared = SharedFile(url: url)
            return
        }
        guard let file = await download() else { return }
        shared = SharedFile(url: file)
    }

    private func openQuickLook() async {
        if let file = await download() { quickLook = file }
    }

    private func download() async -> URL? {
        downloading = true
        defer { downloading = false }
        do {
            if artifact.value.hasPrefix("data:") {
                guard let data = DashboardClient.decodeDataURL(artifact.value) else { throw DashboardError.rpc("The image can't be read.") }
                return try DashboardClient.temporaryFile(data, name: "image.png")
            }
            return try await client.downloadHostFile(artifact)
        } catch {
            if !error.isCancellation { failure = "Download failed. \(error.dashboardMessage)" }
            return nil
        }
    }
}

/// An image that fits the sheet and zooms with a pinch or a double tap.
private struct ZoomableImage: View {
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
