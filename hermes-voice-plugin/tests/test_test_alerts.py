"""Test alerts (``POST /devices/test``) against a mock APNs: the push the asking phone gets and no other, what the
route answers for each way it can fail, the delayed send and its outcome, the phone's answer, the rate limit, and
nothing secret in the logs."""

from __future__ import annotations

import asyncio
import json
import logging
import types

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from support import PREFIX, serving

VOIP, ALERT = "ab" * 32, "cd" * 32
OTHER_VOIP, OTHER_ALERT = "12" * 32, "34" * 32
KEY_ID, TEAM_ID = "KEY1234567", "TEAM123456"
BUNDLE = "com.example.hermesvoice"


class MockApns:
    """Answers like APNs; `script` is a list of (status, reason) for successive requests (then 200)."""

    def __init__(self, *script: tuple[int, str]) -> None:
        self.script = list(script)
        self.requests: list[httpx.Request] = []
        self.unreachable = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.unreachable:
            raise httpx.ConnectError("no route")
        if self.script:
            status, reason = self.script.pop(0)
            return httpx.Response(status, json={"reason": reason} if reason else {})
        return httpx.Response(200, headers={"apns-id": "x"})

    def tokens(self) -> list[str]:
        return [request.url.path.rsplit("/", 1)[-1] for request in self.requests]


@pytest.fixture
def env(core, fake, tmp_path, make_hub, monkeypatch):
    """Two phones registered for calls and alerts, a mock APNs behind the hub's real sender, fresh rate limits."""
    private = ec.generate_private_key(ec.SECP256R1())
    key_path = tmp_path / "AuthKey.p8"
    key_path.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
    fake.secrets.update({"HERMES_VOICE_APNS_KEY_PATH": str(key_path), "HERMES_VOICE_APNS_KEY_ID": KEY_ID,
                         "HERMES_VOICE_APNS_TEAM_ID": TEAM_ID})
    mock = MockApns()
    store = core.push.DeviceStore(lambda: tmp_path / "hermes-voice")
    store.register(core.push.Device(OTHER_VOIP, "production", BUNDLE, OTHER_ALERT))
    store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT))
    apns = core.push.Apns(store, transport=httpx.MockTransport(mock), clock=lambda: 1_000_000.0)
    hub = make_hub(pusher=apns)
    settings = [core.notify.AlertSettings()]
    tests = core.notify.TestAlerts(settings=lambda: settings[0])
    core.notify.install_test_alerts(tests)
    monkeypatch.setattr(core.api, "_test_limiter", core.api._Limiter(100, 60.0))
    monkeypatch.setattr(core.api, "_test_poll_limiter", core.api._Limiter(1000, 60.0))
    yield types.SimpleNamespace(fake=fake, hub=hub, mock=mock, store=store, apns=apns, settings=settings,
                                tests=tests, key_path=key_path, log=tmp_path / "hermes-voice" / "rings.jsonl")
    core.notify.install_test_alerts(None)


def post(core, *bodies: dict, path: str = "/devices/test") -> list[httpx.Response]:
    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                return [await http.post(path, json=body) for body in bodies]

    return asyncio.run(scenario())


def ring_log(env) -> list[dict]:
    if not env.log.exists():
        return []
    return [json.loads(line) for line in env.log.read_text().splitlines()]


# ── a test that goes out ───────────────────────────────────────────────────────────────────────────────────


def test_a_test_approval_goes_to_the_asking_phone_alone(core, env):
    [response] = post(core, {"voip_token": VOIP.upper()})
    answer = response.json()
    assert response.status_code == 200 and response.headers["cache-control"] == "no-store"
    assert answer == {"ok": True, "test_id": answer["test_id"], "kind": "approval", "status": "sent",
                      "code": "sent", "message": answer["message"], "delay_s": 0.0, "action": None}
    assert "APNs accepted" in answer["message"] and len(answer["test_id"]) == 16

    [request] = env.mock.requests  # the other phone takes approval alerts too, and hears nothing
    assert request.url.host == "api.sandbox.push.apple.com" and request.url.path == f"/3/device/{ALERT}"
    assert request.headers["apns-push-type"] == "alert" and request.headers["apns-topic"] == BUNDLE
    assert request.headers["apns-priority"] == "10" and request.headers["apns-expiration"] == str(1_000_000 + 900)
    assert request.headers["apns-collapse-id"] == f"test-{answer['test_id']}"
    payload = json.loads(request.content)
    assert payload == {
        "aps": {"alert": {"title": "Hermes test", "body": core.notify.TEST_BODIES["approval"]},
                "category": "HERMES_APPROVAL", "thread-id": "hermes-voice-test", "sound": "default"},
        "hermes": {"kind": "approval", "session_id": "hermes-voice-test", "profile": "default",
                   "request_id": f"test-{answer['test_id']}", "choices": ["once", "session", "always", "deny"],
                   "test": True, "test_id": answer["test_id"]},
    }
    # The same shape as a real approval alert, plus the test marks.
    real = core.notify.request_alert("approval", {"description": "d"}, request_id="srq-1", title="T",
                                     session_id="s1", profile="default", previews=True)
    assert set(payload["aps"]) == set(real["aps"]) and set(payload["hermes"]) - set(real["hermes"]) == {"test",
                                                                                                         "test_id"}
    assert ring_log(env) == [{"at": ring_log(env)[0]["at"], "event": "test_alert", "kind": "approval",
                              "result": "sent"}]


@pytest.mark.parametrize(("kind", "category"), [("clarify", "HERMES_CLARIFY"), ("turn_done", "HERMES_TURN_DONE")])
def test_the_other_kinds_look_like_their_real_alerts(core, env, kind, category):
    [response] = post(core, {"alert_token": ALERT, "kind": kind})  # found by its alert token alone
    assert response.json()["status"] == "sent" and response.json()["kind"] == kind
    assert env.mock.tokens() == [ALERT]
    payload = json.loads(env.mock.requests[0].content)
    assert payload["aps"]["category"] == category and payload["aps"]["sound"] == "default"
    assert payload["hermes"]["test"] is True and payload["hermes"]["kind"] == kind
    if kind == "clarify":
        assert payload["hermes"]["questions"] == [{"qid": "test", "question": core.notify.TEST_BODIES["clarify"],
                                                   "choices": None, "multi_select": False}]
        assert payload["hermes"]["request_id"].startswith("test-")
    else:
        assert "request_id" not in payload["hermes"] and "questions" not in payload["hermes"]
        assert env.mock.requests[0].headers["apns-expiration"] == str(1_000_000 + 3600)


def test_each_phone_gets_only_the_test_it_asked_for(core, env):
    first, second = post(core, {"voip_token": OTHER_VOIP}, {"voip_token": VOIP, "alert_token": OTHER_ALERT})
    assert first.json()["status"] == second.json()["status"] == "sent"
    # The VoIP token says which phone asks; a second token naming another phone doesn't add that one.
    assert env.mock.tokens() == [OTHER_ALERT, ALERT]
    assert [request.url.host for request in env.mock.requests] == ["api.push.apple.com",
                                                                  "api.sandbox.push.apple.com"]


def test_a_test_sounds_in_quiet_hours_and_spends_no_budget(core, env, monkeypatch):
    watcher = core.notify.Alerts(pusher=lambda: env.apns, quiet_hours=lambda: True)
    post(core, {"voip_token": VOIP, "kind": "turn_done"})
    payload = json.loads(env.mock.requests[0].content)
    assert payload["aps"]["sound"] == "default" and "interruption-level" not in payload["aps"]
    assert not watcher.sounded and core.notify.alerts().sent == 0


# ── a delayed test, and the phone's answer ─────────────────────────────────────────────────────────────────


def test_a_delayed_test_is_sent_later_and_its_outcome_can_be_read(core, env):
    gate = asyncio.Event()
    loop: list[asyncio.AbstractEventLoop] = []
    slept: list[float] = []

    def sleep(seconds: float) -> None:  # the sender's thread waits here until the test lets it go
        slept.append(seconds)
        asyncio.run_coroutine_threadsafe(gate.wait(), loop[0]).result(timeout=10)

    env.tests.sleep = sleep

    async def scenario():
        loop.append(asyncio.get_running_loop())
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                asked = (await http.post("/devices/test", json={"voip_token": VOIP, "delay_s": 5})).json()
                waiting = (await http.get(f"/devices/test/{asked['test_id']}")).json()
                before = len(env.mock.requests)
                gate.set()
                sent = waiting
                for _ in range(200):
                    sent = (await http.get(f"/devices/test/{asked['test_id']}")).json()
                    if sent["status"] != "scheduled":
                        break
                    await asyncio.sleep(0.02)
                answered = await http.post(f"/devices/test/{asked['test_id']}/answer", json={"action": "once"})
                after = (await http.get(f"/devices/test/{asked['test_id']}")).json()
                unknown = await http.get("/devices/test/" + "0" * 16)
                odd = await http.get("/devices/test/nope")
                lost = await http.post("/devices/test/" + "0" * 16 + "/answer", json={"action": "deny"})
                bad = await http.post(f"/devices/test/{asked['test_id']}/answer", json={"action": "rm -rf"})
                return asked, waiting, before, sent, answered, after, unknown, odd, lost, bad

    asked, waiting, before, sent, answered, after, unknown, odd, lost, bad = asyncio.run(scenario())
    assert asked["ok"] is True and asked["status"] == "scheduled" and asked["code"] == "scheduled"
    assert asked["delay_s"] == 5.0 and "5 s" in asked["message"] and "Lock the iPhone" in asked["message"]
    assert waiting == asked and before == 0 and slept == [5.0]
    assert sent["status"] == "sent" and sent["code"] == "sent" and env.mock.tokens() == [ALERT]
    assert answered.status_code == 200 and answered.json() == after
    assert after["status"] == "answered" and after["action"] == "once" and after["ok"] is True
    assert unknown.status_code == 404 and odd.status_code == 404 and lost.status_code == 404
    assert bad.status_code == 400 and "action" in bad.json()["detail"]
    assert [(entry["event"], entry.get("result") or entry.get("action")) for entry in ring_log(env)] == [
        ("test_alert", "sent"), ("test_alert_answered", "once")]


def test_an_answer_that_overtakes_the_send_stays_answered(core, env):
    test = env.tests.begin("clarify", VOIP)
    send = env.apns.push_alert

    def answered_before_apns_returns(*args, **kwargs):
        result = send(*args, **kwargs)
        assert env.tests.answered(test.test_id, "reply") is test
        return result

    env.apns.push_alert = answered_before_apns_returns
    env.tests.send(test)
    assert test.status == "answered" and test.action == "reply" and len(env.mock.requests) == 1
    env.tests.send(test)  # a test is pushed once
    assert len(env.mock.requests) == 1


# ── what can go wrong ──────────────────────────────────────────────────────────────────────────────────────


def failure(core, body: dict | None = None) -> dict:
    [response] = post(core, body or {"voip_token": VOIP})
    answer = response.json()
    assert response.status_code == 200 and answer["ok"] is False and answer["status"] == "failed"
    assert answer["message"] and answer["action"] is None
    return answer


def test_a_phone_that_never_registered(core, env):
    answer = failure(core, {"voip_token": "99" * 32})
    assert answer["code"] == "not_registered" and "isn't registered" in answer["message"]
    assert env.mock.requests == []


def test_apns_not_configured(core, env, monkeypatch):
    env.fake.secrets.pop("HERMES_VOICE_APNS_KEY_ID")
    answer = failure(core)
    assert answer["code"] == "apns_not_configured" and "HERMES_VOICE_APNS_KEY_PATH" in answer["message"]
    env.fake.secrets["HERMES_VOICE_APNS_KEY_ID"] = KEY_ID
    env.apns.transport = None  # the real HTTP/2 client, which needs h2
    monkeypatch.setattr(core.push, "h2_available", lambda: False)
    answer = failure(core)
    assert answer["code"] == "apns_not_configured" and "h2" in answer["message"]
    assert env.mock.requests == []


def test_alerts_turned_off_on_the_host_or_the_phone(core, env):
    env.settings[0] = core.notify.AlertSettings(enabled=False)
    assert failure(core)["code"] == "off_on_host"
    env.settings[0] = core.notify.AlertSettings(kinds=frozenset({"approval", "turn_done"}))
    answer = failure(core, {"voip_token": VOIP, "kind": "clarify"})
    assert answer["code"] == "off_on_host" and "question notifications" in answer["message"]
    env.settings[0] = core.notify.AlertSettings()
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, alerts={"turn_done": False}))
    answer = failure(core, {"voip_token": VOIP, "kind": "turn_done"})
    assert answer["code"] == "off_on_phone" and "This iPhone has turn-finished notifications turned off" in \
        answer["message"]
    assert env.mock.requests == []


def test_a_phone_without_an_alert_token(core, env):
    env.store.forget_alert_token(ALERT)
    answer = failure(core)
    assert answer["code"] == "no_alert_token" and "allow notifications" in answer["message"]
    assert env.mock.requests == []


@pytest.mark.parametrize(("status", "reason", "code", "says"), [
    (400, "BadDeviceToken", "bad_token", "sandbox environment (APNs answered 400 BadDeviceToken)"),
    (410, "Unregistered", "bad_token", "APNs answered 410 Unregistered"),
    (403, "BadEnvironmentKeyInToken", "wrong_environment", "sandbox environment"),
    (400, "DeviceTokenNotForTopic", "wrong_topic", "bundle id"),
    (403, "InvalidProviderToken", "bad_key", "HERMES_VOICE_APNS_KEY_ID"),
    (429, "TooManyRequests", "apns_unreachable", "Try again"),
    (503, "ServiceUnavailable", "apns_unreachable", "APNs 503 ServiceUnavailable"),
    (400, "PayloadEmpty", "refused", "APNs 400 PayloadEmpty"),
    (400, "", "refused", "APNs 400"),
])
def test_what_apns_refuses_is_said_in_words(core, env, status, reason, code, says):
    env.mock.script = [(status, reason)]
    answer = failure(core)
    assert answer["code"] == code and says in answer["message"]
    assert len(env.mock.requests) == 1
    [entry] = ring_log(env)
    assert (entry["event"], entry["kind"], entry["result"]) == ("test_alert", "approval", code)
    assert entry["detail"] == f"APNs {status} {reason}".strip()
    [device] = [d for d in env.store.devices() if d.voip_token == VOIP]
    # As for a real alert: a token APNs doesn't know is forgotten (the phone still rings), any other stays.
    assert device.alert_token == (None if code == "bad_token" or reason == "DeviceTokenNotForTopic" else ALERT)
    [other] = [d for d in env.store.devices() if d.voip_token == OTHER_VOIP]
    assert other.alert_token == OTHER_ALERT


def test_apns_unreachable_and_a_sender_that_blows_up(core, env):
    env.mock.unreachable = True
    answer = failure(core)
    assert answer["code"] == "apns_unreachable" and "ConnectError" in answer["message"]

    class Broken:
        store = env.store

        def ready(self):
            return True, ""

        def push_alert(self, *args, **kwargs):
            raise RuntimeError(f"boom {ALERT}")

    env.hub.pusher = Broken()
    answer = failure(core)
    assert answer["code"] == "refused" and "RuntimeError" in answer["message"] and ALERT not in answer["message"]


def test_a_host_that_cannot_send_alerts_says_so(core, env, make_hub):
    make_hub()  # the tests' call-only pusher: no device store, no alert sender
    assert failure(core)["code"] == "not_registered"


# ── the route's own checks ─────────────────────────────────────────────────────────────────────────────────


def test_bad_requests_are_refused(core, env):
    responses = post(core, {"voip_token": VOIP, "kind": "voip"}, {"kind": "approval"}, {"voip_token": "xyz"},
                     {"alert_token": 7}, {"voip_token": VOIP, "delay_s": 31}, {"voip_token": VOIP, "delay_s": -1},
                     {"voip_token": VOIP, "delay_s": "5"}, {"voip_token": VOIP, "delay_s": True})
    assert [response.status_code for response in responses] == [400] * 8
    details = [response.json()["detail"] for response in responses]
    assert "kind" in details[0] and "voip_token or alert_token" in details[1] and "voip_token" in details[2]
    assert "alert_token" in details[3] and all("delay_s" in detail for detail in details[4:])

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                return (await http.post("/devices/test", content=b"not json"),
                        await http.post("/devices/test", content=b"[1]"),
                        await http.post("/devices/test", content=b"{" + b" " * 5000 + b"}"))

    garbage, array, huge = asyncio.run(scenario())
    assert (garbage.status_code, array.status_code, huge.status_code) == (400, 400, 413)
    assert env.mock.requests == [] and ring_log(env) == []


def test_test_alerts_are_rate_limited(core, env, monkeypatch):
    monkeypatch.setattr(core.api, "_test_limiter", core.api._Limiter(2, 60.0))
    responses = post(core, *[{"voip_token": VOIP}] * 4)
    assert [response.status_code for response in responses] == [200, 200, 429, 429]
    assert "Too many test notifications" in responses[2].json()["detail"]
    assert len(env.mock.requests) == 2
    assert core.api.TEST_LIMIT <= 10  # the real limit stays a handful a minute


def test_nothing_secret_reaches_the_logs(core, env, caplog):
    caplog.set_level(logging.DEBUG, logger="hermes_voice")
    env.mock.script = [(403, "ExpiredProviderToken"), (400, "BadDeviceToken")]
    first, second = post(core, {"voip_token": VOIP, "alert_token": ALERT}, {"voip_token": OTHER_VOIP,
                                                                           "kind": "clarify"})
    post(core, {"action": "reply"}, path=f"/devices/test/{second.json()['test_id']}/answer")
    logged = "\n".join(record.getMessage() + (record.exc_text or "") for record in caplog.records)
    assert "test approval alert: bad_token" in logged and "test clarify alert: sent" in logged
    assert "answered a test clarify alert (reply)" in logged
    written = env.log.read_text()
    tokens = [request.headers["authorization"].removeprefix("bearer ") for request in env.mock.requests]
    for secret in [VOIP, ALERT, OTHER_VOIP, OTHER_ALERT, str(env.key_path), env.key_path.read_text().splitlines()[1],
                   core.notify.TEST_BODIES["clarify"], first.json()["test_id"], *tokens]:
        assert secret not in logged and secret not in written
    for answer in (first.json(), second.json()):
        assert all(token not in json.dumps(answer) for token in (VOIP, ALERT, OTHER_VOIP, OTHER_ALERT))
