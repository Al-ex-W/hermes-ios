"""hermes_voice routes on the Hermes dashboard, mounted at /api/plugins/hermes_voice/.

- ``WS /phone?ticket=<single-use ws-ticket>``: the phone's call link (protocol in ``hub.py``).
- ``POST /devices {voip_token, alert_token?, environment, bundle_id}``: where to send VoIP pushes.
- ``POST /scribe-token``: a single-use ElevenLabs Scribe token for on-phone speech recognition; the API key stays
  on this host.
- ``GET /status``: what works here (TTS, h2, APNs, Scribe) and the call in progress.

HTTP routes sit behind the dashboard's own auth middleware. WebSocket upgrades skip that middleware, so the socket
checks the dashboard's WebSocket auth itself (the check ``/api/audio/speak-stream`` uses), failing closed.

The web server imports this file on its own, by path, at startup. It reaches the call hub through ``loader.py``,
which keeps one copy of the plugin's core per process, shared with the tools the plugin manager registered.
"""

from __future__ import annotations

import importlib.util
import inspect
import json
import logging
import sys
import threading
import time
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional

import httpx
from fastapi import APIRouter, Request, WebSocket
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

logger = logging.getLogger("hermes_voice")

PLUGIN_DIR = Path(__file__).resolve().parent.parent
MAX_BODY_BYTES = 4096
SCRIBE_TOKEN_TTL = timedelta(minutes=15)
SCRIBE_TIMEOUT_S = 15.0
# A phone mints a Scribe token per call (and on reconnects): allow bursts, stop a looping client.
SCRIBE_LIMIT, SCRIBE_WINDOW_S = 20, 60.0
DEVICE_LIMIT, DEVICE_WINDOW_S = 20, 60.0
# Tests swap in an httpx.MockTransport for ElevenLabs.
SCRIBE_TRANSPORT: Optional[httpx.AsyncBaseTransport] = None


def _loader() -> Any:
    """``loader.py`` beside this folder (by path: this file is not imported as part of the plugin package)."""
    module = sys.modules.get("hermes_voice_loader")
    if module is None:
        spec = importlib.util.spec_from_file_location("hermes_voice_loader", PLUGIN_DIR / "loader.py")
        if spec is None or spec.loader is None:
            raise ImportError("hermes_voice: loader.py is missing; reinstall the plugin")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sys.modules["hermes_voice_loader"] = module
    return module


def _core(name: str) -> Any:
    return _loader().module(name, PLUGIN_DIR)


hub_module = _core("hub")
hermes = _core("hermes")
push = _core("push")
hub_module.mark_routes_mounted()

router = APIRouter()


class _Limiter:
    def __init__(self, limit: int, window: float) -> None:
        self.limit, self.window = limit, window
        self.hits: deque[float] = deque()
        self.lock = threading.Lock()

    def allow(self) -> bool:
        now = time.monotonic()
        with self.lock:
            while self.hits and now - self.hits[0] > self.window:
                self.hits.popleft()
            if len(self.hits) >= self.limit:
                return False
            self.hits.append(now)
            return True


_scribe_limiter = _Limiter(SCRIBE_LIMIT, SCRIBE_WINDOW_S)
_device_limiter = _Limiter(DEVICE_LIMIT, DEVICE_WINDOW_S)


def _hub() -> Any:
    hub = hub_module.get_hub()
    hub.capture_loop()
    return hub


def _error(status: int, message: str) -> JSONResponse:
    # `detail`, like the dashboard's own HTTPException bodies (the phone shows it).
    return JSONResponse({"detail": message}, status_code=status, headers={"Cache-Control": "no-store"})


async def authorize(ws: WebSocket) -> Optional[int]:
    """None when the dashboard's WebSocket auth admits the upgrade, else the close code: 4401 for every refusal
    (a bad or reused ticket, or a Host / Origin / peer the dashboard refuses), as the phone protocol has it; the
    phone mints one more ticket, then gives up. Fails closed when this Hermes has no such check."""
    try:
        from hermes_cli.web_server_chat import _ws_auth_ok, _ws_request_is_allowed
    except ImportError:
        logger.warning("hermes_voice: phone socket refused: this Hermes has no dashboard WebSocket auth")
        return 4401
    for check, what in ((_ws_auth_ok, "credential"), (_ws_request_is_allowed, "host / origin / peer")):
        try:
            result = check(ws)
            # An async check would otherwise be a coroutine, which is truthy.
            if inspect.isawaitable(result):
                result = await result
        except Exception as error:  # noqa: BLE001 - a broken check refuses
            logger.warning("hermes_voice: phone socket auth check failed: %s", type(error).__name__)
            return 4401
        if not result:
            logger.info("hermes_voice: phone socket refused: the dashboard rejected its %s", what)
            return 4401
    return None


@router.websocket("/phone")
async def phone(ws: WebSocket) -> None:
    await _hub().serve_phone(ws, authorize)


@router.post("/devices")
async def devices(request: Request) -> Any:
    hub = _hub()
    if not _device_limiter.allow():
        return _error(429, "Too many device registrations; try again shortly")
    raw = await request.body()
    if len(raw) > MAX_BODY_BYTES:
        return _error(413, "Body too large")
    try:
        device = push.parse_device(json.loads(raw or b"null"))
    except (ValueError, UnicodeDecodeError) as error:
        return _error(400, str(error) if isinstance(error, push.DeviceError) else "Body must be JSON")
    store = getattr(hub.pusher, "store", None) or push.DeviceStore()
    try:
        await run_in_threadpool(store.register, device)
    except OSError:
        logger.warning("hermes_voice: could not save the device", exc_info=True)
        return _error(500, "Could not save the device")
    logger.info("hermes_voice: registered a %s device for %s", device.environment, device.bundle_id)
    return {"ok": True}


@router.post("/scribe-token")
async def scribe_token() -> Any:
    hub = _hub()
    if not _scribe_limiter.allow():
        return _error(429, "Too many token requests; try again shortly")
    key = hermes.get_secret("ELEVENLABS_API_KEY")
    if not key:
        return _error(503, "ELEVENLABS_API_KEY is not set on the Hermes host")
    url = f"{hub.settings().elevenlabs_base_url}/v1/single-use-token/realtime_scribe"
    try:
        async with httpx.AsyncClient(timeout=SCRIBE_TIMEOUT_S, transport=SCRIBE_TRANSPORT) as client:
            response = await client.post(url, headers={"xi-api-key": key})
    except httpx.HTTPError as error:
        logger.warning("hermes_voice: ElevenLabs unreachable for a Scribe token: %s", type(error).__name__)
        return _error(502, "ElevenLabs is unreachable")
    if response.status_code >= 400:
        logger.warning("hermes_voice: ElevenLabs refused a Scribe token: HTTP %s", response.status_code)
        return _error(502, f"ElevenLabs returned HTTP {response.status_code}")
    try:
        token = response.json().get("token")
    except (ValueError, AttributeError):
        token = None
    if not isinstance(token, str) or not token or len(token) > 4096:
        return _error(502, "ElevenLabs returned no token")
    expires = datetime.now(timezone.utc) + SCRIBE_TOKEN_TTL
    return JSONResponse({"token": token, "expires_at": expires.isoformat(timespec="seconds")},
                        headers={"Cache-Control": "no-store"})


@router.get("/status")
async def status() -> Any:
    hub = _hub()
    return await run_in_threadpool(hub.status)
