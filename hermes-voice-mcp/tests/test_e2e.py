"""End to end: a fake phone holds the /phone socket while an MCP client calls `speak` on an in-process server."""

from __future__ import annotations

import asyncio
import base64
import json
import os
import socket
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

import httpx2
import pytest
import uvicorn
import websockets
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from hermes_voice_mcp import server as voice_server
from hermes_voice_mcp.config import Settings
from hermes_voice_mcp.server import ElevenLabs, build_app

TOKEN = "test-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def _settings(**overrides: Any) -> Settings:
    values: dict[str, Any] = dict(
        host="127.0.0.1",
        port=0,
        token=TOKEN,
        elevenlabs_api_key=None,
        elevenlabs_base_url="http://127.0.0.1:9",
        voice_id="testvoice",
        model_id="test-model",
        max_chars=1000,
        fake_tts=True,
    )
    return Settings(**{**values, **overrides})


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _call_id() -> str:
    return uuid.uuid4().hex


class PacedSpeech:
    """Fake TTS: one 0.1 s chunk of silence per word, `delay` seconds apart. Records every request."""

    def __init__(self, delay: float = 0.0) -> None:
        self.delay = delay
        self.requests: list[tuple[str, str | None]] = []

    async def stream(self, text: str, voice_id: str | None) -> AsyncIterator[bytes]:
        self.requests.append((text, voice_id))
        for _ in text.split():
            await asyncio.sleep(self.delay)
            yield b"\x00\x00" * 2400


@asynccontextmanager
async def serving(settings: Settings | None = None, tts: Any = None) -> AsyncIterator[int]:
    port = _free_port()
    config = uvicorn.Config(
        build_app(settings or _settings(), tts),
        host="127.0.0.1",
        port=port,
        log_level="warning",
        timeout_graceful_shutdown=2,
    )
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            task.result()
        await asyncio.sleep(0.01)
    try:
        yield port
    finally:
        server.should_exit = True
        await task


@asynccontextmanager
async def mcp_session(port: int) -> AsyncIterator[ClientSession]:
    async with httpx2.AsyncClient(headers=AUTH, timeout=30) as client:
        async with streamable_http_client(f"http://127.0.0.1:{port}/mcp", http_client=client) as (read, write, *_):
            async with ClientSession(read, write) as session:
                await session.initialize()
                yield session


async def speak(session: ClientSession, **arguments: Any) -> str:
    result = await session.call_tool("speak", arguments)
    return "".join(getattr(c, "text", "") for c in result.content)


class Phone:
    """A fake HermesVoice app on /phone that records what the server sends."""

    def __init__(self, socket: Any, auto_ack: bool) -> None:
        self.socket = socket
        self.auto_ack = auto_ack
        self.messages: list[dict] = []
        self.audio = 0
        self.inbox: asyncio.Queue[dict] = asyncio.Queue()
        self.heard_audio = asyncio.Event()
        self.reader = asyncio.create_task(self._read())

    @classmethod
    async def dial(cls, port: int, call_id: str, auto_ack: bool = True) -> "Phone":
        ws = await websockets.connect(f"ws://127.0.0.1:{port}/phone", additional_headers=AUTH)
        await ws.send(json.dumps({"type": "hello", "call_id": call_id, "session_id": "s1", "title": "Test"}))
        assert json.loads(await ws.recv()) == {"type": "ready", "call_id": call_id}
        return cls(ws, auto_ack)

    async def _read(self) -> None:
        try:
            async for frame in self.socket:
                if isinstance(frame, bytes):
                    self.audio += len(frame)
                    self.heard_audio.set()
                    continue
                message = json.loads(frame)
                self.messages.append(message)
                if self.auto_ack and message["type"] == "speech_end" and not message.keys() & {"cancelled", "error"}:
                    await self.socket.send(json.dumps({"type": "played", "id": message["id"]}))
                await self.inbox.put(message)
        except websockets.ConnectionClosed:
            pass

    async def expect(self, kind: str, timeout: float = 5) -> dict:
        async with asyncio.timeout(timeout):
            while (message := await self.inbox.get())["type"] != kind:
                pass
        return message

    async def send(self, message: dict) -> None:
        await self.socket.send(json.dumps(message))

    async def hang_up(self) -> None:
        await self.send({"type": "bye"})
        await self.socket.close()
        await self.reader

    def kinds(self) -> list[str]:
        return [m["type"] for m in self.messages]


def test_routes_need_the_bearer_header():
    async def scenario():
        async with serving() as port:
            base = f"http://127.0.0.1:{port}"
            async with httpx2.AsyncClient() as http:
                assert (await http.get(f"{base}/health")).status_code == 200
                assert (await http.post(f"{base}/mcp", json={})).status_code == 401
                assert (await http.get(f"{base}/status")).status_code == 401
                # The token is never accepted in the query string, where access logs would keep it.
                assert (await http.get(f"{base}/status", params={"token": TOKEN})).status_code == 401
                ok = await http.get(f"{base}/status", headers=AUTH)
                assert ok.status_code == 200 and ok.json() == {"calls": 0, "tts": "fake"}

    asyncio.run(scenario())


def test_speak_streams_to_phone():
    async def scenario():
        async with serving() as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id)
            async with httpx2.AsyncClient(headers=AUTH) as http:
                assert (await http.get(f"http://127.0.0.1:{port}/status")).json()["calls"] == 1
            async with mcp_session(port) as session:
                tools = [tool.name for tool in (await session.list_tools()).tools]
                result = await speak(session, text="Hi there friend", call_id=call_id)
            await phone.hang_up()
            return tools, result, phone

    tools, result, phone = asyncio.run(scenario())
    assert tools == ["speak"]
    assert result.startswith("Spoken to the user"), result
    assert phone.messages[0]["text"] == "Hi there friend"
    assert phone.messages[0]["format"] == "pcm_s16le"
    assert phone.kinds() == ["speech_start", "speech_end"]
    assert phone.audio > 0 and phone.audio % 2 == 0


def test_speak_never_falls_back_to_another_call():
    async def scenario():
        async with serving() as port:
            phone = await Phone.dial(port, _call_id())
            async with mcp_session(port) as session:
                unknown = await speak(session, text="hello", call_id=_call_id())
                malformed = await speak(session, text="hello", call_id="c1")
                missing = await session.call_tool("speak", {"text": "hello"})
            await asyncio.sleep(0.2)
            await phone.hang_up()
            return unknown, malformed, missing, phone

    unknown, malformed, missing, phone = asyncio.run(scenario())
    assert "is connected" in unknown and "nothing was spoken" in unknown, unknown
    assert "32-character" in malformed, malformed
    assert missing.is_error
    assert phone.messages == [] and phone.audio == 0


def test_hang_up_mid_speech_is_not_reported_as_spoken():
    async def scenario():
        async with serving() as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id, auto_ack=False)
            async with mcp_session(port) as session:
                pending = asyncio.create_task(speak(session, text="A long answer", call_id=call_id))
                await phone.expect("speech_end")
                await phone.hang_up()
                during = await asyncio.wait_for(pending, 5)
                after = await speak(session, text="Are you there?", call_id=call_id)
            return during, after

    during, after = asyncio.run(scenario())
    assert not during.startswith("Spoken") and "call ended" in during, during
    assert "has ended" in after and "Reply in text" in after, after


def test_reconnect_with_same_call_id_resolves_in_flight_speak():
    async def scenario():
        async with serving() as port:
            call_id = _call_id()
            first = await Phone.dial(port, call_id, auto_ack=False)
            async with mcp_session(port) as session:
                pending = asyncio.create_task(speak(session, text="Hello again", call_id=call_id))
                end = await first.expect("speech_end")
                second = await Phone.dial(port, call_id, auto_ack=False)
                await asyncio.wait_for(first.reader, 5)
                started = time.monotonic()
                await second.send({"type": "played", "id": end["id"]})
                result = await asyncio.wait_for(pending, 5)
                elapsed = time.monotonic() - started
            await second.hang_up()
            return first.socket.close_code, result, elapsed

    replaced_code, result, elapsed = asyncio.run(scenario())
    assert replaced_code == 4409
    assert result.startswith("Spoken to the user"), result
    assert elapsed < 2


def test_dropped_connection_that_reconnects_keeps_the_call():
    async def scenario():
        async with serving() as port:
            call_id = _call_id()
            first = await Phone.dial(port, call_id, auto_ack=False)
            async with mcp_session(port) as session:
                pending = asyncio.create_task(speak(session, text="Hold on", call_id=call_id))
                end = await first.expect("speech_end")
                await first.socket.close()  # network drop: no bye
                await first.reader
                await asyncio.sleep(0.5)
                second = await Phone.dial(port, call_id, auto_ack=True)
                await second.send({"type": "played", "id": end["id"]})
                result = await asyncio.wait_for(pending, 5)
                follow_up = await speak(session, text="Still here", call_id=call_id)
            await second.hang_up()
            return result, follow_up

    result, follow_up = asyncio.run(scenario())
    assert result.startswith("Spoken to the user"), result
    assert follow_up.startswith("Spoken to the user"), follow_up


@pytest.mark.parametrize("phase", ["streaming", "waiting for playback"])
def test_cancelled_speak_tells_phone(phase):
    async def scenario():
        tts = PacedSpeech(delay=0.1 if phase == "streaming" else 0.0)
        async with serving(tts=tts) as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id)
            async with mcp_session(port) as session:
                text = " ".join(["word"] * 60)
                phone.auto_ack = phase == "streaming"
                pending = asyncio.create_task(speak(session, text=text, call_id=call_id))
                if phase == "streaming":
                    await asyncio.wait_for(phone.heard_audio.wait(), 5)
                else:
                    await phone.expect("speech_end")
                pending.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await pending
                cancelled = await phone.expect("speech_end")
                # The call keeps working: the lock was released and the next utterance plays normally.
                phone.auto_ack = True
                follow_up = await speak(session, text="okay", call_id=call_id)
            await phone.hang_up()
            return cancelled, follow_up, phone

    cancelled, follow_up, phone = asyncio.run(scenario())
    assert cancelled.get("cancelled") is True, cancelled
    assert cancelled["id"] == phone.messages[0]["id"]
    assert follow_up.startswith("Spoken to the user"), follow_up


def test_tts_failure_ends_the_utterance_with_an_error():
    class BrokenSpeech:
        async def stream(self, text: str, voice_id: str | None) -> AsyncIterator[bytes]:
            yield b"\x00\x00" * 2400
            raise RuntimeError("ElevenLabs returned HTTP 401.")

    async def scenario():
        async with serving(tts=BrokenSpeech()) as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id)
            async with mcp_session(port) as session:
                result = await speak(session, text="hello", call_id=call_id)
            end = await phone.expect("speech_end")
            await phone.hang_up()
            return result, end

    result, end = asyncio.run(scenario())
    assert result == "Could not speak: ElevenLabs returned HTTP 401.", result
    assert end["error"] == "ElevenLabs returned HTTP 401."


def test_invalid_voice_id_is_rejected_without_a_request():
    async def scenario():
        tts = PacedSpeech()
        async with serving(tts=tts) as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id)
            async with mcp_session(port) as session:
                result = await speak(session, text="hello", call_id=call_id, voice_id="../../v1/user/subscription#")
            await asyncio.sleep(0.2)
            await phone.hang_up()
            return result, tts.requests, phone.messages

    result, requests, messages = asyncio.run(scenario())
    assert "Invalid voice_id" in result, result
    assert requests == [] and messages == []


def test_elevenlabs_refuses_a_voice_id_that_would_change_the_url():
    async def scenario():
        tts = ElevenLabs(_settings(fake_tts=False, elevenlabs_api_key="key"))
        async for _ in tts.stream("hello", "../../v1/models#"):
            pass

    # A request would fail with a connection error instead (nothing listens on port 9).
    with pytest.raises(ValueError, match="Invalid voice_id"):
        asyncio.run(scenario())


def test_long_text_is_truncated_and_said_so():
    async def scenario():
        async with serving(_settings(max_chars=20), tts=PacedSpeech()) as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id)
            async with mcp_session(port) as session:
                result = await speak(session, text="one two three four five six seven eight", call_id=call_id)
            await phone.hang_up()
            return result, phone.messages[0]["text"]

    result, spoken = asyncio.run(scenario())
    assert spoken == "one two three four"
    assert result.startswith("Spoken to the user") and "Only the first 18 of 39 characters" in result, result


def test_phone_bad_token_and_query_token_close_with_4401():
    async def scenario():
        codes = []
        async with serving() as port:
            for url, headers in (
                (f"ws://127.0.0.1:{port}/phone", {"Authorization": "Bearer nope"}),
                (f"ws://127.0.0.1:{port}/phone?token={TOKEN}", {}),
            ):
                async with websockets.connect(url, additional_headers=headers) as ws:
                    await ws.wait_closed()
                    codes.append(ws.close_code)
        return codes

    assert asyncio.run(scenario()) == [4401, 4401]


def test_bad_hello_closes_with_4400():
    async def scenario():
        async with serving() as port:
            async with websockets.connect(f"ws://127.0.0.1:{port}/phone", additional_headers=AUTH) as ws:
                await ws.send(json.dumps({"type": "hello", "call_id": "c1"}))
                await ws.wait_closed()
                return ws.close_code

    assert asyncio.run(scenario()) == 4400


def test_undecodable_authorization_header_is_401_not_500():
    async def raw_status(port: int, method: str, path: str, authorization: bytes) -> int:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(
            f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nConnection: close\r\n".encode()
            + b"Authorization: " + authorization + b"\r\n\r\n{}"
        )
        await writer.drain()
        status_line = await reader.readline()
        writer.close()
        return int(status_line.split()[1])

    async def scenario():
        async with serving() as port:
            return [
                await raw_status(port, method, path, value)
                for method, path in (("POST", "/mcp"), ("GET", "/status"))
                for value in (b"Bearer \xe9\xff", b"Bearer \xc3\xa9", b"\xff\xfe")
            ]

    assert asyncio.run(scenario()) == [401] * 6


def test_a_drop_longer_than_the_grace_is_not_final(monkeypatch):
    monkeypatch.setattr(voice_server, "RECONNECT_GRACE", 0.3)
    monkeypatch.setattr(voice_server, "PLAYBACK_MARGIN", 0.5)

    async def scenario():
        async with serving() as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id, auto_ack=False)
            async with mcp_session(port) as session:
                pending = asyncio.create_task(speak(session, text="Anyone there", call_id=call_id))
                await phone.expect("speech_end")
                await phone.socket.close()  # dropped without a bye, and away for longer than the grace
                during = await asyncio.wait_for(pending, 5)
                gap = await speak(session, text="Hello?", call_id=call_id)
                back = await Phone.dial(port, call_id)
                after = await speak(session, text="There you are", call_id=call_id)
            await back.hang_up()
            return during, gap, after

    during, gap, after = asyncio.run(scenario())
    assert "lost its connection" in during and "speak again" in during, during
    assert "not connected right now" in gap and "do not call speak" not in gap, gap
    assert after.startswith("Spoken to the user"), after


def test_a_lost_call_answers_at_once_and_comes_back_on_hello(monkeypatch):
    monkeypatch.setattr(voice_server, "DROP_RETENTION", 0.2)

    async def scenario():
        async with serving() as port:
            call_id = _call_id()
            phone = await Phone.dial(port, call_id)
            await phone.socket.close()
            await phone.reader
            await asyncio.sleep(0.5)  # past the retention: the call counts as lost
            async with mcp_session(port) as session:
                started = time.monotonic()
                lost = await speak(session, text="Hello?", call_id=call_id)
                elapsed = time.monotonic() - started
                back = await Phone.dial(port, call_id)
                after = await speak(session, text="Back again", call_id=call_id)
            await back.hang_up()
            return lost, elapsed, after

    lost, elapsed, after = asyncio.run(scenario())
    assert "not connected right now" in lost and "do not call speak" not in lost, lost
    assert elapsed < 2, elapsed
    assert after.startswith("Spoken to the user"), after


class WedgedPhone:
    """A phone on a half-open path: it says hello, then never reads again, so the server's writes back up."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader, self.writer = reader, writer

    @classmethod
    async def dial(cls, port: int, call_id: str) -> "WedgedPhone":
        raw = socket.socket()
        raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        raw.connect(("127.0.0.1", port))
        raw.setblocking(False)
        reader, writer = await asyncio.open_connection(sock=raw, limit=4096)
        key = base64.b64encode(os.urandom(16)).decode()
        writer.write(
            f"GET /phone HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\nAuthorization: Bearer {TOKEN}\r\n\r\n".encode()
        )
        while (await reader.readline()) not in (b"\r\n", b""):
            pass
        hello = json.dumps({"type": "hello", "call_id": call_id}).encode()
        mask = os.urandom(4)
        writer.write(bytes([0x81, 0x80 | len(hello)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(hello)))
        await writer.drain()
        header = await reader.readexactly(2)
        assert json.loads(await reader.readexactly(header[1] & 0x7F))["type"] == "ready"
        return cls(reader, writer)

    async def read_until_closed(self, timeout: float = 5) -> tuple[int, list[dict]]:
        """Start reading again: the JSON messages the server had queued, then the code it closed the link with.
        Times out if the server never closes it."""
        messages: list[dict] = []
        async with asyncio.timeout(timeout):
            while True:
                head = await self.reader.readexactly(2)
                size = head[1] & 0x7F
                if size >= 126:
                    size = int.from_bytes(await self.reader.readexactly(2 if size == 126 else 8), "big")
                payload = await self.reader.readexactly(size)
                opcode = head[0] & 0x0F
                if opcode == 0x8:
                    return int.from_bytes(payload[:2], "big"), messages
                if opcode == 0x1:
                    messages.append(json.loads(payload))

    def abort(self) -> None:
        self.writer.transport.abort()


def test_a_replaced_link_that_stopped_reading_does_not_hold_up_the_new_one():
    async def scenario():
        async with serving(_settings(max_chars=20000), tts=PacedSpeech()) as port:
            call_id = _call_id()
            wedged = await WedgedPhone.dial(port, call_id)
            async with mcp_session(port) as session:
                pending = asyncio.create_task(speak(session, text=" ".join(["w"] * 3000), call_id=call_id))
                await asyncio.sleep(1.0)  # the old link's write buffer fills up
                started = time.monotonic()
                phone = await asyncio.wait_for(Phone.dial(port, call_id), 3)
                ready_after = time.monotonic() - started
                await asyncio.wait_for(phone.heard_audio.wait(), 3)
                pending.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await pending
                # The new link's handler is reading, not stuck closing the old link: it answers pings and acks.
                await phone.send({"type": "ping"})
                await phone.expect("pong", timeout=1)
                follow_up = await asyncio.wait_for(speak(session, text="Still there?", call_id=call_id), 5)
            # The old link is closed as replaced once it reads again.
            replaced_code, _ = await wedged.read_until_closed()
            wedged.abort()
            await phone.hang_up()
            return ready_after, phone.messages[0], follow_up, replaced_code

    ready_after, first, follow_up, replaced_code = asyncio.run(scenario())
    assert ready_after < 2, ready_after
    assert first["type"] == "speech_start", first
    assert follow_up.startswith("Spoken to the user"), follow_up
    assert replaced_code == 4409


def test_a_link_that_stops_reading_is_dropped_instead_of_blocking_speak(monkeypatch):
    monkeypatch.setattr(voice_server, "SEND_TIMEOUT", 1.0)
    monkeypatch.setattr(voice_server, "RECONNECT_GRACE", 0.3)

    async def scenario():
        async with serving(_settings(max_chars=20000), tts=PacedSpeech()) as port:
            call_id = _call_id()
            wedged = await WedgedPhone.dial(port, call_id)
            async with mcp_session(port) as session:
                result = await asyncio.wait_for(speak(session, text=" ".join(["w"] * 3000), call_id=call_id), 10)
                # The stalled link is out of use: the next speak only waits the grace for a reconnect, instead of
                # first getting stuck on that link for another SEND_TIMEOUT.
                started = time.monotonic()
                gap = await speak(session, text="Hello?", call_id=call_id)
                elapsed = time.monotonic() - started
                # And it was closed, which is what makes the phone reconnect once it reads again.
                code, _ = await wedged.read_until_closed()
                wedged.abort()
                back = await Phone.dial(port, call_id)
                after = await speak(session, text="There you are", call_id=call_id)
            await back.hang_up()
            return result, gap, elapsed, code, after

    result, gap, elapsed, code, after = asyncio.run(scenario())
    assert "lost its connection" in result, result
    assert "not connected right now" in gap, gap
    assert elapsed < 0.9, elapsed
    assert code == 1011
    assert after.startswith("Spoken to the user"), after


class StuckSpeech:
    """Fake TTS whose first utterance is one chunk bigger than a stopped link's buffers can hold, then an error or a
    hang until the speak is cancelled. Later utterances are a short silence."""

    def __init__(self, ending: str) -> None:
        self.ending = ending
        self.first = True
        self.sent = asyncio.Event()

    async def stream(self, text: str, voice_id: str | None) -> AsyncIterator[bytes]:
        if not self.first:
            yield b"\x00\x00" * 2400
            return
        self.first = False
        yield b"\x00\x00" * 4_000_000  # taken whole, after which the link no longer takes anything
        self.sent.set()
        if self.ending == "error":
            raise RuntimeError("ElevenLabs returned HTTP 500.")
        await asyncio.Event().wait()


@pytest.mark.parametrize("ending", ["error", "cancelled"])
def test_an_end_notice_the_link_does_not_take_stalls_it(monkeypatch, ending):
    """The final speech_end of a failed or cancelled utterance can't reach a phone whose link stopped taking frames.
    The link is closed, so the phone drops the utterance and reconnects instead of waiting on it while the link
    stays up."""
    monkeypatch.setattr(voice_server, "NOTICE_TIMEOUT", 0.3)

    async def scenario():
        tts = StuckSpeech(ending)
        async with serving(tts=tts) as port:
            call_id = _call_id()
            wedged = await WedgedPhone.dial(port, call_id)
            async with mcp_session(port) as session:
                pending = asyncio.create_task(speak(session, text="hello", call_id=call_id))
                await asyncio.wait_for(tts.sent.wait(), 5)
                result = None
                if ending == "cancelled":
                    pending.cancel()
                    with pytest.raises(asyncio.CancelledError):
                        await pending
                    await asyncio.sleep(1.0)  # well past NOTICE_TIMEOUT, before the link starts reading again
                else:
                    result = await asyncio.wait_for(pending, 5)
                code, messages = await wedged.read_until_closed()
                wedged.abort()
                back = await Phone.dial(port, call_id)
                after = await speak(session, text="Back again", call_id=call_id)
            await back.hang_up()
            return result, code, messages, after

    result, code, messages, after = asyncio.run(scenario())
    if ending == "error":
        assert result == "Could not speak: ElevenLabs returned HTTP 500.", result
    assert [m["type"] for m in messages] == ["speech_start"], messages
    assert code == 1011
    assert after.startswith("Spoken to the user"), after
