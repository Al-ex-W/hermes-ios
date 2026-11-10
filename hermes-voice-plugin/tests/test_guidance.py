"""What the agent is told beyond a call's bare facts (``guidance.py``): what the user did not hear before a call
ended, offered again when the conversation's next call starts."""

from __future__ import annotations

import asyncio

import pytest

from support import PLUGIN_DIR, FakePusher, PacedSpeech, Phone, serving, tool

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
