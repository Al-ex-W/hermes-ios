"""The call model: ringing, answering, declining, cancelling, turn routing, the call slot, ownership through
compression, outcome notices, the tools' visibility and the plugin's registration."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import sys
import threading
import time
import types
import uuid

import pytest
import websockets

from support import PLUGIN_DIR, PREFIX, FakePusher, Phone, bound_agent, iso, say_line, serving, tool, until


async def _rung(pusher: FakePusher) -> dict:
    await asyncio.to_thread(pusher.pushed.wait, 5)
    return pusher.payloads[-1]


async def _answer(port: int, fake, pusher: FakePusher, auto_ack: bool = True) -> Phone:
    """What the app does on a VoIP push: open the link for the pushed call, ring, answer."""
    payload = await _rung(pusher)
    phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push",
                             session_id=payload["session_id"], auto_ack=auto_ack)
    assert phone.ready["state"] == "ringing"
    await phone.send({"type": "ringing"})
    await phone.send({"type": "answered"})
    return phone


# ── ringing ────────────────────────────────────────────────────────────────────────────────────────────────


def test_start_call_rings_then_speaks_once_answered(core, fake, make_hub):
    fake.host.add("s1", title="Deploy chat")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            started = await tool(core.tools.start_call, {"text": "The deploy finished."})
            payload = await _rung(pusher)
            phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push", session_id="s1")
            await phone.send({"type": "ringing"})
            await asyncio.sleep(0.3)
            silent_while_ringing = list(phone.messages)
            again = await tool(core.tools.start_call, {"text": "Are you there?"})
            await phone.send({"type": "answered"})
            first = await phone.expect("speech_start")
            second = await phone.expect("speech_start")
            await phone.hang_up()
            return started, payload, phone, silent_while_ringing, again, first, second

    started, payload, phone, silent, again, first, second = asyncio.run(scenario())
    assert started["status"] == "ringing" and len(started["call_id"]) == 32
    assert payload == {"call_id": started["call_id"], "session_id": "s1", "profile": "default", "mode": "async",
                       "title": "Deploy chat"}
    assert phone.ready == {"type": "ready", "call_id": started["call_id"], "state": "ringing"}
    assert silent == []  # nothing is spoken before the user answers
    assert again == {"call_id": started["call_id"], "status": "ringing", "note": again["note"]}  # never re-rings
    assert len(pusher.payloads) == 1
    assert (first["text"], second["text"]) == ("The deploy finished.", "Are you there?")


def test_sync_call_returns_the_reply_that_follows_its_line(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Ship it?", "mode": "sync"}))
            phone = await _answer(port, fake, pusher)
            await phone.expect("speech_end")
            await until(lambda: phone.played_at)
            await asyncio.sleep(0.1)
            await phone.say("Yes, ship it.")
            result = await asyncio.wait_for(pending, 5)
            await asyncio.sleep(0.2)
            injected = hub.injector.texts()
            await phone.hang_up()
            return result, injected

    result, injected = asyncio.run(scenario())
    assert result == {"said": "Yes, ship it.", "ending": "end_of_speech", "outcome": "answered",
                      "call_id": result["call_id"]}
    assert fake.waits == 1  # waited inside human_wait_window
    assert fake.beats > 0  # and kept Hermes' inactivity watchdog quiet meanwhile
    assert injected == []  # the waiter took the turn: nothing injected


def test_a_turn_that_started_before_the_line_played_is_injected_not_returned(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            await hub.injector.wait_for(1)  # [Voice call started]
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Which one?", "mode": "sync"}))
            end = await phone.expect("speech_end")
            await phone.say("wait no", ending="cut_off")  # spoken over the line, before it was played
            await hub.injector.wait_for(2)
            await phone.send({"type": "played", "id": end["id"]})
            await asyncio.sleep(0.1)
            await phone.say("the blue one", started_at=iso(offset=-5))  # started long before the ack
            await hub.injector.wait_for(3)
            assert not pending.done()
            await phone.say("the red one")
            result = await asyncio.wait_for(pending, 5)
            await phone.hang_up()
            return result

    result = asyncio.run(scenario())
    assert result["said"] == "the red one" and result["outcome"] == "answered"
    texts = hub.injector.texts()
    assert texts[1] == "[Voice, cut off] wait no (Reply out loud with start_call; your text replies are not spoken.)"
    assert texts[2].startswith("[Voice] the blue one")


def test_turns_of_an_async_call_are_injected_in_order_with_their_endings(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()
    hub.injector.gate = threading.Event()  # hold deliveries: the started notice must still go first

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            await phone.say("hello there")
            await phone.say("", ending="muted")  # silence: nothing to tell
            await phone.say("I could not", ending="provider_error", error="network")
            await phone.say("", ending="provider_error", error="Scribe closed the stream")
            await phone.say("and then I", ending="hang_up")
            await asyncio.sleep(0.3)
            hub.injector.gate.set()
            texts = await hub.injector.wait_for(5)
            await phone.hang_up()
            await asyncio.sleep(0.3)
            return texts, hub.injector.texts()

    texts, after = asyncio.run(scenario())
    hint = "(Reply out loud with start_call; your text replies are not spoken.)"
    assert texts[0].startswith("[Voice call started] The user is calling you")
    assert texts[1:] == [
        f"[Voice] hello there {hint}",
        f"[Voice, speech recognition failed] I could not {hint}",
        f"[Voice, speech recognition failed: Scribe closed the stream] {hint}",
        "[Voice, hung up] and then I (The user hung up, so the call is over; reply in text.)",
    ]
    assert after == texts  # the hung-up turn already said it: no "[Voice call ended by user]" on top


def test_hanging_up_injects_the_ended_notice(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            await phone.hang_up()
            return await hub.injector.wait_for(2), phone.socket.close_code

    texts, code = asyncio.run(scenario())
    assert texts[1].startswith("[Voice call ended by user]")
    assert code == 1000 and hub.slot is None


@pytest.mark.parametrize("mode", ["sync", "async"])
def test_a_declined_call(core, fake, make_hub, mode):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Got a minute?", "mode": mode}))
            payload = await _rung(pusher)
            phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push")
            await phone.send({"type": "declined"})
            code = await phone.closed()
            result = await asyncio.wait_for(pending, 5)
            texts = await hub.injector.wait_for(1) if mode == "async" else hub.injector.texts()
            return result, code, texts, phone

    result, code, texts, phone = asyncio.run(scenario())
    assert code == 1000 and phone.messages == []
    if mode == "sync":
        assert result["outcome"] == "declined" and result["said"] == "" and texts == []
    else:
        assert result["status"] == "ringing"
        assert texts == ["[Voice call not answered] The user didn't take the call (they declined it). Reply in text."]


@pytest.mark.parametrize(("reason", "outcome"), [("no_answer", "no_answer"), ("declined", "declined"),
                                                 (None, "declined")])
def test_a_bye_while_ringing_ends_the_call_by_its_reason(core, fake, make_hub, reason, outcome):
    """The phone's own ring timeout says bye {reason: no_answer}; any other bye while ringing declines."""
    fake.host.add("s1")
    pusher = FakePusher()
    make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Hello?", "mode": "sync"}))
            payload = await _rung(pusher)
            phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push")
            await phone.send({"type": "ringing"})
            await phone.send({"type": "bye", **({"reason": reason} if reason else {})})
            code = await phone.closed()
            return await asyncio.wait_for(pending, 5), code

    result, code = asyncio.run(scenario())
    assert code == 1000 and result["outcome"] == outcome and result["said"] == ""


def test_a_bye_with_an_error_ends_a_live_call_as_lost(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            started = await tool(core.tools.start_call, {"text": "Hi."})
            phone = await _answer(port, fake, pusher)
            await phone.expect("speech_end")
            await phone.send({"type": "bye", "reason": "error"})
            await phone.closed()
            return started, await hub.injector.wait_for(1)

    started, texts = asyncio.run(scenario())
    assert hub.history[started["call_id"]].outcome == "lost"
    assert texts[-1].startswith("[Voice call ended: the phone's connection was lost")


def test_an_unanswered_ring_is_cancelled(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, ring_timeout_s=0.5)

    async def scenario():
        async with serving(core) as port:
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Hello?", "mode": "sync"}))
            payload = await _rung(pusher)
            phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push")
            await phone.send({"type": "ringing"})
            cancel = await phone.expect("cancel")
            code = await phone.closed()
            result = await asyncio.wait_for(pending, 5)
            return cancel, code, result

    cancel, code, result = asyncio.run(scenario())
    assert cancel == {"type": "cancel", "reason": "no_answer"}
    assert code == 1000
    assert result["outcome"] == "no_answer" and "didn't pick up" in result["note"]


def test_a_ring_the_phone_never_picks_up_is_unreachable_and_late_hellos_are_cancelled(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher, ring_timeout_s=0.3)

    async def scenario():
        async with serving(core) as port:
            started = await tool(core.tools.start_call, {"text": "Hello?"})
            texts = await hub.injector.wait_for(1)
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={fake.ticket()}") as ws:
                await ws.send(json.dumps({"type": "hello", "call_id": started["call_id"], "initiated_by": "push"}))
                late = json.loads(await ws.recv())
                await ws.wait_closed()
                return started, texts, late, ws.close_code

    started, texts, late, code = asyncio.run(scenario())
    assert texts == ["[Voice line not delivered: the phone never answered the ring] Reply in text."]
    assert late == {"type": "cancel", "reason": "unreachable"} and code == 1000


@pytest.mark.parametrize("mode", ["sync", "async"])
def test_a_failed_push_is_reported(core, fake, make_hub, mode):
    fake.host.add("s1")
    hub = make_hub(pusher=FakePusher(ok=False, reason="no iPhone has registered for calls yet"))

    async def scenario():
        result = await tool(core.tools.start_call, {"text": "Hi", "mode": mode})
        texts = await hub.injector.wait_for(1) if mode == "async" else hub.injector.texts()
        return result, texts

    result, texts = asyncio.run(scenario())
    assert hub.slot is None
    if mode == "sync":
        assert result["outcome"] == "push_failed" and "no iPhone has registered" in result["note"]
    else:
        assert texts == ["[Voice line not delivered: the phone couldn't be rung (no iPhone has registered for "
                         "calls yet)] Reply in text."]


def test_end_call_cancels_a_ring_and_hangs_up_a_live_call(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher)

    async def scenario():
        async with serving(core) as port:
            await tool(core.tools.start_call, {"text": "Hi"})
            payload = await _rung(pusher)
            ringing = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push")
            ended_ring = await tool(core.tools.end_call, {})
            cancel = await ringing.expect("cancel")
            await ringing.closed()

            pusher.pushed.clear()
            await tool(core.tools.start_call, {"text": "Hi again"})
            live = await _answer(port, fake, pusher)
            await live.expect("speech_end")
            hung_up = await tool(core.tools.end_call, {"text": "Talk later."})
            ended = await live.expect("ended")
            code = await live.closed()
            texts = [m.get("text") for m in live.messages if m["type"] == "speech_start"]
            return ended_ring, cancel, hung_up, ended, code, texts

    ended_ring, cancel, hung_up, ended, code, texts = asyncio.run(scenario())
    assert ended_ring["outcome"] == "ended_by_agent" and cancel == {"type": "cancel", "reason": "ended_by_agent"}
    assert hung_up["outcome"] == "ended_by_agent" and "Spoken to the user" in hung_up["note"]
    assert ended == {"type": "ended", "outcome": "ended_by_agent"} and code == 1000
    assert texts == ["Hi again", "Talk later."]
    assert hub.slot is None and hub.injector.texts() == []


# ── the call slot ──────────────────────────────────────────────────────────────────────────────────────────


def test_one_call_slot_busy_for_others_and_4429_for_another_link(core, fake, make_hub):
    fake.host.add("s1")
    fake.host.add("s2")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="s1", title="Trip planning")
            busy = await tool(core.tools.start_call, {"text": "hi"}, session_id="s2")
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={fake.ticket()}") as ws:
                await ws.send(json.dumps({"type": "hello", "call_id": uuid.uuid4().hex, "session_id": "s2"}))
                await ws.wait_closed()
                code = ws.close_code
            mine = await tool(core.tools.start_call, {"text": "hi"}, session_id="s1")
            await phone.hang_up()
            free = await tool(core.tools.start_call, {"text": "hi"}, session_id="s2")
            return busy, code, mine, free

    busy, code, mine, free = asyncio.run(scenario())
    assert busy["status"] == "busy" and '"Trip planning"' in busy["note"]
    assert code == 4429
    assert mine["status"] == "speaking"
    assert free["status"] == "ringing"  # the slot is free again once the call ended


def test_the_call_follows_its_conversation_through_compression(core, fake, make_hub):
    runtime = fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="s1")
            await hub.injector.wait_for(1)
            fake.host.rotate(runtime, "s1-tip")  # compression: same runtime session, new stored id
            # The tool runs under the new id before any hook saw it: the live runtime ties it to the call.
            spoken = await tool(core.tools.start_call, {"text": "still me"}, session_id="s1-tip")
            assert hub.slot.owner.session_id == "s1-tip"
            fake.host.rotate(runtime, "s1-tip2")
            hub.note_turn_start("s1-tip2", "s1-tip")  # pre_llm_call sees the post-rotation id
            owner = hub.slot.owner.session_id
            busy_elsewhere = await tool(core.tools.start_call, {"text": "x"}, session_id="other")
            await phone.say("did you hear me")
            await hub.injector.wait_for(2)
            await phone.hang_up()
            return spoken, owner, busy_elsewhere

    spoken, owner, busy = asyncio.run(scenario())
    assert spoken["status"] == "speaking"
    assert owner == "s1-tip2"
    assert busy["status"] == "busy"
    assert [sid for sid, _ in hub.injector.delivered][:2] == ["s1", "s1-tip2"]


def test_rekey_by_parent_id_only_outside_subagents(core, fake, make_hub):
    hub = make_hub()
    origin = core.hermes.Origin(session_id="stored-a")
    call = core.hub.Call(hub, uuid.uuid4().hex, core.hub.Owner.from_origin(origin), "agent", "live")
    hub.slot = call
    fake.subagent_parent = bound_agent("child-1", parent="stored-a")
    hub.note_turn_start("child-1", "stored-a")  # a delegated subagent: its parent id is the owner
    assert call.owner.session_id == "stored-a"
    # Hermes binds the main agent itself during its own turns: that is not a subagent.
    fake.subagent_parent = bound_agent("stored-b")
    hub.note_turn_start("stored-b", "stored-a")  # compression continuation
    assert call.owner.session_id == "stored-b" and call.owner.owns("stored-a")
    assert "stored-b" in hub.busy
    hub.note_turn_end("stored-b")
    assert "stored-b" not in hub.busy
    hub.slot = None


def test_a_subagent_speaks_into_its_parents_call(core, fake, make_hub):
    fake.host.add("parent")
    hub = make_hub(settings=core.config.Settings(
        fake_tts=True, policy=core.config.PolicyConfig(allow_subagents=True)))

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="parent")
            fake.subagent_parent = bound_agent("child", parent=bound_agent("helper", parent="parent"))
            result = await tool(core.tools.start_call, {"text": "from the helper"}, session_id="child")
            start = await phone.expect("speech_start")
            fake.subagent_parent = None
            await phone.hang_up()
            return result, start

    result, start = asyncio.run(scenario())
    assert result["status"] == "speaking" and start["text"] == "from the helper"


def test_the_main_agent_bound_for_its_own_turn_is_not_a_subagent(core, fake, make_hub):
    """Hermes binds the agent running the turn as "the subagent parent" in every turn, the main agent's too: only
    an agent with a delegate depth is a subagent (refused by default, its calls belong to the top agent)."""
    fake.host.add("s1")
    pusher = FakePusher()
    make_hub(pusher=pusher)
    fake.subagent_parent = bound_agent("child", parent="s1")
    assert core.hermes.subagent_parent().session_id == "s1"
    origin = core.hermes.origin("child")
    assert origin.is_subagent and origin.session_id == "s1"
    child = asyncio.run(tool(core.tools.start_call, {"text": "Hi", "mode": "sync"}, session_id="child"))
    assert child["outcome"] == "not_allowed" and "main conversation" in child["note"]
    fake.subagent_parent = bound_agent("s1")
    assert core.hermes.subagent_parent() is None and not core.hermes.origin("s1").is_subagent
    main = asyncio.run(tool(core.tools.start_call, {"text": "Hi"}))
    assert main["status"] == "ringing" and pusher.pushed.wait(5) and len(pusher.payloads) == 1
    orphan = bound_agent("child")
    orphan._delegate_depth = 1  # its parent is gone: still a subagent
    fake.subagent_parent = orphan
    assert core.hermes.subagent_parent() is orphan


def test_not_allowed_is_returned_without_ringing(core, fake, make_hub):
    fake.host.add("s1")
    pusher = FakePusher()
    make_hub(pusher=pusher)
    fake.env["HERMES_CRON_SESSION"] = "1"
    result = asyncio.run(tool(core.tools.start_call, {"text": "Report ready", "mode": "sync"}))
    assert result["outcome"] == "not_allowed" and "Scheduled jobs" in result["note"]
    assert pusher.payloads == []


def test_an_interrupted_sync_call_stops_speaking_and_returns(core, fake, make_hub):
    fake.host.add("s1")
    from support import PacedSpeech
    hub = make_hub(tts=PacedSpeech(delay=0.05))

    def interrupt_soon() -> None:
        time.sleep(0.5)
        fake.interrupt_all = True

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            threading.Thread(target=interrupt_soon, daemon=True).start()
            result = await tool(core.tools.start_call, {"text": " ".join(["word"] * 80), "mode": "sync"})
            fake.interrupt_all = False
            end = await phone.expect("speech_end")
            follow = await say_line(hub, hub.slot, "okay")
            await phone.hang_up()
            return result, end, follow

    result, end, follow = asyncio.run(scenario())
    assert result["status"] == "interrupted" and result["call_id"]
    assert end.get("cancelled") is True
    assert follow.status == "played"


# ── visibility and registration ────────────────────────────────────────────────────────────────────────────


def test_the_tools_show_only_where_calls_work(core, fake, monkeypatch):
    assert core.tools.available() is True
    fake.host.turn_isolation = True
    assert core.tools.available() is False
    fake.host.turn_isolation = False
    monkeypatch.setenv("HERMES_COMPUTE_HOST_CHILD", "1")
    assert core.tools.available() is False
    monkeypatch.delenv("HERMES_COMPUTE_HOST_CHILD")
    monkeypatch.setitem(sys.modules, "tui_gateway.server", None)
    assert core.tools.available() is False
    monkeypatch.undo()
    fake.install(monkeypatch)
    monkeypatch.setitem(sys.__dict__, "_hermes_voice_routes_mounted", False)
    assert core.tools.available() is False
    monkeypatch.setitem(sys.__dict__, "_hermes_voice_routes_mounted", True)
    assert core.tools.available() is True
    # The routes are mounted whenever hermes_cli.web_server is imported (a TUI resume that shows an image
    # imports it): only a process whose web server runs (start_server set bound_host) serves the phone.
    fake.bound_host = None
    assert core.tools.available() is False and core.hub.routes_mounted() is False


def test_register_adds_tools_skill_and_hooks(core, fake, make_hub):
    spec = importlib.util.spec_from_file_location("hermes_plugins_hermes_voice", PLUGIN_DIR / "__init__.py",
                                                  submodule_search_locations=[str(PLUGIN_DIR)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = plugin
    spec.loader.exec_module(plugin)

    class Ctx:
        def __init__(self) -> None:
            self.tools, self.skills, self.hooks = {}, {}, {}

        def register_tool(self, name, toolset, schema, handler, check_fn=None, requires_env=None, is_async=False,
                          description="", emoji="", override=False):
            self.tools[name] = dict(toolset=toolset, schema=schema, handler=handler, check_fn=check_fn,
                                    description=description)

        def register_skill(self, name, path, description="", frontmatter=None):
            assert path.exists()
            self.skills[name] = path

        def register_hook(self, name, callback):
            self.hooks[name] = callback

    ctx = Ctx()
    plugin.register(ctx)
    assert set(ctx.tools) == {"start_call", "end_call"}
    for name, entry in ctx.tools.items():
        assert entry["toolset"] == "voice" and entry["schema"]["name"] == name
        assert entry["check_fn"] is core.tools.available and entry["description"] == entry["schema"]["description"]
        assert entry["handler"].__module__ == "hermes_voice_core.tools"  # the one shared copy
    assert ctx.tools["start_call"]["schema"]["parameters"]["required"] == ["text"]
    assert "[Voice]" in ctx.tools["start_call"]["description"]
    assert set(ctx.skills) == {"voice-calls"}
    assert ctx.skills["voice-calls"].read_text().startswith("---\nname: voice-calls\n")
    assert set(ctx.hooks) == {"pre_llm_call", "on_session_end"}

    hub = make_hub()
    origin = core.hermes.Origin(session_id="a")
    hub.slot = core.hub.Call(hub, uuid.uuid4().hex, core.hub.Owner.from_origin(origin), "agent", "live")
    assert ctx.hooks["pre_llm_call"](session_id="b", parent_session_id="a", turn_id="t", model="m") is None
    assert hub.slot.owner.session_id == "b" and "b" in hub.busy
    ctx.hooks["on_session_end"](session_id="b", completed=True)
    assert "b" not in hub.busy
    hub.slot = None


def test_a_sync_call_returns_a_hang_up_without_a_notice_on_top(core, fake, make_hub):
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            await hub.injector.wait_for(1)  # [Voice call started]
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Anything else?", "mode": "sync"}))
            await phone.expect("speech_end")
            await until(lambda: phone.played_at)
            await asyncio.sleep(0.1)
            await phone.say("no that's all", ending="hang_up")
            await phone.hang_up()
            result = await asyncio.wait_for(pending, 5)
            await asyncio.sleep(0.3)
            return result, hub.injector.texts()

    result, texts = asyncio.run(scenario())
    assert (result["said"], result["ending"], result["outcome"]) == ("no that's all", "hang_up", "ended_by_user")
    assert len(texts) == 1 and texts[0].startswith("[Voice call started]"), texts


# ── reply routing ──────────────────────────────────────────────────────────────────────────────────────────


def test_a_reply_kept_through_a_reconnect_is_still_the_reply(core, fake, make_hub):
    """The line played, the link dropped before the ack went out, and the user answered meanwhile. On the next
    link the phone repeats the ack and then sends the reply: the reply started before the plugin saw the ack,
    and is still the one the sync start_call gets."""
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            first = await Phone.dial(port, fake, auto_ack=False)
            await hub.injector.wait_for(1)  # [Voice call started]
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Deploy now?", "mode": "sync"}))
            end = await first.expect("speech_end")
            await first.socket.close()  # dropped: no bye, no ack
            await first.reader
            answered_at = iso()  # the user answers while the link is down; the phone keeps the turn
            await asyncio.sleep(1.5)
            second = await Phone.dial(port, fake, call_id=first.call_id, auto_ack=False)
            await second.send({"type": "played", "id": end["id"]})
            await second.say("yes deploy", started_at=answered_at)
            result = await asyncio.wait_for(pending, 5)
            await asyncio.sleep(0.2)
            injected = hub.injector.texts()
            await second.hang_up()
            return result, injected

    result, injected = asyncio.run(scenario())
    assert (result["said"], result["outcome"]) == ("yes deploy", "answered"), result
    assert len(injected) == 1 and injected[0].startswith("[Voice call started]"), injected


def test_an_unconfirmed_line_takes_a_reply_that_started_after_it_was_heard(core, fake, make_hub, monkeypatch):
    fake.host.add("s1")
    hub = make_hub()
    monkeypatch.setattr(core.hub, "PLAYBACK_MARGIN", 0.5)

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, auto_ack=False)
            await hub.injector.wait_for(1)
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Still there?", "mode": "sync"}))
            await phone.expect("speech_end")
            started = iso(offset=0.3)  # after the 0.2 s line played, within the margin
            await until(lambda: hub.slot.waiter is not None and hub.slot.waiter.line.state == "unconfirmed")
            await phone.say("yes I am", started_at=started)
            result = await asyncio.wait_for(pending, 5)
            await phone.hang_up()
            return result

    result = asyncio.run(scenario())
    assert (result["said"], result["outcome"]) == ("yes I am", "answered"), result


def test_a_newer_sync_call_takes_over_the_wait(core, fake, make_hub):
    """Two sync start_calls on one call (parallel tool calls in one batch): the first returns at once, the second
    gets the reply."""
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            await hub.injector.wait_for(1)
            first = asyncio.create_task(tool(core.tools.start_call, {"text": "One?", "mode": "sync"}))
            await phone.expect("speech_end")
            second = asyncio.create_task(tool(core.tools.start_call, {"text": "Or two?", "mode": "sync"}))
            superseded = await asyncio.wait_for(first, 3)
            end = await phone.expect("speech_end")
            await until(lambda: end["id"] in phone.played_at)
            await asyncio.sleep(0.1)
            await phone.say("two")
            reply = await asyncio.wait_for(second, 5)
            await phone.hang_up()
            return superseded, reply

    superseded, reply = asyncio.run(scenario())
    assert superseded["status"] == "superseded" and superseded["call_id"] == reply["call_id"]
    assert (reply["said"], reply["outcome"]) == ("two", "answered")


def test_a_sync_wait_yields_to_a_message_hermes_holds_for_it(core, fake, make_hub):
    """Hermes delivers a message that arrives while tools run (a typed one, or an injected [Voice] turn) once the
    tool returns, and asks the tool to yield: the sync wait returns, the call and its line carry on."""
    fake.host.add("s1")
    hub = make_hub()

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            await hub.injector.wait_for(1)
            pending = asyncio.create_task(tool(core.tools.start_call, {"text": "Shall I?", "mode": "sync"}))
            end = await phone.expect("speech_end")
            await until(lambda: end["id"] in phone.played_at)
            fake.yield_all = True  # what redirect() during tool execution does: request_yield on the tool threads
            result = await asyncio.wait_for(pending, 3)
            await phone.say("go ahead")
            texts = await hub.injector.wait_for(2)
            await phone.hang_up()
            return result, end, texts, hub.slot

    result, end, texts, slot = asyncio.run(scenario())
    assert result["status"] == "yielded" and "was spoken" in result["note"], result
    assert fake.yields_taken == 1
    assert not end.keys() & {"cancelled", "error"}  # the line was not stopped
    assert texts[1].startswith("[Voice] go ahead")  # with no waiter, the reply is injected


# ── policy through the hub ─────────────────────────────────────────────────────────────────────────────────


def test_rings_are_rate_limited_per_conversation_and_overall(core, fake, make_hub):
    for key in ("s1", "s2", "s3"):
        fake.host.add(key)
    hub = make_hub(pusher=FakePusher(ok=False, reason="no phone"), settings=core.config.Settings(
        fake_tts=True, policy=core.config.PolicyConfig(rings_per_session=2, rings_global=3)))

    def ring(session_id: str) -> dict:
        return asyncio.run(tool(core.tools.start_call, {"text": "Hi", "mode": "sync"}, session_id=session_id))

    first = [ring("s1")["outcome"] for _ in range(3)]
    assert first == ["push_failed", "push_failed", "not_allowed"]
    assert ring("s2")["outcome"] == "push_failed"  # the third ring overall
    refused = ring("s3")
    assert refused["outcome"] == "not_allowed" and "Too many calls" in refused["note"]
    entries = [json.loads(line) for line in (fake.home / "hermes-voice" / "rings.jsonl").read_text().splitlines()]
    assert [e.get("reason") for e in entries if e["event"] == "refused"] == ["rate_session", "rate_global"]


def test_quiet_hours_confirm_takes_the_users_own_reply_as_the_go_ahead(core, fake, make_hub, tmp_path):
    from datetime import datetime

    fake.host.add("s1")
    pusher = FakePusher()
    now = [datetime(2026, 10, 25, 23, 0).timestamp()]
    settings = core.config.Settings(fake_tts=True, policy=core.config.PolicyConfig(
        quiet_hours=core.config.QuietHours(start=22 * 60, end=7 * 60, action="confirm")))
    hub = make_hub(pusher=pusher, settings=settings, policy=core.policy.Policy(
        lambda: settings, log_dir=lambda: tmp_path / "hermes-voice", clock=lambda: now[0]))

    def ring() -> dict:
        now[0] += 1
        return asyncio.run(tool(core.tools.start_call, {"text": "Hi"}))

    def turn(message: object) -> None:
        now[0] += 1
        hub.note_turn_start("s1", "", message)  # what the pre_llm_call hook passes on

    assert ring()["status"] == "not_allowed"
    # Turns Hermes starts by itself, and the plugin's own injections, are not the user saying yes.
    for automatic in ("[Continuing toward your standing goal]\nGoal: ship it", "[Voice] okay (Reply out loud...)",
                      "[IMPORTANT: Background process 7 exited (exit code 0).]", None):
        turn(automatic)
        assert ring()["status"] == "not_allowed", automatic
    turn("yes, call me now")
    assert ring()["status"] == "ringing" and pusher.pushed.wait(5)


def test_a_kanban_worker_counts_as_a_scheduled_job(core, fake, make_hub, monkeypatch):
    fake.host.add("s1")
    pusher = FakePusher()
    make_hub(pusher=pusher)
    monkeypatch.setenv("HERMES_KANBAN_TASK", "task-1")
    result = asyncio.run(tool(core.tools.start_call, {"text": "Done", "mode": "sync"}))
    assert result["outcome"] == "not_allowed" and "Scheduled jobs" in result["note"] and pusher.payloads == []


# ── a call that ends while its phone link is coming up ─────────────────────────────────────────────────────


class _RacingSocket:
    """A phone socket driven by hand; `on_ready` runs while the plugin sends `ready` (the await in which
    another thread can end the call)."""

    def __init__(self, hello: dict, on_ready=None) -> None:
        self.incoming: asyncio.Queue = asyncio.Queue()
        self.incoming.put_nowait({"type": "websocket.receive", "text": json.dumps(hello)})
        self.on_ready = on_ready
        self.sent: list[dict] = []
        self.closed = None

    async def accept(self) -> None:
        pass

    async def receive(self) -> dict:
        return await self.incoming.get()

    async def send_json(self, message: dict) -> None:
        self.sent.append(message)
        if message["type"] == "ready" and self.on_ready is not None:
            self.on_ready()
            await asyncio.sleep(0.05)  # the close-out the ending scheduled runs now

    async def close(self, code: int = 1000) -> None:
        self.closed = code
        self.incoming.put_nowait({"type": "websocket.disconnect", "code": code})


@pytest.mark.parametrize("when", ["before ready", "while sending ready"])
def test_a_call_that_ends_while_its_link_comes_up_turns_the_link_away(core, fake, make_hub, when):
    fake.host.add("s1")
    pusher = FakePusher()
    hub = make_hub(pusher=pusher)

    async def admitted() -> None:
        return None

    async def scenario():
        hub.capture_loop()
        started = await tool(core.tools.start_call, {"text": "Hi"})
        call = hub.slot
        hello = {"type": "hello", "call_id": started["call_id"], "initiated_by": "push", "app_version": "test"}
        end = lambda: hub.finish(call, "ended_by_agent")  # noqa: E731
        if when == "before ready":
            admit = hub.admit
            hub.admit = lambda message: (lambda verdict: (end(), verdict)[1])(admit(message))
            socket = _RacingSocket(hello)
        else:
            socket = _RacingSocket(hello, on_ready=end)
        await asyncio.wait_for(hub.serve_phone(socket, lambda ws: admitted()), 5)
        await asyncio.sleep(0.1)
        return socket, call

    socket, call = asyncio.run(scenario())
    cancel = {"type": "cancel", "reason": "ended_by_agent"}
    if when == "before ready":
        assert socket.sent == [cancel]  # never a ready {state: "ended"}
    else:
        assert socket.sent == [{"type": "ready", "call_id": call.call_id, "state": "ringing"}, cancel]
    assert socket.closed == 1000 and hub.links == {} and hub.dropped == {}
