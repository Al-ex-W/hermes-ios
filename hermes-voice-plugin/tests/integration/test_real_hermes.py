"""The plugin inside a real ``hermes serve`` (opt-in; see conftest.py): sign-in and tickets through the dashboard's
own auth, ``start_call`` run by Hermes' agent loop for a stub model, a scripted phone on ``/phone``, and what the
plugin injects landing in real sessions through ``session.redirect`` / ``session.steer`` / ``prompt.submit``."""

from __future__ import annotations

import asyncio
import json
import uuid
from contextlib import asynccontextmanager
from typing import AsyncIterator

import pytest
import websockets

from hermes_sandbox import PREFIX, PUBLIC_HOST, Dashboard, Gateway, Phone
from scenario import start_call_result

pytestmark = pytest.mark.integration


@asynccontextmanager
async def signed_in(sandbox) -> AsyncIterator[tuple[Dashboard, Gateway]]:
    dashboard = Dashboard(sandbox)
    gateway = None
    try:
        assert (await dashboard.sign_in()).status_code == 200
        assert (await dashboard.post("/api/plugins/hermes_voice_it/arm")).status_code == 200
        gateway = await Gateway.open(dashboard)
        yield dashboard, gateway
    finally:
        if gateway is not None:
            await gateway.close()
        await dashboard.close()


async def new_session(gateway: Gateway, title: str) -> tuple[str, str]:
    created = await gateway.call("session.create", {"source": "desktop", "title": title})
    return created["session_id"], created["stored_session_id"]


async def submit(gateway: Gateway, sid: str, text: str) -> int:
    """Sends a prompt; returns the event index to wait for its completion from."""
    mark = len(gateway.events)
    await gateway.call("prompt.submit", {"session_id": sid, "text": text})
    return mark


async def turn_done(gateway: Gateway, sid: str, mark: int, timeout: float = 60.0) -> dict:
    return await gateway.event("message.complete", lambda e: e.get("session_id") == sid, after=mark,
                               timeout=timeout)


async def ring(dashboard: Dashboard, stored: str, seen: int = 0) -> tuple[dict, Phone]:
    """What the app does on the VoIP push: open /phone for the pushed call and say it rings."""
    push = await dashboard.push_for(stored, seen)
    phone = await Phone.dial(dashboard, push["call_id"], "push", session_id=push["session_id"])
    await phone.send({"type": "ringing"})
    return push, phone


async def until(predicate, timeout: float = 30.0, what: str = "a condition"):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while loop.time() < deadline:
        value = await predicate()
        if value:
            return value
        await asyncio.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


def test_dashboard_auth_guards_the_plugin(hermes):
    sandbox, _, _ = hermes

    async def scenario():
        anonymous = Dashboard(sandbox)
        status_without_cookie = (await anonymous.get(f"{PREFIX}/status")).status_code
        await anonymous.close()
        async with signed_in(sandbox) as (dashboard, _):
            status = (await dashboard.get(f"{PREFIX}/status")).json()
            codes = {}
            for label, ticket in (("forged ticket", "not-a-ticket"), ("ticket", None)):
                socket = await dashboard.socket(f"{PREFIX}/phone", ticket=ticket or await dashboard.ticket())
                if label == "ticket":
                    await socket.send(json.dumps({"type": "hello", "call_id": uuid.uuid4().hex,
                                                  "initiated_by": "push"}))
                    codes["unknown call"] = json.loads(await socket.recv())
                await socket.wait_closed()
                codes[label] = socket.close_code
            reused = await dashboard.ticket()
            first = await dashboard.socket(f"{PREFIX}/phone", ticket=reused)
            await first.close()
            second = await dashboard.socket(f"{PREFIX}/phone", ticket=reused)
            await second.wait_closed()
            codes["reused ticket"] = second.close_code
            # A Host the dashboard doesn't serve (DNS rebinding): refused like a bad credential.
            uri = f"ws://evil.example:{sandbox.port}{PREFIX}/phone?ticket={await dashboard.ticket()}"
            async with websockets.connect(uri, host="127.0.0.1", port=sandbox.port, proxy=None) as foreign:
                await foreign.wait_closed()
                codes["foreign host"] = foreign.close_code
            return status_without_cookie, status, codes

    without, status, codes = asyncio.run(scenario())
    assert without == 401
    assert status["tts"] == "fake" and status["calls"] == 0 and status["active_call"] is None
    assert set(status) >= {"calls", "tts", "h2", "apns_configured", "scribe_configured"}
    assert codes["unknown call"] == {"type": "cancel", "reason": "unknown_call"}
    assert codes == {"unknown call": codes["unknown call"], "forged ticket": 4401, "ticket": 1000,
                     "reused ticket": 4401, "foreign host": 4401}


def test_sync_start_call_returns_what_the_user_said(hermes):
    sandbox, model, _ = hermes

    async def scenario():
        async with signed_in(sandbox) as (dashboard, gateway):
            sid, stored = await new_session(gateway, "Sync call")
            mark = await submit(gateway, sid, "call me sync: Pick a color.")
            push, phone = await ring(dashboard, stored)
            ready = phone.ready
            silent = list(phone.messages)
            await phone.send({"type": "answered"})
            line = await phone.heard("Pick a color.")
            await asyncio.sleep(0.3)  # the played ack is in before the user starts talking
            await phone.say("blue")
            await turn_done(gateway, sid, mark)
            result = start_call_result(model.requests, push["call_id"])
            status = (await dashboard.get(f"{PREFIX}/status")).json()
            # Hanging up ends the call; the plugin tells the (idle) conversation, which starts a new turn.
            code = await phone.hang_up()
            seen = await asyncio.to_thread(model.wait_for, "[Voice call ended by user]")
            deliveries = await dashboard.deliveries()
            return push, ready, silent, line, phone.audio_bytes, result, status, code, seen, deliveries

    push, ready, silent, line, audio, result, status, code, seen, deliveries = asyncio.run(scenario())
    assert set(push) == {"call_id", "session_id", "profile", "mode", "title"}
    assert push["mode"] == "sync" and push["title"] and len(push["call_id"]) == 32  # title: Hermes' live title
    assert ready == {"type": "ready", "call_id": push["call_id"], "state": "ringing"}
    assert silent == []  # nothing is spoken before the user answers
    assert line["format"] == "pcm_s16le" and line["sample_rate"] == 24000 and audio > 0
    assert result == {"said": "blue", "ending": "end_of_speech", "outcome": "answered", "call_id": push["call_id"]}
    assert "[Voice] blue" not in seen  # the waiting start_call took the reply: nothing was injected
    assert status["active_call"]["call_id"] == push["call_id"] and status["active_call"]["state"] == "live"
    assert status["active_call"]["initiated_by"] == "push"
    assert code == 1000
    notice = [d for d in deliveries if d["call_id"] == push["call_id"]
              and d["text"].startswith("[Voice call ended by user]")]
    assert notice and notice[0]["ok"] and notice[0]["via"] == "submit"  # the session was idle


def test_async_start_call_injects_what_the_user_says(hermes):
    sandbox, model, agent = hermes
    # The model takes a while over the first reply, so the second arrives while that turn is still running.
    agent.slow["pasta"] = 5.0

    async def scenario():
        async with signed_in(sandbox) as (dashboard, gateway):
            sid, stored = await new_session(gateway, "Async call")
            mark = await submit(gateway, sid, "call me async: What should we cook?")
            await turn_done(gateway, sid, mark)
            started = start_call_result(model.requests, key="status")
            push, phone = await ring(dashboard, stored)
            await phone.send({"type": "answered"})
            await phone.heard("What should we cook?")
            await asyncio.sleep(0.3)
            await phone.say("pasta")  # idle conversation: a new turn (prompt.submit)
            await asyncio.to_thread(model.wait_for, "[Voice] pasta")
            await asyncio.sleep(0.5)
            mark = len(gateway.events)
            await phone.say("with basil")  # while that turn runs: redirect, else steer
            await phone.heard("You said with basil.", timeout=60)
            await turn_done(gateway, sid, mark)
            deliveries = await dashboard.deliveries()
            # Said once the conversation is idle again. (A redirect Hermes accepts in the moment its last model
            # reply completes is dropped with that turn, unlike a steer: see the README's known limits.)
            await phone.say("thanks, bye", ending="hang_up")
            code = await phone.hang_up()
            seen = await asyncio.to_thread(model.wait_for, "[Voice, hung up] thanks, bye")
            deliveries_after = await dashboard.deliveries()
            return started, push, deliveries, code, seen, deliveries_after

    started, push, deliveries, code, seen, after = asyncio.run(scenario())
    assert started["status"] == "ringing" and started["call_id"] == push["call_id"] and push["mode"] == "async"
    by_text = {d["text"].split(" (")[0]: d for d in deliveries if d["call_id"] == push["call_id"]}
    assert by_text["[Voice] pasta"]["ok"] and by_text["[Voice] pasta"]["via"] == "submit"
    basil = by_text["[Voice] with basil"]
    assert basil["ok"] and basil["via"] in ("redirect", "steer") and basil["status"] in ("redirected", "queued")
    assert "(Reply out loud with start_call" in seen
    assert code == 1000
    # The hang-up turn already told the conversation: no separate "ended by user" notice.
    mine = [d for d in after if d["call_id"] == push["call_id"]]
    assert [d["via"] for d in mine if d["text"].startswith("[Voice, hung up] thanks, bye")] == ["submit"]
    assert not [d for d in mine if d["text"].startswith("[Voice call ended by user]")], mine


def test_rings_that_are_declined_unanswered_or_busy(hermes):
    sandbox, model, _ = hermes

    async def scenario():
        async with signed_in(sandbox) as (dashboard, gateway):
            # Declined while ringing: the sync start_call returns it, and nothing is injected.
            sid, stored = await new_session(gateway, "Declined call")
            mark = await submit(gateway, sid, "call me sync: Got a minute?")
            push, phone = await ring(dashboard, stored)
            await phone.send({"type": "declined"})
            await phone.send({"type": "bye", "reason": "declined"})
            declined_code = await phone.closed()
            await turn_done(gateway, sid, mark)
            declined = start_call_result(model.requests, push["call_id"])

            # Rings out: the phone gets cancel {no_answer}, the conversation a notice.
            sid2, stored2 = await new_session(gateway, "Unanswered call")
            mark2 = await submit(gateway, sid2, "call me async: Dinner is ready.")
            push2, phone2 = await ring(dashboard, stored2)
            await turn_done(gateway, sid2, mark2)
            # Meanwhile another conversation can't take the one call slot.
            sid3, stored3 = await new_session(gateway, "Busy call")
            mark3 = await submit(gateway, sid3, "call me async: Me too!")
            await turn_done(gateway, sid3, mark3)
            busy = start_call_result(model.requests, key="status")
            cancel = await phone2.expect("cancel", timeout=20)
            unanswered_code = await phone2.closed()
            await asyncio.to_thread(model.wait_for, "[Voice call not answered]")

            # Nobody ever answers the push: unreachable.
            mark4 = await submit(gateway, sid3, "call me async: Anyone home?")
            push4 = await dashboard.push_for(stored3)
            await turn_done(gateway, sid3, mark4)
            seen = await asyncio.to_thread(model.wait_for, "[Voice line not delivered: the phone never answered",
                                           30)
            late = await Phone.dial(dashboard, push4["call_id"], "push", session_id=stored3)
            return declined, declined_code, cancel, unanswered_code, busy, push2, push4, late.ready, seen

    declined, declined_code, cancel, unanswered_code, busy, push2, push4, late, seen = asyncio.run(scenario())
    assert declined["outcome"] == "declined" and declined["said"] == "" and declined_code == 1000
    assert cancel == {"type": "cancel", "reason": "no_answer", "_taken": True} and unanswered_code == 1000
    assert busy["status"] == "busy" and busy["call_id"] is None and "Dinner is ready" in busy["note"]
    assert push4["call_id"] != push2["call_id"]
    assert late == {"type": "cancel", "reason": "unreachable"}  # a push that comes in too late is cancelled
    assert "[Voice call not answered] The user didn't take the call (they didn't pick up)." in seen
