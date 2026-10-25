"""Streaming, acks, reconnects and stalls on the phone link (ported from hermes-voice-mcp's end-to-end tests).

A fake phone holds the plugin's /phone socket on a real server while lines are spoken into its call.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import socket
import time
import uuid
from typing import AsyncIterator, Optional

import httpx
import pytest
import websockets

from support import PREFIX, PacedSpeech, Phone, say_line, serving, tool, until


def _call_id() -> str:
    return uuid.uuid4().hex


def test_phone_route_needs_a_ticket_and_status_reports(core, fake, make_hub):
    make_hub()

    async def scenario():
        async with serving(core) as port:
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone") as ws:
                await ws.wait_closed()
                no_ticket = ws.close_code
            async with httpx.AsyncClient() as http:
                status = (await http.get(f"http://127.0.0.1:{port}{PREFIX}/status")).json()
            return no_ticket, status

    no_ticket, status = asyncio.run(scenario())
    assert no_ticket == 4401
    assert status["calls"] == 0 and status["tts"] == "fake" and status["active_call"] is None
    assert set(status) >= {"calls", "tts", "h2", "apns_configured", "scribe_configured"}
    assert status["scribe_configured"] is False


def test_line_streams_to_phone(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            async with httpx.AsyncClient() as http:
                status = (await http.get(f"http://127.0.0.1:{port}{PREFIX}/status")).json()
            started = await tool(core.tools.start_call, {"text": "Hi there friend"})
            await phone.expect("speech_end")
            await until(lambda: not hub.slot.lines)
            await phone.hang_up()
            return status, started, phone

    status, started, phone = asyncio.run(scenario())
    assert status["calls"] == 1 and status["active_call"]["state"] == "live"
    assert started["status"] == "speaking" and started["call_id"] == phone.call_id
    assert phone.messages[0]["text"] == "Hi there friend"
    assert phone.messages[0]["format"] == "pcm_s16le" and phone.messages[0]["sample_rate"] == 24000
    assert phone.kinds() == ["speech_start", "speech_end"]
    assert phone.audio > 0 and phone.audio % 2 == 0


def test_another_conversation_never_speaks_into_the_call(core, fake, make_hub):
    fake.host.add("s1")
    fake.host.add("s2")
    make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            other = await tool(core.tools.start_call, {"text": "hello"}, session_id="s2")
            other_sync = await tool(core.tools.start_call, {"text": "hello", "mode": "sync"}, session_id="s2")
            hang_up = await tool(core.tools.end_call, {}, session_id="s2")
            missing = await tool(core.tools.start_call, {}, session_id="s1")
            await asyncio.sleep(0.2)
            await phone.hang_up()
            return other, other_sync, hang_up, missing, phone

    other, other_sync, hang_up, missing, phone = asyncio.run(scenario())
    assert other["status"] == "busy" and other["call_id"] is None, other
    assert other_sync["outcome"] == "busy" and other_sync["said"] == "", other_sync
    assert '"Test"' in other["note"]
    assert hang_up["outcome"] is None and "no voice call" in hang_up["note"]
    assert "text is required" in missing["error"]
    assert phone.messages == [] and phone.audio == 0


def test_hang_up_mid_speech_is_not_reported_as_heard(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            call = hub.slot
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "A long answer", "mode": "sync"}))
            await phone.expect("speech_end")
            await phone.hang_up()
            during = await asyncio.wait_for(pending, 5)
            after = await say_line(hub, call, "Are you there?")
            await hub.injector.wait_for(1)
            await asyncio.sleep(0.2)
            return during, after

    during, after = asyncio.run(scenario())
    assert during["outcome"] == "ended_by_user" and during["said"] == "", during
    assert after.status == "not_delivered" and "has ended" in after.message and "Reply in text" in after.message
    # The sync start_call returned the hang-up itself: no "[Voice call ended by user]" notice on top.
    texts = hub.injector.texts()
    assert len(texts) == 1 and texts[0].startswith("[Voice call started]"), texts


def test_reconnect_with_same_call_id_resolves_in_flight_line(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            first = await Phone.dial(port, fake, auto_ack=False)
            call = hub.slot
            pending = asyncio.create_task(say_line(hub, call, "Hello again"))
            end = await first.expect("speech_end")
            second = await Phone.dial(port, fake, call_id=first.call_id, auto_ack=False)
            assert second.ready["state"] == "live"
            await asyncio.wait_for(first.reader, 5)
            started = time.monotonic()
            await second.send({"type": "played", "id": end["id"]})
            result = await asyncio.wait_for(pending, 5)
            elapsed = time.monotonic() - started
            await second.hang_up()
            return first.socket.close_code, result, elapsed

    replaced_code, result, elapsed = asyncio.run(scenario())
    assert replaced_code == 4409
    assert result.status == "played" and result.message.startswith("Spoken to the user"), result
    assert elapsed < 2


def test_dropped_link_that_reconnects_keeps_the_call(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            first = await Phone.dial(port, fake, auto_ack=False)
            call = hub.slot
            pending = asyncio.create_task(say_line(hub, call, "Hold on"))
            end = await first.expect("speech_end")
            await first.socket.close()  # network drop: no bye
            await first.reader
            await asyncio.sleep(0.5)
            assert hub.slot is call and call.state == "live"
            second = await Phone.dial(port, fake, call_id=first.call_id, auto_ack=True)
            await second.send({"type": "played", "id": end["id"]})
            result = await asyncio.wait_for(pending, 5)
            follow_up = await say_line(hub, call, "Still here")
            await second.hang_up()
            return result, follow_up

    result, follow_up = asyncio.run(scenario())
    assert result.status == "played", result
    assert follow_up.status == "played", follow_up


@pytest.mark.parametrize("phase", ["streaming", "waiting for playback"])
def test_cancelled_line_tells_phone(core, fake, make_hub, phase):
    fake.host.add("s1")
    hub = make_hub(tts=PacedSpeech(delay=0.1 if phase == "streaming" else 0.0))

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            call = hub.slot
            phone.auto_ack = phase == "streaming"
            line, _ = hub.enqueue_line(call, " ".join(["word"] * 60))
            if phase == "streaming":
                await asyncio.wait_for(phone.heard_audio.wait(), 5)
            else:
                await phone.expect("speech_end")
            hub.cancel_line(call, line)
            await asyncio.to_thread(line.done.wait, 5)
            cancelled = await phone.expect("speech_end")
            # The call keeps working: the link's lock was released and the next line plays normally.
            phone.auto_ack = True
            follow_up = await say_line(hub, call, "okay")
            await phone.hang_up()
            return line.result, cancelled, follow_up, phone

    result, cancelled, follow_up, phone = asyncio.run(scenario())
    assert result.status == "cancelled"
    assert cancelled.get("cancelled") is True, cancelled
    assert cancelled["id"] == phone.messages[0]["id"]
    assert follow_up.status == "played", follow_up


def test_tts_failure_ends_the_line_with_an_error(core, fake, make_hub):
    class BrokenSpeech:
        async def stream(self, text: str, voice_id: Optional[str] = None) -> AsyncIterator[bytes]:
            yield b"\x00\x00" * 2400
            raise RuntimeError("ElevenLabs returned HTTP 401.")

    fake.host.add("s1")
    make_hub(tts=BrokenSpeech())

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            result = await tool(core.tools.start_call, {"text": "hello", "mode": "sync"})
            end = await phone.expect("speech_end")
            await phone.hang_up()
            return result, end

    result, end = asyncio.run(scenario())
    assert result["outcome"] == "tts_failed", result
    assert result["note"] == "Could not speak: ElevenLabs returned HTTP 401."
    assert end["error"] == "ElevenLabs returned HTTP 401."


def test_invalid_voice_id_in_config_never_reaches_the_url(core, fake):
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, content=b"\x00\x00" * 10)

    settings = core.config.Settings.from_config(
        {"plugins": {"entries": {"hermes_voice": {"settings": {"voice_id": "../../v1/user/subscription#"}}}}}, {})
    assert settings.voice_id == core.config.DEFAULT_VOICE_ID
    tts = core.tts.ElevenLabs(lambda: settings, api_key=lambda: "key", transport=httpx.MockTransport(handler))

    async def scenario():
        return b"".join([chunk async for chunk in tts.stream("hello")])

    assert asyncio.run(scenario()) == b"\x00\x00" * 10
    assert requests[0].url.path == f"/v1/text-to-speech/{core.config.DEFAULT_VOICE_ID}/stream"
    assert requests[0].url.params["output_format"] == "pcm_24000"


def test_elevenlabs_refuses_a_voice_id_that_would_change_the_url(core, fake):
    requests: list[httpx.Request] = []
    settings = core.config.Settings(fake_tts=False)
    transport = httpx.MockTransport(lambda request: requests.append(request) or httpx.Response(200))
    tts = core.tts.ElevenLabs(lambda: settings, api_key=lambda: "key", transport=transport)

    async def scenario():
        async for _ in tts.stream("hello", "../../v1/models#"):
            pass

    with pytest.raises(ValueError, match="Invalid voice_id"):
        asyncio.run(scenario())
    assert requests == []


def test_long_text_is_truncated_and_said_so(core, fake, make_hub):
    fake.host.add("s1")
    make_hub(max_chars=20)

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            result = await tool(core.tools.start_call, {"text": "one two three four five six seven eight"})
            start = await phone.expect("speech_start")
            await phone.hang_up()
            return result, start["text"]

    result, spoken = asyncio.run(scenario())
    assert spoken == "one two three four"
    assert "Only the first 18 of 39 characters" in result["note"], result


def test_bad_and_reused_tickets_close_with_4401(core, fake, make_hub):
    make_hub()

    async def scenario():
        codes = []
        async with serving(core) as port:
            used = fake.ticket()
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={used}") as ws:
                await ws.send(json.dumps({"type": "hello", "call_id": "0" * 32, "initiated_by": "push"}))
                await ws.wait_closed()  # a push hello for no call: cancelled and closed normally
                codes.append(ws.close_code)
            for url in (f"{PREFIX}/phone?ticket=nope", f"{PREFIX}/phone?ticket={used}", f"{PREFIX}/phone?token=x"):
                async with websockets.connect(f"ws://127.0.0.1:{port}{url}") as ws:
                    await ws.wait_closed()
                    codes.append(ws.close_code)
        return codes

    assert asyncio.run(scenario()) == [1000, 4401, 4401, 4401]


def test_bad_hello_closes_with_4400(core, fake, make_hub):
    make_hub()

    async def scenario():
        codes = []
        async with serving(core) as port:
            for hello in (
                {"type": "hello", "call_id": "c1"},
                {"type": "hello", "call_id": _call_id(), "initiated_by": "robot"},
                {"type": "hello", "call_id": _call_id()},  # a call the user starts needs its conversation
                {"type": "ping"},
            ):
                async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={fake.ticket()}") as ws:
                    await ws.send(json.dumps(hello))
                    await ws.wait_closed()
                    codes.append(ws.close_code)
        return codes

    assert asyncio.run(scenario()) == [4400] * 4


def test_undecodable_requests_are_refused_not_500(core, fake, make_hub):
    make_hub()

    async def raw_status(port: int, method: str, path: str, body: bytes, extra: bytes = b"") -> int:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(
            f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {len(body)}\r\nConnection: close\r\n"
            .encode() + extra + b"\r\n" + body
        )
        await writer.drain()
        status_line = await reader.readline()
        writer.close()
        return int(status_line.split()[1])

    async def scenario():
        async with serving(core) as port:
            statuses = [
                await raw_status(port, "POST", f"{PREFIX}/devices", body)
                for body in (b"\xe9\xff", b"{", b"[]", b'{"voip_token": "\xc3\xa9"}', b"null")
            ]
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket=%E9%FF") as ws:
                await ws.wait_closed()
                code = ws.close_code
            return statuses, code

    statuses, code = asyncio.run(scenario())
    assert statuses == [400] * 5
    assert code == 4401


def test_a_drop_longer_than_the_grace_is_not_final(core, fake, make_hub, monkeypatch):
    monkeypatch.setattr(core.hub, "RECONNECT_GRACE", 0.3)
    monkeypatch.setattr(core.hub, "PLAYBACK_MARGIN", 0.5)
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            call = hub.slot
            pending = asyncio.create_task(say_line(hub, call, "Anyone there"))
            await phone.expect("speech_end")
            await phone.socket.close()  # dropped without a bye, and away for longer than the grace
            during = await asyncio.wait_for(pending, 5)
            gap = await say_line(hub, call, "Hello?")
            back = await Phone.dial(port, fake, call_id=phone.call_id)
            after = await say_line(hub, call, "There you are")
            await back.hang_up()
            return during, gap, after

    during, gap, after = asyncio.run(scenario())
    assert during.status == "cut_off" and "lost its connection" in during.message and "start_call again" in during.message
    assert gap.status == "not_connected" and "not connected right now" in gap.message, gap
    assert after.status == "played", after


def test_a_lost_call_ends_and_comes_back_on_hello(core, fake, make_hub, monkeypatch):
    monkeypatch.setattr(core.hub, "DROP_RETENTION", 0.3)
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            call = hub.slot
            waiting = asyncio.create_task(tool(core.tools.start_call, {"text": "Still there?", "mode": "sync"}))
            await phone.expect("speech_end")
            await phone.socket.close()
            await phone.reader
            started = time.monotonic()
            lost = await asyncio.wait_for(waiting, 5)
            elapsed = time.monotonic() - started
            assert hub.slot is None and call.outcome == "lost"
            back = await Phone.dial(port, fake, call_id=phone.call_id)
            revived = hub.slot
            after = await say_line(hub, revived, "Back again")
            await back.hang_up()
            return lost, elapsed, back.ready, revived, after

    lost, elapsed, ready, revived, after = asyncio.run(scenario())
    assert lost["outcome"] == "lost", lost
    assert elapsed < 2, elapsed
    assert ready["state"] == "live" and revived.call_id == ready["call_id"]
    assert after.status == "played", after


class WedgedPhone:
    """A phone on a half-open path: it says hello, then never reads again, so the server's writes back up."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader, self.writer = reader, writer

    @classmethod
    async def dial(cls, port: int, fake, call_id: str, session_id: str = "s1") -> "WedgedPhone":
        raw = socket.socket()
        raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        raw.connect(("127.0.0.1", port))
        raw.setblocking(False)
        reader, writer = await asyncio.open_connection(sock=raw, limit=4096)
        key = base64.b64encode(os.urandom(16)).decode()
        writer.write(
            f"GET {PREFIX}/phone?ticket={fake.ticket()} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n".encode()
        )
        while (await reader.readline()) not in (b"\r\n", b""):
            pass
        hello = json.dumps({"type": "hello", "call_id": call_id, "session_id": session_id}).encode()
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


def test_a_replaced_link_that_stopped_reading_does_not_hold_up_the_new_one(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub(max_chars=20000)

    async def scenario():
        async with serving(core) as port:
            call_id = _call_id()
            wedged = await WedgedPhone.dial(port, fake, call_id)
            call = hub.slot
            line, _ = hub.enqueue_line(call, " ".join(["w"] * 3000))
            await asyncio.sleep(1.0)  # the old link's write buffer fills up
            started = time.monotonic()
            phone = await asyncio.wait_for(Phone.dial(port, fake, call_id=call_id), 3)
            ready_after = time.monotonic() - started
            await asyncio.wait_for(phone.heard_audio.wait(), 3)
            hub.cancel_line(call, line)
            await asyncio.to_thread(line.done.wait, 5)
            # The new link's handler is reading, not stuck closing the old link: it answers pings and acks.
            await phone.send({"type": "ping"})
            await phone.expect("pong", timeout=1)
            follow_up = await asyncio.wait_for(say_line(hub, call, "Still there?"), 5)
            # The old link is closed as replaced once it reads again.
            replaced_code, _ = await wedged.read_until_closed()
            wedged.abort()
            await phone.hang_up()
            return ready_after, phone.messages[0], line.result, follow_up, replaced_code

    ready_after, first, cancelled, follow_up, replaced_code = asyncio.run(scenario())
    assert ready_after < 2, ready_after
    assert first["type"] == "speech_start", first
    assert cancelled.status == "cancelled"
    assert follow_up.status == "played", follow_up
    assert replaced_code == 4409


def test_a_link_that_stops_reading_is_dropped_instead_of_blocking_speech(core, fake, make_hub, monkeypatch):
    monkeypatch.setattr(core.hub, "SEND_TIMEOUT", 1.0)
    monkeypatch.setattr(core.hub, "RECONNECT_GRACE", 0.3)
    fake.host.add("s1")
    hub = make_hub(max_chars=20000)

    async def scenario():
        async with serving(core) as port:
            call_id = _call_id()
            wedged = await WedgedPhone.dial(port, fake, call_id)
            call = hub.slot
            result = await asyncio.wait_for(say_line(hub, call, " ".join(["w"] * 3000)), 10)
            # The stalled link is out of use: the next line only waits the grace for a reconnect, instead of
            # first getting stuck on that link for another SEND_TIMEOUT.
            started = time.monotonic()
            gap = await say_line(hub, call, "Hello?")
            elapsed = time.monotonic() - started
            # And it was closed, which is what makes the phone reconnect once it reads again.
            code, _ = await wedged.read_until_closed()
            wedged.abort()
            back = await Phone.dial(port, fake, call_id=call_id)
            after = await say_line(hub, call, "There you are")
            await back.hang_up()
            return result, gap, elapsed, code, after

    result, gap, elapsed, code, after = asyncio.run(scenario())
    assert result.status == "cut_off" and "lost its connection" in result.message, result
    assert gap.status == "not_connected" and "not connected right now" in gap.message, gap
    assert elapsed < 0.9, elapsed
    assert code == 1011
    assert after.status == "played", after


class StuckSpeech:
    """Fake TTS whose first line is one chunk bigger than a stopped link's buffers can hold, then an error or a
    hang until the line is cancelled. Later lines are a short silence."""

    def __init__(self, ending: str) -> None:
        self.ending = ending
        self.first = True
        self.sent = asyncio.Event()

    async def stream(self, text: str, voice_id: Optional[str] = None) -> AsyncIterator[bytes]:
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
def test_an_end_notice_the_link_does_not_take_stalls_it(core, fake, make_hub, monkeypatch, ending):
    """The final speech_end of a failed or cancelled line can't reach a phone whose link stopped taking frames.
    The link is closed, so the phone drops the line and reconnects instead of waiting on it while the link
    stays up."""
    monkeypatch.setattr(core.hub, "NOTICE_TIMEOUT", 0.3)
    fake.host.add("s1")
    tts = StuckSpeech(ending)
    hub = make_hub(tts=tts)

    async def scenario():
        async with serving(core) as port:
            call_id = _call_id()
            wedged = await WedgedPhone.dial(port, fake, call_id)
            call = hub.slot
            line, _ = hub.enqueue_line(call, "hello")
            await asyncio.wait_for(tts.sent.wait(), 5)
            if ending == "cancelled":
                hub.cancel_line(call, line)
                await asyncio.sleep(1.0)  # well past NOTICE_TIMEOUT, before the link starts reading again
            await asyncio.to_thread(line.done.wait, 5)
            code, messages = await wedged.read_until_closed()
            wedged.abort()
            back = await Phone.dial(port, fake, call_id=call_id)
            after = await say_line(hub, call, "Back again")
            await back.hang_up()
            return line.result, code, messages, after

    result, code, messages, after = asyncio.run(scenario())
    if ending == "error":
        assert result.status == "failed" and result.message == "Could not speak: ElevenLabs returned HTTP 500."
    else:
        assert result.status == "cancelled"
    assert [m["type"] for m in messages] == ["speech_start"], messages
    assert code == 1011
    assert after.status == "played", after
