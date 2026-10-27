import SwiftUI
import UIKit

// Branch and worktree screens (the desktop's coding-row menu, `worktree-dialog.tsx`, `store/projects.ts` git ops):
// the repository's worktrees, its branches, the PRs on them, and the new-worktree sheet.

/// `git worktree list`: browse one here, start a chat in it, or remove it (asking first).
struct WorkspaceWorktreesScreen: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    @State private var worktrees: [GitWorktree]?
    @State private var error: String?

    var body: some View {
        Group {
            if let error, worktrees == nil {
                ContentUnavailableView("Couldn't list worktrees", systemImage: Theme.Icon.warning, description: Text(error))
            } else if let worktrees {
                if worktrees.isEmpty {
                    ContentUnavailableView("No worktrees", systemImage: "square.stack.3d.up",
                                           description: Text("This folder isn't in a git repository."))
                } else {
                    List(worktrees) { worktree in
                        row(worktree).listRowBackground(Theme.background)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle("Worktrees")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.worktreeSheet = WorktreeSheetRequest(base: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New worktree")
            }
        }
        .task(id: model.worktreesChanged) { await load() }
        .refreshable { await load() }
    }

    private func row(_ worktree: GitWorktree) -> some View {
        let here = model.workingFolder.map { WorkspacePath.clean($0) == WorkspacePath.clean(worktree.path) } ?? false
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: Theme.Icon.branch).font(.system(size: 12)).foregroundStyle(Theme.Semantic.green)
                Text(worktree.detached ? "detached" : worktree.branch ?? "No branch")
                    .hermesText(.rowTitle)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(1)
                if worktree.isMain { OpsPill("main tree") }
                if worktree.locked { OpsPill("locked", tone: .warn) }
                if here { OpsPill("here", tone: .good) }
            }
            Text(worktree.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.Text.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu { menu(worktree, here: here) }
        .swipeActions(edge: .trailing) {
            if !worktree.isMain {
                Button(role: .destructive) { model.request(.removeWorktree(path: worktree.path, force: false)) } label: {
                    Label("Remove", systemImage: Theme.Icon.delete)
                }
            }
        }
        .swipeActions(edge: .leading) {
            if !here {
                Button { model.browse(worktree.path) } label: { Label("Browse", systemImage: "folder") }
                    .tint(Theme.primary)
            }
        }
    }

    @ViewBuilder private func menu(_ worktree: GitWorktree, here: Bool) -> some View {
        if !here {
            Button { model.browse(worktree.path) } label: { Label("Browse here", systemImage: "folder") }
        }
        if let start = model.context.startSession {
            Button { start(worktree.path) } label: { Label("New chat here", systemImage: Theme.Icon.newSession) }
        }
        Button { model.copy(worktree.path) } label: { Label("Copy path", systemImage: Theme.Icon.copy) }
        if !worktree.isMain {
            Divider()
            Button(role: .destructive) { model.request(.removeWorktree(path: worktree.path, force: false)) } label: {
                Label("Remove worktree", systemImage: Theme.Icon.delete)
            }
        }
    }

    private func load() async {
        guard let repo = await review.resolveRepo() else {
            worktrees = []
            return
        }
        do {
            worktrees = try await model.client.gitWorktrees(repo)
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }
}

/// The repository's branches (the convert-a-branch picker): open a checked-out one, switch the main tree home,
/// check a free branch out into a worktree, or track a remote one. Switching asks first.
struct WorkspaceBranchesScreen: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    @State private var branches: [GitBranch]?
    @State private var error: String?
    @State private var query = ""
    @State private var working: String?

    var body: some View {
        Group {
            if let error, branches == nil {
                ContentUnavailableView("Couldn't list branches", systemImage: Theme.Icon.warning, description: Text(error))
            } else if let branches {
                let shown = branches.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                if shown.isEmpty {
                    ContentUnavailableView("No branches found", systemImage: Theme.Icon.branch)
                } else {
                    List {
                        let local = shown.filter { !$0.isRemote }, remote = shown.filter(\.isRemote)
                        if !local.isEmpty {
                            Section("Local") { ForEach(local) { row($0) } }
                                .listRowBackground(Theme.background)
                        }
                        if !remote.isEmpty {
                            Section("Remote") { ForEach(remote) { row($0) } }
                                .listRowBackground(Theme.background)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle("Convert a branch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .searchable(text: $query, prompt: "Search branches…")
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ branch: GitBranch) -> some View {
        let current = review.status?.currentBranch == branch.name && !branch.isRemote
        return Button { Task { await pick(branch) } } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: branch.isRemote ? "network" : Theme.Icon.branch)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Text.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(branch.name).hermesText(.body).foregroundStyle(Theme.Text.primary).lineLimit(1)
                    if let path = branch.worktreePath {
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.Text.quaternary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: Theme.Spacing.sm)
                if working == branch.id {
                    ProgressView()
                } else if current {
                    OpsPill("current", tone: .good)
                } else {
                    Text(branch.actionLabel).hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                }
            }
        }
        .disabled(working != nil || current)
        .contextMenu {
            if !branch.isRemote, !branch.checkedOut {
                Button { model.request(.switchBranch(branch.name)) } label: {
                    Label("Switch to \(branch.name)", systemImage: "arrow.left.arrow.right")
                }
            }
            Button { model.copy(branch.name, label: "Copied") } label: { Label("Copy name", systemImage: Theme.Icon.copy) }
        }
    }

    /// The desktop's convert flow: an existing checkout opens; the trunk switches the main tree; another local
    /// branch gets its own worktree; a remote one gets a local branch tracking it, in a worktree.
    private func pick(_ branch: GitBranch) async {
        if let path = branch.worktreePath {
            if let start = model.context.startSession { start(path) } else { model.browse(path) }
            return
        }
        if branch.isDefault, !branch.isRemote {
            model.request(.switchBranch(branch.name))
            return
        }
        working = branch.id
        defer { working = nil }
        do {
            let result = try await review.addWorktree(WorktreeAddOptions(existingBranch: branch.name))
            model.worktreeCreated(result)
        } catch {
            if !error.isCancellation { model.failure = "Could not create worktree. \(error.dashboardMessage)" }
        }
    }

    private func load() async {
        guard let repo = await review.resolveRepo() else {
            branches = []
            return
        }
        do {
            branches = try await model.client.gitBranches(repo)
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }
}

/// The pull requests on the repository's local branches (`review/pr-list`), newest state from GitHub via gh.
struct WorkspacePullRequestsScreen: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    @State private var result: RepoPullRequests?
    @State private var error: String?

    var body: some View {
        Group {
            if let error, result == nil {
                ContentUnavailableView("Couldn't list pull requests", systemImage: Theme.Icon.warning, description: Text(error))
            } else if let result {
                if !result.ghReady {
                    ContentUnavailableView {
                        Label("GitHub CLI not ready", systemImage: "arrow.triangle.pull")
                    } description: {
                        Text(review.gh.map { "\($0.label). " } ?? "")
                            + Text("Install the GitHub CLI (gh) on the host and sign in to open PRs.")
                    } actions: {
                        Button("Check again") { Task { await load(refreshAuth: true) } }
                            .buttonStyle(.bordered)
                    }
                } else if result.prs.isEmpty {
                    ContentUnavailableView("No pull requests", systemImage: "arrow.triangle.pull",
                                           description: Text("None of this repository's branches has a PR."))
                } else {
                    List(result.prs.sorted { $0.number > $1.number }) { pr in
                        row(pr).listRowBackground(Theme.background)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .navigationTitle("Pull requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ pr: BranchPullRequest) -> some View {
        Button {
            if let url = URL(string: pr.url) { UIApplication.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("#\(pr.number)").hermesText(.label).foregroundStyle(Theme.primary)
                    Text(pr.title.isEmpty ? pr.branch : pr.title)
                        .hermesText(.body)
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    Spacer(minLength: Theme.Spacing.sm)
                    OpsPill(pr.draft ? "draft" : pr.state, tone: tone(pr))
                }
                Text(pr.branch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .contextMenu {
            Button { model.copy(pr.url, label: "Link copied") } label: { Label("Copy link", systemImage: "link") }
        }
    }

    private func tone(_ pr: BranchPullRequest) -> OpsPill.Tone {
        if pr.draft { return .muted }
        switch pr.state {
        case "open": return .good
        case "merged": return .muted
        default: return .bad
        }
    }

    private func load(refreshAuth: Bool = false) async {
        guard let repo = await review.resolveRepo() else {
            result = nil
            error = "This folder isn't in a git repository."
            return
        }
        do {
            if refreshAuth { await review.refreshShip(refreshAuth: true) }
            let branches = try await model.client.gitBranches(repo).filter { !$0.isRemote }.map(\.name)
            result = try await model.client.pullRequests(repo, branches: branches)
            error = nil
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }
}

/// The new-worktree sheet: name the branch, pick its base, or convert an existing branch instead.
struct WorkspaceNewWorktreeSheet: View {
    @ObservedObject var model: WorkspacePanelModel
    @ObservedObject var review: WorkspaceReviewModel
    let base: String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedBase = ""
    @State private var bases: [GitBaseBranch] = []
    @State private var pending = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. my-feature", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { Task { await submit() } }
                } header: {
                    FormNote("Branch")
                } footer: {
                    if !branch.isEmpty, branch != name.trimmingCharacters(in: .whitespaces) {
                        FormNote("Creates \(branch)")
                    }
                }
                .hermesFormRows()
                Section {
                    Picker("Branch off", selection: $selectedBase) {
                        Text("Current HEAD").tag("")
                        ForEach(bases) { base in
                            Text(base.isDefault ? "\(base.name) (default)" : base.name).tag(base.name)
                        }
                    }
                } footer: {
                    FormNote("The new worktree goes in .worktrees inside the repository, on its own branch.")
                }
                .hermesFormRows()
                Section {
                    Button("Convert an existing branch") {
                        dismiss()
                        model.route.append(.branches)
                    }
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle("New worktree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(pending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if pending {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await submit() } }.disabled(branch.isEmpty)
                    }
                }
            }
            .task { await loadBases() }
        }
        .failureAlert($failure)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(pending)
    }

    /// The name made safe as a git ref, as the host will make it.
    private var branch: String { GitRefName.sanitize(name) }

    private func loadBases() async {
        selectedBase = base ?? ""
        guard let repo = await review.resolveRepo(), let found = try? await model.client.gitBaseBranches(repo) else { return }
        bases = found
        if base == nil, let preferred = found.first(where: \.isDefault) { selectedBase = preferred.name }
        if !selectedBase.isEmpty, !found.contains(where: { $0.name == selectedBase }) {
            bases.insert(contentsOf: [GitBaseBranch(row: ["name": selectedBase])].compactMap { $0 }, at: 0)
        }
    }

    private func submit() async {
        let branch = branch
        guard !pending, !branch.isEmpty else { return }
        pending = true
        defer { pending = false }
        do {
            let result = try await review.addWorktree(WorktreeAddOptions(name: branch, branch: branch,
                                                                         base: selectedBase.isEmpty ? nil : selectedBase))
            dismiss()
            model.worktreeCreated(result)
        } catch {
            if !error.isCancellation { failure = "Could not create worktree. \(error.dashboardMessage)" }
        }
    }
}
