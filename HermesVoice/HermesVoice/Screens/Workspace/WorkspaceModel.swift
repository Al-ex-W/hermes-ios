import Foundation
import SwiftUI

/// What the workspace panel works on: the session's folder on the host, and how it hands things back to the chat.
struct WorkspaceContext {
    let client: DashboardClient
    /// Drafts commit messages (`llm.oneshot`); nil hides the generate button.
    var gateway: GatewayClient?
    /// The profile the session belongs to (`?profile=` on the file routes); nil is the dashboard's own.
    var profile: String?
    /// The session's working folder on the host; nil shows "No project open".
    var cwd: String?
    /// The stored session id: downloads resolve relative paths against its folder.
    var sessionID: String?
    /// The live session id: a drafted commit message borrows its model.
    var runtimeSessionID: String?
    /// True while a turn runs. The review captures HEAD when a turn starts (the Last turn baseline) and
    /// refreshes when it settles.
    var turnBusy = false
    /// Puts text into the chat's composer (`@file:` / `@folder:` references, the ship prompt).
    var insertIntoComposer: (String) -> Void
    /// Sends a prompt to the chat at once ("Ask Hermes to open PR"); nil puts it in the composer instead.
    var submitToChat: ((String) -> Void)?
    /// Opens a fresh chat in a folder (a new worktree); nil browses the worktree here instead.
    var startSession: ((String) -> Void)?
    /// Closes the panel; nil hides the close button (beside the chat, its header button closes it).
    var close: (() -> Void)?

    init(client: DashboardClient, gateway: GatewayClient? = nil, profile: String? = nil, cwd: String? = nil,
         sessionID: String? = nil, runtimeSessionID: String? = nil, turnBusy: Bool = false,
         insertIntoComposer: @escaping (String) -> Void, submitToChat: ((String) -> Void)? = nil,
         startSession: ((String) -> Void)? = nil, close: (() -> Void)? = nil) {
        self.client = client
        self.gateway = gateway
        self.profile = profile
        self.cwd = cwd
        self.sessionID = sessionID
        self.runtimeSessionID = runtimeSessionID
        self.turnBusy = turnBusy
        self.insertIntoComposer = insertIntoComposer
        self.submitToChat = submitToChat
        self.startSession = startSession
        self.close = close
    }
}

/// The panel's tabs, in the desktop's order. The terminal runs on the desktop's own machine and isn't ported.
enum WorkspaceTab: String, CaseIterable, Identifiable {
    case terminal, files, review

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .review: return "Review"
        }
    }
}

/// Pushed screens.
enum WorkspaceRoute: Hashable {
    case folder(String)
    case file(WorkspaceEntry)
    case diff(ReviewFile)
    case worktrees
    case branches
    case pullRequests
}

/// Per-device view preferences (the desktop persists the same ones in local storage).
enum WorkspacePrefs {
    private static let scopeKey = "hermes.workspace.reviewScope"
    private static let treeKey = "hermes.workspace.reviewTreeMode"
    private static let commitKey = "hermes.workspace.reviewCommitDefault"
    private static let ignoredKey = "hermes.workspace.showIgnoredRoots"
    private static let tabKey = "hermes.workspace.tab"

    static var scope: ReviewScope {
        get { UserDefaults.standard.string(forKey: scopeKey).flatMap(ReviewScope.init(rawValue:)) ?? .uncommitted }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: scopeKey) }
    }

    /// true: folder tree (the desktop's default); false: flat list.
    static var treeMode: Bool {
        get { UserDefaults.standard.object(forKey: treeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: treeKey) }
    }

    /// The commit button's remembered action: plain commit, or commit and push.
    static var commitAndPush: Bool {
        get { UserDefaults.standard.bool(forKey: commitKey) }
        set { UserDefaults.standard.set(newValue, forKey: commitKey) }
    }

    static var tab: WorkspaceTab {
        get { UserDefaults.standard.string(forKey: tabKey).flatMap(WorkspaceTab.init(rawValue:)).flatMap { $0 == .terminal ? nil : $0 } ?? .files }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: tabKey) }
    }

    /// "Show gitignored files" is per project root and per host, as on the desktop.
    static func showsIgnored(root: String, host: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: ignoredKey) ?? []).contains(key(root, host))
    }

    static func setShowsIgnored(_ show: Bool, root: String, host: URL) {
        var roots = UserDefaults.standard.stringArray(forKey: ignoredKey) ?? []
        let key = key(root, host)
        roots.removeAll { $0 == key }
        if show { roots.append(key) }
        UserDefaults.standard.set(Array(roots.suffix(200)), forKey: ignoredKey)
    }

    private static func key(_ root: String, _ host: URL) -> String {
        "\(host.host ?? ""):\(host.port ?? 0)|\(WorkspacePath.clean(root))"
    }
}

/// HEAD per repository, recorded when a turn starts there: the Last turn scope's base. Bounded like the desktop's
/// (the least recently recorded repository drops first).
@MainActor
final class WorkspaceTurnBase {
    static let shared = WorkspaceTurnBase()
    static let capacity = 8

    private var bases: [(repo: String, sha: String)] = []

    func base(for repo: String) -> String? {
        let key = WorkspacePath.clean(repo)
        return bases.last { $0.repo == key }?.sha
    }

    func record(_ sha: String, for repo: String) {
        let key = WorkspacePath.clean(repo)
        bases.removeAll { $0.repo == key }
        while bases.count >= Self.capacity { bases.removeFirst() }
        bases.append((key, sha))
    }

    /// Reads HEAD in `repo` and records it.
    func capture(client: DashboardClient, repo: String) async {
        guard let sha = try? await client.revParse(repo, ref: "HEAD") else { return }
        record(sha, for: repo)
    }
}

// MARK: - Files

/// The file browser: folder listings under the session's folder, filtered like the desktop's tree (noise folders,
/// then the repository's .gitignore unless the project shows ignored files), with git change tints.
@MainActor
final class WorkspaceFilesModel: ObservableObject {
    enum FolderState: Equatable {
        case loading
        case loaded([WorkspaceEntry])
        case failed(String)
    }

    let client: DashboardClient
    let profile: String?
    @Published private(set) var root: String?
    /// True when the session has no folder and the tree shows the profile's default one.
    @Published private(set) var rootIsDefault = false
    @Published private(set) var folders: [String: FolderState] = [:]
    @Published private(set) var showIgnored = false
    @Published private(set) var changes: [String: GitChangeKind] = [:]
    @Published private(set) var resolvingDefault = false

    private var raw: [String: [WorkspaceEntry]] = [:]
    private var gitRoots: [String: String?] = [:]
    private var gitignores: [String: GitignoreRules?] = [:]
    private var nestedRepos: [String: Bool] = [:]
    private var generation = 0

    init(client: DashboardClient, profile: String?) {
        self.client = client
        self.profile = profile
    }

    /// Points the tree at `folder`, dropping what was read under another root.
    func setRoot(_ folder: String?, isDefault: Bool = false) {
        let cleaned = folder.map(WorkspacePath.clean).flatMap(WorkspacePath.nonBlank)
        guard cleaned != root || isDefault != rootIsDefault else { return }
        generation += 1
        root = cleaned
        rootIsDefault = isDefault
        folders = [:]
        raw = [:]
        gitRoots = [:]
        gitignores = [:]
        nestedRepos = [:]
        changes = [:]
        showIgnored = cleaned.map { WorkspacePrefs.showsIgnored(root: $0, host: client.base) } ?? false
    }

    /// No session folder: browse the profile's default one (`terminal.cwd`, else home).
    func useDefaultFolder() async throws {
        resolvingDefault = true
        defer { resolvingDefault = false }
        guard let folder = try await client.workspaceDefaultCwd(profile: profile)?.cwd else {
            throw DashboardError.rpc("Hermes didn't name a default folder.")
        }
        setRoot(folder, isDefault: true)
        await load(folder)
    }

    func state(_ folder: String) -> FolderState? { folders[WorkspacePath.clean(folder)] }

    /// Reads `folder` (again with `force`). A refresh keeps what is on screen until the new listing arrives.
    func load(_ folder: String, force: Bool = false) async {
        let folder = WorkspacePath.clean(folder)
        if !force, let state = folders[folder], state != .loading { return }
        if folders[folder] == nil { folders[folder] = .loading }
        let generation = generation
        do {
            let listing = try await client.workspaceList(folder, profile: profile)
            guard generation == self.generation else { return }
            if let error = listing.error {
                folders[folder] = .failed(WorkspaceListing.describe(error))
                return
            }
            raw[folder] = listing.entries
            let visible = await filter(listing.entries, folder: folder)
            guard generation == self.generation else { return }
            folders[folder] = .loaded(visible)
        } catch {
            guard generation == self.generation, !error.isCancellation else { return }
            if case .loaded? = folders[folder] { return }
            folders[folder] = .failed(error.dashboardMessage)
        }
    }

    /// Re-reads every folder on screen and the git tints.
    func refresh(_ visible: [String]) async {
        gitRoots = [:]
        gitignores = [:]
        nestedRepos = [:]
        await withTaskGroup(of: Void.self) { group in
            for folder in Set(visible.map(WorkspacePath.clean)) { group.addTask { await self.load(folder, force: true) } }
            group.addTask { await self.refreshChanges() }
        }
    }

    /// The repository's changed files, for tinting rows.
    func refreshChanges() async {
        guard let root, let repo = await gitRoot(root) else {
            changes = [:]
            return
        }
        let status = try? await client.gitStatus(repo)
        changes = GitChangeKind.map(status, repoRoot: repo)
    }

    func changeKind(_ path: String) -> GitChangeKind? {
        GitChangeKind.kind(for: path, in: changes)
    }

    func setShowIgnored(_ show: Bool) async {
        guard let root, show != showIgnored else { return }
        WorkspacePrefs.setShowsIgnored(show, root: root, host: client.base)
        showIgnored = show
        // Every loaded listing was filtered under the old setting.
        let generation = generation
        for (folder, entries) in raw {
            let visible = await filter(entries, folder: folder)
            guard generation == self.generation else { return }
            folders[folder] = .loaded(visible)
        }
    }

    /// Forgets `folder`'s listing and the .gitignore rules read there (after a change inside it).
    func invalidate(_ folder: String) {
        let folder = WorkspacePath.clean(folder)
        gitignores[folder] = nil
        raw[folder] = nil
    }

    // MARK: Ignore filtering (files/ipc.ts)

    private func filter(_ entries: [WorkspaceEntry], folder: String) async -> [WorkspaceEntry] {
        let floor = showIgnored ? WorkspaceExclusions.showIgnored : WorkspaceExclusions.always
        let kept = entries.filter { !floor.contains($0.name) }
        guard !showIgnored, let root else { return kept }
        // The rules of the listed folder's own repository: a nested repo's tree follows only its .gitignore chain.
        let repo: String?
        if let own = await gitRoot(folder) { repo = own } else { repo = await gitRoot(root) }
        guard let repo else { return kept }
        var rules: [GitignoreRules] = []
        for folder in Self.ancestors(from: repo, to: folder) {
            if let found = await gitignore(in: folder) { rules.append(found) }
        }
        guard !rules.isEmpty else { return kept }
        var visible: [WorkspaceEntry] = []
        for entry in kept {
            if !Self.isIgnored(entry, by: rules) {
                visible.append(entry)
            } else if entry.isDirectory, await isNestedRepoRoot(entry.path) {
                // A repository inside the project stays visible even when the parent ignores it.
                visible.append(entry)
            }
        }
        return visible
    }

    static func isIgnored(_ entry: WorkspaceEntry, by rules: [GitignoreRules]) -> Bool {
        rules.contains { rule in
            guard let relative = WorkspacePath.relative(entry.path, to: rule.base), !relative.isEmpty else { return false }
            return rule.ignores(relative, isDirectory: entry.isDirectory)
        }
    }

    /// The repository root, then each folder down to `folder`.
    static func ancestors(from repo: String, to folder: String) -> [String] {
        let repo = WorkspacePath.clean(repo)
        guard let relative = WorkspacePath.relative(folder, to: repo), !relative.isEmpty else { return [repo] }
        var folders = [repo]
        var current = repo
        for part in relative.split(separator: "/") {
            guard let next = WorkspacePath.join(current, String(part)) else { break }
            folders.append(next)
            current = next
        }
        return folders
    }

    private func gitRoot(_ path: String) async -> String? {
        let key = WorkspacePath.clean(path)
        if let cached = gitRoots[key] { return cached }
        let root = (try? await client.workspaceGitRoot(key, profile: profile)).flatMap { $0 }.map(WorkspacePath.clean)
        gitRoots[key] = .some(root)
        return root
    }

    private func isNestedRepoRoot(_ path: String) async -> Bool {
        let key = WorkspacePath.clean(path)
        if let cached = nestedRepos[key] { return cached }
        let nested = await gitRoot(key) == key
        nestedRepos[key] = nested
        return nested
    }

    /// The .gitignore in `folder`, read only when the listing shows one.
    private func gitignore(in folder: String) async -> GitignoreRules? {
        if let cached = gitignores[folder] { return cached }
        var entries = raw[folder]
        if entries == nil {
            entries = (try? await client.workspaceList(folder, profile: profile))?.entries
            if let entries { raw[folder] = entries }
        }
        guard let file = entries?.first(where: { $0.name == ".gitignore" && !$0.isDirectory }),
              let text = try? await client.workspaceReadText(file.path, profile: profile), !text.binary else {
            gitignores[folder] = .some(nil)
            return nil
        }
        let rules = GitignoreRules(base: folder, text: text.text)
        gitignores[folder] = .some(rules)
        return rules
    }
}

// MARK: - Review

/// The review pane (`store/review.ts`): the changed files for a scope, their diffs, stage / unstage / revert, and the
/// ship flow (commit, push, PR) against the repository holding the session's folder.
@MainActor
final class WorkspaceReviewModel: ObservableObject {
    let client: DashboardClient
    private let profile: String?
    /// Drafts commit messages; follows the chat's connection.
    var gateway: GatewayClient?
    /// The live session whose model a drafted message borrows.
    var runtimeSessionID: String?

    /// The session's folder (or a worktree the panel moved to).
    @Published private(set) var cwd: String?
    /// The repository root holding it; git reports paths relative to it.
    @Published private(set) var repo: String?
    @Published private(set) var isRepo = true
    @Published private(set) var loading = false
    /// The last read failed (the list on screen is the previous one).
    @Published private(set) var error: String?
    @Published private(set) var files: [ReviewFile] = []
    @Published private(set) var base: String?
    @Published private(set) var status: GitRepoStatus?
    @Published private(set) var ship = ReviewShipInfo()
    @Published private(set) var gh: GHAuthState?
    /// The current branch's PR from `pr-list` (title and state for the coding row).
    @Published private(set) var branchPR: BranchPullRequest?
    @Published private(set) var shipBusy = false
    @Published private(set) var generating = false
    @Published var scope: ReviewScope = WorkspacePrefs.scope {
        didSet {
            guard scope != oldValue else { return }
            WorkspacePrefs.scope = scope
            files = []
            Task { await refresh() }
        }
    }
    @Published var treeMode = WorkspacePrefs.treeMode {
        didSet { WorkspacePrefs.treeMode = treeMode }
    }
    @Published var commitAndPush = WorkspacePrefs.commitAndPush {
        didSet { WorkspacePrefs.commitAndPush = commitAndPush }
    }
    /// Folders the user opened or closed in the tree view, keyed by folder id.
    @Published var folderOpen: [String: Bool] = [:]

    private var refreshSeq = 0
    private var generationSeq = 0

    init(client: DashboardClient, gateway: GatewayClient?, profile: String?, runtimeSessionID: String?) {
        self.client = client
        self.gateway = gateway
        self.profile = profile
        self.runtimeSessionID = runtimeSessionID
    }

    var canGenerate: Bool { gateway != nil }

    /// Stage, revert and the ship bar act on the working tree: the Uncommitted scope only.
    var isUncommitted: Bool { scope == .uncommitted }

    func setCwd(_ folder: String?) {
        let cleaned = folder.map(WorkspacePath.clean).flatMap(WorkspacePath.nonBlank)
        guard cleaned != cwd else { return }
        cwd = cleaned
        repo = nil
        files = []
        base = nil
        error = nil
        status = nil
        ship = ReviewShipInfo()
        branchPR = nil
        isRepo = true
        folderOpen = [:]
    }

    /// The repository for the current folder, resolved once; nil off a repository.
    func resolveRepo() async -> String? {
        try? await resolvedRepo()
    }

    private func resolvedRepo() async throws -> String? {
        if let repo { return repo }
        guard let cwd else { return nil }
        let root = try await client.workspaceGitRoot(cwd, profile: profile)
        guard cwd == self.cwd else { return nil }
        repo = root.map(WorkspacePath.clean)
        return repo
    }

    /// Re-reads the changed files and the branch status.
    func refresh() async {
        refreshSeq += 1
        let seq = refreshSeq
        loading = true
        defer { if seq == refreshSeq { loading = false } }
        let repo: String
        do {
            guard let found = try await resolvedRepo() else {
                guard seq == refreshSeq else { return }
                isRepo = false
                files = []
                status = nil
                error = nil
                return
            }
            repo = found
        } catch {
            if seq == refreshSeq, !error.isCancellation { self.error = error.dashboardMessage }
            return
        }
        let scope = scope
        let base = scope == .lastTurn ? WorkspaceTurnBase.shared.base(for: repo) : nil
        let client = client
        async let list = Self.result { try await client.reviewList(repo, scope: scope, base: base) }
        async let probe = Self.result { try await client.gitStatus(repo) }
        let (listed, probed) = await (list, probe)
        guard seq == refreshSeq, repo == self.repo, scope == self.scope else { return }
        isRepo = true
        if case let .success(status) = probed { self.status = status }
        switch listed {
        case let .success(review):
            files = review.files
            self.base = review.base
            error = nil
        case let .failure(failure):
            if !failure.isCancellation { error = failure.dashboardMessage }
        }
    }

    private static func result<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// gh readiness, the branch's PR and its title.
    func refreshShip(refreshAuth: Bool = false) async {
        guard let repo = await resolveRepo() else { return }
        async let info = try? client.shipInfo(repo)
        async let auth = try? client.ghAuth(refresh: refreshAuth)
        let (shipInfo, ghState) = await (info, auth)
        guard repo == self.repo else { return }
        ship = shipInfo ?? ReviewShipInfo()
        gh = ghState
        if let branch = status?.currentBranch, ship.ghReady,
           let prs = try? await client.pullRequests(repo, branches: [branch]) {
            branchPR = prs.prs.first { $0.branch == branch }
        } else {
            branchPR = nil
        }
    }

    func diff(for file: ReviewFile) async throws -> String {
        guard let repo = await resolveRepo() else { return "" }
        let base = scope == .lastTurn ? WorkspaceTurnBase.shared.base(for: repo) : nil
        return try await client.reviewDiff(repo, file: file.path, scope: scope, base: base, staged: file.staged)
    }

    /// Absolute host path of a repo-relative review path.
    func absolutePath(_ relative: String) -> String {
        if relative.hasPrefix("/") || relative.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return relative }
        guard let root = repo ?? cwd else { return relative }
        return WorkspacePath.clean(root) + WorkspacePath.separator(of: root) + relative
    }

    // MARK: Mutations (each re-reads the list after)

    func stage(_ file: String?) async throws {
        guard isUncommitted, let repo = await resolveRepo() else { return }
        try await client.reviewStage(repo, file: file)
        await refresh()
    }

    func unstage(_ file: String?) async throws {
        guard isUncommitted, let repo = await resolveRepo() else { return }
        try await client.reviewUnstage(repo, file: file)
        await refresh()
    }

    func revert(_ file: String?) async throws {
        guard isUncommitted, let repo = await resolveRepo() else { return }
        try await client.reviewRevert(repo, file: file)
        await refresh()
    }

    func commit(message: String, push: Bool) async throws {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let repo = await resolveRepo() else { return }
        shipBusy = true
        defer { shipBusy = false }
        try await client.reviewCommit(repo, message: message, push: push)
        await refresh()
        await refreshShip()
    }

    func push() async throws {
        guard let repo = await resolveRepo() else { return }
        shipBusy = true
        defer { shipBusy = false }
        try await client.reviewPush(repo)
        await refresh()
        await refreshShip()
    }

    /// Creates the PR (pushing first) and answers its URL.
    func createPR() async throws -> URL? {
        guard let repo = await resolveRepo() else { return nil }
        shipBusy = true
        defer { shipBusy = false }
        let url = try await client.reviewCreatePR(repo)
        await refreshShip()
        return URL(string: url)
    }

    /// Drafts a commit message from what will commit; `previous` is the box's text, so pressing again gives a new one.
    func generateMessage(previous: String) async throws -> String {
        guard let gateway, let repo = await resolveRepo() else { return "" }
        generationSeq += 1
        let seq = generationSeq
        generating = true
        defer { if seq == generationSeq { generating = false } }
        let context = try await client.commitContext(repo)
        guard seq == generationSeq, !context.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let params = Self.commitMessageParams(context, previous: previous, profile: profile, sessionID: runtimeSessionID)
        let text = try await gateway.llmOneshot(params, timeout: 120).text.trimmingCharacters(in: .whitespacesAndNewlines)
        return seq == generationSeq ? text : ""
    }

    /// Stops waiting for a drafted message (the model call itself runs out on the host).
    func cancelGenerate() {
        generationSeq += 1
        generating = false
    }

    /// The desktop's request: the `commit_message` template with the diff, the recent subjects and the text to avoid.
    static func commitMessageParams(_ context: CommitContext, previous: String, profile: String?, sessionID: String?) -> LlmOneshotParams {
        LlmOneshotParams(profile: profile, template: "commit_message",
                         variables: ["avoid": .string(previous), "diff": .string(context.diff), "recent_commits": .string(context.recent)],
                         temperature: 0.8, sessionId: sessionID)
    }

    // MARK: Branches and worktrees

    func switchBranch(_ branch: String) async throws {
        guard let repo = await resolveRepo() else { return }
        try await client.branchSwitch(repo, branch: branch)
        await refresh()
        await refreshShip()
    }

    func addWorktree(_ options: WorktreeAddOptions) async throws -> WorktreeAddResult {
        guard let repo = await resolveRepo() else { throw DashboardError.rpc("This folder isn't in a git repository.") }
        return try await client.worktreeAdd(repo, options: options)
    }

    func removeWorktree(_ path: String, force: Bool) async throws {
        guard let repo = await resolveRepo() else { return }
        try await client.worktreeRemove(repo, worktree: path, force: force)
    }
}

// MARK: - Review tree (review/tree-data.ts)

/// A row of the changed-files view: a file, or a folder aggregating its descendants' counts.
struct ReviewTreeNode: Identifiable, Hashable {
    var id: String
    var name: String
    var isDirectory: Bool
    var added: Int
    var removed: Int
    /// Flat list: the parent folder, shown dimmed.
    var folder: String?
    var file: ReviewFile?
    var children: [ReviewTreeNode] = []
}

/// A visible row of the tree view and how deep it sits.
struct ReviewTreeRow: Identifiable, Hashable {
    var node: ReviewTreeNode
    var depth: Int
    var id: String { (node.isDirectory ? "dir:" : "file:") + node.id }
}

enum ReviewTree {
    /// One row per file, sorted by path (the list view).
    static func flat(_ files: [ReviewFile]) -> [ReviewTreeNode] {
        files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.map { file in
            ReviewTreeNode(id: file.path, name: file.name, isDirectory: false, added: file.added, removed: file.removed,
                           folder: file.folder, file: file)
        }
    }

    /// The folder hierarchy; with `compact`, single-child folder chains merge into one `a/b/c` row.
    static func tree(_ files: [ReviewFile], compact: Bool = true) -> [ReviewTreeNode] {
        final class Folder {
            let id: String, name: String
            var added = 0, removed = 0
            var folders: [String: Folder] = [:]
            var files: [ReviewTreeNode] = []
            init(id: String, name: String) { self.id = id; self.name = name }
        }
        let root = Folder(id: "", name: "")
        for file in files {
            var segments = file.path.split(separator: "/").map(String.init)
            let name = segments.popLast() ?? file.path
            var folder = root
            folder.added += file.added
            folder.removed += file.removed
            var prefix = ""
            for segment in segments {
                prefix = prefix.isEmpty ? segment : "\(prefix)/\(segment)"
                let child = folder.folders[segment] ?? Folder(id: prefix, name: segment)
                folder.folders[segment] = child
                child.added += file.added
                child.removed += file.removed
                folder = child
            }
            folder.files.append(ReviewTreeNode(id: file.path, name: name, isDirectory: false, added: file.added,
                                               removed: file.removed, file: file))
        }
        func finalize(_ folder: Folder) -> [ReviewTreeNode] {
            let folders = folder.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { child in
                var node = ReviewTreeNode(id: child.id, name: child.name, isDirectory: true, added: child.added,
                                          removed: child.removed, children: finalize(child))
                while compact, node.children.count == 1, let only = node.children.first, only.isDirectory {
                    node = ReviewTreeNode(id: only.id, name: "\(node.name)/\(only.name)", isDirectory: true, added: only.added,
                                          removed: only.removed, children: only.children)
                }
                return node
            }
            let files = folder.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return folders + files
        }
        return finalize(root)
    }

    /// Every node, descendants included (whether the tree is heavy).
    static func count(_ nodes: [ReviewTreeNode]) -> Int {
        nodes.reduce(0) { $0 + 1 + count($1.children) }
    }

    /// The rows on screen: a folder's children only while it is open, each with its depth.
    static func rows(_ nodes: [ReviewTreeNode], isOpen: (String) -> Bool, depth: Int = 0) -> [ReviewTreeRow] {
        var rows: [ReviewTreeRow] = []
        for node in nodes {
            rows.append(ReviewTreeRow(node: node, depth: depth))
            if node.isDirectory, isOpen(node.id) { rows += self.rows(node.children, isOpen: isOpen, depth: depth + 1) }
        }
        return rows
    }

    /// Past this many rows the tree starts collapsed.
    static let heavyCap = 60
}
