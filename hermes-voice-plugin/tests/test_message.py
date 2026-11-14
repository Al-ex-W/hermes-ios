"""``notify_user`` (message.py): the agent's own notification, against a mock APNs behind the hub's real sender:
every result state, who may send one (each surface, scheduled jobs on and off, subagents, group chats), the rate
limits, quiet hours and the alert budget, previews off, redaction, the length caps, each phone's switch and the
host's, retries, the hub socket for other processes, ``GET /status``, and that the text never reaches a log."""

from __future__ import annotations

import asyncio
import json
import logging
import types

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from support import PLUGIN_DIR, PREFIX, serving, tool

VOIP, ALERT = "ab" * 32, "cd" * 32
OTHER_VOIP, OTHER_ALERT = "12" * 32, "34" * 32
OFF_VOIP, OFF_ALERT = "56" * 32, "78" * 32
KEY_ID, TEAM_ID = "KEY1234567", "TEAM123456"
BUNDLE = "com.example.hermesvoice"
TEXT = "Your train is 10 minutes late"
SECRET_TEXT = "Platform 7, gate code zebra-unicorn"


class MockApns:
    """Answers like APNs; `script` is a list of (status, reason) for successive requests (then 200)."""

    def __init__(self, *script: tuple[int, str]) -> None:
        self.script = list(script)
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.script:
            status, reason = self.script.pop(0)
            return httpx.Response(status, json={"reason": reason} if reason else {})
        return httpx.Response(200, headers={"apns-id": "x"})

    def payloads(self) -> list[dict]:
        return [json.loads(request.content) for request in self.requests]

    def tokens(self) -> list[str]:
        return [request.url.path.rsplit("/", 1)[-1] for request in self.requests]


@pytest.fixture
def env(core, fake, tmp_path, make_hub):
    """Two phones that take message alerts (one sandbox, one production) and one that turned them off, a mock APNs
    behind the hub's real sender, the alert budget's watcher, quiet hours the test switches, and this process's
    notify_user state."""
    message = core.loader.module("message", PLUGIN_DIR)
    private = ec.generate_private_key(ec.SECP256R1())
    key_path = tmp_path / "AuthKey.p8"
    key_path.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
    fake.secrets.update({"HERMES_VOICE_APNS_KEY_PATH": str(key_path), "HERMES_VOICE_APNS_KEY_ID": KEY_ID,
                         "HERMES_VOICE_APNS_TEAM_ID": TEAM_ID})
    fake.host.add("s1", title="Trains")
    mock = MockApns()
    store = core.push.DeviceStore(lambda: tmp_path / "hermes-voice")
    store.register(core.push.Device(OFF_VOIP, "sandbox", BUNDLE, OFF_ALERT, alerts={"message": False}))
    store.register(core.push.Device(OTHER_VOIP, "production", BUNDLE, OTHER_ALERT))
    store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT))
    now = [1_000_000.0]
    apns = core.push.Apns(store, transport=httpx.MockTransport(mock), clock=lambda: now[0])
    hub = make_hub(pusher=apns)
    settings = [message.MessageSettings()]
    alert_settings = [core.notify.AlertSettings()]
    watcher = core.notify.Alerts(pusher=lambda: apns, settings=lambda: alert_settings[0], clock=lambda: now[0])
    quiet = [False]
    slept: list[float] = []
    messages = message.Messages(hub=lambda: hub, settings=lambda: settings[0], alert_settings=lambda: alert_settings[0],
                                alerts=lambda: watcher, quiet_hours=lambda: quiet[0], clock=lambda: now[0],
                                sleep=slept.append)
    message.install(messages)
    yield types.SimpleNamespace(message=message, messages=messages, fake=fake, hub=hub, mock=mock, store=store,
                                apns=apns, settings=settings, alert_settings=alert_settings, watcher=watcher,
                                quiet=quiet, now=now, slept=slept, log=tmp_path / "hermes-voice" / "rings.jsonl",
                                origin=core.hermes.Origin(session_id="s1", source="desktop", profile="work"))
    message.install(None)


def ring_log(env) -> list[dict]:
    if not env.log.exists():
        return []
    return [json.loads(line) for line in env.log.read_text().splitlines() if '"notify"' in line]


def send(env, title="Train", body=TEXT, urgency=None, origin=None, **kw) -> dict:
    return env.messages.send(origin or env.origin, title, body, urgency, **kw)


# ── sent ───────────────────────────────────────────────────────────────────────────────────────────────────


def test_a_message_goes_to_every_phone_that_takes_them(core, env):
    result = send(env)
    assert result["status"] == "sent" and "reason" not in result
    assert "with sound" in result["note"] and "2 iPhones" in result["note"]
    assert "also in this conversation" in result["note"] and "don't repeat it" in result["note"]
    # Both phones that take messages, each in its own environment; not the one that turned them off.
    assert sorted(env.mock.tokens()) == sorted([ALERT, OTHER_ALERT])
    assert {request.url.host for request in env.mock.requests} == {"api.sandbox.push.apple.com", "api.push.apple.com"}
    request = env.mock.requests[0]
    assert request.headers["apns-push-type"] == "alert" and request.headers["apns-topic"] == BUNDLE
    assert request.headers["apns-priority"] == "10"
    assert int(request.headers["apns-expiration"]) == int(env.now[0] + 3600)
    collapse = request.headers["apns-collapse-id"]
    assert collapse.startswith("msg-") and env.mock.requests[1].headers["apns-collapse-id"] == collapse
    payload = env.mock.payloads()[0]
    assert payload == {"aps": {"alert": {"title": "Train", "body": TEXT}, "category": "HERMES_MESSAGE",
                               "thread-id": "s1", "sound": "default"},
                       "hermes": {"kind": "message", "session_id": "s1", "profile": "work"}}
    # A second message is a notification of its own (no collapse into the first).
    send(env, body="And now 12 minutes")
    assert env.mock.requests[-1].headers["apns-collapse-id"] != collapse
    entry = ring_log(env)[0]
    assert entry | {"at": 0} == {"at": 0, "event": "notify", "session_id": "s1", "source": "desktop",
                                 "result": "sent", "urgency": "normal", "level": "sound", "phones": 2}
    assert env.messages.sent == 2 and len(env.watcher.sounded) == 2  # counted in the alert budget


def test_urgency_sets_how_it_interrupts(core, env):
    sensitive = send(env, urgency="time_sensitive")
    quiet = send(env, urgency="quiet")
    alias = send(env, urgency="Time-Sensitive")
    odd = send(env, urgency="loud")
    aps = [payload["aps"] for payload in env.mock.payloads()[::2]]
    assert aps[0]["interruption-level"] == "time-sensitive" and aps[0]["sound"] == "default"
    assert aps[1]["interruption-level"] == "passive" and "sound" not in aps[1]
    assert aps[2]["interruption-level"] == "time-sensitive"
    assert "interruption-level" not in aps[3] and aps[3]["sound"] == "default"
    assert sensitive["status"] == "sent" and "time-sensitive" in sensitive["note"]
    assert quiet["status"] == "sent" and "silently, as asked" in quiet["note"]
    assert alias["status"] == "sent"
    assert odd["status"] == "sent" and "'loud' isn't one of normal, time_sensitive, quiet" in odd["note"]
    assert [entry["level"] for entry in ring_log(env)] == ["time-sensitive", "passive", "time-sensitive", "sound"]
    assert len(env.watcher.sounded) == 3  # the quiet one doesn't count in the budget


def test_quiet_hours_make_every_urgency_passive(core, env):
    env.quiet[0] = True
    normal = send(env)
    sensitive = send(env, urgency="time_sensitive")
    for result in (normal, sensitive):
        assert (result["status"], result["reason"]) == ("quiet", "quiet_hours") and "quiet hours" in result["note"]
    for payload in env.mock.payloads():
        assert payload["aps"]["interruption-level"] == "passive" and "sound" not in payload["aps"]
    assert [(entry["result"], entry["reason"]) for entry in ring_log(env)] == [("quiet", "quiet_hours")] * 2
    assert len(env.watcher.sounded) == 0


def test_the_alert_budget_quiets_a_normal_message_but_not_a_time_sensitive_one(core, env):
    for index in range(core.notify.SOUNDED_PER_HOUR):
        env.watcher._sounded("turn_done", f"other-{index}", env.now[0] - 60)
    normal = send(env)
    assert (normal["status"], normal["reason"]) == ("quiet", "budget") and "alert budget" in normal["note"]
    assert env.mock.payloads()[-1]["aps"]["interruption-level"] == "passive"
    sensitive = send(env, urgency="time_sensitive")
    assert sensitive["status"] == "sent" and "reason" not in sensitive
    assert env.mock.payloads()[-1]["aps"]["interruption-level"] == "time-sensitive"
    env.now[0] += 3600  # an hour later the budget is free again
    assert send(env)["status"] == "sent"


# ── text ───────────────────────────────────────────────────────────────────────────────────────────────────


def test_previews_off_send_no_text_through_apns(core, env):
    env.alert_settings[0] = core.notify.AlertSettings(previews=False)
    result = send(env, title="Gate", body=SECRET_TEXT)
    assert result["status"] == "sent" and "previews off" in result["note"]
    assert "Hermes sent you a message" in result["note"] and "open this conversation" in result["note"]
    payload = env.mock.payloads()[0]
    assert payload["aps"]["alert"] == {"title": "Hermes", "body": "Hermes sent you a message."}
    assert payload["hermes"] == {"kind": "message", "session_id": "s1", "profile": "work"}
    assert not any("zebra" in request.content.decode() or "Gate" in request.content.decode()
                   for request in env.mock.requests)
    assert ring_log(env)[0]["previews"] is False


def test_text_is_redacted_and_without_redaction_the_phone_gets_the_generic_line(core, env, monkeypatch):
    key = "sk-abcdef0123456789abcdefWXYZ"
    send(env, title=f"Key {key}", body=f"Your new key is {key}, use it")
    alert = env.mock.payloads()[0]["aps"]["alert"]
    assert key not in json.dumps(alert) and "sk-abc...WXYZ" in alert["body"] and "sk-abc...WXYZ" in alert["title"]
    monkeypatch.setattr(core.hermes, "redact", lambda text: None)
    result = send(env, body=SECRET_TEXT)
    assert result["status"] == "sent" and "redaction isn't available" in result["note"]
    assert env.mock.payloads()[-1]["aps"]["alert"] == {"title": "Hermes", "body": "Hermes sent you a message."}


def test_long_text_is_cut_and_the_result_says_so(core, env):
    result = send(env, title="T" * 120, body="word " * 200)
    alert = env.mock.payloads()[0]["aps"]["alert"]
    assert len(alert["title"]) == 80 and alert["title"].endswith("…")
    assert len(alert["body"]) <= 500 and alert["body"].endswith("…")
    assert "title was cut to 80 characters" in result["note"] and "body was cut" in result["note"]
    assert ring_log(env)[0]["cut"] is True
    # Whitespace is collapsed, which is not a cut; a short text is not cut either.
    fine = send(env, title="  Train\n", body="Late\n\n  by ten")
    assert env.mock.payloads()[-1]["aps"]["alert"] == {"title": "Train", "body": "Late by ten"}
    assert "cut" not in fine["note"]


def test_an_empty_message_is_not_sent_and_a_title_alone_is_the_message(core, env):
    empty = send(env, title=" ", body="")
    assert (empty["status"], empty["reason"]) == ("not_sent", "empty") and env.mock.requests == []
    alone = send(env, title="Train late", body=None)
    assert alone["status"] == "sent"
    assert env.mock.payloads()[0]["aps"]["alert"] == {"title": "Hermes", "body": "Train late"}


# ── not sent ───────────────────────────────────────────────────────────────────────────────────────────────


def test_the_phone_and_host_switches(core, env):
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, alerts={"message": False}))
    env.store.register(core.push.Device(OTHER_VOIP, "production", BUNDLE, OTHER_ALERT, alerts={"message": False}))
    off = send(env)
    assert (off["status"], off["reason"]) == ("not_sent", "off_on_phone")
    assert "Messages from Hermes" in off["note"] and "Settings → Notifications" in off["note"]
    # The other kinds stay as they were: only messages are off on these phones.
    assert all(device.wants("turn_done") for device in env.store.devices())
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, alerts={"message": True}))
    assert send(env)["status"] == "sent" and env.mock.tokens() == [ALERT]
    for host in (core.notify.AlertSettings.from_plugin_settings({"alerts": {"message": False}}),
                 core.notify.AlertSettings(enabled=False)):
        env.alert_settings[0] = host
        refused = send(env)
        assert (refused["status"], refused["reason"]) == ("not_sent", "off_on_host")
        assert "settings.alerts" in refused["note"]
    assert len(env.mock.requests) == 1


def test_no_phone_no_token_and_no_apns(core, env, fake, tmp_path):
    for voip in (VOIP, OTHER_VOIP, OFF_VOIP):
        env.store.remove(voip)
    nobody = send(env)
    assert (nobody["status"], nobody["reason"]) == ("not_sent", "no_phone") and "registered" in nobody["note"]
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, None))
    no_token = send(env)
    assert (no_token["status"], no_token["reason"]) == ("not_sent", "no_alert_token")
    assert "iOS Settings" in no_token["note"]
    fake.secrets.clear()
    unconfigured = send(env)
    assert (unconfigured["status"], unconfigured["reason"]) == ("not_sent", "apns_not_configured")
    assert "HERMES_VOICE_APNS_KEY_PATH" in unconfigured["note"]
    assert env.mock.requests == []
    assert [entry["reason"] for entry in ring_log(env)] == ["no_phone", "no_alert_token", "apns_not_configured"]


def test_a_hub_without_an_alert_sender_says_so(core, env, make_hub):
    from support import FakePusher

    hub = make_hub(pusher=FakePusher())
    messages = env.message.Messages(hub=lambda: hub, settings=lambda: env.settings[0],
                                    alert_settings=lambda: env.alert_settings[0], alerts=lambda: env.watcher,
                                    quiet_hours=lambda: False)
    result = messages.send(env.origin, "t", "b")
    assert (result["status"], result["reason"]) == ("not_sent", "apns_not_configured")
    assert "no alert sender" in result["note"]


def test_apns_refusals_are_said_in_words(core, env):
    env.mock.script = [(400, "BadDeviceToken"), (400, "BadDeviceToken")]
    refused = send(env)
    assert (refused["status"], refused["reason"]) == ("not_sent", "apns_refused")
    assert "no longer knows the phone's notification token" in refused["note"] and "BadDeviceToken" in refused["note"]
    assert env.slept == []  # a refusal for good isn't tried again
    assert not any(device.alert_token for device in env.store.devices() if device.voip_token in (VOIP, OTHER_VOIP))
    entry = ring_log(env)[0]
    assert entry["reason"] == "apns_refused" and "BadDeviceToken" in entry["detail"]


def test_a_passing_apns_failure_is_tried_again(core, env):
    env.mock.script = [(503, "ServiceUnavailable"), (503, "ServiceUnavailable"), (429, "TooManyRequests"),
                       (429, "TooManyRequests")]
    result = send(env)
    assert result["status"] == "sent"
    assert round(sum(env.slept), 1) == 3.0  # 1 s, then 2 s
    assert ring_log(env)[0]["attempts"] == 3
    env.slept.clear()
    env.mock.script = [(503, "ServiceUnavailable")] * 10
    gone = send(env)
    assert (gone["status"], gone["reason"]) == ("not_sent", "apns_unreachable") and "couldn't reach APNs" in gone["note"]
    assert round(sum(env.slept), 1) == 15.0  # 1, 2, 4, 8 s: then it gives up
    assert ring_log(env)[-1]["attempts"] == 5


def test_stop_ends_the_retries(core, env):
    env.mock.script = [(503, "ServiceUnavailable")] * 10
    result = send(env, interrupted=lambda: bool(env.slept))
    assert (result["status"], result["reason"]) == ("not_sent", "interrupted")
    assert len(env.mock.requests) == 2  # the first try, to both phones


# ── who may, how often ─────────────────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("origin, config, reason", [
    (dict(source="desktop"), {}, ""),
    (dict(source="dashboard"), {}, ""),
    (dict(source="cli"), {}, ""),
    (dict(source="tui"), {}, ""),
    (dict(source="oneshot"), {}, "source"),
    (dict(source="tool"), {}, "source"),
    (dict(source="desktop", is_subagent=True), {}, "subagent"),
    (dict(is_cron=True), {}, ""),  # a job that checks something and tells the user
    (dict(is_cron=True), {"allow_cron": False}, "cron"),
    (dict(is_cron=True, is_subagent=True), {}, "subagent"),
    (dict(platform="telegram", chat_type="dm", user_id="42", is_owner=True), {}, ""),
    (dict(platform="telegram", chat_type="dm", user_id="43", is_owner=False), {}, "not_owner"),
    (dict(platform="telegram", chat_type="group", user_id="42", is_owner=True), {}, "group"),
    (dict(platform="discord", chat_type="channel", user_id="42", is_owner=True), {}, "group"),
])
def test_who_may_notify(core, env, origin, config, reason):
    settings = env.message.MessageSettings.from_plugin_settings({"notify_user": config})
    decision = env.message.allowed(core.hermes.Origin(session_id="x", **origin), settings, core.config.PolicyConfig())
    assert (decision.allowed, decision.reason) == (not reason, reason)
    if reason:
        assert decision.note


def test_a_refused_conversation_sends_nothing_and_is_logged(core, env):
    group = core.hermes.Origin(session_id="g1", platform="telegram", chat_type="group", user_id="42", is_owner=True)
    result = send(env, origin=group)
    assert (result["status"], result["reason"]) == ("not_sent", "not_allowed") and "group chat" in result["note"]
    env.settings[0] = env.message.MessageSettings(allow_cron=False)
    cron = send(env, origin=core.hermes.Origin(session_id="c1", is_cron=True))
    assert cron["reason"] == "not_allowed" and "allow_cron" in cron["note"]
    assert env.mock.requests == []
    assert [(entry["session_id"], entry["source"], entry["policy"]) for entry in ring_log(env)] == [
        ("g1", "telegram", "group"), ("c1", "cron", "cron")]


def test_the_owner_of_a_dm_is_who_the_call_policy_names(core, env):
    stranger = core.hermes.Origin(session_id="x", platform="telegram", chat_type="dm", user_id="43", is_owner=True)
    named = core.config.PolicyConfig(owner_ids=("telegram:42",))
    assert env.message.allowed(stranger, env.settings[0], named).reason == "not_owner"
    owner = core.hermes.Origin(session_id="x", platform="telegram", chat_type="dm", user_id="42")
    assert env.message.allowed(owner, env.settings[0], named).allowed


def test_rate_limits_per_conversation_and_per_host(core, env):
    env.settings[0] = env.message.MessageSettings(per_session=2, per_host=3)
    assert [send(env)["status"] for _ in range(2)] == ["sent", "sent"]
    limited = send(env)
    assert (limited["status"], limited["reason"]) == ("not_sent", "rate_limited")
    assert "already sent 2 notifications in the last 10 minutes" in limited["note"]
    other = core.hermes.Origin(session_id="s2", source="cli")
    assert send(env, origin=other)["status"] == "sent"
    everyone = send(env, origin=core.hermes.Origin(session_id="s3", source="cli"))
    assert everyone["reason"] == "rate_limited" and "3 notifications went to the user in the last hour" in everyone["note"]
    assert len(env.mock.requests) == 6  # three messages, two phones each
    env.now[0] += 3600
    assert send(env)["status"] == "sent"


def test_settings_are_read_and_clamped(core, env):
    read = env.message.MessageSettings.from_plugin_settings
    default = env.message.MessageSettings()
    assert read({}) == default == read({"notify_user": "yes"})
    assert (default.allow_cron, default.per_session, default.session_window_s, default.per_host,
            default.host_window_s) == (True, 5, 600.0, 30, 3600.0)
    custom = read({"notify_user": {"allow_cron": "off", "per_session": 0, "session_window_s": "x", "per_host": 1e9}})
    assert (custom.allow_cron, custom.per_session, custom.session_window_s, custom.per_host) == (False, 1, 600.0, 10000)
    # The host switch is the alert kind's.
    assert "message" not in core.notify.AlertSettings.from_plugin_settings({"alerts": {"message": "no"}}).kinds
    assert "message" in core.notify.AlertSettings.from_plugin_settings({}).kinds


# ── the tool ───────────────────────────────────────────────────────────────────────────────────────────────


def test_the_tool_answers_json_for_the_calling_conversation(core, env, fake):
    async def scenario():
        sent = await tool(env.message.notify_user, {"title": "Train", "body": TEXT, "urgency": "time_sensitive"})
        nowhere = await tool(env.message.notify_user, {"body": TEXT}, session_id="")
        fake.env.update({"HERMES_SESSION_PLATFORM": "telegram", "HERMES_SESSION_CHAT_TYPE": "group"})
        group = await tool(env.message.notify_user, {"title": "t", "body": TEXT})
        return sent, nowhere, group

    sent, nowhere, group = asyncio.run(scenario())
    assert set(sent) == {"status", "note"} and sent["status"] == "sent"
    # The conversation's stored id and the dashboard's profile name the thread.
    assert env.mock.payloads()[0]["hermes"] == {"kind": "message", "session_id": "s1", "profile": "default"}
    assert nowhere["status"] == "not_sent" and group["status"] == "not_sent" and group["reason"] == "not_allowed"


def test_the_tool_never_raises(core, env, monkeypatch):
    monkeypatch.setattr(env.messages, "send", lambda *a, **k: 1 / 0)
    result = json.loads(env.message.notify_user({"body": "x"}, session_id="s1"))
    assert result["status"] == "not_sent" and "nothing was sent" in result["note"]


def test_the_tool_schema_is_short_and_says_what_the_agent_needs(core):
    schema = core.loader.module("message", PLUGIN_DIR).NOTIFY_USER
    description = schema["description"]
    assert schema["name"] == "notify_user" and schema["parameters"]["required"] == ["title", "body"]
    assert schema["parameters"]["properties"]["urgency"]["enum"] == ["normal", "time_sensitive", "quiet"]
    for word in ("not a call", "Silent mode", "time_sensitive", "quiet", "not_sent", "not_available", "during a call"):
        assert word in description
    assert len(description) < 800 and description.count(". ") <= 4


def test_a_test_alert_of_the_message_kind(core, env):
    tests = core.notify.TestAlerts(pusher=lambda: env.apns, settings=lambda: env.alert_settings[0],
                                   ring_log=lambda entry: None)
    test = tests.send(tests.begin("message", voip_token=VOIP))
    assert test.status == "sent"
    payload = env.mock.payloads()[-1]
    assert payload["aps"]["category"] == "HERMES_MESSAGE" and payload["hermes"]["test"] is True
    assert payload["hermes"]["kind"] == "message" and "request_id" not in payload["hermes"]
    assert env.mock.tokens() == [ALERT]
    off = tests.begin("message", voip_token=OFF_VOIP)
    assert (off.status, off.code) == ("failed", "off_on_phone") and "message notifications" in off.message


# ── other Hermes processes ─────────────────────────────────────────────────────────────────────────────────


@pytest.fixture
def hub_socket(core, env, fake):
    """The hub's socket for other processes, and this process made to look like one of them."""
    hubsock = core.loader.module("hubsock", PLUGIN_DIR)
    server = hubsock.HubServer(env.hub, fake.home / "hermes-voice").start()
    fake.bound_host = None  # not the dashboard: the tool goes through the socket
    assert core.hub.routes_mounted() is False
    yield server
    server.close()


def test_another_process_notifies_through_the_hub_socket(core, env, fake, hub_socket):
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    result = json.loads(env.message.notify_user({"title": "Train", "body": TEXT}, session_id="local-1"))
    assert result["status"] == "sent" and "also in this conversation" in result["note"]
    payload = env.mock.payloads()[0]
    assert payload["aps"]["thread-id"] == "local-1" and payload["hermes"]["session_id"] == "local-1"
    assert payload["aps"]["alert"] == {"title": "Train", "body": TEXT}
    assert ring_log(env)[-1]["source"] == "cli" and ring_log(env)[-1]["session_id"] == "local-1"
    # A long text crosses the socket cut to a bound, and the hub still says it was cut.
    long = json.loads(env.message.notify_user({"title": "t", "body": "x" * 50_000}, session_id="local-1"))
    assert long["status"] == "sent" and "body was cut" in long["note"]


def test_the_policy_runs_in_the_hub_for_other_processes(core, env, fake, hub_socket):
    fake.env.update({"HERMES_SESSION_PLATFORM": "telegram", "HERMES_SESSION_CHAT_TYPE": "dm",
                     "HERMES_SESSION_USER_ID": "43"})
    fake.env.pop("HERMES_SESSION_SOURCE", None)
    stranger = json.loads(env.message.notify_user({"title": "t", "body": TEXT}, session_id="tg-1"))
    assert stranger["status"] == "not_sent" and "owner" in stranger["note"]
    fake.env["HERMES_CRON_SESSION"] = "1"
    assert json.loads(env.message.notify_user({"title": "t", "body": TEXT}, session_id="cron-1"))["status"] == "sent"
    assert ring_log(env)[-1]["source"] == "cron"
    env.settings[0] = env.message.MessageSettings(allow_cron=False)
    refused = json.loads(env.message.notify_user({"title": "t", "body": TEXT}, session_id="cron-1"))
    assert refused["reason"] == "not_allowed" and "allow_cron" in refused["note"]


def test_another_profile_notifies_only_when_the_policy_names_it(core, env, fake, hub_socket, monkeypatch):
    remote = core.loader.module("remote", PLUGIN_DIR)
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    monkeypatch.setattr(remote, "payload", lambda origin, real=remote.payload: {**real(origin), "profile": "work"})
    result = json.loads(env.message.notify_user({"title": "t", "body": TEXT}, session_id="s1"))
    assert result["status"] == "not_sent" and "'work' profile" in result["note"]
    assert env.mock.requests == []


def test_without_a_dashboard_the_tool_is_not_available(core, env, fake):
    fake.bound_host = None
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    result = json.loads(env.message.notify_user({"title": "t", "body": TEXT}, session_id="s1"))
    assert result["status"] == "not_available" and "hermes serve" in result["note"]


def test_an_older_dashboard_plugin_says_so(core, env, fake, hub_socket, monkeypatch):
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    hubsock = core.loader.module("hubsock", PLUGIN_DIR)
    old = hubsock.HubServer._dispatch

    def dispatch(self, conn, op, message, signals):
        if op == "notify":
            raise hubsock.ProtocolError("unknown_op", "unknown op 'notify'")
        return old(self, conn, op, message, signals)

    monkeypatch.setattr(hubsock.HubServer, "_dispatch", dispatch)
    result = json.loads(env.message.notify_user({"title": "t", "body": TEXT}, session_id="s1"))
    assert result["status"] == "not_available" and "older hermes_voice plugin" in result["note"]


# ── status, privacy ────────────────────────────────────────────────────────────────────────────────────────


def test_status_says_whether_messages_can_go_out(core, env):
    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                before = (await http.get("/status")).json()
                send(env)
                after = (await http.get("/status")).json()
                env.alert_settings[0] = core.notify.AlertSettings(kinds=frozenset({"approval"}))
                off = (await http.get("/status")).json()
                return before, after, off

    before, after, off = asyncio.run(scenario())
    assert before["messages"] == {"available": True, "phones": 2, "sent": 0, "allow_cron": True}
    assert after["messages"]["sent"] == 1
    assert off["messages"]["available"] is False and "turned off on this host" in off["messages"]["note"]
    for voip in (VOIP, OTHER_VOIP):
        env.store.register(core.push.Device(voip, "sandbox", BUNDLE, ALERT if voip == VOIP else OTHER_ALERT,
                                            alerts={"message": False}))
    env.alert_settings[0] = core.notify.AlertSettings()
    assert env.messages.status() == {"available": False, "phones": 0, "sent": 1, "allow_cron": True,
                                     "note": "no registered iPhone takes message notifications"}


def test_the_text_never_reaches_a_log_or_a_file(core, env, tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    send(env, title="Gate", body=SECRET_TEXT)
    env.quiet[0] = True
    send(env, title="Gate", body=SECRET_TEXT)
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, alerts={"message": False}))
    env.store.register(core.push.Device(OTHER_VOIP, "production", BUNDLE, OTHER_ALERT, alerts={"message": False}))
    send(env, title="Gate", body=SECRET_TEXT)
    assert [entry["result"] for entry in ring_log(env)] == ["sent", "quiet", "not_sent"]
    logged = "\n".join(record.getMessage() + (record.exc_text or "") for record in caplog.records)
    assert "notify_user from s1 (desktop): sent" in logged
    written = {path.name: path.read_text(errors="replace") for path in tmp_path.rglob("*") if path.is_file()}
    assert "rings.jsonl" in written
    for secret in ("zebra", "Gate"):
        assert secret not in logged
        assert not [name for name, text in written.items() if secret in text]
    for entry in ring_log(env):
        assert set(entry) <= {"at", "event", "session_id", "source", "result", "reason", "urgency", "level",
                              "policy", "phones", "attempts", "cut", "previews", "detail"}
