"""Where the user's phone is, when the agent asks: the ``get_location`` tool (toolset ``voice``).

The HermesVoice app shares its location only when the user turned "Share location with Hermes" on (off by
default), and only when it is asked. It says so with its registration (``POST /devices``, ``location: {"enabled":
bool, "background": bool}``, kept with the device; ``background``: iOS lets the app answer while it isn't on
screen). Asking:

- **On a call**: the phone's socket is up, so the hub sends ``location_request {id}`` on it and the phone answers
  ``location {id, latitude, longitude, accuracy_m, fixed_at, speed_mps?, course_deg?}`` or ``location {id, error}``
  (``off``, ``denied``, ``unavailable``, ``timeout``).
- **Otherwise**: a background push (``push.Apns.push_background``: ``{"aps": {"content-available": 1}, "hermes":
  {"kind": "location_request", "request_id", "profile"}}``) wakes the app, which posts the same answer to
  ``POST /api/plugins/hermes_voice/location`` with ``request_id`` and the tokens it registered with. iOS decides
  when a background push reaches the app, and whether it does: it throttles them, holds them back in Low Power
  Mode and drops them for an app the user force-quit. So a request can go unanswered; the tool then says so and
  gives the last fix it has, marked as old.

The tool waits ``timeout_s`` (20 s) for the answer. A fix younger than ``max_age_s`` (60 s by default) is given
without asking the phone again.

Privacy: the last fix lives in this process's memory only (``Locations.fix``), is dropped ``keep_s`` (30 minutes)
after it arrived, when the phone turns sharing off, and with a restart. It is never written to disk. Logs and
``rings.jsonl`` say that a request happened, from which conversation and how it ended, never where the phone is;
``GET /status`` says whether a phone shares, not where it is. A fix is taken only as the answer to a request this
process made (by its id), from a registered phone that shares.

Who may ask: the owner's own conversations, as for calls (``policy.allowed_sources``, the owner's direct
messages), and scheduled jobs unless ``location.allow_cron`` is off; never a subagent, a group chat or somebody
else's chat. ``requests_per_session`` (6 per 10 minutes) and ``requests_global`` (30 an hour) bound how often the
phone is asked, so a loop can't drain its battery.

The hub and its phones live in the dashboard process. From any other Hermes process the tool goes through the
hub's socket (``hubsock.py``, op ``location``), where the same checks run.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import threading
import time
import uuid
from collections import OrderedDict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable, Optional

from . import hermes
from . import hub as hub_module
from . import policy as call_policy
from . import push

logger = logging.getLogger("hermes_voice")

SETTINGS_CACHE_S = 5.0
POLL_S = 0.1
# How long a request's id stays good for a late answer (a background push iOS delivered late): the fix is kept as
# the last known one, for the next request.
LATE_ANSWER_S = 600.0
# A phone's clock may run ahead of the host's by this much; a fix dated later than that is refused.
CLOCK_AHEAD_S = 300.0
# A fix this coarse comes from a phone whose app has only approximate location (iOS "Precise Location" off).
COARSE_M = 1000.0
ERRORS = ("off", "denied", "unavailable", "timeout")
PUSH_KIND = "location_request"
COLLAPSE_ID = "hermes-location"

SETTINGS_PATH = "Settings → Location in the HermesVoice app"
SHARING_OFF = (
    "Location sharing is off on the user's iPhone, so nothing was asked and nothing was sent. If you need their "
    f"location, ask them to turn on \"Share location with Hermes\" ({SETTINGS_PATH}), or ask them where they are."
)
NO_PHONE = (
    "No iPhone is registered with this Hermes host, so there is nobody to ask. The user has to open the HermesVoice "
    "app while signed in to this host."
)
OFF_ON_HOST = (
    "Location requests are turned off on this Hermes host (plugins.entries.hermes_voice.settings.location.enabled "
    "is false). Ask the user where they are."
)
NOT_AVAILABLE = (
    "The user's location can't be asked for from here: no Hermes dashboard with the hermes_voice plugin is running "
    "on this host (the phone is reached through `hermes serve`). Ask the user where they are."
)
OLD_PLUGIN = (
    "The user's location can't be asked for from here: the Hermes dashboard on this host runs an older hermes_voice "
    "plugin without get_location. Restart the dashboard after updating the plugin."
)
NO_ANSWER_PUSH = (
    "The phone was asked with a background push and did not answer within {seconds:g} s. iOS delivers these "
    "pushes when it sees fit: it delays or drops them when the phone is in Low Power Mode, has no connection, was "
    "asked several times lately, or when the user force-quit the app. {background}"
)
NOT_IN_BACKGROUND = (
    "This iPhone lets the app use location only while the app is open (\"While Using the App\"), so it can't "
    f"answer from the background; the user can allow that under {SETTINGS_PATH}."
)
NO_ANSWER_CALL = (
    "The phone was asked over the voice call's connection and did not answer within {seconds:g} s (the connection "
    "may have dropped, or the app is an older version)."
)
PHONE_ERRORS = {
    "off": ("sharing_off", SHARING_OFF),
    "denied": ("unavailable", (
        "The phone answered that iOS doesn't let the app use its location right now: the permission is denied, "
        "or it is \"While Using the App\" and the app isn't on screen. The user can change it under "
        f"{SETTINGS_PATH}.")),
    "unavailable": ("unavailable", "The phone answered that it can't get a position fix right now (no GPS, Wi-Fi "
                                   "or cell position)."),
    "timeout": ("unavailable", "The phone answered that it could not get a position fix in time."),
}
STALE = (
    " last_known is the last position the phone sent, {age} ago: it is old, and the user may have moved since. "
    "Say so if you use it."
)


# ── settings ───────────────────────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class LocationSettings:
    """``plugins.entries.hermes_voice.settings.location``."""

    # False: the tool answers not_allowed for everyone on this host, and no phone is asked.
    enabled: bool = True
    # Scheduled jobs (and kanban tasks) may ask: the reason this exists is a scheduled "am I going to be late".
    allow_cron: bool = True
    # How long the tool waits for the phone's answer.
    timeout_s: float = 20.0
    # How long the last fix is kept (in memory) after it arrived.
    keep_s: float = 1800.0
    # A fix younger than this is given without asking the phone again (the tool's max_age_s overrides it).
    fresh_s: float = 60.0
    requests_per_session: int = 6
    session_window_s: float = 600.0
    requests_global: int = 30
    global_window_s: float = 3600.0

    @classmethod
    def from_plugin_settings(cls, own: Any) -> "LocationSettings":
        raw = own.get("location") if isinstance(own, dict) else None
        raw = raw if isinstance(raw, dict) else {}
        default = cls()
        return cls(
            enabled=_flag(raw.get("enabled"), default.enabled),
            allow_cron=_flag(raw.get("allow_cron"), default.allow_cron),
            timeout_s=_number(raw.get("timeout_s"), default.timeout_s, 5.0, 60.0),
            keep_s=_number(raw.get("keep_s"), default.keep_s, 60.0, 86400.0),
            fresh_s=_number(raw.get("fresh_s"), default.fresh_s, 0.0, 3600.0),
            requests_per_session=int(_number(raw.get("requests_per_session"), default.requests_per_session, 1, 1000)),
            session_window_s=_number(raw.get("session_window_s"), default.session_window_s, 10.0, 86400.0),
            requests_global=int(_number(raw.get("requests_global"), default.requests_global, 1, 10000)),
            global_window_s=_number(raw.get("global_window_s"), default.global_window_s, 10.0, 86400.0),
        )


def _flag(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _number(value: Any, default: float, low: float, high: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return min(high, max(low, number)) if math.isfinite(number) else default


_settings_cache: tuple[float, Optional[LocationSettings]] = (0.0, None)
_settings_lock = threading.Lock()


def current_settings() -> LocationSettings:
    """The host's location settings, re-read at most every few seconds."""
    global _settings_cache
    with _settings_lock:
        at, settings = _settings_cache
        if settings is None or time.monotonic() - at > SETTINGS_CACHE_S:
            settings = LocationSettings.from_plugin_settings(hermes.plugin_settings())
            _settings_cache = (time.monotonic(), settings)
        return settings


# ── who may ask ────────────────────────────────────────────────────────────────────────────────────────────


def allowed(origin: hermes.Origin, settings: LocationSettings, calls: Any) -> call_policy.Decision:
    """Whether this conversation may ask where the user is. `calls` is the call policy (``config.PolicyConfig``):
    the same sources and the same owner as for ringing the phone."""
    if not settings.enabled:
        return call_policy.Decision(False, "off_on_host", OFF_ON_HOST)
    if origin.is_subagent:
        return call_policy.Decision(False, "subagent", (
            "Only the main conversation can ask where the user is. Report back; it can ask."))
    if origin.is_cron:
        if settings.allow_cron:
            return call_policy.Decision(True)
        return call_policy.Decision(False, "cron", (
            "Scheduled jobs can't ask for the user's location on this host (settings.location.allow_cron is off)."))
    surface = call_policy._surface(origin)
    if call_policy.is_messaging(surface):
        if origin.chat_type != "dm":
            return call_policy.Decision(False, "group", "The user's location is never given out in a group chat.")
        if not (calls.allow_owner_dms and call_policy.is_owner(origin, calls.owner_ids)):
            return call_policy.Decision(False, "not_owner", (
                "Only the owner's own direct messages may ask where they are."))
    elif surface not in calls.allowed_sources:
        return call_policy.Decision(False, "source", (
            f"Conversations from {surface or 'this surface'} can't ask for the user's location."))
    return call_policy.Decision(True)


# ── fixes ──────────────────────────────────────────────────────────────────────────────────────────────────


class LocationError(ValueError):
    """An answer from the phone this plugin won't take (the message goes back to the phone, with `status` as the
    HTTP status: 400 for a bad body, 409 for an answer to a request nobody made)."""

    def __init__(self, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.status = status


@dataclass(frozen=True, repr=False)
class Fix:
    latitude: float
    longitude: float
    accuracy_m: float
    # When the phone got the fix (its clock, epoch seconds) and when it arrived here (this host's clock).
    fixed_at: float
    received_at: float
    # How it was asked for: "call" (the call's socket) or "push" (a background push).
    source: str
    speed_mps: Optional[float] = None
    course_deg: Optional[float] = None
    # The VoIP token of the phone that posted it ("" for one that came over a call's socket).
    device: str = ""

    def __repr__(self) -> str:  # never the coordinates: a Fix that ends up in a log line says nothing
        return f"Fix(source={self.source!r}, accuracy_m={self.accuracy_m:.0f})"

    def view(self, now: float, source: str = "") -> dict[str, Any]:
        """The fix as the tool gives it."""
        out: dict[str, Any] = {
            "latitude": round(self.latitude, 6), "longitude": round(self.longitude, 6),
            "accuracy_m": round(self.accuracy_m, 1), "age_s": round(max(0.0, now - self.fixed_at), 1),
            "fixed_at": _iso(self.fixed_at), "source": source or self.source,
        }
        if self.speed_mps is not None:
            out["speed_mps"] = round(self.speed_mps, 1)
        if self.course_deg is not None:
            out["course_deg"] = round(self.course_deg, 1)
        return out


def parse_fix(body: Any, now: float, source: str, device: str = "") -> Fix:
    """A fix as the phone sends it (in a ``location`` frame or to ``POST /location``), validated."""
    if not isinstance(body, dict):
        raise LocationError("body must be a JSON object")

    def number(name: str, low: float, high: float, required: bool = True) -> Optional[float]:
        value = body.get(name)
        if value is None and not required:
            return None
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise LocationError(f"{name} must be a number")
        if not low <= value <= high:
            raise LocationError(f"{name} must be between {low:g} and {high:g}")
        return float(value)

    latitude, longitude = number("latitude", -90.0, 90.0), number("longitude", -180.0, 180.0)
    accuracy = number("accuracy_m", 0.0, 1e7)
    fixed_at = body.get("fixed_at")
    if isinstance(fixed_at, (int, float)) and not isinstance(fixed_at, bool) and math.isfinite(fixed_at):
        fixed = float(fixed_at)
    else:
        parsed = hub_module._timestamp(fixed_at)
        if parsed is None:
            raise LocationError("fixed_at must be the fix's time (ISO 8601)")
        fixed = parsed
    if fixed > now + CLOCK_AHEAD_S:
        raise LocationError("fixed_at is in the future")
    assert latitude is not None and longitude is not None and accuracy is not None
    return Fix(latitude, longitude, accuracy, fixed, now, source,
               speed_mps=number("speed_mps", 0.0, 1e4, required=False),
               course_deg=number("course_deg", 0.0, 360.0, required=False), device=device)


def _iso(moment: float) -> str:
    return datetime.fromtimestamp(moment, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _ago(seconds: float) -> str:
    seconds = max(0.0, seconds)
    if seconds < 90:
        return f"{seconds:.0f} seconds"
    return f"{seconds / 60:.0f} minutes"


# ── requests ───────────────────────────────────────────────────────────────────────────────────────────────


class _Pending:
    """One request to the phone, waiting for its answer."""

    def __init__(self, request_id: str, via: str, issued_at: float) -> None:
        self.id = request_id
        self.via = via
        self.issued_at = issued_at
        self.done = threading.Event()
        self.fix: Optional[Fix] = None
        self.error = ""


class Locations:
    """The phones' sharing state, the requests in flight and the last fix (memory only)."""

    def __init__(
        self,
        hub: Optional[Callable[[], Any]] = None,
        settings: Callable[[], LocationSettings] = current_settings,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.hub = hub or hub_module.get_hub
        self.settings = settings
        self.clock = clock
        self.lock = threading.Lock()
        self.fix: Optional[Fix] = None
        self.expiry: Optional[threading.Timer] = None
        # Requests made lately, by id: only their answers are taken (a late one updates the last fix).
        self.requests: OrderedDict[str, _Pending] = OrderedDict()
        # When the phone was asked, and for which conversation (the rate limits).
        self.asked: deque[tuple[float, str]] = deque(maxlen=2000)

    # ── the tool ─────────────────────────────────────────────────────────────────────────────────────────

    def request(self, origin: hermes.Origin, max_age_s: Optional[float] = None,
                interrupted: Callable[[], bool] = hermes.is_interrupted) -> dict[str, Any]:
        """Where the phone is, for the conversation `origin` (a tool thread): the fix, or ``{status, note}``."""
        started = time.monotonic()
        settings = self.settings()
        hub = self.hub()

        def ended(result: dict[str, Any], outcome: str, via: str = "", **more: Any) -> dict[str, Any]:
            self._log(hub, origin, outcome, via, time.monotonic() - started, **more)
            return result

        decision = allowed(origin, settings, hub.settings().policy)
        if not decision.allowed:
            return ended(_status("not_allowed", decision.note), "not_allowed", reason=decision.reason)
        devices = self._devices(hub)
        if not devices:
            return ended(_status("no_phone", NO_PHONE), "no_phone")
        sharing = [device for device in devices if device.location]
        if not sharing:
            self.forget()
            return ended(_status("sharing_off", SHARING_OFF), "sharing_off")
        now = self.clock()
        fresh = settings.fresh_s if max_age_s is None else max(0.0, max_age_s)
        last = self.last()
        # (0 always asks, also when the phone's clock runs ahead of this host's.)
        if fresh > 0 and last is not None and now - last.fixed_at <= fresh:
            return ended({"status": "ok", **last.view(now, "cached"), "note": _fix_note(last, now, cached=True)},
                         "cached")
        limited = self._rate_limited(origin, settings, now)
        if limited:
            return ended(self._with_last(_status("rate_limited", limited), now), "rate_limited")
        pending = self._issue(origin, now)
        try:
            pending.via = "call" if self._ask_on_call(hub, pending.id) else "push"
            if pending.via == "push":
                failure = self._ask_by_push(hub, pending.id)
                if failure:
                    return ended(self._with_last(_status("push_failed", (
                        f"The phone couldn't be asked: {failure}. No call is connected, so a background push was "
                        "the only way to reach it.")), now), "push_failed", "push")
            deadline = time.monotonic() + settings.timeout_s
            while not pending.done.wait(POLL_S):
                if interrupted():
                    return ended(_status("interrupted", "Stopped before the phone answered."), "interrupted",
                                 pending.via)
                if time.monotonic() >= deadline:
                    break
        finally:
            pending.done.set()  # a later answer still updates the last fix, but nobody waits for it
        now = self.clock()
        if pending.fix is not None:
            fix = pending.fix
            return ended({"status": "ok", **fix.view(now), "note": _fix_note(fix, now)}, "ok", pending.via)
        if pending.error:
            status, note = PHONE_ERRORS.get(pending.error, PHONE_ERRORS["unavailable"])
            if pending.error == "timeout" and not any(device.location_background for device in sharing):
                note = f"{note} {NOT_IN_BACKGROUND}"
            return ended(self._with_last(_status(status, note), now), pending.error, pending.via)
        if pending.via == "call":
            note = NO_ANSWER_CALL.format(seconds=settings.timeout_s)
        else:
            background = "" if any(device.location_background for device in sharing) else NOT_IN_BACKGROUND
            note = NO_ANSWER_PUSH.format(seconds=settings.timeout_s, background=background).strip()
        return ended(self._with_last(_status("no_answer", note), now), "no_answer", pending.via)

    def _with_last(self, result: dict[str, Any], now: float) -> dict[str, Any]:
        """`result` with the last known fix, plainly marked as old, when there is one."""
        last = self.last()
        if last is None:
            return result
        view = last.view(now)
        return {**result, "note": result["note"] + STALE.format(age=_ago(view["age_s"])),
                "last_known": {**view, "stale": True}}

    def _issue(self, origin: hermes.Origin, now: float) -> _Pending:
        pending = _Pending(uuid.uuid4().hex[:16], "", now)
        with self.lock:
            self.asked.append((now, origin.session_id))
            self.requests[pending.id] = pending
            for request_id in [rid for rid, old in self.requests.items() if now - old.issued_at > LATE_ANSWER_S]:
                del self.requests[request_id]
            while len(self.requests) > 200:
                self.requests.popitem(last=False)
        return pending

    def _rate_limited(self, origin: hermes.Origin, settings: LocationSettings, now: float) -> str:
        """Why the phone isn't asked again right now, or ""."""
        with self.lock:
            mine = sum(1 for at, sid in self.asked
                       if sid == origin.session_id and now - at < settings.session_window_s)
            everyone = sum(1 for at, _ in self.asked if now - at < settings.global_window_s)
        if mine >= settings.requests_per_session:
            return (f"This conversation asked the phone for its location {mine} times in the last "
                    f"{_ago(settings.session_window_s)}; each request costs the phone battery. Wait before asking "
                    "again.")
        if everyone >= settings.requests_global:
            return (f"The phone was asked for its location {everyone} times in the last "
                    f"{_ago(settings.global_window_s)}; each request costs it battery. Wait before asking again.")
        return ""

    def _ask_on_call(self, hub: Any, request_id: str) -> bool:
        """Ask the phone on a call's socket. False without one (or when the frame couldn't be sent)."""
        loop = hub.loop
        links = [link for link in list(hub.links.values()) if not link.ended.is_set()]
        if loop is None or loop.is_closed() or not links:
            return False
        try:
            if asyncio.get_running_loop() is loop:
                return False  # on the loop itself there is no waiting for the send: the push asks instead
        except RuntimeError:
            pass  # a tool thread, as always

        async def send() -> bool:
            for link in links:
                try:
                    await hub_module._send_on(link, {"type": "location_request", "id": request_id})
                    return True
                except Exception:  # noqa: BLE001 - a link that went away: the push asks instead
                    continue
            return False

        try:
            return bool(asyncio.run_coroutine_threadsafe(send(), loop).result(hub_module.SEND_TIMEOUT + 1.0))
        except Exception:  # noqa: BLE001 - the loop stopped, or the send got stuck
            return False

    def _ask_by_push(self, hub: Any, request_id: str) -> str:
        """Ask by background push. "" when APNs accepted it for at least one phone, else why not."""
        sender = getattr(hub.pusher, "push_background", None)
        if not callable(sender):
            return "this host can't send background pushes"
        payload = {"hermes": {"kind": PUSH_KIND, "request_id": request_id, "profile": hermes.profile_name()}}
        try:
            result = sender(payload, collapse_id=COLLAPSE_ID)
        except Exception as error:  # noqa: BLE001 - the type only: a transport error can quote the request
            logger.warning("hermes_voice: the location push failed (%s)", type(error).__name__)
            return f"the push failed ({type(error).__name__})"
        return "" if getattr(result, "ok", False) else str(getattr(result, "reason", "") or "APNs refused the push")

    # ── the phone's answers ──────────────────────────────────────────────────────────────────────────────

    def answered(self, body: Any, source: str, device: Optional[push.Device] = None) -> None:
        """The phone's answer to a request: a fix, or ``error``. Raises LocationError for one that isn't taken."""
        if not isinstance(body, dict):
            raise LocationError("body must be a JSON object")
        request_id = str(body.get("request_id") or body.get("id") or "")
        now = self.clock()
        with self.lock:
            pending = self.requests.get(request_id)
            if pending is not None and now - pending.issued_at > LATE_ANSWER_S:
                pending = None
        if pending is None:
            raise LocationError("Nobody asked for this location (request_id is unknown or too old)", 409)
        error = body.get("error")
        if error is not None:
            code = error if isinstance(error, str) and error in ERRORS else "unavailable"
            if not pending.done.is_set():
                pending.error = code
                pending.done.set()
            return
        fix = parse_fix(body, now, source, device.voip_token if device is not None else "")
        self._keep(fix)
        if not pending.done.is_set():
            pending.fix = fix
            pending.done.set()

    def phone_frame(self, message: dict[str, Any]) -> None:
        """A ``location`` frame from the phone on a call (the hub's loop): never raises."""
        try:
            if not any(device.location for device in self._devices(self.hub())):
                return  # no phone shares: a fix nobody may have
            self.answered(message, "call")
        except LocationError as error:
            logger.info("hermes_voice: ignored a location answer from the call's phone (%s)", error)
        except Exception:  # noqa: BLE001 - the phone's socket must not suffer
            logger.debug("hermes_voice: a location answer failed", exc_info=True)

    def device_registered(self, device: push.Device) -> None:
        """A phone registered (again): one that doesn't share (any more) takes its fix with it, and whoever waits
        for an answer hears that sharing is off."""
        if device.location:
            return
        still = any(other.location for other in self._devices(self.hub()))
        with self.lock:
            fix = self.fix
            waiting = [] if still else [p for p in self.requests.values() if not p.done.is_set()]
        if fix is not None and (not still or fix.device in ("", device.voip_token)):
            self.forget()
        for pending in waiting:
            pending.error = "off"
            pending.done.set()

    # ── the last fix ─────────────────────────────────────────────────────────────────────────────────────

    def _keep(self, fix: Fix) -> None:
        keep_s = self.settings().keep_s
        with self.lock:
            if self.fix is not None and self.fix.fixed_at > fix.fixed_at:
                return  # a late answer with an older fix
            self.fix = fix
            if self.expiry is not None:
                self.expiry.cancel()
            timer = threading.Timer(keep_s, self._expire, args=(fix,))
            timer.daemon = True
            self.expiry = timer
            timer.start()

    def _expire(self, fix: Fix) -> None:
        with self.lock:
            if self.fix is fix:
                self.fix = None
                self.expiry = None

    def last(self) -> Optional[Fix]:
        """The last fix, unless it is older than ``keep_s`` (then it is dropped)."""
        keep_s = self.settings().keep_s
        with self.lock:
            fix = self.fix
            if fix is not None and self.clock() - fix.received_at > keep_s:
                self.fix = fix = None
            return fix

    def forget(self) -> None:
        with self.lock:
            self.fix = None
            if self.expiry is not None:
                self.expiry.cancel()
                self.expiry = None

    # ── status, logging ──────────────────────────────────────────────────────────────────────────────────

    def status(self) -> dict[str, Any]:
        """For ``GET /status``: whether a phone shares its location, never where it is."""
        devices = self._devices(self.hub())
        last = self.last()
        return {
            "enabled": self.settings().enabled,
            "sharing": any(device.location for device in devices),
            "phones": sum(1 for device in devices if device.location),
            "background": sum(1 for device in devices if device.location_background),
            "last_fix_age_s": None if last is None else round(max(0.0, self.clock() - last.fixed_at)),
        }

    def _devices(self, hub: Any) -> list[push.Device]:
        store = getattr(hub.pusher, "store", None)
        try:
            return list(store.devices()) if store is not None else []
        except Exception:  # noqa: BLE001
            logger.debug("hermes_voice: could not read the registered devices", exc_info=True)
            return []

    def _log(self, hub: Any, origin: hermes.Origin, outcome: str, via: str, took: float, **more: Any) -> None:
        """That a request happened, from which conversation and how it ended: never a coordinate."""
        source = "cron" if origin.is_cron else call_policy._surface(origin)
        logger.info("hermes_voice: location request from %s (%s): %s%s", origin.session_id, source or "?", outcome,
                    f" via {via}" if via else "")
        entry: dict[str, Any] = {"event": "location", "session_id": origin.session_id, "source": source,
                                 "result": outcome, "took_s": round(took, 1), **more}
        if via:
            entry["via"] = via
        try:
            hub.policy.log(entry)
        except Exception:  # noqa: BLE001 - the log must never fail the tool
            logger.debug("hermes_voice: ring log unavailable", exc_info=True)


def _status(status: str, note: str) -> dict[str, Any]:
    return {"status": status, "note": note}


def _fix_note(fix: Fix, now: float, cached: bool = False) -> str:
    parts = []
    age = max(0.0, now - fix.fixed_at)
    if cached:
        parts.append(f"The phone sent this fix {_ago(age)} ago; it was not asked again (max_age_s).")
    elif age > 120:
        parts.append(f"The phone answered with a fix from {_ago(age)} ago.")
    if fix.accuracy_m >= COARSE_M:
        parts.append("It is only approximate (accuracy_m is large): the app has no precise location on this iPhone.")
    return " ".join(parts) or "A fresh fix from the phone."


# ── one per process ────────────────────────────────────────────────────────────────────────────────────────

_locations: Optional[Locations] = None
_locations_lock = threading.Lock()


def locations() -> Locations:
    """The dashboard process's location state."""
    global _locations
    with _locations_lock:
        if _locations is None:
            _locations = Locations()
        return _locations


def install(instance: Optional[Locations]) -> None:
    """Replace the process's location state (tests)."""
    global _locations
    with _locations_lock:
        if _locations is not None and _locations is not instance:
            _locations.forget()
        _locations = instance


def find_device(hub: Any, voip_token: str = "", alert_token: str = "") -> Optional[push.Device]:
    """The registered phone with these tokens, found as a registration finds it: by its VoIP token, else by its
    alert token."""
    store = getattr(hub.pusher, "store", None)
    devices = store.devices() if store is not None else []
    return next((d for d in devices if voip_token and d.voip_token == voip_token), None) or next(
        (d for d in devices if alert_token and d.alert_token == alert_token), None)


# ── the tool ───────────────────────────────────────────────────────────────────────────────────────────────

GET_LOCATION: dict[str, Any] = {
    "name": "get_location",
    "description": (
        "Ask the user's iPhone (the HermesVoice app) where it is right now. Use it when you need the user's "
        "current position for something they asked for (\"will I make it to my meeting?\", directions, what is "
        "nearby): never out of curiosity, and don't repeat the coordinates back unless asked. Returns {status: "
        "\"ok\", latitude, longitude, accuracy_m, age_s, fixed_at, source} (accuracy_m: the radius the phone is "
        "within; age_s: how old the fix is; source: \"call\", \"push\" or \"cached\"), or {status, note} when "
        "there is no fix: \"sharing_off\" (the user has not turned on Share location with Hermes in the app's "
        "Settings: tell them that is where to turn it on, or ask where they are), \"no_phone\", \"no_answer\" (the "
        "phone did not answer in time; iOS may delay or drop the request while the app is in the background), "
        "\"unavailable\", \"push_failed\", \"rate_limited\", \"not_allowed\", \"not_available\". Such a result "
        "may carry last_known: the phone's last position with its age, which is old (stale: true), so say so "
        "if you use it. It waits up to about 20 seconds."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "max_age_s": {
                "type": "number",
                "description": (
                    "Accept a fix the phone sent at most this many seconds ago instead of asking it again "
                    "(default 60). 0 always asks the phone."
                ),
            },
        },
    },
}


def get_location(args: Any, session_id: Any = None, task_id: Any = None, **_: Any) -> str:
    args = args if isinstance(args, dict) else {}
    max_age = args.get("max_age_s")
    if isinstance(max_age, bool) or not isinstance(max_age, (int, float)) or not math.isfinite(max_age):
        max_age = None
    try:
        if not hub_module.routes_mounted():
            return _answer(_remote(session_id, max_age))
        origin = hermes.origin(session_id)
        if not origin.session_id:
            return _answer(_status("not_allowed", "This conversation can't ask for the user's location."))
        return _answer(locations().request(origin, max_age))
    except Exception:  # noqa: BLE001 - a tool must never raise
        logger.warning("hermes_voice: get_location failed", exc_info=True)
        return _answer({"status": "error", "note": "The location request failed. Ask the user where they are."})


def _answer(result: dict[str, Any]) -> str:
    return json.dumps(result, ensure_ascii=False)


# ── other Hermes processes (the hub's socket) ──────────────────────────────────────────────────────────────


def _remote(session_id: Any, max_age_s: Optional[float]) -> dict[str, Any]:
    """``get_location`` from a process that isn't the dashboard: through its hub socket (op ``location``)."""
    from . import remote

    origin = remote.origin_for(session_id)
    if not origin.session_id:
        return _status("not_allowed", "This conversation can't ask for the user's location.")
    params: dict[str, Any] = {"origin": remote.payload(origin)}
    if max_age_s is not None:
        params["max_age_s"] = max_age_s
    stopped = False

    def watch() -> list:
        """Tell the hub once when the user pressed Stop (a yield request is left for Hermes: the wait is short)."""
        nonlocal stopped
        if not stopped and hermes.is_interrupted():
            stopped = True
            return [{"interrupt": True}]
        return []

    try:
        with remote.Client.connect() as client:
            # The hub bounds the wait itself (timeout_s, at most 60 s); the rest is for the push to go out.
            return client.request("location", params, timeout=90.0, watch=watch)
    except remote.NotAvailable:
        return _status("not_available", NOT_AVAILABLE)
    except remote.RemoteError as error:
        if error.error == "unknown_op":
            return _status("not_available", OLD_PLUGIN)
        logger.warning("hermes_voice: get_location through the hub failed: %s", error.error)
    except (ConnectionError, OSError, TimeoutError) as error:
        logger.warning("hermes_voice: get_location through the hub failed: %s", type(error).__name__)
    return _status("not_available", "The Hermes dashboard stopped answering. Ask the user where they are.")


def from_socket(server: Any, message: dict[str, Any], signals: Any) -> dict[str, Any]:
    """The hub socket's ``location {origin, max_age_s?}`` (``hubsock.HubServer._dispatch``): the same request, for
    a conversation in another process. A process of another profile asks only when ``policy.allowed_profiles``
    names its profile, as for calls."""
    from . import hubsock

    origin = hubsock.origin_from(message.get("origin"))
    if server._foreign(origin, "async") is not None:
        return _status("not_allowed", (
            f"Conversations of the {origin.profile!r} profile can't ask for the location of the phone this "
            "dashboard serves (its policy.allowed_profiles doesn't list the profile)."))
    max_age = message.get("max_age_s")
    if isinstance(max_age, bool) or not isinstance(max_age, (int, float)) or not math.isfinite(max_age):
        max_age = None
    return locations().request(origin, max_age, interrupted=signals.interrupted)
