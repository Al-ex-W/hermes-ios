"""The fake Hermes behind the M5 screens: the files panel and git review, messaging (platforms, onboarding, pairing,
webhooks, gateway start/stop), the learning graph, session import, the agents fleet and the kanban plugin, checked
against the Hermes shapes and the pinned gateway contract. Servers run on ports 9300-9309."""

from __future__ import annotations

import asyncio
import base64
import json
import socket
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

import httpx
import pytest
import uvicorn
import websockets

from fakeclient import CONTRACT_PATH, Contract, Gateway, RpcFailure, signed_in, until
from fake_hermes import ATLAS_TOKENS_PY, DEMO_HOME, FakeHermes, build_app, build_parser, project_path

ATLAS, BEACON = project_path("atlas"), project_path("beacon")
LINKED = f"{ATLAS}/.worktrees/token-refresh"
CONTRACT = Contract(CONTRACT_PATH) if CONTRACT_PATH else None
PORTS = range(9300, 9310)


def contract_problems(*gateways: Gateway) -> list[str]:
    return [p for g in gateways for p in CONTRACT.check_gateway(g)] if CONTRACT else []


def m5_port() -> int:
    for port in PORTS:
        with socket.socket() as s:
            try:
                s.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("ports 9300-9309 are all busy")


@asynccontextmanager
async def serving(**options: Any) -> AsyncIterator[tuple[FakeHermes, str]]:
    """A fake Hermes on a port in 9300-9309, full seed, actions finished only by polls."""
    args = build_parser().parse_args(["--voice-url", "", "--contract", CONTRACT_PATH, "--seed", "full",
                                      "--action-seconds", "0"])
    for name, value in options.items():
        setattr(args, name, value)
    fake = FakeHermes(args)
    server = uvicorn.Server(uvicorn.Config(build_app(fake), host="127.0.0.1", port=m5_port(), log_level="warning",
                                           timeout_graceful_shutdown=1))
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            task.result()
        await asyncio.sleep(0.01)
    port = server.servers[0].sockets[0].getsockname()[1]
    try:
        yield fake, f"127.0.0.1:{port}"
    finally:
        server.should_exit = True
        await task


async def finish(http: httpx.AsyncClient, name: str, polls: int = 10) -> dict[str, Any]:
    """Poll an action until it stops running."""
    status: dict[str, Any] = {}
    for _ in range(polls):
        status = (await http.get(f"/api/actions/{name}/status")).json()
        if not status["running"]:
            break
    return status


def data_url(data: bytes, kind: str = "text/plain") -> str:
    return f"data:{kind};base64,{base64.b64encode(data).decode()}"


# ── files panel ──────────────────────────────────────────────────────────────────────────────────────


def test_fs_and_managed_files_browse_read_write_upload_and_delete():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                out: dict[str, Any] = {}
                out["home"] = (await http.get("/api/fs/list", params={"path": "~"})).json()
                out["hermes"] = (await http.get("/api/fs/list", params={"path": f"{DEMO_HOME}/.hermes"})).json()
                out["atlas"] = (await http.get("/api/fs/list", params={"path": ATLAS})).json()
                out["missing"] = (await http.get("/api/fs/list", params={"path": f"{DEMO_HOME}/nope"})).json()
                out["file"] = (await http.get("/api/fs/list", params={"path": f"{DEMO_HOME}/notes.md"})).json()
                out["no_path"] = (await http.get("/api/fs/list")).status_code
                out["bad_profile"] = (await http.get("/api/fs/list", params={"path": "~", "profile": "nobody"})
                                      ).status_code
                out["root"] = (await http.get("/api/fs/git-root", params={"path": f"{ATLAS}/src/atlas/auth.py"})
                               ).json()
                out["linked_root"] = (await http.get("/api/fs/git-root", params={"path": f"{LINKED}/README.md"})
                                      ).json()
                out["no_root"] = (await http.get("/api/fs/git-root", params={"path": DEMO_HOME})).json()
                out["cwd"] = (await http.get("/api/fs/default-cwd")).json()
                await http.put("/api/config", params={"profile": "research"},
                               json={"config": {"terminal": {"cwd": BEACON}}})
                out["research_cwd"] = (await http.get("/api/fs/default-cwd", params={"profile": "research"})).json()
                saved = await http.post("/api/fs/write-text", json={"path": f"{ATLAS}/docs/new.md", "content": "# New\n"})
                out["saved"] = saved.json()
                out["saved_text"] = (await http.get("/api/fs/read-text", params={"path": f"{ATLAS}/docs/new.md"})
                                     ).json()["text"]
                out["write_errors"] = {label: (await http.post("/api/fs/write-text", json=body)).status_code
                                       for label, body in {
                                           "no parent": {"path": f"{DEMO_HOME}/a/b/c.md", "content": "x"},
                                           "dir": {"path": ATLAS, "content": "x"},
                                           "missing": {"path": f"{DEMO_HOME}/x.md"}}.items()}
                out["managed_home"] = (await http.get("/api/files")).json()
                out["managed_hermes"] = (await http.get("/api/files", params={"path": f"{DEMO_HOME}/.hermes"})).json()
                out["managed_errors"] = {label: (await http.get("/api/files", params={"path": p})).status_code
                                         for label, p in {"relative": "projects", "dotdot": f"{DEMO_HOME}/../x",
                                                          "missing": f"{DEMO_HOME}/nope",
                                                          "file": f"{DEMO_HOME}/notes.md"}.items()}
                read = (await http.get("/api/files/read", params={"path": f"{BEACON}/assets/logo.png"})).json()
                out["read"] = read
                download = await http.get("/api/files/download", params={"path": f"{DEMO_HOME}/notes.md"})
                out["download"] = (download.status_code, download.headers["content-disposition"], download.content)
                up = await http.post("/api/files/upload", json={"path": f"{DEMO_HOME}/inbox/report.txt",
                                                               "data_url": data_url(b"hello\n")})
                out["upload"] = up.json()
                out["upload_errors"] = {label: (await http.post("/api/files/upload", json=body)).status_code
                                        for label, body in {
                                            "exists": {"path": f"{DEMO_HOME}/inbox/report.txt",
                                                       "data_url": data_url(b"x"), "overwrite": False},
                                            "dir": {"path": f"{DEMO_HOME}/inbox", "data_url": data_url(b"x")},
                                            "not data": {"path": f"{DEMO_HOME}/inbox/y.txt", "data_url": "hello"},
                                            "not base64": {"path": f"{DEMO_HOME}/inbox/y.txt",
                                                           "data_url": "data:text/plain,hello"}}.items()}
                streamed = await http.post("/api/files/upload-stream", data={"path": f"{DEMO_HOME}/inbox/photo.png"},
                                           files={"file": ("photo.png", b"\x89PNG\r\n\x1a\nfake", "image/png")})
                out["stream"] = streamed.json()
                out["mkdir"] = (await http.post("/api/files/mkdir", json={"path": f"{DEMO_HOME}/inbox/new/deeper"})
                                ).json()
                out["mkdir_file"] = (await http.post("/api/files/mkdir", json={"path": f"{DEMO_HOME}/notes.md"})
                                     ).status_code
                out["inbox"] = (await http.get("/api/fs/list", params={"path": f"{DEMO_HOME}/inbox"})).json()
                out["delete_full"] = (await http.request("DELETE", "/api/files", json={"path": f"{DEMO_HOME}/inbox"})
                                      ).status_code
                out["delete_file"] = (await http.request("DELETE", "/api/files", json={
                    "path": f"{DEMO_HOME}/inbox/report.txt"})).json()
                out["delete_tree"] = (await http.request("DELETE", "/api/files", json={
                    "path": f"{DEMO_HOME}/inbox", "recursive": True})).json()
                out["delete_root"] = (await http.request("DELETE", "/api/files", json={"path": "/"})).status_code
                out["gone"] = (await http.get("/api/fs/list", params={"path": f"{DEMO_HOME}/inbox"})).json()
        return out

    out = asyncio.run(scenario())
    names = [e["name"] for e in out["home"]["entries"]]
    assert names[:2] == [".hermes", "projects"] and "notes.md" in names, "folders first"
    assert all(set(e) == {"name", "path", "isDirectory"} for e in out["home"]["entries"])
    hermes = {e["name"] for e in out["hermes"]["entries"]}
    assert "images" in hermes and ".env" not in hermes and "config.yaml" not in hermes
    atlas = {e["name"] for e in out["atlas"]["entries"]}
    assert {"src", "docs", ".worktrees", "README.md"} <= atlas and ".git" not in atlas
    assert out["missing"] == {"entries": [], "error": "ENOENT"} and out["file"] == {"entries": [], "error": "ENOTDIR"}
    assert out["no_path"] == 422 and out["bad_profile"] == 404
    assert out["root"] == {"root": ATLAS} and out["linked_root"] == {"root": LINKED} and out["no_root"] == {"root": None}
    assert out["cwd"] == {"cwd": DEMO_HOME, "branch": ""}
    assert out["research_cwd"] == {"cwd": BEACON, "branch": "release/1.4"}
    assert out["saved"] == {"ok": True, "path": f"{ATLAS}/docs/new.md", "byteSize": 6}
    assert out["saved_text"] == "# New\n"
    assert out["write_errors"] == {"no parent": 400, "dir": 400, "missing": 422}
    managed = out["managed_home"]
    assert managed["path"] == DEMO_HOME and managed["parent"] == "/home" and managed["root"] is None
    assert managed["can_change_path"] is True and managed["entries"][0]["is_directory"]
    notes = next(e for e in managed["entries"] if e["name"] == "notes.md")
    assert notes["size"] > 0 and isinstance(notes["mime_type"], str) and isinstance(notes["mtime"], float)
    assert {e["name"] for e in out["managed_hermes"]["entries"]} >= {"images"} and \
        not {".env", "config.yaml"} & {e["name"] for e in out["managed_hermes"]["entries"]}
    assert out["managed_errors"] == {"relative": 400, "dotdot": 400, "missing": 404, "file": 400}
    assert out["read"]["mime_type"] == "image/png" and out["read"]["data_url"].startswith("data:image/png;base64,")
    assert out["download"][0] == 200 and "notes.md" in out["download"][1] and out["download"][2].startswith(b"# Notes")
    assert out["upload"]["ok"] and out["upload"]["entry"]["size"] == 6 and out["upload"]["path"].endswith("report.txt")
    assert out["upload_errors"] == {"exists": 409, "dir": 409, "not data": 400, "not base64": 400}
    assert out["stream"]["entry"]["mime_type"] == "image/png" and out["stream"]["entry"]["size"] == 12
    assert out["mkdir"]["entry"]["is_directory"] and out["mkdir_file"] == 409
    assert [e["name"] for e in out["inbox"]["entries"]] == ["new", "photo.png", "report.txt"]
    assert out["delete_full"] == 409 and out["delete_file"]["ok"] and out["delete_tree"]["ok"]
    assert out["delete_root"] == 400 and out["gone"] == {"entries": [], "error": "ENOENT"}


# ── git review ───────────────────────────────────────────────────────────────────────────────────────


def test_git_reads_status_review_diffs_branches_worktrees_and_prs():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                get = lambda route, **params: http.get(f"/api/git/{route}", params=params)  # noqa: E731
                out: dict[str, Any] = {}
                out["status"] = (await get("status", path=ATLAS)).json()
                out["status_sub"] = (await get("status", path=f"{ATLAS}/src")).json()
                out["linked"] = (await get("status", path=LINKED)).json()
                out["beacon"] = (await get("status", path=BEACON)).json()
                out["none"] = (await get("status", path=DEMO_HOME)).json()
                out["missing"] = (await get("status", path=f"{DEMO_HOME}/nope")).json()
                out["gh"] = (await get("gh-auth", refresh="true")).json()
                out["worktrees"] = (await get("worktrees", path=ATLAS)).json()
                out["branches"] = (await get("branches", path=ATLAS)).json()
                out["bases"] = (await get("base-branches", path=ATLAS)).json()
                out["list"] = (await get("review/list", path=ATLAS)).json()
                out["branch_scope"] = (await get("review/list", path=ATLAS, scope="branch")).json()
                head = (await get("review/rev-parse", path=ATLAS)).json()["sha"]
                parent = (await get("review/rev-parse", path=ATLAS, ref="HEAD~1")).json()["sha"]
                out["shas"] = (head, parent, (await get("review/rev-parse", path=ATLAS, ref="nope")).json())
                out["last_turn"] = (await get("review/list", path=ATLAS, scope="lastTurn", base=parent)).json()
                diff = lambda file, **extra: get("review/diff", path=ATLAS, file=file, **extra)  # noqa: E731
                out["unstaged"] = (await diff("src/atlas/auth.py")).json()["diff"]
                out["staged"] = (await diff("CHANGELOG.md", staged="true")).json()["diff"]
                out["untracked"] = (await diff("src/atlas/tokens.py")).json()["diff"]
                out["deleted"] = (await diff("tests/test_storage.py")).json()["diff"]
                out["dir"] = (await diff("src/atlas")).status_code
                out["branch_diff"] = (await diff("docs/architecture.md", scope="branch")).json()["diff"]
                out["file_diff"] = (await get("file-diff", path=ATLAS, file=f"{ATLAS}/src/atlas/storage.py")).json()
                out["clean_diff"] = (await get("file-diff", path=ATLAS, file="README.md")).json()
                out["context"] = (await get("review/commit-context", path=ATLAS)).json()
                out["ship"] = (await get("review/ship-info", path=LINKED)).json()
                out["ship_main"] = (await get("review/ship-info", path=ATLAS)).json()
                out["prs"] = (await http.post("/api/git/review/pr-list", json={
                    "path": ATLAS, "branches": ["main", "hermes/token-refresh", "feature/rate-limit", "x"],
                    "numbers": [38]})).json()
                out["no_prs"] = (await http.post("/api/git/review/pr-list", json={"path": ATLAS})).json()
                out["non_repo"] = [(await get(route, path=DEMO_HOME)).json() for route in (
                    "worktrees", "branches", "review/list", "review/commit-context", "review/ship-info")]
        return out

    out = asyncio.run(scenario())
    status = out["status"]
    assert status["branch"] == "main" and status["defaultBranch"] == "main" and not status["detached"]
    assert (status["ahead"], status["behind"]) == (1, 0)
    files = {f["path"]: f for f in status["files"]}
    assert files["CHANGELOG.md"] == {"path": "CHANGELOG.md", "staged": True, "unstaged": False, "untracked": False,
                                     "conflicted": False}
    assert files["src/atlas/auth.py"]["unstaged"] and not files["src/atlas/auth.py"]["staged"]
    assert files["src/atlas/storage.py"]["staged"] and files["src/atlas/storage.py"]["unstaged"]
    assert files["src/atlas/tokens.py"]["untracked"] and files["docs/token-flow.md"]["untracked"]
    assert files["tests/test_storage.py"]["unstaged"] and files["src/atlas/clock.py"]["staged"]
    assert (status["staged"], status["unstaged"], status["untracked"], status["changed"]) == (3, 5, 2, 7)
    assert status["added"] > 0 and status["removed"] > 0 and ".worktrees" not in json.dumps(status["files"])
    assert out["status_sub"] == status, "any folder inside the tree reports the whole tree"
    assert out["linked"]["branch"] == "hermes/token-refresh" and (out["linked"]["ahead"], out["linked"]["behind"]) \
        == (1, 0) and [f["path"] for f in out["linked"]["files"]] == ["README.md"]
    assert out["beacon"]["branch"] == "release/1.4" and out["beacon"]["behind"] == 1 and out["beacon"]["changed"] == 0
    assert out["none"] is None and out["missing"] is None
    assert out["gh"] == {"available": True, "authenticated": True}
    assert out["worktrees"] == {"worktrees": [
        {"path": ATLAS, "branch": "main", "isMain": True, "detached": False, "locked": False},
        {"path": LINKED, "branch": "hermes/token-refresh", "isMain": False, "detached": False, "locked": False}]}
    branches = {b["name"]: b for b in out["branches"]["branches"]}
    assert branches["main"]["isDefault"] and branches["main"]["worktreePath"] == ATLAS
    assert branches["hermes/token-refresh"]["checkedOut"] and branches["hermes/token-refresh"]["worktreePath"] == LINKED
    assert not branches["feature/storage-v2"]["checkedOut"]
    assert branches["origin/feature/rate-limit"]["isRemote"] and "origin/main" not in branches
    assert [b["name"] for b in out["branches"]["branches"]][-1] == "origin/feature/rate-limit", "remotes last"
    bases = {b["name"]: b for b in out["bases"]["branches"]}
    assert bases["origin/main"]["isDefault"] and bases["origin/main"]["isRemote"] and not bases["main"]["isDefault"]
    review = {f["path"]: f for f in out["list"]["files"]}
    assert out["list"]["base"] is None and review["src/atlas/tokens.py"]["status"] == "?"
    assert review["src/atlas/tokens.py"]["added"] == ATLAS_TOKENS_PY.count("\n")
    assert review["tests/test_storage.py"]["status"] == "D" and review["src/atlas/clock.py"]["status"] == "A"
    assert review["CHANGELOG.md"] == {"path": "CHANGELOG.md", "added": 3, "removed": 0, "status": "M", "staged": True}
    assert [f["path"] for f in out["list"]["files"]] == sorted(review)
    assert [f["path"] for f in out["branch_scope"]["files"]] == ["docs/architecture.md"]
    assert out["branch_scope"]["base"] and out["branch_scope"]["files"][0]["status"] == "M"
    head, parent, unknown = out["shas"]
    assert len(head) == 40 and len(parent) == 40 and head != parent and unknown == {"sha": None}
    assert out["last_turn"]["base"] == parent
    assert {"docs/architecture.md", "src/atlas/auth.py", "src/atlas/tokens.py"} <= \
        {f["path"] for f in out["last_turn"]["files"]}
    assert out["unstaged"].startswith("diff --git a/src/atlas/auth.py b/src/atlas/auth.py\nindex ")
    assert "+    if now is None:" in out["unstaged"] and "-    now = now or time.time()" in out["unstaged"]
    assert "+## Unreleased" in out["staged"]
    assert "new file mode 100644" in out["untracked"] and "--- /dev/null" in out["untracked"]
    assert "deleted file mode 100644" in out["deleted"] and "+++ /dev/null" in out["deleted"]
    assert out["dir"] == 400
    assert "+# Atlas architecture" in out["branch_diff"]
    assert "+def delete_user(uid):" in out["file_diff"]["diff"] and "+def list_users():" in out["file_diff"]["diff"]
    assert out["clean_diff"] == {"diff": ""}
    context = out["context"]
    assert "CHANGELOG.md" in context["diff"] and "src/atlas/auth.py" not in context["diff"], "staged only"
    assert "# New (untracked) files:\n#   docs/token-flow.md\n#   src/atlas/tokens.py\n" in context["diff"]
    assert context["recent"].splitlines()[:2] == ["Docs: architecture overview", "Release 0.3.0"]
    assert out["ship"] == {"ghReady": True, "pr": {"url": "https://github.com/acme/atlas/pull/42", "state": "OPEN",
                                                   "number": 42}}
    assert out["ship_main"] == {"ghReady": True, "pr": None}, "a fork's PR on main is not ours"
    prs = out["prs"]
    assert prs["ghReady"] and [p["number"] for p in prs["prs"]] == [42, 44, 38]
    assert prs["prs"][1] == {"branch": "feature/rate-limit", "draft": True, "number": 44, "state": "open",
                             "title": "Rate limit /login", "url": "https://github.com/acme/atlas/pull/44"}
    assert out["no_prs"] == {"ghReady": False, "prs": []}
    assert out["non_repo"] == [{"worktrees": []}, {"branches": []}, {"files": [], "base": None},
                               {"diff": "", "recent": ""}, {"ghReady": False, "pr": None}]


def test_git_mutations_stage_commit_push_worktrees_branches_and_prs():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                post = lambda route, **body: http.post(f"/api/git/{route}", json=body)  # noqa: E731
                status = lambda path=ATLAS: http.get("/api/git/status", params={"path": path})  # noqa: E731
                out: dict[str, Any] = {}
                out["stage"] = (await post("review/stage", path=ATLAS, file="src/atlas/auth.py")).json()
                out["after_stage"] = {f["path"]: f for f in (await status()).json()["files"]}
                out["unstage"] = (await post("review/unstage", path=ATLAS, file="CHANGELOG.md")).json()
                out["after_unstage"] = {f["path"]: f for f in (await status()).json()["files"]}
                out["bad_stage"] = (await post("review/stage", path=ATLAS, file="nope.py")).json()
                out["revert"] = (await post("review/revert", path=ATLAS, file="docs/token-flow.md")).json()
                out["revert_file"] = (await post("review/revert", path=ATLAS, file="tests/test_storage.py")).json()
                out["after_revert"] = {f["path"] for f in (await status()).json()["files"]}
                out["restored"] = (await http.get("/api/fs/read-text", params={
                    "path": f"{ATLAS}/tests/test_storage.py"})).status_code
                out["empty_message"] = (await post("review/commit", path=ATLAS, message="  ")).json()
                out["commit"] = (await post("review/commit", path=ATLAS, message="Fix the epoch-zero token\n\nBody",
                                            push=True)).json()
                after = (await status()).json()
                out["after_commit"] = (after["ahead"], after["behind"], after["changed"])
                out["log"] = (await http.get("/api/git/review/commit-context", params={"path": ATLAS})).json()
                out["nothing"] = (await post("review/commit", path=BEACON, message="Again")).json()
                out["rejected"] = (await post("review/push", path=BEACON)).json()
                out["switch_dirty"] = (await post("branch/switch", path=ATLAS, branch="feature/storage-v2")).json()
                out["switch_used"] = (await post("branch/switch", path=ATLAS, branch="hermes/token-refresh")).json()
                out["switch_bad"] = (await post("branch/switch", path=ATLAS, branch="nope")).json()
                out["switch"] = (await post("branch/switch", path=BEACON, branch="main")).json()
                out["beacon_now"] = (await status(BEACON)).json()["branch"]
                added = (await post("worktree/add", path=ATLAS, name="Login copy")).json()
                out["added"] = added
                out["added_status"] = (await status(added["path"])).json()
                out["added_files"] = (await http.get("/api/fs/list", params={"path": added["path"]})).json()
                await http.post("/api/fs/write-text", json={"path": f"{added['path']}/NOTES.md", "content": "wip\n"})
                out["commit_wt"] = (await post("review/commit", path=added["path"], message="Notes for the login copy")
                                    ).json()
                out["pr"] = (await post("review/create-pr", path=added["path"])).json()
                out["pr_again"] = (await post("review/create-pr", path=added["path"])).json()
                out["pr_main"] = (await post("review/create-pr", path=ATLAS)).json()
                out["ship"] = (await http.get("/api/git/review/ship-info", params={"path": added["path"]})).json()
                out["existing"] = (await post("worktree/add", path=ATLAS, existingBranch="feature/storage-v2")).json()
                out["remote"] = (await post("worktree/add", path=ATLAS, existingBranch="origin/feature/rate-limit")
                                 ).json()
                out["remote_again"] = (await post("worktree/add", path=ATLAS,
                                                  existingBranch="origin/feature/rate-limit")).json()
                out["trunk"] = (await post("worktree/add", path=ATLAS, existingBranch="main")).json()
                out["used"] = (await post("worktree/add", path=ATLAS, existingBranch="hermes/token-refresh")).json()
                out["based"] = (await post("worktree/add", path=ATLAS, name="from origin", base="origin/main")).json()
                out["trees"] = (await http.get("/api/git/worktrees", params={"path": ATLAS})).json()["worktrees"]
                out["remove_dirty"] = (await post("worktree/remove", path=ATLAS, worktreePath=LINKED)).json()
                out["remove_main"] = (await post("worktree/remove", path=ATLAS, worktreePath=ATLAS)).json()
                out["remove_none"] = (await post("worktree/remove", path=ATLAS, worktreePath=f"{ATLAS}/src")).json()
                out["remove"] = (await post("worktree/remove", path=ATLAS, worktreePath=LINKED, force=True)).json()
                out["linked_gone"] = (await http.get("/api/fs/list", params={"path": LINKED})).json()
                out["not_repo"] = (await post("review/stage", path=DEMO_HOME)).json()
                await http.post("/api/files/mkdir", json={"path": f"{DEMO_HOME}/projects/fresh"})
                out["fresh"] = (await post("worktree/add", path=f"{DEMO_HOME}/projects/fresh", name="first")).json()
                out["fresh_status"] = (await status(f"{DEMO_HOME}/projects/fresh")).json()
                out["fresh_push"] = (await post("review/push", path=f"{DEMO_HOME}/projects/fresh")).json()
        return out

    out = asyncio.run(scenario())
    assert out["stage"] == {"ok": True} and out["after_stage"]["src/atlas/auth.py"]["staged"]
    assert not out["after_stage"]["src/atlas/auth.py"]["unstaged"]
    assert out["unstage"] == {"ok": True} and "CHANGELOG.md" in out["after_unstage"]
    assert out["after_unstage"]["CHANGELOG.md"]["unstaged"] and not out["after_unstage"]["CHANGELOG.md"]["staged"]
    assert out["bad_stage"] == {"detail": "fatal: pathspec 'nope.py' did not match any files"}
    assert out["revert"] == {"ok": True} and out["revert_file"] == {"ok": True}
    assert "docs/token-flow.md" not in out["after_revert"] and "tests/test_storage.py" not in out["after_revert"]
    assert out["restored"] == 200
    assert out["empty_message"] == {"detail": "Aborting commit due to empty commit message."}
    assert out["commit"] == {"ok": True}
    assert out["after_commit"] == (0, 0, 3), "staged ones committed and pushed; the rest stays"
    assert out["log"]["recent"].splitlines()[0] == "Fix the epoch-zero token"
    assert out["nothing"] == {"detail": "git commit failed"}
    assert "! [rejected]        release/1.4 -> release/1.4 (non-fast-forward)" in out["rejected"]["detail"]
    assert out["switch_dirty"]["detail"].startswith("error: Your local changes to the following files would be "
                                                    "overwritten by checkout:\n\tCHANGELOG.md\n\tsrc/atlas/storage.py\n")
    assert out["switch_used"] == {"detail": f"fatal: 'hermes/token-refresh' is already used by worktree at '{LINKED}'"}
    assert out["switch_bad"] == {"detail": "fatal: invalid reference: nope"}
    assert out["switch"] == {"branch": "main"} and out["beacon_now"] == "main"
    added = out["added"]
    assert added == {"path": f"{ATLAS}/.worktrees/login-copy", "branch": "hermes/login-copy", "repoRoot": ATLAS}
    assert out["added_status"]["branch"] == "hermes/login-copy" and out["added_status"]["changed"] == 0
    assert "README.md" in {e["name"] for e in out["added_files"]["entries"]}
    assert out["commit_wt"] == {"ok": True}
    assert out["pr"] == {"url": "https://github.com/acme/atlas/pull/46"}
    assert "already exists:\nhttps://github.com/acme/atlas/pull/46" in out["pr_again"]["detail"]
    assert "is the same as base branch" in out["pr_main"]["detail"]
    assert out["ship"]["pr"] == {"url": "https://github.com/acme/atlas/pull/46", "state": "OPEN", "number": 46}
    assert out["existing"] == {"path": f"{ATLAS}/.worktrees/feature-storage-v2", "branch": "feature/storage-v2",
                               "repoRoot": ATLAS}
    assert out["remote"] == {"path": f"{ATLAS}/.worktrees/feature-rate-limit", "branch": "feature/rate-limit",
                             "repoRoot": ATLAS}, "a remote branch gets a local one tracking it"
    assert out["remote_again"] == {"detail": "fatal: a branch named 'feature/rate-limit' already exists"}
    assert out["trunk"] == {"path": ATLAS, "branch": "main", "repoRoot": ATLAS}, "the trunk switches the main tree"
    assert out["used"]["detail"].startswith("fatal: 'hermes/token-refresh' is already used by worktree")
    assert out["based"]["branch"] == "hermes/from-origin"
    assert [t["isMain"] for t in out["trees"]] == [True, False, False, False, False, False]
    assert "contains modified or untracked files, use --force" in out["remove_dirty"]["detail"]
    assert out["remove_main"] == {"detail": f"fatal: '{ATLAS}' is a main working tree"}
    assert out["remove_none"]["detail"].endswith("is not a working tree")
    assert out["remove"] == {"removed": LINKED} and out["linked_gone"]["error"] == "ENOENT"
    assert out["not_repo"] == {"detail": "fatal: not a git repository (or any of the parent directories): .git"}
    assert out["fresh"]["repoRoot"] == f"{DEMO_HOME}/projects/fresh" and out["fresh"]["branch"] == "hermes/first"
    assert out["fresh_status"]["branch"] == "main" and out["fresh_status"]["defaultBranch"] == "main"
    assert "'origin' does not appear to be a git repository" in out["fresh_push"]["detail"]


def test_minimal_seed_is_clean_and_gh_signed_out():
    async def scenario():
        async with serving(seed="minimal") as (fake, base):
            async with signed_in(base) as http:
                status = (await http.get("/api/git/status", params={"path": ATLAS})).json()
                gh = (await http.get("/api/git/gh-auth")).json()
                ship = (await http.get("/api/git/review/ship-info", params={"path": ATLAS})).json()
                pr = (await http.post("/api/git/review/create-pr", json={"path": ATLAS})).json()
                trees = (await http.get("/api/git/worktrees", params={"path": ATLAS})).json()
                workspaces = (await http.get("/api/chat/workspaces")).json()
        return status, gh, ship, pr, trees, workspaces

    status, gh, ship, pr, trees, workspaces = asyncio.run(scenario())
    assert status["changed"] == 0 and (status["ahead"], status["behind"]) == (0, 0) and status["files"] == []
    assert gh == {"available": True, "authenticated": False} and ship == {"ghReady": False, "pr": None}
    assert pr["detail"].startswith("gh pr create failed: To get started with GitHub CLI")
    assert len(trees["worktrees"]) == 1
    assert {r["root"] for r in workspaces["repos"]} == {ATLAS, BEACON}
    assert workspaces["home"] == DEMO_HOME and workspaces["default_cwd"] == DEMO_HOME and workspaces["scan_enabled"]
    assert [p["slug"] for p in workspaces["projects"]] == ["atlas", "beacon"]


# ── messaging ────────────────────────────────────────────────────────────────────────────────────────


def test_messaging_platforms_update_test_and_gateway_start_stop(capsys):
    token = "8123456789:AAnotherFakeTokenForTheTestsOnly0000"

    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                out: dict[str, Any] = {}
                out["listed"] = (await http.get("/api/messaging/platforms")).json()
                out["research"] = (await http.get("/api/messaging/platforms", params={"profile": "research"})).json()
                put = lambda pid, body, **params: http.put(  # noqa: E731
                    f"/api/messaging/platforms/{pid}", json=body, params=params)
                out["errors"] = {label: (await put(pid, body)).json()["detail"] for label, (pid, body) in {
                    "unknown": ("pager", {"env": {}}),
                    "foreign key": ("telegram", {"env": {"DISCORD_BOT_TOKEN": "x"}}),
                    "bad token": ("telegram", {"env": {"TELEGRAM_BOT_TOKEN": "nope"}}),
                    "bad ids": ("telegram", {"env": {"TELEGRAM_ALLOWED_USERS": "12,abc"}}),
                    "preview": ("telegram", {"env": {"TELEGRAM_BOT_TOKEN": "«redacted:7012...0000»"}})}.items()}
                out["saved"] = (await put("telegram", {"enabled": True, "env": {"TELEGRAM_BOT_TOKEN": token,
                                                                                 "TELEGRAM_ALLOWED_USERS": "42, 7"}},
                                          profile="research")).json()
                research = (await http.get("/api/messaging/platforms", params={"profile": "research"})).json()
                out["pending"] = next(p for p in research["platforms"] if p["id"] == "telegram")
                out["test_pending"] = (await http.post("/api/messaging/platforms/telegram/test",
                                                       params={"profile": "research"})).json()
                restart = (await http.post("/api/gateway/restart")).json()
                await finish(http, restart["name"])
                research = (await http.get("/api/messaging/platforms", params={"profile": "research"})).json()
                out["connected"] = next(p for p in research["platforms"] if p["id"] == "telegram")["state"]
                out["test"] = (await http.post("/api/messaging/platforms/telegram/test",
                                               params={"profile": "research"})).json()
                out["test_discord"] = (await http.post("/api/messaging/platforms/discord/test")).json()
                out["test_slack"] = (await http.post("/api/messaging/platforms/slack/test")).json()
                out["test_whatsapp"] = (await http.post("/api/messaging/platforms/whatsapp/test")).json()
                out["cleared"] = (await put("discord", {"clear_env": ["DISCORD_BOT_TOKEN"], "enabled": False})).json()
                out["stop"] = (await http.post("/api/gateway/stop")).json()
                out["stop_status"] = (await finish(http, "gateway-stop"))["running"]
                out["status_stopped"] = (await http.get("/api/status")).json()
                out["stopped_state"] = next(p for p in (await http.get("/api/messaging/platforms")).json()["platforms"]
                                            if p["id"] == "telegram")["state"]
                out["research_status"] = (await http.get("/api/status", params={"profile": "research"})).json()
                out["start"] = (await http.post("/api/gateway/start")).json()
                await finish(http, "gateway-start")
                out["status_started"] = (await http.get("/api/status")).json()
        return out

    out = asyncio.run(scenario())
    listed = {p["id"]: p for p in out["listed"]["platforms"]}
    assert list(listed)[:4] == ["telegram", "discord", "slack", "whatsapp"]
    assert out["listed"]["env_path"].endswith("/.hermes/.env")
    assert out["listed"]["gateway_start_command"] == "hermes -p default gateway start"
    telegram = listed["telegram"]
    assert telegram["state"] == "connected" and telegram["enabled"] and telegram["configured"]
    assert telegram["home_channel"]["chat_id"] == "123456789" and telegram["gateway_running"]
    env = {e["key"]: e for e in telegram["env_vars"]}
    assert env["TELEGRAM_BOT_TOKEN"]["is_password"] and env["TELEGRAM_BOT_TOKEN"]["value"] is None
    assert env["TELEGRAM_BOT_TOKEN"]["redacted_value"].startswith("«redacted:")
    assert env["TELEGRAM_ALLOWED_USERS"]["is_list"] and env["TELEGRAM_ALLOWED_USERS"]["value"] == "123456789"
    assert listed["discord"]["state"] == "fatal" and listed["discord"]["error_code"] == "unauthorized"
    assert listed["slack"]["state"] == "disabled" and listed["slack"]["configured"] is False
    assert listed["whatsapp"]["whatsapp_setup"] == {"mode": "", "allowed_users_set": False, "home_channel_set": False}
    assert all(p["state"] == "disabled" for p in out["research"]["platforms"])
    assert out["errors"] == {
        "unknown": "Unknown messaging platform: pager",
        "foreign key": "DISCORD_BOT_TOKEN is not configurable for Telegram",
        "bad token": "Telegram bot token must be the complete token from @BotFather, such as 123456789:ABC…",
        "bad ids": "Telegram allowed users must be comma-separated numeric user IDs.",
        "preview": "Refusing to save a redacted credential preview; re-enter the full secret to replace it."}
    assert out["saved"] == {"ok": True, "platform": "telegram", "hot_served": False}
    assert out["pending"]["state"] == "pending_restart"
    assert out["test_pending"]["ok"] is False and "Restart the gateway" in out["test_pending"]["message"]
    assert out["connected"] == "connected"
    assert out["test"] == {"ok": True, "state": "connected", "auth_posture": "allowlist",
                           "message": "Connected. 2 users allowlisted via TELEGRAM_ALLOWED_USERS."}
    assert out["test_discord"]["ok"] is False and "rejected the bot token" in out["test_discord"]["message"]
    assert out["test_slack"] == {"ok": False, "state": "disabled",
                                 "message": "Slack is disabled. Enable it, then restart the gateway."}
    assert out["test_whatsapp"]["state"] == "disabled"
    assert out["cleared"]["ok"]
    assert out["stop"]["name"] == "gateway-stop" and out["stop_status"] is False
    stopped = out["status_stopped"]
    assert stopped["gateway_running"] is False and stopped["gateway_state"] == "stopped"
    assert stopped["gateway_platforms"] == {} and out["stopped_state"] == "gateway_stopped"
    assert out["research_status"]["gateway_running"] is True, "each profile has its own gateway"
    assert out["start"]["name"] == "gateway-start"
    started = out["status_started"]
    assert started["gateway_running"] and started["gateway_platforms"]["telegram"]["state"] == "connected"
    logged = capsys.readouterr().out
    assert token not in logged and "AAFakeDemoToken" not in logged


def test_telegram_and_whatsapp_onboarding_complete_after_polls_or_the_debug_trigger(capsys):
    async def scenario():
        async with serving(onboarding_polls=2) as (fake, base):
            async with signed_in(base) as http:
                out: dict[str, Any] = {}
                started = (await http.post("/api/messaging/telegram/onboarding/start",
                                           json={"bot_name": "Demo Helper"})).json()
                out["started"] = started
                tid = started["pairing_id"]
                out["early_apply"] = (await http.post(f"/api/messaging/telegram/onboarding/{tid}/apply",
                                                      json={"allowed_user_ids": ["123"]})).status_code
                out["polls"] = [(await http.get(f"/api/messaging/telegram/onboarding/{tid}")).json()
                                for _ in range(2)]
                out["bad_ids"] = (await http.post(f"/api/messaging/telegram/onboarding/{tid}/apply",
                                                  json={"allowed_user_ids": ["me"]})).json()
                out["no_ids"] = (await http.post(f"/api/messaging/telegram/onboarding/{tid}/apply",
                                                 json={"allowed_user_ids": []})).json()
                out["applied"] = (await http.post(f"/api/messaging/telegram/onboarding/{tid}/apply",
                                                  params={"profile": "research"},
                                                  json={"allowed_user_ids": ["123", "123", "456"],
                                                        "profile": "research"})).json()
                out["gone"] = (await http.get(f"/api/messaging/telegram/onboarding/{tid}")).status_code
                out["research_env"] = dict(fake.profiles["research"].env)
                second = (await http.post("/api/messaging/telegram/onboarding/start", json={})).json()
                out["debug"] = (await http.post(f"/api/messaging/debug/onboarding/{second['pairing_id']}/complete")
                                ).json()
                out["debug_ready"] = (await http.get(f"/api/messaging/telegram/onboarding/{second['pairing_id']}")
                                      ).json()["status"]
                out["cancel"] = (await http.delete(f"/api/messaging/telegram/onboarding/{second['pairing_id']}")
                                 ).json()
                out["cancel_again"] = (await http.delete("/api/messaging/telegram/onboarding/nope")).json()
                wa = (await http.post("/api/messaging/whatsapp/onboarding/start",
                                      json={"mode": "self-chat", "profile": "research"})).json()
                out["wa_start"] = wa
                out["wa_busy"] = (await http.post("/api/messaging/whatsapp/onboarding/start",
                                                  json={"profile": "research"})).status_code
                out["wa_bad_mode"] = (await http.post("/api/messaging/whatsapp/onboarding/start",
                                                      json={"mode": "x"})).status_code
                wid = wa["pairing_id"]
                out["wa_polls"] = [(await http.get(f"/api/messaging/whatsapp/onboarding/{wid}")).json()
                                   for _ in range(2)]
                out["wa_apply"] = (await http.post(f"/api/messaging/whatsapp/onboarding/{wid}/apply", json={})).json()
                out["wa_env"] = {k: v for k, v in fake.profiles["research"].env.items() if k.startswith("WHATSAPP")}
                out["wrong_kind"] = (await http.get(f"/api/messaging/telegram/onboarding/{wid}")).status_code
                platforms = (await http.get("/api/messaging/platforms", params={"profile": "research"})).json()
                out["research"] = {p["id"]: p for p in platforms["platforms"]}
        return out

    out = asyncio.run(scenario())
    started = out["started"]
    assert set(started) == {"pairing_id", "suggested_username", "deep_link", "qr_payload", "expires_at"}
    assert started["suggested_username"].startswith("demo_helper_") and started["qr_payload"] == started["deep_link"]
    assert out["early_apply"] == 409
    assert out["polls"][0] == {"status": "waiting", "expires_at": started["expires_at"]}
    ready = out["polls"][1]
    assert ready["status"] == "ready" and ready["bot_username"] == started["suggested_username"]
    assert ready["owner_user_id"].isdigit()
    assert out["bad_ids"] == {"detail": "Allowed Telegram user IDs must be numeric."}
    assert out["no_ids"] == {"detail": "Add at least one allowed Telegram user ID."}
    applied = out["applied"]
    assert applied["ok"] and applied["platform"] == "telegram" and applied["needs_restart"] is False
    assert applied["restart_started"] and applied["restart_action"] == "gateway-restart"
    assert out["gone"] == 404
    assert out["research_env"]["TELEGRAM_ALLOWED_USERS"] == "123,456"
    assert out["research_env"]["TELEGRAM_BOT_TOKEN"].split(":")[0].isdigit()
    assert out["debug"] == {"ok": True, "kind": "telegram"} and out["debug_ready"] == "ready"
    assert out["cancel"] == {"ok": True} and out["cancel_again"] == {"ok": True}
    wa = out["wa_start"]
    assert wa["status"] == "starting" and wa["mode"] == "self-chat" and wa["qr_payload"] is None
    assert out["wa_busy"] == 409 and out["wa_bad_mode"] == 400
    assert out["wa_polls"][0]["status"] == "waiting" and out["wa_polls"][0]["qr_payload"].startswith("2@")
    assert out["wa_polls"][1]["status"] == "connected" and out["wa_polls"][1]["account_phone"] == "15550100123"
    assert out["wa_apply"]["ok"] and out["wa_apply"]["platform"] == "whatsapp"
    assert out["wa_env"] == {"WHATSAPP_MODE": "self-chat", "WHATSAPP_DM_POLICY": "pairing", "WHATSAPP_ENABLED": "true",
                             "WHATSAPP_ALLOWED_USERS": "15550100123"}
    assert out["wrong_kind"] == 404
    assert out["research"]["whatsapp"]["whatsapp_setup"] == {"mode": "self-chat", "allowed_users_set": True,
                                                             "home_channel_set": False}
    assert out["research"]["telegram"]["enabled"] and out["research"]["telegram"]["configured"]
    assert out["research_env"]["TELEGRAM_BOT_TOKEN"] not in capsys.readouterr().out


def test_pairing_approve_revoke_clear_and_the_code_lockout():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                out: dict[str, Any] = {}
                listed = (await http.get("/api/pairing")).json()
                out["listed"] = listed
                out["research"] = (await http.get("/api/pairing", params={"profile": "research"})).json()
                request_id = listed["pending"][0]["request_id"]
                out["approved"] = (await http.post("/api/pairing/approve", json={
                    "platform": "telegram", "request_id": request_id, "profile": "default"})).json()
                out["stale"] = (await http.post("/api/pairing/approve", json={
                    "platform": "telegram", "request_id": request_id})).status_code
                dm = (await http.post("/api/pairing/debug/request", json={
                    "platform": "discord", "user_id": "4242", "user_name": "newbie"})).json()
                out["wrong_codes"] = [(await http.post("/api/pairing/approve", json={
                    "platform": "slack", "code": "WRONG123"})).status_code for _ in range(5)]
                out["by_code"] = (await http.post("/api/pairing/approve", json={
                    "platform": "discord", "code": dm["code"].lower()})).json()
                out["missing"] = (await http.post("/api/pairing/approve", json={"platform": "telegram"})).status_code
                out["revoke"] = (await http.post("/api/pairing/revoke", json={
                    "platform": "telegram", "user_id": "555000111"})).json()
                out["revoke_again"] = (await http.post("/api/pairing/revoke", json={
                    "platform": "telegram", "user_id": "555000111"})).status_code
                out["cleared"] = (await http.post("/api/pairing/clear-pending")).json()
                out["after"] = (await http.get("/api/pairing")).json()
        return out

    out = asyncio.run(scenario())
    pending = out["listed"]["pending"]
    assert [p["platform"] for p in pending] == ["telegram", "discord"]
    assert set(pending[0]) == {"platform", "request_id", "user_id", "user_name", "age_minutes"}
    assert len(pending[0]["request_id"]) == 16 and pending[0]["age_minutes"] == 7 and "code" not in pending[0]
    assert out["listed"]["approved"][0]["user_id"] == "123456789" and "approved_at" in out["listed"]["approved"][0]
    assert out["research"] == {"pending": [], "approved": []}
    assert out["approved"] == {"ok": True, "user": {"user_id": "555000111", "user_name": "Alex Example"}}
    assert out["stale"] == 404
    assert out["wrong_codes"] == [404, 404, 404, 404, 429]
    assert out["by_code"] == {"ok": True, "user": {"user_id": "4242", "user_name": "newbie"}}
    assert out["missing"] == 400 and out["revoke"] == {"ok": True} and out["revoke_again"] == 404
    assert out["cleared"] == {"ok": True, "cleared": 1}
    assert out["after"]["pending"] == [] and {a["user_id"] for a in out["after"]["approved"]} == {"123456789", "4242"}


def test_webhooks_enable_create_toggle_delete(capsys):
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                out: dict[str, Any] = {}
                out["listed"] = (await http.get("/api/webhooks")).json()
                out["research"] = (await http.get("/api/webhooks", params={"profile": "research"})).json()
                out["off"] = (await http.post("/api/webhooks", params={"profile": "research"},
                                              json={"name": "x"})).json()
                out["enable"] = (await http.post("/api/webhooks/enable", params={"profile": "research"})).json()
                created = (await http.post("/api/webhooks", params={"profile": "research"}, json={
                    "name": "Deploy Hook", "events": ["push", " "], "prompt": "Summarize {{head_commit.message}}",
                    "deliver": "telegram", "deliver_only": True, "deliver_chat_id": "123"})).json()
                out["created"] = created
                out["errors"] = {label: (await http.post("/api/webhooks", json=body)).json()["detail"]
                                 for label, body in {"name": {"name": "-bad"},
                                                     "direct log": {"name": "ok", "deliver_only": True}}.items()}
                out["toggle"] = (await http.put("/api/webhooks/deploy-hook/enabled", params={"profile": "research"},
                                                json={"enabled": False})).json()
                out["toggle_missing"] = (await http.put("/api/webhooks/nope/enabled", json={"enabled": True})
                                         ).status_code
                out["after"] = (await http.get("/api/webhooks", params={"profile": "research"})).json()
                out["unnamed_delete"] = (await http.delete("/api/webhooks/deploy-hook")).status_code
                out["delete"] = (await http.delete("/api/webhooks/deploy-hook", params={"profile": "research"})).json()
                out["delete_again"] = (await http.delete("/api/webhooks/deploy-hook", params={"profile": "research"})
                                       ).status_code
        return out

    out = asyncio.run(scenario())
    listed = out["listed"]
    assert listed["enabled"] and listed["base_url"] == "http://localhost:8644"
    routes = {r["name"]: r for r in listed["subscriptions"]}
    assert routes["github-pr"]["url"] == "http://localhost:8644/webhooks/github-pr" and routes["github-pr"]["enabled"]
    assert routes["github-pr"]["secret_set"] and "secret" not in routes["github-pr"]
    assert routes["uptime-alert"]["enabled"] is False
    assert out["research"] == {"enabled": False, "base_url": "http://localhost:8644", "subscriptions": []}
    assert out["off"] == {"detail": "Webhook platform is not enabled. Enable it from the Webhooks page first."}
    assert out["enable"]["ok"] and out["enable"]["enabled"] and out["enable"]["platform"] == "webhook"
    created = out["created"]
    assert created["name"] == "deploy-hook" and created["events"] == ["push"] and created["deliver_only"]
    assert len(created["secret"]) >= 32 and created["secret_set"] and created["enabled"]
    assert out["errors"] == {"name": "Invalid name. Use lowercase alphanumeric with hyphens/underscores.",
                             "direct log": "Direct delivery requires a real target (telegram, discord, …), not 'log'."}
    assert out["toggle"] == {"ok": True, "name": "deploy-hook", "enabled": False} and out["toggle_missing"] == 404
    assert out["after"]["subscriptions"][0]["enabled"] is False and "secret" not in out["after"]["subscriptions"][0]
    assert out["unnamed_delete"] == 400 and out["delete"] == {"ok": True} and out["delete_again"] == 404
    assert created["secret"] not in capsys.readouterr().out


# ── learning graph, plugins, session import, agents ───────────────────────────────────────────────


def test_learning_graph_nodes_edit_and_delete_memories_and_skills():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                out: dict[str, Any] = {}
                graph = (await http.get("/api/learning/graph")).json()
                out["graph"] = graph
                out["research"] = (await http.get("/api/learning/graph", params={"profile": "research"})).json()
                memory_id = next(n["id"] for n in graph["nodes"] if n["kind"] == "memory")
                out["memory"] = (await http.get("/api/learning/node", params={"id": memory_id})).json()
                out["skill"] = (await http.get("/api/learning/node", params={"id": "release-notes"})).json()
                out["unknown"] = (await http.get("/api/learning/node", params={"id": "ghost"})).status_code
                out["edit"] = (await http.put("/api/learning/node", json={
                    "id": memory_id, "content": "User prefers short answers, code first, no emoji."})).json()
                out["stale"] = (await http.put("/api/learning/node", json={"id": memory_id, "content": "x"})).json()
                graph2 = (await http.get("/api/learning/graph")).json()
                fresh_id = next(n["id"] for n in graph2["nodes"] if n["kind"] == "memory")
                out["fresh_label"] = next(n["label"] for n in graph2["nodes"] if n["id"] == fresh_id)
                out["bad_skill"] = (await http.put("/api/learning/node", json={
                    "id": "release-notes", "content": "no frontmatter"})).status_code
                out["delete_memory"] = (await http.request("DELETE", "/api/learning/node", json={"id": fresh_id})
                                        ).json()
                out["delete_skill"] = (await http.request("DELETE", "/api/learning/node",
                                                          json={"id": "deploy-checklist"})).json()
                out["bad_id"] = (await http.request("DELETE", "/api/learning/node", json={"id": "memory:x"})).json()
                await http.post("/api/memory/reset", params={"profile": "default"}, json={"target": "memory"})
                out["after"] = (await http.get("/api/learning/graph")).json()
        return out

    out = asyncio.run(scenario())
    graph = out["graph"]
    skills = {n["id"]: n for n in graph["nodes"] if n["kind"] == "skill"}
    assert set(skills) == {"release-notes", "deploy-checklist", "weekly-review-planning"}, \
        "agent-created or used, never bundled or external"
    assert skills["release-notes"]["createdBy"] == "agent" and skills["weekly-review-planning"]["createdBy"] is None
    memories = [n for n in graph["nodes"] if n["kind"] == "memory"]
    assert len(memories) == 4 and memories[0]["memorySource"] == "memory" and memories[-1]["memorySource"] == "profile"
    assert all(n["id"].count(":") == 3 for n in memories)
    assert {"source": "deploy-checklist", "target": "release-notes"} in graph["edges"]
    assert graph["clusters"][0] == {"category": "memory", "count": 4}
    assert [c["title"] for c in graph["memory"]][0] == "User prefers short answers with the code first."
    assert graph["stats"]["learned_skills"] == 3 and graph["stats"]["memory_nodes"] == 4
    assert {n["id"] for n in out["research"]["nodes"] if n["kind"] == "skill"} == {"paper-summary", "citation-check"}
    assert out["memory"]["kind"] == "memory" and out["memory"]["content"].startswith("User prefers")
    assert out["skill"]["kind"] == "skill" and out["skill"]["content"].startswith("---\nname: release-notes")
    assert out["unknown"] == 404
    assert out["edit"] == {"ok": True, "message": "updated memory in MEMORY.md"}
    assert out["stale"] == {"detail": "memory node id is stale — refresh the graph"}
    assert out["fresh_label"] == "User prefers short answers, code first, no emoji."
    assert out["bad_skill"] == 400
    assert out["delete_memory"] == {"ok": True, "message": "deleted memory from MEMORY.md"}
    assert out["delete_skill"]["ok"] and out["delete_skill"]["message"].startswith("archived 'deploy-checklist'")
    assert out["bad_id"] == {"detail": "bad memory node id: 'memory:x'"}
    after = out["after"]
    assert [n["memorySource"] for n in after["nodes"] if n["kind"] == "memory"] == ["profile"], \
        "MEMORY.md was reset; USER.md stays"


def test_dashboard_plugins_list_kanban_unless_disabled():
    async def scenario(**options):
        async with serving(**options) as (fake, base):
            async with signed_in(base) as http:
                listed = (await http.get("/api/dashboard/plugins")).json()
                research = (await http.get("/api/dashboard/plugins", params={"profile": "research"})).json()
                board = await http.get("/api/plugins/kanban/board")
                async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                    unauth = await anonymous.get("/api/plugins/kanban/board")
                gateway = await Gateway.connect(base, http)
                try:
                    if not options:
                        await gateway.call("plugins.manage", {"action": "toggle", "key": "kanban", "enable": False,
                                                              "profile": "research"})
                    research_after = (await http.get("/api/dashboard/plugins", params={"profile": "research"})).json()
                    research_board = (await http.get("/api/plugins/kanban/board", params={"profile": "research"})
                                      ).status_code
                finally:
                    await gateway.close()
        return listed, research, board.status_code, unauth.status_code, research_after, research_board

    listed, research, board, unauth, research_after, research_board = asyncio.run(scenario())
    kanban = next(p for p in listed if p["name"] == "kanban")
    assert kanban["has_api"] and kanban["source"] == "bundled" and kanban["tab"]["path"] == "/kanban"
    assert not any(k.startswith("_") for k in kanban)
    assert {p["name"] for p in listed} == {"kanban", "hermes_voice"} and [p["name"] for p in research] == ["kanban"]
    assert board == 200 and unauth == 401
    assert research_after == [] and research_board == 404
    listed, research, board, unauth, research_after, research_board = asyncio.run(scenario(no_kanban=True))
    assert [p["name"] for p in listed] == ["hermes_voice"] and research == []
    assert board == 404 and unauth == 401 and research_board == 404


def test_session_import_lists_previews_and_imports_once():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                try:
                    page = await gateway.call("session.foreign.list", {"limit": 3})
                    rest = await gateway.call("session.foreign.list", {"offset": 3, "limit": 3})
                    codex = await gateway.call("session.foreign.list", {"source": "codex"})
                    errors = {}
                    for label, (method, params) in {
                            "source": ("session.foreign.list", {"source": "cursor"}),
                            "page": ("session.foreign.list", {"limit": 0}),
                            "handle": ("session.foreign.preview", {"id": "x"}),
                            "gone": ("session.foreign.import", {"id": "0" * 64}),
                            "profile": ("session.foreign.list", {"profile": "nobody"})}.items():
                        with pytest.raises(RpcFailure) as caught:
                            await gateway.call(method, params)
                        errors[label] = (caught.value.code, caught.value.message)
                    first = page["sessions"][0]
                    preview = await gateway.call("session.foreign.preview", {"id": first["id"]})
                    imported = await gateway.call("session.foreign.import", {"id": first["id"]})
                    again = await gateway.call("session.foreign.import", {"id": first["id"]})
                    preview_after = await gateway.call("session.foreign.preview", {"id": first["id"]})
                    research = await gateway.call("session.foreign.import", {"id": first["id"],
                                                                             "profile": "research"})
                    stored = (await http.get(f"/api/sessions/{imported['session_id']}")).json()
                    messages = (await http.get(f"/api/sessions/{imported['session_id']}/messages")).json()
                finally:
                    await gateway.close()
        return page, rest, codex, errors, preview, imported, again, preview_after, research, stored, messages, gateway

    page, rest, codex, errors, preview, imported, again, preview_after, research, stored, messages, gateway = \
        asyncio.run(scenario())
    assert [s["source"] for s in page["sessions"]] == ["claude", "codex", "claude"]
    assert page["host"] == "hermes-demo-host" and page["next_offset"] == 3 and page["unreadable"] == 0
    assert rest["unreadable"] == 1 and rest["next_offset"] is None and len(rest["sessions"]) == 1
    assert codex["sessions"][0]["title"] == "Add a /health endpoint that reports the version."
    assert codex["unreadable"] == 1
    first = page["sessions"][0]
    assert len(first["id"]) == 64 and first["label"] == "Claude Code" and first["turn_count"] == 4
    assert first["cwd"] == ATLAS and first["excerpt"].startswith("Why does")
    assert errors == {"source": (-32602, "Unknown session source"), "page": (-32602, "Invalid session page"),
                      "handle": (-32602, "Unknown session. Refresh the list and try again"),
                      "gone": (-32602, "Session no longer available. Refresh the list and try again"),
                      "profile": (4004, "Profile 'nobody' does not exist.")}
    assert preview["total"] == 4 and not preview["truncated"] and preview["already_imported"] is None
    assert imported["already_imported"] is False and again == {"session_id": imported["session_id"],
                                                               "already_imported": True}
    assert preview_after["already_imported"] == imported["session_id"]
    assert research["already_imported"] is False and research["session_id"] != imported["session_id"]
    assert stored["source"] == "claude-code" and stored["title"] == "Why does test_token_at_epoch_zero fail on CI only?"
    assert stored["git_repo_root"] == ATLAS and stored["message_count"] == 4
    assert [m["role"] for m in messages["messages"]] == ["user", "assistant", "user", "assistant"]
    assert contract_problems(gateway) == []


def test_the_fleet_trigger_runs_a_subagent_tree_that_can_be_steered_interrupted_and_tailed():
    async def scenario():
        async with serving(fleet_seconds=1.2) as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                try:
                    created = await gateway.call("session.create", {"source": "desktop"})
                    sid = created["session_id"]
                    start = len(gateway.events)
                    await gateway.call("prompt.submit", {"session_id": sid, "text": "send the fleet"})
                    await until(lambda: sum(e["type"] == "subagent.start" for e in gateway.events[start:]) >= 3)
                    running = await gateway.call("subagent.list", {"session_id": sid})
                    by_goal = {s["goal"]: s["subagent_id"] for s in running["subagents"]}
                    first = by_goal["Audit the token module for clock bugs"]
                    third = by_goal["Check the release checklist against CI"]
                    steer = await gateway.call("subagent.steer", {"session_id": sid, "subagent_id": first,
                                                                  "text": "Look at issue_token first"})
                    tail = await gateway.call("subagent.tail", {"session_id": sid, "subagent_id": first})
                    interrupt = await gateway.call("subagent.interrupt", {"session_id": sid, "subagent_id": third})
                    missing = await gateway.call("subagent.interrupt", {"session_id": sid, "subagent_id": "sa-x"})
                    with pytest.raises(RpcFailure) as caught:
                        await gateway.call("subagent.tail", {"session_id": "nope", "subagent_id": first})
                    complete = await gateway.event("message.complete", timeout=15)
                    after = await gateway.call("subagent.list", {"session_id": sid})
                    late = await gateway.call("subagent.steer", {"session_id": sid, "subagent_id": first,
                                                                 "text": "too late"})
                finally:
                    await gateway.close()
        return gateway, start, steer, tail, interrupt, missing, caught.value.code, complete, after, late

    gateway, start, steer, tail, interrupt, missing, stale, complete, after, late = asyncio.run(scenario())
    events = [e for e in gateway.events[start:] if e["type"].startswith("subagent.")]
    starts = [e["payload"] for e in events if e["type"] == "subagent.start"]
    assert len(starts) == 4 and {p["task_count"] for p in starts} == {3}
    nested = next(p for p in starts if p["depth"] == 2)
    assert nested["parent_id"] and nested["goal"] == "Read the storage tests"
    assert len({p["delegation_id"] for p in starts}) == 1
    completes = {e["payload"]["goal"]: e["payload"] for e in events if e["type"] == "subagent.complete"}
    assert completes["Audit the token module for clock bugs"]["status"] == "completed"
    assert completes["Check the release checklist against CI"]["status"] == "interrupted"
    assert completes["Map every caller of the storage layer"]["status"] == "completed"
    assert any(e["type"] == "subagent.progress" and e["payload"]["text"].startswith("Steered:") for e in events)
    assert steer["status"] == "queued" and tail["available"] and "goal: Audit" in tail["text"]
    assert interrupt["found"] is True and missing == {"found": False, "subagent_id": "sa-x"} and stale == 4001
    assert complete["payload"]["text"].startswith("The fleet finished: 2 of 3")
    assert after == {"subagents": [], "delegations": []} and late["status"] == "rejected"
    assert contract_problems(gateway) == []


# ── kanban ───────────────────────────────────────────────────────────────────────────────────────────


async def kanban_socket(base: str, http: httpx.AsyncClient, query: str = "") -> Any:
    ticket = (await http.post("/api/auth/ws-ticket")).json()["ticket"]
    return await websockets.connect(f"ws://{base}/api/plugins/kanban/events?ticket={ticket}{query}")


async def frames(ws: Any, count: int, timeout: float = 5) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    async with asyncio.timeout(timeout):
        while sum(len(f["events"]) for f in out) < count:
            out.append(json.loads(await ws.recv()))
    return out


def test_kanban_board_tasks_transitions_comments_attachments_and_events():
    async def scenario():
        async with serving(kanban_run_seconds=0.6) as (fake, base):
            async with signed_in(base) as http:
                k = "/api/plugins/kanban"
                out: dict[str, Any] = {}
                board = (await http.get(f"{k}/board")).json()
                out["board"] = board
                out["archived"] = (await http.get(f"{k}/board", params={"include_archived": "true"})).json()
                out["workflow"] = (await http.get(f"{k}/workflow")).json()
                ws = await kanban_socket(base, http)
                created = (await http.post(f"{k}/tasks", json={"title": "Write the changelog", "assignee": "research",
                                                              "priority": 3})).json()
                tid = created["task"]["id"]
                out["created"] = created
                out["child"] = (await http.post(f"{k}/tasks", json={"title": "Publish", "parents": [tid]})).json()
                out["triage"] = (await http.post(f"{k}/tasks", json={"title": "Idea", "triage": True})).json()
                out["create_errors"] = {label: (await http.post(f"{k}/tasks", json=body)).json()["detail"]
                                        for label, body in {"blank": {"title": " "},
                                                            "parent": {"title": "x", "parents": ["t_nope"]},
                                                            "kind": {"title": "x", "workspace_kind": "vm"}}.items()}
                out["live"] = await frames(ws, 3)
                patch = lambda task, **body: http.patch(f"{k}/tasks/{task}", json=body)  # noqa: E731
                child_id = out["child"]["task"]["id"]
                out["child_ready"] = (await patch(child_id, status="ready")).json()
                out["running"] = (await patch(tid, status="running")).json()
                out["unknown"] = (await patch(tid, status="later")).json()
                out["empty_done"] = (await patch(tid, status="done")).json()
                out["block"] = (await patch(tid, status="blocked", block_reason="waiting on legal")).json()
                out["unblock"] = (await patch(tid, status="ready")).json()
                out["edit"] = (await patch(tid, title="Write the 0.4 changelog", priority=5)).json()
                out["comment"] = (await http.post(f"{k}/tasks/{tid}/comments", json={"body": "Draft is in docs/"})
                                  ).json()
                out["no_comment"] = (await http.post(f"{k}/tasks/{tid}/comments", json={"body": " "})).status_code
                upload = await http.post(f"{k}/tasks/{tid}/attachments",
                                         files={"file": ("notes.txt", b"first\n", "text/plain")})
                second = await http.post(f"{k}/tasks/{tid}/attachments",
                                         files={"file": ("notes.txt", b"second\n", "text/plain")})
                out["uploads"] = (upload.json(), second.json())
                attachment_id = upload.json()["attachment"]["id"]
                download = await http.get(f"{k}/attachments/{attachment_id}")
                out["download"] = (download.status_code, download.content)
                out["remove_attachment"] = (await http.delete(f"{k}/attachments/{attachment_id}")).json()
                out["dispatch"] = (await http.post(f"{k}/dispatch")).json()
                out["dispatched"] = (await http.get(f"{k}/tasks/{tid}")).json()
                out["link_running"] = (await http.post(f"{k}/links", json={"parent_id": "t_1a2b3c4d",
                                                                          "child_id": tid})).json()
                out["workers"] = (await http.get(f"{k}/workers/active")).json()
                out["log"] = (await http.get(f"{k}/tasks/{tid}/log", params={"tail": "16384"})).json()
                await asyncio.sleep(0.8)
                out["finished"] = (await http.get(f"{k}/tasks/{tid}")).json()
                out["promoted"] = (await http.get(f"{k}/tasks/{child_id}")).json()["task"]["status"]
                out["bulk"] = (await http.post(f"{k}/tasks/bulk", json={
                    "ids": [child_id, "t_nope", out["triage"]["task"]["id"]], "priority": 1, "assignee": "default"})
                    ).json()
                out["reassign_running"] = (await http.post(f"{k}/tasks/t_5e6f7a8b/reassign",
                                                           json={"profile": "research"})).status_code
                out["reassign"] = (await http.post(f"{k}/tasks/t_5e6f7a8b/reassign",
                                                   json={"profile": "research", "reclaim_first": True})).json()
                out["reclaim_idle"] = (await http.post(f"{k}/tasks/t_5e6f7a8b/reclaim", json={})).status_code
                out["review_done"] = (await patch("t_5a6b7c8d", status="done")).json()
                out["todo_ready"] = (await patch("t_9c0d1e2f", status="ready")).json()
                out["archive"] = (await patch("t_7e8f9a0b", status="archived")).json()
                out["delete"] = (await http.delete(f"{k}/tasks/{out['triage']['task']['id']}")).json()
                out["delete_again"] = (await http.delete(f"{k}/tasks/{out['triage']['task']['id']}")).status_code
                out["link"] = (await http.post(f"{k}/links", json={"parent_id": "t_1a2b3c4d",
                                                                  "child_id": child_id})).json()
                out["cycle"] = (await http.post(f"{k}/links", json={"parent_id": child_id,
                                                                   "child_id": "t_1a2b3c4d"})).json()
                out["unlink"] = (await http.delete(f"{k}/links", params={"parent_id": "t_1a2b3c4d",
                                                                        "child_id": child_id})).json()
                out["relinked"] = (await http.get(f"{k}/tasks/{child_id}")).json()["task"]["status"]
                out["detail"] = (await http.get(f"{k}/tasks/t_5a6b7c8d")).json()
                out["stats"] = (await http.get(f"{k}/stats")).json()
                out["diagnostics"] = (await http.get(f"{k}/diagnostics")).json()
                out["estimate"] = (await http.post(f"{k}/estimate", json={"title": "Write docs"})).json()
                out["no_estimate"] = (await http.post(f"{k}/estimate", json={})).json()
                out["after"] = (await http.get(f"{k}/board")).json()
                await ws.close()
                replay = await kanban_socket(base, http, "&since=0")
                out["replay"] = json.loads(await asyncio.wait_for(replay.recv(), 5))
                await replay.close()
        return out

    out = asyncio.run(scenario())
    board = out["board"]
    assert [c["name"] for c in board["columns"]] == ["triage", "todo", "scheduled", "ready", "running", "blocked",
                                                     "review", "done"]
    cards = {t["id"]: t for c in board["columns"] for t in c["tasks"]}
    assert len(cards) == 8 and "t_3c4d5e6f" not in cards, "archived only on request"
    running = cards["t_5e6f7a8b"]
    assert running["status"] == "running" and running["current_run_started_at"] and running["progress"] == \
        {"done": 0, "total": 1} and running["link_counts"] == {"parents": 0, "children": 1}
    assert cards["t_1c2d3e4f"]["warnings"]["highest_severity"] == "critical" and cards["t_1c2d3e4f"]["diagnostics"]
    assert cards["t_5a6b7c8d"]["comment_count"] == 2 and cards["t_5a6b7c8d"]["latest_summary"].startswith("Added")
    assert {"age", "latest_summary", "current_run_started_at", "link_counts", "comment_count", "progress"} <= \
        set(cards["t_1a2b3c4d"])
    assert board["assignees"] == ["default", "research"] and board["latest_event_id"] > 0
    assert [c["name"] for c in out["archived"]["columns"]][-1] == "archived"
    assert out["workflow"]["columns"][2] == {"key": "scheduled", "label": "Scheduled", "icon": "⏱",
                                             "drag_target": False}
    task = out["created"]["task"]
    assert task["status"] == "ready" and task["assignee"] == "research" and task["id"].startswith("t_")
    assert "warning" not in out["created"]
    assert out["child"]["task"]["status"] == "todo" and out["triage"]["task"]["status"] == "triage"
    assert out["create_errors"] == {"blank": "title is required", "parent": "unknown parent task(s): t_nope",
                                    "kind": "workspace_kind must be one of ['dir', 'scratch', 'worktree'], got 'vm'"}
    live = [e for f in out["live"] for e in f["events"]]
    assert [e["kind"] for e in live][:3] == ["created", "created", "dependency_wait"]
    assert all(set(e) == {"id", "task_id", "run_id", "kind", "payload", "created_at"} for e in live)
    assert out["live"][-1]["cursor"] == live[-1]["id"]
    assert out["child_ready"]["detail"].startswith("Cannot move to 'ready': blocked by parent(s) not done — "
                                                   "'Write the changelog'")
    assert out["running"] == {"detail": "Cannot set status to 'running' directly; use the dispatcher/claim path"}
    assert out["unknown"] == {"detail": "unknown status: later"}
    assert out["empty_done"]["detail"].endswith("has no result or summary evidence")
    assert out["block"]["task"]["status"] == "blocked" and out["unblock"]["task"]["status"] == "ready"
    assert out["edit"]["task"]["title"] == "Write the 0.4 changelog" and out["edit"]["task"]["priority"] == 5
    assert out["comment"] == {"ok": True} and out["no_comment"] == 400
    first, second = out["uploads"]
    assert first["attachment"]["filename"] == "notes.txt" and second["attachment"]["filename"] == "notes (1).txt"
    assert out["download"] == (200, b"first\n") and out["remove_attachment"]["ok"]
    spawned = out["dispatch"]["spawned"]
    assert [s[0] for s in spawned][0] == task["id"] and "t_3a4b5c6d" in [s[0] for s in spawned]
    assert out["dispatch"]["skipped_unassigned"] == [] and out["dispatch"]["skipped_locked"] is False
    assert out["dispatched"]["task"]["status"] == "running" and out["dispatched"]["runs"][-1]["status"] == "running"
    assert {w["task_id"] for w in out["workers"]["workers"]} >= {task["id"], "t_5e6f7a8b"}
    assert out["log"]["exists"] and "claimed" in out["log"]["content"]
    finished = out["finished"]
    assert finished["task"]["status"] == "done" and finished["runs"][-1]["outcome"] == "completed"
    assert [e["kind"] for e in finished["events"]][-1] == "completed"
    assert out["promoted"] == "ready", "the child's only parent is done"
    assert out["bulk"]["results"][1] == {"id": "t_nope", "ok": False, "error": "not found"}
    assert out["bulk"]["results"][0]["ok"] and out["bulk"]["results"][2]["ok"]
    assert out["reassign_running"] == 409 and out["reassign"]["assignee"] == "research"
    assert out["reclaim_idle"] == 409
    assert out["review_done"]["task"]["status"] == "done", "approving a review needs no evidence"
    assert out["todo_ready"]["detail"].startswith("Cannot move to 'ready': blocked by parent(s) not done — "
                                                  "'Refresh tokens before they expire'"), "its parent was reclaimed"
    assert out["archive"]["task"]["status"] == "archived"
    assert out["delete"] == {"deleted": True, "task_id": out["triage"]["task"]["id"]} and out["delete_again"] == 404
    assert out["link"] == {"ok": True, "gated": True}, "the ready child waits for its new open parent"
    assert out["link_running"]["detail"].endswith("child is already running")
    assert out["cycle"]["detail"].endswith("would create a cycle")
    assert out["unlink"] == {"ok": True} and out["relinked"] == "ready", "its remaining parent is done"
    detail = out["detail"]
    assert {"task", "comments", "events", "attachments", "links", "link_tasks", "child_results", "runs"} <= set(detail)
    assert detail["attachments"][0]["filename"] == "limits.csv" and len(detail["comments"]) == 2
    assert out["stats"]["by_status"]["done"] >= 3 and "oldest_ready_age_seconds" in out["stats"]
    assert out["diagnostics"]["count"] == 1 and out["diagnostics"]["diagnostics"][0]["task_id"] == "t_1c2d3e4f"
    assert out["estimate"]["ok"] and out["estimate"]["complexity"] == "S"
    assert out["no_estimate"] == {"ok": False, "reason": "a title is required to estimate"}
    assert out["after"]["latest_event_id"] > board["latest_event_id"]
    assert out["replay"]["events"][0]["id"] == 1, "an explicit since replays history"


def test_kanban_boards_orchestration_and_the_events_socket_gates():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                k = "/api/plugins/kanban"
                out: dict[str, Any] = {}
                out["boards"] = (await http.get(f"{k}/boards")).json()
                out["created"] = (await http.post(f"{k}/boards", json={"slug": "beacon", "project_id": "beacon",
                                                                      "switch": True})).json()
                out["bad_slug"] = (await http.post(f"{k}/boards", json={"slug": "-x"})).status_code
                out["bad_dir"] = (await http.post(f"{k}/boards", json={"slug": "y", "default_workdir": "rel"})
                                  ).status_code
                out["current_board"] = (await http.get(f"{k}/board")).json()["columns"][3]["tasks"]
                out["task"] = (await http.post(f"{k}/tasks", json={"title": "Ship 1.5", "assignee": "default"})
                               ).json()
                out["renamed"] = (await http.patch(f"{k}/boards/beacon", json={"name": "Beacon ops",
                                                                              "default_workdir": ""})).json()
                out["exported"] = (await http.post(f"{k}/boards/beacon/export", json={})).json()
                out["imported"] = (await http.post(f"{k}/boards/import", json={"archive": out["exported"]["archive"]})
                                   ).json()
                ws_old = await kanban_socket(base, http, "&board=beacon")
                out["archived"] = (await http.delete(f"{k}/boards/beacon")).json()
                out["default_delete"] = (await http.delete(f"{k}/boards/default")).status_code
                out["stale_board"] = (await http.get(f"{k}/board", params={"board": "beacon"})).json()
                out["boards_after"] = (await http.get(f"{k}/boards", params={"include_archived": "true"})).json()
                with pytest.raises(websockets.ConnectionClosed) as closed:
                    stale = await kanban_socket(base, http, "&board=beacon")
                    await asyncio.wait_for(stale.recv(), 5)
                out["stale_close"] = closed.value.rcvd.code if closed.value.rcvd else None
                await ws_old.close()
                with pytest.raises(websockets.InvalidStatus) as refused:
                    await websockets.connect(f"ws://{base}/api/plugins/kanban/events?ticket=nope")
                out["refused"] = refused.value.response.status_code
                out["switch"] = (await http.post(f"{k}/boards/atlas/switch")).json()
                out["orchestration"] = (await http.get(f"{k}/orchestration")).json()
                out["set"] = (await http.put(f"{k}/orchestration", json={"default_assignee": "research",
                                                                         "auto_decompose": False})).json()
                out["set_bad"] = (await http.put(f"{k}/orchestration", json={"default_assignee": "ghost"})
                                  ).status_code
                out["config"] = (await http.get("/api/config")).json()["kanban"]
                out["profiles"] = (await http.get(f"{k}/profiles")).json()
                out["describe"] = (await http.patch(f"{k}/profiles/research", json={"description": "Paper reader"})
                                   ).json()
                out["auto"] = (await http.post(f"{k}/profiles/research/describe-auto", json={})).json()
                out["projects"] = (await http.get(f"{k}/projects")).json()
                out["homes"] = (await http.get(f"{k}/home-channels", params={"task_id": "t_aa11bb22",
                                                                             "board": "atlas"})).json()
                out["subscribe"] = (await http.post(f"{k}/tasks/t_aa11bb22/home-subscribe/telegram",
                                                    params={"board": "atlas"})).json()
                out["no_home"] = (await http.post(f"{k}/tasks/t_aa11bb22/home-subscribe/slack",
                                                  params={"board": "atlas"})).status_code
                out["homes_after"] = (await http.get(f"{k}/home-channels", params={"task_id": "t_aa11bb22"})).json()
                out["model_options"] = (await http.get(f"{k}/model-options")).json()
                out["unassigned"] = (await http.post(f"{k}/dispatch", params={"dry_run": "true"})).json()
        return out

    out = asyncio.run(scenario())
    boards = {b["slug"]: b for b in out["boards"]["boards"]}
    assert list(boards) == ["default", "atlas"] and out["boards"]["current"] == "default"
    assert boards["default"]["is_current"] and boards["default"]["total"] == 8 and boards["default"]["counts"]
    assert boards["atlas"]["project_name"] == "Atlas" and boards["atlas"]["default_workspace_kind"] == "worktree"
    created = out["created"]
    assert created["current"] == "beacon" and created["board"]["default_workdir"] == BEACON
    assert created["board"]["project_id"] == "p_be4c0a11" and created["board"]["name"] == "Beacon"
    assert out["bad_slug"] == 400 and out["bad_dir"] == 400 and out["current_board"] == []
    assert out["task"]["task"]["project_id"] == "p_be4c0a11" and out["task"]["task"]["workspace_kind"] == "worktree"
    assert out["renamed"]["board"]["name"] == "Beacon ops" and out["renamed"]["board"]["default_workdir"] is None
    assert out["exported"]["board"] == "beacon" and out["exported"]["archive"].endswith(".tar.gz")
    assert out["imported"]["board"] == "beacon-2" and out["imported"]["renamed"] and out["imported"]["counts"] == \
        {"tasks": 1}
    assert out["archived"]["result"]["action"] == "archived" and out["archived"]["current"] == "default"
    assert out["default_delete"] == 400 and out["stale_board"] == {"detail": "board 'beacon' is archived"}
    assert {b["slug"]: b["archived"] for b in out["boards_after"]["boards"]}["beacon"] is True
    assert out["stale_close"] == 1008 and out["refused"] == 403
    assert out["switch"] == {"current": "atlas"}
    assert out["orchestration"]["resolved_default_assignee"] == "default" and out["orchestration"]["auto_decompose"]
    assert out["set"]["default_assignee"] == "research" and out["set"]["auto_decompose"] is False
    assert out["set_bad"] == 400 and out["config"]["default_assignee"] == "research"
    assert [p["name"] for p in out["profiles"]["profiles"]] == ["default", "research"]
    assert out["describe"] == {"ok": True, "profile": "research", "description": "Paper reader"}
    assert out["auto"]["ok"] is False and "user-written" in out["auto"]["reason"]
    assert [p["slug"] for p in out["projects"]["projects"]] == ["atlas", "beacon"]
    assert out["homes"]["home_channels"] == [{"platform": "telegram", "chat_id": "123456789", "thread_id": "",
                                              "name": "Demo DM", "subscribed": False}]
    assert out["subscribe"]["ok"] and out["no_home"] == 404
    assert out["homes_after"]["home_channels"][0]["subscribed"] is True, "atlas is now the current board"
    assert out["model_options"]["providers"][0]["models"]
    assert out["unassigned"]["spawned"] == [["t_aa11bb22", "default", ATLAS]] or \
        out["unassigned"]["spawned"][0][0] == "t_aa11bb22"
