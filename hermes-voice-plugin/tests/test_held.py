"""A call whose chat another Hermes process holds (Hermes keeps one writer per conversation: the lease in
``runtime/active_sessions.json``): the dashboard's ``prompt.submit`` is refused with 4090 / ``SESSION_NOT_OWNED``
("This chat is open in another Hermes window/terminal"). What the user says must not be dropped silently: the
process that holds the chat puts it in when it runs this plugin (``attend`` on the hub socket), else the turn is
kept and retried in order, the user hears once that the chat can't be reached, and the ring log says so."""

from __future__ import annotations

import asyncio
import json
import socket
import sys
import time
import types

import pytest

from support import PLUGIN_DIR, Phone, serving, until

HELD_MESSAGE = ("This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\n"
                "Details: session s1 opened by desktop 5m ago.")


def held(_params: dict | None = None) -> dict:
    """Hermes' answer to ``prompt.submit`` for a chat another process holds (tui_gateway/methods_prompt.py)."""
    return {"error": {"code": 4090, "message": HELD_MESSAGE, "data": {"reason": "SESSION_NOT_OWNED"}}}


def hold(fake) -> None:
    """Another process holds the chat: a reopened copy takes no redirect or steer (no agent), and no prompt."""
    fake.host.answers.update({"session.redirect": ("error", 4010), "session.steer": ("error", 4010),
                              "prompt.submit": held})


def release(fake) -> None:
    """The other process let go of the chat: prompts are taken from now on (and kept in ``fake.taken``)."""
    fake.taken = []

    def take(params: dict) -> dict:
        fake.taken.append(params["text"])
        return {"result": {"status": "streaming"}}

    fake.host.answers["prompt.submit"] = take


def ring_log(fake) -> list[dict]:
    path = fake.home / "hermes-voice" / "rings.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def submitted(fake) -> list[str]:
    """The texts Hermes took as prompts (the refused ones left out)."""
    return list(getattr(fake, "taken", []))


def spoken(phone: Phone) -> list[str]:
    return [m["text"] for m in phone.messages if m["type"] == "speech_start"]


async def over(hub) -> None:
    """Every call is over and its queue done, so no retry outlives the test (into the next one's fake Hermes)."""
    await until(lambda: hub.slot is None and all(call.inbox.finished for call in hub.history.values()), timeout=10)


@pytest.fixture
def mods(core):
    return types.SimpleNamespace(hubsock=core.loader.module("hubsock", PLUGIN_DIR),
                                 remote=core.loader.module("remote", PLUGIN_DIR))


@pytest.fixture
def fast(core, monkeypatch):
    """Retries a few times a second, for up to two seconds."""
    monkeypatch.setattr(core.hub, "HELD_RETRY_S", 0.05)
    monkeypatch.setattr(core.hub, "HELD_RETRY_LIMIT_S", 2.0)


# ── the refusal ────────────────────────────────────────────────────────────────────────────────────────────


def test_a_submit_refused_because_another_process_holds_the_chat_is_marked_held(core, fake):
    fake.host.add("s1")
    hold(fake)
    delivery = core.inject.TuiInjector().deliver(core.hub.Owner("s1"), "[Voice] hi")
    assert not delivery.ok and delivery.held and delivery.via == "submit"
    assert delivery.detail.startswith("This chat is open in another Hermes window/terminal")


@pytest.mark.parametrize("error", [
    {"code": 4090, "message": "Hermes is at the active session limit (4/4).",
     "data": {"reason": "MAX_CONCURRENT_SESSIONS"}},
    {"code": 4090, "message": "Hermes could not safely reserve this session. Try again.",
     "data": {"reason": "SESSION_COORDINATION_UNAVAILABLE"}},
    {"code": 5000, "message": "prompt.submit failed (ValueError)"},
])
def test_other_refusals_are_not_taken_for_a_held_chat(core, fake, error):
    fake.host.add("s1")
    hold(fake)
    fake.host.answers["prompt.submit"] = lambda params: {"error": error}
    delivery = core.inject.TuiInjector().deliver(core.hub.Owner("s1"), "[Voice] hi")
    assert not delivery.ok and not delivery.held


# ── kept, retried, announced, logged ───────────────────────────────────────────────────────────────────────


def test_turns_of_a_held_chat_are_kept_announced_once_and_delivered_in_order_when_it_frees(core, fake, make_hub,
                                                                                           fast):
    """The bug: the user calls from the app in a chat a Desktop backend holds. Every delivery was refused, logged
    to the dashboard's log and dropped; the user heard nothing."""
    hold(fake)
    hub = make_hub(injector=core.inject.TuiInjector())

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="s1")
            await phone.expect("speech_end")  # the hub's own line: the chat can't be reached
            await phone.say("first thing")
            await phone.say("second thing")
            # The first one is tried again (waited for, not slept for: a loaded machine retries late).
            await until(lambda: fake.host.methods_called().count("prompt.submit") >= 3)
            assert not hub.deliveries  # nothing given up, nothing in: all three wait
            said_once = spoken(phone)
            release(fake)
            await until(lambda: len(submitted(fake)) >= 3)
            await asyncio.sleep(0.2)
            await phone.hang_up()
            await until(lambda: len(submitted(fake)) >= 4)
            await over(hub)
            return said_once, spoken(phone)

    said_once, said = asyncio.run(scenario())
    assert said_once == said == [core.inject.CHAT_HELD_SPOKEN]  # once per call, through the hub's own speech
    texts = submitted(fake)
    assert [text.split("]")[0] for text in texts] == ["[Voice call started", "[Voice", "[Voice",
                                                      "[Voice call ended by user"]
    assert "first thing" in texts[1] and "second thing" in texts[2]  # in order, each once
    assert all("Delayed" in text and "another Hermes window" in text for text in texts[:3])
    assert "Delayed" not in texts[3]  # said after the chat was free again
    log = ring_log(fake)
    blocked = [entry for entry in log if entry["event"] == "chat_held"]
    assert len(blocked) == 1 and blocked[0]["session_id"] == "s1" and blocked[0]["announced"] is True
    late = [entry for entry in log if entry["event"] == "delivered_late"]
    assert [entry["what"] for entry in late] == ["call_started", "turn", "turn"]
    assert not [entry for entry in log if entry["event"] == "undelivered"]
    # Never what was said, nor the hub's spoken line.
    dump = json.dumps(log)
    assert "first thing" not in dump and "can't reach" not in dump


def test_a_turn_the_chat_never_takes_is_given_up_after_the_limit_and_logged(core, fake, make_hub, monkeypatch):
    monkeypatch.setattr(core.hub, "HELD_RETRY_S", 0.05)
    monkeypatch.setattr(core.hub, "HELD_RETRY_LIMIT_S", 0.3)
    hold(fake)
    hub = make_hub(injector=core.inject.TuiInjector())

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="s1")
            await phone.expect("speech_end")
            await phone.say("is anyone there")
            await until(lambda: len(hub.deliveries) >= 2)
            await phone.hang_up()
            await until(lambda: len(hub.deliveries) >= 3)
            await over(hub)
            return spoken(phone)

    said = asyncio.run(scenario())
    assert said == [core.inject.CHAT_HELD_SPOKEN]
    assert [(d.ok, d.held) for _, _, d in hub.deliveries] == [(False, True)] * 3
    lost = [entry for entry in ring_log(fake) if entry["event"] == "undelivered"]
    assert [entry["what"] for entry in lost] == ["call_started", "turn", "notice"]
    assert all(entry["reason"] == "chat_held" and entry["session_id"] == "s1" for entry in lost)
    assert "is anyone there" not in json.dumps(ring_log(fake))
    assert submitted(fake) == []


def test_a_delivery_that_fails_for_another_reason_is_logged_and_not_retried(core, fake, make_hub, fast):
    hold(fake)
    fake.host.answers["prompt.submit"] = lambda params: {"error": {"code": 5000, "message": "boom"}}
    hub = make_hub(injector=core.inject.TuiInjector())

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="s1")
            await until(lambda: len(hub.deliveries) >= 1)
            await asyncio.sleep(0.3)
            attempts = fake.host.methods_called().count("prompt.submit")
            await phone.hang_up()
            await over(hub)
            return attempts, spoken(phone)

    attempts, said = asyncio.run(scenario())
    assert attempts == 1 and said == []  # no retry (it may have been taken), and nothing claimed about the chat
    lost = [entry for entry in ring_log(fake) if entry["event"] == "undelivered"]
    assert lost and lost[0]["what"] == "call_started" and lost[0]["reason"] == "boom"


def test_an_agent_started_calls_notice_is_retried_too(core, fake, make_hub, fast):
    """The notice of a ring that ran out, for a chat that got held meanwhile: kept and retried like a turn (nothing
    is spoken: nobody is on the call)."""
    fake.host.add("s1")
    hub = make_hub(injector=core.inject.TuiInjector(), ring_timeout_s=0.3)
    hold(fake)

    async def scenario():
        result = await asyncio.to_thread(hub.start_call, core.hermes.Origin("s1", source="desktop"), "Hi", "async")
        assert result["status"] == "ringing"
        await until(lambda: any(entry["event"] == "chat_held" for entry in ring_log(fake)))
        release(fake)
        await until(lambda: submitted(fake))
        await over(hub)

    asyncio.run(scenario())
    assert submitted(fake)[0].startswith("[Voice line not delivered") and "Delayed" in submitted(fake)[0]
    blocked = [entry for entry in ring_log(fake) if entry["event"] == "chat_held"]
    assert len(blocked) == 1 and blocked[0]["announced"] is False


# ── through the process that holds the chat ────────────────────────────────────────────────────────────────


class Raw:
    """A bare client on the hub socket: a Hermes process that attends for the chats it holds."""

    def __init__(self, mods, folder) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(mods.hubsock.socket_path(folder))
        self.buffer = b""
        self.send({"op": "hello", "token": (folder / "hub.token").read_text().strip(), "version": 1})
        assert self.read()["ok"] is True

    def send(self, message: dict) -> None:
        self.sock.sendall((json.dumps(message) + "\n").encode())

    def read(self) -> dict:
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            assert chunk, "the hub closed the connection"
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def attend(self) -> dict:
        self.send({"id": 1, "op": "attend", "pid": 4242})
        return self.read()

    def close(self) -> None:
        self.sock.close()


@pytest.fixture
def open_socket(mods, fake, make_hub):
    servers = []

    def start(**hub_kw):
        hub = make_hub(**hub_kw)
        servers.append(mods.hubsock.HubServer(hub, fake.home / "hermes-voice").start())
        return hub

    yield start
    for server in servers:
        server.close()


def test_the_process_that_holds_the_chat_takes_the_turn(mods, core, fake, open_socket, fast):
    """Two processes attend. Both are asked whether they have the chat open; only the one that does is handed the
    text, and what it did with it is the delivery."""
    hold(fake)
    hub = open_socket(injector=core.inject.TuiInjector())
    folder = fake.home / "hermes-voice"

    async def scenario():
        async with serving(core) as port:
            bystander, holder = Raw(mods, folder), Raw(mods, folder)
            assert bystander.attend() == {"id": 1, "ok": True, "result": {"attending": True}}
            assert holder.attend()["ok"] is True
            phone = await Phone.dial(port, fake, session_id="s1")
            finds = [await asyncio.to_thread(client.read) for client in (bystander, holder)]
            bystander.send({"op": "attended", "seq": finds[0]["seq"], "session_id": None})
            holder.send({"op": "attended", "seq": finds[1]["seq"], "session_id": "s1", "holds": True})
            event = await asyncio.to_thread(holder.read)
            holder.send({"op": "attended", "seq": event["seq"], "ok": True, "via": "submit", "status": "streaming"})
            await until(lambda: hub.deliveries)
            await asyncio.sleep(0.2)
            said, log = spoken(phone), ring_log(fake)
            for client in (bystander, holder):
                client.close()
            release(fake)
            await phone.hang_up()
            await over(hub)
            return finds, event, said, log

    finds, event, said, log = asyncio.run(scenario())
    assert [(find["event"], find["session_ids"]) for find in finds] == [("find", ["s1"])] * 2
    assert "text" not in finds[0]  # what was said goes only to a process that has the chat
    assert (event["event"], event["session_id"]) == ("deliver", "s1")
    assert event["text"].startswith("[Voice call started]")
    _, _, delivery = hub.deliveries[0]
    assert (delivery.ok, delivery.via, delivery.status) == (True, "holder:submit", "streaming")
    assert said == []  # delivered: nothing to announce
    assert not [entry for entry in log if entry["event"] in ("chat_held", "undelivered", "delivered_late")]


def test_no_attending_process_has_the_chat_so_the_user_hears_it(mods, core, fake, open_socket, fast):
    hold(fake)
    hub = open_socket(injector=core.inject.TuiInjector())
    folder = fake.home / "hermes-voice"

    async def scenario():
        async with serving(core) as port:
            bystander = Raw(mods, folder)
            bystander.attend()

            def not_mine() -> dict:
                asked = bystander.read()
                bystander.send({"op": "attended", "seq": asked["seq"], "session_id": None})
                return asked

            answering = asyncio.create_task(asyncio.to_thread(not_mine))
            phone = await Phone.dial(port, fake, session_id="s1")
            await phone.expect("speech_end")
            asked = await answering
            said = spoken(phone)
            bystander.close()  # gone: the retries don't wait for it
            release(fake)
            await until(lambda: submitted(fake))
            await phone.hang_up()
            await over(hub)
            return asked, said

    asked, said = asyncio.run(scenario())
    assert asked["event"] == "find" and said == [core.inject.CHAT_HELD_SPOKEN]
    assert "Delayed" in submitted(fake)[0]


def test_a_holder_that_doesnt_say_what_it_did_is_final(mods, core, fake, open_socket, fast, monkeypatch):
    """Handed the text and silent: it may have taken it, so it is neither retried nor claimed delivered."""
    monkeypatch.setattr(mods.hubsock, "ACK_TIMEOUT", 0.3)
    hold(fake)
    hub = open_socket(injector=core.inject.TuiInjector())
    folder = fake.home / "hermes-voice"

    async def scenario():
        async with serving(core) as port:
            holder = Raw(mods, folder)
            holder.attend()
            phone = await Phone.dial(port, fake, session_id="s1")
            find = await asyncio.to_thread(holder.read)
            holder.send({"op": "attended", "seq": find["seq"], "session_id": "s1", "holds": True})
            await asyncio.to_thread(holder.read)  # the text; no answer
            await until(lambda: hub.deliveries)
            holder.close()
            release(fake)
            await phone.hang_up()
            await over(hub)

    asyncio.run(scenario())
    _, _, delivery = hub.deliveries[0]
    assert not delivery.ok and not delivery.held and "didn't say whether it took it" in delivery.detail
    lost = [entry for entry in ring_log(fake) if entry["event"] == "undelivered"]
    assert lost[0]["what"] == "call_started" and "didn't say" in lost[0]["reason"]


def test_an_attending_process_puts_the_text_into_the_session_it_holds(mods, core, fake, open_socket, monkeypatch):
    """remote.Attendant, in the process that holds the chat (here: the test process's fake session host). It says
    which chats it has open and injects into its own live session, never reopening one."""
    hub = open_socket()
    folder = fake.home / "hermes-voice"
    fake.host.add("s1", active_session_lease=types.SimpleNamespace(released=False))
    fake.host.add("viewed")  # open here, but another process holds it
    monkeypatch.setattr(mods.remote.Attendant, "eligible", lambda self: True)
    attendant = mods.remote.Attendant(folders=[folder], idle_s=0.05)
    assert attendant.find(["old-id", "s1"]) == {"session_id": "s1", "holds": True}
    assert attendant.find(["viewed"]) == {"session_id": "viewed", "holds": False}
    assert attendant.find(["elsewhere"]) == {"session_id": None}
    attendant.start()
    try:
        deadline = time.monotonic() + 5
        while not attendant.attending.is_set():
            assert time.monotonic() < deadline, "never attended"
            time.sleep(0.02)
        assert hub.holders(["elsewhere"], "[Voice] hi") is None  # not open there: not its to take
        delivery = hub.holders(["old-id", "s1"], "[Voice] hi there")
        assert delivery is not None and delivery.ok and delivery.via == "holder:redirect"
        assert ("session.redirect", {"session_id": "rt-s1", "text": "[Voice] hi there"}) in fake.host.calls
        # A chat it has open but may not write either: still held, so the hub keeps trying.
        hold(fake)
        assert hub.holders(["viewed"], "[Voice] again") is None
        assert "session.resume" not in fake.host.methods_called()  # never reopens a chat
    finally:
        attendant.close()


def test_a_process_attends_only_where_it_hosts_sessions_and_isnt_the_dashboard(mods, core, fake, make_hub,
                                                                                monkeypatch):
    make_hub()
    attendant = mods.remote.Attendant()
    assert core.hub.routes_mounted() and not attendant.eligible()  # the dashboard: its own hub delivers
    fake.bound_host = None  # a Desktop backend, an Ink TUI: hosts sessions, doesn't serve the phone
    assert attendant.eligible()
    monkeypatch.setenv("HERMES_COMPUTE_HOST_CHILD", "1")
    assert not attendant.eligible()  # its sessions are the dashboard's
    monkeypatch.delenv("HERMES_COMPUTE_HOST_CHILD")
    monkeypatch.delitem(sys.modules, "tui_gateway.server")
    assert not attendant.eligible()  # the CLI, a messaging gateway, cron: no session host


def test_a_subscribed_process_that_may_not_write_the_chat_says_held(mods, core, fake, make_hub):
    """inject.deliver_here in a process that has the chat open while another one holds it: reported as held (the
    hub then looks for the holder, or retries) instead of starting a turn Hermes would refuse later, unseen."""
    fake.host.add("s1")
    hold(fake)
    injected: list[str] = []
    ctx = types.SimpleNamespace(inject_message=lambda text, **_: injected.append(text) or True)
    target = core.inject.AgentTarget.capture("s1", "", None, ctx)
    delivery = core.inject.deliver_here(target, "[Voice] hi", core.inject.Turns())
    assert not delivery.ok and delivery.held and injected == []
