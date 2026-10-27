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
    monkeypatch.setattr(remote, "TURNS", core.inject.Turns(late=remote._late_delivery))
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


class LiveAgent:
    """An agent that shows its state the way Hermes' AIAgent does (``agent/interrupt_control.py``): ``steer()``
    takes text whether or not a turn runs (only the next drain reads it), ``redirect()`` refuses unless a model
    request is in flight (during tools it becomes a ticketless steer), and the turn lease is held from admission to
    release on every way out of a turn."""

    def __init__(self, session_id: str) -> None:
        import threading
        self.session_id = session_id
        self._delegate_depth = 0
        self._delegate_parent_ref = None
        self._executing_tools = False
        self._model_request_active = threading.Event()
        self._active_session_turn_lease_holder = None
        self.parts: list[tuple[Any, str]] = []
        self.fates: dict[Any, bool] = {}
        self.redirected: list[str] = []

    # the turn, as run_conversation goes through it
    def begin(self) -> None:
        self._active_session_turn_lease_holder = "pid=1:turn=x"

    def model_request(self, active: bool) -> None:
        (self._model_request_active.set if active else self._model_request_active.clear)()

    def drain(self) -> None:
        for ticket, _ in self.parts:
            if ticket is not None:
                self.fates[ticket] = True
        self.parts = []

    def release(self) -> None:
        self._active_session_turn_lease_holder = None

    # InterruptControlMixin
    def steer(self, text: str, *, ticket: Any = None) -> bool:
        if not text.strip():
            return False
        self.parts.append((ticket, text.strip()))
        return True

    def redirect(self, text: str) -> bool:
        if self._executing_tools:
            return self.steer(text)
        if not self._model_request_active.is_set():
            return False
        self.redirected.append(text)
        return True

    def withdraw_steer(self, ticket: Any) -> bool:
        kept = [part for part in self.parts if part[0] is not ticket]
        consumed = self.fates.pop(ticket, True)
        if len(kept) == len(self.parts):
            return consumed is False
        self.parts = kept
        return True

    def buffered(self) -> list[str]:
        return [text for _, text in self.parts]


class Ctx:
    """A plugin context: ``inject_message`` starts a turn (or refuses, like Hermes without the setting)."""

    def __init__(self, accept: bool = True, cli: bool = False, surface: str = "", home: Any = None) -> None:
        self.accept = accept
        self.surface = surface
        self._manager = types.SimpleNamespace(_cli_ref=object() if cli else None, home_path=home,
                                              scope_key=str(home) if home is not None else None)
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


@pytest.mark.parametrize("how", ["early_return", "compression", "compression_then_a_turn"])
def test_a_turn_no_hook_closed_doesnt_swallow_the_next_voice_turn(core, fake, mods, how):
    """on_session_end doesn't fire on every way out of a turn (a provider 4xx, retries used up, an interrupt during a
    model call), and compression gives a running turn a new id. The hooks then still say "mid-turn", but the agent
    is idle: Hermes' steer() would take the text and no turn would ever read it. The agent's own state decides."""
    agent, ctx = LiveAgent("tg-1"), Ctx()
    target = _target(core, agent, ctx)
    fake.subagent_parent = agent  # the hooks run inside the agent's turn
    mods.remote.note_turn_start("tg-1")
    agent.begin()
    if how.startswith("compression"):
        agent.session_id = "tg-1b"  # conversation_compression: agent.session_id = new_session_id
        mods.remote.note_turn_end("tg-1b")
        if how == "compression_then_a_turn":
            mods.remote.note_turn_start("tg-1b")
            mods.remote.note_turn_end("tg-1b")
    agent.release()  # early_return: no on_session_end; the lease is released all the same
    fake.subagent_parent = None
    delivery = core.inject.deliver_here(target, "[Voice] are you there?", mods.remote.TURNS)
    assert (delivery.ok, delivery.via) == (True, "inject")
    assert ctx.injected == [(TG_KEY, "[Voice] are you there?")] and agent.buffered() == []
    if how != "early_return":
        assert not mods.remote.TURNS.running  # no id stranded by the rotation


def test_mid_turn_by_the_agents_own_state(core, fake, mods):
    agent, ctx = LiveAgent("tg-1"), Ctx()
    target = _target(core, agent, ctx)
    agent.begin()
    agent.model_request(True)
    delivery = core.inject.deliver_here(target, "[Voice] wait", mods.remote.TURNS)  # no hook seen at all
    assert (delivery.ok, delivery.via) == (True, "redirect") and agent.redirected == ["[Voice] wait"]
    agent.model_request(False)
    agent._executing_tools = True
    delivery = core.inject.deliver_here(target, "[Voice] and", mods.remote.TURNS)
    assert (delivery.ok, delivery.via) == (True, "redirect") and agent.buffered() == ["[Voice] and"]
    assert ctx.injected == []


def test_a_steer_a_turn_ends_without_reading_starts_a_turn_without_the_hook(core, fake, mods):
    """Between a model request and the tools (or while the turn winds down) redirect() refuses and the steer waits
    in the buffer. A turn that then ends on an early return fires no on_session_end: the watcher sees the agent
    idle, takes the steer back and starts a turn with it."""
    agent, ctx = LiveAgent("tg-1"), Ctx()
    target = _target(core, agent, ctx)
    agent.begin()
    delivery = core.inject.deliver_here(target, "[Voice] one more thing", mods.remote.TURNS)
    assert (delivery.ok, delivery.via, delivery.status) == (True, "steer", "queued")
    assert agent.buffered() == ["[Voice] one more thing"] and ctx.injected == []
    agent.release()
    asyncio.run(until(lambda: ctx.injected))
    assert ctx.injected == [(TG_KEY, "[Voice] one more thing")] and agent.buffered() == []
    # One the turn read stays read.
    agent.begin()
    core.inject.deliver_here(target, "[Voice] read this", mods.remote.TURNS)
    agent.drain()
    agent.release()
    asyncio.run(until(lambda: not mods.remote.TURNS.held))
    assert ctx.injected == [(TG_KEY, "[Voice] one more thing")]


def test_a_steer_that_lands_as_the_turn_ends_is_taken_back_at_once(core, fake, mods):
    agent, ctx = LiveAgent("tg-1"), Ctx()
    target = _target(core, agent, ctx)
    agent.begin()

    def steer_then_end(text, *, ticket=None):
        LiveAgent.steer(agent, text, ticket=ticket)
        agent.release()  # the turn ended right after the look
        return True

    agent.steer = steer_then_end
    delivery = core.inject.deliver_here(target, "[Voice] hello", mods.remote.TURNS)
    assert (delivery.ok, delivery.via) == (True, "inject") and agent.buffered() == []
    assert ctx.injected == [(TG_KEY, "[Voice] hello")] and not mods.remote.TURNS.held


def test_a_compute_host_child_leaves_idle_turns_to_the_dashboard(core, fake, mods, monkeypatch):
    """Under dashboard.turn_isolation the child holds a copy of the dashboard's session: a turn submitted there
    would run behind the dashboard's back. Idle, the child says fallback (the dashboard's prompt.submit starts the
    turn and sends it to the child); mid-turn it steers its own agent."""
    monkeypatch.setenv("HERMES_COMPUTE_HOST_CHILD", "1")
    fake.host.add("s1")
    agent, ctx = LiveAgent("s1"), Ctx()
    target = _target(core, agent, ctx, "s1", "s1")
    delivery = core.inject.deliver_here(target, "[Voice] pasta", mods.remote.TURNS)
    assert not delivery.ok and delivery.fallback
    assert fake.host.calls == [] and ctx.injected == []
    agent.begin()
    agent.model_request(True)
    delivery = core.inject.deliver_here(target, "[Voice] no, rice", mods.remote.TURNS)
    assert (delivery.ok, delivery.via) == (True, "redirect") and fake.host.calls == []
    # A steer its turn never read goes back to the hub, which puts it through the dashboard.
    agent.model_request(False)

    class Sub:
        def __init__(self):
            self.target, self.requeued = target, []

        def requeue(self, text):
            self.requeued.append(text)
            return True

    sub = Sub()
    mods.remote._subscriptions["c" * 32] = sub
    assert core.inject.deliver_here(target, "[Voice] sorry", mods.remote.TURNS).via == "steer"
    agent.release()
    asyncio.run(until(lambda: sub.requeued))
    assert sub.requeued == ["[Voice] sorry"] and ctx.injected == []


def test_the_call_follows_the_agent_through_compression(core, fake, mods):
    """In-place compression rotates the agent's session id without a parent id on the next turn: the call still
    follows, because it is the same agent."""
    agent = LiveAgent("tg-1")
    target = _target(core, agent, Ctx())

    class Sub:
        def __init__(self):
            self.target, self.rekeyed = target, []

        def rekey(self, session_id):
            self.rekeyed.append(session_id)
            self.target.rekey(session_id)

    sub = Sub()
    mods.remote._subscriptions["c" * 32] = sub
    agent.session_id = "tg-1b"
    fake.subagent_parent = agent
    mods.remote.note_turn_start("tg-1b")
    assert sub.rekeyed == ["tg-1b"] and target.session_id == "tg-1b"
    other = LiveAgent("tg-9")
    fake.subagent_parent = other
    mods.remote.note_turn_start("tg-9")  # another conversation's turn in the same process
    assert sub.rekeyed == ["tg-1b"]


def test_the_plugin_context_is_matched_by_home_whatever_its_spelling(core, fake, mods, tmp_path):
    real = tmp_path / "real-home"
    real.mkdir()
    link = tmp_path / "linked-home"
    link.symlink_to(real)
    other = tmp_path / "other"
    other.mkdir()
    mine, theirs = Ctx(home=real), Ctx(home=other)
    mods.remote.bind_context(mine)
    assert mods.remote.context() is mine  # one context: it is this process's
    mods.remote.bind_context(theirs)
    fake.home = link  # HERMES_HOME given through a symlink (/tmp vs /private/tmp)
    assert mods.remote.context() is mine
    fake.home = tmp_path / "unknown"
    assert mods.remote.context() is None  # never another profile's


@pytest.mark.parametrize(
    ("setup", "label"),
    [
        (lambda fake: fake.env.update(HERMES_SINGLE_QUERY_SESSION="1"), "oneshot"),
        (lambda fake: setattr(fake, "finite", True), "oneshot"),
        (lambda fake: setattr(fake, "launch_source", "oneshot"), "oneshot"),
        (lambda fake: setattr(fake, "launch_source", "tool"), "tool"),
    ],
)
def test_a_run_nobody_is_at_the_keyboard_for_doesnt_ring_by_default(core, fake, mods, hub_socket, monkeypatch,
                                                                   setup, label):
    """`hermes chat -q`, `hermes -z` and `--source tool` run as the CLI (session surface "cli"), but nobody is there
    to talk to: a prompt injection in what they read must not ring the phone unless the owner allows that."""
    policy_state = types.SimpleNamespace(source="")
    monkeypatch.setitem(sys.modules, "gateway.session_policy",
                        types.SimpleNamespace(active_policy=lambda: policy_state if policy_state.source else None))
    finite = types.SimpleNamespace(value=None)
    monkeypatch.setitem(sys.modules, "gateway.session_finite", types.SimpleNamespace(
        finite_turn_required=lambda: finite.value, unattended_turn=lambda: False))
    fake.launch_source = ""
    fake.finite = None
    setup(fake)
    policy_state.source = fake.launch_source
    finite.value = fake.finite
    fake.env.pop("HERMES_SESSION_SOURCE", None)
    fake.config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    mods.remote.bind_context(Ctx(surface="cli"))
    pusher = FakePusher()
    hub_socket(pusher=pusher)
    origin = mods.remote.origin_for("s1")
    assert origin.source == label
    refused = mods.remote.start_call("s1", "Hi", "async")
    assert refused["status"] == "not_allowed" and pusher.payloads == []
    entries = [json.loads(line) for line in (fake.home / "hermes-voice" / "rings.jsonl").read_text().splitlines()]
    assert entries[-1]["reason"] == "source" and entries[-1]["source"] == label


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


@pytest.mark.parametrize("surface", ["telegram", "cli"])
def test_a_sync_wait_is_capped_by_the_tool_deadline_and_waits_as_a_human_wait(core, fake, mods, hub_socket,
                                                                             monkeypatch, surface):
    """Hermes abandons a tool call past its deadline (timeouts.tools.sequential_call) plus at most
    approvals.timeout + 60 s of human wait, whatever the platform: the wait ends before that, with a note."""
    hub_socket(pusher=FakePusher())
    if surface == "telegram":
        _as_telegram_dm(fake)
        fake.secrets["GATEWAY_ALLOWED_USERS"] = "42"
    else:
        fake.env["HERMES_SESSION_SOURCE"] = "cli"
    fake.config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    mods.remote.bind_context(Ctx())
    sequential = types.ModuleType("agent.tool_executor")
    sequential._resolve_sequential_tool_timeout = lambda: 21.0
    monkeypatch.setitem(sys.modules, "agent.tool_executor", sequential)
    monkeypatch.setattr(core.hermes, "human_wait_ceiling", lambda: 0.5)
    # 21 s deadline + 0.5 s of human wait - the 20 s margin - what the ring took: about a second.
    result = mods.remote.start_call("tg-1", "Are you there?", "sync")
    assert result["outcome"] == "answered" and result["said"] == ""
    assert "timeouts.tools.sequential_call" in result["note"] and "approvals.timeout + 60 s" in result["note"]
    assert fake.waits == 1 and fake.beats > 0  # in this process's human-wait window, with heartbeats


def test_tool_wait_cap(core, fake, monkeypatch):
    import time
    assert core.hermes.tool_wait_cap(time.monotonic()) is None  # outside Hermes: no deadline known
    sequential = types.ModuleType("agent.tool_executor")
    sequential._resolve_sequential_tool_timeout = lambda: 420.0
    monkeypatch.setitem(sys.modules, "agent.tool_executor", sequential)
    monkeypatch.setattr(core.hermes, "human_wait_ceiling", lambda: 360.0)
    cap = core.hermes.tool_wait_cap(time.monotonic() - 100)
    assert 420 + 360 - 100 - 21 < cap <= 420 + 360 - 100 - 20
    sequential._resolve_sequential_tool_timeout = lambda: None  # timeouts.tools.sequential_call: 0
    assert core.hermes.tool_wait_cap(time.monotonic()) is None


def test_a_sync_call_in_the_dashboard_is_capped_too(core, fake, make_hub, monkeypatch):
    import time
    hub = make_hub(pusher=FakePusher())
    fake.host.add("s1")
    sequential = types.ModuleType("agent.tool_executor")
    sequential._resolve_sequential_tool_timeout = lambda: 21.0
    monkeypatch.setitem(sys.modules, "agent.tool_executor", sequential)
    monkeypatch.setattr(core.hermes, "human_wait_ceiling", lambda: 0.5)
    started = time.monotonic()
    result = json.loads(core.tools.start_call({"text": "Still there?", "mode": "sync"}, session_id="s1"))
    assert time.monotonic() - started < 10
    assert result["outcome"] == "answered" and "timeouts.tools.sequential_call" in result["note"]
    assert hub.slot is not None  # the call stays open


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
