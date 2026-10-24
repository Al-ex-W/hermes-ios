"""Hermes Voice: an MCP server whose `speak` tool talks out loud on the HermesVoice iPhone app.

One process serves two things on the same port:

- ``/mcp``: a streamable-HTTP MCP endpoint Hermes connects to (tool ``speak``).
- ``/phone``: a WebSocket the iPhone app holds open for the length of a CallKit call.

``speak`` turns text into speech with ElevenLabs on this host and streams the raw
PCM down the phone's socket. Nothing else Hermes writes is ever voiced. Every route
except ``/health`` needs the shared token in ``Authorization: Bearer <token>``.

Phone protocol (JSON text frames plus binary PCM):

- phone ``hello {call_id, session_id?, title}`` -> server ``ready {call_id}``
- server ``speech_start {id, text, sample_rate, format}``, PCM frames, then ``speech_end {id}``,
  ``speech_end {id, cancelled: true}`` or ``speech_end {id, error}``; the phone answers a normal
  end with ``played {id}`` once the audio has been heard
- phone ``ping`` -> server ``pong``; phone ``bye`` on hang-up
- close codes: 4401 bad token, 4400 bad hello, 4409 replaced by a newer connection for the call,
  1011 stopped taking frames (the phone reconnects)
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import re
import struct
import time
import uuid
from contextlib import aclosing
from dataclasses import dataclass, field
from typing import Annotated, Any, AsyncIterator, Protocol

import anyio
import httpx
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import Field
from starlette.datastructures import Headers
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import WebSocketRoute
from starlette.types import ASGIApp, Receive, Scope, Send
from starlette.websockets import WebSocket, WebSocketDisconnect

from .config import Settings

logger = logging.getLogger("hermes_voice")

SAMPLE_RATE = 24_000
# Time allowed beyond the audio's own length for the phone to confirm it played.
PLAYBACK_MARGIN = 15.0
# Upper bound on a whole `speak` call, under Hermes' 300 s MCP tool timeout.
PLAYBACK_WAIT_LIMIT = 270.0
# How long `speak` waits for a dropped phone connection to come back before giving up on this utterance.
RECONNECT_GRACE = 6.0
# How long a dropped call keeps its pending acks for a reconnect; past the phone's whole retry schedule.
DROP_RETENTION = 60.0
# How long ended and lost call_ids are remembered, so `speak` can say why nothing was spoken.
ENDED_MEMORY = 3600.0
HELLO_TIMEOUT = 15.0
# Bound on the send that tells the phone a failed or cancelled utterance is over; past it the connection is stalled.
NOTICE_TIMEOUT = 2.0
# A connection that takes no frame for this long has stopped reading (a half-open path): it is dropped.
SEND_TIMEOUT = 5.0

CALL_ENDED = "The call ended while speaking; the user may not have heard all of it. Reply in text."
CALL_DROPPED = (
    "The phone lost its connection while speaking, so the user may not have heard all of it. Reply in text; "
    "the phone reconnects by itself, so you can use speak again on the next [Voice] message."
)

CALL_ID = re.compile(r"[0-9a-f]{32}")
VOICE_ID = re.compile(r"[A-Za-z0-9]{1,64}")

# What a send on a socket the phone has dropped (or the server has closed) raises.
_SOCKET_GONE = (WebSocketDisconnect, RuntimeError, OSError)


def normalize_call_id(value: Any) -> str | None:
    """The call_id as the app generates it (32 lowercase hex characters), else None."""
    call_id = str(value or "").strip().lower()
    return call_id if CALL_ID.fullmatch(call_id) else None


@dataclass(eq=False)
class PhoneCall:
    """One phone connection for a call. A reconnect gets a new PhoneCall that takes over the lock and pending acks."""

    call_id: str
    socket: WebSocket
    session_id: str | None = None
    title: str | None = None
    # One utterance at a time per call, so two `speak` calls never interleave audio.
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    # Utterances waiting for the phone's `played`, and the ones it has acknowledged.
    played: dict[str, asyncio.Event] = field(default_factory=dict)
    acked: set[str] = field(default_factory=set)
    # Set once this connection is over: bye, disconnect, replaced by a newer one, or stalled.
    ended: asyncio.Event = field(default_factory=asyncio.Event)

    def ack(self, speech_id: str) -> None:
        if (event := self.played.get(speech_id)) is not None:
            self.acked.add(speech_id)
            event.set()


class CallHub:
    """Phone connections by call_id, plus calls that dropped (and may reconnect), were lost, or were hung up.

    Only a hang-up (bye) is final. A drop is kept for DROP_RETENTION with its pending acks, and even a call lost
    after that comes back when the phone says hello with its call_id again.
    """

    def __init__(self) -> None:
        self.calls: dict[str, PhoneCall] = {}
        self.dropped: dict[str, PhoneCall] = {}
        # When each call was hung up, or lost (dropped and not back within DROP_RETENTION).
        self.ended: dict[str, float] = {}
        self.lost: dict[str, float] = {}
        self.reconnect_grace = RECONNECT_GRACE
        self.drop_retention = DROP_RETENTION
        # Background closes of replaced or stalled connections.
        self.closing: set[asyncio.Task[None]] = set()

    def connect(
        self, call_id: str, socket: WebSocket, session_id: str | None, title: str | None
    ) -> tuple[PhoneCall, PhoneCall | None]:
        """Register a connection. Also returns the call's earlier connection if it was still live, to be closed."""
        call = PhoneCall(call_id, socket, session_id, title)
        live = self.calls.get(call_id)
        previous = live or self.dropped.pop(call_id, None)
        self.ended.pop(call_id, None)
        self.lost.pop(call_id, None)
        if previous is not None:
            # An in-flight `speak` keeps its lock, and an ack on the new socket resolves it.
            call.lock, call.played, call.acked = previous.lock, previous.played, previous.acked
            previous.ended.set()
        self.calls[call_id] = call
        return call, live

    def disconnect(self, call: PhoneCall, hung_up: bool) -> None:
        """A connection closed. A hang-up ends the call; a drop keeps it for DROP_RETENTION to come back."""
        call.ended.set()
        if self.calls.get(call.call_id) is not call:
            return  # replaced by a newer connection, which now owns the pending acks
        del self.calls[call.call_id]
        if hung_up:
            self._finish(call, self.ended)
            logger.info("call %s ended", call.call_id[:8])
        else:
            logger.info("call %s dropped; keeping it %.0fs for a reconnect", call.call_id[:8], self.drop_retention)
            self.dropped[call.call_id] = call
            asyncio.get_running_loop().call_later(self.drop_retention, self._expire, call)

    def stall(self, call: PhoneCall) -> None:
        """A send on this connection got stuck (the phone stopped reading): stop using it and close it, so the
        phone reconnects. Its handler disconnects it as a drop once the socket is really gone."""
        if not call.ended.is_set():
            logger.info("call %s stalled; closing its connection", call.call_id[:8])
            call.ended.set()
            self.retire(call.socket, 1011)

    def retire(self, socket: WebSocket, code: int) -> None:
        """Close a connection in the background: one that stopped reading can't hold anything else up."""
        task = asyncio.ensure_future(_close_quietly(socket, code))
        self.closing.add(task)
        task.add_done_callback(self.closing.discard)

    def _expire(self, call: PhoneCall) -> None:
        if self.dropped.get(call.call_id) is call:
            del self.dropped[call.call_id]
            self._finish(call, self.lost)
            logger.info("call %s lost: no reconnect", call.call_id[:8])

    def _finish(self, call: PhoneCall, record: dict[str, float]) -> None:
        """Remember the call_id in `record` and wake every `speak` still waiting on the call."""
        now = time.monotonic()
        for memory in (self.ended, self.lost):
            for cid in [cid for cid, at in memory.items() if now - at >= ENDED_MEMORY]:
                del memory[cid]
        record[call.call_id] = now
        for event in call.played.values():
            event.set()

    def is_over(self, call_id: str) -> bool:
        return call_id not in self.calls and call_id not in self.dropped

    async def line(self, call_id: str, avoid: WebSocket | None = None) -> PhoneCall | None:
        """The call's live connection, waiting up to RECONNECT_GRACE for one if it dropped (or if `avoid` failed)."""
        deadline = time.monotonic() + self.reconnect_grace
        while True:
            call = self.calls.get(call_id)
            if call is not None and call.socket is not avoid and not call.ended.is_set():
                return call
            if self.is_over(call_id) or time.monotonic() >= deadline:
                return None
            await asyncio.sleep(0.05)

    def cut_off(self, call_id: str) -> str:
        """The result for an utterance the call went away during."""
        return CALL_ENDED if call_id in self.ended else CALL_DROPPED

    def problem(self, call_id: str) -> str:
        """Why nothing can be spoken on call_id."""
        if call_id in self.ended:
            return (
                f"Voice call {call_id} has ended, so nothing was spoken. "
                "Reply in text and do not call speak for this call again."
            )
        if call_id in self.dropped or call_id in self.lost or call_id in self.calls:
            return (
                f"The phone on voice call {call_id} is not connected right now (it may be reconnecting), so nothing "
                "was spoken. Reply in text; you can use speak again on the next [Voice] message."
            )
        return (
            f"No voice call {call_id} is connected (it ended or belongs to another conversation), "
            "so nothing was spoken. Reply in text."
        )


class TextToSpeech(Protocol):
    def stream(self, text: str, voice_id: str | None) -> AsyncIterator[bytes]: ...


class ElevenLabs:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def stream(self, text: str, voice_id: str | None) -> AsyncIterator[bytes]:
        """Yield 16-bit little-endian mono PCM at SAMPLE_RATE."""
        if self.settings.fake_tts:
            async for chunk in _fake_speech(text):
                yield chunk
            return
        if not self.settings.elevenlabs_api_key:
            raise RuntimeError("ELEVENLABS_API_KEY is not set on the Hermes host.")
        voice = voice_id or self.settings.voice_id
        # The voice id goes into the URL path, so only plain ids may reach it.
        if not VOICE_ID.fullmatch(voice):
            raise ValueError(f"Invalid voice_id {voice[:80]!r}.")
        url = f"{self.settings.elevenlabs_base_url}/v1/text-to-speech/{voice}/stream"
        body = {"text": text, "model_id": self.settings.model_id}
        headers = {"xi-api-key": self.settings.elevenlabs_api_key, "Accept": "audio/pcm"}
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0, read=60.0)) as client:
            async with client.stream(
                "POST", url, params={"output_format": f"pcm_{SAMPLE_RATE}"}, json=body, headers=headers
            ) as response:
                if response.status_code >= 400:
                    raise RuntimeError(_elevenlabs_error(response.status_code, await response.aread()))
                async for chunk in response.aiter_bytes():
                    if chunk:
                        yield chunk


def _elevenlabs_error(status: int, body: bytes) -> str:
    """A short error for the agent; the response body itself only goes to the log."""
    logger.warning("ElevenLabs returned %s: %s", status, body[:500].decode("utf-8", "replace"))
    try:
        reason = json.loads(body)["detail"]["status"]
    except (ValueError, KeyError, TypeError):
        reason = None
    if isinstance(reason, str) and re.fullmatch(r"[a-z_]{1,64}", reason):
        return f"ElevenLabs returned HTTP {status} ({reason})."
    return f"ElevenLabs returned HTTP {status}."


async def _fake_speech(text: str) -> AsyncIterator[bytes]:
    """A short tone per word, for testing without an ElevenLabs key (HERMES_VOICE_FAKE_TTS=1)."""
    for index, _ in enumerate(text.split()[:40]):
        freq = 440 + 60 * (index % 5)
        samples = int(SAMPLE_RATE * 0.18)
        frames = b"".join(
            struct.pack("<h", int(6000 * math.sin(2 * math.pi * freq * n / SAMPLE_RATE))) for n in range(samples)
        )
        yield frames + b"\x00\x00" * int(SAMPLE_RATE * 0.05)
        await asyncio.sleep(0)


INSTRUCTIONS = """\
Hermes Voice lets you talk out loud to the user while they are on a voice call from the HermesVoice iPhone app.
A call belongs to the one conversation that received a message starting "[Voice call started]"; that message
carries the call_id, and "[Voice call ended]" closes the call. During a call your normal replies are shown as text
only and are NEVER spoken: the user hears you only through `speak`, and their speech arrives as messages starting
"[Voice]". Use `speak` only in that conversation while its call is running, always passing its exact call_id; never
from other conversations, scheduled jobs or messaging platforms. Keep spoken text short and conversational (no
Markdown, lists, code or URLs) and put detail in your text reply. If `speak` says the call has ended, stop using it
and reply in text. If it says the phone is not connected right now, reply in text this time; the phone reconnects by
itself, so use `speak` again for the next "[Voice]" message.
"""

SPEAK_DESCRIPTION = (
    "Say something out loud on the user's HermesVoice call (ElevenLabs voice). Use it ONLY in the conversation that "
    "received the '[Voice call started]' message, while that call is running (no '[Voice call ended]' yet), and pass "
    "that message's call_id exactly; never from other conversations or scheduled jobs. During the call your text "
    "replies are never spoken, so this is the only way the user hears you: use it to answer their '[Voice]' messages. "
    "Keep it short and natural, as you'd say it on the phone, with no Markdown, lists, code or URLs. Returns once the "
    "user has heard it, or says why not; if the call has ended, reply in text instead."
)


def build_app(settings: Settings, tts: TextToSpeech | None = None) -> ASGIApp:
    hub = CallHub()
    tts = tts or ElevenLabs(settings)
    mcp = MCPServer(name="hermes-voice", instructions=INSTRUCTIONS)

    @mcp.tool(description=SPEAK_DESCRIPTION)
    async def speak(
        text: Annotated[str, Field(description="What to say, as plain conversational speech")],
        call_id: Annotated[str, Field(description="call_id from this conversation's '[Voice call started]' message")],
        voice_id: Annotated[str | None, Field(description="Optional ElevenLabs voice id; omit for the default")] = None,
    ) -> str:
        text = text.strip()
        cid = normalize_call_id(call_id)
        if cid is None:
            return (
                "call_id must be the 32-character id from the '[Voice call started]' message in this "
                "conversation; nothing was spoken. Reply in text."
            )
        if not text:
            return "Nothing to say: text was empty."
        voice_id = (voice_id or "").strip() or None
        if voice_id is not None and not VOICE_ID.fullmatch(voice_id):
            return "Invalid voice_id (letters and digits only); nothing was spoken. Omit voice_id to use the default."
        text, note = _clip(text, settings.max_chars)
        result = await _speak_on(hub, cid, text, voice_id, tts)
        return result + note if result.startswith("Spoken") else result

    async def phone_socket(ws: WebSocket) -> None:
        # Accept first so a wrong token is reported with close code 4401 rather than a bare HTTP 403.
        await ws.accept()
        if not settings.authorized(ws.headers.get("authorization")):
            await _close_quietly(ws, 4401)
            return
        call: PhoneCall | None = None
        hung_up = False
        try:
            hello = None
            with anyio.move_on_after(HELLO_TIMEOUT):
                hello = await _next_message(ws)
            call_id = normalize_call_id(hello.get("call_id")) if hello and hello.get("type") == "hello" else None
            if call_id is None:
                await _close_quietly(ws, 4400)
                return
            session_id, title = _optional_str(hello.get("session_id")), _optional_str(hello.get("title"))
            await ws.send_json({"type": "ready", "call_id": call_id})
            call, previous = hub.connect(call_id, ws, session_id, title)
            if previous is not None:
                # Closed in the background: a replaced link that stopped reading must not hold up this one.
                hub.retire(previous.socket, 4409)
            logger.info("call %s connected (session %s)", call_id[:8], session_id)
            while not hung_up:
                message = await _next_message(ws) or {}
                kind = message.get("type")
                if kind == "played":
                    call.ack(str(message.get("id")))
                elif kind == "ping":
                    await ws.send_json({"type": "pong"})
                elif kind == "bye":
                    hung_up = True
        except _SOCKET_GONE:
            pass
        finally:
            if call is not None:
                hub.disconnect(call, hung_up)
        if hung_up:
            await _close_quietly(ws, 1000)

    async def health(_: Request) -> PlainTextResponse:
        return PlainTextResponse("ok")

    async def status(_: Request) -> JSONResponse:
        # _TokenGate has already checked the bearer token.
        return JSONResponse({"calls": len(hub.calls), "tts": "fake" if settings.fake_tts else "elevenlabs"})

    mcp.custom_route("/health", methods=["GET"])(health)
    mcp.custom_route("/status", methods=["GET"])(status)
    app = mcp.streamable_http_app(
        host=settings.host,
        # The bearer token guards every route; Tailscale Serve rewrites Host, so skip rebinding checks.
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
    app.router.routes.append(WebSocketRoute("/phone", phone_socket))
    return _TokenGate(app, settings)


def _clip(text: str, limit: int) -> tuple[str, str]:
    """Cut text to `limit` characters (at a word break when one is near) and say so in a note for the agent."""
    if len(text) <= limit:
        return text, ""
    cut = text.rfind(" ", 0, limit + 1)
    clipped = text[: cut if cut > limit // 2 else limit].rstrip()
    return clipped, (
        f" Only the first {len(clipped)} of {len(text)} characters were spoken; the rest was cut, "
        "so put it in your text reply."
    )


class _Utterance:
    """Sends one utterance to whichever connection the call has now, restarting it on a new socket after a reconnect."""

    def __init__(self, hub: CallHub, call_id: str, start: dict[str, Any]) -> None:
        self.hub = hub
        self.call_id = call_id
        self.start = start
        self.socket: WebSocket | None = None
        self.started = False
        self.resumed = False

    async def send(self, payload: bytes | dict[str, Any] | None = None) -> bool:
        """Send `payload` (after speech_start, if this socket has not had it). False once the call is gone."""
        avoid: WebSocket | None = None
        while (call := await self.hub.line(self.call_id, avoid=avoid)) is not None:
            try:
                if call.socket is not self.socket:
                    self.resumed = self.resumed or self.started
                    self.started = True
                    await _send_on(call, self.start)
                    self.socket = call.socket
                if payload is not None:
                    await _send_on(call, payload)
                return True
            except _Stalled:
                self.hub.stall(call)
                avoid = call.socket
            except _SOCKET_GONE:
                avoid = call.socket
        return False

    async def notify(self, message: dict[str, Any], shield: bool = False) -> None:
        """Time-bounded send on the current connection, without waiting for a reconnect. A connection that doesn't
        take it is stalled like in `send`: otherwise the phone would wait on the utterance (and keep its microphone
        paused) for as long as the link stays up. Once closed, the phone drops the utterance and reconnects."""
        call = self.hub.calls.get(self.call_id)
        if call is None or call.ended.is_set():
            return  # gone or already stalled: the phone drops the utterance when that connection closes
        with anyio.CancelScope(shield=shield):
            try:
                await _send_on(call, message, timeout=NOTICE_TIMEOUT)
            except Exception:  # noqa: BLE001 - _Stalled or the socket going away
                self.hub.stall(call)


class _Stalled(Exception):
    """A connection didn't take a frame: it was replaced meanwhile, or stopped reading."""


async def _send_on(call: PhoneCall, payload: bytes | dict[str, Any], timeout: float | None = None) -> None:
    """Send one frame on the call's connection. A send waits while the socket's write buffer is full, which on a
    half-open path never ends, so it gives up (raising _Stalled) once the connection is replaced or `timeout`
    (default SEND_TIMEOUT) passes. Cancelling it is clean: uvicorn writes a frame whole after its only wait."""
    socket = call.socket
    sending = asyncio.ensure_future(
        socket.send_bytes(payload) if isinstance(payload, bytes) else socket.send_json(payload)
    )
    replaced = asyncio.ensure_future(call.ended.wait())
    try:
        await asyncio.wait(
            {sending, replaced},
            timeout=SEND_TIMEOUT if timeout is None else timeout,
            return_when=asyncio.FIRST_COMPLETED,
        )
    except BaseException:
        sending.cancel()
        raise
    finally:
        replaced.cancel()
    if not sending.done():
        sending.cancel()
        raise _Stalled
    sending.result()


async def _speak_on(hub: CallHub, call_id: str, text: str, voice_id: str | None, tts: TextToSpeech) -> str:
    """Stream `text` to the call and wait until the phone has played it. Returns the result for the agent."""
    loop = asyncio.get_running_loop()
    give_up_at = loop.time() + PLAYBACK_WAIT_LIMIT
    call = await hub.line(call_id)
    if call is None:
        return hub.problem(call_id)
    async with call.lock:
        speech_id = uuid.uuid4().hex[:12]
        played = call.played[speech_id] = asyncio.Event()
        acked = call.acked
        start = {
            "type": "speech_start", "id": speech_id, "text": text, "sample_rate": SAMPLE_RATE, "format": "pcm_s16le"
        }
        utterance = _Utterance(hub, call_id, start)
        try:
            if not await utterance.send():
                return hub.problem(call_id)
            sent = 0
            audio_started: float | None = None
            carry = b""
            async with aclosing(tts.stream(text, voice_id)) as audio:
                async for chunk in audio:
                    chunk = carry + chunk
                    # Keep whole 16-bit samples per frame; hold back an odd trailing byte.
                    cut = len(chunk) - (len(chunk) % 2)
                    carry = chunk[cut:]
                    if not cut:
                        continue
                    if audio_started is None:
                        audio_started = loop.time()
                    if not await utterance.send(chunk[:cut]):
                        return hub.cut_off(call_id)
                    sent += cut
            if not await utterance.send({"type": "speech_end", "id": speech_id}):
                return hub.cut_off(call_id)
            seconds = sent / 2 / SAMPLE_RATE
            # The phone plays as audio arrives: it finishes `seconds` after the first frame, or just
            # after the last one if the stream was slower than real time.
            now = loop.time()
            wait_until = min(max((audio_started or now) + seconds, now) + PLAYBACK_MARGIN, give_up_at)
            with anyio.move_on_after(max(0.0, wait_until - loop.time())):
                await played.wait()
            if speech_id in acked:
                gap = " The connection dropped briefly, so they may have missed part." if utterance.resumed else ""
                return f"Spoken to the user ({seconds:.1f}s of audio).{gap}"
            if call_id not in hub.calls:
                return hub.cut_off(call_id)
            return "The phone did not confirm it played the audio, so the user may not have heard it."
        except Exception as error:  # noqa: BLE001 - report TTS and other failures back to the agent
            reason = str(error) or type(error).__name__
            logger.warning("speak failed on call %s: %s", call_id[:8], reason)
            if utterance.started:
                await utterance.notify({"type": "speech_end", "id": speech_id, "error": reason[:200]})
            return f"Could not speak: {reason}"
        except BaseException:
            # Cancelled (the user pressed Stop, or the turn was interrupted): the phone drops the
            # utterance's queued audio and resumes listening. The send is shielded and bounded.
            if utterance.started:
                await utterance.notify({"type": "speech_end", "id": speech_id, "cancelled": True}, shield=True)
            raise
        finally:
            call.played.pop(speech_id, None)
            acked.discard(speech_id)


async def _next_message(ws: WebSocket) -> dict[str, Any] | None:
    """The phone's next JSON object; None for any other frame. Raises WebSocketDisconnect when it goes away."""
    message = await ws.receive()
    if message["type"] == "websocket.disconnect":
        raise WebSocketDisconnect(message.get("code", 1000))
    try:
        data = json.loads(message.get("text") or "")
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _optional_str(value: Any) -> str | None:
    return str(value)[:200] if value else None


async def _close_quietly(ws: WebSocket, code: int) -> None:
    try:
        await ws.close(code=code)
    except Exception:  # noqa: BLE001 - already closed
        pass


class _TokenGate:
    """Require the shared token on every HTTP route except /health (/phone checks its own, to close with 4401)."""

    def __init__(self, app: ASGIApp, settings: Settings) -> None:
        self.app = app
        self.settings = settings

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        # Headers decodes as latin-1, so no byte sequence can raise here.
        if scope["type"] == "http" and scope["path"] != "/health":
            if not self.settings.authorized(Headers(scope=scope).get("authorization")):
                response = JSONResponse({"error": "unauthorized"}, status_code=401)
                await response(scope, receive, send)
                return
        await self.app(scope, receive, send)
