"""The agent notifies the user: the ``notify_user`` tool (toolset ``voice``).

A notification the agent sends of its own, at any time ("Your train is 10 minutes late"), from any of the owner's
conversations and from scheduled jobs. It is an ordinary alert push (``notify.py``'s payload, sent with
``push.Apns.push_alert``), the fourth alert kind ``message``:

``{"aps": {"alert": {title, body}, "category": "HERMES_MESSAGE", "thread-id": <stored session id>, "sound":
"default"}, "hermes": {"kind": "message", "session_id": <stored session id>, "profile"}}``. ``urgency``:
``normal`` (sound), ``time_sensitive`` (sound and ``"interruption-level": "time-sensitive"``: it gets through a Focus
the user allows time-sensitive notifications in; the app has the Time Sensitive Notifications entitlement) or
``quiet`` (``"interruption-level": "passive"``, no sound). A tap opens the conversation; the app's Reply action
sends the user's answer into it.

- **Text.** Title (at most ``TITLE_CHARS``) and body (at most ``BODY_CHARS``), whitespace collapsed, passed through
  Hermes' secret redaction as every alert is (where redaction can't run, the phone gets the generic line). With
  ``alerts.previews: false`` no text goes through APNs: the phone shows "Hermes" / "Hermes sent you a message." and
  the user reads it in the conversation, where the tool call (with its arguments) is stored anyway. The result says
  when the text was cut.
- **Where it goes.** Every phone of the profile that takes ``message`` alerts (``POST /devices {"alerts":
  {"message": false}}`` turns them off on a phone; ``settings.alerts.message: false`` or ``alerts.enabled: false``
  on the host).
- **Quiet.** During ``policy.quiet_hours`` it goes passive whatever its urgency (the user's own setting wins over
  the agent's idea of urgent). Past the alert budget (20 sounding alerts an hour, shared with the other kinds) a
  ``normal`` one goes passive too; a ``time_sensitive`` one still sounds (the tool's own rate limits bound it).
- **Who may.** The owner's own conversations, as for calls and ``get_location`` (``policy.owner_conversation``), and
  scheduled jobs unless ``notify_user.allow_cron`` is off; never a subagent, a group chat or somebody else's chat.
  ``per_session`` (5 per ``session_window_s``, 10 minutes) and ``per_host`` (30 per ``host_window_s``, an hour)
  bound how often.
- **Retries.** APNs unreachable, 429 or 5xx: tried again after 1, 2, 4 and 8 s while the tool waits.
- **Log.** ``rings.jsonl`` gets ``{"event": "notify", "session_id", "source", "result", "reason"?, "urgency",
  "level", "policy"?, "phones"?, "attempts"?, "cut"?, "previews"?, "detail"?}``: never the text.

The hub and its phones live in the dashboard process. From any other Hermes process the tool goes through the hub's
socket (``hubsock.py``, op ``notify``), where the same checks run; without a dashboard it answers
``not_available``.
"""

from __future__ import annotations

import json
import logging
import math
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass
from typing import Any, Callable, Optional

from . import hermes
from . import hub as hub_module
from . import notify
from . import policy as call_policy

logger = logging.getLogger("hermes_voice")

KIND = "message"
URGENCIES = ("normal", "time_sensitive", "quiet")
TITLE_CHARS = notify.TITLE_CHARS
BODY_CHARS = 500
# What goes over the hub socket at most (the hub cuts to the limits above and says so).
WIRE_CHARS = 2000
SETTINGS_CACHE_S = 5.0
RETRY_STEP_S = 0.1

SETTINGS_PATH = "Settings → Notifications in the HermesVoice app"
IN_CONVERSATION = ("The text is also in this conversation (this tool call), so don't repeat it in your reply unless "
                   "that helps.")
NOT_AVAILABLE = (
    "Nothing was sent: no Hermes dashboard with the hermes_voice plugin is running on this host (the phone is "
    "reached through `hermes serve`). Tell the user in your reply instead."
)
OLD_PLUGIN = (
    "Nothing was sent: the Hermes dashboard on this host runs an older hermes_voice plugin without notify_user. "
    "Restart the dashboard after updating the plugin, and tell the user in your reply meanwhile."
)
NOTES = {
    "subagent": "Only the main conversation can notify the user. Report back; it can.",
    "cron": ("Scheduled jobs can't notify the user on this host (settings.notify_user.allow_cron is off). Put it "
             "in the job's output instead."),
    "group": "Notifications are never sent from a group chat. Reply in the chat instead.",
    "not_owner": "Only the owner's own direct messages may notify them. Reply in the chat instead.",
    "no_phone": ("No iPhone is registered with this Hermes host, so nothing was sent. The user has to open the "
                 "HermesVoice app while signed in to this host. Tell them in your reply instead."),
    "no_alert_token": ("The user's iPhone has no notification token on this host (notifications are off for the "
                       "HermesVoice app in iOS Settings, or it hasn't registered since), so nothing was sent. Tell "
                       "them in your reply instead."),
    "off_on_phone": (f"The user turned off \"Messages from Hermes\" ({SETTINGS_PATH}), so nothing was sent. Put it "
                     "in your reply instead."),
    "off_on_host": ("Message notifications are turned off on this Hermes host "
                    "(plugins.entries.hermes_voice.settings.alerts), so nothing was sent. Put it in your reply "
                    "instead."),
    "empty": "Nothing was sent: body is empty. Pass the message in body.",
    "interrupted": "Stopped before the notification went out; nothing was sent.",
}
# APNs' answers, in words (notify.test_failure's codes).
APNS_WORDS = {
    "wrong_environment": "the host's APNs key isn't valid for the environment the app registered",
    "bad_token": ("APNs no longer knows the phone's notification token (the app was reinstalled, or registered for "
                  "the other environment); the host dropped it until the user opens the app again"),
    "wrong_topic": "APNs refused the app's bundle id: the host's APNs key belongs to another app or team",
    "bad_key": "APNs refused the host's key (check HERMES_VOICE_APNS_KEY_ID, _TEAM_ID and the .p8 file)",
    "apns_unreachable": "the host couldn't reach APNs",
    "no_alert_token": "no phone takes message notifications",
}


# ── settings ───────────────────────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class MessageSettings:
    """``plugins.entries.hermes_voice.settings.notify_user`` (the host switch for the kind is
    ``settings.alerts.message``, with the other alert kinds)."""

    # Scheduled jobs (and kanban tasks) may notify: a job that checks something and tells the user is the point.
    allow_cron: bool = True
    per_session: int = 5
    session_window_s: float = 600.0
    per_host: int = 30
    host_window_s: float = 3600.0

    @classmethod
    def from_plugin_settings(cls, own: Any) -> "MessageSettings":
        raw = own.get("notify_user") if isinstance(own, dict) else None
        raw = raw if isinstance(raw, dict) else {}
        default = cls()
        return cls(
            allow_cron=_flag(raw.get("allow_cron"), default.allow_cron),
            per_session=int(_number(raw.get("per_session"), default.per_session, 1, 1000)),
            session_window_s=_number(raw.get("session_window_s"), default.session_window_s, 10.0, 86400.0),
            per_host=int(_number(raw.get("per_host"), default.per_host, 1, 10000)),
            host_window_s=_number(raw.get("host_window_s"), default.host_window_s, 10.0, 86400.0),
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


_settings_cache: tuple[float, Optional[MessageSettings]] = (0.0, None)
_settings_lock = threading.Lock()


def current_settings() -> MessageSettings:
    """The host's notify_user settings, re-read at most every few seconds."""
    global _settings_cache
    with _settings_lock:
        at, settings = _settings_cache
        if settings is None or time.monotonic() - at > SETTINGS_CACHE_S:
            settings = MessageSettings.from_plugin_settings(hermes.plugin_settings())
            _settings_cache = (time.monotonic(), settings)
        return settings


# ── who may ────────────────────────────────────────────────────────────────────────────────────────────────


def allowed(origin: hermes.Origin, settings: MessageSettings, calls: Any) -> call_policy.Decision:
    """Whether this conversation may notify the user (the call policy's sources and owner; see the module doc)."""
    reason = call_policy.owner_conversation(origin, calls, settings.allow_cron)
    if not reason:
        return call_policy.Decision(True)
    if reason == "source":
        surface = call_policy._surface(origin) or "this surface"
        return call_policy.Decision(False, reason, f"Conversations from {surface} can't notify the user. Reply in "
                                                   "text instead.")
    return call_policy.Decision(False, reason, NOTES[reason])


def urgency_of(value: Any) -> tuple[str, str]:
    """The urgency asked for, and a note when it wasn't one of URGENCIES (then it is "normal")."""
    if value is None or value == "":
        return "normal", ""
    word = str(value).strip().lower().replace("-", "_").replace(" ", "_")
    if word in URGENCIES:
        return word, ""
    return "normal", f"urgency {str(value)[:40]!r} isn't one of normal, time_sensitive, quiet: it went as normal."


def _line(text: Any) -> str:
    return " ".join(str(text or "").split()) if isinstance(text, (str, int, float)) else ""


# ── sending ────────────────────────────────────────────────────────────────────────────────────────────────


class Messages:
    """Sends the agent's notifications for the dashboard process, with their rate limits (memory only)."""

    def __init__(
        self,
        hub: Optional[Callable[[], Any]] = None,
        settings: Callable[[], MessageSettings] = current_settings,
        alert_settings: Callable[[], notify.AlertSettings] = notify.current_settings,
        alerts: Callable[[], notify.Alerts] = notify.alerts,
        quiet_hours: Callable[[], bool] = notify._quiet_hours_now,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.hub = hub or hub_module.get_hub
        self.settings = settings
        self.alert_settings = alert_settings
        self.alerts = alerts
        self.quiet_hours = quiet_hours
        self.clock = clock
        self.sleep = sleep
        self.lock = threading.Lock()
        # When a notification went to APNs, and for which conversation (the rate limits).
        self.sent_at: deque[tuple[float, str]] = deque(maxlen=2000)
        self.sent = 0

    def send(self, origin: hermes.Origin, title: Any, body: Any, urgency: Any = None,
             interrupted: Callable[[], bool] = hermes.is_interrupted) -> dict[str, Any]:
        """Notify the user for the conversation `origin` (a tool thread): ``{status, note}`` (see the tool)."""
        hub = self.hub()
        level, unknown = urgency_of(urgency)
        log: dict[str, Any] = {"urgency": level}

        def refused(reason: str, note: str, **more: Any) -> dict[str, Any]:
            self._log(hub, origin, "not_sent", reason=reason, **log, **more)
            return {"status": "not_sent", "reason": reason, "note": note}

        decision = allowed(origin, self.settings(), hub.settings().policy)
        if not decision.allowed:
            return refused("not_allowed", decision.note, policy=decision.reason)
        title_line, body_line = _line(title), _line(body)
        if not body_line:
            if not title_line:
                return refused("empty", NOTES["empty"])
            title_line, body_line = "", title_line  # only a title: it is the message
        alert_settings = self.alert_settings()
        if not alert_settings.enabled or KIND not in alert_settings.kinds:
            return refused("off_on_host", NOTES["off_on_host"])
        pusher = hub.pusher
        ready = getattr(pusher, "ready", None)
        usable, why = ready() if callable(ready) else (False, "it has no alert sender")
        if not usable or not callable(getattr(pusher, "push_alert", None)):
            return refused("apns_not_configured", f"This Hermes host can't send notifications: {why or 'no sender'}. "
                                                  "Nothing was sent; tell the user in your reply instead.")
        devices = self._devices(hub)
        if not devices:
            return refused("no_phone", NOTES["no_phone"])
        if not any(device.alert_token for device in devices):
            return refused("no_alert_token", NOTES["no_alert_token"])
        phones = [device for device in devices if device.wants(KIND)]
        if not phones:
            return refused("off_on_phone", NOTES["off_on_phone"])
        limited = self._rate_limited(origin)
        if limited:
            return refused("rate_limited", limited)

        # How it sounds: the user's quiet hours win over any urgency; the budget only over a normal one.
        quiet_reason = ""
        if level == "quiet":
            passive = True
        elif self._quiet_hours():
            passive, quiet_reason = True, "quiet_hours"
        elif level == "normal" and self._over_budget(origin.session_id):
            passive, quiet_reason = True, "budget"
        else:
            passive = False
        payload, cut, generic = self._payload(origin, title_line, body_line, alert_settings.previews, passive,
                                              level == "time_sensitive")
        log["level"] = "passive" if passive else "time-sensitive" if level == "time_sensitive" else "sound"
        if cut:
            log["cut"] = True
        if not alert_settings.previews:
            log["previews"] = False
        with self.lock:
            self.sent_at.append((self.clock(), origin.session_id))
        collapse = f"msg-{uuid.uuid4().hex[:16]}"
        result, attempts = None, 0
        while True:
            attempts += 1
            try:
                result = pusher.push_alert(KIND, payload, collapse_id=collapse)
            except Exception as error:  # noqa: BLE001 - the type only (a message could carry a token)
                logger.warning("hermes_voice: a message alert failed (%s)", type(error).__name__)
                result = None
            if result is not None and getattr(result, "ok", False):
                break
            passing = result is None or getattr(result, "retry", False) is True
            if not passing or attempts > len(notify.RETRY_DELAYS):
                break
            if not self._wait(notify.RETRY_DELAYS[attempts - 1], interrupted):
                return refused("interrupted", NOTES["interrupted"], attempts=attempts)
        if attempts > 1:
            log["attempts"] = attempts
        if result is None or not getattr(result, "ok", False):
            reason = str(getattr(result, "reason", "") or "the push failed")
            code, _ = notify.test_failure(reason, phones[0].environment)
            words = APNS_WORDS.get(code, "APNs refused it")
            status = "apns_unreachable" if code == "apns_unreachable" else "apns_refused"
            if reason.startswith("no iPhone takes"):
                return refused("off_on_phone", NOTES["off_on_phone"])
            return refused(status, f"Nothing was sent: {words} ({reason}). Tell the user in your reply instead.",
                           detail=reason[:200])
        delivered = int(getattr(result, "delivered", 0) or 0) or len(phones)
        log["phones"] = delivered
        with self.lock:
            self.sent += 1
        if not passive:
            self._sounded(origin.session_id)
        parts = []
        if quiet_reason == "quiet_hours":
            parts.append("Sent to the user's iPhone, but silently (no sound, no banner on a locked screen): it is "
                         "the user's quiet hours.")
        elif quiet_reason == "budget":
            parts.append("Sent to the user's iPhone, but silently (no sound): many notifications went to the phone "
                         "in the last hour (the alert budget). Use time_sensitive only if it really can't wait.")
        elif level == "quiet":
            parts.append("Sent to the user's iPhone silently, as asked (no sound).")
        elif level == "time_sensitive":
            parts.append("Sent to the user's iPhone with sound, as time-sensitive (it gets through a Focus that "
                         "allows those).")
        else:
            parts.append("Sent to the user's iPhone, with sound.")
        if delivered > 1:
            parts.append(f"It went to {delivered} iPhones.")
        if unknown:
            parts.append(unknown[0].upper() + unknown[1:])
        parts.extend(cut)
        if generic:
            parts.append(generic)
        parts.append(IN_CONVERSATION)
        status = "quiet" if quiet_reason else "sent"
        self._log(hub, origin, status, **({"reason": quiet_reason} if quiet_reason else {}), **log)
        out: dict[str, Any] = {"status": status, "note": " ".join(parts)}
        if quiet_reason:
            out["reason"] = quiet_reason
        return out

    def _payload(self, origin: hermes.Origin, title: str, body: str, previews: bool, passive: bool,
                 time_sensitive: bool) -> tuple[dict[str, Any], list[str], str]:
        """The alert, the notes on what was cut, and the note when the phone shows the generic line."""
        cut: list[str] = []
        generic = ""
        if previews:
            safe_title = notify.safe(title) if title else ""
            safe_body = notify.safe(body)
            if safe_title is None or safe_body is None:
                previews = False
                generic = ("Hermes' secret redaction isn't available on this host, so the phone showed only "
                           "\"Hermes sent you a message.\"; the user sees the text when they open this conversation.")
            else:
                title, body = safe_title, safe_body
        else:
            generic = ("This host keeps notification previews off (settings.alerts.previews), so the phone showed "
                       "only \"Hermes sent you a message.\"; the user sees the text when they open this "
                       "conversation.")
        if not previews:
            title, body = notify.DEFAULT_TITLE, notify.GENERIC[KIND]
        payload = notify.build(KIND, title=title or notify.DEFAULT_TITLE, body=body, session_id=origin.session_id,
                               profile=origin.profile or hermes.profile_name(), quiet=passive,
                               time_sensitive=time_sensitive and not passive, body_chars=BODY_CHARS)
        if previews:
            shown = payload["aps"]["alert"]
            if title and shown["title"] != title:
                cut.append(f"The title was cut to {len(shown['title'])} characters (at most {TITLE_CHARS}).")
            if shown["body"] != body:
                cut.append(f"The body was cut to {len(shown['body'])} characters (at most {BODY_CHARS}, and a "
                           "notification must fit APNs' 4 KB); the whole text is in this conversation.")
        return payload, cut, generic

    def _wait(self, delay: float, interrupted: Callable[[], bool]) -> bool:
        """Wait before a retry; False when the user pressed Stop meanwhile."""
        waited = 0.0
        while waited < delay:
            if interrupted():
                return False
            step = min(RETRY_STEP_S, delay - waited)
            self.sleep(step)
            waited += step
        return not interrupted()

    def _rate_limited(self, origin: hermes.Origin) -> str:
        settings = self.settings()
        now = self.clock()
        with self.lock:
            mine = sum(1 for at, sid in self.sent_at
                       if sid == origin.session_id and now - at < settings.session_window_s)
            everyone = sum(1 for at, _ in self.sent_at if now - at < settings.host_window_s)
        if mine >= settings.per_session:
            return (f"Nothing was sent: this conversation already sent {_count(mine)} in the last "
                    f"{_minutes(settings.session_window_s)}. Put it in your reply, or wait.")
        if everyone >= settings.per_host:
            return (f"Nothing was sent: {_count(everyone)} went to the user in the last "
                    f"{_minutes(settings.host_window_s)}. Put it in your reply, or wait.")
        return ""

    def _quiet_hours(self) -> bool:
        try:
            return bool(self.quiet_hours())
        except Exception:  # noqa: BLE001 - unreadable settings: not quiet
            return False

    def _over_budget(self, session_id: str) -> bool:
        try:
            return self.alerts().over_budget(KIND, session_id)
        except Exception:  # noqa: BLE001
            return False

    def _sounded(self, session_id: str) -> None:
        try:
            self.alerts()._sounded(KIND, session_id)
        except Exception:  # noqa: BLE001
            logger.debug("hermes_voice: could not count a message in the alert budget", exc_info=True)

    def _devices(self, hub: Any) -> list[Any]:
        store = getattr(hub.pusher, "store", None)
        try:
            return list(store.devices()) if store is not None else []
        except Exception:  # noqa: BLE001
            logger.debug("hermes_voice: could not read the registered devices", exc_info=True)
            return []

    # ── status, logging ──────────────────────────────────────────────────────────────────────────────────

    def status(self) -> dict[str, Any]:
        """For ``GET /status``: whether a message notification can go out now, and why not."""
        hub = self.hub()
        alert_settings = self.alert_settings()
        ready = getattr(hub.pusher, "ready", None)
        try:
            usable, why = ready() if callable(ready) else (False, "no alert sender")
        except Exception:  # noqa: BLE001
            usable, why = False, "the sender failed"
        devices = self._devices(hub)
        phones = sum(1 for device in devices if device.wants(KIND))
        if not alert_settings.enabled or KIND not in alert_settings.kinds:
            unavailable = "turned off on this host (settings.alerts)"
        elif not usable:
            unavailable = why or "APNs is not configured"
        elif not devices:
            unavailable = "no iPhone is registered"
        elif not phones:
            unavailable = "no registered iPhone takes message notifications"
        else:
            unavailable = ""
        out: dict[str, Any] = {"available": not unavailable, "phones": phones, "sent": self.sent,
                               "allow_cron": self.settings().allow_cron}
        if unavailable:
            out["note"] = unavailable
        return out

    def _log(self, hub: Any, origin: hermes.Origin, result: str, **more: Any) -> None:
        """That a notification was asked for, from which conversation and how it ended: never its text."""
        source = "cron" if origin.is_cron else call_policy._surface(origin)
        logger.info("hermes_voice: notify_user from %s (%s): %s%s", origin.session_id, source or "?", result,
                    f" ({more['reason']})" if more.get("reason") else "")
        entry: dict[str, Any] = {"event": "notify", "session_id": origin.session_id, "source": source,
                                 "result": result, **more}
        try:
            hub.policy.log(entry)
        except Exception:  # noqa: BLE001 - the log must never fail the tool
            logger.debug("hermes_voice: ring log unavailable", exc_info=True)


def _count(number: int) -> str:
    return f"{number} notification{'' if number == 1 else 's'}"


def _minutes(seconds: float) -> str:
    minutes = seconds / 60
    return f"{minutes:.0f} minutes" if minutes != 60 else "hour"


# ── one per process ────────────────────────────────────────────────────────────────────────────────────────

_messages: Optional[Messages] = None
_messages_lock = threading.Lock()


def messages() -> Messages:
    """The dashboard process's notify_user state."""
    global _messages
    with _messages_lock:
        if _messages is None:
            _messages = Messages()
        return _messages


def install(instance: Optional[Messages]) -> None:
    """Replace the process's notify_user state (tests)."""
    global _messages
    with _messages_lock:
        _messages = instance


# ── the tool ───────────────────────────────────────────────────────────────────────────────────────────────

NOTIFY_USER: dict[str, Any] = {
    "name": "notify_user",
    "description": (
        "Send the user a notification on their iPhone (HermesVoice app) now, for news they asked to be told or "
        "would want right away (\"Your train is 10 minutes late\"); not for routine progress, not during a call "
        "(speak instead) and not to the chat they are reading (just reply). It is a banner, not a call: it never "
        "rings through Silent mode. urgency: \"normal\" (default, with sound), \"time_sensitive\" (also gets "
        "through a Focus that allows it) or \"quiet\" (no sound). Returns {status: \"sent\", \"quiet\" (sent "
        "silently: quiet hours or too many lately), \"not_sent\" or \"not_available\", note}: the note says why "
        "and what to do."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": f"A few words, the headline (at most {TITLE_CHARS} characters).",
            },
            "body": {
                "type": "string",
                "description": f"The message: plain text, a sentence or two (at most {BODY_CHARS} characters).",
            },
            "urgency": {
                "type": "string",
                "enum": list(URGENCIES),
                "description": "\"normal\" (default), \"time_sensitive\" (can't wait) or \"quiet\" (no sound).",
            },
        },
        "required": ["title", "body"],
    },
}


def notify_user(args: Any, session_id: Any = None, task_id: Any = None, **_: Any) -> str:
    args = args if isinstance(args, dict) else {}
    title, body, urgency = args.get("title"), args.get("body"), args.get("urgency")
    try:
        if not hub_module.routes_mounted():
            return _answer(_remote(session_id, title, body, urgency))
        origin = hermes.origin(session_id)
        if not origin.session_id:
            return _answer({"status": "not_sent", "reason": "not_allowed",
                            "note": "This conversation can't notify the user. Reply in text instead."})
        return _answer(messages().send(origin, title, body, urgency))
    except Exception:  # noqa: BLE001 - a tool must never raise
        logger.warning("hermes_voice: notify_user failed", exc_info=True)
        return _answer({"status": "not_sent", "reason": "error",
                        "note": "The notification failed on the host; nothing was sent. Tell the user in your reply."})


def _answer(result: dict[str, Any]) -> str:
    return json.dumps(result, ensure_ascii=False)


# ── other Hermes processes (the hub's socket) ──────────────────────────────────────────────────────────────


def _wire(value: Any) -> str:
    return value[:WIRE_CHARS] if isinstance(value, str) else ""


def _remote(session_id: Any, title: Any, body: Any, urgency: Any) -> dict[str, Any]:
    """``notify_user`` from a process that isn't the dashboard: through its hub socket (op ``notify``)."""
    from . import remote

    origin = remote.origin_for(session_id)
    if not origin.session_id:
        return {"status": "not_sent", "reason": "not_allowed",
                "note": "This conversation can't notify the user. Reply in text instead."}
    params: dict[str, Any] = {"origin": remote.payload(origin), "title": _wire(title), "body": _wire(body)}
    if isinstance(urgency, str):
        params["urgency"] = urgency[:40]
    stopped = False

    def watch() -> list:
        """Tell the hub once when the user pressed Stop (it stops between retries)."""
        nonlocal stopped
        if not stopped and hermes.is_interrupted():
            stopped = True
            return [{"interrupt": True}]
        return []

    try:
        with remote.Client.connect() as client:
            # APNs answers within seconds; a passing failure is tried again for up to 15 s.
            return client.request("notify", params, timeout=90.0, watch=watch)
    except remote.NotAvailable:
        return {"status": "not_available", "note": NOT_AVAILABLE}
    except remote.RemoteError as error:
        if error.error == "unknown_op":
            return {"status": "not_available", "note": OLD_PLUGIN}
        logger.warning("hermes_voice: notify_user through the hub failed: %s", error.error)
    except (ConnectionError, OSError, TimeoutError) as error:
        logger.warning("hermes_voice: notify_user through the hub failed: %s", type(error).__name__)
    return {"status": "not_available",
            "note": "The Hermes dashboard stopped answering, so it isn't known whether the notification went out. "
                    "Tell the user in your reply."}


def from_socket(server: Any, message: dict[str, Any], signals: Any) -> dict[str, Any]:
    """The hub socket's ``notify {origin, title, body, urgency?}`` (``hubsock.HubServer._dispatch``): the same
    notification, for a conversation in another process. A process of another profile notifies only when
    ``policy.allowed_profiles`` names its profile, as for calls."""
    from . import hubsock

    origin = hubsock.origin_from(message.get("origin"))
    if server._foreign(origin, "async") is not None:
        return {"status": "not_sent", "reason": "not_allowed", "note": (
            f"Conversations of the {origin.profile!r} profile can't notify the phone this dashboard serves (its "
            "policy.allowed_profiles doesn't list the profile). Reply in text instead.")}
    return messages().send(origin, message.get("title"), message.get("body"), message.get("urgency"),
                           interrupted=signals.interrupted)
