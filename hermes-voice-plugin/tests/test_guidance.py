"""What the agent is told beyond a call's bare facts (``guidance.py``): what the user did not hear before a call
ended, offered again when the conversation's next call starts."""

from __future__ import annotations

import asyncio
import json
import sys
import types

import httpx
import pytest

from support import PLUGIN_DIR, FakePusher, PacedSpeech, Phone, serving, tool, until

LONG = " ".join(["word"] * 40)
REMINDER = (f' On the last call in this conversation the user did not hear all of this: "{LONG}". Offer it first, '
            "unless they have had it since.")


async def _answer(port: int, fake, pusher: FakePusher, auto_ack: bool = True) -> Phone:
    await asyncio.to_thread(pusher.pushed.wait, 5)
    payload = pusher.payloads[-1]
    pusher.pushed.clear()
    phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push",
                             session_id=payload["session_id"], auto_ack=auto_ack)
    await phone.send({"type": "ringing"})
    await phone.send({"type": "answered"})
    return phone


async def _hang_up_mid_line(core, hub, port, fake, pusher, mode: str = "async") -> dict:
    """A call the agent starts, hung up while its (long) line is still playing. Returns start_call's result."""
    pending = asyncio.create_task(tool(core.tools.start_call, {"text": LONG, "mode": mode}))
    phone = await _answer(port, fake, pusher)
    await asyncio.wait_for(phone.heard_audio.wait(), 5)
    await phone.hang_up()
    return await asyncio.wait_for(pending, 5)


# ── missed speech ──────────────────────────────────────────────────────────────────────────────────────────


def test_what_was_not_heard_is_offered_once_when_the_agent_calls_again(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, tts=PacedSpeech(delay=0.05))

    async def scenario():
        async with serving(core) as port:
            await _hang_up_mid_line(core, hub, port, fake, pusher)
            notice = (await hub.injector.wait_for(1))[0]
            again = await tool(core.tools.start_call, {"text": "Me again."})
            more = await tool(core.tools.start_call, {"text": "One more thing."})
            phone = await _answer(port, fake, pusher)
            await phone.expect("speech_end")
            await phone.expect("speech_end")
            await phone.hang_up()
            later = await hub.injector.wait_for(2)
            third = await tool(core.tools.start_call, {"text": "Hello again."})
            return notice, again, more, later[1], third

    notice, again, more, ended, third = asyncio.run(scenario())
    assert notice.startswith("[Voice call ended by user] ") and f'when the call ended: "{LONG}".' in notice
    assert again["status"] == "ringing" and again["note"].endswith(REMINDER), again
    assert "did not hear" not in more["note"]  # once per call
    # They heard both lines of the second call out: nothing to say about it, and nothing left for a third call.
    assert "did not hear" not in ended and "did not hear" not in third["note"]


def test_what_was_not_heard_comes_with_the_notice_of_the_users_next_call(core, fake, make_hub):
    fake.host.add("s1")
    fake.host.add("s2")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, tts=PacedSpeech(delay=0.05))

    async def scenario():
        async with serving(core) as port:
            await _hang_up_mid_line(core, hub, port, fake, pusher)
            await hub.injector.wait_for(1)
            other = await Phone.dial(port, fake, session_id="s2")  # another conversation's call: not its business
            await other.hang_up()
            await hub.injector.wait_for(3)
            back = await Phone.dial(port, fake, session_id="s1")
            await back.hang_up()
            await hub.injector.wait_for(5)
            last = await Phone.dial(port, fake, session_id="s1")
            await last.hang_up()
            return await hub.injector.wait_for(7)

    texts = asyncio.run(scenario())
    started = [text for text in texts if text.startswith("[Voice call started]")]
    assert len(started) == 3
    assert "did not hear" not in started[0]
    assert started[1].endswith(REMINDER)
    assert "did not hear" not in started[2]  # reminded once


def test_a_sync_call_says_what_was_not_heard_and_the_next_one_reminds_with_the_reply(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, tts=PacedSpeech(delay=0.05))

    async def scenario():
        async with serving(core) as port:
            first = await _hang_up_mid_line(core, hub, port, fake, pusher, mode="sync")
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Got a minute?", "mode": "sync"}))
            phone = await _answer(port, fake, pusher)
            await phone.expect("speech_end")
            await asyncio.sleep(0.1)
            await phone.say("Yes, go on.")
            second = await asyncio.wait_for(pending, 5)
            await phone.hang_up()
            return first, second, await hub.injector.wait_for(1)

    first, second, texts = asyncio.run(scenario())
    assert first["outcome"] == "ended_by_user" and first["said"] == ""
    assert first["note"] == (
        "The user hung up. This is about this call only and is not a preference, so don't store it. The user did "
        f'not hear all of what you were saying when the call ended: "{LONG}". The user can\'t hear you now and is '
        "probably not reading this chat. Finish the task you were given, then reply once in text with a short "
        "recap; if you were waiting for an answer, say what you still need. Don't ring back unless the user asked "
        "in this conversation to be called when you're done. When they next call or ask for a call, speak as usual "
        "and first offer anything they missed.")
    assert second["said"] == "Yes, go on." and second["outcome"] == "answered"
    assert second["note"] == REMINDER.strip()
    # The first hang-up was the sync result's to tell; the second (nobody waiting, all heard) is a plain notice.
    assert len(texts) == 1 and texts[0].startswith("[Voice call ended by user]") and "did not hear" not in texts[0]


def test_a_reminder_for_a_call_nobody_answered_is_kept_for_the_next_one(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, tts=PacedSpeech(delay=0.05), ring_timeout_s=0.4)

    async def scenario():
        async with serving(core) as port:
            await _hang_up_mid_line(core, hub, port, fake, pusher)
            await hub.injector.wait_for(1)
            unanswered = await tool(core.tools.start_call, {"text": "Me again."})
            await hub.injector.wait_for(2)  # it rang out
            return unanswered, await tool(core.tools.start_call, {"text": "Third time lucky."})

    unanswered, third = asyncio.run(scenario())
    assert unanswered["note"].endswith(REMINDER)
    assert third["note"].endswith(REMINDER)  # the user never got the offer: remind again


@pytest.mark.parametrize("outcome", ["no_answer", "ended_by_agent"])
def test_only_a_call_the_user_left_mid_line_leaves_something_to_offer(core, fake, make_hub, outcome):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, tts=PacedSpeech(delay=0.05), ring_timeout_s=0.4)

    async def scenario():
        async with serving(core) as port:
            await tool(core.tools.start_call, {"text": LONG})
            if outcome == "ended_by_agent":
                phone = await _answer(port, fake, pusher)
                await asyncio.wait_for(phone.heard_audio.wait(), 5)
                await tool(core.tools.end_call, {})
            else:
                await hub.injector.wait_for(1)  # rang out
            return await tool(core.tools.start_call, {"text": "Again."})

    again = asyncio.run(scenario())
    assert "did not hear" not in again["note"], again


def test_a_hung_up_turn_is_followed_by_the_notice_when_a_line_went_unheard(core, fake, make_hub):
    """The "[Voice, hung up] …" turn says the call is over, so the ended notice normally stays away; it still comes
    when the user missed a line, because only it says which."""
    fake.host.add("s1")
    hub = make_hub(tts=PacedSpeech(delay=0.05))

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            await hub.injector.wait_for(1)  # [Voice call started]
            await tool(core.tools.start_call, {"text": LONG})
            await asyncio.wait_for(phone.heard_audio.wait(), 5)
            await phone.say("never mind I", ending="hang_up")
            await phone.hang_up()
            return await hub.injector.wait_for(3)

    texts = asyncio.run(scenario())
    assert texts[1] == f"[Voice, hung up] never mind I {core.inject.HUNG_UP_HINT}"
    assert texts[2].startswith("[Voice call ended by user] ") and f'when the call ended: "{LONG}".' in texts[2]


def test_missed_speech_is_kept_in_memory_only_and_not_for_ever(core, fake, make_hub, monkeypatch):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, tts=PacedSpeech(delay=0.05))

    async def scenario():
        async with serving(core) as port:
            await _hang_up_mid_line(core, hub, port, fake, pusher)
            await hub.injector.wait_for(1)

    asyncio.run(scenario())
    assert [entry[1] for entry in hub.missed.entries] == [[LONG]]
    on_disk = [path for path in fake.home.rglob("*") if path.is_file() and "word word" in path.read_text("utf-8")]
    assert on_disk == []  # the ring log names the call and its outcome, never what was said
    # A day later it is no longer worth offering.
    moment = core.guidance.time.time()
    monkeypatch.setattr(core.guidance.time, "time", lambda: moment + core.guidance.Missed.KEEP_S + 1)
    assert hub.missed.take(lambda owner: True) == [] and hub.missed.entries == []


def test_the_missed_store_keeps_each_conversations_lines_apart(core):
    missed = core.guidance.Missed()
    a, b = object(), object()
    missed.note(a, ["one"])
    missed.note(b, ["two"])
    missed.note(a, ["three", " "])
    missed.note(b, [])
    assert missed.take(lambda owner: owner is a) == ["one", "three"]
    assert missed.take(lambda owner: owner is a) == []
    assert missed.take(lambda owner: owner is b) == ["two"]
    for index in range(core.guidance.Missed.LIMIT + 5):
        missed.note(object(), [str(index)])
    assert len(missed.entries) == core.guidance.Missed.LIMIT


def test_a_sync_reply_that_ends_in_a_hang_up_says_what_to_do_next(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Shall I book it?", "mode": "sync"}))
            phone = await _answer(port, fake, pusher)
            await phone.expect("speech_end")
            await asyncio.sleep(0.1)
            await phone.say("yes, and", ending="hang_up")
            result = await asyncio.wait_for(pending, 5)
            await phone.hang_up()
            await asyncio.sleep(0.3)
            return result, hub.injector.texts()

    result, texts = asyncio.run(scenario())
    assert (result["said"], result["ending"], result["outcome"]) == ("yes, and", "hang_up", "ended_by_user")
    assert result["note"].startswith("The user hung up. This is about this call only and is not a preference")
    assert "reply once in text with a short recap" in result["note"] and "did not hear" not in result["note"]
    assert texts == []  # the result said it: no notice on top


# ── long lines ─────────────────────────────────────────────────────────────────────────────────────────────

# 330 characters: 22 s at 15 characters a second.
LONG_LINE = ("I looked at all three options and here is the full comparison. " * 6)[:330].strip()
LONG_NOTE = "Long line: about 22 s of speech. Keep lines to a sentence or two and offer details instead."


@pytest.fixture
def through_the_socket(core, fake, make_hub, monkeypatch):
    """A process whose tools reach the hub over its socket (a backend the Desktop app spawned, here): start_call
    goes tools.py -> remote.py -> hubsock.py -> the hub."""
    remote = core.loader.module("remote", PLUGIN_DIR)
    hubsock = core.loader.module("hubsock", PLUGIN_DIR)
    monkeypatch.setattr(remote, "TURNS", core.inject.Turns(late=remote._late_delivery))
    monkeypatch.setattr(remote, "_contexts", [])
    monkeypatch.setattr(remote, "_subscriptions", {})
    monkeypatch.setattr(remote, "_user_turn_at", {})
    servers = []

    def start(**hub_kw):
        hub = make_hub(**hub_kw)
        servers.append(hubsock.HubServer(hub, fake.home / "hermes-voice").start())
        monkeypatch.setitem(sys.modules, "hermes_cli.process_identity",
                            types.SimpleNamespace(is_desktop_owned_backend=lambda: True))
        assert core.hub.routes_mounted() is False
        return hub

    yield start
    for server in servers:
        server.close()


def test_the_estimate_counts_what_is_spoken_at_fifteen_characters_a_second(core):
    guidance = core.guidance
    assert (guidance.CHARS_PER_SECOND, guidance.LONG_LINE_S) == (15.0, 15.0)
    assert guidance.speech_seconds("x" * 150) == 10.0
    assert guidance.long_line_note("x" * 225) == ""  # 15 s: two full sentences, still fine
    assert guidance.long_line_note("x" * 226).strip() == (
        "Long line: about 15 s of speech. Keep lines to a sentence or two and offer details instead.")
    assert guidance.long_line_note(LONG_LINE).strip() == LONG_NOTE
    # Audio tags are directions to the voice, not speech; ordinary brackets around a sentence are speech.
    assert guidance.spoken_chars("[whispers] Hello there. [laughs softly]") == len("Hello there.")
    assert guidance.spoken_chars("  spaced \n out  ") == len("spaced out")
    tagged = "[excited] " + "x" * 220 + " [sighs]"
    assert guidance.long_line_note(tagged) == ""
    bracketed = "[" + "word " * 20 + "]"
    assert guidance.spoken_chars(bracketed) == len(" ".join(bracketed.split()))


@pytest.mark.parametrize("mode", ["async", "sync"])
def test_a_long_line_is_flagged_in_the_result(core, fake, make_hub, mode):
    fake.host.add("s1")
    pusher = FakePusher()
    make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            short = await tool(core.tools.start_call, {"text": "Done. Want the details?"})
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": LONG_LINE, "mode": mode}))
            phone = await _answer(port, fake, pusher)
            await phone.expect("speech_end")
            end = await phone.expect("speech_end")
            await asyncio.sleep(0.1)
            await phone.say("okay")
            result = await asyncio.wait_for(pending, 5)
            await phone.hang_up()
            return short, result, end

    short, result, _ = asyncio.run(scenario())
    assert "Long line" not in short["note"]
    if mode == "async":
        assert result["status"] == "ringing" and result["note"].endswith(LONG_NOTE), result
    else:
        assert result["said"] == "okay" and result["note"] == LONG_NOTE, result


def test_a_long_line_is_flagged_however_a_sync_wait_ends(core, fake, make_hub):
    """The user hanging up on a long line is the moment the note matters most."""
    fake.host.add("s1")
    pusher = FakePusher()
    make_hub(pusher=pusher, tts=PacedSpeech(delay=0.02))

    async def scenario():
        async with serving(core) as port:
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": LONG_LINE, "mode": "sync"}))
            phone = await _answer(port, fake, pusher)
            await asyncio.wait_for(phone.heard_audio.wait(), 5)
            await phone.hang_up()
            return await asyncio.wait_for(pending, 5)

    result = asyncio.run(scenario())
    assert result["outcome"] == "ended_by_user" and result["note"].startswith("The user hung up.")
    assert result["note"].endswith(LONG_NOTE), result


def test_a_cut_line_is_judged_by_what_is_spoken(core, fake, make_hub):
    fake.host.add("s1")
    make_hub(max_chars=300)

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            result = await tool(core.tools.start_call, {"text": "word " * 200})
            await phone.hang_up()
            return result

    note = asyncio.run(scenario())["note"]
    assert "Only the first 299 of 999 characters were spoken; the rest was cut." in note
    assert "text reply" not in note  # the user is listening, not reading
    assert note.endswith("Long line: about 20 s of speech. Keep lines to a sentence or two and offer details instead.")


@pytest.mark.parametrize("mode", ["async", "sync"])
def test_a_long_line_is_flagged_through_the_hub_socket(core, fake, through_the_socket, mode):
    hub = through_the_socket(pusher=FakePusher())
    fake.host.add("s1")
    if mode == "sync":
        fake.interrupt_all = True  # stop the wait at once: only the note matters here
    result = json.loads(core.tools.start_call({"text": LONG_LINE, "mode": mode}, session_id="s1"))
    fake.interrupt_all = False
    assert hub.slot is not None and hub.slot.owner.remote and hub.slot.call_id == result["call_id"]
    if mode == "async":
        assert result["status"] == "ringing" and result["note"].endswith(LONG_NOTE), result
    else:
        # The ring was cut short before the line went out: nothing was said, so nothing is flagged.
        assert result["status"] == "interrupted" and "Long line" not in result["note"], result
    short = json.loads(core.tools.start_call({"text": "Short one."}, session_id="s1"))
    assert "Long line" not in short["note"]
    remote = core.loader.module("remote", PLUGIN_DIR)
    asyncio.run(until(lambda: (sub := remote.subscriptions().get(result["call_id"])) is not None
                      and sub.ready.is_set()))
    json.loads(core.tools.end_call({}, session_id="s1"))


def test_audio_tags_reach_elevenlabs_untouched(core, fake, make_hub):
    """Square-bracket tags are the voice's directions: the plugin passes the text on as written."""
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        bodies.append(json.loads(request.content))
        return httpx.Response(200, content=b"\x00\x00" * 2400)

    settings = core.config.Settings(fake_tts=False, model_id="eleven_v3")
    tts = core.tts.ElevenLabs(lambda: settings, api_key=lambda: "key", transport=httpx.MockTransport(handler))
    fake.host.add("s1")
    make_hub(settings=settings, tts=tts)
    line = "[whispers] It's done. [laughs] Want the details?"

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            result = await tool(core.tools.start_call, {"text": line})
            await phone.expect("speech_end")
            await phone.hang_up()
            return result

    result = asyncio.run(scenario())
    assert bodies == [{"text": line, "model_id": "eleven_v3"}]
    assert "Long line" not in result["note"]


def test_the_skill_and_the_description_say_how_to_speak(core):
    description = core.tools.START_CALL["description"]
    for rule in ("lead with the answer", "two sentences at most", "offer more instead of saying it all",
                 "a progress update is a few words", "never read out codes, long ids, hashes, URLs, file paths, "
                 "issue numbers or exact timestamps", "round numbers", "say it shorter and plainer"):
        assert rule in description, rule
    skill = _skill()
    speaking = " ".join(skill[skill.index("## Speaking well"):skill.index("## When to ring")].split())
    for rule in ("Lead with the answer. Two sentences at most by default", "offer more", "A few words",
                 "never a report", "course code", "long identifiers", "hashes", "URLs", "file paths",
                 "issue numbers", "exact timestamps", "Say the human name", "text recap", "Round them",
                 "shorter and plainer", "Long line: about 22 s of speech", "15 characters a second"):
        assert rule in speaking, rule
    assert "about 15 s of speech" in core.tools.START_CALL["parameters"]["properties"]["text"]["description"]


# ── the guidance the agent reads ───────────────────────────────────────────────────────────────────────────


def _skill() -> str:
    return (PLUGIN_DIR / "skills" / "voice-calls" / "SKILL.md").read_text(encoding="utf-8")


def _readme() -> str:
    return (PLUGIN_DIR / "README.md").read_text(encoding="utf-8")


def test_the_description_and_the_skill_treat_a_hang_up_as_an_event_not_a_preference(core):
    description = core.tools.START_CALL["description"]
    assert '"[Voice call" or "[Voice line" are automated notices about one call' in description
    assert "never a preference to remember" in description
    assert "the user is not reading the chat" in description and "say everything that matters with it" in description
    assert "reply once in text with a short recap" in description and "first offer what they missed" in description
    skill = _skill()
    for text in (description, skill, _readme()):
        assert "Reply in text from now on" not in text
    assert ("Assume the user is not looking at the chat during or right after a call. Say everything that matters "
            "out loud.\nText is for exact identifiers, links and a recap.") in skill
    assert core.inject.NOTICE_MARKER in skill and "## When a call ends" in skill
    assert core.inject.NOTICE_MARKER in _readme()
