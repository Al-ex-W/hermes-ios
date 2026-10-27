import Foundation

// `/api/git/*`: the host's git for the review pane, the coding row and worktrees (the desktop's `desktop-git.ts`
// remote facade over `hermes_cli/web_routers/git.py`). Reads degrade to empty off a repository; a failed
// mutation answers 400 with git's own message.

// MARK: - Answers

/// Compact working-tree status (`HermesRepoStatus`, `git status --porcelain=v2 --branch`).
struct GitRepoStatus: Hashable {
    struct File: Hashable {
        var path: String
        var staged = false
        var unstaged = false
        var untracked = false
        var conflicted = false

        init(path: String, staged: Bool = false, unstaged: Bool = false, untracked: Bool = false, conflicted: Bool = false) {
            self.path = path
            self.staged = staged
            self.unstaged = unstaged
            self.untracked = untracked
            self.conflicted = conflicted
        }

        init?(row: JSON) {
            guard let path = LenientField.text(row["path"]) else { return nil }
            self.path = path
            staged = LenientField.bool(row["staged"])
            unstaged = LenientField.bool(row["unstaged"])
            untracked = LenientField.bool(row["untracked"])
            conflicted = LenientField.bool(row["conflicted"])
        }
    }

    var branch: String?
    var defaultBranch: String?
    var detached = false
    var ahead = 0
    var behind = 0
    var staged = 0
    var unstaged = 0
    var untracked = 0
    var conflicted = 0
    var changed = 0
    var added = 0
    var removed = 0
    var files: [File] = []

    init() {}

    /// nil for `null` (not a repository).
    init?(response: Any?) {
        guard let row = response as? JSON, !row.isEmpty else { return nil }
        branch = LenientField.text(row["branch"])
        defaultBranch = LenientField.text(row["defaultBranch"])
        detached = LenientField.bool(row["detached"])
        ahead = max(0, LenientField.int(row["ahead"]))
        behind = max(0, LenientField.int(row["behind"]))
        staged = max(0, LenientField.int(row["staged"]))
        unstaged = max(0, LenientField.int(row["unstaged"]))
        untracked = max(0, LenientField.int(row["untracked"]))
        conflicted = max(0, LenientField.int(row["conflicted"]))
        changed = max(0, LenientField.int(row["changed"]))
        added = max(0, LenientField.int(row["added"]))
        removed = max(0, LenientField.int(row["removed"]))
        files = (row["files"] as? [JSON] ?? []).compactMap(File.init(row:))
    }

    /// The checked-out branch, nil when detached.
    var currentBranch: String? { detached ? nil : branch }
}

/// A file tree row's git decoration (`RepoChangeKind`): the file explorer tints changed files.
enum GitChangeKind: Hashable {
    case added, modified, conflicted

    /// Absolute path → change, from `status` probed at `repoRoot` (git reports repo-relative paths).
    static func map(_ status: GitRepoStatus?, repoRoot: String?) -> [String: GitChangeKind] {
        guard let status, let root = repoRoot.map(WorkspacePath.clean), !root.isEmpty else { return [:] }
        var map: [String: GitChangeKind] = [:]
        let separator = WorkspacePath.separator(of: root)
        for file in status.files {
            var relative = file.path
            while relative.hasPrefix("/") || relative.hasPrefix("\\") { relative.removeFirst() }
            while relative.hasSuffix("/") || relative.hasSuffix("\\") { relative.removeLast() }
            guard !relative.isEmpty else { continue }
            let kind: GitChangeKind = file.conflicted ? .conflicted : file.untracked ? .added : .modified
            map[(root.hasSuffix(separator) ? root : root + separator) + relative] = kind
        }
        return map
    }

    /// The kind for `path`: its own, else `added` under an untracked folder.
    static func kind(for path: String, in map: [String: GitChangeKind]) -> GitChangeKind? {
        if let direct = map[WorkspacePath.clean(path)] { return direct }
        var parent = WorkspacePath.parent(path)
        while let folder = parent {
            if map[folder] == .added { return .added }
            parent = WorkspacePath.parent(folder)
        }
        return nil
    }
}

/// The review pane's diff scope (`HermesReviewScope`).
enum ReviewScope: String, CaseIterable, Identifiable, Hashable {
    case uncommitted
    case branch
    case lastTurn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uncommitted: return "Uncommitted"
        case .branch: return "Branch"
        case .lastTurn: return "Last turn"
        }
    }
}

/// One changed file in the review pane (`HermesReviewFile`); `path` is relative to the repository root.
struct ReviewFile: Identifiable, Hashable {
    var path: String
    var added = 0
    var removed = 0
    /// M(odified) A(dded) D(eleted) R(enamed) C(opied) U(nmerged) ?(untracked)
    var status = "M"
    var staged = false

    var id: String { path }

    init(path: String, added: Int = 0, removed: Int = 0, status: String = "M", staged: Bool = false) {
        self.path = path
        self.added = added
        self.removed = removed
        self.status = status
        self.staged = staged
    }

    init?(row: JSON) {
        guard let path = LenientField.text(row["path"]) else { return nil }
        self.path = path
        added = max(0, LenientField.int(row["added"]))
        removed = max(0, LenientField.int(row["removed"]))
        status = LenientField.text(row["status"])?.uppercased() ?? "M"
        staged = LenientField.bool(row["staged"])
    }

    var name: String { WorkspacePath.name(path) }

    /// The parent folder, relative and shown dimmed in the list view.
    var folder: String {
        let parts = path.split(separator: "/")
        return parts.dropLast().joined(separator: "/")
    }
}

struct ReviewList: Hashable {
    var files: [ReviewFile]
    /// The base the scope diffed against (merge-base, turn baseline); nil for uncommitted.
    var base: String?

    init(files: [ReviewFile] = [], base: String? = nil) {
        self.files = files
        self.base = base
    }

    /// Dependency, build and cache folders and OS noise are dropped even when the repo tracks them.
    init(response: JSON) {
        files = (response["files"] as? [JSON] ?? []).compactMap(ReviewFile.init(row:)).filter { !WorkspaceExclusions.isExcludedPath($0.path) }
        base = LenientField.text(response["base"])
    }
}

/// The branch's pull request as `gh pr view` reports it (`HermesReviewPr`).
struct ReviewPullRequest: Hashable {
    var url: String
    var state: String
    var number: Int

    init?(row: Any?) {
        guard let row = row as? JSON, let url = LenientField.text(row["url"]) else { return nil }
        self.url = url
        state = LenientField.text(row["state"]) ?? ""
        number = max(0, LenientField.int(row["number"]))
    }
}

/// gh readiness and this branch's PR (`HermesReviewShipInfo`): drives Create PR / Open PR.
struct ReviewShipInfo: Hashable {
    var ghReady = false
    var pr: ReviewPullRequest?

    init(ghReady: Bool = false, pr: ReviewPullRequest? = nil) {
        self.ghReady = ghReady
        self.pr = pr
    }

    init(response: JSON) {
        ghReady = LenientField.bool(response["ghReady"])
        pr = ReviewPullRequest(row: response["pr"])
    }
}

/// One PR from `review/pr-list` (`HermesBranchPullRequest`).
struct BranchPullRequest: Identifiable, Hashable {
    var branch: String
    var draft: Bool
    var number: Int
    /// `open`, `closed` or `merged`.
    var state: String
    var title: String
    var url: String

    var id: String { "\(number)-\(branch)" }

    init?(row: JSON) {
        guard let branch = LenientField.text(row["branch"]), let url = LenientField.text(row["url"]) else { return nil }
        self.branch = branch
        self.url = url
        draft = LenientField.bool(row["draft"])
        number = max(0, LenientField.int(row["number"]))
        state = LenientField.text(row["state"])?.lowercased() ?? ""
        title = LenientField.text(row["title"]) ?? ""
    }
}

struct RepoPullRequests: Hashable {
    var ghReady = false
    var prs: [BranchPullRequest] = []

    init(response: JSON) {
        ghReady = LenientField.bool(response["ghReady"])
        prs = (response["prs"] as? [JSON] ?? []).compactMap(BranchPullRequest.init(row:))
    }
}

/// A git worktree as `git worktree list` reports it (`HermesGitWorktree`); the main tree comes first.
struct GitWorktree: Identifiable, Hashable {
    var path: String
    var branch: String?
    var isMain = false
    var detached = false
    var locked = false

    var id: String { path }

    init(path: String, branch: String? = nil, isMain: Bool = false, detached: Bool = false, locked: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMain = isMain
        self.detached = detached
        self.locked = locked
    }

    init?(row: JSON) {
        guard let path = LenientField.text(row["path"]) else { return nil }
        self.path = path
        branch = LenientField.text(row["branch"])
        isMain = LenientField.bool(row["isMain"])
        detached = LenientField.bool(row["detached"])
        locked = LenientField.bool(row["locked"])
    }
}

/// A branch for the convert-a-branch picker (`HermesGitBranch`): local heads, then remote-tracking refs without one.
struct GitBranch: Identifiable, Hashable {
    var name: String
    var checkedOut = false
    var isDefault = false
    var isRemote = false
    var worktreePath: String?

    var id: String { (isRemote ? "remote:" : "local:") + name }

    init(name: String, checkedOut: Bool = false, isDefault: Bool = false, isRemote: Bool = false, worktreePath: String? = nil) {
        self.name = name
        self.checkedOut = checkedOut
        self.isDefault = isDefault
        self.isRemote = isRemote
        self.worktreePath = worktreePath
    }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        checkedOut = LenientField.bool(row["checkedOut"])
        isDefault = LenientField.bool(row["isDefault"])
        isRemote = LenientField.bool(row["isRemote"])
        worktreePath = LenientField.text(row["worktreePath"])
    }

    /// What picking it does, as the desktop's convert dialog labels it.
    var actionLabel: String {
        if checkedOut { return "open" }
        if isRemote { return "track remote" }
        return isDefault ? "switch home" : "new worktree"
    }
}

/// A base for a new worktree's branch (`HermesGitBaseBranch`); `isDefault` flags origin/HEAD.
struct GitBaseBranch: Identifiable, Hashable {
    var name: String
    var isRemote = false
    var isDefault = false

    var id: String { name }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        isRemote = LenientField.bool(row["isRemote"])
        isDefault = LenientField.bool(row["isDefault"])
    }
}

/// `gh auth status` on the host (`/api/git/gh-auth`).
struct GHAuthState: Hashable {
    var available = false
    var authenticated = false

    init(available: Bool = false, authenticated: Bool = false) {
        self.available = available
        self.authenticated = authenticated
    }

    init(response: JSON) {
        available = LenientField.bool(response["available"])
        authenticated = LenientField.bool(response["authenticated"])
    }

    var label: String {
        if !available { return "GitHub CLI isn't installed on the host" }
        return authenticated ? "GitHub CLI signed in" : "GitHub CLI isn't signed in"
    }
}

/// What will commit, and the recent subjects, for drafting a message (`review/commit-context`).
struct CommitContext: Hashable {
    var diff: String
    var recent: String

    init(response: JSON) {
        diff = response["diff"] as? String ?? ""
        recent = response["recent"] as? String ?? ""
    }
}

/// A new worktree's options (`worktree/add`): a new branch off `base`, or an existing branch checked out.
struct WorktreeAddOptions: Hashable {
    var name: String?
    var branch: String?
    var base: String?
    var existingBranch: String?
}

struct WorktreeAddResult: Hashable {
    var path: String
    var branch: String
    var repoRoot: String?

    init?(response: JSON) {
        guard let path = LenientField.text(response["path"]) else { return nil }
        self.path = path
        branch = LenientField.text(response["branch"]) ?? ""
        repoRoot = LenientField.text(response["repoRoot"])
    }
}

/// The desktop's `gitRef` sanitizer for a branch name the user types: spaces to dashes, only word characters,
/// `.`, `/` and `-`, no doubled separators, none at either end (the host sanitizes the same way).
enum GitRefName {
    static func sanitize(_ name: String) -> String {
        var value = name
        let rules: [(String, String)] = [(#"\s+"#, "-"), (#"[^\w./-]"#, ""), (#"-{2,}"#, "-"), (#"/{2,}"#, "/"),
                                         (#"\.{2,}"#, "."), (#"^[-./]+|[-./]+$"#, "")]
        for (pattern, replacement) in rules {
            value = value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return value
    }
}

// MARK: - Requests

enum GitCalls {
    static func status(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/status", query: [("path", repo)])
    }

    /// `refresh` skips the host's five-minute cache.
    static func ghAuth(refresh: Bool = false) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/gh-auth", query: [("refresh", refresh ? "true" : nil)])
    }

    static func worktrees(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/worktrees", query: [("path", repo)])
    }

    static func branches(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/branches", query: [("path", repo)])
    }

    static func baseBranches(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/base-branches", query: [("path", repo)])
    }

    static func reviewList(_ repo: String, scope: ReviewScope, base: String?) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/review/list", query: [("path", repo), ("scope", scope.rawValue), ("base", base)])
    }

    /// `file` is repo-relative, as the list reports it.
    static func reviewDiff(_ repo: String, file: String, scope: ReviewScope, base: String?, staged: Bool) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/review/diff", query: [("path", repo), ("file", file), ("scope", scope.rawValue),
                                                             ("base", base), ("staged", staged ? "true" : "false")])
    }

    /// Working tree vs HEAD for one file (the preview's diff view).
    static func fileDiff(_ repo: String, file: String) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/file-diff", query: [("path", repo), ("file", file)])
    }

    static func commitContext(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/review/commit-context", query: [("path", repo)], timeout: 60)
    }

    static func revParse(_ repo: String, ref: String? = "HEAD") -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/review/rev-parse", query: [("path", repo), ("ref", ref)])
    }

    static func shipInfo(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(route: "/api/git/review/ship-info", query: [("path", repo)], timeout: 60)
    }

    static func prList(_ repo: String, branches: [String], numbers: [Int] = []) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/review/pr-list",
                      body: ["path": repo, "branches": branches, "numbers": numbers], timeout: 90)
    }

    /// `file` nil stages everything (`git add -A`).
    static func stage(_ repo: String, file: String?) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/review/stage", body: fileBody(repo, file))
    }

    static func unstage(_ repo: String, file: String?) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/review/unstage", body: fileBody(repo, file))
    }

    /// Discards changes (restores tracked files, removes untracked ones). `file` nil reverts everything.
    static func revert(_ repo: String, file: String?) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/review/revert", body: fileBody(repo, file))
    }

    /// Commits (staging everything first when nothing is staged); `push` pushes after.
    static func commit(_ repo: String, message: String, push: Bool) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/review/commit",
                      body: ["path": repo, "message": message, "push": push], timeout: push ? 180 : 60)
    }

    static func push(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/review/push", body: ["path": repo], timeout: 180)
    }

    /// Pushes, then `gh pr create --fill`; answers the PR's URL.
    static func createPR(_ repo: String) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/review/create-pr", body: ["path": repo], timeout: 180)
    }

    /// Only the options that are set go out, as the host drops empty ones.
    static func worktreeAdd(_ repo: String, options: WorktreeAddOptions) -> WorkspaceCall {
        var body: JSON = ["path": repo]
        let fields: [(String, String?)] = [("name", options.name), ("branch", options.branch), ("base", options.base),
                                           ("existingBranch", options.existingBranch)]
        for (key, value) in fields {
            if let value = WorkspacePath.nonBlank(value) { body[key] = value }
        }
        return WorkspaceCall(method: "POST", route: "/api/git/worktree/add", body: body, timeout: 180)
    }

    static func worktreeRemove(_ repo: String, worktree: String, force: Bool) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/worktree/remove",
                      body: ["path": repo, "worktreePath": worktree, "force": force], timeout: 60)
    }

    static func branchSwitch(_ repo: String, branch: String) -> WorkspaceCall {
        WorkspaceCall(method: "POST", route: "/api/git/branch/switch", body: ["path": repo, "branch": branch], timeout: 60)
    }

    private static func fileBody(_ repo: String, _ file: String?) -> JSON {
        ["path": repo, "file": WorkspacePath.nonBlank(file).map { $0 as Any } ?? NSNull()]
    }
}

// MARK: - Client

extension DashboardClient {
    /// nil off a repository.
    func gitStatus(_ repo: String) async throws -> GitRepoStatus? {
        GitRepoStatus(response: try await workspace(GitCalls.status(repo)))
    }

    func ghAuth(refresh: Bool = false) async throws -> GHAuthState {
        GHAuthState(response: try await workspace(GitCalls.ghAuth(refresh: refresh)) as? JSON ?? [:])
    }

    func gitWorktrees(_ repo: String) async throws -> [GitWorktree] {
        ((try await workspace(GitCalls.worktrees(repo)) as? JSON)?["worktrees"] as? [JSON] ?? []).compactMap(GitWorktree.init(row:))
    }

    func gitBranches(_ repo: String) async throws -> [GitBranch] {
        ((try await workspace(GitCalls.branches(repo)) as? JSON)?["branches"] as? [JSON] ?? []).compactMap(GitBranch.init(row:))
    }

    func gitBaseBranches(_ repo: String) async throws -> [GitBaseBranch] {
        ((try await workspace(GitCalls.baseBranches(repo)) as? JSON)?["branches"] as? [JSON] ?? []).compactMap(GitBaseBranch.init(row:))
    }

    func reviewList(_ repo: String, scope: ReviewScope, base: String?) async throws -> ReviewList {
        ReviewList(response: try await workspace(GitCalls.reviewList(repo, scope: scope, base: base)) as? JSON ?? [:])
    }

    func reviewDiff(_ repo: String, file: String, scope: ReviewScope, base: String?, staged: Bool) async throws -> String {
        (try await workspace(GitCalls.reviewDiff(repo, file: file, scope: scope, base: base, staged: staged)) as? JSON)?["diff"] as? String ?? ""
    }

    func gitFileDiff(_ repo: String, file: String) async throws -> String {
        (try await workspace(GitCalls.fileDiff(repo, file: file)) as? JSON)?["diff"] as? String ?? ""
    }

    func commitContext(_ repo: String) async throws -> CommitContext {
        CommitContext(response: try await workspace(GitCalls.commitContext(repo)) as? JSON ?? [:])
    }

    func revParse(_ repo: String, ref: String? = "HEAD") async throws -> String? {
        LenientField.text((try await workspace(GitCalls.revParse(repo, ref: ref)) as? JSON)?["sha"])
    }

    func shipInfo(_ repo: String) async throws -> ReviewShipInfo {
        ReviewShipInfo(response: try await workspace(GitCalls.shipInfo(repo)) as? JSON ?? [:])
    }

    func pullRequests(_ repo: String, branches: [String], numbers: [Int] = []) async throws -> RepoPullRequests {
        RepoPullRequests(response: try await workspace(GitCalls.prList(repo, branches: branches, numbers: numbers)) as? JSON ?? [:])
    }

    func reviewStage(_ repo: String, file: String?) async throws {
        _ = try await workspace(GitCalls.stage(repo, file: file))
    }

    func reviewUnstage(_ repo: String, file: String?) async throws {
        _ = try await workspace(GitCalls.unstage(repo, file: file))
    }

    func reviewRevert(_ repo: String, file: String?) async throws {
        _ = try await workspace(GitCalls.revert(repo, file: file))
    }

    func reviewCommit(_ repo: String, message: String, push: Bool) async throws {
        _ = try await workspace(GitCalls.commit(repo, message: message, push: push))
    }

    func reviewPush(_ repo: String) async throws {
        _ = try await workspace(GitCalls.push(repo))
    }

    /// The new PR's URL ("" when gh printed none).
    func reviewCreatePR(_ repo: String) async throws -> String {
        LenientField.text((try await workspace(GitCalls.createPR(repo)) as? JSON)?["url"]) ?? ""
    }

    func worktreeAdd(_ repo: String, options: WorktreeAddOptions) async throws -> WorktreeAddResult {
        guard let result = WorktreeAddResult(response: try await workspace(GitCalls.worktreeAdd(repo, options: options)) as? JSON ?? [:]) else {
            throw DashboardError.rpc("Hermes didn't say where the worktree went.")
        }
        return result
    }

    func worktreeRemove(_ repo: String, worktree: String, force: Bool) async throws {
        _ = try await workspace(GitCalls.worktreeRemove(repo, worktree: worktree, force: force))
    }

    func branchSwitch(_ repo: String, branch: String) async throws {
        _ = try await workspace(GitCalls.branchSwitch(repo, branch: branch))
    }
}
