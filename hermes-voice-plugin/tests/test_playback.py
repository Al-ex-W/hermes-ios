"""Playback feedback: what the phone reports about how a line played (``played {id, playback}``, ``unplayed``,
``replayed``), the notes the agent gets when a line may not have been heard well, how much of a line was heard
when a call ended in the middle of it, and the replay of the last line's audio for a ``start_call`` with the same
text."""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import AsyncIterator, Optional

import pytest

from support import FakePusher, PacedSpeech, Phone, heard_part, say_line, serving, tool, until

FINE = {"audio_s": 4.0, "played_s": 4.0, "stalls": 0, "stall_s": 0.0, "rebuilds": 0, "route_changes": 0,
        "route": "speaker", "volume": 0.6, "level_db": -21.5, "gain_db": 0.0}
STALLED = {**FINE, "stalls": 2, "stall_s": 1.8}
STALL_NOTE = ("Your last line may not have been heard well: playback stalled twice (1.8 s of gaps). If it "
              "mattered, say it again shorter and plainer.")
LONG = " ".join(["word"] * 40)


def _ring_log(tmp_path: Path) -> list[dict]:
    path = tmp_path / "hermes-voice" / "rings.jsonl"
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []


# ── the facts ──────────────────────────────────────────────────────────────────────────────────────────────


def test_a_played_ack_without_facts_is_an_app_from_before_them(core):
    parse = core.guidance.Playback.parse
    assert parse(None) is None and parse("fine") is None and parse([1]) is None
    assert core.guidance.playback_note(None) == ""


def test_the_facts_are_read_field_by_field_and_bounded(core):
    parse = core.guidance.Playback.parse
    facts = parse(FINE)
    assert (facts.ended, facts.audio_s, facts.played_s, facts.route, facts.volume) == ("played", 4.0, 4.0, "speaker", 0.6)
    assert (facts.stalls, facts.stall_s, facts.rebuilds, facts.route_changes) == (0, 0.0, 0, 0)
    assert (facts.level_db, facts.gain_db) == (-21.5, 0.0)
    # Every field is optional; what isn't a sane number is left out, never trusted.
    empty = parse({})
    assert empty.audio_s is None and empty.played_s is None and empty.volume is None and empty.route == ""
    assert empty.problems() == []
    odd = parse({"audio_s": "4", "played_s": float("nan"), "stalls": True, "stall_s": -3, "volume": 7,
                 "route": "Submarine", "rebuilds": 2.9, "level_db": 12, "extra": {"x": 1}})
    assert odd.audio_s is None and odd.played_s is None and odd.stalls == 0 and odd.stall_s == 0.0
    assert odd.volume == 1.0 and odd.route == "other" and odd.rebuilds == 2 and odd.level_db == 0.0
    assert parse({"audio_s": 1e9}).audio_s == 900.0
    # How the line ended comes from the message (``unplayed {reason}``); an unknown reason counts as lost.
    assert parse({}, "hang_up").ended == "hang_up" and parse({}, "exploded").ended == "lost"
    assert parse({}, None).ended == "lost"


def test_fine_playback_adds_nothing(core):
    note = core.guidance.playback_note
    parse = core.guidance.Playback.parse
    assert note(parse(FINE)) == ""
    # Under every threshold: a short hiccup, a volume three steps up, nearly all of it played.
    assert note(parse({**FINE, "stalls": 2, "stall_s": 0.49})) == ""
    assert note(parse({**FINE, "volume": 0.19})) == ""
    assert note(parse({**FINE, "played_s": 3.1})) == ""
    assert note(parse({"route": "bluetooth"})) == ""


def test_each_problem_has_its_threshold_and_its_note(core):
    guidance = core.guidance
    note, parse = guidance.playback_note, guidance.Playback.parse
    again = "If it mattered, say it again shorter and plainer."
    assert (guidance.STALL_NOTE_S, guidance.STALL_NOTE_COUNT, guidance.LOW_VOLUME, guidance.MISSING_NOTE_S) == (
        0.5, 3, 0.13, 1.0)
    # Stalls: the gaps add up to half a second, or there were three of them.
    assert note(parse(STALLED)) == STALL_NOTE
    assert note(parse({**FINE, "stalls": 1, "stall_s": 0.5})) == (
        f"Your last line may not have been heard well: playback stalled once (0.5 s of gaps). {again}")
    assert note(parse({**FINE, "stalls": 3, "stall_s": 0.3})) == (
        f"Your last line may not have been heard well: playback stalled 3 times (0.3 s of gaps). {again}")
    # The volume: two of iOS' sixteen steps or less.
    assert note(parse({**FINE, "volume": 0.125})) == (
        "Your last line may not have been heard well: the phone's volume is very low. Ask them to turn the volume "
        "up.")
    assert note(parse({**FINE, "volume": 0.125}), volume_told=True) == ""
    # The audio engine restarted under the line, or only its output changed.
    assert note(parse({**FINE, "rebuilds": 1, "route_changes": 1})) == (
        f"Your last line may not have been heard well: the phone's audio restarted while it played. {again}")
    assert note(parse({**FINE, "route_changes": 1})) == (
        f"Your last line may not have been heard well: the phone's audio output changed while it played. {again}")
    # Acknowledged, but a second or more of it never reached the speaker.
    assert note(parse({**FINE, "played_s": 3.0})) == (
        f"Your last line may not have been heard well: part of its audio was not played. {again}")
    # Several at once stay one short sentence.
    assert note(parse({**STALLED, "volume": 0.0})) == (
        "Your last line may not have been heard well: playback stalled twice (1.8 s of gaps); the phone's volume "
        "is very low. If it mattered, say it again shorter and plainer, and ask them to turn the volume up.")
    assert parse({**STALLED, "volume": 0.0, "rebuilds": 1}).problems() == ["stalled", "audio_restarted", "low_volume"]


def test_how_much_was_heard_is_said_in_whole_seconds(core):
    heard = core.guidance.heard_text
    assert heard(2.2, 9.4) == "they heard about 2 of 9 s"
    assert heard(0.0, 9.0) == "they heard none of it" and heard(0.4, 9.0) == "they heard none of it"
    assert heard(8.8, 9.0) == "they heard nearly all of it" and heard(12.0, 9.0) == "they heard nearly all of it"
    assert heard(0.6, 0.7) == "they heard nearly all of it"
    quote = core.guidance.quote_lines
    assert quote(["One.", "", "Two."], ["they heard about 2 of 9 s", "x", ""]) == (
        '"One." (they heard about 2 of 9 s), "Two."')
    assert core.guidance.unheard_note(["One."], ["they heard none of it"]) == (
        ' The user did not hear all of what you were saying when the call ended: "One." (they heard none of it).')


# ── the notes reach the agent ──────────────────────────────────────────────────────────────────────────────


def test_a_stalled_line_is_told_with_the_next_result_once_and_logged_without_its_text(core, fake, make_hub, tmp_path):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            phone.playback = STALLED
            first = await tool(core.tools.start_call, {"text": "The secret number is forty two."})
            await phone.expect("speech_end")
            await until(lambda: not hub.slot.lines)
            phone.playback = FINE
            second = await tool(core.tools.start_call, {"text": "Did you get that?"})
            await phone.expect("speech_end")
            await until(lambda: not hub.slot.lines)
            third = await tool(core.tools.start_call, {"text": "Good."})
            await phone.expect("speech_end")
            await phone.hang_up()
            return first, second, third

    first, second, third = asyncio.run(scenario())
    assert first["status"] == "speaking" and "heard well" not in first["note"]  # it had not played yet
    # In the result for the next line, "your last line" would read as that next line: it is named as the one before.
    assert second["note"] == (
        "Your line is being spoken. What the user says arrives as [Voice] messages; answer them with start_call. "
        "Your line before this one may not have been heard well: playback stalled twice (1.8 s of gaps). If it "
        "mattered, say it again shorter and plainer."), second
    assert "heard well" not in third["note"], third  # told once; the second line played fine
    logged = [entry for entry in _ring_log(tmp_path) if entry["event"] == "playback"]
    assert [entry.get("problems") for entry in logged] == [["stalled"], None, None]
    assert logged[0] == {"at": logged[0]["at"], "event": "playback", "call_id": logged[0]["call_id"],
                         "line": logged[0]["line"], "ended": "played", "audio_s": 4.0, "played_s": 4.0,
                         "volume": 0.6, "level_db": -21.5, "gain_db": 0.0, "stalls": 2, "stall_s": 1.8,
                         "route": "speaker", "problems": ["stalled"]}
    assert "secret" not in json.dumps(_ring_log(tmp_path))


def test_a_stalled_line_is_told_with_the_users_next_turn(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            phone.playback = STALLED
            await hub.injector.wait_for(1)  # [Voice call started]
            await tool(core.tools.start_call, {"text": "Here is the plan."})
            await phone.expect("speech_end")
            await until(lambda: not hub.slot.lines)
            await phone.say("what was that")
            await phone.say("hello?")
            texts = await hub.injector.wait_for(3)
            await phone.hang_up()
            return texts

    texts = asyncio.run(scenario())
    hint = core.inject.REPLY_HINT
    assert texts[1] == f"[Voice] what was that {hint} (HermesVoice playback note, not the user's words: {STALL_NOTE})"
    assert texts[2] == f"[Voice] hello? {hint}"  # once


def test_a_sync_result_carries_the_note_about_its_own_line(core, fake, make_hub):
    fake.host.add("s1")
    make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            phone.playback = {**FINE, "volume": 0.06}
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Tea or coffee?", "mode": "sync"}))
            await phone.expect("speech_end")
            await asyncio.sleep(0.1)
            await phone.say("Sorry?")
            first = await asyncio.wait_for(pending, 5)
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Tea, or coffee?", "mode": "sync"}))
            await phone.expect("speech_end")
            await asyncio.sleep(0.1)
            await phone.say("Tea.")
            second = await asyncio.wait_for(pending, 5)
            await phone.hang_up()
            return first, second

    first, second = asyncio.run(scenario())
    assert first["said"] == "Sorry?" and first["outcome"] == "answered"
    assert first["note"] == ("Your last line may not have been heard well: the phone's volume is very low. Ask them "
                             "to turn the volume up.")
    # The volume is still as low, and the agent was told: once per call.
    assert second["said"] == "Tea." and "note" not in second, second


def test_a_note_about_a_line_the_agent_has_spoken_past_names_it_as_an_earlier_one(core, fake, make_hub):
    """A sync line that played fine must not be blamed for the stall of the async line before it."""
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            phone.playback = STALLED
            await hub.injector.wait_for(1)
            # Queued behind each other: the async result for the question comes before the first line has played.
            first = await tool(core.tools.start_call, {"text": "The parcel arrives on Tuesday."})
            await phone.expect("speech_end")
            await until(lambda: hub.slot.remarks)
            phone.playback = FINE
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Shall I confirm?", "mode": "sync"}))
            await phone.expect("speech_end")
            await asyncio.sleep(0.1)
            await phone.say("Yes.")
            reply = await asyncio.wait_for(pending, 5)
            await phone.hang_up()
            return first, reply

    first, reply = asyncio.run(scenario())
    assert "heard well" not in first["note"]
    assert reply["said"] == "Yes." and reply["note"] == (
        "An earlier line of yours may not have been heard well: playback stalled twice (1.8 s of gaps). If it "
        "mattered, say it again shorter and plainer."), reply
    about = core.guidance.about_line
    assert about("The user replayed your last line on their phone: x.", earlier=True) == (
        "The user replayed an earlier line of yours on their phone: x.")
    assert about(STALL_NOTE) == STALL_NOTE


@pytest.mark.parametrize("playback", [None, FINE])
def test_fine_playback_and_an_app_without_facts_change_nothing(core, fake, make_hub, tmp_path, playback):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            phone.playback = playback
            await hub.injector.wait_for(1)
            first = await tool(core.tools.start_call, {"text": "One."})
            await phone.expect("speech_end")
            await until(lambda: not hub.slot.lines)
            second = await tool(core.tools.start_call, {"text": "Two."})
            await phone.expect("speech_end")
            await until(lambda: not hub.slot.lines)
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Three?", "mode": "sync"}))
            await phone.expect("speech_end")
            await asyncio.sleep(0.1)
            await phone.say("Yes.")
            third = await asyncio.wait_for(pending, 5)
            await phone.say("And more.")
            texts = await hub.injector.wait_for(2)
            await phone.hang_up()
            return first, second, third, texts

    first, second, third, texts = asyncio.run(scenario())
    plain = "Your line is being spoken. What the user says arrives as [Voice] messages; answer them with start_call."
    assert first["note"] == plain and second["note"] == plain
    assert third == {"said": "Yes.", "ending": "end_of_speech", "outcome": "answered", "call_id": third["call_id"]}
    assert texts[1] == f"[Voice] And more. {core.inject.REPLY_HINT}"
    logged = [entry for entry in _ring_log(tmp_path) if entry["event"] == "playback"]
    assert len(logged) == (0 if playback is None else 3)  # the facts are logged; an old app has none


def test_a_line_the_phone_could_not_play_is_told_at_once_instead_of_after_the_margin(core, fake, make_hub, tmp_path):
    """``unplayed {reason: "lost"}``: the line's audio never all reached the speaker. The line stops waiting for an
    ack (it used to wait out PLAYBACK_MARGIN in silence), and the agent hears about it."""
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            call = hub.slot
            line, _ = hub.enqueue_line(call, "Four words of speech")
            end = await phone.expect("speech_end")
            await phone.send({"type": "unplayed", "id": end["id"], "reason": "lost",
                              "playback": {"audio_s": 0.4, "played_s": 0.0, "rebuilds": 1}})
            await asyncio.wait_for(asyncio.to_thread(line.done.wait, 5), 6)
            after = await tool(core.tools.start_call, {"text": "Again."})
            await phone.hang_up()
            return line.result, after

    result, after = asyncio.run(scenario())
    assert result.status == "unconfirmed"
    assert after["note"].endswith(" Your line before this one was not played to the end on the phone (they heard "
                                  "none of it). If it mattered, say it again."), after
    logged = [entry for entry in _ring_log(tmp_path) if entry["event"] == "playback"]
    assert [(entry["ended"], entry["played_s"], entry["rebuilds"]) for entry in logged] == [("lost", 0.0, 1)]


def test_a_line_the_phone_never_confirms_is_told_too(core, fake, make_hub, monkeypatch):
    monkeypatch.setattr(core.hub, "PLAYBACK_MARGIN", 0.2)
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            await hub.injector.wait_for(1)
            result = await say_line(hub, hub.slot, "Hello?")
            await phone.say("what")
            texts = await hub.injector.wait_for(2)
            await phone.hang_up()
            return result, texts

    result, texts = asyncio.run(scenario())
    assert result.status == "unconfirmed"
    assert texts[1] == (f"[Voice] what {core.inject.REPLY_HINT} (HermesVoice playback note, not the user's words: "
                        "Your last line may not have been heard: the phone did not confirm it played it. If it "
                        "mattered, say it again.)")


def test_the_user_replaying_the_last_line_is_told_with_the_next_result(core, fake, make_hub, tmp_path):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            phone.playback = FINE
            await tool(core.tools.start_call, {"text": "The meeting moved to three."})
            end = await phone.expect("speech_end")
            await until(lambda: not hub.slot.lines)
            await phone.send({"type": "replayed", "id": end["id"]})
            await phone.send({"type": "replayed", "id": "not an id"})
            await until(lambda: hub.slot.remarks)
            after = await tool(core.tools.start_call, {"text": "Anything else?"})
            later = await tool(core.tools.start_call, {"text": "Okay."})
            await phone.hang_up()
            return end["id"], after, later

    line_id, after, later = asyncio.run(scenario())
    note = "The user replayed your line before this one on their phone: say important things shorter and plainer."
    assert after["note"].endswith(f" {note}") and after["note"].count(note) == 1, after
    assert core.guidance.REPLAYED_BY_USER == (
        "The user replayed your last line on their phone: say important things shorter and plainer.")  # with a turn
    assert "replayed" not in later["note"]
    replays = [entry for entry in _ring_log(tmp_path) if entry["event"] == "replayed"]
    assert [entry.get("line") for entry in replays] == [line_id, None]


# ── how much was heard when a call ended mid-line ──────────────────────────────────────────────────────────


def test_a_hang_up_says_how_much_of_the_line_the_phone_played(core, fake, make_hub, tmp_path):
    fake.host.add("s1")
    hub = make_hub(tts=PacedSpeech(delay=0.05))

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            await hub.injector.wait_for(1)
            await tool(core.tools.start_call, {"text": LONG})
            start = await phone.expect("speech_start")
            await asyncio.wait_for(phone.heard_audio.wait(), 5)
            # The app reports the line it was playing, then says bye.
            await phone.send({"type": "unplayed", "id": start["id"], "reason": "hang_up",
                              "playback": {"audio_s": 2.6, "played_s": 2.2, "route": "receiver", "volume": 0.5}})
            await phone.hang_up()
            return await hub.injector.wait_for(2)

    texts = asyncio.run(scenario())
    # The phone played 2.2 s. Not all of the line's audio was made yet, so its length is the estimate from its text
    # (199 characters at 15 a second).
    assert f'when the call ended: "{LONG}" (they heard about 2 of 13 s). The user can\'t hear' in texts[1], texts[1]
    logged = [entry for entry in _ring_log(tmp_path) if entry["event"] == "playback"]
    assert [(entry["ended"], entry["played_s"], entry["route"]) for entry in logged] == [("hang_up", 2.2, "receiver")]


def test_a_sync_call_hung_up_mid_line_says_how_much_was_heard(core, fake, make_hub):
    fake.host.add("s1")
    make_hub()  # all four seconds of audio go out at once

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": LONG, "mode": "sync"}))
            end = await phone.expect("speech_end")
            await phone.send({"type": "unplayed", "id": end["id"], "reason": "hang_up",
                              "playback": {"audio_s": 4.0, "played_s": 3.9}})
            await phone.hang_up()
            return await asyncio.wait_for(pending, 5)

    result = asyncio.run(scenario())
    assert result["outcome"] == "ended_by_user"
    assert f'when the call ended: "{LONG}" (they heard nearly all of it). The user can\'t hear' in result["note"]


def test_without_facts_from_the_phone_the_hosts_clock_says_how_much_was_heard(core, fake, make_hub):
    """An app from before the facts, or a call that drops: the line's audio started going out at a known time."""
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            await hub.injector.wait_for(1)
            await tool(core.tools.start_call, {"text": LONG})
            await tool(core.tools.start_call, {"text": "And one more thing."})
            await phone.expect("speech_end")
            await until(lambda: hub.slot.lines[0].streamed)
            hub.slot.lines[0].audio_at -= 2.2  # as if 2.2 s of it had played by now
            await phone.hang_up()
            return await hub.injector.wait_for(2)

    texts = asyncio.run(scenario())
    assert (f'when the call ended: "{LONG}" (they heard about 2 of 4 s), "And one more thing." (they heard none of '
            "it). The user can't hear") in texts[1], texts[1]


@pytest.mark.parametrize("mode", ["async", "sync"])
def test_a_line_the_link_dropped_under_says_how_much_was_heard(core, fake, make_hub, monkeypatch, mode):
    """The link goes away mid-line and doesn't come back in time: the line's own notice (async) or result (sync)
    says how much of it had played when the link went, not when the hub gave up waiting for a reconnect."""
    monkeypatch.setattr(core.hub, "RECONNECT_GRACE", 0.3)
    fake.host.add("s1")
    more = asyncio.Event()

    class Halting:
        """Three seconds of the line's audio at once; the rest when the test says so."""

        async def stream(self, text: str, voice_id: Optional[str] = None) -> AsyncIterator[bytes]:
            for _ in range(30):
                yield b"\x00\x00" * 2400
            await more.wait()
            yield b"\x00\x00" * 2400

    hub = make_hub(tts=Halting())

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            await hub.injector.wait_for(1)
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": LONG, "mode": mode}))
            call = hub.slot
            await until(lambda: call.lines and call.lines[0].audio_s >= 3.0)
            call.lines[0].audio_at -= 2.0  # as if two seconds of it had played
            await phone.socket.close()  # no bye
            await until(lambda: call.dropped_at is not None)
            await asyncio.sleep(0.5)  # the hub notices only with the next frame: that wait must not count as heard
            more.set()
            result = await asyncio.wait_for(pending, 5)
            texts = await hub.injector.wait_for(2) if mode == "async" else []
            return result, texts

    result, texts = asyncio.run(scenario())
    said = ("The phone lost its connection while this line was being spoken, so the user may not have heard all of it "
            "(they heard about 2 of 13 s). The phone reconnects by itself: say it again with start_call on the next "
            "[Voice] message.")
    if mode == "sync":
        assert result["outcome"] == "answered" and result["said"] == "" and result["note"] == said, result
    else:
        assert texts[1] == (f"[Voice line not delivered: {said}] Automated notice from HermesVoice, not something "
                            "the user said. It is about that one line only and is not a preference, so don't store "
                            "it."), texts[1]


# ── the same text again replays the audio that was kept ────────────────────────────────────────────────────


class _Voice:
    """A voice whose audio is different every time it is asked, so a replay can be told from a new request."""

    def __init__(self) -> None:
        self.requests: list[str] = []

    async def stream(self, text: str, voice_id: Optional[str] = None) -> AsyncIterator[bytes]:
        self.requests.append(text)
        mark = len(self.requests)
        for _ in text.split():
            yield bytes([mark, 0x5A]) * 2400


class _Listener(Phone):
    """A phone that keeps the audio of each line it gets."""

    async def lines(self, count: int) -> list[bytes]:
        heard: list[bytes] = []
        for _ in range(count):
            await self.expect("speech_end")
            heard.append(self.frames)
            self.frames = b""
        return heard

    async def _read(self) -> None:
        self.frames = b""
        try:
            async for frame in self.socket:
                if isinstance(frame, bytes):
                    self.frames += frame
                    continue
                message = json.loads(frame)
                self.messages.append(message)
                if message["type"] == "speech_end":
                    await self.socket.send(json.dumps({"type": "played", "id": message["id"]}))
                await self.inbox.put(message)
        except Exception:  # noqa: BLE001 - the socket closed
            pass


def test_the_same_text_again_replays_the_kept_audio(core, fake, make_hub):
    fake.host.add("s1")
    voice = _Voice()
    hub = make_hub(tts=voice)

    async def scenario():
        async with serving(core) as port:
            phone = await _Listener.dial(port, fake)
            first = await tool(core.tools.start_call, {"text": "Turn left at the bakery."})
            heard = await phone.lines(1)
            await until(lambda: not hub.slot.lines)
            again = await tool(core.tools.start_call, {"text": "Turn left at the bakery."})
            heard += await phone.lines(1)
            await until(lambda: not hub.slot.lines)
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Turn left at the bakery.",
                                                                       "mode": "sync"}))
            heard += await phone.lines(1)
            await asyncio.sleep(0.1)
            await phone.say("Got it.")
            sync = await asyncio.wait_for(pending, 5)
            kept = hub.slot.kept
            await phone.hang_up()
            return first, again, sync, heard, kept, phone.kinds()

    first, again, sync, heard, kept, kinds = asyncio.run(scenario())
    assert voice.requests == ["Turn left at the bakery."]  # asked once; the other two are the kept audio
    assert heard[0] == heard[1] == heard[2] == kept.audio and len(heard[0]) == 5 * 4800
    replay = (" Same text as your last line, so the audio kept from it is replayed (no new speech). To be "
              "understood better, say it shorter and plainer instead.")
    assert "replayed" not in first["note"]
    assert again["status"] == "speaking" and again["note"].endswith(replay), again
    assert sync["said"] == "Got it." and sync["note"] == replay.strip(), sync
    # To the phone a replay is a line like any other: the mic pauses for it and it is acknowledged.
    assert kinds == ["speech_start", "speech_end"] * 3


def test_a_different_line_in_between_is_a_miss(core, fake, make_hub):
    fake.host.add("s1")
    voice = _Voice()
    hub = make_hub(tts=voice)

    async def say(phone: _Listener, text: str) -> tuple[dict, bytes]:
        result = await tool(core.tools.start_call, {"text": text})
        audio = (await phone.lines(1))[0]
        await until(lambda: not hub.slot.lines)
        return result, audio

    async def scenario():
        async with serving(core) as port:
            phone = await _Listener.dial(port, fake)
            results = [await say(phone, text) for text in ("One fish.", "Two fish.", "One fish.", "one fish.")]
            # Queued behind another line, the same text is not "the last spoken line" when it is its turn.
            last = await tool(core.tools.start_call, {"text": "Red fish."})
            queued = await tool(core.tools.start_call, {"text": "one fish."})
            await phone.lines(2)
            await phone.hang_up()
            return results, last, queued

    results, last, queued = asyncio.run(scenario())
    assert voice.requests == ["One fish.", "Two fish.", "One fish.", "one fish.", "Red fish.", "one fish."]
    assert all("replayed" not in result["note"] for result, _ in results), results
    assert results[0][1] != results[2][1]  # made anew
    assert "replayed" not in last["note"] and "replayed" not in queued["note"]


def test_another_voice_or_model_is_a_miss(core, fake, make_hub):
    fake.host.add("s1")
    voice = _Voice()
    settings = [core.config.Settings(fake_tts=True, ring_timeout_s=10.0, sync_reply_timeout_s=30.0)]
    hub = make_hub(tts=voice)
    hub.settings = lambda: settings[0]

    async def scenario():
        async with serving(core) as port:
            phone = await _Listener.dial(port, fake)
            await tool(core.tools.start_call, {"text": "Hello there."})
            await phone.lines(1)
            await until(lambda: not hub.slot.lines)
            settings[0] = core.config.Settings(fake_tts=True, ring_timeout_s=10.0, sync_reply_timeout_s=30.0,
                                               model_id="eleven_v3")
            other = await tool(core.tools.start_call, {"text": "Hello there."})
            await phone.lines(1)
            await phone.hang_up()
            return other

    other = asyncio.run(scenario())
    assert voice.requests == ["Hello there.", "Hello there."] and "replayed" not in other["note"]


def test_the_kept_audio_goes_with_the_call_and_never_touches_the_disk(core, fake, make_hub, tmp_path):
    fake.host.add("s1")
    voice = _Voice()
    hub = make_hub(tts=voice)

    async def scenario():
        async with serving(core) as port:
            phone = await _Listener.dial(port, fake)
            await tool(core.tools.start_call, {"text": "Remember the milk."})
            await phone.lines(1)
            await until(lambda: not hub.slot.lines)
            call = hub.slot
            kept = call.kept
            on_disk = [path for path in tmp_path.rglob("*") if path.is_file()]
            await phone.hang_up()
            await until(lambda: call.state == "ended")
            after_call = call.kept
            # The next call in the conversation starts with nothing kept.
            phone = await _Listener.dial(port, fake)
            again = await tool(core.tools.start_call, {"text": "Remember the milk."})
            await phone.lines(1)
            await phone.hang_up()
            return kept, on_disk, after_call, again

    kept, on_disk, after_call, again = asyncio.run(scenario())
    assert kept.text == "Remember the milk." and len(kept.audio) == 3 * 4800
    assert after_call is None
    assert voice.requests == ["Remember the milk.", "Remember the milk."] and "replayed" not in again["note"]
    # Only the plugin's small text files are on disk; none of them holds audio.
    assert on_disk and all(path.stat().st_size < 4000 for path in on_disk), on_disk
    assert not any(b"\x01\x5a\x01\x5a" in path.read_bytes() for path in on_disk)


def test_a_line_too_long_to_keep_is_made_again(core, fake, make_hub, monkeypatch):
    monkeypatch.setattr(core.hub, "KEPT_AUDIO_LIMIT", 9000)
    fake.host.add("s1")
    voice = _Voice()
    hub = make_hub(tts=voice)

    async def scenario():
        async with serving(core) as port:
            phone = await _Listener.dial(port, fake)
            await tool(core.tools.start_call, {"text": "Three short words"})
            await phone.lines(1)
            await until(lambda: not hub.slot.lines)
            kept = hub.slot.kept
            await tool(core.tools.start_call, {"text": "Three short words"})
            await phone.lines(1)
            await phone.hang_up()
            return kept

    assert asyncio.run(scenario()) is None
    assert len(voice.requests) == 2


# ── what the agent is told to do ───────────────────────────────────────────────────────────────────────────


def test_the_skill_and_the_readme_explain_the_notes_and_the_replay(core):
    from support import PLUGIN_DIR
    skill = " ".join((PLUGIN_DIR / "skills" / "voice-calls" / "SKILL.md").read_text(encoding="utf-8").split())
    for needed in ("Your last line may not have been heard well", "shorter and plainer", "without quiet tags",
                   "their audio is breaking up", "the speaker", "The user replayed your last line",
                   "Same text as your last line", "they heard about 2 of 9 s"):
        assert needed in skill, needed
    readme = " ".join((PLUGIN_DIR / "README.md").read_text(encoding="utf-8").split())
    for needed in ("played {id, playback?}", "unplayed {id, reason, playback?}", "replayed {id}", "audio_s",
                   "played_s", "stall_s", "route_changes", "level_db", "0.5 s", "0.13",
                   core.inject.PLAYBACK_NOTE_HEAD):
        assert needed in readme, needed
