"""Pushes to the user's iPhone, straight to APNs (no relay): VoIP pushes that ring it, and alert pushes (an
approval or a question waiting, a turn done; see ``notify.py``).

APNs takes HTTP/2 only, so this needs the ``h2`` package (declared in plugin.yaml; Hermes' own venv lacks it);
``/status`` says whether it imports. The provider token is an ES256 JWT signed with the team's APNs auth key
(``HERMES_VOICE_APNS_KEY_PATH`` / ``_KEY_ID`` / ``_TEAM_ID``, read with ``get_secret``), reused for about 45 minutes
(Apple allows 20-60) and signed again once when APNs answers ``403 ExpiredProviderToken``. Both kinds of push use
that one token and the same request path; only the headers differ:

- VoIP: ``apns-push-type: voip``, topic ``<bundle id>.voip``, priority 10, expiration 0 (now or never), to the
  device's VoIP token.
- Alert: ``apns-push-type: alert``, topic ``<bundle id>``, priority 10, an expiration a while ahead (APNs keeps it
  for a phone that is offline just now) and a collapse id, to the device's alert token; at most 4 KB.

Devices register with ``POST /api/plugins/hermes_voice/devices``; they are kept per profile in
``<HERMES_HOME>/hermes-voice/devices.json``, with the alert kinds each one turned off. APNs' ``410 Unregistered`` /
``BadDeviceToken`` drop a device (for a VoIP push) or just its alert token (for an alert).
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

import httpx

from . import hermes

logger = logging.getLogger("hermes_voice")

HOSTS = {"production": "https://api.push.apple.com", "sandbox": "https://api.sandbox.push.apple.com"}
TOKEN_TTL_S = 45 * 60
PUSH_TIMEOUT_S = 10.0
MAX_DEVICES = 5
DEVICE_TOKEN = re.compile(r"[0-9a-fA-F]{64,200}")
BUNDLE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,154}")
KEY_ID = re.compile(r"[A-Z0-9]{10}")
TEAM_ID = re.compile(r"[A-Z0-9]{10}")
GONE_REASONS = frozenset({"Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"})

# Alert kinds a phone can turn off one by one (POST /devices {"alerts": {kind: bool}}).
ALERT_KINDS = ("approval", "clarify", "turn_done")
# How long APNs keeps an alert for a phone that is offline just now: a waiting approval or question rarely
# outlives that (approvals.timeout is 300 s by default); a finished turn stays news for longer.
ALERT_TTL_S = {"approval": 900, "clarify": 900, "turn_done": 3600}
# APNs refuses a larger alert payload (VoIP allows 5 KB).
MAX_ALERT_BYTES = 4096
COLLAPSE_ID = re.compile(r"[A-Za-z0-9._:-]{1,64}")


def h2_available() -> bool:
    try:
        import h2  # noqa: F401
    except ImportError:
        return False
    return True


def encode_alert(payload: dict[str, Any]) -> bytes:
    """An alert payload as it goes to APNs (compact UTF-8): what the 4 KB limit counts."""
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


# ── devices ────────────────────────────────────────────────────────────────────────────────────────────────


@dataclass
class Device:
    voip_token: str
    environment: str
    bundle_id: str
    alert_token: Optional[str] = None
    registered_at: float = field(default_factory=time.time)
    # Alert kinds this phone turned off or back on ({"turn_done": False}); a kind it never named is on.
    alerts: dict[str, bool] = field(default_factory=dict)

    def wants(self, kind: str) -> bool:
        """Whether this phone takes alert pushes of `kind` (any needs an alert token)."""
        return bool(self.alert_token) and self.alerts.get(kind, True) is not False


class DeviceError(ValueError):
    pass


def parse_device(body: Any) -> Device:
    """A ``POST /devices`` body, validated (tokens are hex, the bundle id is a plain reverse-DNS name, ``alerts``
    maps alert kinds to true or false)."""
    if not isinstance(body, dict):
        raise DeviceError("body must be a JSON object")
    voip = str(body.get("voip_token") or "").strip()
    if not DEVICE_TOKEN.fullmatch(voip):
        raise DeviceError("voip_token must be the hex APNs token")
    alert = body.get("alert_token")
    alert = str(alert).strip() if alert else None
    if alert is not None and not DEVICE_TOKEN.fullmatch(alert):
        raise DeviceError("alert_token must be the hex APNs token")
    environment = str(body.get("environment") or "").strip()
    if environment not in HOSTS:
        raise DeviceError('environment must be "sandbox" or "production"')
    bundle = str(body.get("bundle_id") or "").strip()
    if not BUNDLE_ID.fullmatch(bundle) or ".." in bundle:
        raise DeviceError("bundle_id must be the app's bundle identifier")
    return Device(voip.lower(), environment, bundle, alert.lower() if alert else None,
                  alerts=_alert_choices(body.get("alerts")))


def _alert_choices(raw: Any) -> dict[str, bool]:
    if raw is None:
        return {}
    if not isinstance(raw, dict) or not all(isinstance(value, bool) for value in raw.values()):
        raise DeviceError(f"alerts must map {', '.join(ALERT_KINDS)} to true or false")
    return {kind: raw[kind] for kind in ALERT_KINDS if kind in raw}  # a kind this plugin doesn't know: ignored


def kept_fields(body: Any) -> frozenset[str]:
    """What a registration leaves as stored because the body doesn't name it: ``alert_token`` (an explicit null
    clears it). Alert choices are always merged kind by kind."""
    named = body if isinstance(body, dict) else {}
    return frozenset(name for name in ("alert_token",) if name not in named)


class DeviceStore:
    def __init__(self, folder: Callable[[], Path] = hermes.state_dir) -> None:
        self.folder = folder
        self.lock = threading.Lock()

    def _path(self) -> Path:
        return self.folder() / "devices.json"

    def devices(self) -> list[Device]:
        with self.lock:
            return self._read()

    def _read(self) -> list[Device]:
        try:
            raw = json.loads(self._path().read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return []
        devices = []
        for item in raw if isinstance(raw, list) else []:
            if not isinstance(item, dict):
                continue
            try:
                device = Device(**{k: item[k] for k in item if k in Device.__dataclass_fields__})
            except TypeError:
                continue
            alerts = device.alerts if isinstance(device.alerts, dict) else {}
            device.alerts = {k: v for k, v in alerts.items() if k in ALERT_KINDS and isinstance(v, bool)}
            devices.append(device)
        return devices

    def _write(self, devices: list[Device]) -> None:
        path = self._path()
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps([asdict(d) for d in devices], indent=2), encoding="utf-8")
        os.chmod(temp, 0o600)
        temp.replace(path)

    def register(self, device: Device, keep: frozenset[str] = frozenset()) -> Device:
        """Store a phone, newest first. The same phone (its VoIP token, else its alert token) registering again
        keeps its alert token when ``keep`` names it, and its alert choices for the kinds it doesn't name now.
        Returns what is stored."""
        with self.lock:
            devices = self._read()
            earlier = next((d for d in devices if d.voip_token == device.voip_token), None) or next(
                (d for d in devices if device.alert_token and d.alert_token == device.alert_token), None)
            if earlier is not None:
                if "alert_token" in keep:
                    device.alert_token = earlier.alert_token
                device.alerts = {**earlier.alerts, **device.alerts}
            # A phone whose VoIP token changed but not its alert token is the same phone: one entry, one alert.
            others = [d for d in devices if d.voip_token != device.voip_token
                      and not (device.alert_token and d.alert_token == device.alert_token)]
            self._write([device, *others][:MAX_DEVICES])
            return device

    def remove(self, voip_token: str) -> None:
        with self.lock:
            devices = self._read()
            kept = [d for d in devices if d.voip_token != voip_token]
            if len(kept) != len(devices):
                self._write(kept)

    def forget_alert_token(self, alert_token: str) -> None:
        """APNs no longer knows this alert token: the phone still rings, it gets no alerts until it registers a
        new one."""
        with self.lock:
            devices = self._read()
            changed = False
            for device in devices:
                if device.alert_token == alert_token:
                    device.alert_token, changed = None, True
            if changed:
                self._write(devices)


# ── APNs ───────────────────────────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class PushResult:
    ok: bool
    reason: str = ""
    delivered: int = 0
    # Nothing went out, for a passing reason (APNs unreachable, 429, 5xx): worth trying again shortly.
    retry: bool = False


@dataclass(frozen=True)
class ApnsKey:
    pem: str
    key_id: str
    team_id: str


def load_key(secret: Callable[[str], Optional[str]] = hermes.get_secret) -> tuple[Optional[ApnsKey], str]:
    """The APNs auth key, or why it isn't usable (never the key itself)."""
    path, key_id, team_id = (secret(f"HERMES_VOICE_APNS_{name}") for name in ("KEY_PATH", "KEY_ID", "TEAM_ID"))
    if not (path and key_id and team_id):
        return None, "APNs is not configured: set HERMES_VOICE_APNS_KEY_PATH, _KEY_ID and _TEAM_ID"
    if not KEY_ID.fullmatch(key_id) or not TEAM_ID.fullmatch(team_id):
        return None, "HERMES_VOICE_APNS_KEY_ID and _TEAM_ID must be the 10-character ids from Apple"
    try:
        pem = Path(path).expanduser().read_text(encoding="utf-8")
    except OSError as error:
        return None, f"cannot read the APNs key file ({type(error).__name__})"
    if "PRIVATE KEY" not in pem:
        return None, "the APNs key file is not a .p8 private key"
    return ApnsKey(pem, key_id, team_id), ""


class Apns:
    def __init__(
        self,
        store: Optional[DeviceStore] = None,
        key: Callable[[], tuple[Optional[ApnsKey], str]] = load_key,
        transport: Optional[httpx.BaseTransport] = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.store = store or DeviceStore()
        self.key = key
        self.transport = transport
        self.clock = clock
        self.lock = threading.Lock()
        self._token: Optional[tuple[str, float, str]] = None  # (jwt, issued_at, key_id + team_id)
        self.signed = 0  # how many tokens were signed (for tests and /status)

    def configured(self) -> tuple[bool, str]:
        key, reason = self.key()
        return key is not None, reason

    def provider_token(self, key: ApnsKey, refresh: bool = False) -> str:
        import jwt

        identity = f"{key.key_id}.{key.team_id}"
        with self.lock:
            now = self.clock()
            cached = self._token
            if cached is not None and not refresh and cached[2] == identity and now - cached[1] < TOKEN_TTL_S:
                return cached[0]
            token = jwt.encode({"iss": key.team_id, "iat": int(now)}, key.pem, algorithm="ES256",
                               headers={"kid": key.key_id})
            self._token = (token, now, identity)
            self.signed += 1
            return token

    def push_call(self, payload: dict[str, Any]) -> PushResult:
        """Ring every registered device of this profile. OK when APNs accepted at least one."""
        key, reason = self._ready()
        if key is None:
            return PushResult(False, reason)
        devices = self.store.devices()
        if not devices:
            return PushResult(False, "no iPhone has registered for calls yet (open HermesVoice once)")
        body = json.dumps(payload, separators=(",", ":")).encode()
        failures: list[str] = []
        delivered = 0
        with self._client() as client:
            for device in devices:
                headers = {"apns-push-type": "voip", "apns-topic": f"{device.bundle_id}.voip",
                           "apns-priority": "10", "apns-expiration": "0"}
                ok, why, gone, _ = self._post(client, key, device.environment, device.voip_token, headers, body)
                if ok:
                    delivered += 1
                    continue
                if gone:
                    logger.info("hermes_voice: dropping a device APNs no longer knows (%s)", why)
                    self.store.remove(device.voip_token)
                failures.append(why)
        if delivered:
            return PushResult(True, "", delivered)
        return PushResult(False, "; ".join(dict.fromkeys(failures)) or "APNs refused the push")

    def push_alert(self, kind: str, payload: dict[str, Any], collapse_id: str = "") -> PushResult:
        """Show an alert on every phone of this profile that takes `kind` alerts. OK when APNs accepted at least
        one; not OK, with nothing sent, when no phone takes them."""
        key, reason = self._ready()
        if key is None:
            return PushResult(False, reason)
        devices = [device for device in self.store.devices() if device.wants(kind)]
        if not devices:
            return PushResult(False, f"no iPhone takes {kind} alerts")
        body = encode_alert(payload)
        if len(body) > MAX_ALERT_BYTES:
            return PushResult(False, f"the alert is larger than APNs allows ({len(body)} bytes)")
        headers = {"apns-push-type": "alert", "apns-priority": "10",
                   "apns-expiration": str(int(self.clock() + ALERT_TTL_S.get(kind, 900)))}
        if collapse_id and COLLAPSE_ID.fullmatch(collapse_id):
            headers["apns-collapse-id"] = collapse_id
        failures: list[str] = []
        delivered = 0
        transient = False
        with self._client() as client:
            for device in devices:
                token = str(device.alert_token)
                ok, why, gone, passing = self._post(client, key, device.environment, token,
                                                    {**headers, "apns-topic": device.bundle_id}, body)
                if ok:
                    delivered += 1
                    continue
                if gone:
                    logger.info("hermes_voice: forgetting an alert token APNs no longer knows (%s)", why)
                    self.store.forget_alert_token(token)
                transient = transient or passing
                failures.append(why)
        if delivered:
            return PushResult(True, "", delivered)
        return PushResult(False, "; ".join(dict.fromkeys(failures)) or "APNs refused the alert", retry=transient)

    def _ready(self) -> tuple[Optional[ApnsKey], str]:
        """The key, once APNs can be reached from here at all (else why not)."""
        key, reason = self.key()
        if key is None:
            return None, reason
        if self.transport is None and not h2_available():
            return None, ("the h2 package is missing, and APNs needs HTTP/2 (install the plugin with "
                          "`hermes plugins install`, or `pip install 'h2>=4,<5'` into Hermes' venv)")
        return key, ""

    def _client(self) -> httpx.Client:
        return httpx.Client(http2=self.transport is None, transport=self.transport, timeout=PUSH_TIMEOUT_S)

    def _post(self, client: httpx.Client, key: ApnsKey, environment: str, token: str, headers: dict[str, str],
              body: bytes) -> tuple[bool, str, bool, bool]:
        """One push to one device token: (ok, why not, whether APNs no longer knows the token, whether the failure
        is a passing one: unreachable, 429 or 5xx)."""
        url = f"{HOSTS[environment]}/3/device/{token}"
        for attempt in range(2):
            sent = {"authorization": f"bearer {self.provider_token(key, refresh=attempt > 0)}", **headers,
                    "content-type": "application/json"}
            try:
                response = client.post(url, content=body, headers=sent)
            except httpx.HTTPError as error:
                return False, f"APNs unreachable ({type(error).__name__})", False, True
            if response.status_code == 200:
                return True, "", False, False
            reason = _reason(response)
            if response.status_code == 403 and reason == "ExpiredProviderToken" and attempt == 0:
                continue  # sign a fresh token once and resend
            gone = response.status_code == 410 or reason in GONE_REASONS
            passing = response.status_code == 429 or response.status_code >= 500
            return False, f"APNs {response.status_code} {reason}".strip(), gone, passing
        return False, "APNs 403 ExpiredProviderToken", False, False


def _reason(response: httpx.Response) -> str:
    try:
        reason = response.json().get("reason")
    except (ValueError, AttributeError):
        reason = None
    return reason if isinstance(reason, str) and re.fullmatch(r"[A-Za-z]{1,64}", reason) else ""
