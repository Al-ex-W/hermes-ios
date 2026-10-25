"""VoIP pushes to the user's iPhone, straight to APNs (no relay).

APNs takes HTTP/2 only, so this needs the ``h2`` package (declared in plugin.yaml; Hermes' own venv lacks it);
``/status`` says whether it imports. The provider token is an ES256 JWT signed with the team's APNs auth key
(``HERMES_VOICE_APNS_KEY_PATH`` / ``_KEY_ID`` / ``_TEAM_ID``, read with ``get_secret``), reused for about 45 minutes
(Apple allows 20-60) and signed again once when APNs answers ``403 ExpiredProviderToken``.

Devices register with ``POST /api/plugins/hermes_voice/devices``; they are kept per profile in
``<HERMES_HOME>/hermes-voice/devices.json``. APNs' ``410 Unregistered`` / ``BadDeviceToken`` drop a device.
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


def h2_available() -> bool:
    try:
        import h2  # noqa: F401
    except ImportError:
        return False
    return True


# ── devices ────────────────────────────────────────────────────────────────────────────────────────────────


@dataclass
class Device:
    voip_token: str
    environment: str
    bundle_id: str
    alert_token: Optional[str] = None
    registered_at: float = field(default_factory=time.time)


class DeviceError(ValueError):
    pass


def parse_device(body: Any) -> Device:
    """A ``POST /devices`` body, validated (tokens are hex, the bundle id is a plain reverse-DNS name)."""
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
    return Device(voip.lower(), environment, bundle, alert.lower() if alert else None)


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
            try:
                devices.append(Device(**{k: item[k] for k in item if k in Device.__dataclass_fields__}))
            except TypeError:
                continue
        return devices

    def _write(self, devices: list[Device]) -> None:
        path = self._path()
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".tmp")
        temp.write_text(json.dumps([asdict(d) for d in devices], indent=2), encoding="utf-8")
        os.chmod(temp, 0o600)
        temp.replace(path)

    def register(self, device: Device) -> None:
        with self.lock:
            others = [d for d in self._read() if d.voip_token != device.voip_token]
            self._write([device, *others][:MAX_DEVICES])

    def remove(self, voip_token: str) -> None:
        with self.lock:
            devices = self._read()
            kept = [d for d in devices if d.voip_token != voip_token]
            if len(kept) != len(devices):
                self._write(kept)


# ── APNs ───────────────────────────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class PushResult:
    ok: bool
    reason: str = ""
    delivered: int = 0


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
        key, reason = self.key()
        if key is None:
            return PushResult(False, reason)
        if self.transport is None and not h2_available():
            return PushResult(False, "the h2 package is missing, and APNs needs HTTP/2 (install the plugin with "
                                     "`hermes plugins install`, or `pip install 'h2>=4,<5'` into Hermes' venv)")
        devices = self.store.devices()
        if not devices:
            return PushResult(False, "no iPhone has registered for calls yet (open HermesVoice once)")
        failures: list[str] = []
        delivered = 0
        with httpx.Client(http2=self.transport is None, transport=self.transport, timeout=PUSH_TIMEOUT_S) as client:
            for device in devices:
                ok, why = self._send(client, key, device, payload)
                if ok:
                    delivered += 1
                else:
                    failures.append(why)
        if delivered:
            return PushResult(True, "", delivered)
        return PushResult(False, "; ".join(dict.fromkeys(failures)) or "APNs refused the push")

    def _send(self, client: httpx.Client, key: ApnsKey, device: Device, payload: dict) -> tuple[bool, str]:
        url = f"{HOSTS[device.environment]}/3/device/{device.voip_token}"
        body = json.dumps(payload, separators=(",", ":")).encode()
        for attempt in range(2):
            headers = {
                "authorization": f"bearer {self.provider_token(key, refresh=attempt > 0)}",
                "apns-push-type": "voip",
                "apns-topic": f"{device.bundle_id}.voip",
                "apns-priority": "10",
                "apns-expiration": "0",
                "content-type": "application/json",
            }
            try:
                response = client.post(url, content=body, headers=headers)
            except httpx.HTTPError as error:
                return False, f"APNs unreachable ({type(error).__name__})"
            if response.status_code == 200:
                return True, ""
            reason = _reason(response)
            if response.status_code == 403 and reason == "ExpiredProviderToken" and attempt == 0:
                continue  # sign a fresh token once and resend
            if response.status_code == 410 or reason in GONE_REASONS:
                logger.info("hermes_voice: dropping a device APNs no longer knows (%s)", reason)
                self.store.remove(device.voip_token)
            return False, f"APNs {response.status_code} {reason}".strip()
        return False, "APNs 403 ExpiredProviderToken"


def _reason(response: httpx.Response) -> str:
    try:
        reason = response.json().get("reason")
    except (ValueError, AttributeError):
        reason = None
    return reason if isinstance(reason, str) and re.fullmatch(r"[A-Za-z]{1,64}", reason) else ""
