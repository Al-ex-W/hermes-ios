import QuickLook
import SwiftUI
import UIKit

/// The workspace panel: the desktop's right sidebar (Files and Review) for the session's folder on the host. The
/// chat opens it as an inspector on iPad and a sheet on iPhone. The desktop's Terminal tab runs a shell on the
/// desktop's own machine; it isn't ported, and its tab says so.
///
/// The panel keeps its state for its identity: give it a new `.id` when the client or profile changes.
struct WorkspacePanel: View {
    let context: WorkspaceContext
    @StateObject private var model: WorkspacePanelModel

    init(context: WorkspaceContext) {
        self.context = context
        _model = StateObject(wrappedValue: WorkspacePanelModel(context: context))
    }

    var body: some View {
        NavigationStack(path: $model.route) {
            WorkspaceRootView(model: model, files: model.files, review: model.review)
                .navigationDestination(for: WorkspaceRoute.self) { route in
                    destination(route)
                }
        }
        .tint(Theme.primary)
        .workspaceConfirm(model.gate)
        .failureAlert($model.failure)
        .opsToast($model.notice)
        .opsShareSheet($model.shared)
        .quickLookPreview($model.quickLook)
        .onChange(of: model.quickLook) { old, new in
            if let old, new == nil { DashboardClient.removeTemporaryFile(old) }
        }
        .onAppear { model.update(context) }
        .onChange(of: context.cwd) { model.update(context) }
        .onChange(of: context.runtimeSessionID) { model.update(context) }
        .onChange(of: context.turnBusy) { _, busy in
            model.update(context)
            Task { await model.turnBusyChanged(busy) }
        }
    }

    @ViewBuilder private func destination(_ route: WorkspaceRoute) -> some View {
        switch route {
        case let .folder(path):
            WorkspaceFolderView(model: model, files: model.files, folder: path)
        case let .file(entry):
            WorkspaceFilePreview(model: model, files: model.files, entry: entry)
        case let .diff(file):
            WorkspaceReviewDiffScreen(model: model, review: model.review, file: file)
        case .worktrees:
            WorkspaceWorktreesScreen(model: model, review: model.review)
        case .branches:
            WorkspaceBranchesScreen(model: model, review: model.review)
        case .pullRequests:
            WorkspacePullRequestsScreen(model: model, review: model.review)
        }
    }
}

/// Owns the panel's two models, its pushed screens and the actions that ask first.
@MainActor
final class WorkspacePanelModel: ObservableObject {
    private(set) var context: WorkspaceContext
    let files: WorkspaceFilesModel
    let review: WorkspaceReviewModel
    private(set) lazy var gate = WorkspaceActionGate { [weak self] action in await self?.perform(action) }

    @Published var tab = WorkspacePrefs.tab {
        didSet { WorkspacePrefs.tab = tab }
    }
    @Published var route: [WorkspaceRoute] = []
    /// A worktree the panel was moved to ("Browse here"); nil follows the session's folder.
    @Published private(set) var browsing: String?
    @Published var commitMessage = ""
    @Published var failure: String?
    @Published var notice: OpsNotice?
    @Published var shared: SharedFile?
    @Published var quickLook: URL?
    @Published var downloading = false
    @Published var worktreeSheet: WorktreeSheetRequest?

    private var shipCheckedAt = Date.distantPast
    private var shipCheckedFolder: String?

    init(context: WorkspaceContext) {
        self.context = context
        files = WorkspaceFilesModel(client: context.client, profile: context.profile)
        review = WorkspaceReviewModel(client: context.client, gateway: context.gateway, profile: context.profile,
                                      runtimeSessionID: context.runtimeSessionID)
        apply()
    }

    var client: DashboardClient { context.client }

    /// The folder the panel works in: a browsed worktree, else the session's.
    var workingFolder: String? { browsing ?? context.cwd.flatMap(WorkspacePath.nonBlank) }

    func update(_ context: WorkspaceContext) {
        let moved = context.cwd != self.context.cwd
        self.context = context
        review.gateway = context.gateway
        review.runtimeSessionID = context.runtimeSessionID
        if moved {
            browsing = nil
            route = []
        }
        apply()
    }

    /// Points both tabs at the working folder (or the profile's default folder the Files tab was moved to).
    func apply() {
        let folder = workingFolder
        if !(files.rootIsDefault && folder == nil) { files.setRoot(folder) }
        review.setCwd(folder ?? (files.rootIsDefault ? files.root : nil))
    }

    /// Moves the panel to a worktree (nil: back to the session's folder).
    func browse(_ folder: String?) {
        browsing = folder.map(WorkspacePath.clean)
        route = []
        apply()
        Task { await refreshAll() }
    }

    func refreshAll() async {
        async let review: Void = review.refresh()
        async let tint: Void = files.refreshChanges()
        _ = await (review, tint)
        await refreshShipIfStale(force: true)
    }

    /// gh is slow: the PR state is re-read at most every 30 seconds for the same folder (as the desktop's ship bar).
    func refreshShipIfStale(force: Bool = false) async {
        let folder = review.cwd
        guard force || folder != shipCheckedFolder || Date().timeIntervalSince(shipCheckedAt) > 30 else { return }
        shipCheckedAt = Date()
        shipCheckedFolder = folder
        await review.refreshShip()
    }

    /// A turn started: record HEAD for Last turn. A turn settled: re-read what it changed.
    func turnBusyChanged(_ busy: Bool) async {
        guard let folder = workingFolder else { return }
        if busy {
            var repo = await review.resolveRepo()
            if repo == nil { repo = (try? await client.workspaceGitRoot(folder, profile: context.profile)) ?? nil }
            guard let repo else { return }
            await WorkspaceTurnBase.shared.capture(client: client, repo: repo)
        } else {
            await review.refresh()
            await files.refreshChanges()
            await refreshShipIfStale()
        }
    }

    // MARK: Hand-offs to the chat

    /// The composer gets a `@file:` / `@folder:` reference relative to the session's folder.
    func addToChat(path: String, isDirectory: Bool) {
        context.insertIntoComposer(WorkspacePath.refText(path: path, isDirectory: isDirectory, cwd: context.cwd))
        notice = OpsNotice(title: "Added to chat", message: WorkspacePath.name(path))
    }

    static let shipPrompt = "Review the current changes, commit them with a clear conventional-commit message, push the "
        + "branch, and open a pull request."

    func askHermesToShip() {
        if let submit = context.submitToChat {
            submit(Self.shipPrompt)
            notice = OpsNotice(title: "Sent to Hermes")
        } else {
            context.insertIntoComposer(Self.shipPrompt)
            notice = OpsNotice(title: "Added to chat", message: "Send it from the composer.")
        }
    }

    func copy(_ text: String, label: String = "Path copied") {
        UIPasteboard.general.string = text
        notice = OpsNotice(title: label)
    }

    /// Relative to the session's folder (the desktop's "Copy relative path").
    func relativePath(_ path: String) -> String {
        guard let base = workingFolder, let relative = WorkspacePath.relative(path, to: base), !relative.isEmpty else { return path }
        return relative
    }

    // MARK: Files

    func share(_ path: String) async {
        guard let file = await download(path) else { return }
        shared = SharedFile(url: file)
    }

    func openQuickLook(_ path: String) async {
        if let file = await download(path) { quickLook = file }
    }

    private func download(_ path: String) async -> URL? {
        downloading = true
        defer { downloading = false }
        do {
            return try await client.workspaceDownloadFile(path, profile: context.profile, sessionID: context.sessionID)
        } catch {
            if !error.isCancellation { failure = "Download failed. \(error.dashboardMessage)" }
            return nil
        }
    }

    // MARK: Actions

    func request(_ action: WorkspaceAction) {
        Task { await gate.request(action) }
    }

    private func perform(_ action: WorkspaceAction) async {
        do {
            switch action {
            case let .stage(file):
                try await review.stage(file)
            case let .unstage(file):
                try await review.unstage(file)
            case let .revert(file):
                try await review.revert(file)
                route.removeAll { route in
                    if case let .diff(shown) = route { return file == nil || shown.path == file }
                    return false
                }
                await files.refreshChanges()
                notice = OpsNotice(title: file == nil ? "Reverted all changes" : "Reverted", message: file.map(WorkspacePath.name))
            case let .commit(message, push, _):
                try await review.commit(message: message, push: push)
                commitMessage = ""
                await files.refreshChanges()
                notice = OpsNotice(title: push ? "Committed and pushed" : "Committed")
            case .push:
                try await review.push()
                notice = OpsNotice(title: "Pushed")
            case .createPR:
                if let url = try await review.createPR() {
                    notice = OpsNotice(title: "Pull request created", message: url.absoluteString)
                    await UIApplication.shared.open(url)
                } else {
                    notice = OpsNotice(title: "Pull request created")
                }
            case let .switchBranch(branch):
                try await review.switchBranch(branch)
                await files.refresh(visibleFolders)
                notice = OpsNotice(title: "Switched to \(branch)")
            case let .removeWorktree(path, force):
                do {
                    try await review.removeWorktree(path, force: force)
                    if let browsing, WorkspacePath.isUnder(path, browsing) { browse(nil) }
                    worktreesChanged += 1
                    notice = OpsNotice(title: "Worktree removed", message: WorkspacePath.name(path))
                } catch let error where !force && Self.isDirtyWorktree(error) {
                    await gate.request(.removeWorktree(path: path, force: true))
                }
            }
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
        }
    }

    /// Bumped when worktrees were added or removed, so their list reloads.
    @Published var worktreesChanged = 0

    /// git refuses to remove a worktree with changes unless forced.
    static func isDirtyWorktree(_ error: Error) -> Bool {
        let text = error.dashboardMessage.lowercased()
        return text.contains("modified or untracked") || text.contains("--force") || text.contains("is dirty")
    }

    /// The folders on screen: the root and every pushed folder.
    var visibleFolders: [String] {
        var folders = files.root.map { [$0] } ?? []
        for route in route {
            if case let .folder(folder) = route { folders.append(folder) }
        }
        return folders
    }

    /// Shows `folder` with its ancestors under the root on the stack (a breadcrumb tap, a reveal).
    func open(folder: String) {
        guard let root = files.root else { return }
        let target = WorkspacePath.clean(folder)
        if target == root {
            route = []
            return
        }
        if let index = route.firstIndex(of: .folder(target)) {
            route = Array(route[...index])
            return
        }
        guard WorkspacePath.isUnder(root, target) else {
            route = [.folder(target)]
            return
        }
        route = WorkspacePath.crumbs(root: root, path: target).dropFirst().map { .folder($0.path) }
    }

    /// Shows a review file in the file browser.
    func reveal(file path: String) {
        tab = .files
        guard let parent = WorkspacePath.parent(path) else { return }
        open(folder: parent)
        route.append(.file(WorkspaceEntry(name: WorkspacePath.name(path), path: path, isDirectory: false)))
    }

    // MARK: Worktrees

    func worktreeCreated(_ result: WorktreeAddResult) {
        worktreesChanged += 1
        if let start = context.startSession {
            start(result.path)
            notice = OpsNotice(title: "New chat in \(result.branch.isEmpty ? WorkspacePath.name(result.path) : result.branch)")
        } else {
            browse(result.path)
            notice = OpsNotice(title: "Worktree ready", message: result.branch)
        }
    }
}

/// Opens the new-worktree sheet, optionally on a base branch ("New branch from main").
struct WorktreeSheetRequest: Identifiable {
    let id = UUID()
    var base: String?
}

/// The panel's root: the tab switcher over the chosen tab.
private struct WorkspaceRootView: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var files: WorkspaceFilesModel
    @ObservedObject var review: WorkspaceReviewModel

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                if let close = model.context.close {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { close() } label: { Image(systemName: Theme.Icon.close) }
                            .accessibilityLabel("Close")
                    }
                }
                switch model.tab {
                case .files: WorkspaceFilesToolbar(model: model, files: files, folder: files.root)
                case .review: WorkspaceReviewToolbar(model: model, review: review)
                case .terminal: ToolbarItem(placement: .primaryAction) { EmptyView() }
                }
            }
            .sheet(item: $model.worktreeSheet) { request in
                WorkspaceNewWorktreeSheet(model: model, review: review, base: request.base)
            }
    }

    private var title: String {
        switch model.tab {
        case .terminal: return "Terminal"
        case .files: return files.root.map(WorkspacePath.name) ?? "Files"
        case .review: return "Review"
        }
    }

    private var header: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Picker("Panel", selection: $model.tab) {
                ForEach(WorkspaceTab.allCases) { tab in Text(tab.label).tag(tab) }
            }
            .pickerStyle(.segmented)
            if let browsing = model.browsing {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: Theme.Icon.branch).foregroundStyle(Theme.Semantic.green)
                    Text("Worktree \(WorkspacePath.name(browsing))")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Session folder") { model.browse(nil) }
                        .hermesText(.button)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.sm)
        .background(Theme.background)
        .hermesHairline()
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .terminal:
            ContentUnavailableView {
                Label("Terminal isn't on the phone", systemImage: Theme.Icon.terminal)
            } description: {
                Text("The desktop's terminal runs a shell on its own computer. Ask Hermes to run commands in the chat; its tools work on the host.")
            }
        case .files:
            WorkspaceFilesRoot(model: model, files: files)
        case .review:
            WorkspaceReviewRoot(model: model, review: review)
        }
    }
}

/// Nothing to browse: the session has no folder.
struct WorkspaceNoProject: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var files: WorkspaceFilesModel

    var body: some View {
        ContentUnavailableView {
            Label("No project open", systemImage: "folder")
        } description: {
            Text("Open a project to browse its files and review changes.")
        } actions: {
            if files.resolvingDefault {
                ProgressView()
            } else {
                Button("Browse the default folder") {
                    Task {
                        do {
                            try await files.useDefaultFolder()
                            model.apply()
                        } catch {
                            if !error.isCancellation { model.failure = error.dashboardMessage }
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
