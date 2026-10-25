"""The fake Hermes behind the chat screens (M2): sidebar REST, composer RPCs and the demo turns, checked against the
Hermes shapes and the pinned gateway contract."""

from __future__ import annotations

import asyncio
import base64
import re

import httpx
import pytest

from fakeclient import CONTRACT_PATH, Contract, Gateway, RpcFailure, serving, signed_in, until
from fake_hermes import (AUTH_DIFF, DEMO_ATTACHMENTS, DEMO_IMAGE, DEMO_IMAGES, FAILED_TURN_NOTICE,
                         PARTIAL_FAILED_TURN_NOTICE, demo_png, project_path)

ATLAS, BEACON = project_path("atlas"), project_path("beacon")
CONTRACT = Contract(CONTRACT_PATH) if CONTRACT_PATH else None


def contract_problems(*gateways: Gateway) -> list[str]:
    return [p for g in gateways for p in CONTRACT.check_gateway(g)] if CONTRACT else []


async def open_chat(gateway: Gateway, **create) -> tuple[str, str]:
    created = await gateway.call("session.create", {"source": "desktop", **create})
    return created["session_id"], created["stored_session_id"]


async def turn(gateway: Gateway, sid: str, text: str, timeout: float = 10) -> dict:
    """Submit a prompt and wait for its close; the message.complete event."""
    first = len(gateway.events)
    await gateway.call("prompt.submit", {"session_id": sid, "text": text})
    await until(lambda: any(e["type"] == "session.info" and e.get("session_id") == sid
                            for e in gateway.events[first:]), timeout)
    return next(e for e in gateway.events[first:] if e["type"] == "message.complete")


def since(gateway: Gateway, start: int, kind: str | None = None) -> list[dict]:
    return [e for e in gateway.events[start:] if kind is None or e["type"] == kind]


async def failure(gateway: Gateway, method: str, params: dict) -> int:
    with pytest.raises(RpcFailure) as caught:
        await gateway.call(method, params)
    return caught.value.code


def test_the_demo_seed_fills_the_sidebar_lists_and_profiles():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            async with signed_in(base) as http:
                sidebar = (await http.get("/api/profiles/sessions/sidebar")).json()
                scoped = (await http.get("/api/profiles/sessions/sidebar", params={
                    "recents_profile": "research", "recents_exclude": "cron,telegram",
                    "messaging_exclude": "desktop,cron"})).json()
                desk = (await http.get("/api/profiles/sessions/sidebar", params={
                    "recents_exclude": "cron,telegram", "messaging_exclude": "desktop,cron",
                    "recents_limit": 1})).json()
                listed = (await http.get("/api/profiles/sessions", params={"limit": 100})).json()
                archived = (await http.get("/api/profiles/sessions", params={"archived": "only"})).json()
                every = (await http.get("/api/profiles/sessions", params={"archived": "include", "limit": 100})).json()
                page = (await http.get("/api/profiles/sessions", params={"limit": 1})).json()
                bad = await http.get("/api/profiles/sessions", params={"archived": "maybe"})
                profiles = (await http.get("/api/profiles")).json()
                gateway = await Gateway.connect(base, http)
                projects = await gateway.call("projects.list", {})
                await gateway.close()
            async with serving() as (fake, base):
                async with signed_in(base) as http:
                    minimal = (await http.get("/api/profiles/sessions")).json()
        return sidebar, scoped, desk, listed, archived, every, page, bad, profiles, projects, gateway, minimal

    sidebar, scoped, desk, listed, archived, every, page, bad, profiles, projects, gateway, minimal = \
        asyncio.run(scenario())
    recents = {r["title"]: r for r in sidebar["recents"]["sessions"]}
    assert {"Fake Hermes welcome", "Fix flaky login test", "Refactor storage layer", "Release notes draft",
            "Old onboarding notes", "Paper summary", "Daily digest", "Telegram chat"} == set(recents)
    assert recents["Fix flaky login test"]["pinned"] and recents["Refactor storage layer"]["unread"]
    assert recents["Fix flaky login test"]["git_repo_root"] == ATLAS and recents["Release notes draft"]["cwd"] == BEACON
    assert recents["Release notes draft"]["git_branch"] == "release/1.4"
    assert recents["Paper summary"]["profile"] == "research" and not recents["Paper summary"]["is_default_profile"]
    ages = sorted(r["last_active"] for r in recents.values())
    assert ages[-1] - ages[0] > 30 * 86400, "the seed spans weeks"
    assert [r["title"] for r in sidebar["cron"]["sessions"]] == ["Daily digest"]
    assert set(sidebar["recents"]["profiles_usage"]) == {"default", "research"}
    assert sidebar["recents"]["profiles_usage"]["default"]["tokens"] > 0 and sidebar["errors"] == []
    assert [r["title"] for r in scoped["recents"]["sessions"]] == ["Paper summary"]
    assert scoped["messaging"] == {"sessions": [], "total": 0}
    assert [r["title"] for r in desk["messaging"]["sessions"]] == ["Telegram chat"]
    # The newest desktop row, then the pinned one back-filled past the limit.
    assert [r["title"] for r in desk["recents"]["sessions"]] == ["Fake Hermes welcome", "Fix flaky login test"]
    assert desk["recents"]["profiles_truncated"] == {"default": True, "research": True}
    assert "Benchmark ideas" not in {r["title"] for r in listed["sessions"]}
    assert [r["title"] for r in archived["sessions"]] == ["Benchmark ideas"] and archived["sessions"][0]["archived"]
    assert every["total"] == listed["total"] + 1 and every["profile_totals"]["research"] == 1
    assert len(page["sessions"]) == 2 and any(r["pinned"] for r in page["sessions"])
    assert bad.status_code == 400
    assert [p["name"] for p in profiles["profiles"]] == ["default", "research"]
    assert profiles["profiles"][0]["is_default"] and set(profiles["profiles"][1]) >= {"path", "model", "skill_count"}
    assert [p["primary_path"] for p in projects["projects"]] == [ATLAS, BEACON] and projects["active_id"] is None
    assert projects["projects"][0]["folders"][0]["is_primary"]
    assert [r["title"] for r in minimal["sessions"]] == ["Fake Hermes welcome"]
    assert contract_problems(gateway) == []


def test_search_finds_ids_and_message_words_in_one_profile():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            key = next(s.key for s in fake.sessions.values() if s.title == "Release notes draft")
            async with signed_in(base) as http:
                async def search(**params):
                    return (await http.get("/api/sessions/search", params=params)).json()["results"]
                return key, (await search(q="fails now"), await search(q="summ"),
                             await search(q="summ", profile="research"), await search(q=key[-6:]),
                             await search(q="benchmark"), await search(q=""),
                             await search(q="digest", exclude_sources="cron"))

    key, (words, prefix, research, by_id, archived, empty, excluded) = asyncio.run(scenario())
    assert [r["title"] for r in words] == ["Fix flaky login test"]
    assert ">>>fails<<<" in words[0]["snippet"] and ">>>now<<<" in words[0]["snippet"] and words[0]["role"] == "user"
    assert [r["title"] for r in prefix] == ["Old onboarding notes"], "prefix match, default profile only"
    assert [r["title"] for r in research] == ["Paper summary"] and research[0]["profile"] == "research"
    assert by_id[0]["session_id"] == key and by_id[0]["role"] is None and by_id[0]["lineage_root"] == key
    assert archived[0]["title"] == "Benchmark ideas" and archived[0]["archived"] is True
    assert empty == [] and excluded == []
    assert set(words[0]) >= {"id", "snippet", "source", "model", "session_started", "last_active", "message_count",
                             "preview", "is_active", "profile"}


def test_sessions_are_renamed_flagged_and_deleted():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            key = next(s.key for s in fake.sessions.values() if s.title == "Refactor storage layer")
            async with signed_in(base) as http:
                watcher = await Gateway.connect(base, http)
                renamed = await http.patch(f"/api/sessions/{key}", json={"title": "  Storage   split  ", "pinned": True,
                                                                         "unread": False})
                changed = await watcher.event("sessions.changed")
                flagged = (await http.patch(f"/api/sessions/{key}", json={"archived": True})).json()
                listed = (await http.get("/api/profiles/sessions", params={"archived": "only"})).json()["sessions"]
                taken = await http.patch(f"/api/sessions/{key}", json={"title": "Release notes draft"})
                long = await http.patch(f"/api/sessions/{key}", json={"title": "x" * 101})
                nothing = await http.patch(f"/api/sessions/{key}", json={})
                missing = await http.patch("/api/sessions/nope", json={"title": "x"})
                cleared = (await http.patch(f"/api/sessions/{key}", json={"title": ""})).json()
                foreign = await http.patch(f"/api/sessions/{key}", json={"pinned": False},
                                           headers={"Origin": "http://evil.example"})
                owner = await Gateway.connect(base, http)
                sid, busy_key = await open_chat(owner)
                await owner.call("prompt.submit", {"session_id": sid, "text": "delegate"})
                await owner.event("subagent.start")
                busy = await http.delete(f"/api/sessions/{busy_key}")
                await owner.event("message.complete", timeout=10)
                deleted = (await http.delete(f"/api/sessions/{key}")).json()
                again = (await http.delete(f"/api/sessions/{key}")).json()
                gone = await http.get(f"/api/sessions/{key}/messages")
                await owner.close()
                await watcher.close()
            async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                denied = await anonymous.delete(f"/api/sessions/{busy_key}")
        return (renamed, changed, flagged, listed, taken, long, nothing, missing, cleared, foreign, busy, deleted,
                again, gone, denied, watcher)

    (renamed, changed, flagged, listed, taken, long, nothing, missing, cleared, foreign, busy, deleted, again, gone,
     denied, watcher) = asyncio.run(scenario())
    assert renamed.json() == {"ok": True, "pinned": True, "unread": False, "title": "Storage split"}
    assert changed["payload"] == {} and changed["session_id"] == ""
    assert flagged == {"ok": True, "archived": True, "title": "Storage split"}
    assert [r["title"] for r in listed if r["title"] == "Storage split"] and \
        next(r for r in listed if r["title"] == "Storage split")["pinned"]
    assert (taken.status_code, long.status_code, nothing.status_code, missing.status_code) == (400, 400, 400, 404)
    assert "already in use" in taken.json()["detail"] and "too long" in long.json()["detail"]
    assert cleared == {"ok": True, "title": ""}
    assert foreign.status_code == 403 and busy.status_code == 409
    assert deleted == {"ok": True} and again == {"ok": True, "already_absent": True} and gone.status_code == 404
    assert denied.status_code == 401
    assert contract_problems(watcher) == []


def test_a_thinking_turn_streams_reasoning_then_text_and_reports_usage():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway)
                start = len(gateway.events)
                complete = await turn(gateway, sid, "think hard about it")
                usage = await gateway.call("session.usage", {"session_id": sid})
                resumed = await gateway.call("session.activate", {"session_id": sid})
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                second = await turn(gateway, sid, "and now plain")
                await gateway.close()
        return gateway, start, complete, usage, resumed, rows, second

    gateway, start, complete, usage, resumed, rows, second = asyncio.run(scenario())
    kinds = [e["type"] for e in since(gateway, start)]
    assert kinds.index("thinking.delta") < kinds.index("reasoning.delta") < kinds.index("message.delta")
    assert kinds.index("session.usage") == kinds.index("message.complete") - 1
    reasoning = "".join(e["payload"]["text"] for e in since(gateway, start, "reasoning.delta"))
    assert complete["payload"]["reasoning"] == reasoning and complete["payload"]["status"] == "complete"
    assert complete["payload"]["text"] == "After thinking it over: the answer is 42."
    live = next(e for e in since(gateway, start, "session.usage"))["payload"]["usage"]
    assert live == complete["payload"]["usage"]
    counters = ("input", "output", "reasoning", "total", "calls", "context_max")
    assert {k: usage[k] for k in counters} == {k: live[k] for k in counters}
    assert usage["context_used"] > live["context_used"], "the reply now sits in the context"
    assert usage["calls"] == 1 and usage["reasoning"] > 0 and 0 < usage["context_used"] <= usage["context_max"]
    assert rows[-1]["role"] == "assistant" and rows[-1]["reasoning"] == reasoning
    assert next(m for m in resumed["messages"] if m["role"] == "assistant")["reasoning"] == reasoning
    assert "reasoning" not in second["payload"] and second["payload"]["usage"]["calls"] == 2
    assert second["payload"]["usage"]["input"] > usage["input"]
    assert contract_problems(gateway) == []


def test_a_tools_turn_shows_terminal_output_diffs_search_and_a_background_process():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway, cwd=ATLAS)
                start = len(gateway.events)
                complete = await turn(gateway, sid, "run the tools")
                processes = (await gateway.call("process.list", {"session_id": sid}))["processes"]
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                resumed = await gateway.call("session.activate", {"session_id": sid})
                pid = processes[0]["session_id"]
                killed = await gateway.call("process.kill", {"session_id": sid, "process_id": pid})
                again = await gateway.call("process.kill", {"session_id": sid, "process_id": pid})
                after = (await gateway.call("process.list", {"session_id": sid}))["processes"]
                seeded = next(s for s in fake.sessions.values() if s.title == "Fix flaky login test")
                other = await gateway.call("session.resume", {"session_id": seeded.key})
                foreign = next(p for p in fake.processes.values() if p["session_key"] == seeded.key)["id"]
                not_mine = await failure(gateway, "process.kill", {"session_id": sid, "process_id": foreign})
                no_id = await failure(gateway, "process.kill", {"session_id": sid, "process_id": ""})
                stopped = await gateway.call("process.stop", {})
                theirs = (await gateway.call("process.list", {"session_id": other["session_id"]}))["processes"]
                stale = await failure(gateway, "process.list", {"session_id": "deadbeef"})
                await gateway.close()
        return (gateway, start, complete, processes, rows, resumed, killed, again, after, not_mine, no_id, stopped,
                theirs, stale)

    (gateway, start, complete, processes, rows, resumed, killed, again, after, not_mine, no_id, stopped, theirs,
     stale) = asyncio.run(scenario())
    tools = [e for e in since(gateway, start) if e["type"].startswith("tool.")]
    names = [e["payload"]["name"] for e in tools if e["type"] == "tool.start"]
    assert names == ["search_files", "terminal", "patch", "write_file", "terminal", "terminal"]
    for i in range(0, len(tools), 3):
        generating, started, done = tools[i:i + 3]
        assert [generating["type"], started["type"], done["type"]] == ["tool.generating", "tool.start", "tool.complete"]
        assert generating["payload"] == {"name": started["payload"]["name"]}
        assert started["payload"]["tool_id"] == done["payload"]["tool_id"]
        assert isinstance(done["payload"]["result"], dict) and done["payload"]["duration_s"] >= 0
    by_name = [e["payload"] for e in tools if e["type"] == "tool.complete"]
    assert [p["result"]["exit_code"] for p in by_name if p["name"] == "terminal"] == [1, 0, 0]
    assert "1 failed" in by_name[1]["result"]["output"]
    assert by_name[1]["args"] == {"command": "pytest -q tests/test_auth.py"}
    assert by_name[0]["result"]["matches"][0]["path"] == "src/atlas/auth.py"
    patch = by_name[2]
    assert patch["result"]["diff"] == AUTH_DIFF and patch["result"]["files_modified"] == ["src/atlas/auth.py"]
    plain = re.sub(r"\x1b\[[0-9;]*m", "", patch["inline_diff"])
    assert plain.startswith("  ┊ review diff\na/src/atlas/auth.py → b/src/atlas/auth.py")
    assert "+    if now is None:" in plain
    assert "inline_diff" in by_name[3] and by_name[3]["args"]["path"] == "CHANGELOG.md"
    patch_start = next(e for e in tools if e["type"] == "tool.start" and e["payload"]["name"] == "patch")
    assert patch_start["payload"]["context"] == "src/atlas/auth.py"
    text = complete["payload"]["text"]
    assert "2 files changed:\n- `src/atlas/auth.py` +2 -1\n- `CHANGELOG.md` +3 -0" in text
    assert [p["command"] for p in processes] == ["python -m http.server 8000"] and processes[0]["status"] == "running"
    assert processes[0]["cwd"] == ATLAS and processes[0]["session_id"] in text and processes[0]["output_tail"]
    tool_rows = [r for r in rows if r["role"] == "tool"]
    assert [r["tool_name"] for r in tool_rows][2] == "patch"
    assert "inline_diff" in tool_rows[2]["display_metadata"]["tool_result_metadata"]
    resumed_patch = next(m for m in resumed["messages"] if m["role"] == "tool" and m["name"] == "patch")
    assert '"diff"' in resumed_patch["content"] and resumed_patch["args"]["path"] == "src/atlas/auth.py"
    assert killed["status"] == "killed" and killed["completion_reason"] == "killed"
    assert again["status"] == "already_exited" and after[0]["status"] == "exited" and after[0]["exit_code"] == -15
    assert (not_mine, no_id, stale) == (4044, 4012, 4001)
    assert stopped == {"killed": 1} and theirs[0]["status"] == "exited"
    assert contract_problems(gateway) == []


def test_a_todo_turn_publishes_full_snapshots_with_rising_revisions():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway)
                start = len(gateway.events)
                complete = await turn(gateway, sid, "make a todo list")
                activated = await gateway.call("session.activate", {"session_id": sid, "omit_messages": True})
                await gateway.close()
                late = await Gateway.connect(base, http)
                resumed = await late.call("session.resume", {"session_id": key})
                await late.close()
        return gateway, start, complete, activated, resumed, late

    gateway, start, complete, activated, resumed, late = asyncio.run(scenario())
    updates = [e["payload"] for e in since(gateway, start, "todo.updated")]
    assert [u["revision"] for u in updates] == [1, 2]
    assert [t["status"] for t in updates[0]["todos"]] == ["completed", "in_progress", "pending"]
    assert [t["status"] for t in updates[1]["todos"]] == ["completed", "completed", "in_progress"]
    completes = [e["payload"] for e in since(gateway, start, "tool.complete")]
    assert [c["name"] for c in completes] == ["todo_list", "todo_list"]
    assert completes[1]["todos"] == updates[1]["todos"] and completes[1]["revision"] == 2
    assert completes[1]["args"]["merge"] is True and completes[1]["result"]["summary"]["completed"] == 2
    starts = [e["payload"]["context"] for e in since(gateway, start, "tool.start")]
    assert starts == ["planning 3 task(s)", "updating 2 task(s)"]
    assert activated["todo_state"] == updates[1] == resumed["todo_state"]
    assert complete["payload"]["text"] == "Planned 3 tasks; 2 done so far."
    assert contract_problems(gateway, late) == []


def test_a_delegate_turn_runs_a_subagent_the_roster_shows_while_it_works():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, _ = await open_chat(gateway)
                start = len(gateway.events)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "delegate this"})
                await gateway.event("subagent.start")
                running = await gateway.call("subagent.list", {"session_id": sid})
                complete = await gateway.event("message.complete", timeout=10)
                done = await gateway.call("subagent.list", {"session_id": sid})
                stale = await failure(gateway, "subagent.list", {"session_id": "deadbeef"})
                await gateway.close()
        return gateway, start, running, complete, done, stale

    gateway, start, running, complete, done, stale = asyncio.run(scenario())
    kinds = [e["type"] for e in since(gateway, start) if e["type"].startswith(("subagent.", "tool."))]
    assert kinds == ["tool.generating", "tool.start", "subagent.spawn_requested", "subagent.start",
                     "subagent.thinking", "subagent.tool", "subagent.tool", "subagent.progress", "subagent.complete",
                     "tool.complete"]
    events = [e["payload"] for e in since(gateway, start) if e["type"].startswith("subagent.")]
    assert len({(e["subagent_id"], e["delegation_id"], e["child_session_id"]) for e in events}) == 1
    assert all(e["task_count"] == 1 and e["task_index"] == 0 and e["goal"] for e in events)
    assert [e.get("tool_name") for e in events if "tool_name" in e] == ["search_files", "read_file"]
    final = events[-1]
    assert final["status"] == "completed" and final["summary"] and final["duration_seconds"] > 0
    assert final["files_read"] == ["src/atlas/storage.py"] and final["output_tail"][0]["is_error"] is False
    [entry] = running["subagents"]
    assert entry["subagent_id"] == final["subagent_id"] and entry["status"] == "running" and entry["goal"]
    assert done == {"subagents": [], "delegations": []} and stale == 4001
    tool = [e["payload"] for e in since(gateway, start, "tool.complete")][0]
    assert tool["name"] == "delegate_task" and tool["result"]["results"][0]["status"] == "completed"
    assert tool["result"]["total_duration_seconds"] == final["duration_seconds"]
    assert complete["payload"]["text"].startswith("The subagent reports:")
    assert contract_problems(gateway) == []


def test_a_failing_turn_closes_with_a_layered_error_kept_for_resume():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway)
                start = len(gateway.events)
                failed = await turn(gateway, sid, "please fail")
                deltas = since(gateway, start, "message.delta")
                activated = await gateway.call("session.activate", {"session_id": sid})
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                partial = await turn(gateway, sid, "run tools then fail")
                rows_after = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                recovered = await turn(gateway, sid, "hello again")
                cleared = await gateway.call("session.activate", {"session_id": sid, "omit_messages": True})
                await gateway.close()
        return failed, deltas, activated, rows, partial, rows_after, recovered, cleared, gateway

    failed, deltas, activated, rows, partial, rows_after, recovered, cleared, gateway = asyncio.run(scenario())
    payload = failed["payload"]
    assert payload["status"] == "error" and payload["recoverable"] is True and "partial" not in payload
    assert payload["error"].startswith("HTTP 429") and deltas == []
    assert payload["error_surface"] == {"layer": "provider", "code": "rate_limit", "retryable": True,
                                        "provider": "fake", "model": "fake-hermes", "provider_label": "Fake"}
    assert payload["text"].startswith("The model provider is rate-limiting requests (fake). Your message was not")
    assert "Details: HTTP 429" in payload["text"] and payload["text"].endswith("Wait a moment, then /retry.")
    inflight = activated["inflight"]
    assert inflight["status"] == "error" and inflight["user"] == "please fail" and inflight["streaming"] is False
    assert inflight["error_surface"]["layer"] == "provider" and activated["status"] == "idle"
    assert rows[-1]["content"] == FAILED_TURN_NOTICE and rows[-1]["display_kind"] == "failed_turn"
    assert rows[-1]["display_metadata"]["error_surface"]["code"] == "rate_limit"
    assert partial["payload"]["partial"] is True and partial["payload"]["text"].startswith("Found the bug")
    assert rows_after[-1]["content"] == PARTIAL_FAILED_TURN_NOTICE and rows_after[-2]["finish_reason"] == "error"
    assert recovered["payload"]["status"] == "complete" and "inflight" not in cleared
    assert contract_problems(gateway) == []


def test_images_are_staged_for_the_next_prompt_and_come_back_as_media():
    png = demo_png(600, 300, (200, 30, 30))
    encoded = base64.b64encode(png).decode()

    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway)
                attached = await gateway.call("image.attach_bytes", {"session_id": sid, "content_base64": encoded,
                                                                     "filename": "photo.png"})
                sniffed = await gateway.call("image.attach_bytes", {"session_id": sid,
                                                                    "data": f"data:image/png;base64,{encoded}"})
                errors = [await failure(gateway, "image.attach_bytes", params) for params in (
                    {"session_id": sid, "content_base64": encoded, "ext": "heic"},
                    {"session_id": sid, "content_base64": "not base64!"},
                    {"session_id": sid},
                    {"session_id": "deadbeef", "content_base64": encoded})]
                reply = await turn(gateway, sid, "show me the image")
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                media = (await http.get("/api/media", params={"path": attached["path"]})).json()
                demo = await turn(gateway, sid, "another image")
                demo_media = await http.get("/api/media", params={"path": DEMO_IMAGE})
                statuses = [(await http.get("/api/media", params={"path": p})).status_code for p in (
                    f"{DEMO_IMAGES}/missing.png", "/etc/hosts.png", f"{DEMO_IMAGES}/notes.txt")]
                await gateway.close()
        return attached, sniffed, errors, reply, rows, media, demo, demo_media, statuses, gateway

    attached, sniffed, errors, reply, rows, media, demo, demo_media, statuses, gateway = asyncio.run(scenario())
    assert attached["attached"] is True and attached["count"] == 1 and attached["bytes"] == len(png)
    assert (attached["width"], attached["height"], attached["token_estimate"]) == (600, 300, 2 * 1 * 85)
    assert re.fullmatch(rf"{DEMO_IMAGES}/upload_\d{{8}}_\d{{6}}_1\.png", attached["path"])
    assert attached["text"] == f"[User attached image: {attached['name']}]"
    assert sniffed["count"] == 2 and sniffed["path"].endswith("_2.png")
    assert errors == [4016, 4017, 4015, 4001]
    text = reply["payload"]["text"]
    assert text.endswith(f"MEDIA:{sniffed['path']}\n\nI got 2 image(s): {attached['name']}, {sniffed['name']}")
    user_row = [r for r in rows if r["role"] == "user"][-1]["content"]
    assert user_row == f"show me the image\n\n@image:{attached['path']}\n@image:{sniffed['path']}"
    assert media["data_url"] == f"data:image/png;base64,{encoded}"
    assert demo["payload"]["text"] == f"Here is the image:\n\nMEDIA:{DEMO_IMAGE}"
    assert demo_media.json()["data_url"].startswith("data:image/png;base64,iVBOR")
    assert statuses == [404, 403, 415]
    assert contract_problems(gateway) == []


def test_files_are_attached_as_refs_the_prompt_can_carry():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, _ = await open_chat(gateway, cwd=ATLAS)
                inside = await gateway.call("file.attach", {"session_id": sid, "path": "README.md"})
                outside = await gateway.call("file.attach", {"session_id": sid, "path": f"{BEACON}/package.json"})
                uploaded = await gateway.call("file.attach", {
                    "session_id": sid, "name": "my notes.txt",
                    "data_url": "data:text/plain;charset=utf-8;base64," + base64.b64encode(b"hello").decode()})
                twice = await gateway.call("file.attach", {"session_id": sid, "name": "my notes.txt",
                                                           "data_url": base64.b64encode(b"again").decode()})
                errors = [await failure(gateway, "file.attach", params) for params in (
                    {"session_id": sid}, {"session_id": sid, "path": "nope.txt"},
                    {"session_id": sid, "name": "x", "data_url": "data:text/plain;base64,@@@"},
                    {"session_id": "deadbeef", "path": "README.md"})]
                reply = await turn(gateway, sid,
                                   f"read {uploaded['ref_text']} and {inside['ref_text']} and @file:gone.md")
                await gateway.close()
        return inside, outside, uploaded, twice, errors, reply, gateway

    inside, outside, uploaded, twice, errors, reply, gateway = asyncio.run(scenario())
    assert inside == {"attached": True, "name": "README.md", "path": f"{ATLAS}/README.md", "ref_path": "README.md",
                      "ref_text": "@file:README.md", "uploaded": False}
    assert outside["uploaded"] is True and outside["path"] == f"{DEMO_ATTACHMENTS}/package.json"
    assert outside["ref_text"] == f"@file:{DEMO_ATTACHMENTS}/package.json"
    assert uploaded["path"] == f"{DEMO_ATTACHMENTS}/my notes.txt"
    assert uploaded["ref_text"] == f"@file:`{DEMO_ATTACHMENTS}/my notes.txt`"
    assert twice["name"] == "my notes-2.txt"
    assert errors == [4015, 5028, 5028, 4001]
    text = reply["payload"]["text"]
    assert f"Read {uploaded['ref_text']} (5 bytes)." in text and "Read @file:README.md (" in text
    assert "@file:gone.md was not found." in text
    assert contract_problems(gateway) == []


def test_slash_commands_have_a_catalog_completions_and_both_dispatch_paths():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway)
                catalog = await gateway.call("commands.catalog", {"session_id": sid})
                complete = {text: await gateway.call("complete.slash", {"text": text, "session_id": sid})
                            for text in ("/he", "/help", "/reasoning h", "/model ", "/rev", "hello")}
                outputs = {cmd: await gateway.call("slash.exec", {"session_id": sid, "command": cmd})
                           for cmd in ("help", "/usage", "status", "title Release prep", "model", "uptime",
                                       "queue later please")}
                title = await gateway.event("session.title")
                errors = [await failure(gateway, "slash.exec", {"session_id": s, "command": c}) for s, c in (
                    (sid, "review-pr"), (sid, "frobnicate"), (sid, "  "), ("deadbeef", "help"))]
                skill = await gateway.call("command.dispatch", {"session_id": sid, "name": "review-pr",
                                                                "arg": "focus on tests"})
                quick = await gateway.call("command.dispatch", {"name": "/uptime"})
                await turn(gateway, sid, "first question")
                await gateway.call("prompt.submit", {"session_id": sid, "text": "delegate a long one"})
                await gateway.event("subagent.start")
                busy = await failure(gateway, "command.dispatch", {"session_id": sid, "name": "retry"})
                await gateway.event("message.complete", timeout=10)
                await gateway.event("session.info")
                retry = await gateway.call("slash.exec", {"session_id": sid, "command": "retry"})
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                more = [await failure(gateway, "command.dispatch", params) for params in (
                    {"session_id": sid, "name": "queue"}, {"session_id": sid, "name": "nope"})]
                stop = await gateway.call("slash.exec", {"session_id": sid, "command": "stop"})
                await gateway.close()
        return catalog, complete, outputs, title, errors, skill, quick, busy, retry, rows, more, stop, gateway

    catalog, complete, outputs, title, errors, skill, quick, busy, retry, rows, more, stop, gateway = \
        asyncio.run(scenario())
    assert [c["name"] for c in catalog["categories"]] == ["Session", "Configuration", "Info", "User commands"]
    pairs = dict(catalog["pairs"])
    assert pairs["/title"] == "Set a title for the current session (usage: /title [name])"
    assert pairs["/review-pr"] and catalog["skills"]["/review-pr"] == {"usage": 2, "origin": "local"}
    assert catalog["canon"]["/reset"] == "/new" and catalog["commands"]["/model"]["desktop"] == "hidden"
    assert catalog["commands"]["/reasoning"]["argument_mode"] == "options" and "high" in catalog["sub"]["/reasoning"]
    assert catalog["skill_count"] == 2 and catalog["warning"] == ""
    help_desc = pairs["/help"].split(" (usage")[0]
    assert complete["/he"] == {"items": [{"text": "help", "display": "/help", "meta": help_desc, "kind": "command"}],
                               "replace_from": 1}
    assert complete["/help"]["items"][0]["text"] == "help "
    assert [i["text"] for i in complete["/reasoning h"]["items"]] == ["high", "hide"]
    assert complete["/reasoning h"]["replace_from"] == len("/reasoning ")
    assert "echo-2-pro" in [i["text"] for i in complete["/model "]["items"]]
    assert complete["/rev"]["items"] == [{"text": "review-pr", "display": "/review-pr", "kind": "skill",
                                          "meta": "⚡ Review the current branch like a careful reviewer"}]
    assert complete["hello"] == {"items": []}
    assert "/stop" in outputs["help"]["output"] and "Skills: /release-notes, /review-pr" in outputs["help"]["output"]
    assert outputs["/usage"]["output"].startswith("Model: fake-hermes (fake)")
    assert "Reasoning: medium" in outputs["status"]["output"]
    assert outputs["title Release prep"] == {"output": "Title set: Release prep"}
    assert title["payload"]["title"] == "Release prep"
    assert outputs["model"]["output"] == "Current model: fake-hermes (provider: fake)"
    assert outputs["uptime"]["type"] == "exec" and "up 3 days" in outputs["uptime"]["output"]
    assert outputs["queue later please"] == {"type": "send", "message": "later please"}
    assert errors == [4018, 4018, 4004, 4001]
    assert skill["type"] == "skill" and skill["name"] == "review-pr" and skill["display"] == "/review-pr focus on tests"
    assert "focus on tests" in skill["message"] and quick["type"] == "exec"
    assert busy == 4009
    assert retry == {"type": "send", "message": "delegate a long one"}
    assert [r["content"] for r in rows if r["role"] == "user"] == ["first question"], "retry rewound the last turn"
    assert more == [4004, 4018]
    assert stop == {"output": "Stopped 0 background process(es)."}
    assert contract_problems(gateway) == []


def test_path_completion_walks_the_session_workspace():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, _ = await open_chat(gateway, cwd=ATLAS)
                words = ("@", "@file:src/atlas/", "@src/", "@au", "@folder:", "@src/atlas/s", "./t", "@res", "")
                results = {w: (await gateway.call("complete.path", {"word": w, "session_id": sid}))["items"]
                           for w in words}
                elsewhere = (await gateway.call("complete.path", {"word": "@file:", "cwd": BEACON}))["items"]
                await gateway.close()
        return results, elsewhere, gateway

    results, elsewhere, gateway = asyncio.run(scenario())
    texts = {w: [i["text"] for i in items] for w, items in results.items()}
    assert texts["@"][:3] == ["@diff", "@staged", "@file:"] and "@research" in texts["@"]
    assert texts["@file:src/atlas/"] == ["@file:src/atlas/__init__.py", "@file:src/atlas/auth.py",
                                         "@file:src/atlas/storage.py"], "an explicit @file: lists files only"
    assert texts["@src/"] == ["@folder:src/atlas/"] and results["@src/"][0]["meta"] == "dir"
    assert texts["@au"][0] == "@file:src/atlas/auth.py"
    assert results["@au"][0] == {"text": "@file:src/atlas/auth.py", "display": "auth.py", "meta": "src/atlas"}
    assert texts["@folder:"] == ["@folder:src/", "@folder:tests/"]
    assert texts["@src/atlas/s"] == ["@file:src/atlas/storage.py"]
    assert texts["./t"] == ["./tests/"]
    assert texts["@res"][0] == "@research", "a profile mention ranks above files"
    assert texts[""] == []
    assert [i["text"] for i in elsewhere] == ["@file:README.md", "@file:package.json"]
    assert contract_problems(gateway) == []


def test_model_effort_and_fast_pills_switch_the_session():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, _ = await open_chat(gateway)
                options = await gateway.call("model.options", {"session_id": sid})
                start = len(gateway.events)
                switched = await gateway.call("config.set", {"session_id": sid, "key": "model", "value": "echo-2-pro"})
                info = since(gateway, start, "session.info")[-1]["payload"]
                confirm = await gateway.call("config.set", {"session_id": sid, "key": "model",
                                                            "value": "fake-hermes-max"})
                confirmed = await gateway.call("config.set", {"session_id": sid, "key": "model",
                                                              "value": "fake-hermes-max --provider fake",
                                                              "confirm_expensive_model": True})
                effort = await gateway.call("config.set", {"session_id": sid, "key": "reasoning", "value": "high"})
                shown = await gateway.call("config.set", {"session_id": sid, "key": "reasoning", "value": "show"})
                fast = await gateway.call("config.set", {"session_id": sid, "key": "fast", "value": "on"})
                fast_info = since(gateway, start, "session.info")[-1]["payload"]
                status = await gateway.call("config.set", {"session_id": sid, "key": "fast", "value": "status"})
                await gateway.call("config.set", {"session_id": sid, "key": "model", "value": "fake-hermes-mini"})
                no_fast = await failure(gateway, "config.set", {"session_id": sid, "key": "fast", "value": "fast"})
                errors = [await failure(gateway, "config.set", params) for params in (
                    {"session_id": sid, "key": "model", "value": "gpt-nope"},
                    {"session_id": sid, "key": "model", "value": ""},
                    {"key": "model", "value": "echo-1"},
                    {"session_id": "deadbeef", "key": "reasoning", "value": "low"},
                    {"session_id": sid, "key": "reasoning", "value": "loud"},
                    {"session_id": sid, "key": "colour", "value": "blue"})]
                await gateway.call("prompt.submit", {"session_id": sid, "text": "delegate while I switch"})
                await gateway.event("subagent.start")
                deferred = await gateway.call("config.set", {"session_id": sid, "key": "model", "value": "echo-1"})
                during = (await gateway.call("session.activate", {"session_id": sid, "omit_messages": True}))["info"]
                await gateway.event("message.complete", timeout=10)
                after = await gateway.event("session.info")
                await gateway.close()
        return (options, switched, info, confirm, confirmed, effort, shown, fast, fast_info, status, no_fast, errors,
                deferred, during, after, gateway)

    (options, switched, info, confirm, confirmed, effort, shown, fast, fast_info, status, no_fast, errors, deferred,
     during, after, gateway) = asyncio.run(scenario())
    assert [p["slug"] for p in options["providers"]] == ["fake", "echo-cloud"]
    assert options["model"] == "fake-hermes" and options["provider"] == "fake" and options["providers"][0]["is_current"]
    assert options["providers"][0]["capabilities"]["fake-hermes-mini"] == {"fast": False, "reasoning": False,
                                                                           "can_disable_reasoning": False}
    assert options["providers"][0]["pricing"]["fake-hermes-mini"]["free"] is True
    assert switched == {"key": "model", "value": "echo-2-pro", "warning": "", "scope": "session",
                        "confirm_required": False, "confirm_message": ""}
    assert (info["model"], info["provider"]) == ("echo-2-pro", "echo-cloud")
    assert confirm["confirm_required"] is True and "$15.00" in confirm["confirm_message"]
    assert confirmed["value"] == "fake-hermes-max" and confirmed["confirm_required"] is False
    assert effort == {"key": "reasoning", "value": "high"} and shown == {"key": "reasoning", "value": "show"}
    assert fast == {"key": "fast", "value": "fast"} and status == {"key": "fast", "value": "fast"}
    assert fast_info["fast"] is True and fast_info["service_tier"] == "priority"
    assert fast_info["reasoning_effort"] == "high" and fast_info["model"] == "fake-hermes-max"
    assert no_fast == 4002 and errors == [4002, 4002, 4001, 4001, 4002, 4002]
    assert deferred["deferred"] is True and during["model"] == "fake-hermes-mini"
    assert after["payload"]["model"] == "echo-1" and after["payload"]["provider"] == "echo-cloud"
    assert contract_problems(gateway) == []


def test_context_breakdown_workspace_move_and_branching():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway, cwd=ATLAS)
                empty_branch = await failure(gateway, "session.branch", {"session_id": sid})
                await turn(gateway, sid, "remember this")
                breakdown = await gateway.call("session.context_breakdown", {"session_id": sid})
                usage = await gateway.call("session.usage", {"session_id": sid})
                start = len(gateway.events)
                moved = await gateway.call("session.workspace.move", {"session_key": key, "cwd": f"{BEACON}/src"})
                info = since(gateway, start, "session.info")[-1]["payload"]
                home = await gateway.call("session.workspace.move", {"session_key": key, "cwd": "~"})
                errors = [await failure(gateway, "session.workspace.move", params) for params in (
                    {"session_key": key, "cwd": "/nowhere"}, {"session_key": "", "cwd": ATLAS},
                    {"session_key": key, "cwd": ""}, {"session_key": "nope", "cwd": ATLAS})]
                branch = await gateway.call("session.branch", {"session_id": sid, "idempotency_key": "b-1"})
                retried = await gateway.call("session.branch", {"session_id": sid, "idempotency_key": "b-1"})
                second = await gateway.call("session.branch", {"session_id": sid, "count": 1})
                named = await gateway.call("session.branch", {"session_id": sid, "name": "Side quest"})
                await turn(gateway, branch["session_id"], "in the branch")
                listed = (await http.get("/api/profiles/sessions", params={"limit": 100})).json()["sessions"]
                stale = await failure(gateway, "session.context_breakdown", {"session_id": "deadbeef"})
                await gateway.close()
        return (breakdown, usage, moved, info, home, errors, branch, retried, second, named, listed, stale,
                empty_branch, key, gateway)

    (breakdown, usage, moved, info, home, errors, branch, retried, second, named, listed, stale, empty_branch, key,
     gateway) = asyncio.run(scenario())
    ids = [c["id"] for c in breakdown["categories"]]
    assert ids == ["system_prompt", "tool_definitions", "rules", "skills", "memory", "conversation"]
    assert breakdown["context_used"] == sum(c["tokens"] for c in breakdown["categories"]) == usage["context_used"]
    assert breakdown["context_files"][0]["path"] == f"{ATLAS}/AGENTS.md" and breakdown["model"] == "fake-hermes"
    assert moved == {"cwd": f"{BEACON}/src", "branch": "release/1.4", "git_repo_root": BEACON}
    assert info["cwd"] == f"{BEACON}/src" and info["project"]["slug"] == "beacon"
    assert home == {"cwd": "/home/demo", "branch": None, "git_repo_root": None}
    assert errors == [4017, 4007, 4016, 4007]
    assert branch["parent"] == key and branch["title"] == "remember this #2" and branch["message_count"] == 2
    assert [m["role"] for m in branch["messages"]] == ["user", "assistant"]
    assert retried["session_id"] == branch["session_id"] and retried["stored_session_id"] == branch["stored_session_id"]
    assert second["title"] == "remember this #3" and second["message_count"] == 1
    assert named["title"] == "Side quest"
    child = next(r for r in listed if r["id"] == branch["stored_session_id"])
    assert child["_branched_from"] == key and child["parent_session_id"] == key and child["message_count"] == 4
    assert empty_branch == 4008 and stale == 4001
    assert contract_problems(gateway) == []


def test_rewinds_detaches_config_reads_and_closing_before_delete():
    png = base64.b64encode(demo_png(8, 8)).decode()

    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await open_chat(gateway, reasoning_effort="high", fast=True)
                reads = [await gateway.call("config.get", {"session_id": sid, "key": k}) for k in ("reasoning", "fast")]
                full = await gateway.call("config.get", {"key": "full"})
                staged = await gateway.call("image.attach_bytes", {"session_id": sid, "content_base64": png})
                detached = await gateway.call("image.detach", {"session_id": sid, "path": staged["path"]})
                await turn(gateway, sid, "one")
                await turn(gateway, sid, "two")
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                second = next(r["id"] for r in rows if r["role"] == "user" and r["content"] == "two")
                unconfirmed = await failure(gateway, "prompt.submit", {"session_id": sid, "text": "x",
                                                                       "truncate_before_row_id": second})
                await gateway.call("prompt.submit", {"session_id": sid, "text": "blocked approve"})
                busy = await failure(gateway, "prompt.submit", {"session_id": sid, "text": "x", "confirm_truncate": True,
                                                                "truncate_before_row_id": second})
                await gateway.call("session.interrupt", {"session_id": sid})
                await gateway.event("message.complete", timeout=10)
                await until(lambda: not fake.runtimes[sid].running, 5)
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                second = next(r["id"] for r in rows if r["role"] == "user" and r["content"] == "two")
                rewound = await gateway.call("prompt.submit", {"session_id": sid, "text": "two, edited",
                                                               "confirm_truncate": True, "truncate_before_row_id": second})
                await until(lambda: not fake.runtimes[sid].running, 10)
                after = [r["content"] for r in (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                         if r["role"] == "user"]
                deleted = (await http.delete(f"/api/sessions/{key}")).json()
                still_live = sid in fake.runtimes
                closed = await gateway.call("session.close", {"session_id": sid})
                gone = sid not in fake.runtimes and key not in fake.sessions
                await gateway.close()
        return reads, full, detached, unconfirmed, busy, rewound, after, deleted, still_live, closed, gone, gateway

    reads, full, detached, unconfirmed, busy, rewound, after, deleted, still_live, closed, gone, gateway = \
        asyncio.run(scenario())
    assert [r["value"] for r in reads] == ["high", "fast"], "session.create took the effort and Fast picked first"
    assert full["config"]["display"] == {"show_reasoning": True, "tool_progress": "all"}
    assert detached == {"detached": True, "count": 0}
    assert (unconfirmed, busy) == (4029, 4009)
    assert rewound["status"] == "streaming" and len(rewound["survivor_user_row_ids"]) == 1
    assert after == ["one", "two, edited"]
    assert deleted == {"ok": True} and still_live, "the store goes, the runtime stays until session.close"
    assert closed == {"closed": True} and gone
    assert contract_problems(gateway) == []
