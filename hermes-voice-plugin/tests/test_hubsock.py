"""The hub's socket for other Hermes processes (hubsock.py): where it lives and who may use it, the line protocol,
waits that a client stops or abandons, and routes that hand a call's turns to the conversation's process."""

from __future__ import annotations

import asyncio
import json
import os
import socket
import stat
import time
import types
import uuid
from pathlib import Path

import pytest

from support import PLUGIN_DIR, FakePusher, Phone, serving, until


@pytest.fixture
def mods(core):
    return types.SimpleNamespace(hubsock=core.loader.module("hubsock", PLUGIN_DIR),
                                 remote=core.loader.module("remote", PLUGIN_DIR))


@pytest.fixture
def open_socket(mods, fake, make_hub):
    """Open a hub's socket (default: a fresh hub, in the fake HERMES_HOME); closed after the test."""
    servers = []

    def start(hub=None, folder: Path | None = None, **hub_kw):
        hub = hub or make_hub(**hub_kw)
        server = mods.hubsock.HubServer(hub, folder or fake.home / "hermes-voice").start()
        servers.append(server)
        return hub, server

    yield start
    for server in servers:
        server.close()


class Raw:
    """A bare client on the socket (no remote.py), to test the protocol itself."""

    def __init__(self, mods, folder: Path) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(mods.hubsock.socket_path(folder))
        self.buffer = b""

    def send(self, message) -> None:
        data = message if isinstance(message, bytes) else (json.dumps(message) + "\n").encode()
        self.sock.sendall(data)

    def read(self) -> dict | None:
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def hello(self, token: str) -> dict | None:
        self.send({"op": "hello", "token": token, "version": 1})
        return self.read()

    def close(self) -> None:
        self.sock.close()


def _origin(**fields):
    return {"session_id": "tg-1", "platform": "telegram", "chat_type": "dm", "user_id": "42", "is_owner": True,
            "session_key": "agent:main:telegram:dm:42", **fields}


# ── where it lives and who may use it ──────────────────────────────────────────────────────────────────────


def test_socket_and_token_are_private_and_the_token_is_required(mods, fake, open_socket):
    hub, server = open_socket()
    folder = fake.home / "hermes-voice"
    assert stat.S_IMODE(folder.stat().st_mode) == 0o700
    assert stat.S_IMODE(os.stat(mods.hubsock.socket_path(folder)).st_mode) == 0o600
    token_file = folder / "hub.token"
    assert stat.S_IMODE(token_file.stat().st_mode) == 0o600
    token = token_file.read_text().strip()
    assert len(token) == 64 and token == server.token

    wrong = Raw(mods, folder)
    assert wrong.hello("0" * 64) == {"op": "hello", "ok": False, "error": "auth"}
    assert wrong.read() is None  # and closed
    skipped = Raw(mods, folder)
    skipped.send({"id": 1, "op": "status"})  # a request before the hello
    assert skipped.read() == {"op": "hello", "ok": False, "error": "auth"} and skipped.read() is None

    good = Raw(mods, folder)
    assert good.hello(token) == {"op": "hello", "ok": True, "version": 1}
    good.send({"id": 7, "op": "status"})
    answer = good.read()
    assert answer["id"] == 7 and answer["ok"] is True and answer["result"]["active_call"] is None
    good.close()


def test_a_fresh_token_every_start_and_files_go_with_the_server(mods, fake, make_hub):
    hub = make_hub()
    folder = fake.home / "hermes-voice"
    first = mods.hubsock.HubServer(hub, folder).start()
    token = first.token
    first.close()
    assert not (folder / "hub.sock").exists() and not (folder / "hub.token").exists()
    second = mods.hubsock.HubServer(hub, folder).start()
    try:
        assert second.token != token and (folder / "hub.token").read_text().strip() == second.token
    finally:
        second.close()


def test_the_peer_is_this_user(mods):
    left, right = socket.socketpair(socket.AF_UNIX)
    try:
        uid = mods.hubsock.peer_uid(left)
        if uid is None:
            pytest.skip("this OS doesn't report a Unix socket peer's credentials")
        assert uid == os.getuid()
    finally:
        left.close()
        right.close()


def test_a_path_too_long_for_a_unix_socket_is_bound_elsewhere_and_linked(mods, fake, open_socket, make_hub):
    folder = fake.home / ("deep-" * 20) / "hermes-voice"
    assert len(os.fsencode(str(folder / "hub.sock"))) > mods.hubsock.SUN_PATH_MAX
    hub, server = open_socket(folder=folder)
    link = folder / "hub.sock"
    assert link.is_symlink()
    short = server.short_dir
    assert stat.S_IMODE(os.stat(short).st_mode) == 0o700
    status = mods.remote.Client.connect([folder]).request("status")
    assert status["active_call"] is None
    server.close()
    assert not link.exists() and not link.is_symlink() and not os.path.exists(short)


def test_a_stale_socket_is_replaced_and_a_live_one_is_left_alone(mods, fake, open_socket, make_hub):
    import tempfile
    folder = fake.home / "hermes-voice"
    folder.mkdir(parents=True)
    # What a dashboard that died leaves behind (its socket path was too long, so it is a link): nobody listens.
    dead_dir = tempfile.mkdtemp(prefix="hermes-voice-", dir=mods.hubsock._short_tmp())
    dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    dead.bind(os.path.join(dead_dir, "hub.sock"))
    dead.close()
    os.symlink(os.path.join(dead_dir, "hub.sock"), folder / "hub.sock")
    hub, server = open_socket(folder=folder)
    assert not os.path.exists(dead_dir)
    assert mods.remote.Client.connect([folder]).request("status")["calls"] == 0
    with pytest.raises(RuntimeError, match="already serves"):
        mods.hubsock.HubServer(make_hub(), folder).start()
    assert (folder / "hub.token").read_text().strip() == server.token  # the live one's token stays
    assert mods.remote.Client.connect([folder]).request("status")["calls"] == 0


# ── the protocol ───────────────────────────────────────────────────────────────────────────────────────────


def test_bad_requests_get_errors_and_an_oversized_line_closes(mods, fake, open_socket):
    hub, server = open_socket()
    folder = fake.home / "hermes-voice"
    client = Raw(mods, folder)
    client.hello(server.token)
    client.send(b"not json\n")
    assert client.read()["error"] == "bad_json"
    client.send({"op": "status"})
    assert client.read()["error"] == "bad_request"
    client.send({"id": 1, "op": "launch"})
    assert client.read() == {"id": 1, "ok": False, "error": "unknown_op", "message": "unknown op 'launch'"}
    client.send({"id": 2, "op": "ring", "origin": {"platform": "telegram"}, "text": "hi"})
    assert client.read()["message"] == "origin.session_id is required"
    client.send({"id": 3, "op": "ring", "origin": _origin(), "text": "  "})
    assert client.read()["message"] == "text is required"
    client.send({"id": 4, "op": "await_turn", "waiter": "nope"})
    assert client.read()["error"] == "unknown_waiter"
    client.send(b"x" * (70 * 1024))
    assert client.read() is None


def test_an_origin_is_taken_field_by_field(mods):
    origin = mods.hubsock.origin_from({**_origin(), "runtime_sid": "rt-1", "profile_home": "/elsewhere",
                                       "is_cron": "yes", "user_turn_at": 12.5, "title": "x" * 999})
    assert origin.runtime_sid == "" and origin.profile_home is None  # another process's: meaningless here
    assert origin.is_cron is False and origin.is_owner is True and origin.user_turn_at == 12.5
    assert len(origin.title) == 256 and origin.profile == "default"
    with pytest.raises(mods.hubsock.ProtocolError):
        mods.hubsock.origin_from(["tg-1"])


def test_speak_never_rings(mods, fake, open_socket):
    pusher = FakePusher()
    hub, server = open_socket(pusher=pusher)
    client = mods.remote.Client.connect([fake.home / "hermes-voice"])
    result = client.request("speak", {"origin": _origin(), "text": "Hello"})
    assert result["status"] == "no_call" and result["call_id"] is None and pusher.payloads == []


# ── waits ──────────────────────────────────────────────────────────────────────────────────────────────────


def _ring_sync(mods, folder, text="Ship it?"):
    client = mods.remote.Client.connect([folder])
    answer = client.request("ring", {"origin": _origin(), "text": text, "mode": "sync"}, timeout=30)
    assert answer["status"] == "waiting" and len(answer["waiter"]) == 16
    return client, answer


def test_a_client_that_stops_its_wait_is_told_and_its_line_cancelled(mods, core, fake, open_socket):
    from support import PacedSpeech
    pusher = FakePusher()
    hub, server = open_socket(pusher=pusher, tts=PacedSpeech(delay=0.05))
    folder = fake.home / "hermes-voice"

    async def scenario():
        async with serving(core) as port:
            client, answer = await asyncio.to_thread(_ring_sync, mods, folder, " ".join(["word"] * 80))
            phone = await _pick_up(port, fake, pusher)
            await phone.expect("speech_start")
            stops = iter([[], [{"interrupt": True}]])
            result = await asyncio.to_thread(client.request, "await_turn", {"waiter": answer["waiter"]}, None,
                                             lambda: next(stops, []))
            end = await phone.expect("speech_end")
            await phone.hang_up()
            client.close()
            return result, end

    result, end = asyncio.run(scenario())
    assert result["status"] == "interrupted" and result["call_id"]
    assert end.get("cancelled") is True


def test_a_wait_nobody_collects_gives_the_turns_back(mods, fake, open_socket):
    hub, server = open_socket(pusher=FakePusher())
    client, answer = _ring_sync(mods, fake.home / "hermes-voice")
    call = hub.slot
    assert call.waiter is not None and server.waiters
    client.close()  # the process went away before collecting the reply
    asyncio.run(until(lambda: call.waiter is None))
    assert server.waiters == {}


def test_a_capped_wait_says_why_it_stopped(mods, fake, open_socket):
    pusher = FakePusher()
    hub, server = open_socket(pusher=pusher)
    folder = fake.home / "hermes-voice"
    client, answer = _ring_sync(mods, folder)
    started = time.monotonic()
    result = client.request("await_turn", {"waiter": answer["waiter"], "cap_s": 0.5}, timeout=None)
    assert time.monotonic() - started < 5
    assert result["outcome"] == "answered" and result["said"] == ""
    assert "approvals.timeout + 60 s" in result["note"] and "[Voice]" in result["note"]
    client.close()


def test_a_wait_yields_when_the_client_asks(mods, fake, open_socket):
    pusher = FakePusher()
    hub, server = open_socket(pusher=pusher)
    client, answer = _ring_sync(mods, fake.home / "hermes-voice")
    signals = iter([[], [{"yield": True}]])
    result = client.request("await_turn", {"waiter": answer["waiter"]}, timeout=None,
                            watch=lambda: next(signals, []))
    assert result["status"] == "yielded" and "is still being spoken" in result["note"]
    client.close()


# ── routes ─────────────────────────────────────────────────────────────────────────────────────────────────


def test_turns_wait_for_a_subscriber_and_a_call_nobody_holds_ends(mods, fake, open_socket, monkeypatch):
    monkeypatch.setattr(mods.hubsock, "SUBSCRIBER_GRACE", 0.6)
    pusher = FakePusher()
    hub, server = open_socket(pusher=pusher)
    folder = fake.home / "hermes-voice"
    client = mods.remote.Client.connect([folder])
    started = client.request("ring", {"origin": _origin(), "text": "Hi"})
    call = hub.slot
    assert started["status"] == "ringing" and call.owner.remote and call.route is not None
    assert call.owner.key == "agent:main:telegram:dm:42" and call.owner.source == "telegram"
    # Nobody subscribed: the call is over after the grace, and the phone hears so.
    deadline = time.monotonic() + 5
    while call.state != "ended" and time.monotonic() < deadline:
        time.sleep(0.05)
    assert (call.outcome, call.detail) == ("ended_by_agent", "the conversation's Hermes process went away")
    client.close()


def test_a_subscriber_gets_turns_and_reports_what_it_did(mods, core, fake, open_socket):
    pusher = FakePusher()
    hub, server = open_socket(pusher=pusher)
    folder = fake.home / "hermes-voice"

    async def scenario():
        async with serving(core) as port:
            ringer = mods.remote.Client.connect([folder])
            started = await asyncio.to_thread(ringer.request, "ring", {"origin": _origin(), "text": "Hi"})
            sub = mods.remote.Client.connect([folder])
            answer = await asyncio.to_thread(sub.request, "subscribe_turns",
                                             {"call_id": started["call_id"], "origin": _origin()})
            stranger = mods.remote.Client.connect([folder])
            with pytest.raises(mods.remote.RemoteError, match="not_owner"):
                await asyncio.to_thread(stranger.request, "subscribe_turns",
                                        {"call_id": started["call_id"], "origin": _origin(session_id="x",
                                                                                          session_key="y")})
            phone = await _pick_up(port, fake, pusher)
            await phone.expect("speech_end")
            await phone.say("hello there")
            event = await asyncio.to_thread(sub.recv, 5)
            await asyncio.to_thread(sub.send, {"op": "delivered", "call_id": started["call_id"],
                                               "seq": event["seq"], "ok": True, "via": "redirect",
                                               "status": "redirected"})
            await until(lambda: hub.deliveries)
            await phone.hang_up()
            notice = await asyncio.to_thread(sub.recv, 5)
            await asyncio.to_thread(sub.send, {"op": "delivered", "call_id": started["call_id"],
                                               "seq": notice["seq"], "ok": True, "via": "inject"})
            ended = [notice, await asyncio.to_thread(sub.recv, 5)]
            for client in (ringer, sub, stranger):
                client.close()
            return answer, event, ended

    answer, event, ended = asyncio.run(scenario())
    assert answer == {"subscribed": True, "call_id": event["call_id"]}
    assert event["event"] == "turn" and event["text"].startswith("[Voice] hello there")
    call_id, text, delivery = hub.deliveries[0]
    assert (delivery.ok, delivery.via, delivery.status) == (True, "redirect", "redirected")
    # The hang-up notice, then the end of the call.
    assert ended[0]["event"] == "turn" and ended[0]["text"].startswith("[Voice call ended by user]")
    assert ended[1] == {"event": "ended", "call_id": call_id, "outcome": "ended_by_user"}


def test_a_compute_host_child_takes_a_dashboard_calls_turns_and_hands_them_back(mods, core, fake, open_socket):
    """Turns of a dashboard session run in a compute-host child (dashboard.turn_isolation): the child subscribes to
    the call the user started and steers its own agent; once it leaves, the dashboard delivers again, at once."""
    fake.host.add("s1")
    hub, server = open_socket()
    folder = fake.home / "hermes-voice"

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="s1")
            await hub.injector.wait_for(1)  # [Voice call started], by the dashboard itself
            child = mods.remote.Client.connect([folder])
            answer = await asyncio.to_thread(child.request, "subscribe_turns", {
                "call_id": phone.call_id, "origin": {"session_id": "s1", "source": "dashboard"}})
            await phone.say("hello")
            event = await asyncio.to_thread(child.recv, 5)
            await asyncio.to_thread(child.send, {"op": "delivered", "call_id": phone.call_id, "seq": event["seq"],
                                                 "ok": True, "via": "redirect", "status": "redirected"})
            await until(lambda: len(hub.deliveries) >= 2)
            child.close()
            await asyncio.sleep(0.2)
            started = time.monotonic()
            await phone.say("again")
            texts = await hub.injector.wait_for(2, timeout=5)
            took = time.monotonic() - started
            await phone.hang_up()
            return answer, event, texts, took

    answer, event, texts, took = asyncio.run(scenario())
    assert answer["subscribed"] is True and event["text"].startswith("[Voice] hello")
    assert texts[1].startswith("[Voice] again") and took < 3
    assert not hub.history[event["call_id"]].owner.remote


@pytest.mark.parametrize("platform", ["", "telegram"])
def test_what_the_process_cant_deliver_is_tried_here_only_for_open_dashboard_sessions(mods, core, fake, make_hub,
                                                                                    platform):
    """A compute-host child can't start a turn when its conversation is idle; the dashboard has the session open
    and can. A messaging chat is never reopened in the dashboard."""
    from support import RecordingInjector

    class Live(RecordingInjector):
        def deliver_live(self, owner, text):
            return self.deliver(owner, text)

    hub = make_hub(injector=Live())
    origin = core.hermes.Origin(session_id="s1", source="dashboard", platform=platform)
    call = core.hub.Call(hub, uuid.uuid4().hex, core.hub.Owner.from_origin(origin, remote=True), "agent", "live")

    class Refusing:
        def deliver(self, text):
            return core.inject.Delivery(False, "inject", detail="no host here", fallback=True)

    call.route = Refusing()
    delivery = hub.deliver(call, "[Voice] hi")
    if platform:
        assert not delivery.ok and delivery.detail == "no host here" and hub.injector.texts() == []
    else:
        assert delivery.ok and hub.injector.texts() == ["[Voice] hi"]


def test_a_subscriber_that_goes_away_mid_call_ends_it_after_the_grace(mods, core, fake, open_socket, monkeypatch):
    """The conversation's process dies with the call live: no one holds the call's turns any more, so after
    SUBSCRIBER_GRACE the call ends and the phone hears so (the grace starts again when a subscriber leaves)."""
    monkeypatch.setattr(mods.hubsock, "SUBSCRIBER_GRACE", 0.6)
    pusher = FakePusher()
    hub, server = open_socket(pusher=pusher)
    folder = fake.home / "hermes-voice"

    async def scenario():
        async with serving(core) as port:
            ringer = mods.remote.Client.connect([folder])
            started = await asyncio.to_thread(ringer.request, "ring", {"origin": _origin(), "text": "Hi"})
            sub = mods.remote.Client.connect([folder])
            await asyncio.to_thread(sub.request, "subscribe_turns", {"call_id": started["call_id"],
                                                                     "origin": _origin()})
            phone = await _pick_up(port, fake, pusher)
            await phone.expect("speech_end")
            call = hub.slot
            await asyncio.sleep(1.0)  # past the first grace: the subscriber holds the call
            assert call.state == "live"
            sub.close()  # the process went away
            ringer.close()
            ended = await phone.expect("ended", timeout=5)
            return call, ended

    call, ended = asyncio.run(scenario())
    assert (call.outcome, call.detail) == ("ended_by_agent", "the conversation's Hermes process went away")
    assert ended == {"type": "ended", "outcome": "ended_by_agent"}


def test_in_a_short_folder_the_socket_is_bound_in_place_and_only_its_own_server_removes_it(mods, fake, make_hub):
    """~/.hermes/hermes-voice is short: the socket is bound at hub.sock itself (no link). A dashboard that is
    closing must not remove its successor's socket, which took the same path in the meantime."""
    import shutil
    import tempfile
    root = tempfile.mkdtemp(prefix="hv-", dir="/tmp")
    folder = Path(root) / "hermes-voice"
    try:
        folder.mkdir()
        dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)  # what a dashboard killed with SIGKILL leaves
        dead.bind(str(folder / "hub.sock"))
        dead.close()
        first = mods.hubsock.HubServer(make_hub(), folder).start()
        assert not (folder / "hub.sock").is_symlink() and first.bound == str(folder / "hub.sock")
        assert mods.remote.Client.connect([folder]).request("status")["calls"] == 0  # the stale one replaced
        first.sock.close()  # it starts closing: no longer listening...
        second = mods.hubsock.HubServer(make_hub(), folder).start()  # ...and the next dashboard takes over
        first.close()  # ...then the first one finishes closing
        assert (folder / "hub.sock").exists() and (folder / "hub.token").read_text().strip() == second.token
        assert mods.remote.Client.connect([folder]).request("status")["calls"] == 0
        second.close()
        assert not (folder / "hub.sock").exists() and not (folder / "hub.token").exists()
    finally:
        shutil.rmtree(root, ignore_errors=True)


@pytest.fixture
def socket_key(core, monkeypatch):
    """The process's hub socket, opened the way the dashboard opens it (serve_socket_when_ready)."""
    import sys
    monkeypatch.delenv("HERMES_VOICE_HUB_SOCKET", raising=False)
    monkeypatch.setattr(core.hub, "SOCKET_RETRY_S", 0.1)
    sys.__dict__.pop(core.hub._SOCKET_KEY, None)
    yield core.hub._SOCKET_KEY
    core.hub.pause_socket()
    sys.__dict__.pop(core.hub._SOCKET_KEY, None)


def test_the_dashboard_takes_the_socket_over_once_another_one_lets_it_go(mods, core, fake, make_hub, socket_key):
    folder = fake.home / "hermes-voice"
    make_hub()
    other = mods.hubsock.HubServer(make_hub(), folder).start()  # another dashboard in the same home
    core.hub.serve_socket_when_ready()
    asyncio.run(until(lambda: core.hub.socket_state() == "taken"))
    assert core.hub.get_hub().status()["hub_socket"] == "taken"
    other.close()
    asyncio.run(until(lambda: core.hub.socket_state() == "open", timeout=5))
    assert mods.remote.Client.connect([folder]).request("status")["hub_socket"] == "open"
    # The plugin unloads: no process rings through it any more; loading it again opens the socket again.
    core.hub.pause_socket()
    assert core.hub.socket_state() == "paused"
    with pytest.raises(mods.remote.NotAvailable):
        mods.remote.Client.connect([folder])
    core.hub.resume_socket()
    asyncio.run(until(lambda: core.hub.socket_state() == "open", timeout=5))
    assert mods.remote.Client.connect([folder]).request("status")["calls"] == 0


def test_another_profiles_process_rings_only_when_allowed_and_never_vouches_for_the_owner(mods, core, fake,
                                                                                      open_socket):
    """A profile without a dashboard of its own finds the root profile's hub. Its allowlist and pairings say
    nothing about this profile's owner."""
    pusher = FakePusher()
    folder = fake.home / "hermes-voice"
    hub, server = open_socket(pusher=pusher)
    client = mods.remote.Client.connect([folder])
    refused = client.request("ring", {"origin": _origin(profile="family"), "text": "Hi"})
    assert refused["status"] == "not_allowed" and "allowed_profiles" in refused["note"] and pusher.payloads == []
    server.close()
    entries = [json.loads(line) for line in (fake.home / "hermes-voice" / "rings.jsonl").read_text().splitlines()]
    assert (entries[-1]["reason"], entries[-1]["source"]) == ("profile", "family")

    allowed = core.config.PolicyConfig(allowed_profiles=("family",))
    hub, server = open_socket(pusher=pusher, settings=core.config.Settings(fake_tts=True, policy=allowed))
    client = mods.remote.Client.connect([folder])
    not_owner = client.request("ring", {"origin": _origin(profile="family"), "text": "Hi"})
    assert not_owner["status"] == "not_allowed" and pusher.payloads == []  # is_owner from it doesn't count
    server.close()
    named = core.config.PolicyConfig(allowed_profiles=("family",), owner_ids=("telegram:42",))
    hub, server = open_socket(pusher=pusher, settings=core.config.Settings(fake_tts=True, policy=named))
    client = mods.remote.Client.connect([folder])
    rang = client.request("ring", {"origin": _origin(profile="family"), "text": "Hi"})
    assert rang["status"] == "ringing" and len(pusher.payloads) == 1 and pusher.payloads[0]["profile"] == "family"
    client.close()


def test_without_previews_the_voip_push_carries_no_title(core, fake, make_hub, monkeypatch):
    fake.config = {"plugins": {"entries": {"hermes_voice": {"settings": {"alerts": {"previews": False}}}}}}
    monkeypatch.setattr(core.notify, "_settings_cache", (0.0, None))
    pusher = FakePusher()
    make_hub(pusher=pusher)
    fake.host.add("s1", title="Divorce lawyer")
    result = json.loads(core.tools.start_call({"text": "Hi"}, session_id="s1"))
    asyncio.run(until(lambda: pusher.payloads))
    assert result["status"] == "ringing" and pusher.payloads[0]["title"] == "Hermes"


# ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────


async def _pick_up(port: int, fake, pusher: FakePusher) -> Phone:
    await asyncio.to_thread(pusher.pushed.wait, 5)
    payload = pusher.payloads[-1]
    phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push",
                             session_id=payload["session_id"])
    await phone.send({"type": "ringing"})
    await phone.send({"type": "answered"})
    return phone
