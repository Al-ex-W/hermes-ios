import SwiftUI
import UIKit

// The Review tab (`right-sidebar/review/*`, `store/review.ts`, the composer's coding row): the working-tree row,
// the scope switcher, the changed files as a tree or a list, and the ship bar (commit, push, PR).

/// The Review tab's root.
struct WorkspaceReviewRoot: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel

    var body: some View {
        if review.cwd == nil {
            WorkspaceNoProject(model: model, files: model.files)
        } else {
            list
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .task(id: review.cwd) {
                    await review.refresh()
                    await model.refreshShipIfStale()
                }
                .refreshable { await model.refreshAll() }
        }
    }

    private var list: some View {
        List {
            Section {
                WorkspaceCodingRow(model: model, review: review)
                Picker("Scope", selection: $review.scope) {
                    ForEach(ReviewScope.allCases) { scope in Text(scope.label).tag(scope) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }
            .listRowBackground(Theme.background)
            if let error = review.error {
                Section {
                    Label(error, systemImage: Theme.Icon.warning)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Semantic.attention)
                }
                .listRowBackground(Theme.background)
            }
            Section {
                rows
            }
            .listRowBackground(Theme.background)
            .listRowSeparatorTint(Theme.Hairline.quaternary)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 32)
    }

    @ViewBuilder private var rows: some View {
        if !review.isRepo {
            ContentUnavailableView("No diffs", systemImage: Theme.Icon.branch, description: Text("Not a git repository"))
                .listRowSeparator(.hidden)
        } else if review.files.isEmpty {
            if review.loading {
                OpsLoaderRow()
            } else {
                ContentUnavailableView("No diffs", systemImage: "checkmark.circle", description: Text(emptyNote))
                    .listRowSeparator(.hidden)
            }
        } else if review.treeMode {
            let tree = ReviewTree.tree(review.files)
            let heavy = ReviewTree.count(tree) > ReviewTree.heavyCap
            ForEach(ReviewTree.rows(tree, isOpen: { review.folderOpen[$0] ?? !heavy })) { row in
                if row.node.isDirectory {
                    WorkspaceReviewFolderRow(review: review, node: row.node, depth: row.depth, open: review.folderOpen[row.node.id] ?? !heavy)
                } else if let file = row.node.file {
                    WorkspaceReviewFileRow(model: model, review: review, file: file, depth: row.depth, showsFolder: false)
                }
            }
        } else {
            ForEach(ReviewTree.flat(review.files)) { node in
                if let file = node.file {
                    WorkspaceReviewFileRow(model: model, review: review, file: file, depth: 0, showsFolder: true)
                }
            }
        }
    }

    private var emptyNote: String {
        switch review.scope {
        case .uncommitted: return "The working tree matches the last commit."
        case .branch: return "No commits on this branch beyond the default branch."
        case .lastTurn:
            return review.repo.flatMap { WorkspaceTurnBase.shared.base(for: $0) } == nil
                ? "Hermes records where the repository stood when a turn starts. Nothing is recorded for this one yet."
                : "Nothing changed since the last turn started."
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if !review.isUncommitted {
            Text("Read-only view — stage, revert, and commit apply to Uncommitted")
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.md)
                .background(Theme.background)
                .hermesHairline(edges: .top)
        } else if !review.files.isEmpty {
            WorkspaceShipBar(model: model, review: review)
        }
    }
}

/// The review header's actions: refresh, and view as tree or list, stage all, revert all.
struct WorkspaceReviewToolbar: ToolbarContent {
    let model: WorkspacePanelModel
    let review: WorkspaceReviewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if review.cwd != nil {
                if review.loading {
                    ProgressView()
                } else {
                    Button { Task { await model.refreshAll() } } label: { Image(systemName: Theme.Icon.retry) }
                        .accessibilityLabel("Refresh")
                }
                Menu {
                    Button { review.treeMode.toggle() } label: {
                        Label(review.treeMode ? "View as list" : "View as tree",
                              systemImage: review.treeMode ? "list.bullet" : "list.bullet.indent")
                    }
                    .disabled(review.files.isEmpty)
                    Divider()
                    Button { model.request(.stage(file: nil)) } label: { Label("Stage all", systemImage: "plus") }
                        .disabled(review.files.isEmpty || !review.isUncommitted)
                    Button(role: .destructive) { model.request(.revert(file: nil)) } label: {
                        Label("Revert all", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(review.files.isEmpty || !review.isUncommitted)
                } label: {
                    Image(systemName: Theme.Icon.more)
                }
                .accessibilityLabel("Review actions")
            }
        }
    }
}

/// The coding row: branch, its PR, ahead/behind and the line delta, with the branch menu (new branch, switch,
/// worktrees, branches, pull requests, push).
struct WorkspaceCodingRow: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: Theme.Icon.branch)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Semantic.green)
            if let number = prNumber {
                Text("#\(number)")
                    .hermesText(.meta)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.primary)
            }
            Text(branchLabel)
                .hermesText(.body)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.sm)
            if let status = review.status {
                if status.ahead > 0 || status.behind > 0 {
                    HStack(spacing: Theme.Spacing.xs) {
                        if status.ahead > 0 { Text("↑\(status.ahead)") }
                        if status.behind > 0 { Text("↓\(status.behind)") }
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.Text.tertiary)
                    .accessibilityLabel("\(status.ahead) ahead, \(status.behind) behind")
                }
                if status.added > 0 || status.removed > 0 {
                    WorkspaceDiffCount(added: status.added, removed: status.removed)
                } else if status.untracked > 0 {
                    Text("\(status.untracked) changed")
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Semantic.attention)
                }
            }
            Menu {
                WorkspaceBranchMenu(model: model, review: review)
            } label: {
                Image(systemName: Theme.Icon.more)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Branch actions")
        }
        .contextMenu { WorkspaceBranchMenu(model: model, review: review) }
        .accessibilityElement(children: .contain)
    }

    private var prNumber: Int? {
        if let pr = review.branchPR, pr.number > 0 { return pr.number }
        if let pr = review.ship.pr, pr.number > 0 { return pr.number }
        return nil
    }

    private var branchLabel: String {
        guard let status = review.status else { return review.isRepo ? "Working tree" : "Not a git repository" }
        if status.detached { return "detached" }
        return status.branch ?? "No branch"
    }
}

/// The branch actions (the coding row's kebab): branch off, switch home, worktrees, branches, PRs, push.
struct WorkspaceBranchMenu: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel

    var body: some View {
        let current = review.status?.currentBranch
        let trunk = review.status?.defaultBranch
        Section("New branch") {
            ForEach(branchTargets(current: current, trunk: trunk), id: \.label) { target in
                Button { model.worktreeSheet = WorktreeSheetRequest(base: target.base) } label: {
                    Label(target.label, systemImage: Theme.Icon.branch)
                }
            }
            if let current, let trunk, trunk != current {
                Button { model.request(.switchBranch(trunk)) } label: {
                    Label("Switch to \(trunk)", systemImage: "arrow.left.arrow.right")
                }
            }
        }
        Section("Worktrees") {
            Button { model.route.append(.worktrees) } label: { Label("Worktrees", systemImage: "square.stack.3d.up") }
            Button { model.worktreeSheet = WorktreeSheetRequest(base: nil) } label: { Label("New worktree", systemImage: "plus") }
            Button { model.route.append(.branches) } label: { Label("Convert a branch…", systemImage: "arrow.triangle.branch") }
        }
        Section {
            Button { model.route.append(.pullRequests) } label: { Label("Pull requests", systemImage: "arrow.triangle.pull") }
            Button { model.request(.push(branch: current)) } label: { Label("Push", systemImage: "arrow.up.circle") }
                .disabled(review.shipBusy || current == nil)
            if let repo = review.repo {
                Button { model.copy(repo) } label: { Label("Copy path", systemImage: Theme.Icon.copy) }
            }
        }
    }

    /// The current branch first, then the trunk ("New branch from main"); a plain off-HEAD branch when neither.
    private func branchTargets(current: String?, trunk: String?) -> [(base: String?, label: String)] {
        var targets: [(String?, String)] = []
        if let current { targets.append((current, "New branch from \(current)")) }
        if let trunk, trunk != current { targets.append((trunk, "New branch from \(trunk)")) }
        if targets.isEmpty { targets.append((nil, "New branch")) }
        return targets
    }
}

/// A folder in the tree view: a disclosure that aggregates its files' counts while closed.
struct WorkspaceReviewFolderRow: View {
    @ObservedObject var review: WorkspaceReviewModel
    let node: ReviewTreeNode
    let depth: Int
    let open: Bool

    var body: some View {
        Button {
            review.folderOpen[node.id] = !open
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: Theme.Icon.disclosure)
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(Theme.Text.quaternary)
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.tertiary)
                Text(node.name)
                    .hermesText(.body)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.sm)
                if !open { WorkspaceDiffCount(added: node.added, removed: node.removed) }
            }
            .padding(.leading, CGFloat(depth) * 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.name), folder")
        .accessibilityValue(open ? "expanded" : "collapsed")
    }
}

/// A changed file: its status glyph, name (and folder in the list view), counts and staged dot. A tap opens its diff.
struct WorkspaceReviewFileRow: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    let file: ReviewFile
    let depth: Int
    let showsFolder: Bool

    var body: some View {
        NavigationLink(value: WorkspaceRoute.diff(file)) {
            HStack(spacing: Theme.Spacing.sm) {
                let glyph = WorkspaceStatusGlyph(status: file.status)
                Image(systemName: glyph.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(glyph.color)
                    .frame(width: 16)
                    .accessibilityLabel(glyph.label)
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(file.name)
                        .hermesText(.body)
                        .foregroundStyle(Theme.Text.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if showsFolder, !file.folder.isEmpty {
                        Text(file.folder)
                            .hermesText(.meta)
                            .foregroundStyle(Theme.Text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
                WorkspaceDiffCount(added: file.added, removed: file.removed)
                if file.staged {
                    OpsDot(color: Theme.Semantic.green.opacity(0.7), size: 6)
                        .accessibilityLabel("Staged")
                }
            }
            .padding(.leading, CGFloat(depth) * 12 + (depth > 0 ? 14 : 0))
        }
        .swipeActions(edge: .leading) {
            if review.isUncommitted {
                Button {
                    model.request(file.staged ? .unstage(file: file.path) : .stage(file: file.path))
                } label: {
                    Label(file.staged ? "Unstage" : "Stage", systemImage: file.staged ? "minus" : "plus")
                }
                .tint(Theme.Semantic.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if review.isUncommitted {
                Button(role: .destructive) { model.request(.revert(file: file.path)) } label: {
                    Label("Revert", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .contextMenu { WorkspaceReviewFileMenu(model: model, review: review, file: file) }
    }
}

/// The review row's menu: open changes or the file, stage, revert, copy, add to chat.
struct WorkspaceReviewFileMenu: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    let file: ReviewFile

    var body: some View {
        let absolute = review.absolutePath(file.path)
        Button { model.route.append(.diff(file)) } label: { Label("Open changes", systemImage: "plusminus") }
        if file.status != "D" {
            Button { model.reveal(file: absolute) } label: { Label("Open file", systemImage: "doc.text") }
        }
        if review.isUncommitted {
            Divider()
            Button { model.request(file.staged ? .unstage(file: file.path) : .stage(file: file.path)) } label: {
                Label(file.staged ? "Unstage" : "Stage", systemImage: file.staged ? "minus" : "plus")
            }
            Button(role: .destructive) { model.request(.revert(file: file.path)) } label: {
                Label("Revert", systemImage: "arrow.uturn.backward")
            }
        }
        Divider()
        Button { model.addToChat(path: absolute, isDirectory: false) } label: { Label("Add to chat", systemImage: "text.badge.plus") }
        Button { model.copy(absolute) } label: { Label("Copy path", systemImage: Theme.Icon.copy) }
        Button { model.copy(model.relativePath(absolute)) } label: { Label("Copy relative path", systemImage: "doc.on.clipboard") }
    }
}

/// The git status letter as a glyph (`STATUS_GLYPH`): added, modified, deleted, renamed, conflicted, untracked.
struct WorkspaceStatusGlyph {
    let symbol: String
    let color: Color
    let label: String

    init(status: String) {
        let glyph = Self.glyph(status)
        symbol = glyph.symbol
        color = glyph.color
        label = glyph.label
    }

    private static func glyph(_ status: String) -> (symbol: String, color: Color, label: String) {
        switch status {
        case "A", "C": return ("plus.square", Theme.Semantic.green, "Added")
        case "D": return ("minus.square", Theme.Semantic.red, "Deleted")
        case "R": return ("arrow.right.square", Theme.Semantic.cyan, "Renamed")
        case "U": return ("exclamationmark.triangle", Theme.Semantic.red, "Conflicted")
        case "?": return ("plus.square.dashed", Theme.Text.tertiary, "Untracked")
        default: return ("dot.square", Theme.Semantic.yellow, "Modified")
        }
    }
}

/// The ship bar: the commit message (drafted on request), Commit or Commit & Push, the agent hand-off and the PR.
struct WorkspaceShipBar: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                TextField("Message", text: $model.commitMessage, axis: .vertical)
                    .lineLimit(1...6)
                    .hermesText(.body)
                    .focused($focused)
                    .disabled(review.generating)
                    .submitLabel(.return)
                if review.canGenerate {
                    if review.generating {
                        Button { review.cancelGenerate() } label: {
                            ProgressView().frame(width: 24, height: 24)
                        }
                        .accessibilityLabel("Stop generating")
                    } else {
                        Button { generate() } label: {
                            Image(systemName: "sparkles").frame(width: 24, height: 24)
                        }
                        .disabled(review.shipBusy)
                        .accessibilityLabel("Generate commit message")
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(focused ? Theme.ring.opacity(0.55) : Theme.border, lineWidth: Theme.hairlineWidth)
            }

            Menu {
                Button { run(push: false) } label: { Label("Commit", systemImage: "checkmark") }
                Button { run(push: true) } label: { Label("Commit & Push", systemImage: "arrow.up.circle") }
            } label: {
                HStack {
                    if review.shipBusy { ProgressView().tint(Theme.primaryForeground) } else { Image(systemName: "checkmark") }
                    Text(review.commitAndPush ? "Commit & Push" : "Commit").hermesText(.button)
                }
                .frame(maxWidth: .infinity)
            } primaryAction: {
                run(push: review.commitAndPush)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCommit)
            .accessibilityHint("Press and hold to choose Commit or Commit & Push")

            HStack(spacing: Theme.Spacing.sm) {
                Button { model.askHermesToShip() } label: {
                    Text("Ask Hermes to open PR").underline().hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                prButton
            }
            if !review.ship.ghReady {
                Text(ghNote)
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.quaternary)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.background)
        .hermesHairline(edges: .top)
    }

    private var canCommit: Bool {
        !review.files.isEmpty && !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !review.shipBusy
    }

    @ViewBuilder private var prButton: some View {
        if let pr = review.ship.pr, let url = URL(string: pr.url) {
            Button { UIApplication.shared.open(url) } label: {
                Label(pr.number > 0 ? "Open PR #\(pr.number)" : "Open PR", systemImage: "arrow.triangle.pull")
                    .hermesText(.button)
            }
            .buttonStyle(.bordered)
        } else {
            Button { model.request(.createPR(branch: review.status?.currentBranch)) } label: {
                Label("Create PR", systemImage: "arrow.triangle.pull").hermesText(.button)
            }
            .buttonStyle(.bordered)
            .disabled(!review.ship.ghReady || review.shipBusy)
        }
    }

    private var ghNote: String {
        guard let gh = review.gh else { return "Install the GitHub CLI (gh) and sign in to open PRs" }
        return "\(gh.label). Install the GitHub CLI (gh) on the host and sign in to open PRs."
    }

    private func run(push: Bool) {
        guard canCommit else { return }
        review.commitAndPush = push
        focused = false
        model.request(.commit(message: model.commitMessage, push: push, branch: review.status?.currentBranch))
    }

    private func generate() {
        let previous = model.commitMessage
        Task {
            do {
                let text = try await review.generateMessage(previous: previous)
                if !text.isEmpty { model.commitMessage = text }
            } catch {
                if !error.isCancellation { model.failure = "Couldn't generate a commit message. \(error.dashboardMessage)" }
            }
        }
    }
}

/// One file's diff (the review pane's lower half): path, counts, stage or unstage, then the diff.
struct WorkspaceReviewDiffScreen: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    let file: ReviewFile

    @State private var diff: String?
    @State private var error: String?

    /// The row as the list reads it now (staging flips which diff shows).
    private var current: ReviewFile { review.files.first { $0.path == file.path } ?? file }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error {
                ContentUnavailableView("Couldn't load the diff", systemImage: Theme.Icon.warning, description: Text(error))
            } else if let diff {
                if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("No diff to show", systemImage: "doc.plaintext")
                } else {
                    WorkspaceDiffView(lines: WorkspaceDiffParser.parse(diff))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if current.status != "D" {
                    Button { model.reveal(file: review.absolutePath(current.path)) } label: { Image(systemName: "doc.text") }
                        .accessibilityLabel("Open file")
                }
                Menu { WorkspaceReviewFileMenu(model: model, review: review, file: current) } label: {
                    Image(systemName: Theme.Icon.more)
                }
                .accessibilityLabel("More")
            }
        }
        .task(id: current) { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(current.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer(minLength: Theme.Spacing.sm)
            WorkspaceDiffCount(added: current.added, removed: current.removed)
            if review.isUncommitted {
                Button {
                    model.request(current.staged ? .unstage(file: current.path) : .stage(file: current.path))
                } label: {
                    Text(current.staged ? "Unstage" : "Stage").hermesText(.button)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .hermesHairline()
    }

    private func load() async {
        do {
            diff = try await review.diff(for: current)
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }
}
