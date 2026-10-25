"""Fake ``hermes_voice`` plugin for the fake Hermes dashboard (devtools/fake_hermes.py mounts it).

It speaks the plugin <-> phone wire contract of the real plugin (hermes-voice-plugin/, plan Part D) so the app's
call mode can be tested in the iOS Simulator without Hermes, APNs or ElevenLabs:

  WS   /api/plugins/hermes_voice/phone?ticket=…   the call link; the ticket is the same single-use one /api/ws takes
  POST /api/plugins/hermes_voice/devices          {voip_token, alert_token?, environment, bundle_id} -> {ok}
  POST /api/plugins/hermes_voice/scribe-token     -> {token, expires_at}: a dummy token (ElevenLabs is never called)
  GET  /api/plugins/hermes_voice/status           -> {calls, tts: "fake", h2, apns_configured, scribe_configured,
                                                      active_call: {call_id, session_id, title, state, initiated_by}?}
  POST /api/plugins/hermes_voice/debug/ring       {session_id, mode?, text?}: makes that session's fake agent call
                                                  start_call and returns the VoIP push the phone would have got
  GET  /api/plugins/hermes_voice/debug/pushes     every push the fake would have sent

The HTTP routes need the dashboard sign-in cookie, like every /api/* route of the fake.

Link protocol (JSON text frames plus binary PCM16LE mono at 24 kHz; the speech is a tone per word):
  phone hello {call_id (32 hex), session_id?, title?, initiated_by: "user"|"push", app_version}
        -> ready {call_id, state: "ringing"|"live"}
  phone ringing / answered / declined (a push call), played {id}, user_turn {…}, ping -> pong, bye {reason?}
  plugin speech_start {id, text, sample_rate, format: "pcm_s16le"}, PCM frames, then speech_end {id} |
        speech_end {id, cancelled: true} | speech_end {id, error}; cancel {reason} ends a ringing call,
        ended {outcome} a live one
  close codes: 4401 bad ticket, 4400 bad hello, 4409 replaced by a newer link for the call, 4429 another session
        holds the call slot, 1011 the link stopped taking frames

The call model is the real plugin's: one call slot; a call belongs to the session that started it (the session_id of
a user-initiated hello, or the session whose agent called start_call). A user-initiated call is live at once and the
plugin injects "[Voice call started] … (call <call_id>) …" into its session (turns are held until that is delivered).
Every user_turn is force-injected into the owning session as "[Voice] <said> (Reply out loud with start_call; …)"
("[Voice, cut off] …", "[Voice, hung up] …"), except the one a waiting sync start_call consumes: the first turn that
started after its line was played. Injecting mirrors inject.py: a running session takes the text after its turn
(Hermes redirects or steers; the fake queues), an idle one starts a new turn. Async calls get their notices injected
("[Voice call not answered] …", "[Voice call ended by user] …", "[Voice call ended: …lost…]", "[Voice line not
delivered: …]"); a sync start_call returns the outcome instead. The texts are hermes-voice-plugin/inject.py's. A ring
ends as no_answer when the phone rang but nobody answered, as unreachable when no phone ever opened the link.

The fake agent (fake_hermes.py run_turn hands these to ``FakeVoicePlugin.handle``):
  "call me sync[: <text>]"   start_call(text, mode="sync"): rings, speaks once answered, returns the user's next turn
                             {said, ending, outcome, call_id}, then streams "You said: <said>" as text
  "call me async[: <text>]"  start_call(text, mode="async"): returns {call_id, status} at once
  "[Voice call started] …"   start_call("Hi, I am fake Hermes. I can hear you.") on that call
  "[Voice] <said>"           start_call("You said: <said>") while the call is live, and the same as text
  "hang up" / "end the call" end_call("Goodbye from fake Hermes.") on this session's call
  the plugin's notices       a short text reply

Simulator: the Simulator can't receive VoIP pushes, so nothing is pushed. Each push is logged (``FAKE … voice push``)
and returned by debug/ring and debug/pushes; hand {call_id, session_id} to the app's debug path so it opens /phone
with initiated_by "push" (the fake then answers ready {state: "ringing"}). To ring from a terminal:

  curl -c jar.txt -H 'Content-Type: application/json' \\
       -d '{"provider":"basic","username":"test","password":"test"}' http://127.0.0.1:9311/auth/password-login
  curl -b jar.txt -H 'Content-Type: application/json' \\
       -d '{"session_id":"<id>","mode":"sync","text":"Pick a color"}' \\
       http://127.0.0.1:9311/api/plugins/hermes_voice/debug/ring

Options (fake_hermes.py flags): --call-ring-timeout (default 45 s, then no_answer/unreachable), --call-drop-retention
(default 60 s a live call waits for a dropped link before it is lost).
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import re
import secrets
import struct
import sys
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Awaitable, Iterator

from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.routing import BaseRoute, Route, WebSocketRoute
from starlette.websockets import WebSocket, WebSocketDisconnect

PREFIX = "/api/plugins/hermes_voice"
SAMPLE_RATE = 24_000
RING_TIMEOUT = 45.0
# A live call whose link dropped waits this long for the phone to reconnect before it is lost.
DROP_RETENTION = 60.0
HELLO_TIMEOUT = 15.0
# A link that takes no frame for this long has stopped reading: it is closed with 1011 and the phone reconnects.
SEND_TIMEOUT = 5.0
NOTICE_TIMEOUT = 2.0
# Time allowed beyond the audio's own length for the phone's played ack.
PLAYBACK_MARGIN = 15.0
# A turn counts as the reply to a sync line when it started after the line's played ack, less this much (latency,
# clocks): the phone's started_at is the phone's clock, the ack time the fake's.
PLAYED_SLACK = 0.5
SCRIBE_TOKEN_TTL = 15 * 60
ENDED_MEMORY = 64
MODES = ("sync", "async")
# Policy: the real plugin allows dashboard/desktop sessions and the owner's DMs; the fake refuses these sources.
REFUSED_SOURCES = {"cron", "subagent"}
ENDINGS = ("end_of_speech", "cut_off", "hang_up", "muted", "dropped", "provider_error")
PROVIDERS = ("apple", "scribe")
# The injected texts of hermes-voice-plugin/inject.py.
ENDING_MARKERS = {"end_of_speech": "", "cut_off": "cut off", "hang_up": "hung up", "muted": "muted",
                  "dropped": "line dropped", "provider_error": "speech recognition failed"}
REPLY_HINT = "(Reply out loud with start_call; your text replies are not spoken.)"
HUNG_UP_HINT = "(The user hung up, so the call is over; reply in text.)"
# The notes on start_call results (hermes-voice-plugin/hub.py: start_call, _outcome_note).
ASYNC_NOTES = {
    "ringing": "The phone is ringing; your line is spoken once the user answers.",
    "speaking": "Your line is being spoken.",
    "ended": "The call ended before your line could be spoken.",
}
ASYNC_HINT = " What the user says arrives as [Voice] messages; answer them with start_call."
OUTCOME_NOTES = {
    "no_answer": "The user didn't pick up. Reply in text.",
    "declined": "The user declined the call. Reply in text.",
    "push_failed": "The phone couldn't be rung: the push failed. Reply in text.",
    "unreachable": "The phone never answered the ring (it may be offline). Reply in text.",
    "lost": "The call's connection was lost. Reply in text.",
    "ended_by_user": "The user hung up. Reply in text.",
    "ended_by_agent": "The call was ended with end_call.",
}

# The prefixes the fake agent recognizes the plugin's notices by.
STARTED = "[Voice call started]"
NOT_ANSWERED = "[Voice call not answered]"
NOT_DELIVERED = "[Voice line not delivered"
ENDED_BY_USER = "[Voice call ended by user]"
LOST = "[Voice call ended:"
HELLO_TEXT = "Hi, I am fake Hermes. I can hear you."
SYNC_LINE = "Fake Hermes calling. What should I write down?"
ASYNC_LINE = "Fake Hermes calling. Say something and I will answer."
GOODBYE = "Goodbye from fake Hermes."

CALL_ID = re.compile(r"[0-9a-f]{32}")
NOTICE_CALL_ID = re.compile(r"\b([0-9a-fA-F]{32})\b")
CALL_ME = re.compile(r"call me (sync|async)\b[:,]?\s*(.*)", re.IGNORECASE | re.DOTALL)
HANG_UP = re.compile(r"\b(hang up|end the call)\b", re.IGNORECASE)
VOICE_TURN = re.compile(r"\[Voice(?:, ([^\]]+))?\] ?(.*)", re.DOTALL)
# A merged queue slot is prompts joined by blank lines; the plugin's own texts start a new block with "[Voice".
BLOCKS = re.compile(r"\n\n(?=\[Voice)")
VOIP_TOKEN = re.compile(r"[0-9a-fA-F]{16,256}")

# What a send on (or a read from) a socket that is gone raises.
_SOCKET_GONE = (WebSocketDisconnect, RuntimeError, OSError)


def normalize_call_id(value: Any) -> str | None:
    call_id = str(value or "").strip().lower()
    return call_id if CALL_ID.fullmatch(call_id) else None


def iso(moment: float) -> str:
    return datetime.fromtimestamp(moment, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_time(value: Any) -> float | None:
    try:
        moment = datetime.fromisoformat(str(value))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


async def first_of(*events: asyncio.Event, timeout: float | None = None) -> None:
    """Wait until any of ``events`` is set (or ``timeout`` passes)."""
    waits = [asyncio.ensure_future(event.wait()) for event in events]
    try:
        await asyncio.wait(waits, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for wait in waits:
            wait.cancel()


async def close_quietly(ws: WebSocket, code: int) -> None:
    try:
        await ws.close(code=code)
    except Exception:  # noqa: BLE001 - already closed
        pass


async def next_message(ws: WebSocket) -> dict[str, Any] | None:
    """The phone's next JSON object; None for any other frame. Raises WebSocketDisconnect when it goes away."""
    message = await ws.receive()
    if message["type"] == "websocket.disconnect":
        raise WebSocketDisconnect(message.get("code", 1000))
    try:
        data = json.loads(message.get("text") or "")
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


_TONES: dict[int, bytes] = {}


def fake_speech(text: str) -> Iterator[bytes]:
    """A short tone per word (like hermes-voice-mcp's HERMES_VOICE_FAKE_TTS), PCM16LE mono at SAMPLE_RATE."""
    gap = b"\x00\x00" * int(SAMPLE_RATE * 0.05)
    for index, _ in enumerate(text.split()[:40]):
        freq = 440 + 60 * (index % 5)
        if freq not in _TONES:
            samples = int(SAMPLE_RATE * 0.18)
            _TONES[freq] = b"".join(struct.pack("<h", int(6000 * math.sin(2 * math.pi * freq * n / SAMPLE_RATE)))
                                    for n in range(samples))
        yield _TONES[freq] + gap


@dataclass
class Turn:
    """One user_turn: what was said and how the turn ended (the app's provider-agnostic UserTurn)."""

    call_id: str
    text: str
    ending: dict[str, Any]
    provider: str
    language: str | None
    started: float
    ended: float

    @property
    def kind(self) -> str:
        return self.ending["kind"]

    @classmethod
    def parse(cls, message: dict[str, Any]) -> "Turn | str":
        """The turn, or why it is malformed."""
        ending = message.get("ending")
        if not isinstance(ending, dict) or ending.get("kind") not in ENDINGS:
            return f"ending.kind must be one of {', '.join(ENDINGS)}"
        if message.get("provider") not in PROVIDERS:
            return "provider must be apple or scribe"
        text = message.get("text")
        if not isinstance(text, str):
            return "text must be a string"
        started, ended = parse_time(message.get("started_at")), parse_time(message.get("ended_at"))
        if started is None or ended is None:
            return "started_at and ended_at must be ISO-8601 times"
        clean = {k: ending[k] for k in ("kind", "detector", "detail", "error") if ending.get(k) is not None}
        language = message.get("language")
        return cls(str(message.get("call_id") or "").lower(), text, clean, message["provider"],
                   language if isinstance(language, str) else None, started, ended)

    def injected(self) -> str | None:
        """The text force-injected into the session (inject.py turn_text), or None when there is nothing to tell."""
        said = " ".join(self.text.split())
        marker = ENDING_MARKERS[self.kind]
        if not said:
            if self.kind != "provider_error":
                return None  # silence that ended (mute, hang-up, drop): the call notices cover it
            error = self.ending.get("error")
            detail = f": {' '.join(str(error).split())[:120]}" if error else ""
            return f"[Voice, {marker}{detail}] {REPLY_HINT}"
        prefix = f"[Voice, {marker}]" if marker else "[Voice]"
        return f"{prefix} {said} {HUNG_UP_HINT if self.kind == 'hang_up' else REPLY_HINT}"


@dataclass(eq=False)
class Waiter:
    """A sync start_call waiting for the user's reply to its line."""

    speech_id: str | None = None
    # When the line was played (the phone's ack, or when the fake gave up waiting for one).
    after: float | None = None
    turn: Turn | None = None
    event: asyncio.Event = field(default_factory=asyncio.Event)


@dataclass(eq=False)
class Call:
    call_id: str
    owner: str  # the stored session id (session key) the call belongs to
    title: str
    initiated_by: str  # "user" | "push"
    state: str  # "ringing" | "live" | "ended"
    mode: str | None = None
    first_text: str | None = None
    outcome: str | None = None
    link: "Link | None" = None
    waiter: Waiter | None = None
    # Turns that arrived before the "[Voice call started]" notice was delivered.
    held: list[Turn] = field(default_factory=list)
    hang_up_reported: bool = False
    ever_linked: bool = False
    answered: asyncio.Event = field(default_factory=asyncio.Event)
    over: asyncio.Event = field(default_factory=asyncio.Event)
    linked: asyncio.Event = field(default_factory=asyncio.Event)
    notice_sent: asyncio.Event = field(default_factory=asyncio.Event)
    # One line at a time, in the order start_call asked for them.
    speech: asyncio.Lock = field(default_factory=asyncio.Lock)
    acks: dict[str, asyncio.Event] = field(default_factory=dict)
    acked: set[str] = field(default_factory=set)
    ring_task: asyncio.Task | None = None
    drop_task: asyncio.Task | None = None


class Link:
    """One /phone connection. Sends are serialized and time-bounded; a link that stops reading is closed (1011)."""

    def __init__(self, plugin: "FakeVoicePlugin", ws: WebSocket, peer: str, call: Call) -> None:
        self.plugin = plugin
        self.ws = ws
        self.peer = peer
        self.call = call
        self.lock = asyncio.Lock()
        self.closed = False
        # finish() telling the phone why the call ended and closing the link; its handler waits for it.
        self.ending: asyncio.Task | None = None

    def dead(self) -> None:
        self.closed = True
        if self.call.link is self:
            self.call.linked.clear()

    async def send(self, payload: bytes | dict[str, Any], timeout: float = SEND_TIMEOUT) -> bool:
        if self.closed:
            return False
        try:
            async with asyncio.timeout(timeout):
                async with self.lock:
                    if isinstance(payload, bytes):
                        await self.ws.send_bytes(payload)
                    else:
                        await self.ws.send_text(json.dumps(payload, ensure_ascii=False))
            return True
        except TimeoutError:
            self.plugin.log(f"call {self.call.call_id[:8]} link {self.peer} stalled: closing it with 1011")
            self.plugin.retire(self, 1011)
            return False
        except Exception:  # noqa: BLE001 - the phone went away
            self.dead()
            return False


class FakeVoicePlugin:
    def __init__(self, fake: Any, args: argparse.Namespace | None = None) -> None:
        self.fake = fake
        # The module that defined the fake (``__main__`` when fake_hermes.py runs as a script): its Runtime + log.
        self.host = sys.modules[type(fake).__module__]
        self.ring_timeout = float(getattr(args, "call_ring_timeout", RING_TIMEOUT))
        self.drop_retention = float(getattr(args, "call_drop_retention", DROP_RETENTION))
        # Test knobs: a push that fails, and a text-to-speech error for every line.
        self.push_failure: str | None = None
        self.tts_error: str | None = None
        self.call: Call | None = None
        self.calls_by_key: dict[str, Call] = {}
        self.ended: OrderedDict[str, Call] = OrderedDict()
        self.devices: dict[str, dict[str, Any]] = {}
        self.pushes: list[dict[str, Any]] = []
        self.ring_watchers: dict[str, list[asyncio.Future]] = {}
        self.tasks: set[asyncio.Task] = set()

    @staticmethod
    def add_arguments(parser: argparse.ArgumentParser) -> None:
        group = parser.add_argument_group("fake hermes_voice plugin")
        group.add_argument("--call-ring-timeout", type=float, default=RING_TIMEOUT,
                           help="seconds an agent call rings before it ends as no_answer")
        group.add_argument("--call-drop-retention", type=float, default=DROP_RETENTION,
                           help="seconds a live call waits for a dropped phone link before it is lost")

    def routes(self) -> list[BaseRoute]:
        return [
            WebSocketRoute(f"{PREFIX}/phone", self.phone_ws),
            Route(f"{PREFIX}/devices", self.register_device, methods=["POST"]),
            Route(f"{PREFIX}/scribe-token", self.scribe_token, methods=["POST"]),
            Route(f"{PREFIX}/status", self.status, methods=["GET"]),
            Route(f"{PREFIX}/debug/ring", self.debug_ring, methods=["POST"]),
            Route(f"{PREFIX}/debug/pushes", self.debug_pushes, methods=["GET"]),
        ]

    # ── helpers ───────────────────────────────────────────────────────────────────────────────────

    def log(self, *parts: Any) -> None:
        self.host.log("voice", *parts)

    def spawn(self, coro: Awaitable[Any]) -> asyncio.Task:
        task = asyncio.ensure_future(coro)
        self.tasks.add(task)
        task.add_done_callback(self._task_done)
        return task

    def _task_done(self, task: asyncio.Task) -> None:
        self.tasks.discard(task)
        if not task.cancelled() and (error := task.exception()) is not None:
            self.log(f"background task failed: {type(error).__name__}: {error}")

    def retire(self, link: Link, code: int) -> None:
        """Close a link in the background: one that stopped reading can't hold anything else up."""
        link.dead()
        self.spawn(close_quietly(link.ws, code))

    async def end_link(self, link: Link, message: dict[str, Any] | None) -> None:
        if message is not None:
            await link.send(message, timeout=NOTICE_TIMEOUT)
        link.dead()
        await close_quietly(link.ws, 1000)

    def resolve_key(self, value: Any) -> str | None:
        """A stored session id (or a runtime id) -> the stored id, when the session exists."""
        value = str(value or "")
        if (rt := self.fake.runtimes.get(value)) is not None:
            return rt.key
        return value if value in self.fake.sessions else None

    def gate(self, request: Request, post: bool) -> Response | None:
        name = f"{request.method} {request.url.path}"
        if not self.fake.authed(request):
            self.log(f"http {name} -> 401")
            return self.fake.unauthorized(request)
        if post and (problem := self.fake.origin_problem(request)):
            self.log(f"http {name} -> 403", problem)
            return JSONResponse({"detail": problem}, status_code=403)
        return None

    @staticmethod
    async def json_body(request: Request) -> dict[str, Any] | None:
        try:
            body = await request.json()
        except ValueError:
            return None
        return body if isinstance(body, dict) else None

    # ── HTTP routes ───────────────────────────────────────────────────────────────────────────────

    async def register_device(self, request: Request) -> Response:
        if (denied := self.gate(request, post=True)) is not None:
            return denied
        body = await self.json_body(request) or {}
        voip, alert = body.get("voip_token"), body.get("alert_token")
        environment, bundle = body.get("environment"), body.get("bundle_id")
        problem = None
        if not isinstance(voip, str) or not VOIP_TOKEN.fullmatch(voip):
            problem = "voip_token must be the device's hex VoIP token"
        elif alert is not None and (not isinstance(alert, str) or not VOIP_TOKEN.fullmatch(alert)):
            problem = "alert_token must be a hex APNs token"
        elif environment not in ("sandbox", "production"):
            problem = "environment must be sandbox or production"
        elif not isinstance(bundle, str) or not bundle.strip():
            problem = "bundle_id is required"
        if problem is not None:
            self.log(f"http POST {PREFIX}/devices -> 422 ({problem})")
            return JSONResponse({"detail": problem}, status_code=422)
        self.devices[voip] = {"alert_token": alert, "environment": environment, "bundle_id": bundle.strip(),
                              "registered_at": time.time()}
        self.log(f"http POST {PREFIX}/devices -> 200 (voip {voip[:8]}…, {environment}, topic "
                 f"{bundle.strip()}.voip{', alert token' if alert else ''}; {len(self.devices)} registered)")
        return JSONResponse({"ok": True})

    async def scribe_token(self, request: Request) -> Response:
        if (denied := self.gate(request, post=True)) is not None:
            return denied
        token = "fake-scribe-" + secrets.token_hex(16)
        self.log(f"http POST {PREFIX}/scribe-token -> 200 (a dummy token: ElevenLabs will refuse it)")
        return JSONResponse({"token": token, "expires_at": iso(time.time() + SCRIBE_TOKEN_TTL)})

    async def status(self, request: Request) -> Response:
        if (denied := self.gate(request, post=False)) is not None:
            return denied
        call = self.call
        active = None if call is None else {"call_id": call.call_id, "session_id": call.owner, "title": call.title,
                                            "state": call.state, "initiated_by": call.initiated_by}
        return JSONResponse({"calls": 0 if call is None else 1, "tts": "fake", "h2": False,
                             "apns_configured": False, "scribe_configured": False, "active_call": active})

    async def debug_pushes(self, request: Request) -> Response:
        if (denied := self.gate(request, post=False)) is not None:
            return denied
        return JSONResponse({"pushes": self.pushes})

    async def debug_ring(self, request: Request) -> Response:
        """Have the session's fake agent call start_call, as the prompt "call me <mode>: <text>" does."""
        if (denied := self.gate(request, post=True)) is not None:
            return denied
        body = await self.json_body(request)
        mode = (body or {}).get("mode") or "async"
        if body is None or mode not in MODES:
            return JSONResponse({"detail": "body must be {session_id, mode: sync|async, text?}"}, status_code=422)
        key = self.resolve_key(body.get("session_id"))
        if key is None:
            self.log(f"http POST {PREFIX}/debug/ring -> 404")
            return JSONResponse({"detail": "Session not found"}, status_code=404)
        text = str(body.get("text") or "").strip()
        future = asyncio.get_running_loop().create_future()
        self.ring_watchers.setdefault(key, []).append(future)
        delivered = self.inject(key, f"call me {mode}" + (f": {text}" if text else ""))
        try:
            result = await asyncio.wait_for(asyncio.shield(future), 5)
        except TimeoutError:
            result = {"ok": False, "detail": f"the prompt was {delivered}, but the fake agent did not call start_call "
                                             "within 5 s (another turn may still be running)"}
        finally:
            watchers = self.ring_watchers.get(key, [])
            if future in watchers:
                watchers.remove(future)
        self.log(f"http POST {PREFIX}/debug/ring -> 200 {self.host.short(result, 200)}")
        return JSONResponse(result)

    def notify_ring(self, key: str, result: dict[str, Any]) -> None:
        watchers = self.ring_watchers.get(key) or []
        while watchers:
            future = watchers.pop(0)
            if not future.done():
                future.set_result(result)
                return

    # ── the phone link ────────────────────────────────────────────────────────────────────────────

    async def phone_ws(self, ws: WebSocket) -> None:
        peer = f"{ws.client.host}:{ws.client.port}" if ws.client else "?"
        # Accept first, so a bad ticket reaches the phone as close code 4401 rather than a bare HTTP 403.
        await ws.accept()
        expiry = self.fake.tickets.pop(ws.query_params.get("ticket", ""), None)
        if expiry is None or expiry < time.time():
            self.log(f"ws /phone peer={peer} rejected: ticket invalid -> close 4401")
            await close_quietly(ws, 4401)
            return
        try:
            hello = await asyncio.wait_for(next_message(ws), HELLO_TIMEOUT)
        except (TimeoutError, *_SOCKET_GONE):
            hello = None
        call_id = normalize_call_id((hello or {}).get("call_id"))
        initiated_by = (hello or {}).get("initiated_by")
        if (hello or {}).get("type") != "hello" or call_id is None or initiated_by not in ("user", "push"):
            self.log(f"ws /phone peer={peer} bad hello {self.host.short(hello)} -> close 4400")
            await close_quietly(ws, 4400)
            return
        call = self.call if self.call is not None and self.call.call_id == call_id else None
        new_call = False
        if call is None:
            if (old := self.ended.get(call_id)) is not None:
                message = ({"type": "ended", "outcome": old.outcome} if old.answered.is_set()
                           else {"type": "cancel", "reason": old.outcome})
                self.log(f"ws /phone call {call_id[:8]} is over ({old.outcome}): {message['type']} + close 1000")
                await self.say_and_close(ws, message)
                return
            if initiated_by == "push":
                self.log(f"ws /phone call {call_id[:8]} (push) is not ringing here: cancel + close 1000")
                await self.say_and_close(ws, {"type": "cancel", "reason": "unknown_call"})
                return
            key = self.resolve_key(hello.get("session_id"))
            if key is None:
                self.log(f"ws /phone call {call_id[:8]}: user call without a known session_id -> close 4400")
                await close_quietly(ws, 4400)
                return
            if self.call is not None:
                self.log(f"ws /phone call {call_id[:8]} for {key} refused: call {self.call.call_id[:8]} of "
                         f"{self.call.owner} holds the slot -> close 4429")
                await close_quietly(ws, 4429)
                return
            title = str(hello.get("title") or self.fake.sessions[key].title or "Hermes")[:200]
            call = self.claim(Call(call_id, key, title, "user", "live"))
            call.answered.set()
            new_call = True
        link = Link(self, ws, peer, call)
        previous, call.link = call.link, link
        again, call.ever_linked = call.ever_linked, True
        call.linked.set()
        if call.drop_task is not None:
            call.drop_task.cancel()
            call.drop_task = None
        if previous is not None:
            self.retire(previous, 4409)
        state = "ringing" if call.state == "ringing" else "live"
        self.log(f"ws /phone call {call_id[:8]} {'reconnected' if again else 'connected'} "
                 f"peer={peer} initiated_by={initiated_by} state={state} session={call.owner}"
                 + (" (replaced the previous link: 4409)" if previous else ""))
        await link.send({"type": "ready", "call_id": call_id, "state": state})
        if new_call:
            self.announce(call)
        hung_up = False
        try:
            while not hung_up:
                message = await next_message(ws)
                if message is not None:
                    hung_up = self.on_message(call, link, message)
            # bye / declined: the socket closes only once finish() told the phone (a handler that returns
            # first leaves uvicorn to drop it with 1006).
            if link.ending is not None:
                await link.ending
            else:
                await close_quietly(ws, 1000)
        except _SOCKET_GONE:
            pass
        finally:
            if not hung_up:
                link.dead()  # after a bye, finish() still sends ended {outcome} on it, then closes it
            if call.link is link:
                call.link = None
                call.linked.clear()
                if not call.over.is_set():
                    self.log(f"call {call_id[:8]} link dropped (state {call.state})")
                    if call.state == "live":
                        call.drop_task = self.spawn(self.drop_later(call))

    async def say_and_close(self, ws: WebSocket, message: dict[str, Any]) -> None:
        try:
            await asyncio.wait_for(ws.send_text(json.dumps(message)), NOTICE_TIMEOUT)
        except Exception:  # noqa: BLE001
            pass
        await close_quietly(ws, 1000)

    def on_message(self, call: Call, link: Link, message: dict[str, Any]) -> bool:
        """Handle one phone frame; True once the phone said bye."""
        kind = message.get("type")
        if kind == "ping":
            self.spawn(link.send({"type": "pong"}))
        elif kind == "played":
            speech_id = str(message.get("id"))
            if (event := call.acks.get(speech_id)) is not None:
                call.acked.add(speech_id)
                event.set()
                if (waiter := call.waiter) is not None and waiter.speech_id == speech_id and waiter.after is None:
                    waiter.after = time.time()
        elif kind == "ringing":
            self.log(f"call {call.call_id[:8]} is ringing on the phone")
        elif kind == "answered":
            if call.state == "ringing":
                call.state = "live"
                call.answered.set()
                if call.ring_task is not None:
                    call.ring_task.cancel()
                self.log(f"call {call.call_id[:8]} answered")
        elif kind == "declined":
            self.finish(call, "declined" if call.state == "ringing" else "ended_by_user")
            return True
        elif kind == "user_turn":
            self.on_turn(call, message)
        elif kind == "bye":
            reason = message.get("reason")
            self.log(f"call {call.call_id[:8]} bye" + (f" ({self.host.short(reason, 80)})" if reason else ""))
            # As the real plugin: the phone's own ring timeout says no_answer; an error ends a live call as lost.
            if call.state == "ringing":
                self.finish(call, "no_answer" if reason == "no_answer" else "declined")
            else:
                self.finish(call, "lost" if reason == "error" else "ended_by_user")
            return True
        else:
            self.log(f"call {call.call_id[:8]} ignored frame {self.host.short(message, 120)}")
        return False

    def on_turn(self, call: Call, message: dict[str, Any]) -> None:
        turn = Turn.parse(message)
        if isinstance(turn, str):
            self.log(f"call {call.call_id[:8]} malformed user_turn ({turn}): {self.host.short(message, 120)}")
            return
        if turn.call_id != call.call_id:
            self.log(f"call {call.call_id[:8]} user_turn for another call_id {turn.call_id[:8]} ignored")
            return
        if call.state != "live":
            self.log(f"call {call.call_id[:8]} user_turn while {call.state} ignored")
            return
        if not call.notice_sent.is_set():
            call.held.append(turn)
            return
        self.route(call, turn)

    def route(self, call: Call, turn: Turn) -> None:
        """A waiting sync start_call takes the first turn that began after its line was played; every other turn
        is force-injected into the call's session."""
        waiter = call.waiter
        label = f"call {call.call_id[:8]} turn {turn.kind} ({turn.provider})"
        if turn.kind == "hang_up" and turn.text.strip():
            call.hang_up_reported = True
        if (waiter is not None and not waiter.event.is_set() and waiter.after is not None
                and turn.started >= waiter.after - PLAYED_SLACK):
            waiter.turn = turn
            waiter.event.set()
            self.log(f"{label} -> the waiting sync start_call: {self.host.short(turn.text, 80)}")
            return
        text = turn.injected()
        if text is None:
            self.log(f"{label} was empty: nothing to inject")
            return
        self.inject(call.owner, text)

    # ── the call slot ─────────────────────────────────────────────────────────────────────────────

    def claim(self, call: Call) -> Call:
        self.call = call
        self.calls_by_key[call.owner] = call
        return call

    def announce(self, call: Call) -> None:
        """A user-initiated call: tell its session, then let the turns through (held until now)."""
        self.inject(call.owner, (
            f"{STARTED} The user is calling you from the HermesVoice app (call {call.call_id}). Your text replies "
            "are not spoken: talk to them with start_call (mode \"sync\" waits for their answer) and hang up with "
            "end_call. What they say arrives as messages starting with \"[Voice]\"."))
        call.notice_sent.set()
        held, call.held = call.held, []
        for turn in held:
            self.route(call, turn)

    def ring(self, key: str, title: str, mode: str, text: str, waiter: Waiter | None) -> tuple[Call, dict]:
        call = self.claim(Call(uuid.uuid4().hex, key, title, "push", "ringing", mode=mode, first_text=text,
                               waiter=waiter))
        call.notice_sent.set()  # an agent call has no "[Voice call started]" notice
        push = {"call_id": call.call_id, "session_id": key, "profile": "default", "mode": mode, "title": title}
        self.pushes.append(push)
        where = (f"{len(self.devices)} registered device(s)" if self.devices
                 else "no device registered: the Simulator can't get VoIP pushes")
        self.log(f"push (fake, not sent; {where}) {json.dumps(push, ensure_ascii=False)}")
        if self.push_failure:
            # The tool result says so; no notice.
            self.finish(call, "push_failed", notify=False)
        else:
            call.ring_task = self.spawn(self.ring_later(call))
        return call, push

    async def ring_later(self, call: Call) -> None:
        await first_of(call.answered, call.over, timeout=self.ring_timeout)
        if call.state == "ringing" and not call.over.is_set():
            # Nobody answered a phone that rang; or no phone ever opened the link (the push never got there).
            outcome = "no_answer" if call.ever_linked else "unreachable"
            self.log(f"call {call.call_id[:8]} rang {self.ring_timeout:g}s without an answer: {outcome}")
            self.finish(call, outcome)

    async def drop_later(self, call: Call) -> None:
        await asyncio.sleep(self.drop_retention)
        if call.link is None and not call.over.is_set():
            self.log(f"call {call.call_id[:8]} lost: no reconnect within {self.drop_retention:g}s")
            self.finish(call, "lost")

    def finish(self, call: Call, outcome: str, notify: bool = True) -> None:
        """End the call: tell the phone (cancel while ringing, ended once live), wake its waiters, free the slot and,
        when no sync start_call takes the outcome, inject the notice."""
        if call.over.is_set():
            return
        was = call.state
        call.state, call.outcome = "ended", outcome
        call.over.set()
        if self.call is call:
            self.call = None
        self.ended[call.call_id] = call
        while len(self.ended) > ENDED_MEMORY:
            self.ended.popitem(last=False)
        current = asyncio.current_task()
        for task in (call.ring_task, call.drop_task):
            if task is not None and task is not current:
                task.cancel()
        if (link := call.link) is not None and not link.closed:
            message = None if outcome == "declined" else (
                {"type": "cancel", "reason": outcome} if was == "ringing" else {"type": "ended", "outcome": outcome})
            link.ending = self.spawn(self.end_link(link, message))
        self.log(f"call {call.call_id[:8]} ended: {outcome}")
        waiting = call.waiter is not None and not call.waiter.event.is_set()
        if notify and not waiting and (notice := self.notice(call, outcome)) is not None:
            self.inject(call.owner, notice)

    def notice(self, call: Call, outcome: str) -> str | None:
        """inject.py outcome_notice: the notice for a call that ended with nobody waiting on it."""
        if outcome in ("no_answer", "declined"):
            why = "they declined it" if outcome == "declined" else "they didn't pick up"
            return f"{NOT_ANSWERED} The user didn't take the call ({why}). Reply in text."
        if outcome == "push_failed":
            return f"{NOT_DELIVERED}: the phone couldn't be rung ({self.push_failure or 'push failed'})] Reply in text."
        if outcome == "unreachable":
            return f"{NOT_DELIVERED}: the phone never answered the ring] Reply in text."
        if outcome == "lost":
            return (f"{LOST} the phone's connection was lost and didn't come back] Reply in text; call again with "
                    "start_call only if it's worth it.")
        if outcome == "ended_by_user" and not call.hang_up_reported:
            return f"{ENDED_BY_USER} Reply in text from now on; don't call back unless they ask."
        return None

    # ── force-inject (inject.py: redirect -> steer -> prompt.submit) ─────────────────────────────────

    def inject(self, key: str, text: str) -> str:
        """Into a running session the text goes after its turn (Hermes redirects or steers it into the live turn;
        the fake queues it, merging like Hermes' text queue); an idle session starts a new turn with it."""
        stored = self.fake.sessions.get(key)
        if stored is None:
            self.log(f"inject into unknown session {key} dropped: {self.host.short(text, 80)}")
            return "rejected"
        rt = self.fake.find_runtime(key)
        if rt is None:
            # The plugin resumes a session nobody has open (session.resume of the stored id).
            rt = self.host.Runtime(sid=uuid.uuid4().hex[:8], key=key)
            self.fake.runtimes[rt.sid] = rt
            self.log(f"resumed {key} as runtime {rt.sid} to inject (no client attached)")
        if rt.running:
            if rt.queued is None:
                rt.queued = text
                rt.queued_row = self.fake.add_row(stored, "user", text)
            else:
                rt.queued = f"{rt.queued}\n\n{text}"
                if rt.queued_row is not None:
                    rt.queued_row["content"] = rt.queued
            status = "queued"
        else:
            self.fake.add_row(stored, "user", text)
            rt.running = True
            rt.turn_started_at = time.time()
            rt.loop_task = asyncio.ensure_future(self.fake.turn_loop(rt, text))
            status = "streaming"
        self.log(f"inject -> {key} ({status}): {self.host.short(text, 100)}")
        return status

    # ── speaking ──────────────────────────────────────────────────────────────────────────────────

    async def wait_link(self, call: Call) -> Link | None:
        while not call.over.is_set():
            if call.link is not None and not call.link.closed:
                return call.link
            await first_of(call.linked, call.over)
        return None

    async def say(self, call: Call, text: str, waiter: Waiter | None = None) -> tuple[str, str | None]:
        """Speak one line once the call is answered: ("played" | "unconfirmed" | "tts_failed" | "over", detail).
        A link that drops mid-line gets the whole line again on the phone's next link."""
        async with call.speech:
            await first_of(call.answered, call.over)
            if call.over.is_set():
                return "over", call.outcome
            speech_id = uuid.uuid4().hex[:12]
            if waiter is not None:
                waiter.speech_id = speech_id
            played = call.acks[speech_id] = asyncio.Event()
            started: Link | None = None
            try:
                while True:
                    link = await self.wait_link(call)
                    if link is None:
                        return "over", call.outcome
                    started = link
                    sent, error = await self.stream(link, speech_id, text)
                    if error is not None:
                        self.log(f"call {call.call_id[:8]} line {speech_id} failed: {error}")
                        return "tts_failed", error
                    if sent is not None:
                        break
                    self.log(f"call {call.call_id[:8]} line {speech_id} cut off by the link: waiting for a reconnect")
                seconds = sent / 2 / SAMPLE_RATE
                self.log(f"call {call.call_id[:8]} spoke line {speech_id} ({seconds:.1f}s): {self.host.short(text, 80)}")
                await first_of(played, call.over, timeout=seconds + PLAYBACK_MARGIN)
                if speech_id in call.acked:
                    status = "played"
                elif call.over.is_set():
                    return "over", call.outcome
                else:
                    status = "unconfirmed"
                    self.log(f"call {call.call_id[:8]} line {speech_id}: the phone never confirmed it played")
                if waiter is not None and waiter.after is None:
                    waiter.after = time.time()
                return status, None
            except asyncio.CancelledError:
                # The turn was interrupted: the phone drops the line's audio and listens again.
                if started is not None:
                    self.spawn(started.send({"type": "speech_end", "id": speech_id, "cancelled": True},
                                            timeout=NOTICE_TIMEOUT))
                raise
            finally:
                call.acks.pop(speech_id, None)
                call.acked.discard(speech_id)

    async def stream(self, link: Link, speech_id: str, text: str) -> tuple[int | None, str | None]:
        """(bytes sent, None) once speech_end went out; (None, None) when the link failed; (None, error) on a TTS
        error, which the phone gets as speech_end {error}."""
        if not await link.send({"type": "speech_start", "id": speech_id, "text": text, "sample_rate": SAMPLE_RATE,
                                "format": "pcm_s16le"}):
            return None, None
        if self.tts_error:
            await link.send({"type": "speech_end", "id": speech_id, "error": self.tts_error}, timeout=NOTICE_TIMEOUT)
            return None, self.tts_error
        sent = 0
        for chunk in fake_speech(text):
            if not await link.send(chunk):
                return None, None
            sent += len(chunk)
            await asyncio.sleep(0)
        if not await link.send({"type": "speech_end", "id": speech_id}):
            return None, None
        return sent, None

    async def say_async(self, call: Call, text: str) -> None:
        status, detail = await self.say(call, text)
        if status == "tts_failed":
            self.inject(call.owner, f"{NOT_DELIVERED}: {' '.join(f'text-to-speech failed ({detail})'.split())[:240]}]")

    # ── the tools ─────────────────────────────────────────────────────────────────────────────────

    async def start_call(self, stored: Any, text: str, mode: str) -> dict[str, Any]:
        """start_call(text, mode): ring (or reuse this session's call), speak once answered. sync waits for the
        user's reply: {said, ending, outcome, call_id}; async returns {call_id, status} at once."""
        key = stored.key
        text = text.strip()
        if mode not in MODES or not text:
            return {"error": "start_call needs text and mode sync or async"}
        if stored.source in REFUSED_SOURCES:
            return self.refusal(key, mode, "not_allowed", f"Voice calls are off for {stored.source} sessions.")
        call = self.call
        if call is not None and call.owner != key:
            return self.refusal(key, mode, "busy", f"The user is on a call with “{call.title}”, so nothing "
                                                   "rang. Try again after that call.")
        waiter = Waiter() if mode == "sync" else None
        push = None
        if call is None:
            call, push = self.ring(key, stored.title or "Hermes", mode, text, waiter)
            status = call.outcome if call.over.is_set() else "ringing"
        else:
            if waiter is not None:
                if call.waiter is not None and not call.waiter.event.is_set():
                    return self.refusal(key, mode, "busy", "Another start_call is already waiting for the user.")
                call.waiter = waiter
            status = "ringing" if call.state == "ringing" else "speaking"
        self.notify_ring(key, {"ok": not call.over.is_set(), "call_id": call.call_id, "mode": mode, "status": status,
                               "push": push})
        if mode == "async":
            if not call.over.is_set():
                self.spawn(self.say_async(call, text))
            return {"call_id": call.call_id, "status": status, "note": ASYNC_NOTES.get(status, "") + ASYNC_HINT}
        return await self.converse(call, text, waiter)

    def refusal(self, key: str, mode: str, outcome: str, note: str) -> dict[str, Any]:
        """The plugin's refusal shapes (hub._refusal): sync {said, ending, outcome, call_id, note}, async
        {call_id, status, note}."""
        self.log(f"start_call from {key} refused: {outcome} ({note})")
        self.notify_ring(key, {"ok": False, "outcome": outcome, "note": note})
        if mode == "sync":
            return {"said": "", "ending": None, "outcome": outcome, "call_id": None, "note": note}
        return {"call_id": None, "status": outcome, "note": note}

    async def converse(self, call: Call, text: str, waiter: Waiter) -> dict[str, Any]:
        """A sync start_call's result as the plugin returns it (hub._sync): `ending` is the turn's kind, and a call
        that ended without a reply carries a `note` on its outcome."""
        def result(outcome: str | None, note: str = "") -> dict[str, Any]:
            outcome = outcome or "ended_by_user"
            note = note or OUTCOME_NOTES.get(outcome, "")
            return {"said": "", "ending": None, "outcome": outcome, "call_id": call.call_id,
                    **({"note": note} if note else {})}

        try:
            status, detail = await self.say(call, text, waiter)
            if status == "over":
                return result(call.outcome)
            if status == "tts_failed":
                return result("tts_failed", f"Could not speak: {detail}")
            await first_of(waiter.event, call.over)
            if (turn := waiter.turn) is not None:
                return {"said": " ".join(turn.text.split()), "ending": turn.kind,
                        "outcome": "ended_by_user" if turn.kind == "hang_up" else "answered", "call_id": call.call_id}
            return result(call.outcome)
        finally:
            if call.waiter is waiter:
                call.waiter = None

    async def end_call(self, stored: Any, text: str | None) -> dict[str, Any]:
        """end_call's result as the plugin returns it: {call_id, outcome, note}."""
        call = self.call
        if call is None or call.owner != stored.key:
            return {"call_id": None, "outcome": None, "note": "This conversation has no voice call running."}
        note = ""
        if text and call.state == "live":
            status, _ = await self.say(call, text)
            note = " Spoken to the user." if status == "played" else ""
        self.finish(call, "ended_by_agent")
        return {"call_id": call.call_id, "outcome": "ended_by_agent", "note": f"Hung up.{note}"}

    # ── the fake agent (fake_hermes.py run_turn) ─────────────────────────────────────────────────────

    async def handle(self, rt: Any, stored: Any, segment: str) -> str | None:
        """The reply to one prompt segment when the plugin's texts or triggers are in it, else None (the fake's own
        agent handles it)."""
        blocks = BLOCKS.split(segment)
        if not any(self.claims(stored, block) for block in blocks):
            return None
        replies = []
        for block in blocks:
            if self.claims(stored, block):
                replies.append(await self.respond(rt, stored, block))
            else:
                replies.append(await self.fake.reply_to(rt, stored, block))
        return "\n\n".join(replies)

    def claims(self, stored: Any, block: str) -> bool:
        if block.startswith((NOT_ANSWERED, NOT_DELIVERED, ENDED_BY_USER, LOST)):
            return True
        if block.startswith(STARTED):
            match = NOTICE_CALL_ID.search(block)
            call_id = match.group(1).lower() if match else ""
            return (self.call is not None and self.call.call_id == call_id) or call_id in self.ended
        if VOICE_TURN.match(block):
            return stored.key in self.calls_by_key
        if CALL_ME.search(block):
            return True
        return bool(HANG_UP.search(block)) and self.call is not None and self.call.owner == stored.key

    def live_call(self, stored: Any) -> Call | None:
        call = self.call
        return call if call is not None and call.owner == stored.key and call.state == "live" else None

    async def respond(self, rt: Any, stored: Any, block: str) -> str:
        if block.startswith(NOT_ANSWERED):
            return "The call was not answered."
        if block.startswith(NOT_DELIVERED):
            return "That line was not delivered."
        if block.startswith(ENDED_BY_USER):
            return "Call ended."
        if block.startswith(LOST):
            return "The call was lost."
        if block.startswith(STARTED):
            if self.live_call(stored) is None:
                return "That call is already over."
            await self.tool(rt, stored, "start_call", {"text": HELLO_TEXT, "mode": "async"})
            return "Call connected."
        if (turn := VOICE_TURN.match(block)) is not None:
            marker, said = turn.group(1), turn.group(2).strip()
            for hint in (REPLY_HINT, HUNG_UP_HINT):
                said = said.removesuffix(hint).strip()
            note = f" ({marker})" if marker else ""
            if marker == "hung up":
                return f"You said before hanging up: {said}"
            spoken = f"You said: {said}" if said else "Sorry, I didn't catch that."
            if self.live_call(stored) is None:
                return f"{spoken}{note} (the call is over, so text only)"
            await self.tool(rt, stored, "start_call", {"text": spoken, "mode": "async"})
            return f"You said{note}: {said}" if said else f"Nothing came through{note}."
        if (match := CALL_ME.search(block)) is not None:
            mode = match.group(1).lower()
            text = match.group(2).strip() or (SYNC_LINE if mode == "sync" else ASYNC_LINE)
            result = await self.tool(rt, stored, "start_call", {"text": text, "mode": mode})
            return self.describe(mode, result)
        result = await self.tool(rt, stored, "end_call", {"text": GOODBYE})
        return "Hung up." if result.get("outcome") == "ended_by_agent" else "There is no call to hang up."

    @staticmethod
    def describe(mode: str, result: dict[str, Any]) -> str:
        if result.get("call_id") is None and (note := result.get("note")):
            return f"No call: {note}"  # refused (busy, not_allowed)
        if mode == "async":
            return {"ringing": "Ringing your phone.", "speaking": "Said it on the call."}.get(
                result.get("status"), f"The call failed: {result.get('status')}.")
        if result.get("said"):
            kind = result.get("ending")
            return f"You said: {result['said']}" + ("" if kind == "end_of_speech" else f" ({kind})")
        return f"The call ended without a reply ({result.get('outcome')})."

    async def tool(self, rt: Any, stored: Any, name: str, args: dict[str, Any]) -> dict[str, Any]:
        """One tool call in the turn (tool.start, the work, tool.complete, stored rows) with a JSON result."""
        out: dict[str, Any] = {}

        async def work() -> tuple[str, bool]:
            nonlocal out
            if name == "start_call":
                out = await self.start_call(stored, args["text"], args["mode"])
            else:
                out = await self.end_call(stored, args.get("text"))
            self.log(f"{name} from {stored.key} -> {self.host.short(out, 160)}")
            return json.dumps(out, ensure_ascii=False), "error" not in out

        await self.fake.run_tool(rt, stored, name, args, str(args.get("text") or name), work)
        return out
