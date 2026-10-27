import SwiftUI
import UniformTypeIdentifiers

// The Files tab (`right-sidebar/index.tsx`, `files/tree.tsx`, `file-actions.tsx`): the session's folder as a
// drill-down list with breadcrumbs. Folders push, files open a preview. Each row's menu adds it to the chat, copies
// its path or downloads it. The desktop hides reveal, rename and delete on a remote backend, which the phone always
// is, and its tree has no upload: the host's `/api/files` writes act on the dashboard's own disk, not the profile's
// workspace (an SSH backend's files live on another machine), so the tab doesn't write either.

/// The Files tab's root: the session's folder, or "No project open".
struct WorkspaceFilesRoot: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var files: WorkspaceFilesModel

    var body: some View {
        if let root = files.root {
            WorkspaceFolderContent(model: model, files: files, folder: root)
                .task(id: root) {
                    await files.load(root)
                    await files.refreshChanges()
                }
        } else {
            WorkspaceNoProject(model: model, files: files)
        }
    }
}

/// A pushed folder: breadcrumbs over its listing.
struct WorkspaceFolderView: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var files: WorkspaceFilesModel
    let folder: String

    var body: some View {
        WorkspaceFolderContent(model: model, files: files, folder: folder)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let root = files.root {
                    WorkspaceBreadcrumbs(model: model, root: root, path: folder)
                }
            }
            .background(Theme.background)
            .navigationTitle(WorkspacePath.name(folder))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar { WorkspaceFilesToolbar(model: model, files: files, folder: folder) }
            .task(id: folder) { await files.load(folder) }
    }
}

/// The breadcrumb trail from the project folder down to the one on screen; a tap goes back to that level.
struct WorkspaceBreadcrumbs: View {
    @ObservedObject var model: WorkspacePanelModel
    let root: String
    let path: String

    var body: some View {
        let crumbs = WorkspacePath.crumbs(root: root, path: path)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.Text.quaternary)
                                .accessibilityHidden(true)
                        }
                        let last = index == crumbs.count - 1
                        Button { model.open(folder: crumb.path) } label: {
                            Text(crumb.name)
                                .hermesText(.label)
                                .foregroundStyle(last ? Theme.Text.primary : Theme.Text.tertiary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(last)
                        .id(index)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
            }
            .onAppear { proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
        }
        .background(Theme.background)
        .hermesHairline()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }
}

/// A folder's listing in its states: loading, unreadable, empty, entries.
struct WorkspaceFolderContent: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var files: WorkspaceFilesModel
    let folder: String

    var body: some View {
        Group {
            switch files.state(folder) {
            case nil, .loading?:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading files")
            case let .failed(message)?:
                ContentUnavailableView {
                    Label("Unreadable", systemImage: Theme.Icon.warning)
                } description: {
                    Text("Could not read this folder. \(message)")
                } actions: {
                    Button("Try again") { Task { await files.load(folder, force: true) } }
                        .buttonStyle(.bordered)
                }
            case let .loaded(entries)?:
                if entries.isEmpty {
                    ScrollView {
                        ContentUnavailableView("Empty", systemImage: "folder", description: Text("This folder is empty."))
                            .padding(.top, Theme.Spacing.xxl)
                    }
                } else {
                    List {
                        ForEach(entries) { entry in
                            WorkspaceEntryRow(model: model, files: files, entry: entry)
                        }
                        .listRowBackground(Theme.background)
                        .listRowSeparatorTint(Theme.Hairline.quaternary)
                        .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.lg, bottom: 0, trailing: Theme.Spacing.lg))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 34)
                }
            }
        }
        .refreshable { await files.refresh([folder]) }
    }
}

/// One file or folder: icon, name in its git tint; a folder pushes, a file opens its preview.
struct WorkspaceEntryRow: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var files: WorkspaceFilesModel
    let entry: WorkspaceEntry

    var body: some View {
        NavigationLink(value: entry.isDirectory ? WorkspaceRoute.folder(entry.path) : WorkspaceRoute.file(entry)) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: entry.isDirectory ? "folder" : WorkspaceFileKind(path: entry.path).symbol)
                    .font(.system(size: Theme.IconSize.sm))
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 18)
                Text(entry.name)
                    .hermesText(.body)
                    .foregroundStyle(tint ?? Theme.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .contextMenu { WorkspaceEntryMenu(model: model, entry: entry) }
        .swipeActions(edge: .leading) {
            Button { model.addToChat(path: entry.path, isDirectory: entry.isDirectory) } label: {
                Label("Add to chat", systemImage: "text.badge.plus")
            }
            .tint(Theme.primary)
        }
        .accessibilityHint(entry.isDirectory ? "Opens the folder" : "Opens a preview")
    }

    /// The desktop's git decoration: added green, modified yellow, conflicted red.
    private var tint: Color? {
        switch files.changeKind(entry.path) {
        case .added?: return Theme.Semantic.green
        case .modified?: return Theme.Semantic.yellow
        case .conflicted?: return Theme.Semantic.red
        case nil: return nil
        }
    }
}

/// The desktop's file menu on a remote backend: add to chat, copy path, copy relative path, download (files).
struct WorkspaceEntryMenu: View {
    @ObservedObject var model: WorkspacePanelModel
    let entry: WorkspaceEntry

    var body: some View {
        Button { model.addToChat(path: entry.path, isDirectory: entry.isDirectory) } label: {
            Label("Add to chat", systemImage: "text.badge.plus")
        }
        Divider()
        Button { model.copy(entry.path) } label: { Label("Copy path", systemImage: Theme.Icon.copy) }
        Button { model.copy(model.relativePath(entry.path)) } label: {
            Label("Copy relative path", systemImage: "doc.on.clipboard")
        }
        if !entry.isDirectory {
            Divider()
            Button { Task { await model.share(entry.path) } } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
        }
    }
}

/// A folder's header actions: show or hide gitignored files, refresh, add the folder to the chat, copy its path.
struct WorkspaceFilesToolbar: ToolbarContent {
    let model: WorkspacePanelModel
    let files: WorkspaceFilesModel
    let folder: String?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let folder {
                Menu {
                    Button {
                        Task { await files.setShowIgnored(!files.showIgnored) }
                    } label: {
                        Label(files.showIgnored ? "Hide gitignored files" : "Show gitignored files",
                              systemImage: files.showIgnored ? "eye.slash" : "eye")
                    }
                    Button { Task { await files.refresh(model.visibleFolders) } } label: {
                        Label("Refresh tree", systemImage: Theme.Icon.retry)
                    }
                    Divider()
                    Button { model.addToChat(path: folder, isDirectory: true) } label: {
                        Label("Add folder to chat", systemImage: "text.badge.plus")
                    }
                    Button { model.copy(folder) } label: { Label("Copy path", systemImage: Theme.Icon.copy) }
                } label: {
                    Image(systemName: files.showIgnored ? "eye" : Theme.Icon.more)
                }
                .accessibilityLabel("Folder actions")
            }
        }
    }
}

/// How a file previews, from its extension.
enum WorkspaceFileKind: Hashable {
    case image
    case markdown
    case pdf
    /// Read as text; the host says whether it is binary.
    case text

    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff", "ico"]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    init(path: String) {
        let ext = (WorkspacePath.name(path) as NSString).pathExtension.lowercased()
        if Self.images.contains(ext) {
            self = .image
        } else if Self.markdownExtensions.contains(ext) {
            self = .markdown
        } else if ext == "pdf" {
            self = .pdf
        } else {
            self = .text
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .markdown: return "doc.richtext"
        case .pdf: return "doc.text.image"
        case .text: return "doc.text"
        }
    }
}
