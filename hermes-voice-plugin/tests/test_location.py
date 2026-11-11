"""``get_location`` (location.py): the tool in every state, the background push APNs gets, the phone's answer over
``POST /location`` and over a call's socket, who may ask and how often, the stored fix and when it goes, the hub
socket for other processes, and that no coordinate reaches a log or a file."""

from __future__ import annotations

import asyncio
import json
import logging
import threading
import time
import types

import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from support import PLUGIN_DIR, PREFIX, FakePusher, Phone, iso, serving, tool, until

VOIP, ALERT = "ab" * 32, "cd" * 32
OTHER_VOIP, OTHER_ALERT = "12" * 32, "34" * 32
KEY_ID, TEAM_ID = "KEY1234567", "TEAM123456"
BUNDLE = "com.example.hermesvoice"
# Obviously fake coordinates, distinctive enough to search every log and file for.
LAT, LON = 59.123456, 18.654321
SECRETS = ("59.12", "18.65")


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

    def request_ids(self) -> list[str]:
        return [json.loads(request.content)["hermes"]["request_id"] for request in self.requests]


@pytest.fixture
def env(core, fake, tmp_path, make_hub, monkeypatch):
    """A phone that shares its location (and one that doesn't), a mock APNs behind the hub's real sender, a clock
    the test moves, and this process's location state."""
    location = core.api.location
    private = ec.generate_private_key(ec.SECP256R1())
    key_path = tmp_path / "AuthKey.p8"
    key_path.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
    fake.secrets.update({"HERMES_VOICE_APNS_KEY_PATH": str(key_path), "HERMES_VOICE_APNS_KEY_ID": KEY_ID,
                         "HERMES_VOICE_APNS_TEAM_ID": TEAM_ID})
    fake.host.add("s1")
    mock = MockApns()
    store = core.push.DeviceStore(lambda: tmp_path / "hermes-voice")
    store.register(core.push.Device(OTHER_VOIP, "production", BUNDLE, OTHER_ALERT))
    store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, location=True, location_background=True))
    now = [time.time()]
    apns = core.push.Apns(store, transport=httpx.MockTransport(mock), clock=lambda: now[0])
    hub = make_hub(pusher=apns)
    settings = [location.LocationSettings(timeout_s=5.0)]
    locations = location.Locations(hub=lambda: hub, settings=lambda: settings[0], clock=lambda: now[0])
    location.install(locations)
    monkeypatch.setattr(core.api, "_location_limiter", core.api._Limiter(1000, 60.0))
    monkeypatch.setattr(core.api, "_device_limiter", core.api._Limiter(1000, 60.0))
    yield types.SimpleNamespace(location=location, locations=locations, fake=fake, hub=hub, mock=mock, store=store,
                                settings=settings, now=now, log=tmp_path / "hermes-voice" / "rings.jsonl",
                                origin=core.hermes.Origin(session_id="s1", source="desktop"))
    location.install(None)


def fix_body(request_id: str, **over) -> dict:
    return {"voip_token": VOIP, "request_id": request_id, "latitude": LAT, "longitude": LON, "accuracy_m": 12.4,
            "fixed_at": iso(), **over}


def ring_log(env) -> list[dict]:
    if not env.log.exists():
        return []
    return [json.loads(line) for line in env.log.read_text().splitlines()]


def ask(env, origin=None, **kw) -> tuple[threading.Thread, dict]:
    """Start a request on a tool thread; the result lands in the returned dict."""
    out: dict = {}

    def run() -> None:
        out["result"] = env.locations.request(origin or env.origin, **kw)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread, out


def wait_for(predicate, timeout: float = 5.0):
    deadline = time.monotonic() + timeout
    while not (value := predicate()):
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.01)
    return value


def answer_by_push(env, max_age_s=0, **over) -> dict:
    """One request, answered by the phone as a registered device (what POST /location does)."""
    before = len(env.mock.requests)
    thread, out = ask(env, max_age_s=max_age_s)
    wait_for(lambda: len(env.mock.requests) > before)
    device = env.location.find_device(env.hub, VOIP)
    env.locations.answered(fix_body(env.mock.request_ids()[-1], **over), "push", device)
    thread.join(5)
    return out["result"]


# ── the push path ──────────────────────────────────────────────────────────────────────────────────────────


def test_a_background_push_asks_and_the_phone_posts_its_fix(core, env):
    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin))
                await until(lambda: env.mock.requests)
                [request_id] = env.mock.request_ids()
                posted = await http.post("/location", json=fix_body(request_id, speed_mps=1.4, course_deg=270.0))
                status = await http.get("/status")
                return await asking, posted, status

    result, posted, status = asyncio.run(scenario())
    assert posted.status_code == 200 and posted.json() == {"ok": True}
    assert result["status"] == "ok" and result["source"] == "push"
    assert (result["latitude"], result["longitude"], result["accuracy_m"]) == (LAT, LON, 12.4)
    assert (result["speed_mps"], result["course_deg"]) == (1.4, 270.0)
    assert 0 <= result["age_s"] < 5 and result["fixed_at"].endswith("Z")
    # The push APNs got: a background one, to the phone that shares and to no other.
    [request] = env.mock.requests
    assert str(request.url) == f"https://api.sandbox.push.apple.com/3/device/{ALERT}"
    assert request.headers["apns-push-type"] == "background" and request.headers["apns-priority"] == "5"
    assert request.headers["apns-topic"] == BUNDLE
    assert int(request.headers["apns-expiration"]) == int(env.now[0] + core.push.BACKGROUND_TTL_S)
    payload = json.loads(request.content)
    assert payload["aps"] == {"content-available": 1}
    assert payload["hermes"] == {"kind": "location_request", "request_id": payload["hermes"]["request_id"],
                                 "profile": "default"}
    # The status says that a phone shares, and how old its fix is; never where it is.
    shown = status.json()["location"]
    assert shown == {"enabled": True, "sharing": True, "phones": 1, "background": 1,
                     "last_fix_age_s": shown["last_fix_age_s"]}
    assert not any(secret in status.text for secret in SECRETS)
    assert ring_log(env)[-1] | {"at": 0, "took_s": 0} == {
        "at": 0, "event": "location", "session_id": "s1", "source": "desktop", "result": "ok", "via": "push",
        "took_s": 0}


def test_a_young_fix_is_given_without_asking_the_phone_again(core, env):
    first = answer_by_push(env)
    assert first["source"] == "push" and len(env.mock.requests) == 1
    env.now[0] += 30
    cached = env.locations.request(env.origin)
    assert cached["status"] == "ok" and cached["source"] == "cached" and 29 < cached["age_s"] < 36
    assert "not asked again" in cached["note"] and len(env.mock.requests) == 1
    assert env.locations.request(env.origin, max_age_s=600)["source"] == "cached"
    env.now[0] += 40  # older than fresh_s (60 s): the phone is asked
    fresh = answer_by_push(env, max_age_s=None)
    assert fresh["source"] == "push" and len(env.mock.requests) == 2


def test_a_phone_that_does_not_answer_gives_the_last_fix_marked_as_old(core, env):
    answer_by_push(env)
    env.settings[0] = env.location.LocationSettings(timeout_s=0.3)
    env.now[0] += 600
    result = env.locations.request(env.origin)
    assert result["status"] == "no_answer"
    assert "did not answer within 0.3 s" in result["note"] and "force-quit" in result["note"]
    assert "While Using the App" not in result["note"]  # this phone answers in the background
    last = result["last_known"]
    assert last["stale"] is True and 599 < last["age_s"] < 606 and (last["latitude"], last["longitude"]) == (LAT, LON)
    assert "10 minutes ago" in result["note"] and "old" in result["note"]
    assert "latitude" not in result  # nothing that reads like a current position
    assert ring_log(env)[-1]["result"] == "no_answer" and ring_log(env)[-1]["via"] == "push"


def test_no_answer_from_a_phone_without_background_access_says_so(core, env):
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, location=True, location_background=False))
    env.settings[0] = env.location.LocationSettings(timeout_s=0.2)
    result = env.locations.request(env.origin)
    assert result["status"] == "no_answer" and "While Using the App" in result["note"]
    assert "last_known" not in result


def test_a_late_answer_becomes_the_last_known_fix(core, env):
    env.settings[0] = env.location.LocationSettings(timeout_s=0.2)
    assert env.locations.request(env.origin)["status"] == "no_answer"
    [request_id] = env.mock.request_ids()
    env.locations.answered(fix_body(request_id), "push", env.location.find_device(env.hub, VOIP))
    assert env.locations.request(env.origin)["source"] == "cached"
    # Past the window for late answers the id is forgotten.
    env.now[0] += env.location.LATE_ANSWER_S + 1
    with pytest.raises(env.location.LocationError) as refused:
        env.locations.answered(fix_body(request_id), "push", env.location.find_device(env.hub, VOIP))
    assert refused.value.status == 409


@pytest.mark.parametrize("error, status, says", [
    ("denied", "unavailable", "While Using the App"),
    ("unavailable", "unavailable", "can't get a position fix"),
    ("timeout", "unavailable", "in time"),
    ("off", "sharing_off", "Share location with Hermes"),
    ("something new", "unavailable", "can't get a position fix"),
])
def test_what_the_phone_could_not_do_is_said_in_words(core, env, error, status, says):
    thread, out = ask(env)
    wait_for(lambda: env.mock.requests)
    env.locations.answered({"request_id": env.mock.request_ids()[0], "error": error}, "push",
                           env.location.find_device(env.hub, VOIP))
    thread.join(5)
    assert out["result"]["status"] == status and says in out["result"]["note"]


def test_a_phone_that_ran_out_of_time_without_background_access(core, env):
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, location=True, location_background=False))
    thread, out = ask(env)
    wait_for(lambda: env.mock.requests)
    env.locations.answered({"request_id": env.mock.request_ids()[0], "error": "timeout"}, "push",
                           env.location.find_device(env.hub, VOIP))
    thread.join(5)
    assert out["result"]["status"] == "unavailable" and "While Using the App" in out["result"]["note"]


@pytest.mark.parametrize("script, says", [
    ([(400, "BadDeviceToken")], "APNs 400 BadDeviceToken"),
    ([(503, "")], "APNs 503"),
])
def test_a_push_apns_refuses_is_reported(core, env, script, says):
    env.mock.script = list(script)
    result = env.locations.request(env.origin)
    assert result["status"] == "push_failed" and says in result["note"]
    assert ring_log(env)[-1]["result"] == "push_failed"
    if "BadDeviceToken" in says:  # as for an alert: the token is forgotten, the phone still rings
        assert env.location.find_device(env.hub, VOIP).alert_token is None


def test_a_host_that_cannot_push(core, env, fake, make_hub):
    del fake.secrets["HERMES_VOICE_APNS_KEY_PATH"]
    result = env.locations.request(env.origin)
    assert result["status"] == "push_failed" and "APNs is not configured" in result["note"]
    assert env.mock.requests == []


def test_a_phone_that_shares_but_has_no_alert_token_cannot_be_pushed(core, env):
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, None, location=True))
    result = env.locations.request(env.origin)
    assert result["status"] == "push_failed" and "notification token" in result["note"]


# ── sharing off, no phone ──────────────────────────────────────────────────────────────────────────────────


def test_sharing_off_says_so_and_nothing_is_sent(core, env):
    env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, location=False))
    result = env.locations.request(env.origin)
    assert result == {"status": "sharing_off", "note": env.location.SHARING_OFF}
    assert "Settings → Location" in result["note"] and env.mock.requests == []
    assert ring_log(env)[-1]["result"] == "sharing_off"


def test_no_phone_registered(core, env):
    env.store.remove(VOIP)
    env.store.remove(OTHER_VOIP)
    assert env.locations.request(env.origin)["status"] == "no_phone"
    assert env.locations.status() == {"enabled": True, "sharing": False, "phones": 0, "background": 0,
                                      "last_fix_age_s": None}


def test_turning_sharing_off_drops_the_fix_and_answers_whoever_waits(core, env):
    answer_by_push(env)
    assert env.locations.last() is not None
    body = {"voip_token": VOIP, "environment": "sandbox", "bundle_id": BUNDLE}

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                # A registration that doesn't name location keeps it (the app's alert changes don't turn it off).
                kept = await http.post("/devices", json=body)
                still = env.locations.last() is not None and env.location.find_device(env.hub, VOIP).location
                asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin, 0))
                await until(lambda: len(env.mock.requests) == 2)
                off = await http.post("/devices", json={**body, "location": {"enabled": False}})
                bad = await http.post("/devices", json={**body, "location": {"enabled": "yes"}})
                late = await http.post("/location", json=fix_body(env.mock.request_ids()[-1]))
                return kept, still, await asking, off, bad, late, (await http.get("/status")).json()["location"]

    kept, still, waiting, off, bad, late, status = asyncio.run(scenario())
    assert kept.status_code == 200 and still
    assert off.status_code == 200 and waiting["status"] == "sharing_off"
    assert env.locations.last() is None and "last_known" not in waiting
    assert bad.status_code == 400 and "location must be" in bad.json()["detail"]
    assert late.status_code == 403 and "doesn't share" in late.json()["detail"]
    assert status["sharing"] is False and status["last_fix_age_s"] is None
    device = env.location.find_device(env.hub, VOIP)
    assert device.location is False and device.alert_token == ALERT


def test_the_registration_carries_whether_the_phone_answers_in_the_background(core):
    parse = core.push.parse_device
    base = {"voip_token": VOIP, "environment": "sandbox", "bundle_id": BUNDLE}
    assert (parse(base).location, parse(base).location_background) == (False, False)
    on = parse({**base, "location": {"enabled": True, "background": True}})
    assert (on.location, on.location_background) == (True, True)
    assert parse({**base, "location": {"enabled": True}}).location_background is False
    assert parse({**base, "location": {"enabled": False, "background": True}}).location_background is False
    for bad in (True, "on", {"background": True}, {"enabled": True, "background": 1}):
        with pytest.raises(core.push.DeviceError):
            parse({**base, "location": bad})
    assert core.push.kept_fields(base) == {"alert_token", "location"}
    assert core.push.kept_fields({**base, "location": {"enabled": False}}) == {"alert_token"}


# ── the stored fix ─────────────────────────────────────────────────────────────────────────────────────────


def test_the_fix_is_dropped_after_keep_s(core, env):
    answer_by_push(env)
    env.now[0] += env.settings[0].keep_s - 1
    assert env.locations.last() is not None
    env.now[0] += 2
    assert env.locations.last() is None and env.locations.fix is None
    assert env.locations.status()["last_fix_age_s"] is None
    env.settings[0] = env.location.LocationSettings(timeout_s=0.2)
    assert "last_known" not in env.locations.request(env.origin)


def test_a_timer_drops_the_fix_even_when_nobody_asks(core, env):
    env.settings[0] = env.location.LocationSettings(timeout_s=5.0, keep_s=0.5)
    answer_by_push(env)
    assert env.locations.fix is not None and env.locations.expiry is not None
    wait_for(lambda: env.locations.fix is None)


def test_a_fix_never_shows_its_coordinates_when_printed(core, env):
    fix = env.location.parse_fix(fix_body("x"), time.time(), "push")
    assert not any(secret in text for secret in SECRETS for text in (repr(fix), str(fix), f"{fix}"))


@pytest.mark.parametrize("over, says", [
    ({"latitude": 91}, "latitude must be between"),
    ({"longitude": "18.0"}, "longitude must be a number"),
    ({"latitude": True}, "latitude must be a number"),
    ({"accuracy_m": -1}, "accuracy_m must be between"),
    ({"accuracy_m": float("nan")}, "accuracy_m must be a number"),
    ({"fixed_at": "yesterday"}, "fixed_at must be"),
    ({"fixed_at": iso(offset=3600)}, "in the future"),
    ({"course_deg": 400}, "course_deg must be between"),
])
def test_a_fix_is_validated(core, env, over, says):
    with pytest.raises(env.location.LocationError, match=says):
        env.location.parse_fix(fix_body("x", **over), time.time(), "push")


# ── the route ──────────────────────────────────────────────────────────────────────────────────────────────


def test_the_route_takes_only_answers_to_requests_from_phones_that_share(core, env):
    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin))
                await until(lambda: env.mock.requests)
                [request_id] = env.mock.request_ids()
                answers = {
                    "nobody asked": await http.post("/location", json=fix_body("0" * 16)),
                    "no request id": await http.post("/location", json={**fix_body(request_id), "request_id": None}),
                    "unknown phone": await http.post("/location", json=fix_body(request_id, voip_token="ef" * 32)),
                    "not sharing": await http.post("/location", json=fix_body(request_id, voip_token=OTHER_VOIP)),
                    "no token": await http.post("/location", json={**fix_body(request_id), "voip_token": ""}),
                    "bad token": await http.post("/location", json=fix_body(request_id, voip_token="zz")),
                    "bad fix": await http.post("/location", json=fix_body(request_id, latitude=123)),
                    "not json": await http.post("/location", content=b"[1]"),
                    "too large": await http.post("/location", content=b"{" + b" " * 5000 + b"}"),
                    # Found by its alert token too, as a registration finds a phone.
                    "ok": await http.post("/location", json={**fix_body(request_id), "voip_token": "",
                                                             "alert_token": ALERT.upper()}),
                }
                return await asking, answers

    result, answers = asyncio.run(scenario())
    assert {name: answer.status_code for name, answer in answers.items()} == {
        "nobody asked": 409, "no request id": 409, "unknown phone": 404, "not sharing": 403, "no token": 400,
        "bad token": 400, "bad fix": 400, "not json": 400, "too large": 413, "ok": 200}
    assert "Nobody asked" in answers["nobody asked"].json()["detail"]
    assert result["status"] == "ok" and result["source"] == "push"
    assert all(answer.headers.get("cache-control") == "no-store" for answer in answers.values())


def test_location_answers_are_rate_limited(core, env, monkeypatch):
    monkeypatch.setattr(core.api, "_location_limiter", core.api._Limiter(1, 60.0))

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                return [await http.post("/location", json=fix_body("0" * 16)) for _ in range(2)]

    assert [answer.status_code for answer in asyncio.run(scenario())] == [409, 429]


# ── on a call ──────────────────────────────────────────────────────────────────────────────────────────────


def test_on_a_call_the_phone_is_asked_over_its_socket(core, env, fake):
    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin))
            asked = await phone.expect("location_request")
            await phone.send({"type": "location", "id": asked["id"], "latitude": LAT, "longitude": LON,
                              "accuracy_m": 5, "fixed_at": iso()})
            result = await asking
            # An answer nobody asked for is ignored, and so is one that isn't a fix.
            await phone.send({"type": "location", "id": "0" * 16, "latitude": 1.0, "longitude": 2.0,
                              "accuracy_m": 5, "fixed_at": iso()})
            await phone.send({"type": "location", "id": asked["id"], "latitude": "north"})
            await phone.send({"type": "ping"})
            await phone.expect("pong")
            await phone.hang_up()
            return asked, result

    asked, result = asyncio.run(scenario())
    assert asked == {"type": "location_request", "id": asked["id"]} and len(asked["id"]) == 16
    assert result["status"] == "ok" and result["source"] == "call"
    assert (result["latitude"], result["longitude"], result["accuracy_m"]) == (LAT, LON, 5.0)
    assert env.mock.requests == []  # no push while a call is connected
    assert env.locations.last().latitude == LAT
    assert [entry["via"] for entry in ring_log(env) if entry["event"] == "location"] == ["call"]


def test_a_call_whose_phone_does_not_answer_or_cannot(core, env, fake):
    env.settings[0] = env.location.LocationSettings(timeout_s=0.3)

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            silent = await asyncio.to_thread(env.locations.request, env.origin)
            await phone.expect("location_request")
            env.settings[0] = env.location.LocationSettings(timeout_s=5.0)
            asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin))
            asked = await phone.expect("location_request")
            await phone.send({"type": "location", "id": asked["id"], "error": "denied"})
            refused = await asking
            await phone.hang_up()
            return silent, refused

    silent, refused = asyncio.run(scenario())
    assert silent["status"] == "no_answer" and "voice call's connection" in silent["note"]
    assert refused["status"] == "unavailable" and "While Using the App" in refused["note"]
    assert env.mock.requests == []


def test_a_fix_from_a_call_is_refused_when_no_phone_shares(core, env, fake):
    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake)
            asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin))
            asked = await phone.expect("location_request")
            env.store.register(core.push.Device(VOIP, "sandbox", BUNDLE, ALERT, location=False))
            await phone.send({"type": "location", "id": asked["id"], "latitude": LAT, "longitude": LON,
                              "accuracy_m": 5, "fixed_at": iso()})
            await phone.send({"type": "ping"})
            await phone.expect("pong")
            kept = env.locations.fix
            env.locations.device_registered(env.location.find_device(env.hub, VOIP))
            result = await asking
            await phone.hang_up()
            return kept, result

    kept, result = asyncio.run(scenario())
    assert kept is None and result["status"] == "sharing_off"


# ── who may ask, and how often ─────────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("origin, config, reason", [
    (dict(source="desktop"), {}, ""),
    (dict(source="cli"), {}, ""),
    (dict(source="oneshot"), {}, "source"),
    (dict(source="tool"), {}, "source"),
    (dict(source="desktop", is_subagent=True), {}, "subagent"),
    (dict(is_cron=True), {}, ""),  # the reason this exists: a scheduled "am I going to be late"
    (dict(is_cron=True), {"allow_cron": False}, "cron"),
    (dict(is_cron=True, is_subagent=True), {}, "subagent"),
    (dict(platform="telegram", chat_type="dm", user_id="42", is_owner=True), {}, ""),
    (dict(platform="telegram", chat_type="dm", user_id="43", is_owner=False), {}, "not_owner"),
    (dict(platform="telegram", chat_type="group", user_id="42", is_owner=True), {}, "group"),
    (dict(source="desktop"), {"enabled": False}, "off_on_host"),
])
def test_who_may_ask(core, env, origin, config, reason):
    settings = env.location.LocationSettings.from_plugin_settings({"location": config})
    decision = env.location.allowed(core.hermes.Origin(session_id="x", **origin), settings,
                                    core.config.PolicyConfig())
    assert (decision.allowed, decision.reason) == (not reason, reason)
    if reason:
        assert decision.note


def test_the_owner_of_a_dm_is_who_the_call_policy_names(core, env):
    stranger = core.hermes.Origin(session_id="x", platform="telegram", chat_type="dm", user_id="43", is_owner=True)
    named = core.config.PolicyConfig(owner_ids=("telegram:42",))
    assert env.location.allowed(stranger, env.settings[0], named).reason == "not_owner"
    no_dms = core.config.PolicyConfig(allow_owner_dms=False)
    assert env.location.allowed(stranger, env.settings[0], no_dms).reason == "not_owner"


def test_a_refused_conversation_asks_nobody_and_is_logged(core, env):
    group = core.hermes.Origin(session_id="g1", platform="telegram", chat_type="group", user_id="42", is_owner=True)
    result = env.locations.request(group)
    assert result["status"] == "not_allowed" and "group chat" in result["note"]
    assert env.mock.requests == [] and "last_known" not in result
    assert ring_log(env)[-1] | {"at": 0, "took_s": 0} == {
        "at": 0, "event": "location", "session_id": "g1", "source": "telegram", "result": "not_allowed",
        "reason": "group", "took_s": 0}


def test_settings_are_read_and_clamped(core, env):
    read = env.location.LocationSettings.from_plugin_settings
    assert read({}) == env.location.LocationSettings() == read({"location": "yes"})
    default = env.location.LocationSettings()
    assert (default.enabled, default.allow_cron, default.timeout_s, default.keep_s, default.fresh_s) == (
        True, True, 20.0, 1800.0, 60.0)
    assert (default.requests_per_session, default.session_window_s) == (6, 600.0)
    assert (default.requests_global, default.global_window_s) == (30, 3600.0)
    custom = read({"location": {"enabled": "off", "allow_cron": False, "timeout_s": 500, "keep_s": 1,
                                "fresh_s": "x", "requests_per_session": 2, "requests_global": 0}})
    assert (custom.enabled, custom.allow_cron, custom.timeout_s, custom.keep_s, custom.fresh_s) == (
        False, False, 60.0, 60.0, 60.0)
    assert (custom.requests_per_session, custom.requests_global) == (2, 1)


def test_a_loop_cannot_drain_the_battery(core, env):
    env.settings[0] = env.location.LocationSettings(timeout_s=5.0, requests_per_session=2, requests_global=3)
    assert answer_by_push(env)["status"] == "ok"
    assert answer_by_push(env)["status"] == "ok"
    env.now[0] += 120
    limited = env.locations.request(env.origin, max_age_s=0)
    assert limited["status"] == "rate_limited" and "2 times in the last 10 minutes" in limited["note"]
    assert limited["last_known"]["stale"] is True and len(env.mock.requests) == 2
    # A young enough fix is still given: that asks nobody.
    assert env.locations.request(env.origin, max_age_s=300)["source"] == "cached"
    # Another conversation has its own count, within the host's.
    other = core.hermes.Origin(session_id="s2", source="desktop")
    thread, out = ask(env, origin=other, max_age_s=0)
    wait_for(lambda: len(env.mock.requests) == 3)
    env.locations.answered(fix_body(env.mock.request_ids()[-1]), "push", env.location.find_device(env.hub, VOIP))
    thread.join(5)
    assert out["result"]["status"] == "ok"
    everyone = env.locations.request(core.hermes.Origin(session_id="s3", source="desktop"), max_age_s=0)
    assert everyone["status"] == "rate_limited" and "3 times in the last 60 minutes" in everyone["note"]
    env.now[0] += 3600  # the windows pass (and the fix is gone by then)
    env.settings[0] = env.location.LocationSettings(timeout_s=0.2, requests_per_session=2, requests_global=3)
    assert env.locations.request(env.origin, max_age_s=0)["status"] == "no_answer"
    assert len(env.mock.requests) == 4


def test_stop_ends_the_wait(core, env):
    stopped = threading.Event()
    thread, out = ask(env, interrupted=stopped.is_set)
    wait_for(lambda: env.mock.requests)
    stopped.set()
    thread.join(5)
    assert out["result"]["status"] == "interrupted"


# ── the tool ───────────────────────────────────────────────────────────────────────────────────────────────


def test_the_tool_answers_json_for_the_calling_conversation(core, env, fake):
    async def scenario():
        asking = asyncio.create_task(tool(env.location.get_location, {"max_age_s": 0}))
        await until(lambda: env.mock.requests)
        env.locations.answered(fix_body(env.mock.request_ids()[0]), "push", env.location.find_device(env.hub, VOIP))
        first = await asking
        cached = await tool(env.location.get_location, {"max_age_s": "soon"})  # not a number: the default
        nowhere = await tool(env.location.get_location, None, session_id="")
        fake.env.update({"HERMES_SESSION_PLATFORM": "telegram", "HERMES_SESSION_CHAT_TYPE": "group"})
        group = await tool(env.location.get_location, {})
        return first, cached, nowhere, group

    first, cached, nowhere, group = asyncio.run(scenario())
    assert set(first) == {"status", "latitude", "longitude", "accuracy_m", "age_s", "fixed_at", "source", "note"}
    assert first["source"] == "push" and cached["source"] == "cached"
    assert nowhere["status"] == "not_allowed" and group["status"] == "not_allowed"


def test_the_tool_never_raises(core, env, monkeypatch):
    monkeypatch.setattr(env.locations, "request", lambda *a, **k: 1 / 0)
    result = json.loads(env.location.get_location({}, session_id="s1"))
    assert result["status"] == "error" and "Ask the user" in result["note"]


def test_the_tool_schema_says_what_the_agent_needs(core):
    schema = core.api.location.GET_LOCATION
    assert schema["name"] == "get_location" and "required" not in schema["parameters"]
    for word in ("sharing_off", "no_answer", "last_known", "accuracy_m", "age_s", "Settings"):
        assert word in schema["description"]


def test_a_hub_without_a_background_sender_says_so(core, env, make_hub, tmp_path):
    pusher = FakePusher()
    pusher.store = env.store
    hub = make_hub(pusher=pusher)
    locations = env.location.Locations(hub=lambda: hub, settings=lambda: env.settings[0])
    result = locations.request(env.origin)
    assert result["status"] == "push_failed" and "can't send background pushes" in result["note"]


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


def test_another_process_asks_through_the_hub_socket(core, env, fake, hub_socket):
    fake.env["HERMES_SESSION_SOURCE"] = "cli"

    async def scenario():
        asking = asyncio.create_task(tool(env.location.get_location, {}))
        await until(lambda: env.mock.requests)
        env.locations.answered(fix_body(env.mock.request_ids()[0]), "push", env.location.find_device(env.hub, VOIP))
        return await asking, await tool(env.location.get_location, {"max_age_s": 120})

    first, cached = asyncio.run(scenario())
    assert first["status"] == "ok" and first["source"] == "push" and first["latitude"] == LAT
    assert cached["source"] == "cached"
    assert ring_log(env)[-1]["source"] == "cli" and ring_log(env)[-1]["session_id"] == "s1"


def test_the_policy_runs_in_the_hub_for_other_processes(core, env, fake, hub_socket):
    fake.env.update({"HERMES_SESSION_PLATFORM": "telegram", "HERMES_SESSION_CHAT_TYPE": "dm",
                     "HERMES_SESSION_USER_ID": "43"})
    fake.env.pop("HERMES_SESSION_SOURCE", None)
    stranger = json.loads(env.location.get_location({}, session_id="tg-1"))
    assert stranger["status"] == "not_allowed" and "owner" in stranger["note"]
    fake.env["HERMES_CRON_SESSION"] = "1"
    env.settings[0] = env.location.LocationSettings(timeout_s=0.2)
    assert json.loads(env.location.get_location({}, session_id="cron-1"))["status"] == "no_answer"
    assert ring_log(env)[-1]["source"] == "cron"
    assert env.mock.requests and all(r.headers["apns-push-type"] == "background" for r in env.mock.requests)


def test_another_profile_asks_only_when_the_policy_names_it(core, env, fake, hub_socket, monkeypatch):
    remote = core.loader.module("remote", PLUGIN_DIR)
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    monkeypatch.setattr(remote, "payload", lambda origin, real=remote.payload: {**real(origin), "profile": "work"})
    result = json.loads(env.location.get_location({}, session_id="s1"))
    assert result["status"] == "not_allowed" and "'work' profile" in result["note"]
    assert env.mock.requests == []


def test_without_a_dashboard_the_tool_is_not_available(core, env, fake):
    fake.bound_host = None
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    result = json.loads(env.location.get_location({}, session_id="s1"))
    assert result["status"] == "not_available" and "hermes serve" in result["note"]


def test_an_older_dashboard_plugin_says_so(core, env, fake, hub_socket, monkeypatch):
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    hubsock = core.loader.module("hubsock", PLUGIN_DIR)
    old = hubsock.HubServer._dispatch

    def dispatch(self, conn, op, message, signals):
        if op == "location":
            raise hubsock.ProtocolError("unknown_op", "unknown op 'location'")
        return old(self, conn, op, message, signals)

    monkeypatch.setattr(hubsock.HubServer, "_dispatch", dispatch)
    result = json.loads(env.location.get_location({}, session_id="s1"))
    assert result["status"] == "not_available" and "older hermes_voice plugin" in result["note"]


# ── privacy ────────────────────────────────────────────────────────────────────────────────────────────────


def test_no_coordinate_reaches_a_log_or_a_file(core, env, fake, tmp_path, caplog):
    caplog.set_level(logging.DEBUG)

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin))
                await until(lambda: env.mock.requests)
                await http.post("/location", json=fix_body(env.mock.request_ids()[0], speed_mps=3.21))
                pushed = await asking
                await http.post("/location", json=fix_body("0" * 16))  # refused: 409
                await http.post("/location", json=fix_body(env.mock.request_ids()[0], accuracy_m="x"))  # 400
                phone = await Phone.dial(port, fake)
                asking = asyncio.create_task(asyncio.to_thread(env.locations.request, env.origin, 0))
                asked = await phone.expect("location_request")
                await phone.send({"type": "location", "id": asked["id"], "latitude": LAT, "longitude": LON,
                                  "accuracy_m": 5, "fixed_at": iso()})
                called = await asking
                await phone.send({"type": "location", "id": "f" * 16, "latitude": LAT, "longitude": LON,
                                  "accuracy_m": 5, "fixed_at": iso()})  # ignored, and logged as ignored
                await phone.hang_up()
                status = await http.get("/status")
                return pushed, called, status

    pushed, called, status = asyncio.run(scenario())
    assert pushed["latitude"] == called["latitude"] == LAT
    env.settings[0] = env.location.LocationSettings(timeout_s=0.2)
    env.now[0] += 300
    assert env.locations.request(env.origin)["last_known"]["longitude"] == LON
    logged = "\n".join(record.getMessage() + (record.exc_text or "") for record in caplog.records)
    assert "location request from s1 (desktop): ok via push" in logged
    assert "ignored a location answer" in logged
    written = {path.name: path.read_text(errors="replace") for path in tmp_path.rglob("*") if path.is_file()}
    assert {"rings.jsonl", "devices.json"} <= set(written)
    for secret in (*SECRETS, "3.21"):
        assert secret not in logged and secret not in status.text
        assert not [name for name, text in written.items() if secret in text]
    # What APNs was sent carries no position either (there is none to carry: the request goes out, the fix comes in).
    assert not any(secret in request.content.decode() for request in env.mock.requests for secret in SECRETS)
    results = [entry["result"] for entry in ring_log(env) if entry["event"] == "location"]
    assert results == ["ok", "ok", "no_answer"]
    for entry in ring_log(env):
        assert set(entry) <= {"at", "event", "session_id", "source", "result", "via", "took_s", "reason", "call_id",
                              "what", "outcome", "detail"}
