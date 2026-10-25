"""The fake Hermes gateway against what the real one does: seq + replay, detach/reap, server→client requests."""

from __future__ import annotations

import asyncio
import json
import re
import uuid

import httpx
import pytest

from fakeclient import CONTRACT_PATH, Contract, Gateway, RpcFailure, serving, signed_in, until
from fake_hermes import DEMO_COMMAND, NOT_SHOWN_MESSAGE, SERVER_REQUESTS

SRQ_ID = re.compile(r"^srq-[0-9a-f]{12}$")


async def start_session(gateway: Gateway) -> tuple[str, str]:
    created = await gateway.call("session.create", {"source": "desktop"})
    return created["session_id"], created["stored_session_id"]


async def finish_turn(gateway: Gateway) -> dict:
    complete = await gateway.event("message.complete")
    await gateway.event("session.info")
    return complete


def test_sign_in_sessions_and_a_streamed_turn():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                submitted = await gateway.call("prompt.submit", {"session_id": sid, "text": "hello there"})
                complete = await finish_turn(gateway)
                title = next(e for e in gateway.events if e["type"] == "session.title")
                rows = (await http.get("/api/profiles/sessions")).json()["sessions"]
                messages = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                await gateway.close()
            async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                denied = await anonymous.post("/auth/password-login", json={
                    "provider": "basic", "username": "test", "password": "wrong"})
                unauthenticated = await anonymous.get("/api/profiles/sessions")
            return gateway, sid, submitted, complete, title, rows, messages, denied, unauthenticated

    gateway, sid, submitted, complete, title, rows, messages, denied, unauthenticated = asyncio.run(scenario())
    assert set(gateway.ready["payload"]) == {"skin", "change_events", "heartbeat", "replay_epoch"}
    assert gateway.ready["payload"]["heartbeat"] is True and "seq" not in gateway.ready
    assert gateway.capabilities == {"server_requests": SERVER_REQUESTS, "declines_not_shown": True}
    assert {"approval", "clarify", "secret", "window.read"} <= set(SERVER_REQUESTS) and len(SERVER_REQUESTS) == 13
    assert submitted["status"] == "streaming"
    assert complete["payload"]["text"] == "Echo: hello there" and complete["payload"]["status"] == "complete"
    assert title["payload"]["title"] == "hello there"
    session_events = [e for e in gateway.events if e.get("session_id") == sid]
    assert [e["seq"] for e in session_events] == list(range(1, len(session_events) + 1))
    assert gateway.kinds()[:2] == ["gateway.ready", "message.start"]
    assert rows[0]["title"] == "hello there" and len(rows) == 2
    assert [m["role"] for m in messages] == ["user", "assistant"]
    assert (denied.status_code, unauthenticated.status_code) == (401, 401)
    assert unauthenticated.json()["error"] == "unauthenticated"


def test_reconnect_activates_the_session_and_replays_what_was_missed():
    async def scenario():
        # The grace outlasts the 0.3 s turn: a shorter one can reap the session before the second socket attaches.
        async with serving(reap_grace=1.0) as (fake, base):
            async with signed_in(base) as http:
                first = await Gateway.connect(base, http)
                sid, _ = await start_session(first)
                await first.call("prompt.submit", {"session_id": sid, "text": "while you were away"})
                start = await first.event("message.start")
                await first.close()  # mid-turn: the turn keeps running detached
                await until(lambda: not fake.runtimes[sid].running)
                second = await Gateway.connect(base, http)
                activated = await second.call("session.activate", {"session_id": sid, "omit_messages": True})
                replay = await second.call("session.events.since", {"session_id": sid, "last_seen": start["seq"]})
                await asyncio.sleep(1.5)  # past the grace: the re-attach cancelled the reap
                alive = sid in fake.runtimes
                await second.call("prompt.submit", {"session_id": sid, "text": "and now"})
                live = await second.event("message.start")
                await finish_turn(second)
                await second.close()
            return first, second, start, activated, replay, alive, live

    first, second, start, activated, replay, alive, live = asyncio.run(scenario())
    assert start["seq"] == 1
    assert activated["session_id"] == start["session_id"] and activated["status"] == "idle"
    assert activated["messages"] == [] and activated["messages_omitted"] is True and "open_requests" not in activated
    events = replay["events"]
    assert [e["seq"] for e in events] == list(range(2, replay["latest_seq"] + 1))
    assert [e["type"] for e in events][-3:] == ["message.complete", "session.title", "session.info"]
    assert "".join(e["payload"]["text"] for e in events if e["type"] == "message.delta") == "Echo: while you were away"
    assert replay["truncated"] is False and replay["count"] == len(events) and replay["open_requests"] == []
    assert replay["epoch"] == first.ready["payload"]["replay_epoch"] == second.ready["payload"]["replay_epoch"]
    assert alive
    assert live["seq"] == replay["latest_seq"] + 1


def test_a_replay_past_the_ring_is_truncated():
    async def scenario():
        async with serving(replay_max=4) as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, _ = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "a reply long enough to stream"})
                await finish_turn(gateway)
                latest = gateway.events[-1]["seq"]
                old = await gateway.call("session.events.since", {"session_id": sid, "last_seen": 0})
                recent = await gateway.call("session.events.since", {"session_id": sid, "last_seen": latest - 2})
                bad = await gateway.call_frame("session.events.since", {"session_id": sid, "last_seen": "x"})
                unknown = await gateway.call("session.events.since", {"session_id": "nope", "last_seen": 3})
                await gateway.close()
            return latest, old, recent, bad, unknown

    latest, old, recent, bad, unknown = asyncio.run(scenario())
    assert latest > 4
    assert old["truncated"] is True and [e["seq"] for e in old["events"]] == list(range(latest - 3, latest + 1))
    assert recent["truncated"] is False and recent["count"] == 2
    assert bad["error"]["code"] == -32602
    assert unknown == {"events": [], "latest_seq": 0, "truncated": False, "count": 0, "epoch": old["epoch"],
                       "open_requests": []}


def test_a_detached_session_is_reaped_and_only_resume_brings_it_back():
    async def scenario():
        async with serving(reap_grace=0.3) as (fake, base):
            async with signed_in(base) as http:
                watcher = await Gateway.connect(base, http)  # attached to nothing: sees broadcasts only
                owner = await Gateway.connect(base, http)
                sid, key = await start_session(owner)
                await owner.call("prompt.submit", {"session_id": sid, "text": "remember me"})
                await finish_turn(owner)
                await owner.close()
                reclaimed = await watcher.event("session.reclaimed", timeout=3)
                late = await Gateway.connect(base, http)
                try:
                    await late.call("session.activate", {"session_id": sid})
                    activate_error = None
                except RpcFailure as failure:
                    activate_error = failure
                try:
                    await late.call("prompt.submit", {"session_id": sid, "text": "too late"})
                    submit_error = None
                except RpcFailure as failure:
                    submit_error = failure
                ring = await late.call("session.events.since", {"session_id": sid, "last_seen": 0})
                resumed = await late.call("session.resume", {"session_id": key})
                await late.close()
                await watcher.close()
            return sid, key, reclaimed, activate_error, submit_error, ring, resumed

    sid, key, reclaimed, activate_error, submit_error, ring, resumed = asyncio.run(scenario())
    assert reclaimed["session_id"] == "" and "seq" not in reclaimed
    assert reclaimed["payload"] == {"session_id": sid, "stored_session_id": key, "reason": "ws_orphan_reap"}
    assert (activate_error.code, activate_error.message) == (4001, "session not found")
    assert submit_error.code == 4001
    assert ring["count"] > 0  # the ring outlives the runtime
    assert resumed["session_id"] != sid and resumed["session_key"] == key and resumed["resumed"] == key
    assert [m["text"] for m in resumed["messages"]] == ["remember me", "Echo: remember me"]


def test_a_reaped_draft_resumes_under_its_minted_key():
    async def scenario():
        async with serving(reap_grace=0.3) as (fake, base):
            async with signed_in(base) as http:
                watcher = await Gateway.connect(base, http)
                owner = await Gateway.connect(base, http)
                sid, key = await start_session(owner)
                draft_rows = (await http.get(f"/api/sessions/{key}/messages")).status_code
                await owner.close()
                await watcher.event("session.reclaimed", timeout=3)
                late = await Gateway.connect(base, http)
                resumed = await late.call("session.resume", {"session_id": key, "omit_messages": True})
                try:
                    await late.call("session.resume", {"session_id": "not-a-minted-key"})
                    unknown_error = None
                except RpcFailure as failure:
                    unknown_error = failure
                await late.close()
                await watcher.close()
                messages = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
            return sid, key, draft_rows, resumed, unknown_error, messages

    sid, key, draft_rows, resumed, unknown_error, messages = asyncio.run(scenario())
    assert draft_rows == 404  # no row until the first prompt
    assert resumed["session_id"] != sid and resumed["session_key"] == key and resumed["message_count"] == 0
    assert messages == []  # the resume wrote an empty row
    assert unknown_error.code == 4007


def test_an_approval_waits_through_a_reconnect_and_is_answered_on_the_new_socket():
    async def scenario():
        async with serving(reap_grace=0.3) as (fake, base):
            async with signed_in(base) as http:
                first = await Gateway.connect(base, http)
                sid, _ = await start_session(first)
                await first.call("prompt.submit", {"session_id": sid, "text": "please approve the cleanup"})
                asked = await first.request("approval")
                await first.close()
                await asyncio.sleep(0.6)  # past the grace, but a turn waiting on a human is never reaped
                second = await Gateway.connect(base, http)
                activated = await second.call("session.activate", {"session_id": sid, "omit_messages": True})
                replay = await second.call("session.events.since", {"session_id": sid, "last_seen": 0})
                await second.respond(asked["id"], {"choice": "once"})
                done = await tool_done(second)
                complete = await finish_turn(second)
                await second.respond(asked["id"], {"choice": "deny"})  # stale: dropped, nothing comes back
                await asyncio.sleep(0.1)
                frames_after = len(second.frames)
                await second.close()
            return sid, asked, activated, replay, done, complete, second, frames_after

    sid, asked, activated, replay, done, complete, second, frames_after = asyncio.run(scenario())
    assert SRQ_ID.match(asked["id"])
    params = asked["params"]
    assert params["session_id"] == sid and params["command"] == DEMO_COMMAND
    assert params["choices"] == ["once", "session", "always", "deny"]
    assert re.match(r"^[0-9a-f]{32}$", params["request_id"])
    assert activated["status"] == "waiting" and activated["running"] is True
    assert activated["open_requests"] == [{"id": asked["id"], "method": "approval", "params": params}]
    assert activated["pending_approval"]["request_id"] == params["request_id"]
    assert replay["open_requests"] == activated["open_requests"]
    assert [e["type"] for e in replay["events"]][:2] == ["message.start", "tool.start"]
    assert done["payload"]["name"] == "terminal" and "result" in done["payload"]["result"]
    assert complete["payload"]["text"] == f"Approved (once): ran `{DEMO_COMMAND}`."
    assert "request.cancel" not in second.kinds()  # answered by the response frame itself
    assert len(second.frames) == frames_after


async def tool_done(gateway: Gateway) -> dict:
    return await gateway.event("tool.complete")


def test_approval_respond_resolves_and_withdraws_the_request():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "approve it"})
                asked = await gateway.request("approval")
                resolved = await gateway.call("approval.respond", {"session_id": sid, "choice": "deny"})
                cancel = await gateway.event("request.cancel")
                complete = await finish_turn(gateway)
                again = await gateway.call("approval.respond", {"session_id": sid, "choice": "once"})
                await gateway.call("prompt.submit", {"session_id": sid, "text": "approve once more"})
                second = await gateway.request("approval")
                # A stale runtime id still reaches the approval through its request id.
                by_request = await gateway.call("approval.respond", {
                    "session_id": "deadbeef", "choice": "session", "request_id": second["params"]["request_id"]})
                second_complete = await finish_turn(gateway)
                await gateway.close()
            return asked, resolved, cancel, complete, again, by_request, second_complete

    asked, resolved, cancel, complete, again, by_request, second_complete = asyncio.run(scenario())
    assert resolved == {"resolved": 1}
    assert cancel["payload"] == {"id": asked["id"], "method": "approval", "reason": "resolved"}
    assert complete["payload"]["text"] == f"Denied (deny): `{DEMO_COMMAND}` did not run."
    assert again == {"resolved": 0}
    assert by_request == {"resolved": 1}
    assert second_complete["payload"]["text"].startswith("Approved (session)")


def test_window_owned_requests_settle_only_when_every_client_declined():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                phone = await Gateway.connect(base, http)
                desk = await Gateway.connect(base, http)
                sid, _ = await start_session(phone)
                await desk.call("session.activate", {"session_id": sid})
                await phone.call("prompt.submit", {"session_id": sid, "text": "read the window below"})
                ask_phone, ask_desk = await phone.request("window.read"), await desk.request("window.read")
                await phone.fail(ask_phone["id"], 4404, "not shown here")
                await asyncio.sleep(0.1)
                still_open = await phone.call("session.events.since", {"session_id": sid, "last_seen": 0})
                await desk.fail(ask_desk["id"], 4404, "not shown here")
                complete = await finish_turn(phone)
                await phone.close()
                await desk.close()
            return sid, ask_phone, ask_desk, still_open, complete, phone

    sid, ask_phone, ask_desk, still_open, complete, phone = asyncio.run(scenario())
    assert ask_phone == ask_desk and ask_phone["params"] == {"session_id": sid}
    assert [r["id"] for r in still_open["open_requests"]] == [ask_phone["id"]]
    assert complete["payload"]["text"] == f"window.read declined by every client: {NOT_SHOWN_MESSAGE}"
    assert "request.cancel" not in phone.kinds()


def test_clients_that_cannot_answer_withdraw_the_prompt_instead_of_stalling_the_turn():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                modern = await Gateway.connect(base, http)
                sid, _ = await start_session(modern)
                await modern.call("prompt.submit", {"session_id": sid, "text": "approve, then clarify"})
                approval = await modern.request("approval")
                await modern.fail(approval["id"], -32601, "no handler for server request: approval")
                clarify = await modern.request("clarify")
                await modern.fail(clarify["id"], -32601, "no handler for server request: clarify")
                answered_by_error = await finish_turn(modern)
                await modern.close()
                legacy = await Gateway.connect(base, http, capabilities=False)
                legacy_sid, _ = await start_session(legacy)
                await legacy.call("prompt.submit", {"session_id": legacy_sid, "text": "approve this"})
                never_asked = await finish_turn(legacy)
                await legacy.close()
            return answered_by_error, never_asked, legacy

    answered_by_error, never_asked, legacy = asyncio.run(scenario())
    assert answered_by_error["payload"]["text"] == (
        f"No client could answer the approval, so `{DEMO_COMMAND}` did not run.\n\nClarify undelivered.")
    assert never_asked["payload"]["text"] == f"No client could answer the approval, so `{DEMO_COMMAND}` did not run."
    assert legacy.requests.empty() and "request.cancel" not in legacy.kinds()


def test_clarify_locks_answers_and_a_secret_is_never_logged(capsys):
    secret = "hunter2-" + uuid.uuid4().hex[:6]

    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, _ = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "clarify, then ask for a secret"})
                clarify = await gateway.request("clarify")
                locked = await gateway.call("clarify.lock", {"request_id": clarify["id"], "question_id": "q0",
                                                              "answer": "Green"})
                unknown_qid = await gateway.call_frame("clarify.lock", {"request_id": clarify["id"],
                                                                        "question_id": "q9", "answer": "x"})
                resumed = await gateway.call("session.resume", {"session_id": fake.runtimes[sid].key,
                                                                "omit_messages": True})
                replayed = resumed["open_requests"][0]
                await gateway.respond(clarify["id"], {"answers": {"q1": json.dumps(["Logs"]), "q2": None}})
                secret_request = await gateway.request("secret")
                await gateway.respond(secret_request["id"], {"value": secret})
                complete = await finish_turn(gateway)
                expired = await gateway.call("clarify.lock", {"request_id": clarify["id"], "question_id": "q1"})
                out_of_band = await gateway.call("request.answer", {"id": clarify["id"], "result": {}})
                await gateway.close()
            return clarify, locked, unknown_qid, replayed, secret_request, complete, expired, out_of_band

    clarify, locked, unknown_qid, replayed, secret_request, complete, expired, out_of_band = asyncio.run(scenario())
    questions = clarify["params"]["questions"]
    assert [q["qid"] for q in questions] == ["q0", "q1", "q2"]
    assert questions[1]["multi_select"] is True and questions[2]["choices"] is None
    assert locked == {"status": "ok", "remaining": ["q1", "q2"]}
    assert unknown_qid["error"]["code"] == 4002
    assert replayed["params"]["answers"] == {"q0": "Green"}  # a reconnect restores the locked answers
    assert set(secret_request["params"]) == {"session_id", "env_var", "prompt"}
    text = complete["payload"]["text"]
    assert text.startswith('Clarify submitted: q0: Green; q1: ["Logs"]; q2: (skipped)')
    assert text.endswith(f"Saved FAKE_HERMES_API_KEY ({len(secret)} characters).")
    assert expired == {"status": "expired"} and out_of_band == {"status": "expired"}
    assert secret not in capsys.readouterr().out


def test_interrupt_and_timeout_withdraw_open_requests():
    async def scenario():
        async with serving() as (fake, base):
            fake.ask_timeouts["secret"] = 0.2
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, _ = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "sudo make me a sandwich"})
                sudo = await gateway.request("sudo")
                interrupted = await gateway.call("session.interrupt", {"session_id": sid})
                cancelled = await gateway.event("request.cancel")
                stopped = await gateway.event("message.complete")
                after = await gateway.call("session.events.since", {"session_id": sid, "last_seen": 0})
                await gateway.call("prompt.submit", {"session_id": sid, "text": "a secret nobody types"})
                timed_out_request = await gateway.request("secret")
                timed_out = await gateway.event("request.cancel")
                skipped = await finish_turn(gateway)
                answered = await gateway.call("request.answer", {"id": sudo["id"], "result": {"value": "late"}})
                await gateway.close()
            return sudo, interrupted, cancelled, stopped, after, timed_out_request, timed_out, skipped, answered

    sudo, interrupted, cancelled, stopped, after, timed_out_request, timed_out, skipped, answered = \
        asyncio.run(scenario())
    assert sudo["params"]["command"].startswith("sudo ")
    assert interrupted == {"status": "interrupted"}
    assert cancelled["payload"] == {"id": sudo["id"], "method": "sudo", "reason": "interrupted"}
    assert stopped["payload"]["status"] == "interrupted"
    assert after["open_requests"] == []
    assert timed_out["payload"] == {"id": timed_out_request["id"], "method": "secret", "reason": "timeout"}
    assert skipped["payload"]["text"] == "FAKE_HERMES_API_KEY skipped."
    assert answered == {"status": "expired"}


def test_request_answer_settles_a_request_from_any_socket():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                owner = await Gateway.connect(base, http)
                other = await Gateway.connect(base, http)  # not attached to the session
                sid, _ = await start_session(owner)
                await owner.call("prompt.submit", {"session_id": sid, "text": "secret please"})
                asked = await owner.request("secret")
                answered = await other.call("request.answer", {"id": asked["id"], "result": {"value": "abc"}})
                bad = await other.call_frame("request.answer", {"id": asked["id"], "result": "abc"})
                complete = await finish_turn(owner)
                await owner.close()
                await other.close()
            return answered, bad, complete

    answered, bad, complete = asyncio.run(scenario())
    assert answered == {"status": "ok"}
    assert bad["error"]["code"] == 4002
    assert complete["payload"]["text"] == "Saved FAKE_HERMES_API_KEY (3 characters)."


def test_unknown_params_are_rejected_like_the_contract_does(tmp_path):
    contract = tmp_path / "contract.json"
    contract.write_text(json.dumps({
        "methods": [{"name": "session.activate", "params": [{"name": "params", "schema": {
            "$ref": "#/components/schemas/SessionActivateParams"}}], "result": {"name": "result", "schema": {}}}],
        "components": {"schemas": {"SessionActivateParams": {"additionalProperties": False, "properties": {
            "session_id": {"type": "string"}, "omit_messages": {"type": "boolean"}}}}}}))

    async def scenario():
        async with serving(contract=str(contract)) as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                extra = await gateway.call_frame("session.activate", {"session_id": "x", "omitMessages": True})
                valid = await gateway.call_frame("session.activate", {"session_id": "x", "omit_messages": True})
                unknown = await gateway.call_frame("session.nope", {})
                await gateway.close()
            return extra, valid, unknown

    extra, valid, unknown = asyncio.run(scenario())
    assert extra["error"]["code"] == 4000
    assert "omitMessages: Extra inputs are not permitted" in extra["error"]["message"]
    assert valid["error"]["code"] == 4001
    assert unknown["error"]["code"] == -32601


@pytest.mark.skipif(not CONTRACT_PATH, reason="no pinned gateway contract (HermesVoice/Contract) and no "
                                               "HERMES_GATEWAY_CONTRACT")
def test_results_events_and_requests_match_the_gateway_contract():
    contract = Contract(CONTRACT_PATH)

    async def scenario():
        async with serving(reap_grace=0.3) as (fake, base):
            fake.ask_timeouts["secret"] = 0.2
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                watcher = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "approve, clarify, sudo, window"})
                approval = await gateway.request("approval")
                await gateway.call("approval.respond", {"session_id": sid, "choice": "once"})
                clarify = await gateway.request("clarify")
                await gateway.call("clarify.lock", {"request_id": clarify["id"], "question_id": "q0", "answer": "Red"})
                await gateway.call("session.activate", {"session_id": sid})
                await gateway.call("session.resume", {"session_id": key})
                await gateway.respond(clarify["id"], {"answers": {"q1": None, "q2": "no"}})
                sudo = await gateway.request("sudo")
                await gateway.call("request.answer", {"id": sudo["id"], "result": {"value": "pw"}})
                window = await gateway.request("window.read")
                await gateway.fail(window["id"], 4404, "not shown")
                await finish_turn(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "secret"})
                await gateway.request("secret")
                await gateway.event("request.cancel")
                await finish_turn(gateway)
                await gateway.call("session.events.since", {"session_id": sid, "last_seen": 0})
                await gateway.call("prompt.submit", {"session_id": sid, "text": "stop me"})
                await gateway.event("message.start")
                await gateway.call("session.interrupt", {"session_id": sid})
                await finish_turn(gateway)
                await gateway.close()
                await watcher.event("session.reclaimed", timeout=3)
                late = await Gateway.connect(base, http)
                await late.call("session.resume", {"session_id": key})
                await late.call("ping")
                await late.close()
                await watcher.close()
            return gateway, watcher, late, approval

    gateway, watcher, late, approval = asyncio.run(scenario())
    problems = [p for g in (gateway, watcher, late) for p in contract.check_gateway(g)]
    replayed = [e for method, result in gateway.results if method == "session.events.since" for e in result["events"]]
    for event in replayed:
        problems += [f"replayed {event['type']}{p}" for p in contract.problems(contract.events[event["type"]],
                                                                              event.get("payload", {}))]
    assert problems == []
    assert {m for m, _ in gateway.results} >= {"client.capabilities", "session.create", "prompt.submit",
                                               "approval.respond", "clarify.lock", "session.activate",
                                               "session.resume", "request.answer", "session.events.since",
                                               "session.interrupt"}
    assert {"tool.start", "tool.complete", "request.cancel", "message.delta", "session.title"} <= set(gateway.kinds())


def test_the_speak_demo_reaches_the_voice_server():
    voice = pytest.importorskip("hermes_voice_mcp.server")
    from hermes_voice_mcp.config import Settings
    import uvicorn
    import websockets
    from fakeclient import free_port

    token, call_id = "test-token", uuid.uuid4().hex

    async def scenario():
        port = free_port()
        settings = Settings(host="127.0.0.1", port=port, token=token, elevenlabs_api_key=None,
                            elevenlabs_base_url="http://127.0.0.1:9", voice_id="testvoice", model_id="test-model",
                            max_chars=1000, fake_tts=True)
        server = uvicorn.Server(uvicorn.Config(voice.build_app(settings), host="127.0.0.1", port=port,
                                               log_level="warning", timeout_graceful_shutdown=1))
        task = asyncio.create_task(server.serve())
        await until(lambda: server.started)
        phone = await websockets.connect(f"ws://127.0.0.1:{port}/phone",
                                         additional_headers={"Authorization": f"Bearer {token}"})
        await phone.send(json.dumps({"type": "hello", "call_id": call_id, "session_id": "s1", "title": "Test"}))
        assert json.loads(await phone.recv())["type"] == "ready"
        heard: list[str] = []

        async def listen() -> None:
            async for frame in phone:
                if isinstance(frame, str):
                    message = json.loads(frame)
                    heard.append(message.get("text") or message["type"])
                    if message["type"] == "speech_end":
                        await phone.send(json.dumps({"type": "played", "id": message["id"]}))

        listener = asyncio.create_task(listen())
        try:
            async with serving(voice_url=f"http://127.0.0.1:{port}", voice_token=token) as (fake, base):
                async with signed_in(base) as http:
                    gateway = await Gateway.connect(base, http)
                    sid, _ = await start_session(gateway)
                    await gateway.call("prompt.submit", {"session_id": sid,
                                                         "text": f"[Voice call started] call_id: {call_id}"})
                    done = await gateway.event("tool.complete", timeout=15)
                    complete = await finish_turn(gateway)
                    await gateway.close()
        finally:
            listener.cancel()
            await phone.close()
            server.should_exit = True
            await task
        return done, complete, heard

    done, complete, heard = asyncio.run(scenario())
    assert done["payload"]["name"] == "mcp__hermes_voice__speak"
    assert done["payload"]["result"]["result"].startswith("Spoken to the user"), done["payload"]
    assert complete["payload"]["text"] == "Call connected (text only)."
    assert heard[0] == "Hi, I am fake Hermes. I can hear you."
