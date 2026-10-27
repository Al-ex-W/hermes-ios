import SwiftUI
import UIKit

/// The desktop's Artifacts page (`app/artifacts/index.tsx`): images, files and links recent sessions produced, with
/// All / Images / Files / Links tabs and their counts, a search, an image grid and a file table (here, rows), each
/// paged. Images, markdown and code preview in a sheet; anything can be shared or saved through the share sheet, and
/// every artifact opens the session that made it.
struct ArtifactsScreen: View {
    @StateObject private var store: ArtifactsStore
    let openSession: (_ sessionID: String, _ profile: String?) -> Void

    @State private var filter = ArtifactFilter.all
    @State private var query = ""
    @State private var imagePage = 1
    @State private var filePage = 1
    @State private var previewing: ArtifactRecord?
    @State private var web: WebPage?

    static let imagesPerPage = 24
    static let filesPerPage = 100

    /// `profile` is the sessions' profile, or `SidebarOptions.allProfiles` (what the desktop indexes).
    init(client: DashboardClient, profile: String = SidebarOptions.allProfiles,
         openSession: @escaping (_ sessionID: String, _ profile: String?) -> Void) {
        _store = StateObject(wrappedValue: ArtifactsStore(client: client, profile: profile))
        self.openSession = openSession
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $filter) {
                ForEach(ArtifactFilter.allCases) { tab in
                    Text(store.artifacts == nil ? tab.title : "\(tab.title) \(store.count(tab))").tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            content
        }
        .background(Theme.sidebar)
        .searchable(text: $query, prompt: "Search artifacts...")
        .navigationTitle("Artifacts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.refreshing {
                    ProgressView().accessibilityLabel("Refreshing artifacts")
                } else {
                    Button { Task { await store.refresh() } } label: { Image(systemName: Theme.Icon.retry) }
                        .accessibilityLabel("Refresh artifacts")
                }
            }
        }
        .task { if store.artifacts == nil { await store.refresh() } }
        .onChange(of: filter) { _, _ in resetPages() }
        .onChange(of: query) { _, _ in resetPages() }
        .onChange(of: store.artifacts) { _, _ in resetPages() }
        .sheet(item: $previewing) { artifact in
            ArtifactPreviewSheet(client: store.client, artifact: artifact) {
                previewing = nil
                openSession(artifact.sessionID, artifact.profile)
            }
        }
        .sheet(item: $web) { page in SafariSheet(url: page.url).ignoresSafeArea() }
        .failureAlert($store.failure)
        .alert("Artifacts failed to load", isPresented: Binding(get: { store.warning != nil }, set: { if !$0 { store.warning = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.warning ?? "")
        }
    }

    private func resetPages() {
        imagePage = 1
        filePage = 1
    }

    @ViewBuilder private var content: some View {
        if store.artifacts == nil {
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Indexing recent session artifacts").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        } else {
            let visible = store.visible(filter, query: query)
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("No artifacts found", systemImage: Theme.Icon.artifacts)
                } description: {
                    Text(query.isEmpty ? "Generated images and file outputs will appear here as sessions produce them."
                                       : "Try a broader search.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .refreshable { await store.refresh() }
            } else {
                list(visible)
            }
        }
    }

    private func list(_ visible: [ArtifactRecord]) -> some View {
        let images = visible.filter { $0.kind == .image }
        let files = visible.filter { $0.kind != .image }
        let imagePages = Self.pageCount(images.count, Self.imagesPerPage)
        let filePages = Self.pageCount(files.count, Self.filesPerPage)
        let shownImages = Self.page(images, min(imagePage, imagePages), Self.imagesPerPage)
        let shownFiles = Self.page(files, min(filePage, filePages), Self.filesPerPage)
        return List {
            if !images.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
                        ForEach(shownImages) { artifact in
                            ArtifactImageCard(client: store.client, artifact: artifact,
                                              open: { previewing = artifact },
                                              openChat: { openSession(artifact.sessionID, artifact.profile) })
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.md, bottom: 0, trailing: Theme.Spacing.md))
                    .listRowBackground(Color.clear)
                } header: {
                    ArtifactPager(total: images.count, page: $imagePage, pageSize: Self.imagesPerPage, itemLabel: "images")
                }
            }
            if !files.isEmpty {
                Section {
                    ForEach(shownFiles) { artifact in
                        ArtifactRow(artifact: artifact) { open(artifact) }
                            .swipeActions(edge: .trailing) {
                                Button { openSession(artifact.sessionID, artifact.profile) } label: {
                                    Label("Chat", systemImage: "bubble.left")
                                }
                                .tint(Theme.primary)
                            }
                            .contextMenu { menu(artifact) }
                    }
                } header: {
                    ArtifactPager(total: files.count, page: $filePage, pageSize: Self.filesPerPage,
                                  itemLabel: filter == .link ? "links" : filter == .file ? "files" : "items")
                }
                .hermesFormRows()
            }
        }
        .hermesForm()
        .refreshable { await store.refresh() }
    }

    @ViewBuilder private func menu(_ artifact: ArtifactRecord) -> some View {
        Button { open(artifact) } label: {
            Label(artifact.isLink ? "Open link" : "Preview", systemImage: artifact.isLink ? "safari" : "eye")
        }
        Button { UIPasteboard.general.string = artifact.value } label: {
            Label(artifact.isLink ? "Copy URL" : "Copy path", systemImage: Theme.Icon.copy)
        }
        if let url = artifact.url {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        Button { openSession(artifact.sessionID, artifact.profile) } label: { Label("Chat", systemImage: "bubble.left") }
    }

    private func open(_ artifact: ArtifactRecord) {
        if artifact.isLink, let url = artifact.url {
            web = WebPage(url: url)
        } else {
            previewing = artifact
        }
    }

    static func pageCount(_ total: Int, _ size: Int) -> Int { max(1, (total + size - 1) / size) }

    static func page<T>(_ items: [T], _ page: Int, _ size: Int) -> [T] {
        let start = (page - 1) * size
        guard start < items.count, start >= 0 else { return [] }
        return Array(items[start..<min(items.count, start + size)])
    }

    /// "1-24 of 50" (`pageRangeLabel`).
    static func rangeLabel(total: Int, page: Int, pageSize: Int) -> String {
        guard total > 0 else { return "0" }
        return "\((page - 1) * pageSize + 1)-\(min(total, page * pageSize)) of \(total)"
    }
}

/// A section's range label and page buttons.
private struct ArtifactPager: View {
    let total: Int
    @Binding var page: Int
    let pageSize: Int
    let itemLabel: String

    var body: some View {
        let pages = ArtifactsScreen.pageCount(total, pageSize)
        let current = min(page, pages)
        HStack {
            FormNote("\(ArtifactsScreen.rangeLabel(total: total, page: current, pageSize: pageSize)) \(itemLabel)")
            Spacer()
            if pages > 1 {
                Button { page = max(1, current - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(current <= 1)
                    .accessibilityLabel("Previous \(itemLabel) page")
                Text("\(current) / \(pages)").hermesText(.meta).foregroundStyle(Theme.Text.tertiary).monospacedDigit()
                Button { page = min(pages, current + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(current >= pages)
                    .accessibilityLabel("Next \(itemLabel) page")
            }
        }
        .buttonStyle(.borderless)
        .textCase(nil)
    }
}

/// An image artifact: the thumbnail (tap to preview), what and where it is, and the session that made it.
private struct ArtifactImageCard: View {
    let client: DashboardClient
    let artifact: ArtifactRecord
    let open: () -> Void
    let openChat: () -> Void

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                ZStack {
                    Theme.Fill.quinary
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().padding(Theme.Spacing.sm)
                    } else if failed {
                        Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(Theme.Text.quaternary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(artifact.label)")
            .hermesHairline()

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label("image", systemImage: "photo")
                    .font(.system(size: 10, weight: .medium))
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Text.tertiary)
                Text(artifact.label).hermesText(.caption).fontWeight(.medium).lineLimit(1)
                Text(artifact.value).hermesText(.meta).foregroundStyle(Theme.Text.tertiary).lineLimit(1).truncationMode(.middle)
                Text("\(artifact.sessionTitle) · \(artifact.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
                Button(action: openChat) { Label("Chat", systemImage: "bubble.left") }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(Theme.TextStyle.button.font)
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.widget))
        .hermesOutline(radius: Theme.Radius.widget)
        .contextMenu {
            Button(action: open) { Label("Preview", systemImage: "eye") }
            Button { UIPasteboard.general.string = artifact.value } label: {
                Label(artifact.url == nil ? "Copy path" : "Copy URL", systemImage: Theme.Icon.copy)
            }
            Button(action: openChat) { Label("Chat", systemImage: "bubble.left") }
        }
        .task(id: artifact.id) { await load() }
    }

    private func load() async {
        guard image == nil else { return }
        do {
            image = try await client.artifactThumbnail(artifact)
        } catch {
            if !error.isCancellation { failed = true }
        }
    }
}

/// A file or link artifact (the desktop's table row): name, location, and the session that made it.
private struct ArtifactRow: View {
    let artifact: ArtifactRecord
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: Theme.IconSize.sm))
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 26, height: 26)
                    .background(Theme.Fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.icon))
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(title).hermesText(.rowTitle).lineLimit(artifact.isLink ? 2 : 1)
                        if artifact.isLink {
                            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.Text.quaternary)
                        }
                    }
                    Text(artifact.location)
                        .font(artifact.isLink ? Theme.TextStyle.caption.font : Theme.TextStyle.code.font)
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(artifact.sessionTitle) · \(artifact.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Text.quaternary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(Theme.Text.primary)
        .accessibilityElement(children: .combine)
        .accessibilityHint(artifact.isLink ? "Opens the link" : "Previews the file")
    }

    private var icon: String {
        if artifact.isLink { return "link" }
        switch artifact.preview {
        case .markdown, .text: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .other:
            switch ArtifactScanner.pathExtension(artifact.value) {
            case "pdf": return "doc.richtext"
            case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": return "doc.zipper"
            case "mp3", "wav", "ogg", "opus", "m4a", "flac": return "waveform"
            case "mp4", "mov", "webm", "mkv", "avi": return "film"
            default: return "doc"
            }
        }
    }

    /// A link's slug as a title ("getting-started" → "Getting started"), else its host (`urlSlugTitleLabel`).
    private var title: String {
        guard artifact.isLink else { return artifact.label }
        return ArtifactRecord.slugTitle(artifact.value)
    }
}

extension ArtifactRecord {
    /// The last path segment of a URL as words, else its host.
    static func slugTitle(_ value: String) -> String {
        guard let components = URLComponents(string: value) else { return value }
        let host = components.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? value
        guard let last = components.path.split(separator: "/").last.map(String.init)?.removingPercentEncoding,
              !last.isEmpty else { return host }
        var words = (last as NSString).deletingPathExtension
            .replacingOccurrences(of: "[-_+]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty, words.rangeOfCharacter(from: .letters) != nil else { return host }
        words = words.prefix(1).uppercased() + words.dropFirst()
        return words
    }
}
