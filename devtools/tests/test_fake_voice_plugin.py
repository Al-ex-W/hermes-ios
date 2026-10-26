"""The fake hermes_voice plugin against the plugin <-> phone wire contract, driven by a scripted phone."""

from __future__ import annotations

import asyncio
import json
import time
import uuid
from datetime import datetime, timezone
from typing import Any

import httpx
import pytest
import websockets

from fakeclient import CONTRACT_PATH, Contract, Gateway, serving, signed_in, until
from fake_voice_plugin import ASYNC_LINE, ENDED_BY_USER, HELLO_TEXT, NOT_ANSWERED, PREFIX, REPLY_HINT, SAMPLE_RATE, \
    SYNC_LINE

STATUS = f"{PREFIX}/status"
# The real plugin's notes on async start_call results (hermes-voice-plugin/hub.py start_call).
_HEARD_AS = " What the user says arrives as [Voice] messages; answer them with start_call."
SPEAKING_NOTE = "Your line is being spoken." + _HEARD_AS
RINGING_NOTE = "The phone is ringing; your line is spoken once the user answers." + _HEARD_AS


def stamp(moment: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if moment is None else moment, timezone.utc).isoformat()


class Phone:
    """A scripted HermesVoice call link: records every frame, counts PCM per line, acks lines on request."""

    def __init__(self, ws: Any, call_id: str) -> None:
        self.ws = ws
        self.call_id = call_id
        self.frames: list[dict[str, Any] | int] = []  # JSON frames, and the byte count of each binary frame
        self.inbox: asyncio.Queue[dict[str, Any] | int] = asyncio.Queue()
        self.reader = asyncio.create_task(self._read())

    @classmethod
    async def dial(cls, base: str, http: httpx.AsyncClient, call_id: str, initiated_by: str,
                   session_id: str | None = None, title: str = "Test chat") -> "Phone":
        ticket = (await http.post("/api/auth/ws-ticket")).json()["ticket"]
        phone = cls(await websockets.connect(f"ws://{base}{PREFIX}/phone?ticket={ticket}"), call_id)
        hello: dict[str, Any] = {"type": "hello", "call_id": call_id, "title": title, "initiated_by": initiated_by,
                                 "app_version": "test"}
        if session_id is not None:
            hello["session_id"] = session_id
        await phone.send(hello)
        return phone

    async def _read(self) -> None:
        try:
            async for raw in self.ws:
                item: dict[str, Any] | int = len(raw) if isinstance(raw, bytes) else json.loads(raw)
                self.frames.append(item)
                await self.inbox.put(item)
        except websockets.ConnectionClosed:
            pass

    async def send(self, message: dict[str, Any]) -> None:
        await self.ws.send(json.dumps(message))

    async def next(self, kind: str, timeout: float = 5) -> dict[str, Any]:
        """The next JSON frame of ``kind`` (PCM and other frames before it are skipped)."""
        async with asyncio.timeout(timeout):
            while True:
                item = await self.inbox.get()
                if isinstance(item, dict) and item.get("type") == kind:
                    return item

    async def line(self, timeout: float = 5) -> tuple[dict[str, Any], int, dict[str, Any]]:
        """One spoken line: speech_start, the PCM bytes that followed, speech_end."""
        start = await self.next("speech_start", timeout)
        pcm = 0
        async with asyncio.timeout(timeout):
            while True:
                item = await self.inbox.get()
                if isinstance(item, int):
                    pcm += item
                elif item.get("type") == "speech_end":
                    assert item["id"] == start["id"], item
                    return start, pcm, item

    async def hear(self, timeout: float = 5) -> dict[str, Any]:
        """Take one line and confirm it was played."""
        start, pcm, end = await self.line(timeout)
        assert pcm > 0 and pcm % 2 == 0 and set(end) == {"type", "id"}, (pcm, end)
        await self.send({"type": "played", "id": start["id"]})
        return start

    async def say(self, text: str, kind: str = "end_of_speech", started: float | None = None) -> None:
        started = time.time() if started is None else started
        ending: dict[str, Any] = {"kind": kind}
        if kind == "end_of_speech":
            ending.update(detector="apple_silence", detail=1.2)
        await self.send({"type": "user_turn", "call_id": self.call_id, "text": text, "ending": ending,
                         "provider": "apple", "language": "en-US", "started_at": stamp(started),
                         "ended_at": stamp(max(started, time.time()))})

    async def closed(self, timeout: float = 5) -> int | None:
        await asyncio.wait_for(self.reader, timeout)
        return self.ws.close_code

    async def hang_up(self) -> None:
        await self.ws.close()
        await self.reader

    def kinds(self) -> list[str]:
        return [f["type"] for f in self.frames if isinstance(f, dict)]


async def start_session(gateway: Gateway, **params: Any) -> tuple[str, str]:
    created = await gateway.call("session.create", {"source": "desktop", **params})
    return created["session_id"], created["stored_session_id"]


async def turn(gateway: Gateway, timeout: float = 5) -> dict[str, Any]:
    """The next finished turn: its tool calls (name, args, parsed result) and its final text."""
    tools: list[tuple[str, dict, Any]] = []
    async with asyncio.timeout(timeout):
        while (event := await gateway.inbox.get())["type"] != "message.complete":
            if event["type"] == "tool.complete":
                payload = event["payload"]
                raw = payload["result"].get("result", payload["result"].get("error"))
                tools.append((payload["name"], payload["args"], json.loads(raw)))
    return {"text": event["payload"]["text"], "tools": tools}


async def user_rows(http: httpx.AsyncClient, key: str) -> list[str]:
    messages = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
    return [m["content"] for m in messages if m["role"] == "user"]


def test_a_user_initiated_call_announces_itself_and_every_turn_is_injected():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                idle = (await http.get(STATUS)).json()
                call_id = uuid.uuid4().hex
                phone = await Phone.dial(base, http, call_id, "user", session_id=key, title="Kitchen chat")
                ready = await phone.next("ready")
                greeting = await phone.hear()
                announced = await turn(gateway)
                live = (await http.get(STATUS)).json()
                await phone.say("what time is it")
                answer = await phone.hear()
                answered = await turn(gateway)
                await phone.send({"type": "bye", "reason": "user"})
                ended = await phone.next("ended")
                close_code = await phone.closed()
                goodbye = await turn(gateway)
                after = (await http.get(STATUS)).json()
                rows = await user_rows(http, key)
                problems = Contract(CONTRACT_PATH).check_gateway(gateway) if CONTRACT_PATH else []
                await gateway.close()
            return (call_id, idle, ready, greeting, announced, live, answer, answered, ended, close_code, goodbye,
                    after, rows, problems)

    (call_id, idle, ready, greeting, announced, live, answer, answered, ended, close_code, goodbye, after, rows,
     problems) = asyncio.run(scenario())
    assert idle == {"calls": 0, "tts": "fake", "h2": False, "apns_configured": False, "scribe_configured": False,
                    "active_call": None, "devices": []}
    assert ready == {"type": "ready", "call_id": call_id, "state": "live"}
    assert greeting["text"] == HELLO_TEXT and greeting["sample_rate"] == SAMPLE_RATE
    assert greeting["format"] == "pcm_s16le"
    assert announced["text"] == "Call connected."
    assert announced["tools"] == [("start_call", {"text": HELLO_TEXT, "mode": "async"},
                                   {"call_id": call_id, "status": "speaking", "note": SPEAKING_NOTE})]
    assert live["calls"] == 1
    assert live["active_call"] == {"call_id": call_id, "session_id": live["active_call"]["session_id"],
                                   "title": live["active_call"]["title"], "state": "live", "initiated_by": "user"}
    assert answer["text"] == "You said: what time is it" and answered["text"] == "You said: what time is it"
    assert ended == {"type": "ended", "outcome": "ended_by_user"} and close_code == 1000
    assert goodbye == {"text": "Call ended.", "tools": []}
    assert after["calls"] == 0 and after["active_call"] is None
    assert rows[0].startswith(f"[Voice call started] The user is calling you from the HermesVoice app (call {call_id}).")
    assert rows[1] == f"[Voice] what time is it {REPLY_HINT}"
    assert rows[2].startswith(f"{ENDED_BY_USER} Reply in text")
    assert problems == []


def test_a_sync_call_rings_returns_the_reply_and_injects_turns_from_before_the_line():
    async def scenario():
        async with serving() as (fake, base):
            plugin = fake.voice_plugin
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                submitted = await gateway.call("prompt.submit", {"session_id": sid, "text": "call me sync"})
                await until(lambda: plugin.pushes)
                push = plugin.pushes[-1]
                phone = await Phone.dial(base, http, push["call_id"], "push", session_id=key)
                ready = await phone.next("ready")
                await phone.send({"type": "ringing"})
                await phone.send({"type": "answered"})
                start, _, _ = await phone.line()
                # Started before the line was played: not the reply, so it is injected (behind the running turn).
                await phone.say("never mind", kind="cut_off", started=time.time() - 3)
                await phone.send({"type": "played", "id": start["id"]})
                await phone.say("blue please")
                replied = await turn(gateway)
                followup = await phone.hear()
                cut_off = await turn(gateway)
                rows = await user_rows(http, key)
                await phone.hang_up()
                await gateway.close()
            return submitted, push, key, ready, start, replied, followup, cut_off, rows

    submitted, push, key, ready, start, replied, followup, cut_off, rows = asyncio.run(scenario())
    assert submitted["status"] == "streaming"
    assert set(push) == {"call_id", "session_id", "profile", "mode", "title"}
    assert push["session_id"] == key and push["mode"] == "sync" and len(push["call_id"]) == 32
    assert ready == {"type": "ready", "call_id": push["call_id"], "state": "ringing"}
    assert start["text"] == SYNC_LINE
    [(name, args, result)] = replied["tools"]
    assert (name, args) == ("start_call", {"text": SYNC_LINE, "mode": "sync"})
    # The plugin's sync shape (hub._sync): `ending` is the turn's kind.
    assert result == {"said": "blue please", "outcome": "answered", "call_id": push["call_id"],
                      "ending": "end_of_speech"}
    assert replied["text"] == "You said: blue please"
    assert followup["text"] == "You said: never mind"
    assert cut_off["text"] == "You said (cut off): never mind"
    assert rows[0] == "call me sync" and rows[1] == f"[Voice, cut off] never mind {REPLY_HINT}"
    assert not any("blue please" in row for row in rows)  # the sync reply went to the tool, not into the chat


def test_an_async_call_rung_from_the_debug_route_force_injects_the_reply():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                rung = (await http.post(f"{PREFIX}/debug/ring", json={
                    "session_id": key, "mode": "async", "text": "Ping from the test"})).json()
                rang = await turn(gateway)
                pushes = (await http.get(f"{PREFIX}/debug/pushes")).json()["pushes"]
                phone = await Phone.dial(base, http, rung["call_id"], "push", session_id=key)
                ready = await phone.next("ready")
                await phone.send({"type": "ringing"})
                await phone.send({"type": "answered"})
                line = await phone.hear()
                await phone.say("pong back")
                answer = await phone.hear()
                injected = await turn(gateway)
                rows = await user_rows(http, key)
                await phone.hang_up()
                await gateway.close()
                unknown = await http.post(f"{PREFIX}/debug/ring", json={"session_id": "nope", "mode": "async"})
            return key, rung, rang, pushes, ready, line, answer, injected, rows, unknown

    key, rung, rang, pushes, ready, line, answer, injected, rows, unknown = asyncio.run(scenario())
    assert rung["ok"] is True and rung["status"] == "ringing" and rung["mode"] == "async"
    assert rung["push"] == {"call_id": rung["call_id"], "session_id": key, "profile": "default", "mode": "async",
                            "title": rung["push"]["title"]}
    assert pushes == [rung["push"]]
    assert rang["tools"] == [("start_call", {"text": "Ping from the test", "mode": "async"},
                              {"call_id": rung["call_id"], "status": "ringing", "note": RINGING_NOTE})]
    assert rang["text"] == "Ringing your phone."
    assert ready["state"] == "ringing" and line["text"] == "Ping from the test"
    assert answer["text"] == "You said: pong back"
    assert injected["tools"] == [("start_call", {"text": "You said: pong back", "mode": "async"},
                                  {"call_id": rung["call_id"], "status": "speaking", "note": SPEAKING_NOTE})]
    assert rows[0] == "call me async: Ping from the test" and rows[1] == f"[Voice] pong back {REPLY_HINT}"
    assert unknown.status_code == 404


def test_the_push_carries_the_profile_of_the_chat_that_rang():
    """hub.py sends call.owner.profile: the app opens the ringing chat under that profile, not under default."""
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                _, key = await start_session(gateway, profile="research")
                rung = (await http.post(f"{PREFIX}/debug/ring", json={"session_id": key, "mode": "async"})).json()
                await turn(gateway)
                await gateway.close()
            return key, rung

    key, rung = asyncio.run(scenario())
    assert rung["ok"] is True and rung["push"]["session_id"] == key and rung["push"]["profile"] == "research"


def test_a_declined_call_returns_declined_to_sync_and_notifies_async():
    async def scenario():
        async with serving() as (fake, base):
            plugin = fake.voice_plugin
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "call me sync"})
                await until(lambda: len(plugin.pushes) == 1)
                phone = await Phone.dial(base, http, plugin.pushes[-1]["call_id"], "push", session_id=key)
                await phone.next("ready")
                await phone.send({"type": "ringing"})
                await phone.send({"type": "declined"})
                sync_close = await phone.closed()
                sync = await turn(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "call me async"})
                rang = await turn(gateway)
                phone = await Phone.dial(base, http, plugin.pushes[-1]["call_id"], "push", session_id=key)
                await phone.next("ready")
                await phone.send({"type": "bye"})  # hung up while it rang: also a decline
                async_close = await phone.closed()
                notified = await turn(gateway)
                late = await Phone.dial(base, http, plugin.pushes[-1]["call_id"], "push", session_id=key)
                late_cancel = await late.next("cancel")
                late_close = await late.closed()
                # The phone's own ring timeout runs out first: bye {reason: no_answer}, as the real plugin has it.
                await gateway.call("prompt.submit", {"session_id": sid, "text": "call me async"})
                await turn(gateway)
                phone = await Phone.dial(base, http, plugin.pushes[-1]["call_id"], "push", session_id=key)
                await phone.next("ready")
                await phone.send({"type": "ringing"})
                await phone.send({"type": "bye", "reason": "no_answer"})
                await phone.closed()
                await turn(gateway)
                rows = await user_rows(http, key)
                await gateway.close()
            return sync_close, sync, rang, async_close, notified, late_cancel, late_close, rows

    sync_close, sync, rang, async_close, notified, late_cancel, late_close, rows = asyncio.run(scenario())
    assert sync_close == 1000
    [(_, _, result)] = sync["tools"]
    assert result["outcome"] == "declined" and result["said"] == "" and result["ending"] is None
    assert sync["text"] == "The call ended without a reply (declined)."
    assert rang["tools"][0][2]["status"] == "ringing"
    assert async_close == 1000
    assert notified == {"text": "The call was not answered.", "tools": []}
    assert late_cancel == {"type": "cancel", "reason": "declined"} and late_close == 1000
    assert rows == ["call me sync", "call me async",
                    f"{NOT_ANSWERED} The user didn't take the call (they declined it). Reply in text.",
                    "call me async",
                    f"{NOT_ANSWERED} The user didn't take the call (they didn't pick up). Reply in text."]


def test_an_unanswered_call_is_cancelled_after_the_ring_timeout():
    async def scenario():
        async with serving(call_ring_timeout=1.0) as (fake, base):
            plugin = fake.voice_plugin
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "call me async"})
                await until(lambda: plugin.pushes)
                phone = await Phone.dial(base, http, plugin.pushes[-1]["call_id"], "push", session_id=key)
                ready = await phone.next("ready")
                await phone.send({"type": "ringing"})
                rang = await turn(gateway)
                cancel = await phone.next("cancel")
                close_code = await phone.closed()
                notified = await turn(gateway)
                # A sync call whose push never reached a phone (the Simulator without a push): unreachable.
                await gateway.call("prompt.submit", {"session_id": sid, "text": "call me sync: are you there?"})
                unreached = await turn(gateway)
                rows = await user_rows(http, key)
                await gateway.close()
            return rang, ready, cancel, close_code, notified, unreached, rows, plugin.pushes

    rang, ready, cancel, close_code, notified, unreached, rows, pushes = asyncio.run(scenario())
    assert rang["tools"][0][1] == {"text": ASYNC_LINE, "mode": "async"}
    assert ready["state"] == "ringing"
    assert cancel == {"type": "cancel", "reason": "no_answer"} and close_code == 1000
    assert notified == {"text": "The call was not answered.", "tools": []}
    [(_, args, result)] = unreached["tools"]
    assert args == {"text": "are you there?", "mode": "sync"}
    assert result == {"said": "", "ending": None, "outcome": "unreachable", "call_id": pushes[-1]["call_id"],
                      "note": "The phone never answered the ring (it may be offline). Reply in text."}
    assert unreached["text"] == "The call ended without a reply (unreachable)."
    assert rows[1] == f"{NOT_ANSWERED} The user didn't take the call (they didn't pick up). Reply in text."
    assert len(rows) == 3  # the sync outcome was returned, not injected


def test_the_call_slot_is_busy_for_other_sessions_and_reused_by_its_own():
    async def scenario():
        async with serving() as (fake, base):
            plugin = fake.voice_plugin
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid_a, key_a = await start_session(gateway)
                sid_b, key_b = await start_session(gateway)
                call_id = uuid.uuid4().hex
                phone = await Phone.dial(base, http, call_id, "user", session_id=key_a, title="Chat A")
                await phone.next("ready")
                await phone.hear()
                await turn(gateway)
                other = await Phone.dial(base, http, uuid.uuid4().hex, "user", session_id=key_b, title="Chat B")
                busy_close = await other.closed()
                await gateway.call("prompt.submit", {"session_id": sid_b, "text": "call me async"})
                busy = await turn(gateway)
                await gateway.call("prompt.submit", {"session_id": sid_a, "text": "call me async: still here"})
                reused = await turn(gateway)
                again = await phone.hear()
                stray = await Phone.dial(base, http, uuid.uuid4().hex, "push", session_id=key_b)
                stray_cancel = await stray.next("cancel")
                await gateway.call("prompt.submit", {"session_id": sid_a, "text": "please hang up"})
                goodbye = await phone.hear()
                hung_up = await turn(gateway)
                ended = await phone.next("ended")
                await phone.closed()
                free = (await http.get(STATUS)).json()
                await gateway.close()
            return call_id, busy_close, busy, reused, again, stray_cancel, goodbye, hung_up, ended, free, plugin.pushes

    call_id, busy_close, busy, reused, again, stray_cancel, goodbye, hung_up, ended, free, pushes = \
        asyncio.run(scenario())
    assert busy_close == 4429
    [(_, _, refused)] = busy["tools"]
    assert refused["status"] == "busy" and refused["call_id"] is None and "Chat A" in refused["note"]
    assert reused["tools"] == [("start_call", {"text": "still here", "mode": "async"},
                                {"call_id": call_id, "status": "speaking", "note": SPEAKING_NOTE})]
    assert again["text"] == "still here" and pushes == []  # the live call was reused: nothing rang
    assert stray_cancel == {"type": "cancel", "reason": "unknown_call"}
    assert goodbye["text"] == "Goodbye from fake Hermes."
    assert hung_up["tools"][0][2] == {"call_id": call_id, "outcome": "ended_by_agent",
                                      "note": "Hung up. Spoken to the user."}
    assert hung_up["text"] == "Hung up." and ended == {"type": "ended", "outcome": "ended_by_agent"}
    assert free["calls"] == 0


def test_routes_need_the_sign_in_and_links_need_a_ticket_and_a_hello():
    async def scenario():
        async with serving() as (fake, base):
            async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                denied = [(await anonymous.request(method, f"{PREFIX}/{path}", json={})).status_code
                          for method, path in (("GET", "status"), ("POST", "devices"), ("POST", "scribe-token"),
                                               ("POST", "debug/ring"))]
            async with signed_in(base) as http:
                device = await http.post(f"{PREFIX}/devices", json={
                    "voip_token": "ab" * 32, "alert_token": "cd" * 32, "environment": "sandbox",
                    "bundle_id": "com.example.hermesvoice"})
                bad_device = await http.post(f"{PREFIX}/devices", json={
                    "voip_token": "ab" * 32, "environment": "staging", "bundle_id": "com.example.hermesvoice"})
                scribe = (await http.post(f"{PREFIX}/scribe-token")).json()
                cross_origin = await http.post(f"{PREFIX}/scribe-token", headers={"Origin": "http://evil.example"})
                gateway = await Gateway.connect(base, http)
                _, key = await start_session(gateway)

                async with websockets.connect(f"ws://{base}{PREFIX}/phone?ticket=nope") as ws:
                    with pytest.raises(websockets.ConnectionClosed):
                        await ws.recv()
                    no_ticket = ws.close_code
                bad_hello = await Phone.dial(base, http, "not-a-call-id", "user", session_id=key)
                bad_hello_code = await bad_hello.closed()
                call_id = uuid.uuid4().hex
                first = await Phone.dial(base, http, call_id, "user", session_id=key)
                await first.next("ready")
                await first.hear()
                second = await Phone.dial(base, http, call_id, "user", session_id=key)
                rejoined = await second.next("ready")
                replaced = await first.closed()
                await second.send({"type": "ping"})
                pong = await second.next("pong")
                await second.hang_up()
                await gateway.close()
            return denied, device, bad_device, scribe, cross_origin, fake.voice_plugin.devices, no_ticket, \
                bad_hello_code, rejoined, replaced, pong

    (denied, device, bad_device, scribe, cross_origin, devices, no_ticket, bad_hello_code, rejoined, replaced,
     pong) = asyncio.run(scenario())
    assert denied == [401, 401, 401, 401]
    assert device.json() == {"ok": True} and bad_device.status_code == 422
    assert devices["ab" * 32]["environment"] == "sandbox" and devices["ab" * 32]["bundle_id"].endswith("hermesvoice")
    assert scribe["token"].startswith("fake-scribe-") and datetime.fromisoformat(scribe["expires_at"]).tzinfo
    assert cross_origin.status_code == 403
    assert no_ticket == 4401 and bad_hello_code == 4400
    assert rejoined["state"] == "live" and replaced == 4409
    assert pong == {"type": "pong"}


def test_a_tts_error_and_a_link_that_never_comes_back_are_injected():
    async def scenario():
        async with serving(call_drop_retention=0.3) as (fake, base):
            fake.voice_plugin.tts_error = "voice quota exceeded"
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                _, key = await start_session(gateway)
                phone = await Phone.dial(base, http, uuid.uuid4().hex, "user", session_id=key)
                await phone.next("ready")
                start = await phone.next("speech_start")
                failed = await phone.next("speech_end")
                await turn(gateway)  # the "[Voice call started]" turn
                undelivered = await turn(gateway)
                await phone.hang_up()  # a drop, not a bye
                lost = await turn(gateway)
                rows = await user_rows(http, key)
                status = (await http.get(STATUS)).json()
                await gateway.close()
            return start, failed, undelivered, lost, rows, status

    start, failed, undelivered, lost, rows, status = asyncio.run(scenario())
    assert failed == {"type": "speech_end", "id": start["id"], "error": "voice quota exceeded"}
    assert undelivered["text"] == "That line was not delivered."
    assert rows[1] == "[Voice line not delivered: text-to-speech failed (voice quota exceeded)]"
    assert lost["text"] == "The call was lost."
    assert rows[2].startswith("[Voice call ended: the phone's connection was lost")
    assert status["calls"] == 0
