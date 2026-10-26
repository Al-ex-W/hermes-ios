"""Calls from conversations in other Hermes processes (remote.py): a separate process that rings, hears the reply
and gets later turns injected, end to end through the hub socket with a scripted phone; how a turn is put into
the conversation there (the agent's redirect / steer, ``ctx.inject_message``, the Ink TUI's own session host); and
what start_call says where it can't work."""

from __future__ import annotations

import asyncio
import json
import os
import sys
import types
from pathlib import Path
from typing import Any

import pytest

from support import PLUGIN_DIR, FakePusher, Phone, serving, until

SCRIPT = Path(__file__).resolve().parent / "remote_client.py"
TG_KEY = "agent:main:telegram:dm:42"


@pytest.fixture
def mods(core, monkeypatch):
    remote = core.loader.module("remote", PLUGIN_DIR)
    # Each test starts with a process that has seen no turns, contexts or calls.
    monkeypatch.setattr(remote, "TURNS", core.inject.Turns())
    monkeypatch.setattr(remote, "_contexts", [])
    monkeypatch.setattr(remote, "_subscriptions", {})
    monkeypatch.setattr(remote, "_user_turn_at", {})
    return types.SimpleNamespace(remote=remote, hubsock=core.loader.module("hubsock", PLUGIN_DIR))


@pytest.fixture
def hub_socket(mods, fake, make_hub):
    servers = []

    def start(**hub_kw):
        hub = make_hub(**hub_kw)
        servers.append(mods.hubsock.HubServer(hub, fake.home / "hermes-voice").start())
        return hub

    yield start
    for server in servers:
        server.close()


class Agent:
    """The agent running the conversation in its own process."""

    def __init__(self, session_id: str, redirect: bool = True) -> None:
        self.session_id = session_id
        self._delegate_depth = 0
        self._delegate_parent_ref = None
        self.accept_redirect = redirect
        self.redirects: list[str] = []
        self.steers: list[str] = []
        self.buffer: dict[Any, str] = {}

    def redirect(self, text: str) -> bool:
        self.redirects.append(text)
        return self.accept_redirect

    def steer(self, text: str, *, ticket: Any = None) -> bool:
        self.steers.append(text)
        if ticket is not None:
            self.buffer[ticket] = text
        return True

    def drain(self) -> None:
        """A tool batch ended: the steers are read."""
        self.buffer.clear()

    def withdraw_steer(self, ticket: Any) -> bool:
        return self.buffer.pop(ticket, None) is not None


class Ctx:
    """A plugin context: ``inject_message`` starts a turn (or refuses, like Hermes without the setting)."""

    def __init__(self, accept: bool = True, cli: bool = False, surface: str = "") -> None:
        self.accept = accept
        self.surface = surface
        self._manager = types.SimpleNamespace(_cli_ref=object() if cli else None, home_path=None)
        self.injected: list[tuple[Any, str]] = []

    def inject_message(self, content: str, role: str = "user", *, session_key: Any = None,
                       origin: Any = None) -> bool:
        self.injected.append((session_key, content))
        return self.accept

    def session_surface(self) -> str:
        return self.surface


def _as_telegram_dm(fake, user: str = "42") -> None:
    fake.env.clear()
    fake.env.update({"HERMES_SESSION_PLATFORM": "telegram", "HERMES_SESSION_CHAT_TYPE": "dm",
                     "HERMES_SESSION_USER_ID": user, "HERMES_SESSION_KEY": f"agent:main:telegram:dm:{user}"})


async def _pick_up(port: int, fake, pusher: FakePusher, seen: int = 0) -> Phone:
    await until(lambda: len(pusher.payloads) > seen)
    payload = pusher.payloads[-1]
    phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push",
                             session_id=payload["session_id"])
    await phone.send({"type": "ringing"})
    await phone.send({"type": "answered"})
    return phone


# ── another process, end to end ────────────────────────────────────────────────────────────────────────────


class Script:
    """remote_client.py in its own process, one command at a time."""

    def __init__(self, process: asyncio.subprocess.Process) -> None:
        self.process = process

    @classmethod
    async def start(cls, env: dict) -> "Script":
        process = await asyncio.create_subprocess_exec(
            sys.executable, str(SCRIPT), str(PLUGIN_DIR), env=env, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        return cls(process)

    async def send(self, command: dict) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write((json.dumps(command) + "\n").encode())
        await self.process.stdin.drain()

    async def answer(self, timeout: float = 20) -> Any:
        assert self.process.stdout is not None
        line = await asyncio.wait_for(self.process.stdout.readline(), timeout)
        if not line:
            assert self.process.stderr is not None
            raise AssertionError((await self.process.stderr.read()).decode()[-3000:])
        return json.loads(line)

    async def ask(self, command: dict, timeout: float = 20) -> Any:
        await self.send(command)
        return await self.answer(timeout)

    async def until(self, predicate, timeout: float = 10) -> dict:
        async with asyncio.timeout(timeout):
            while not predicate(state := await self.ask({"do": "injected"})):
                await asyncio.sleep(0.05)
        return state

    async def stop(self) -> None:
        if self.process.returncode is None:
            assert self.process.stdin is not None
            self.process.stdin.close()
            try:
                await asyncio.wait_for(self.process.wait(), 10)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()


def test_a_telegram_dm_in_another_process_rings_hears_the_reply_and_gets_later_turns(core, fake, hub_socket):
    pusher = FakePusher()
    hub = hub_socket(pusher=pusher)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("HERMES_", "GATEWAY_"))}
    env.update({"HERMES_HOME": str(fake.home), "HERMES_SESSION_PLATFORM": "telegram",
                "HERMES_SESSION_CHAT_TYPE": "dm", "HERMES_SESSION_USER_ID": "42", "HERMES_SESSION_KEY": TG_KEY,
                # The gateway's own allowlist names the user: they are the owner.
                "GATEWAY_ALLOWED_USERS": "42", "PYTHONDONTWRITEBYTECODE": "1"})

    async def scenario():
        async with serving(core) as port:
            script = await Script.start(env)
            try:
                await script.send({"do": "start_call", "session_id": "tg-1", "text": "Ship it?", "mode": "sync"})
                phone = await _pick_up(port, fake, pusher)
                end = await phone.expect("speech_end")
                await until(lambda: end["id"] in phone.played_at)
                await asyncio.sleep(0.1)
                await phone.say("Yes, ship it.")
                reply = await script.answer()
                same_chat = await script.ask({"do": "start_call", "session_id": "tg-2", "text": "Hi"})
                again = await script.ask({"do": "start_call", "session_id": "tg-1", "text": "Done."})
                await phone.expect("speech_end")
                # Idle: the turn starts a new one through ctx.inject_message.
                await phone.say("one more thing")
                idle = await script.until(lambda state: state["inject"])
                # Mid-turn: the agent's own redirect.
                await script.ask({"do": "turn_start", "session_id": "tg-1", "user_message": "[Voice] ..."})
                await phone.say("wait, stop")
                busy_turn = await script.until(lambda state: state["redirect"])
                await script.ask({"do": "turn_end", "session_id": "tg-1"})
                subscribed = await script.ask({"do": "subscriptions"})
                await phone.hang_up()
                ended = await script.until(lambda state: len(state["inject"]) > 1)
                async with asyncio.timeout(10):
                    while (await script.ask({"do": "subscriptions"}))["calls"]:
                        await asyncio.sleep(0.05)
                return reply, same_chat, again, idle, busy_turn, subscribed, ended
            finally:
                await script.stop()

    reply, same_chat, again, idle, busy_turn, subscribed, ended = asyncio.run(scenario())
    call_id = reply["call_id"]
    assert reply == {"said": "Yes, ship it.", "ending": "end_of_speech", "outcome": "answered", "call_id": call_id}
    assert pusher.payloads == [{"call_id": call_id, "session_id": "tg-1", "profile": "default", "mode": "sync",
                                "title": "Telegram"}]
    # The same chat (its route key: a new session id after /new or compression) speaks into the call; it never
    # rings twice.
    assert same_chat["status"] == "speaking" and same_chat["call_id"] == call_id
    assert again["status"] == "speaking" and len(pusher.payloads) == 1
    assert idle["inject"] == [[TG_KEY, idle["inject"][0][1]]] and idle["inject"][0][1].startswith("[Voice] one more")
    assert busy_turn["redirect"][0].startswith("[Voice] wait, stop")
    assert subscribed == {"calls": [call_id]}
    assert ended["inject"][1][1].startswith("[Voice call ended by user]")
    entries = [json.loads(line) for line in (fake.home / "hermes-voice" / "rings.jsonl").read_text().splitlines()]
    assert [(e["event"], e.get("source")) for e in entries][:1] == [("ring", "telegram")]
    assert entries[-1]["outcome"] == "ended_by_user"
    assert hub.slot is None


def test_a_call_that_ends_before_its_process_subscribes_still_tells_it(core, fake, mods, hub_socket):
    """An async ring whose push fails at once is over before the process's subscription connects: the subscriber
    still gets the notice (which can reach it before the answer to subscribe_turns), then the end."""
    hub = hub_socket(pusher=FakePusher(ok=False, reason="no phone registered"))
    _as_telegram_dm(fake)
    fake.secrets["GATEWAY_ALLOWED_USERS"] = "42"
    fake.config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    ctx = Ctx()
    mods.remote.bind_context(ctx)
    started = mods.remote.start_call("tg-1", "Hi", "async")
    assert started["status"] in ("ringing", "ended")
    asyncio.run(until(lambda: ctx.injected and not mods.remote.subscriptions()))
    assert ctx.injected == [(TG_KEY, ctx.injected[0][1])]
    assert ctx.injected[0][1].startswith("[Voice line not delivered: the phone couldn't be rung (no phone registered)]")
    call_id, _, delivery = hub.deliveries[0]
    assert call_id == started["call_id"] and (delivery.ok, delivery.via) == (True, "inject")


# ── putting turns in, in the conversation's process ────────────────────────────────────────────────────────


def _target(core, agent=None, ctx=None, session_id="tg-1", key=TG_KEY):
    return core.inject.AgentTarget.capture(session_id, key, agent, ctx)


def test_mid_turn_a_turn_redirects_else_steers(core, fake):
    turns = core.inject.Turns()
    agent, ctx = Agent("tg-1"), Ctx()
    target = _target(core, agent, ctx)
    turns.start("tg-1")
    delivery = core.inject.deliver_here(target, "[Voice] hi", turns)
    assert (delivery.ok, delivery.via) == (True, "redirect") and agent.redirects == ["[Voice] hi"]
    agent.accept_redirect = False  # between model requests: redirect refuses, steer takes it
    delivery = core.inject.deliver_here(target, "[Voice] and", turns)
    assert (delivery.ok, delivery.via, delivery.status) == (True, "steer", "queued")
    assert agent.steers == ["[Voice] and"] and ctx.injected == []


def test_a_steer_the_turn_never_read_starts_a_turn_when_it_ends(core, fake):
    turns = core.inject.Turns()
    agent, ctx = Agent("tg-1", redirect=False), Ctx()
    target = _target(core, agent, ctx)
    turns.start("tg-1")
    core.inject.deliver_here(target, "[Voice] first", turns)
    agent.drain()  # read by a tool batch
    core.inject.deliver_here(target, "[Voice] late", turns)  # after the last tool batch
    unread = turns.end("tg-1")
    assert [text for _, text in unread] == ["[Voice] late"]
    assert core.inject.inject_idle(unread[0][0], unread[0][1]).ok
    assert ctx.injected == [(TG_KEY, "[Voice] late")]


def test_the_on_session_end_hook_delivers_unread_steers(core, fake, mods):
    agent, ctx = Agent("tg-1", redirect=False), Ctx()
    target = _target(core, agent, ctx)
    mods.remote.note_turn_start("tg-1")
    core.inject.deliver_here(target, "[Voice] late", mods.remote.TURNS)
    mods.remote.note_turn_end("tg-1")
    asyncio.run(until(lambda: ctx.injected))
    assert ctx.injected == [(TG_KEY, "[Voice] late")]


def test_idle_a_turn_starts_one_with_inject_message(core, fake):
    agent, ctx = Agent("tg-1"), Ctx()
    delivery = core.inject.deliver_here(_target(core, agent, ctx), "[Voice] hi", core.inject.Turns())
    assert (delivery.ok, delivery.via) == (True, "inject") and agent.redirects == []
    assert ctx.injected == [(TG_KEY, "[Voice] hi")]


def test_idle_without_allow_gateway_injection_says_how_to_turn_it_on(core, fake):
    ctx = Ctx(accept=False)
    delivery = core.inject.deliver_here(_target(core, Agent("tg-1"), ctx), "[Voice] hi", core.inject.Turns())
    assert not delivery.ok and delivery.fallback and "allow_gateway_injection" in delivery.detail
    fake.config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    delivery = core.inject.deliver_here(_target(core, Agent("tg-1"), ctx), "[Voice] hi", core.inject.Turns())
    assert not delivery.ok and "allow_gateway_injection" not in delivery.detail  # allowed, nothing took it
    # The classic CLI needs no setting: a refusal there is something else.
    delivery = core.inject.inject_idle(_target(core, None, Ctx(accept=False, cli=True)), "[Voice] hi")
    assert "allow_gateway_injection" not in delivery.detail


def test_the_ink_tui_puts_turns_in_through_its_own_session_host(core, fake):
    fake.host.add("tui-1")
    ctx = Ctx()
    delivery = core.inject.deliver_here(_target(core, Agent("tui-1"), ctx, "tui-1", ""), "[Voice] hi",
                                        core.inject.Turns())
    assert (delivery.ok, delivery.via) == (True, "redirect")
    assert fake.host.methods_called() == ["session.redirect"] and ctx.injected == []
    # A session it doesn't have open is never reopened here.
    delivery = core.inject.deliver_here(_target(core, None, Ctx(accept=False), "gone", ""), "[Voice] hi",
                                        core.inject.Turns())
    assert not delivery.ok and "session.resume" not in fake.host.methods_called()


def test_the_call_follows_compression_in_the_other_process(core, fake, mods):
    target = _target(core, Agent("tg-1"), Ctx())

    class Sub:
        def __init__(self):
            self.target, self.rekeyed = target, []

        def rekey(self, session_id):
            self.rekeyed.append(session_id)
            self.target.rekey(session_id)

    sub = Sub()
    mods.remote._subscriptions["c" * 32] = sub
    fake.subagent_parent = types.SimpleNamespace(session_id="child", _delegate_depth=1, _delegate_parent_ref=None)
    mods.remote.note_turn_start("child", "tg-1")  # a subagent's turn: not a continuation
    assert sub.rekeyed == []
    fake.subagent_parent = None
    mods.remote.note_turn_start("tg-1b", "tg-1")  # compression rotated the conversation's id
    assert sub.rekeyed == ["tg-1b"] and target.session_id == "tg-1b"


# ── in-process remote calls: errors and the policy across processes ────────────────────────────────────────


def test_start_call_without_a_dashboard_is_not_available(core, fake, mods):
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    for mode, key in (("async", "status"), ("sync", "outcome")):
        result = mods.remote.start_call("s1", "Hi", mode)
        assert result[key] == "not_available" and result["error"] == "not_available"
        assert "hermes serve" in result["note"]
    assert mods.remote.status() is None and mods.remote.reachable() is False


def test_async_from_a_chat_without_allow_gateway_injection_is_refused_sync_works(core, fake, mods, hub_socket):
    pusher = FakePusher()
    hub_socket(pusher=pusher)
    _as_telegram_dm(fake)
    fake.secrets["GATEWAY_ALLOWED_USERS"] = "42"
    mods.remote.bind_context(Ctx(accept=False))
    refused = mods.remote.start_call("tg-1", "Hi", "async")
    assert refused["status"] == "not_available" and refused["error"] == "allow_gateway_injection"
    assert "allow_gateway_injection: true" in refused["note"] and "sync" in refused["note"]
    assert pusher.payloads == []
    fake.interrupt_all = True  # stop the wait at once: only the ring and the note matter here
    result = mods.remote.start_call("tg-1", "Hi", "sync")
    assert result["status"] == "interrupted" and pusher.payloads
    fake.interrupt_all = False


def test_a_sync_wait_from_a_chat_is_capped_and_waits_as_a_human_wait(core, fake, mods, hub_socket, monkeypatch):
    hub_socket(pusher=FakePusher())
    _as_telegram_dm(fake)
    fake.secrets["GATEWAY_ALLOWED_USERS"] = "42"
    fake.config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    mods.remote.bind_context(Ctx())
    monkeypatch.setattr(core.hermes, "human_wait_ceiling", lambda: 0.5)
    result = mods.remote.start_call("tg-1", "Are you there?", "sync")
    assert result["outcome"] == "answered" and result["said"] == ""
    assert "approvals.timeout + 60 s" in result["note"]
    assert fake.waits == 1 and fake.beats > 0  # in this process's human-wait window, with heartbeats


@pytest.mark.parametrize(
    ("env", "secrets", "outcome", "reason"),
    [
        ({"HERMES_SESSION_CHAT_TYPE": "dm"}, {"GATEWAY_ALLOWED_USERS": "42"}, "ringing", ""),
        ({"HERMES_SESSION_CHAT_TYPE": "dm"}, {"GATEWAY_ALLOWED_USERS": "7,8"}, "not_allowed", "not_owner"),
        ({"HERMES_SESSION_CHAT_TYPE": "dm"}, {"GATEWAY_ALLOWED_USERS": "*"}, "not_allowed", "not_owner"),
        ({"HERMES_SESSION_CHAT_TYPE": "group"}, {"GATEWAY_ALLOWED_USERS": "42"}, "not_allowed", "group"),
        ({"HERMES_CRON_SESSION": "1"}, {"GATEWAY_ALLOWED_USERS": "42"}, "not_allowed", "cron"),
    ],
)
def test_who_may_ring_from_a_chat(core, fake, mods, hub_socket, env, secrets, outcome, reason):
    hub_socket(pusher=FakePusher())
    _as_telegram_dm(fake)
    fake.env.update(env)
    fake.secrets.update(secrets)
    fake.config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    mods.remote.bind_context(Ctx())
    result = mods.remote.start_call("tg-1", "Hi", "async")
    assert result["status"] == outcome, result
    if reason:
        entries = [json.loads(line) for line in
                   (fake.home / "hermes-voice" / "rings.jsonl").read_text().splitlines()]
        assert entries[-1]["reason"] == reason


def test_rate_limits_and_quiet_hours_count_rings_from_every_process(core, fake, mods, hub_socket):
    import time
    from datetime import datetime
    now = [time.time()]  # the other process notes the user's message on the host's clock
    local = datetime.fromtimestamp(now[0])
    minute = local.hour * 60 + local.minute
    quiet = core.config.QuietHours(start=(minute - 60) % 1440, end=(minute + 120) % 1440, action="confirm")
    settings = core.config.Settings(fake_tts=True, policy=core.config.PolicyConfig(rings_global=2,
                                                                                    quiet_hours=quiet))
    policy = core.policy.Policy(lambda: settings, log_dir=lambda: fake.home / "hermes-voice", clock=lambda: now[0])
    hub = hub_socket(pusher=FakePusher(ok=False, reason="no phone"), settings=settings, policy=policy)
    _as_telegram_dm(fake)
    fake.secrets["GATEWAY_ALLOWED_USERS"] = "42"
    fake.config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    mods.remote.bind_context(Ctx())

    def ring() -> dict:
        time.sleep(0.01)
        now[0] = time.time()
        return mods.remote.start_call("tg-1", "Hi", "sync")

    refused = ring()
    assert refused["outcome"] == "not_allowed" and "quiet hours" in refused["note"]
    mods.remote.note_turn_start("tg-1", "", "[Voice] yes")  # not the user's own words
    assert ring()["outcome"] == "not_allowed"
    time.sleep(0.01)
    mods.remote.note_turn_start("tg-1", "", "yes, call me")  # the user wrote, in the gateway's process
    assert ring()["outcome"] == "push_failed"
    # The dashboard's own conversations share the hourly limit with the chat.
    fake.host.add("s1")
    policy.record_ring(core.hermes.Origin(session_id="s1"), "a" * 32)
    over = ring()
    assert over["outcome"] == "not_allowed" and "Too many calls" in over["note"]
    assert hub.slot is None


def test_a_gateway_serving_the_dashboard_app_calls_through_the_socket(core, fake, mods, hub_socket, monkeypatch):
    """The messaging gateway mounts the dashboard's app behind its own API listener (app.state.gateway_runner):
    the phone doesn't connect there, so its conversations call through the hub's socket like any other process."""
    hub = hub_socket(pusher=FakePusher())
    fake.host.add("s1")  # hosted here, so turns can be put in without allow_gateway_injection
    web = sys.modules["hermes_cli.web_server"]
    monkeypatch.setattr(web, "app", types.SimpleNamespace(state=types.SimpleNamespace(
        bound_host="127.0.0.1", gateway_runner=object())))
    assert core.hub.routes_mounted() is False and core.tools.reachable() is True
    result = json.loads(core.tools.start_call({"text": "Hi"}, session_id="s1"))
    assert result["status"] == "ringing" and hub.slot.owner.remote and hub.slot.call_id == result["call_id"]
    assert hub.slot.owner.source == "desktop"
    asyncio.run(until(lambda: mods.remote.subscriptions().get(result["call_id"]) is not None
                      and mods.remote.subscriptions()[result["call_id"]].ready.is_set()))
    ended = json.loads(core.tools.end_call({}, session_id="s1"))
    assert ended == {"call_id": result["call_id"], "outcome": "ended_by_agent", "note": "Hung up."}
