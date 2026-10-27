"""Alert pushes against a mock APNs: approvals and questions that wait with no client attached, finished turns,
the payload per kind, the alert headers, each phone's choices, the host's settings, and nothing secret in the log."""

from __future__ import annotations

import asyncio
import importlib.util
import json
import logging
import sys
import types
import uuid

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from support import PLUGIN_DIR, PREFIX, serving, until

VOIP, ALERT, OTHER = "ab" * 32, "cd" * 32, "ef" * 32
KEY_ID, TEAM_ID = "KEY1234567", "TEAM123456"
BUNDLE = "com.example.hermesvoice"
APPROVAL_ID, CLARIFY_ID = "srq-aaaaaaaaaaaa", "srq-bbbbbbbbbbbb"


class MockApns:
    """Answers like APNs; `script` is a list of (status, reason) for successive requests (then 200)."""

    def __init__(self, *script: tuple[int, str]) -> None:
        self.script = list(script)
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.script:
            status, reason = self.script.pop(0)
            return httpx.Response(status, json={"reason": reason})
        return httpx.Response(200, headers={"apns-id": "x"})

    def payloads(self) -> list[dict]:
        return [json.loads(request.content) for request in self.requests]

    def tokens(self) -> list[str]:
        return [request.url.path.rsplit("/", 1)[-1] for request in self.requests]


@pytest.fixture
def key_path(fake, tmp_path):
    private = ec.generate_private_key(ec.SECP256R1())
    path = tmp_path / "AuthKey.p8"
    path.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    fake.secrets.update({"HERMES_VOICE_APNS_KEY_PATH": str(path), "HERMES_VOICE_APNS_KEY_ID": KEY_ID,
                         "HERMES_VOICE_APNS_TEAM_ID": TEAM_ID})
    return path


class Host:
    """The dashboard's session host as notify.py reads it: live conversations, their clients and their open
    server requests (on the fake ``tui_gateway.server``)."""

    def __init__(self, fake) -> None:
        self.fake = fake
        self.requests: dict[str, list[dict]] = {}
        module = fake.host.module
        module._open_requests = lambda sid: [dict(item) for item in self.requests.get(sid, [])]
        module._session_live_transports = lambda record: [record["client"]] if record.get("client") else []

    def add(self, key: str, title: str = "Deploy chat", **extra) -> str:
        return self.fake.host.add(key, title=title, **extra)

    def record(self, sid: str) -> dict:
        return self.fake.host.sessions[sid]

    def attach(self, sid: str) -> None:
        self.record(sid)["client"] = object()

    def detach(self, sid: str) -> None:
        self.record(sid).pop("client", None)

    def approval(self, sid: str, rid: str = APPROVAL_ID, **params) -> None:
        params = {"request_id": "appr-1", "command": "rm -rf build/ --token=hunter2",
                  "description": "recursive delete", "choices": ["once", "session", "always", "deny"], **params}
        self.requests.setdefault(sid, []).append({"id": rid, "method": "approval",
                                                  "params": {"session_id": sid, **params}})

    def clarify(self, sid: str, questions: list[dict], rid: str = CLARIFY_ID) -> None:
        self.requests.setdefault(sid, []).append({"id": rid, "method": "clarify",
                                                  "params": {"session_id": sid, "questions": questions}})

    def answer(self, sid: str, rid: str) -> None:
        self.requests[sid] = [item for item in self.requests.get(sid, []) if item["id"] != rid]


QUESTIONS = [
    {"qid": "q1", "question": "Which environment?", "choices": ["staging", "production"], "multi_select": False},
    {"qid": "q2", "question": "Anything to skip?", "choices": None, "multi_select": False},
]


@pytest.fixture
def env(core, fake, tmp_path, key_path, make_hub):
    """A host, a phone registered for calls and alerts, a mock APNs and a watcher on a hand-moved clock."""
    host = Host(fake)
    hub = make_hub()
    mock = MockApns()
    store = core.push.DeviceStore(lambda: tmp_path / "hermes-voice")
    store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT))
    apns = core.push.Apns(store, transport=httpx.MockTransport(mock), clock=lambda: 1_000_000.0)
    now = [100.0]
    settings = [core.notify.AlertSettings()]
    alerts = core.notify.Alerts(pusher=lambda: apns, settings=lambda: settings[0], clock=lambda: now[0])
    return types.SimpleNamespace(fake=fake, host=host, hub=hub, mock=mock, store=store, apns=apns, now=now,
                                 settings=settings, alerts=alerts)


def at(env, moment: float) -> int:
    env.now[0] = moment
    return env.alerts.tick()


# ── approvals and questions ────────────────────────────────────────────────────────────────────────────────


def test_an_approval_waiting_with_no_client_alerts_after_the_grace(core, env):
    sid = env.host.add("s1")
    env.host.approval(sid)
    assert [at(env, 100.0), at(env, 104.9)] == [0, 0] and env.mock.requests == []
    assert at(env, 105.0) == 1
    assert [at(env, 106.0), at(env, 200.0)] == [0, 0]  # once per request
    request = env.mock.requests[0]
    assert str(request.url) == f"https://api.sandbox.push.apple.com/3/device/{ALERT}"  # the alert token, not VoIP
    assert request.headers["apns-push-type"] == "alert"
    assert request.headers["apns-topic"] == BUNDLE  # the app itself, not <bundle>.voip
    assert request.headers["apns-priority"] == "10"
    assert request.headers["apns-expiration"] == str(1_000_000 + 900)
    assert request.headers["apns-collapse-id"] == APPROVAL_ID
    assert request.headers["authorization"].startswith("bearer ")
    assert json.loads(request.content) == {
        "aps": {"alert": {"title": "Deploy chat", "body": "recursive delete"}, "category": "HERMES_APPROVAL",
                "thread-id": "s1", "sound": "default"},
        "hermes": {"kind": "approval", "session_id": "s1", "profile": "default", "request_id": APPROVAL_ID,
                   "choices": ["once", "session", "always", "deny"]},
    }
    assert b"hunter2" not in request.content and b"rm -rf" not in request.content  # no command on APNs


def test_a_question_alerts_with_its_questions(core, env):
    sid = env.host.add("s1")
    env.host.clarify(sid, QUESTIONS)
    at(env, 100.0)
    assert at(env, 105.0) == 1
    payload = env.mock.payloads()[0]
    assert payload == {
        "aps": {"alert": {"title": "Deploy chat", "body": "Which environment? (+1 more)"},
                "category": "HERMES_CLARIFY", "thread-id": "s1", "sound": "default"},
        "hermes": {"kind": "clarify", "session_id": "s1", "profile": "default", "request_id": CLARIFY_ID,
                   "questions": QUESTIONS},
    }
    assert env.mock.requests[0].headers["apns-collapse-id"] == CLARIFY_ID


def test_the_thread_follows_the_conversation_through_compression(core, env, monkeypatch):
    sid = env.host.add("s1", profile_home="/srv/hermes/profiles/work")
    monkeypatch.setattr(sys.modules["hermes_constants"], "profile_name_for_home",
                        lambda home: home.rsplit("/", 1)[-1], raising=False)
    env.fake.host.rotate(sid, "s1-continued")
    env.host.approval(sid)
    at(env, 100.0)
    at(env, 105.0)
    payload = env.mock.payloads()[0]
    assert payload["aps"]["thread-id"] == payload["hermes"]["session_id"] == "s1-continued"
    assert payload["hermes"]["profile"] == "work"


def test_an_attached_client_holds_alerts_back(core, env):
    sid = env.host.add("s1")
    env.host.attach(sid)
    env.host.approval(sid)
    assert [at(env, t) for t in (100.0, 110.0, 200.0)] == [0, 0, 0]
    env.host.detach(sid)  # the phone locked, the Desktop window closed: the grace starts now
    assert [at(env, 201.0), at(env, 205.0)] == [0, 0]
    env.host.attach(sid)  # back within the grace: it starts over once the client leaves again
    assert at(env, 205.5) == 0
    env.host.detach(sid)
    assert [at(env, 206.0), at(env, 210.9), at(env, 211.0)] == [0, 0, 1]


def test_a_request_answered_within_the_grace_never_alerts(core, env):
    sid = env.host.add("s1")
    env.host.approval(sid)
    at(env, 100.0)
    env.host.answer(sid, APPROVAL_ID)
    assert [at(env, 103.0), at(env, 110.0)] == [0, 0] and env.mock.requests == []
    assert env.alerts.waiting == {}


def test_other_server_requests_and_finished_sessions_say_nothing(core, env):
    sid = env.host.add("s1")
    env.host.requests[sid] = [{"id": "srq-cccccccccccc", "method": "sudo", "params": {"session_id": sid}}]
    gone = env.host.add("s2", _finalized=True)
    env.host.approval(gone)
    assert [at(env, 100.0), at(env, 110.0)] == [0, 0] and env.mock.requests == []


def test_each_phone_chooses_its_alerts(core, env, tmp_path):
    env.store.register(core.push.Device("12" * 32, "production", BUNDLE, OTHER, alerts={"clarify": False}))
    env.store.register(core.push.Device("34" * 32, "sandbox", BUNDLE))  # rings, takes no alerts
    sid = env.host.add("s1")
    env.host.clarify(sid, QUESTIONS)
    at(env, 100.0)
    at(env, 105.0)
    assert env.mock.tokens() == [ALERT]
    env.mock.requests.clear()
    env.host.answer(sid, CLARIFY_ID)
    env.host.approval(sid)
    at(env, 110.0)
    at(env, 115.0)
    assert sorted(env.mock.tokens()) == sorted([ALERT, OTHER])
    assert {request.url.host for request in env.mock.requests} == {"api.push.apple.com",
                                                                     "api.sandbox.push.apple.com"}


def test_the_host_can_turn_alerts_off(core, env):
    sid = env.host.add("s1")
    env.host.approval(sid)
    env.settings[0] = core.notify.AlertSettings(kinds=frozenset({"clarify", "turn_done"}))
    assert [at(env, 100.0), at(env, 110.0)] == [0, 0]
    env.settings[0] = core.notify.AlertSettings(enabled=False)
    env.host.clarify(sid, QUESTIONS)
    assert [at(env, 120.0), at(env, 130.0)] == [0, 0] and env.mock.requests == []

    parsed = core.notify.AlertSettings.from_plugin_settings(
        {"alerts": {"turn_done": False, "grace_s": "12", "previews": "off"}})
    assert parsed == core.notify.AlertSettings(kinds=frozenset({"approval", "clarify"}), grace_s=12.0,
                                               previews=False)
    assert core.notify.AlertSettings.from_plugin_settings({"alerts": {"grace_s": 9999}}).grace_s == 120.0
    assert core.notify.AlertSettings.from_plugin_settings({}) == core.notify.AlertSettings()


def test_without_previews_no_conversation_text_goes_to_apns(core, env):
    env.settings[0] = core.notify.AlertSettings(previews=False)
    sid = env.host.add("s1")
    env.host.approval(sid)
    env.host.clarify(sid, QUESTIONS)
    at(env, 100.0)
    assert at(env, 105.0) == 2
    approval, clarify = sorted(env.mock.payloads(), key=lambda p: p["hermes"]["kind"])
    assert approval["aps"]["alert"]["body"] == "Hermes is waiting for your approval."
    assert clarify["aps"]["alert"]["body"] == "Hermes has a question for you."
    assert clarify["hermes"]["questions"] == []  # the phone opens the conversation to answer
    assert "recursive" not in json.dumps(approval) and "environment" not in json.dumps(clarify)
    assert approval["aps"]["alert"]["title"] == clarify["aps"]["alert"]["title"] == "Hermes"
    env.alerts.note_reply("s1", "the launch codes are 1234")
    env.alerts.turn_ended("s1", "t", completed=True)
    at(env, 110.0)
    assert env.mock.payloads()[-1]["aps"]["alert"] == {"title": "Hermes", "body": "Hermes finished."}


def test_payloads_fit_in_4_kb(core, fake):
    huge = [{"qid": f"q{i}", "question": "Pick one " * 60, "choices": [f"option {j} " * 10 for j in range(12)],
             "multi_select": True} for i in range(6)]
    payload = core.notify.request_alert("clarify", {"questions": huge}, request_id=CLARIFY_ID, title="T" * 300,
                                        session_id="s1", profile="default", previews=True)
    assert len(core.push.encode_alert(payload)) <= core.push.MAX_ALERT_BYTES
    assert payload["hermes"]["questions"] == []  # a cut choice would answer something else
    assert len(payload["aps"]["alert"]["title"]) <= core.notify.TITLE_CHARS
    small = core.notify.request_alert("clarify", {"questions": QUESTIONS}, request_id=CLARIFY_ID, title="T",
                                      session_id="s1", profile="default", previews=True)
    assert small["hermes"]["questions"] == QUESTIONS
    broken = core.notify.request_alert("clarify", {"questions": [{"question": "no qid"}]}, request_id=CLARIFY_ID,
                                       title="T", session_id="s1", profile="default", previews=True)
    assert broken["hermes"]["questions"] == [] and broken["aps"]["alert"]["body"] == "Hermes has a question for you."
    assert core.notify.approval_choices({"choices": ["once", "deny", "bogus"]}) == ["once", "deny"]
    assert core.notify.approval_choices({}) == ["once", "session", "always", "deny"]


# ── finished turns ─────────────────────────────────────────────────────────────────────────────────────────


def test_a_turn_that_ends_with_no_client_alerts_with_its_reply(core, env):
    env.host.add("s1")
    env.alerts.note_reply("s1", "## Done\n**Deployed** `v2` — see [the log](https://example.com/log).")
    env.alerts.turn_ended("s1", "turn-1", completed=True, failed=False, interrupted=False)
    env.alerts.turn_ended("s1", "turn-1", completed=True, failed=False, interrupted=False)  # once per turn
    assert [at(env, 100.0), at(env, 104.9), at(env, 105.0), at(env, 200.0)] == [0, 0, 1, 0]
    request = env.mock.requests[0]
    assert request.headers["apns-push-type"] == "alert" and request.headers["apns-topic"] == BUNDLE
    assert request.headers["apns-collapse-id"] == "turn-s1"  # a newer turn's alert replaces it
    assert request.headers["apns-expiration"] == str(1_000_000 + 3600)
    assert json.loads(request.content) == {
        "aps": {"alert": {"title": "Deploy chat", "body": "Done Deployed v2 — see the log."},
                "category": "HERMES_TURN_DONE", "thread-id": "s1", "sound": "default"},
        "hermes": {"kind": "turn_done", "session_id": "s1", "profile": "default"},
    }


@pytest.mark.parametrize("case", ["attached at the end", "attached in the grace", "interrupted", "silent",
                                  "another turn", "on a call", "subagent", "turned off"])
def test_turns_that_say_nothing(core, env, case):
    sid = env.host.add("s1")
    reply = "[SILENT]" if case == "silent" else "All done."
    if case == "attached at the end":
        env.host.attach(sid)
    if case == "on a call":
        owner = core.hub.Owner.from_origin(core.hermes.Origin(session_id="s1", runtime_sid=sid))
        env.hub.slot = core.hub.Call(env.hub, uuid.uuid4().hex, owner, "agent", "live")
    if case == "turned off":
        env.settings[0] = core.notify.AlertSettings(kinds=frozenset({"approval", "clarify"}))
    session = "s1-child" if case == "subagent" else "s1"
    env.alerts.note_reply(session, reply)
    env.alerts.turn_ended(session, "t", completed=True, interrupted=case == "interrupted")
    at(env, 100.0)
    if case == "attached in the grace":
        env.host.attach(sid)
    if case == "another turn":
        env.host.record(sid)["running"] = True
    assert [at(env, 105.0), at(env, 200.0)] == [0, 0] and env.mock.requests == []
    env.hub.slot = None


def test_a_failed_turn_and_a_closed_conversation_still_alert(core, env):
    sid = env.host.add("s1")
    env.alerts.note_reply("s1", "Error: the provider is down")
    env.alerts.turn_ended("s1", "t1", completed=False, failed=True)
    del env.fake.host.sessions[sid]  # reaped right after its turn: nobody has it open
    assert at(env, 105.0) == 1
    payload = env.mock.payloads()[0]
    assert payload["aps"]["alert"] == {"title": "Deploy chat", "body": "Hermes stopped: the turn failed."}
    assert "provider" not in json.dumps(payload)


def test_a_compute_host_turn_alerts_when_it_ends(core, env):
    sid = env.host.add("s1", running=True, _compute_host_turn_id="turn-x")
    assert at(env, 100.0) == 0
    record = env.host.record(sid)
    record.pop("_compute_host_turn_id")
    record["running"] = False
    assert [at(env, 101.0), at(env, 105.9), at(env, 106.0)] == [0, 0, 1]
    assert env.mock.payloads()[0]["aps"]["alert"]["body"] == "Hermes finished."

    record.update(_compute_host_turn_id="turn-y", running=True)  # the next one ends while the app has it open
    at(env, 110.0)
    env.host.attach(sid)
    record.pop("_compute_host_turn_id")
    record["running"] = False
    assert [at(env, 111.0), at(env, 120.0)] == [0, 0]

    env.host.detach(sid)  # one that was stopped says nothing
    record.update(_compute_host_turn_id="turn-z", running=True)
    at(env, 130.0)
    record.pop("_compute_host_turn_id")
    record.update(running=False, _turn_cancel_requested=True)
    assert [at(env, 131.0), at(env, 140.0)] == [0, 0]

    # A conversation nobody has open is dropped right after its turn: the turn still alerts.
    record.update(_compute_host_turn_id="turn-w", running=True, _turn_cancel_requested=False)
    at(env, 150.0)
    record.pop("_compute_host_turn_id")
    record["running"] = False
    del env.fake.host.sessions[sid]
    assert [at(env, 151.0), at(env, 156.0)] == [0, 1]
    assert len(env.mock.requests) == 2


class Replay:
    """The host's event ring (``tui_gateway.event_replay``): what each conversation's turns emitted."""

    def __init__(self, monkeypatch) -> None:
        self.events: dict[str, list[dict]] = {}
        module = types.ModuleType("tui_gateway.event_replay")
        module.events_since = lambda sid, seq: [dict(e) for e in self.events.get(sid, []) if e["seq"] > seq]
        module.latest_seq = lambda sid: max((e["seq"] for e in self.events.get(sid, [])), default=0)
        monkeypatch.setitem(sys.modules, "tui_gateway.event_replay", module)

    def emit(self, sid: str, kind: str, payload: dict) -> None:
        ring = self.events.setdefault(sid, [])
        ring.append({"seq": len(ring) + 1, "type": kind, "session_id": sid, "payload": payload})

    def complete(self, sid: str, text: str, status: str = "complete") -> None:
        self.emit(sid, "message.delta", {"text": text[:5]})
        self.emit(sid, "message.complete", {"text": text, "status": status})


def _turn(env, sid: str, start: float, end: float, replay: Replay = None, text: str = "", status: str = "complete",
          **after) -> None:
    """A turn the watcher sees running at `start` and idle at `end` (no on_session_end: an early return)."""
    record = env.host.record(sid)
    record["running"] = True
    at(env, start)
    if replay is not None:
        replay.complete(sid, text, status)
    record.update(running=False, **after)
    at(env, end)


def test_a_failed_turn_alerts_without_on_session_end(core, env, monkeypatch):
    """Hermes skips on_session_end on its early returns (a provider 4xx, retries used up): the watcher sees the
    conversation go idle, and the turn's message.complete says it failed."""
    replay = Replay(monkeypatch)
    sid = env.host.add("s1")
    _turn(env, sid, 100.0, 101.0, replay, "Your request was not processed.", "error")
    assert [at(env, 105.9), at(env, 106.0)] == [0, 1]
    assert env.mock.payloads()[0]["aps"]["alert"]["body"] == "Hermes stopped: the turn failed."
    _turn(env, sid, 400.0, 401.0, replay, "**Shipped** it.")  # a completed one carries its reply, hook or not
    assert at(env, 406.0) == 1 and env.mock.payloads()[1]["aps"]["alert"]["body"] == "Shipped it."
    for status in ("interrupted",):
        _turn(env, sid, 700.0, 701.0, replay, "", status)
        assert at(env, 720.0) == 0
    _turn(env, sid, 800.0, 801.0, replay, "[SILENT]")
    assert at(env, 820.0) == 0 and len(env.mock.requests) == 2


def test_a_failed_turn_the_host_kept_alerts_without_events(core, env):
    sid = env.host.add("s1")
    _turn(env, sid, 100.0, 101.0, inflight_turn={"status": "error", "error": "HTTP 400"})
    assert at(env, 106.0) == 1
    assert env.mock.payloads()[0]["aps"]["alert"]["body"] == "Hermes stopped: the turn failed."


def test_a_compute_host_turn_alerts_with_its_relayed_reply(core, env, monkeypatch):
    replay = Replay(monkeypatch)
    sid = env.host.add("s1", running=True, _compute_host_turn_id="turn-x")
    at(env, 100.0)
    replay.complete(sid, "All done, deployed.")
    record = env.host.record(sid)
    record.pop("_compute_host_turn_id")
    record["running"] = False
    assert [at(env, 101.0), at(env, 106.0)] == [0, 1]
    assert env.mock.payloads()[0]["aps"]["alert"]["body"] == "All done, deployed."
    record.update(_compute_host_turn_id="turn-y", running=True)
    at(env, 200.0)
    replay.complete(sid, "", "error")  # the child's turn failed: the relayed status says so
    record.pop("_compute_host_turn_id")
    record["running"] = False
    at(env, 201.0)
    assert at(env, 206.0) == 1 and env.mock.payloads()[1]["aps"]["alert"]["body"] == "Hermes stopped: the turn failed."


def test_the_hook_and_the_watcher_tell_one_turn_once(core, env, monkeypatch):
    replay = Replay(monkeypatch)
    sid = env.host.add("s1")
    record = env.host.record(sid)
    record["running"] = True
    at(env, 100.0)
    env.alerts.note_reply("s1", "From the hook.")
    replay.complete(sid, "From the event.")
    env.alerts.turn_ended("s1", "t1", completed=True)  # still running: Hermes clears it just after
    at(env, 100.5)
    record["running"] = False
    # One alert, timed from the hook (the turn's end), with the reply from the turn's own event.
    assert [at(env, 101.0), at(env, 104.9), at(env, 105.0), at(env, 200.0)] == [0, 0, 1, 0]
    assert env.mock.payloads()[0]["aps"]["alert"]["body"] == "From the event."


def test_two_turn_ends_within_one_grace_alert_once(core, env, monkeypatch):
    replay = Replay(monkeypatch)
    sid = env.host.add("s1")
    _turn(env, sid, 100.0, 101.0, replay, "First.")
    _turn(env, sid, 102.0, 103.0, replay, "Second.")
    assert [at(env, 106.0), at(env, 107.9), at(env, 108.0), at(env, 200.0)] == [0, 0, 1, 0]
    assert [p["aps"]["alert"]["body"] for p in env.mock.payloads()] == ["Second."]


def test_a_turn_watched_to_its_end_says_nothing_even_once_the_client_leaves(core, env, monkeypatch):
    replay = Replay(monkeypatch)
    sid = env.host.add("s1")
    env.host.attach(sid)
    _turn(env, sid, 100.0, 101.0, replay, "Seen on screen.")
    env.host.detach(sid)  # the phone locks during the grace
    assert [at(env, 106.0), at(env, 200.0)] == [0, 0] and env.mock.requests == []
    # One the user left mid-turn (the app went to the background) alerts once it ends.
    env.host.attach(sid)
    record = env.host.record(sid)
    record["running"] = True
    at(env, 300.0)
    env.host.detach(sid)
    at(env, 310.0)
    replay.complete(sid, "Finished while you were away.")
    record["running"] = False
    at(env, 320.0)
    assert at(env, 325.0) == 1


def test_a_muted_wake_and_a_turn_without_its_end_event_say_nothing(core, env, monkeypatch):
    Replay(monkeypatch)
    sid = env.host.add("s1")
    env.alerts.turn_ended("s1", "t1", completed=True, muted=True)
    assert [at(env, 100.0), at(env, 110.0)] == [0, 0]
    _turn(env, sid, 200.0, 201.0)  # no message.complete (a manual compaction): nothing to tell
    assert at(env, 210.0) == 0 and env.mock.requests == []


# ── what may go through APNs, and how loud ─────────────────────────────────────────────────────────────────


def test_credentials_are_redacted_and_a_masked_choice_drops_the_questions(core, env):
    key = "sk-ant-api03-" + "A" * 40
    payload = core.notify.turn_alert("done", f"Done. Your new key is {key} - keep it safe.", title=f"Keys {key}",
                                     session_id="s1", profile="default", previews=True)
    assert key not in json.dumps(payload) and "sk-ant...AAAA" in payload["aps"]["alert"]["body"]
    token = "ghp_" + "b" * 36
    params = {"questions": [{"qid": "q1", "question": f"Use {token}?", "choices": [token, "no"]}]}
    clarify = core.notify.request_alert("clarify", params, request_id=CLARIFY_ID, title="T", session_id="s1",
                                        profile="default", previews=True)
    assert token not in json.dumps(clarify) and clarify["hermes"]["questions"] == []
    approval = core.notify.request_alert("approval", {"description": f"push with {token}"}, request_id=APPROVAL_ID,
                                         title="T", session_id="s1", profile="default", previews=True)
    assert token not in json.dumps(approval)


def test_without_hermes_redaction_only_generic_lines_go(core, env, monkeypatch):
    monkeypatch.setitem(sys.modules, "agent.redact", None)
    payload = core.notify.turn_alert("done", "Here is the key.", title="Chat", session_id="s1", profile="default",
                                     previews=True)
    assert payload["aps"]["alert"] == {"title": "Hermes", "body": "Hermes finished."}
    clarify = core.notify.request_alert("clarify", {"questions": QUESTIONS}, request_id=CLARIFY_ID, title="T",
                                        session_id="s1", profile="default", previews=True)
    assert clarify["hermes"]["questions"] == [] and clarify["aps"]["alert"]["body"] == "Hermes has a question for you."


def test_quiet_hours_and_the_budget_make_alerts_silent(core, env, monkeypatch):
    replay = Replay(monkeypatch)
    quiet = [True]
    env.alerts.quiet_hours = lambda: quiet[0]
    sid = env.host.add("s1")
    env.host.approval(sid)
    at(env, 100.0)
    assert at(env, 105.0) == 1
    aps = env.mock.payloads()[0]["aps"]
    assert "sound" not in aps and aps["interruption-level"] == "passive"
    env.host.answer(sid, APPROVAL_ID)
    quiet[0] = False
    _turn(env, sid, 200.0, 201.0, replay, "One.")
    at(env, 206.0)
    _turn(env, sid, 300.0, 301.0, replay, "Two.")  # within 5 minutes of the last sounding one
    at(env, 306.0)
    _turn(env, sid, 600.0, 601.0, replay, "Three.")
    at(env, 606.0)
    loud = ["sound" in p["aps"] for p in env.mock.payloads()[1:]]
    assert loud == [True, False, True]
    many = core.notify.Alerts(pusher=lambda: env.apns, settings=lambda: env.settings[0], clock=lambda: env.now[0],
                              quiet_hours=lambda: False)
    for index in range(core.notify.SOUNDED_PER_HOUR):
        many._sounded("approval", f"s{index}", 1000.0, quiet=False)
    assert many._quiet("approval", "s-new", 1001.0, False) is True
    assert many._quiet("approval", "s-new", 4700.0, False) is False


def test_an_alert_apns_couldnt_take_is_tried_again(core, env):
    env.mock.script = [(503, "ServiceUnavailable"), (429, "TooManyRequests")]
    sid = env.host.add("s1")
    env.host.approval(sid)
    at(env, 100.0)
    assert [at(env, 105.0), at(env, 105.5), at(env, 106.0), at(env, 107.9), at(env, 108.0), at(env, 200.0)] == \
        [0, 0, 0, 0, 1, 0]
    assert len(env.mock.requests) == 3  # 503, then 429 a second later, then sent two seconds after that
    # A refusal that won't pass (a bad payload, a phone APNs doesn't know) is not tried again.
    env.mock.script = [(400, "BadTopic")]
    env.host.answer(sid, APPROVAL_ID)
    env.host.approval(sid, rid="srq-dddddddddddd")
    at(env, 300.0)
    assert [at(env, 305.0), at(env, 320.0)] == [0, 0] and len(env.mock.requests) == 4


def test_a_turn_done_apns_couldnt_take_is_tried_again(core, env, monkeypatch):
    replay = Replay(monkeypatch)
    env.mock.script = [(500, "InternalServerError")]
    sid = env.host.add("s1")
    _turn(env, sid, 100.0, 101.0, replay, "Done.")
    assert [at(env, 106.0), at(env, 106.5), at(env, 107.0)] == [0, 0, 1]
    assert len(env.mock.requests) == 2


def test_a_send_that_blows_up_is_tried_again(core, env):
    calls = []

    class Flaky:
        store = env.store

        def push_alert(self, kind, payload, collapse_id=""):
            calls.append(kind)
            if len(calls) == 1:
                raise httpx.ConnectTimeout("APNs unreachable")
            return core.push.PushResult(True, "", 1)

    alerts = core.notify.Alerts(pusher=lambda: Flaky(), settings=lambda: env.settings[0], clock=lambda: env.now[0],
                                quiet_hours=lambda: False)
    env.alerts = alerts
    sid = env.host.add("s1")
    env.host.approval(sid)
    at(env, 100.0)
    assert [at(env, 105.0), at(env, 106.0), at(env, 110.0)] == [0, 1, 0] and calls == ["approval", "approval"]


# ── APNs details ───────────────────────────────────────────────────────────────────────────────────────────


def test_alerts_and_calls_share_one_provider_token(core, env):
    assert env.apns.push_call({"call_id": "c" * 32}).ok
    assert env.apns.push_alert("turn_done", core.notify.turn_alert(
        "done", "ok", title="T", session_id="s1", profile="default", previews=True)).ok
    calls, alert = env.mock.requests
    assert env.apns.signed == 1 and calls.headers["authorization"] == alert.headers["authorization"]
    assert calls.headers["apns-push-type"] == "voip" and calls.headers["apns-topic"] == f"{BUNDLE}.voip"
    assert calls.url.path.endswith(VOIP) and alert.url.path.endswith(ALERT)


def test_a_dead_alert_token_is_forgotten_and_the_phone_still_rings(core, env):
    mock = MockApns((410, "Unregistered"))
    apns = core.push.Apns(env.store, transport=httpx.MockTransport(mock))
    payload = core.notify.turn_alert("done", "", title="T", session_id="s1", profile="default", previews=True)
    result = apns.push_alert("turn_done", payload)
    assert not result.ok and result.reason == "APNs 410 Unregistered"
    [device] = env.store.devices()
    assert device.voip_token == VOIP and device.alert_token is None
    assert "no iPhone takes turn_done alerts" in apns.push_alert("turn_done", payload).reason
    assert apns.push_call({"call_id": "c" * 32}).ok and len(mock.requests) == 2


def test_an_alert_apns_would_refuse_is_not_sent(core, env):
    payload = {"aps": {"alert": {"title": "T", "body": "x" * 5000}}, "hermes": {"kind": "turn_done"}}
    result = env.apns.push_alert("turn_done", payload)
    assert not result.ok and "larger than APNs allows" in result.reason and env.mock.requests == []
    env.apns.push_alert("turn_done", {"aps": {}}, collapse_id="not a valid id!")
    assert "apns-collapse-id" not in env.mock.requests[0].headers


def test_nothing_secret_reaches_the_log(core, env, caplog, key_path):
    caplog.set_level(logging.DEBUG, logger="hermes_voice")
    env.mock.script = [(403, "ExpiredProviderToken"), (400, "BadDeviceToken")]
    sid = env.host.add("s1")
    env.host.approval(sid)
    env.alerts.note_reply("s1", "the secret plan is ready")
    env.alerts.turn_ended("s1", "t", completed=True)
    at(env, 100.0)
    at(env, 105.0)
    logged = "\n".join(record.getMessage() + (record.exc_text or "") for record in caplog.records)
    assert "alert" in logged  # it did log what happened
    tokens = [request.headers["authorization"].removeprefix("bearer ") for request in env.mock.requests]
    for secret in [ALERT, VOIP, str(key_path), key_path.read_text().splitlines()[1], "hunter2", "secret plan",
                   "recursive delete", *tokens]:
        assert secret not in logged


# ── the watcher's thread, the hooks and the routes ─────────────────────────────────────────────────────────


def test_the_watcher_thread_sends_on_its_own(core, env, monkeypatch):
    monkeypatch.setattr(core.notify, "POLL_S", 0.02)
    env.settings[0] = core.notify.AlertSettings(grace_s=0.0)
    alerts = core.notify.Alerts(pusher=lambda: env.apns, settings=lambda: env.settings[0])
    sid = env.host.add("s1")
    env.host.approval(sid)
    alerts.start()
    try:
        asyncio.run(until(lambda: env.mock.requests, timeout=5))
    finally:
        alerts.stop()
    assert env.mock.payloads()[0]["hermes"]["request_id"] == APPROVAL_ID
    asyncio.run(until(lambda: not alerts.thread.is_alive(), timeout=5))


def test_the_alert_hooks_work_only_where_the_phone_is_served(core, env):
    spec = importlib.util.spec_from_file_location("hermes_plugins_hermes_voice_alerts", PLUGIN_DIR / "__init__.py",
                                                  submodule_search_locations=[str(PLUGIN_DIR)])
    plugin = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = plugin
    spec.loader.exec_module(plugin)
    hooks: dict[str, list] = {}
    unloads: list = []
    ctx = types.SimpleNamespace(register_hook=lambda name, callback: hooks.setdefault(name, []).append(callback),
                                on_unload=unloads.append)
    core.notify.install(env.alerts)
    try:
        plugin._register_alerts(ctx)
        assert set(hooks) == {"post_llm_call", "on_session_end"} and len(unloads) == 1
        env.host.add("s1")
        env.fake.bound_host = None  # a process that doesn't serve the dashboard (CLI, gateway, compute host)
        hooks["post_llm_call"][0](session_id="s1", assistant_response="Shipped.", turn_id="t")
        hooks["on_session_end"][0](session_id="s1", turn_id="t", completed=True)
        assert env.alerts.replies == {} and env.alerts.turns == []
        env.fake.bound_host = "127.0.0.1"
        assert hooks["post_llm_call"][0](session_id="s1", assistant_response="Shipped.", turn_id="t") is None
        assert hooks["on_session_end"][0](session_id="s1", turn_id="t", completed=True, model="m") is None
        assert at(env, 105.0) == 1 and env.mock.payloads()[0]["aps"]["alert"]["body"] == "Shipped."

        env.settings[0] = core.notify.AlertSettings(grace_s=0.0)
        env.alerts.start()
        unloads[0]()  # the plugin unloads: the watcher stops, and loading it again resumes it
        assert not env.alerts.running() and env.alerts.paused
        plugin._register_alerts(ctx)
        assert env.alerts.running() and not env.alerts.paused
    finally:
        env.alerts.stop()
        core.notify.install(None)


def test_devices_register_alert_tokens_and_choices(core, fake, make_hub, tmp_path):
    make_hub()
    body = {"voip_token": VOIP, "alert_token": ALERT.upper(), "environment": "sandbox", "bundle_id": BUNDLE,
            "alerts": {"turn_done": False}}

    def stored() -> dict:
        [device] = json.loads((tmp_path / "hermes-voice" / "devices.json").read_text())
        return device

    async def scenario():
        steps = []
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                steps.append(((await http.post("/devices", json=body)).json(), stored()))
                # The VoIP registry fires again without the alert token: the stored one stays, choices too.
                plain = {k: v for k, v in body.items() if k not in ("alert_token", "alerts")}
                steps.append(((await http.post("/devices", json=plain)).json(), stored()))
                steps.append(((await http.post("/devices", json={**plain, "alerts": {"turn_done": True,
                                                                                      "clarify": False,
                                                                                      "future_kind": False}})
                               ).json(), stored()))
                steps.append(((await http.post("/devices", json={**plain, "alert_token": None})).json(), stored()))
                bad = await http.post("/devices", json={**plain, "alerts": {"approval": "no"}})
                status = (await http.get("/status")).json()
        return steps, bad, status

    steps, bad, status = asyncio.run(scenario())
    assert [answer for answer, _ in steps] == [{"ok": True}] * 4  # the route answers as before
    assert (steps[0][1]["alert_token"], steps[0][1]["alerts"]) == (ALERT, {"turn_done": False})
    assert (steps[1][1]["alert_token"], steps[1][1]["alerts"]) == (ALERT, {"turn_done": False})
    assert steps[2][1]["alerts"] == {"turn_done": True, "clarify": False}
    assert steps[3][1]["alert_token"] is None and steps[3][1]["voip_token"] == VOIP
    assert bad.status_code == 400 and "alerts" in bad.json()["detail"]
    assert status["alerts"]["enabled"] is True and status["alerts"]["kinds"] == ["approval", "clarify", "turn_done"]
    assert ALERT not in json.dumps(status) and VOIP not in json.dumps(status)


def test_a_new_voip_token_with_the_same_alert_token_is_the_same_phone(core, tmp_path):
    store = core.push.DeviceStore(lambda: tmp_path / "hermes-voice")
    store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, alerts={"clarify": False}))
    store.register(core.push.Device("99" * 32, "sandbox", BUNDLE, ALERT))
    [device] = store.devices()
    assert device.voip_token == "99" * 32 and device.wants("approval") and not device.wants("clarify")
    (tmp_path / "hermes-voice" / "devices.json").write_text(json.dumps(
        [{"voip_token": VOIP, "environment": "sandbox", "bundle_id": BUNDLE, "alerts": "garbage"}, 7]))
    [old] = store.devices()  # a file from before alerts (or hand-edited) still loads
    assert old.alerts == {} and old.alert_token is None and not old.wants("approval")


def test_the_watcher_waits_for_a_session_host(core, env, monkeypatch):
    sid = env.host.add("s1")
    env.host.approval(sid)
    monkeypatch.delitem(sys.modules, "tui_gateway.server")  # this process hosts no conversations (yet)
    assert [at(env, 100.0), at(env, 110.0)] == [0, 0] and env.mock.requests == []


def test_a_failing_sender_logs_no_more_than_what_failed(core, env, caplog):
    caplog.set_level(logging.DEBUG, logger="hermes_voice")

    class Broken:
        def push_alert(self, kind, payload, collapse_id=""):
            raise RuntimeError(f"https://api.push.apple.com/3/device/{ALERT} refused")

    alerts = core.notify.Alerts(pusher=Broken, settings=lambda: env.settings[0], clock=lambda: env.now[0])
    sid = env.host.add("s1")
    env.host.approval(sid)
    alerts.tick()
    env.now[0] = 105.0
    assert alerts.tick() == 0
    logged = "\n".join(record.getMessage() + (record.exc_text or "") for record in caplog.records)
    assert "approval alert failed (RuntimeError)" in logged and ALERT not in logged


def test_status_counts_phones_that_take_alerts(core, env):
    env.store.register(core.push.Device("12" * 32, "sandbox", BUNDLE))
    assert env.alerts.status() == {"enabled": True, "kinds": ["approval", "clarify", "turn_done"],
                                   "watching": False, "devices": 1, "sent": 0}
    sid = env.host.add("s1")
    env.host.approval(sid)
    at(env, 100.0)
    at(env, 105.0)
    assert env.alerts.status()["sent"] == 1


def test_an_older_host_is_read_through_its_fallbacks(core, fake, monkeypatch):
    """Without ``_session_live_transports`` / ``_open_requests``: the record's transport (the drop sink and stdout
    are nobody), and ``server_requests.open_requests``."""
    server = fake.host.module
    record = {"transport": server._detached_ws_transport}
    assert core.notify.client_attached(server, record) is False
    record["transport"] = server._stdio_transport
    assert core.notify.client_attached(server, record) is False
    record["transport"] = types.SimpleNamespace(transports=lambda: [server._detached_ws_transport])
    assert core.notify.client_attached(server, record) is False
    record["transport"] = types.SimpleNamespace(transports=lambda: [object()])
    assert core.notify.client_attached(server, record) is True
    assert core.notify.client_attached(server, {}) is False

    requests = types.ModuleType("tui_gateway.server_requests")
    requests.open_requests = lambda sid: [{"id": "srq-1", "method": "approval", "params": {}}, "junk"]
    monkeypatch.setitem(sys.modules, "tui_gateway.server_requests", requests)
    assert core.notify.open_requests(server, "rt-s1") == [{"id": "srq-1", "method": "approval", "params": {}}]
    server._open_requests = lambda sid: (_ for _ in ()).throw(RuntimeError("host busy"))
    assert core.notify.open_requests(server, "rt-s1") == []
