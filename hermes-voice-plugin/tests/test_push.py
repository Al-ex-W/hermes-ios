"""VoIP pushes against a mock APNs: the provider token (ES256, cached ~45 min, re-signed once on
ExpiredProviderToken), the request APNs expects, device bookkeeping, and clear reasons when something's missing."""

from __future__ import annotations

import json

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

TOKEN = "ab" * 32
KEY_ID, TEAM_ID = "KEY1234567", "TEAM123456"


@pytest.fixture
def apns_key(fake, tmp_path):
    private = ec.generate_private_key(ec.SECP256R1())
    pem = private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
    path = tmp_path / "AuthKey.p8"
    path.write_bytes(pem)
    fake.secrets.update({"HERMES_VOICE_APNS_KEY_PATH": str(path), "HERMES_VOICE_APNS_KEY_ID": KEY_ID,
                         "HERMES_VOICE_APNS_TEAM_ID": TEAM_ID})
    return private.public_key()


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

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self)


def _apns(core, tmp_path, mock, clock=lambda: 1_000_000.0):
    store = core.push.DeviceStore(lambda: tmp_path / "hermes-voice")
    store.register(core.push.Device(TOKEN, "sandbox", "com.example.hermesvoice"))
    return core.push.Apns(store, transport=mock.transport(), clock=clock), store


PAYLOAD = {"call_id": "c" * 32, "session_id": "s1", "profile": "default", "mode": "async", "title": "Chat"}


def test_a_voip_push_is_what_apns_expects(core, fake, tmp_path, apns_key):
    mock = MockApns()
    apns, _ = _apns(core, tmp_path, mock)
    result = apns.push_call(PAYLOAD)
    assert result.ok and result.delivered == 1
    request = mock.requests[0]
    assert str(request.url) == f"https://api.sandbox.push.apple.com/3/device/{TOKEN}"
    assert request.headers["apns-push-type"] == "voip"
    assert request.headers["apns-topic"] == "com.example.hermesvoice.voip"
    assert (request.headers["apns-priority"], request.headers["apns-expiration"]) == ("10", "0")
    assert json.loads(request.content) == PAYLOAD
    token = request.headers["authorization"].removeprefix("bearer ")
    assert jwt.get_unverified_header(token) == {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}
    claims = jwt.decode(token, apns_key, algorithms=["ES256"], options={"verify_iat": False})
    assert claims == {"iss": TEAM_ID, "iat": 1_000_000}


def test_the_provider_token_is_cached_then_refreshed(core, fake, tmp_path, apns_key):
    now = [1_000_000.0]
    mock = MockApns()
    apns, _ = _apns(core, tmp_path, mock, clock=lambda: now[0])
    apns.push_call(PAYLOAD)
    now[0] += 30 * 60
    apns.push_call(PAYLOAD)
    first, second = (r.headers["authorization"] for r in mock.requests)
    assert first == second and apns.signed == 1
    now[0] += 16 * 60  # past ~45 minutes: a fresh token
    apns.push_call(PAYLOAD)
    assert mock.requests[-1].headers["authorization"] != first and apns.signed == 2


def test_an_expired_provider_token_is_signed_again_once(core, fake, tmp_path, apns_key):
    now = [1_000_000.0]
    mock = MockApns((403, "ExpiredProviderToken"))
    apns, _ = _apns(core, tmp_path, mock, clock=lambda: now[0])
    apns.provider_token(core.push.load_key(core.hermes.get_secret)[0])  # a cached token APNs will refuse
    now[0] += 60
    assert apns.push_call(PAYLOAD).ok
    assert len(mock.requests) == 2 and apns.signed == 2
    assert mock.requests[0].headers["authorization"] != mock.requests[1].headers["authorization"]

    stubborn = MockApns((403, "ExpiredProviderToken"), (403, "ExpiredProviderToken"))
    apns, _ = _apns(core, tmp_path, stubborn, clock=lambda: now[0])
    result = apns.push_call(PAYLOAD)
    assert not result.ok and "ExpiredProviderToken" in result.reason and len(stubborn.requests) == 2


def test_a_device_apns_no_longer_knows_is_dropped(core, fake, tmp_path, apns_key):
    mock = MockApns((410, "Unregistered"))
    apns, store = _apns(core, tmp_path, mock)
    result = apns.push_call(PAYLOAD)
    assert not result.ok and result.reason == "APNs 410 Unregistered"
    assert store.devices() == []
    assert "no iPhone has registered" in apns.push_call(PAYLOAD).reason


def test_one_working_device_is_enough(core, fake, tmp_path, apns_key):
    mock = MockApns((400, "BadTopic"))
    apns, store = _apns(core, tmp_path, mock)
    store.register(core.push.Device("cd" * 32, "production", "com.example.hermesvoice"))
    result = apns.push_call(PAYLOAD)
    assert result.ok and result.delivered == 1
    assert {r.url.host for r in mock.requests} == {"api.push.apple.com", "api.sandbox.push.apple.com"}


def test_missing_pieces_are_reported_clearly(core, fake, tmp_path, monkeypatch, apns_key):
    store = core.push.DeviceStore(lambda: tmp_path / "hermes-voice")
    store.register(core.push.Device(TOKEN, "sandbox", "com.example.hermesvoice"))
    monkeypatch.setattr(core.push, "h2_available", lambda: False)
    no_h2 = core.push.Apns(store).push_call(PAYLOAD)
    assert not no_h2.ok and "h2" in no_h2.reason and "HTTP/2" in no_h2.reason

    fake.secrets.pop("HERMES_VOICE_APNS_TEAM_ID")
    assert core.push.Apns(store).configured() == (False, core.push.load_key()[1])
    assert "HERMES_VOICE_APNS_KEY_PATH" in core.push.load_key()[1]
    fake.secrets["HERMES_VOICE_APNS_TEAM_ID"] = "short"
    assert "10-character" in core.push.load_key()[1]
    fake.secrets["HERMES_VOICE_APNS_TEAM_ID"] = TEAM_ID
    fake.secrets["HERMES_VOICE_APNS_KEY_PATH"] = str(tmp_path / "missing.p8")
    reason = core.push.load_key()[1]
    assert "cannot read the APNs key file" in reason and "missing.p8" not in reason


def test_the_real_h2_check(core):
    import importlib.util
    assert core.push.h2_available() is (importlib.util.find_spec("h2") is not None)


@pytest.mark.parametrize(
    ("body", "error"),
    [
        ({"voip_token": TOKEN, "environment": "sandbox", "bundle_id": "com.example.app"}, None),
        ({"voip_token": TOKEN, "alert_token": "EF" * 32, "environment": "production", "bundle_id": "a.b"}, None),
        ({"voip_token": "xyz", "environment": "sandbox", "bundle_id": "a.b"}, "voip_token"),
        ({"voip_token": TOKEN, "alert_token": "nope", "environment": "sandbox", "bundle_id": "a.b"}, "alert_token"),
        ({"voip_token": TOKEN, "environment": "staging", "bundle_id": "a.b"}, "environment"),
        ({"voip_token": TOKEN, "environment": "sandbox", "bundle_id": "../etc"}, "bundle_id"),
        ({"voip_token": TOKEN, "environment": "sandbox", "bundle_id": "a/b"}, "bundle_id"),
        (["not", "an", "object"], "JSON object"),
    ],
)
def test_device_registrations_are_validated(core, body, error):
    if error is None:
        device = core.push.parse_device(body)
        assert device.voip_token == TOKEN and device.environment == body["environment"]
        assert device.alert_token in (None, "ef" * 32)
    else:
        with pytest.raises(core.push.DeviceError, match=error):
            core.push.parse_device(body)
