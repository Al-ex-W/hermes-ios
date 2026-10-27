import SwiftUI
import XCTest
@testable import HermesVoice

/// The workspace panel (files and git review): decoders, path handling, query encoding, diff parsing and styling,
/// .gitignore filtering, request bodies and the confirmations that gate destructive actions.
@MainActor
final class WorkspaceTests: XCTestCase {
    private func json(_ text: String) throws -> JSON {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)
    }

    private let base = URL(string: "https://host.example:9119")!

    // MARK: Decoders

    func testFolderListingDecodesEntriesAndErrors() throws {
        let listing = WorkspaceListing(response: try json("""
        {"entries": [{"name": "src", "path": "/r/src", "isDirectory": true},
                     {"path": "/r/README.md", "isDirectory": false},
                     {"name": "x", "path": "  "}, {"name": "no path"},
                     {"name": "old", "path": "/r/old", "is_directory": 1}]}
        """))
        XCTAssertEqual(listing.entries.map(\.name), ["src", "README.md", "old"], "a row without a path is dropped")
        XCTAssertEqual(listing.entries.map(\.isDirectory), [true, false, true])
        XCTAssertNil(listing.error)

        let failed = WorkspaceListing(response: try json(#"{"entries": [], "error": "EACCES"}"#))
        XCTAssertEqual(failed.error, "EACCES")
        XCTAssertEqual(WorkspaceListing.describe("ENOENT"), "The folder doesn't exist on the host.")
        XCTAssertEqual(WorkspaceListing.describe("weird"), "weird")
    }

    func testTextFileDecodesLeniently() throws {
        let file = WorkspaceTextFile(response: try json("""
        {"binary": false, "byteSize": 600000, "language": "python", "mimeType": "text/x-python", "path": "/r/a.py",
         "text": "print(1)\\n", "truncated": true}
        """))
        XCTAssertEqual(file.language, "python")
        XCTAssertEqual(file.byteSize, 600_000)
        XCTAssertTrue(file.truncated)
        XCTAssertFalse(file.binary)
        XCTAssertEqual(file.text, "print(1)\n")
        let odd = WorkspaceTextFile(response: try json(#"{"byteSize": "-4", "language": "", "binary": 1}"#))
        XCTAssertEqual(odd.byteSize, 0)
        XCTAssertEqual(odd.language, "text")
        XCTAssertTrue(odd.binary)
        XCTAssertEqual(odd.text, "")
    }

    func testRepoStatusDecodesAndNullIsNoRepo() throws {
        let status = try XCTUnwrap(GitRepoStatus(response: try json("""
        {"branch": "feat/x", "defaultBranch": "main", "detached": false, "ahead": 2, "behind": 1, "staged": 1,
         "unstaged": 2, "untracked": 1, "conflicted": 0, "changed": 3, "added": 40, "removed": 5,
         "files": [{"path": "a.swift", "staged": true}, {"path": "new/", "untracked": true, "unstaged": true}, {"x": 1}]}
        """)))
        XCTAssertEqual(status.currentBranch, "feat/x")
        XCTAssertEqual(status.defaultBranch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.added, 40)
        XCTAssertEqual(status.files.count, 2)
        XCTAssertTrue(status.files[1].untracked)
        XCTAssertNil(GitRepoStatus(response: NSNull()), "the host answers null off a repository")
        XCTAssertNil(GitRepoStatus(response: nil))
        let detached = try XCTUnwrap(GitRepoStatus(response: try json(#"{"branch": null, "detached": true, "ahead": "x"}"#)))
        XCTAssertNil(detached.currentBranch)
        XCTAssertEqual(detached.ahead, 0)
    }

    func testReviewListDecodesAndDropsNoise() throws {
        let list = ReviewList(response: try json("""
        {"files": [{"path": "src/app.ts", "added": 3, "removed": 1, "status": "m", "staged": true},
                   {"path": "node_modules/.bin/x", "added": 1, "removed": 0, "status": "?"},
                   {"path": "docs/new.md", "added": 12, "status": "?"},
                   {"path": ".DS_Store", "status": "?"}],
         "base": "abc123"}
        """))
        XCTAssertEqual(list.files.map(\.path), ["src/app.ts", "docs/new.md"])
        XCTAssertEqual(list.files[0].status, "M")
        XCTAssertTrue(list.files[0].staged)
        XCTAssertEqual(list.files[1].added, 12)
        XCTAssertEqual(list.files[1].removed, 0)
        XCTAssertEqual(list.files[1].name, "new.md")
        XCTAssertEqual(list.files[1].folder, "docs")
        XCTAssertEqual(list.base, "abc123")
        XCTAssertNil(ReviewList(response: try json(#"{"files": [], "base": null}"#)).base)
    }

    func testShipInfoPullRequestsAndGhAuth() throws {
        let ship = ReviewShipInfo(response: try json(#"{"ghReady": true, "pr": {"url": "https://github.com/o/r/pull/7", "state": "OPEN", "number": 7}}"#))
        XCTAssertTrue(ship.ghReady)
        XCTAssertEqual(ship.pr?.number, 7)
        XCTAssertNil(ReviewShipInfo(response: try json(#"{"ghReady": false, "pr": null}"#)).pr)

        let prs = RepoPullRequests(response: try json("""
        {"ghReady": true, "prs": [{"branch": "feat", "draft": true, "number": 12, "state": "OPEN", "title": "Add x",
                                   "url": "https://github.com/o/r/pull/12"}, {"branch": "nourl"}]}
        """))
        XCTAssertTrue(prs.ghReady)
        XCTAssertEqual(prs.prs.count, 1)
        XCTAssertEqual(prs.prs[0].state, "open")
        XCTAssertTrue(prs.prs[0].draft)

        XCTAssertEqual(GHAuthState(response: try json(#"{"available": false, "authenticated": false}"#)).label,
                       "GitHub CLI isn't installed on the host")
        XCTAssertEqual(GHAuthState(available: true, authenticated: false).label, "GitHub CLI isn't signed in")
        XCTAssertEqual(GHAuthState(available: true, authenticated: true).label, "GitHub CLI signed in")
    }

    func testWorktreesBranchesAndBases() throws {
        let tree = try XCTUnwrap(GitWorktree(row: try json(#"{"path": "/r/.worktrees/x", "branch": "x", "isMain": false, "locked": true}"#)))
        XCTAssertEqual(tree.branch, "x")
        XCTAssertTrue(tree.locked)
        XCTAssertNil(GitWorktree(row: try json(#"{"branch": "x"}"#)))

        let checkedOut = try XCTUnwrap(GitBranch(row: try json(#"{"name": "feat", "checkedOut": true, "worktreePath": "/r/.worktrees/feat"}"#)))
        XCTAssertEqual(checkedOut.actionLabel, "open")
        XCTAssertEqual(GitBranch(name: "main", isDefault: true).actionLabel, "switch home")
        XCTAssertEqual(GitBranch(name: "origin/x", isRemote: true).actionLabel, "track remote")
        XCTAssertEqual(GitBranch(name: "free").actionLabel, "new worktree")
        XCTAssertNotEqual(GitBranch(name: "x").id, GitBranch(name: "x", isRemote: true).id)

        let base = try XCTUnwrap(GitBaseBranch(row: try json(#"{"name": "origin/main", "isRemote": true, "isDefault": true}"#)))
        XCTAssertTrue(base.isDefault)
        XCTAssertEqual(CommitContext(response: try json(#"{"diff": "d", "recent": "r"}"#)).recent, "r")
        XCTAssertEqual(WorktreeAddResult(response: try json(#"{"path": "/r/.worktrees/a", "branch": "hermes/a", "repoRoot": "/r"}"#))?.branch,
                       "hermes/a")
        XCTAssertNil(WorktreeAddResult(response: [:]))
    }

    // MARK: Paths

    func testNewNamesAreOneComponent() {
        XCTAssertEqual(WorkspacePath.join("/r/src", "new folder"), "/r/src/new folder")
        XCTAssertEqual(WorkspacePath.join("/r/src/", "a.txt"), "/r/src/a.txt")
        XCTAssertEqual(WorkspacePath.join("/", "a"), "/a")
        XCTAssertEqual(WorkspacePath.join("C:\\work", "a"), "C:\\work\\a")
        for bad in ["", ".", "..", "a/b", "../x", "a\\b", " lead", "trail ", "nul\0", "two\nlines"] {
            XCTAssertNil(WorkspacePath.join("/r", bad), "rejects \(bad.debugDescription)")
        }
    }

    func testRelativePathsStayInside() {
        XCTAssertEqual(WorkspacePath.relative("/repo/src/a.ts", to: "/repo"), "src/a.ts")
        XCTAssertEqual(WorkspacePath.relative("/repo/", to: "/repo"), "")
        XCTAssertNil(WorkspacePath.relative("/repo2/a", to: "/repo"), "a sibling with the same prefix is outside")
        XCTAssertNil(WorkspacePath.relative("/repo/../etc/passwd", to: "/repo"), "climbing out never counts as inside")
        XCTAssertNil(WorkspacePath.relative("/other", to: "/repo"))
        XCTAssertEqual(WorkspacePath.relative("/a/b", to: "/"), "a/b")
        XCTAssertEqual(WorkspacePath.relative("C:\\w\\x.txt", to: "C:\\w"), "x.txt")
        XCTAssertTrue(WorkspacePath.isUnder("/repo", "/repo/x"))
        XCTAssertFalse(WorkspacePath.isUnder("/repo/x", "/repo"))
    }

    func testNamesParentsAndCrumbs() {
        XCTAssertEqual(WorkspacePath.name("/r/src/"), "src")
        XCTAssertEqual(WorkspacePath.name("/"), "/")
        XCTAssertEqual(WorkspacePath.parent("/r/src"), "/r")
        XCTAssertEqual(WorkspacePath.parent("/r"), "/")
        XCTAssertNil(WorkspacePath.parent("/"))
        XCTAssertEqual(WorkspacePath.parent("C:\\w"), "C:\\")
        XCTAssertNil(WorkspacePath.parent("C:\\"))
        XCTAssertEqual(WorkspacePath.clean("  /r/x//  "), "/r/x")

        let crumbs = WorkspacePath.crumbs(root: "/home/me/proj", path: "/home/me/proj/src/ui")
        XCTAssertEqual(crumbs.map(\.name), ["proj", "src", "ui"])
        XCTAssertEqual(crumbs.map(\.path), ["/home/me/proj", "/home/me/proj/src", "/home/me/proj/src/ui"])
        XCTAssertEqual(WorkspacePath.crumbs(root: "/p", path: "/p").map(\.name), ["p"])
        XCTAssertEqual(WorkspacePath.crumbs(root: "/p", path: "/q/r").map(\.path), ["/", "/q", "/q/r"],
                       "outside the root the trail starts at /")
    }

    func testComposerReferences() {
        XCTAssertEqual(WorkspacePath.refText(path: "/r/src/a.ts", isDirectory: false, cwd: "/r"), "@file:src/a.ts")
        XCTAssertEqual(WorkspacePath.refText(path: "/r/src", isDirectory: true, cwd: "/r/"), "@folder:src")
        XCTAssertEqual(WorkspacePath.refText(path: "/elsewhere/a.ts", isDirectory: false, cwd: "/r"), "@file:/elsewhere/a.ts")
        XCTAssertEqual(WorkspacePath.refText(path: "/r/my file.md", isDirectory: false, cwd: "/r"), "@file:`my file.md`")
        XCTAssertEqual(WorkspacePath.formatRefValue("a`b c"), "\"a`b c\"")
        XCTAssertEqual(WorkspacePath.formatRefValue("a`b\"c d"), "'a`b\"c d'")
        XCTAssertEqual(WorkspacePath.formatRefValue("plain/path.ts"), "plain/path.ts")
        XCTAssertEqual(WorkspacePath.contextPath("/r/x", cwd: nil), "/r/x")
        XCTAssertEqual(WorkspacePath.safeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(WorkspacePath.safeFileName("C:\\dir\\a:b.txt"), "a-b.txt")
        XCTAssertEqual(WorkspacePath.safeFileName(".."), "file")
    }

    // MARK: Encoding

    func testQueryValuesAreEncodedOnceAndStrictly() throws {
        XCTAssertEqual(WorkspaceQuery.encode("a+b c%20&=/é#?"), "a%2Bb%20c%2520%26%3D%2F%C3%A9%23%3F")
        XCTAssertEqual(WorkspaceQuery.encode("safe-._~AZaz09"), "safe-._~AZaz09")

        let path = "/srv/my repo/c++ & notes/100%.md"
        let url = try XCTUnwrap(WorkspaceCalls.readText(path, profile: "work").url(base: base))
        XCTAssertEqual(url.absoluteString,
                       "https://host.example:9119/api/fs/read-text?path=%2Fsrv%2Fmy%20repo%2Fc%2B%2B%20%26%20notes%2F100%25.md&profile=work")
        // Decoding once gives the path back exactly: it was not encoded twice.
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "path" }?.value, path)
        // A server reading `+` as a space still sees a plus.
        XCTAssertFalse(url.query!.contains("+"))
    }

    func testBlankOptionalQueryValuesAreLeftOut() throws {
        XCTAssertEqual(WorkspaceCalls.list("/r", profile: nil).url(base: base)?.query, "path=%2Fr")
        XCTAssertEqual(WorkspaceCalls.list("/r", profile: "  ").url(base: base)?.query, "path=%2Fr")
        XCTAssertEqual(WorkspaceCalls.defaultCwd(profile: nil).url(base: base)?.absoluteString, "https://host.example:9119/api/fs/default-cwd")
        XCTAssertEqual(WorkspaceCalls.download("/r/a b", profile: nil, sessionID: "s1").url(base: base)?.query,
                       "path=%2Fr%2Fa%20b&session_id=s1")
        let prefixed = URL(string: "https://host.example/hermes/")!
        XCTAssertEqual(GitCalls.status("/r").url(base: prefixed)?.absoluteString, "https://host.example/hermes/api/git/status?path=%2Fr")
        XCTAssertEqual(GitCalls.ghAuth().url(base: base)?.query, nil)
        XCTAssertEqual(GitCalls.ghAuth(refresh: true).url(base: base)?.query, "refresh=true")
    }

    func testReviewQueries() throws {
        let diff = GitCalls.reviewDiff("/r", file: "src/a b.ts", scope: .uncommitted, base: nil, staged: true)
        XCTAssertEqual(diff.route, "/api/git/review/diff")
        XCTAssertEqual(diff.url(base: base)?.query, "path=%2Fr&file=src%2Fa%20b.ts&scope=uncommitted&staged=true")
        let lastTurn = GitCalls.reviewList("/r", scope: .lastTurn, base: "abc")
        XCTAssertEqual(lastTurn.url(base: base)?.query, "path=%2Fr&scope=lastTurn&base=abc")
        XCTAssertEqual(GitCalls.reviewList("/r", scope: .branch, base: nil).url(base: base)?.query, "path=%2Fr&scope=branch")
        XCTAssertEqual(GitCalls.fileDiff("/r", file: "/r/x.swift").url(base: base)?.query, "path=%2Fr&file=%2Fr%2Fx.swift")
        XCTAssertEqual(GitCalls.revParse("/r").url(base: base)?.query, "path=%2Fr&ref=HEAD")
    }

    // MARK: Request bodies

    func testGitMutationBodies() {
        let stageAll = GitCalls.stage("/r", file: nil)
        XCTAssertEqual(stageAll.method, "POST")
        XCTAssertEqual(stageAll.route, "/api/git/review/stage")
        XCTAssertEqual(stageAll.bodyText, #"{"file":null,"path":"\/r"}"#, "no file stages everything")
        XCTAssertEqual(GitCalls.unstage("/r", file: "a.ts").bodyText, #"{"file":"a.ts","path":"\/r"}"#)
        XCTAssertEqual(GitCalls.revert("/r", file: " ").bodyText, #"{"file":null,"path":"\/r"}"#)
        XCTAssertEqual(GitCalls.revert("/r", file: "a.ts").route, "/api/git/review/revert")

        let commit = GitCalls.commit("/r", message: "feat: x", push: true)
        XCTAssertEqual(commit.bodyText, #"{"message":"feat: x","path":"\/r","push":true}"#)
        XCTAssertGreaterThan(commit.timeout, GitCalls.commit("/r", message: "m", push: false).timeout, "a push waits longer")
        XCTAssertEqual(GitCalls.push("/r").bodyText, #"{"path":"\/r"}"#)
        XCTAssertEqual(GitCalls.createPR("/r").route, "/api/git/review/create-pr")
        XCTAssertEqual(GitCalls.prList("/r", branches: ["a", "b"]).bodyText, #"{"branches":["a","b"],"numbers":[],"path":"\/r"}"#)
        XCTAssertEqual(GitCalls.branchSwitch("/r", branch: "main").bodyText, #"{"branch":"main","path":"\/r"}"#)
        XCTAssertEqual(GitCalls.worktreeRemove("/r", worktree: "/r/.worktrees/x", force: false).bodyText,
                       #"{"force":false,"path":"\/r","worktreePath":"\/r\/.worktrees\/x"}"#)
        XCTAssertEqual(GitCalls.worktreeAdd("/r", options: WorktreeAddOptions(name: "x", branch: "x", base: " ", existingBranch: nil)).bodyText,
                       #"{"branch":"x","name":"x","path":"\/r"}"#, "unset options stay out")
        XCTAssertEqual(GitCalls.worktreeAdd("/r", options: WorktreeAddOptions(existingBranch: "origin/feat")).bodyText,
                       #"{"existingBranch":"origin\/feat","path":"\/r"}"#)
    }

    func testCommitMessageRequest() throws {
        let context = CommitContext(response: ["diff": "diff --git a b", "recent": "feat: one\nfix: two"])
        let params = WorkspaceReviewModel.commitMessageParams(context, previous: "old", profile: "work", sessionID: "rt1")
        let data = try JSONEncoder().encode(params)
        let body = try json(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(body["template"] as? String, "commit_message")
        XCTAssertEqual(body["session_id"] as? String, "rt1")
        XCTAssertEqual(body["profile"] as? String, "work")
        XCTAssertEqual(body["temperature"] as? Double, 0.8)
        XCTAssertEqual(body["variables"] as? [String: String], ["avoid": "old", "diff": "diff --git a b", "recent_commits": "feat: one\nfix: two"])
        XCTAssertNil(body["max_tokens"])
    }

    func testFileRouteRefusalsAreNotSignOuts() {
        XCTAssertFalse(DashboardClient.isAuthRefusal(Data(#"{"detail": "Access to sensitive files is not allowed"}"#.utf8)))
        XCTAssertFalse(DashboardClient.isAuthRefusal(Data(#"{"detail": "Path is outside the managed read boundary"}"#.utf8)))
        XCTAssertTrue(DashboardClient.isAuthRefusal(Data(#"{"detail": "Unauthorized"}"#.utf8)))
        XCTAssertTrue(DashboardClient.isAuthRefusal(Data("<html>Forbidden</html>".utf8)))
        XCTAssertTrue(DashboardClient.isAuthRefusal(Data()))
    }

    // MARK: Diffs

    private let sampleDiff = """
    diff --git a/src/a.ts b/src/a.ts
    index 1111111..2222222 100644
    --- a/src/a.ts
    +++ b/src/a.ts
    @@ -1,4 +1,4 @@
     import x
    -const a = 1
    +const a = 2
       indented
    @@ -10,2 +10,3 @@ function f() {
     keep
    +added line
    \\ No newline at end of file
    """

    func testDiffParseDropsHeadersAndTracksLineNumbers() {
        let lines = WorkspaceDiffParser.parse(sampleDiff)
        XCTAssertEqual(lines.map(\.kind), [.context, .remove, .add, .context, .context, .context, .add])
        XCTAssertEqual(lines.map(\.text), ["import x", "const a = 1", "const a = 2", "  indented", "", "keep", "added line"],
                       "markers stripped, indentation kept, a blank row between hunks")
        XCTAssertEqual(lines[0].oldNumber, 1)
        XCTAssertEqual(lines[0].newNumber, 1)
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].newNumber, 2)
        XCTAssertNil(lines[2].oldNumber)
        XCTAssertNil(lines[4].newNumber, "the separator has no numbers")
        XCTAssertEqual(lines[5].newNumber, 10)
        XCTAssertEqual(lines[6].newNumber, 11)
        XCTAssertEqual(WorkspaceDiffParser.counts(lines).added, 2)
        XCTAssertEqual(WorkspaceDiffParser.counts(lines).removed, 1)
    }

    func testDiffHeaderStripping() {
        let arrow = "a/src/x.ts → b/src/x.ts\n@@ -1 +1 @@\n-a\n+b"
        XCTAssertEqual(WorkspaceDiffParser.stripFileHeaders(arrow), "@@ -1 +1 @@\n-a\n+b")
        let newFile = "diff --git a/n b/n\nnew file mode 100644\n--- /dev/null\n+++ b/n\n@@ -0,0 +1,2 @@\n+one\n+two"
        XCTAssertEqual(WorkspaceDiffParser.parse(newFile).map(\.text), ["one", "two"])
        XCTAssertEqual(WorkspaceDiffParser.parse(newFile).first?.newNumber, 1)
        // Not a hunked diff: tinted by marker, shown as it is.
        let plain = WorkspaceDiffParser.parse("+added\n-removed\nplain")
        XCTAssertEqual(plain.map(\.kind), [.add, .remove, .context])
        XCTAssertEqual(plain.map(\.text), ["added", "removed", "plain"])
        XCTAssertEqual(WorkspaceDiffParser.kind("+++ b/x"), .context)
        XCTAssertEqual(WorkspaceDiffParser.kind("--- a/x"), .context)
    }

    func testFullFileDiffKeepsEveryLine() {
        let diff = "@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n three\n@@ -5,1 +5,0 @@\n-five"
        let full = "one\nTWO\nthree\nfour"
        let lines = WorkspaceDiffParser.parseFullFile(diff, fullText: full)
        XCTAssertEqual(lines.map(\.text), ["one", "two", "TWO", "three", "four", "five"])
        XCTAssertEqual(lines.map(\.kind), [.context, .remove, .add, .context, .context, .remove])
        XCTAssertEqual(lines.map(\.newNumber), [1, nil, 2, 3, 4, nil])
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertEqual(lines[0].oldNumber, 1)

        let source = WorkspaceDiffParser.parseFullFile("", fullText: "a\nb")
        XCTAssertEqual(source.map(\.newNumber), [1, 2], "a plain source view numbers every line")
        XCTAssertEqual(Set(source.map(\.kind)), [.context])
    }

    func testDiffStyling() {
        XCTAssertEqual(WorkspaceDiffView.background(.add), Theme.Semantic.diffAddBackground)
        XCTAssertEqual(WorkspaceDiffView.background(.remove), Theme.Semantic.diffRemoveBackground)
        XCTAssertEqual(WorkspaceDiffView.background(.context), .clear)
        XCTAssertEqual(WorkspaceDiffView.border(.add), Theme.Semantic.green)
        XCTAssertEqual(WorkspaceDiffView.border(.remove), Theme.Semantic.red)
        XCTAssertEqual(WorkspaceDiffView.border(.context), .clear, "context rows keep a transparent gutter")
        XCTAssertEqual(WorkspaceDiffView.foreground(.add), Theme.Semantic.diffAddForeground)
        XCTAssertEqual(WorkspaceDiffView.foreground(.remove), Theme.Semantic.diffRemoveForeground)
        XCTAssertEqual(WorkspaceDiffView.foreground(.context), Theme.Text.secondary)
    }

    // MARK: Ignore rules

    func testGitignorePatterns() {
        let rules = GitignoreRules(base: "/r", text: """
        # comment
        *.log
        !keep.log
        build/
        /root-only.txt
        docs/**/*.md
        **/tmp
        cache/**
        \\#hash
        trailing.txt   \u{20}
        [ab].txt
        ?.cfg
        Secrets
        """)
        XCTAssertTrue(rules.ignores("debug.log", isDirectory: false))
        XCTAssertTrue(rules.ignores("sub/deep/debug.log", isDirectory: false))
        XCTAssertFalse(rules.ignores("keep.log", isDirectory: false), "! re-includes")
        XCTAssertTrue(rules.ignores("build", isDirectory: true))
        XCTAssertFalse(rules.ignores("build", isDirectory: false), "a folder-only pattern skips files")
        XCTAssertTrue(rules.ignores("pkg/build", isDirectory: true))
        XCTAssertTrue(rules.ignores("root-only.txt", isDirectory: false))
        XCTAssertFalse(rules.ignores("sub/root-only.txt", isDirectory: false), "a leading slash anchors")
        XCTAssertTrue(rules.ignores("docs/a.md", isDirectory: false))
        XCTAssertTrue(rules.ignores("docs/x/y/a.md", isDirectory: false))
        XCTAssertFalse(rules.ignores("other/docs/a.md", isDirectory: false), "a middle slash anchors too")
        XCTAssertTrue(rules.ignores("a/b/tmp", isDirectory: true))
        XCTAssertTrue(rules.ignores("tmp", isDirectory: false))
        XCTAssertTrue(rules.ignores("cache/x", isDirectory: false))
        XCTAssertFalse(rules.ignores("cache", isDirectory: true), "dir/** matches inside, not the folder")
        XCTAssertTrue(rules.ignores("#hash", isDirectory: false))
        XCTAssertTrue(rules.ignores("trailing.txt", isDirectory: false))
        XCTAssertTrue(rules.ignores("a.txt", isDirectory: false))
        XCTAssertFalse(rules.ignores("c.txt", isDirectory: false))
        XCTAssertTrue(rules.ignores("x.cfg", isDirectory: false))
        XCTAssertFalse(rules.ignores("xy.cfg", isDirectory: false))
        XCTAssertTrue(rules.ignores("secrets", isDirectory: true), "matching ignores case, like the desktop")
        XCTAssertFalse(rules.ignores("", isDirectory: true))
        XCTAssertFalse(rules.ignores("src/main.swift", isDirectory: false))
    }

    func testIgnoreFilteringAcrossGitignoreFiles() {
        let rootRules = GitignoreRules(base: "/r", text: "*.tmp\nvendor-cache/")
        let subRules = GitignoreRules(base: "/r/pkg", text: "!keep.tmp\nlocal.txt")
        let rules = [rootRules, subRules]
        XCTAssertTrue(WorkspaceFilesModel.isIgnored(WorkspaceEntry(name: "a.tmp", path: "/r/pkg/a.tmp", isDirectory: false), by: rules))
        XCTAssertTrue(WorkspaceFilesModel.isIgnored(WorkspaceEntry(name: "keep.tmp", path: "/r/pkg/keep.tmp", isDirectory: false), by: rules),
                      "each .gitignore decides on its own, as in the desktop's filter")
        XCTAssertTrue(WorkspaceFilesModel.isIgnored(WorkspaceEntry(name: "local.txt", path: "/r/pkg/local.txt", isDirectory: false), by: rules))
        XCTAssertFalse(WorkspaceFilesModel.isIgnored(WorkspaceEntry(name: "local.txt", path: "/r/local.txt", isDirectory: false), by: rules))
        XCTAssertTrue(WorkspaceFilesModel.isIgnored(WorkspaceEntry(name: "vendor-cache", path: "/r/vendor-cache", isDirectory: true), by: rules))
        XCTAssertEqual(WorkspaceFilesModel.ancestors(from: "/r", to: "/r/pkg/src"), ["/r", "/r/pkg", "/r/pkg/src"])
        XCTAssertEqual(WorkspaceFilesModel.ancestors(from: "/r", to: "/elsewhere"), ["/r"])
        XCTAssertTrue(WorkspaceExclusions.isExcludedPath("node_modules/.bin/x"))
        XCTAssertTrue(WorkspaceExclusions.isExcludedPath(".DS_Store"))
        XCTAssertFalse(WorkspaceExclusions.isExcludedPath("src/building.ts"))
        XCTAssertTrue(WorkspaceExclusions.always.contains("vendor"))
        XCTAssertFalse(WorkspaceExclusions.showIgnored.contains("vendor"), "showing ignored files can reveal vendor/")
    }

    // MARK: Review tree and decorations

    func testReviewTreeAggregatesAndCompacts() {
        let files = [ReviewFile(path: "src/ui/a.swift", added: 3, removed: 1), ReviewFile(path: "src/ui/b.swift", added: 1),
                     ReviewFile(path: "deep/only/child/x.md", added: 2, removed: 2), ReviewFile(path: "README.md", removed: 4)]
        let tree = ReviewTree.tree(files)
        XCTAssertEqual(tree.map(\.name), ["deep/only/child", "src/ui", "README.md"], "folders first, chains compacted")
        XCTAssertEqual(tree[1].added, 4)
        XCTAssertEqual(tree[1].removed, 1)
        XCTAssertEqual(tree[1].children.map(\.name), ["a.swift", "b.swift"])
        XCTAssertEqual(ReviewTree.count(tree), 6)
        XCTAssertEqual(ReviewTree.rows(tree, isOpen: { _ in false }).count, 3)
        XCTAssertEqual(ReviewTree.rows(tree, isOpen: { $0 == "src/ui" }).map(\.depth), [0, 0, 1, 1, 0])

        let flat = ReviewTree.flat(files)
        XCTAssertEqual(flat.map(\.id), ["deep/only/child/x.md", "README.md", "src/ui/a.swift", "src/ui/b.swift"])
        XCTAssertEqual(flat[2].folder, "src/ui")
    }

    func testChangeTints() {
        var status = GitRepoStatus()
        status.files = [GitRepoStatus.File(path: "src/a.ts", unstaged: true), GitRepoStatus.File(path: "new/", untracked: true),
                        GitRepoStatus.File(path: "c.ts", conflicted: true)]
        let map = GitChangeKind.map(status, repoRoot: "/r/")
        XCTAssertEqual(GitChangeKind.kind(for: "/r/src/a.ts", in: map), .modified)
        XCTAssertEqual(GitChangeKind.kind(for: "/r/c.ts", in: map), .conflicted)
        XCTAssertEqual(GitChangeKind.kind(for: "/r/new", in: map), .added)
        XCTAssertEqual(GitChangeKind.kind(for: "/r/new/inner/file.txt", in: map), .added, "inside an untracked folder")
        XCTAssertNil(GitChangeKind.kind(for: "/r/src/b.ts", in: map))
        XCTAssertTrue(GitChangeKind.map(nil, repoRoot: "/r").isEmpty)
    }

    func testBranchNamesAreMadeSafe() {
        XCTAssertEqual(GitRefName.sanitize("my new feature!"), "my-new-feature")
        XCTAssertEqual(GitRefName.sanitize("--a//b..c--"), "a/b.c")
        XCTAssertEqual(GitRefName.sanitize("feat/ok_1"), "feat/ok_1")
        XCTAssertEqual(GitRefName.sanitize("   "), "")
    }

    func testTurnBaseIsBoundedAndKeyedByRepo() {
        let bases = WorkspaceTurnBase()
        bases.record("aaa", for: "/r/")
        XCTAssertEqual(bases.base(for: "/r"), "aaa")
        bases.record("bbb", for: "/r")
        XCTAssertEqual(bases.base(for: "/r"), "bbb")
        for index in 0..<WorkspaceTurnBase.capacity { bases.record("s\(index)", for: "/repo\(index)") }
        XCTAssertNil(bases.base(for: "/r"), "the oldest repository drops first")
        XCTAssertEqual(bases.base(for: "/repo0"), "s0")
    }

    // MARK: Confirmations

    func testDestructiveActionsAskFirst() {
        let asks: [WorkspaceAction] = [.revert(file: "a.ts"), .revert(file: nil), .commit(message: "m", push: true, branch: "x"),
                                       .push(branch: "x"), .createPR(branch: nil), .switchBranch("main"),
                                       .removeWorktree(path: "/r/.worktrees/x", force: false),
                                       .removeWorktree(path: "/r/.worktrees/x", force: true)]
        for action in asks { XCTAssertNotNil(action.confirmation, "\(action) asks first") }
        let runs: [WorkspaceAction] = [.stage(file: nil), .stage(file: "a"), .unstage(file: "a"), .commit(message: "m", push: false, branch: nil)]
        for action in runs { XCTAssertNil(action.confirmation, "\(action) runs at once") }

        XCTAssertEqual(WorkspaceAction.revert(file: nil).confirmation?.title, "Revert all")
        XCTAssertTrue(WorkspaceAction.revert(file: "src/a.ts").confirmation!.message.contains("src/a.ts"))
        XCTAssertTrue(WorkspaceAction.revert(file: nil).confirmation!.destructive)
        XCTAssertFalse(WorkspaceAction.createPR(branch: "f").confirmation!.destructive)
        XCTAssertTrue(WorkspaceAction.createPR(branch: "f").confirmation!.message.contains("“f”"))
        XCTAssertEqual(WorkspaceAction.removeWorktree(path: "/w", force: true).confirmation?.confirmLabel, "Force remove")
    }

    func testGateHoldsUntilConfirmed() async {
        var performed: [WorkspaceAction] = []
        let gate = WorkspaceActionGate { performed.append($0) }

        await gate.request(.stage(file: "a"))
        XCTAssertEqual(performed, [.stage(file: "a")], "a safe action runs at once")
        XCTAssertNil(gate.pending)

        await gate.request(.revert(file: "a"))
        XCTAssertEqual(performed.count, 1, "revert waits for a yes")
        XCTAssertEqual(gate.pending, .revert(file: "a"))
        gate.cancel()
        XCTAssertNil(gate.pending)
        XCTAssertNil(gate.confirm(), "nothing pending, nothing runs")
        XCTAssertEqual(performed.count, 1)

        await gate.request(.push(branch: "x"))
        await gate.confirm()?.value
        XCTAssertEqual(performed, [.stage(file: "a"), .push(branch: "x")])
        XCTAssertNil(gate.pending)
        XCTAssertNil(gate.confirm(), "a confirmed action runs once")
        XCTAssertEqual(performed.count, 2)
    }

    func testDirtyWorktreeRemovalOffersForce() {
        XCTAssertTrue(WorkspacePanelModel.isDirtyWorktree(DashboardError.http(400,
            #"{"detail": "fatal: '/r/.worktrees/x' contains modified or untracked files, use --force to delete it"}"#)))
        XCTAssertFalse(WorkspacePanelModel.isDirtyWorktree(DashboardError.http(400, #"{"detail": "fatal: not a working tree"}"#)))
    }
}
