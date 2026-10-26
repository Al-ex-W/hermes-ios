"""Alert pushes: the phone hears about an approval or a question waiting in a conversation, and about a turn that
finished, while no client has that conversation open.

Only conversations the dashboard hosts count (the phone app, Hermes Desktop and the dashboard's chat attach to
those), since the phone answers through the dashboard's gateway: ``request.answer {id, result}`` with the request id
from the push (``{choice}`` for an approval, ``{answers}`` for a question). A Telegram or CLI conversation asks on
its own surface.

- **Approval / question waiting:** a watcher thread in the dashboard process looks at the open server requests of
  every live conversation (``tui_gateway`` ``_open_requests``: the ones its own turns opened, and the ones a
  compute-host child opened under ``dashboard.turn_isolation``, which the dashboard mirrors). A request alerts once,
  after it waited ``grace_s`` with no client attached; a client that attaches resets the clock.
- **Turn done:** the ``on_session_end`` hook (a turn run in the dashboard process) or the end of a compute-host turn
  the watcher saw running. It alerts when no client had the conversation open as the turn ended nor ``grace_s``
  later (someone who watched the reply arrive doesn't need a push), the conversation hasn't started another turn by
  then (that one's end alerts instead) and it isn't on a call with the phone. An interrupted turn, and an exact
  ``[SILENT]`` reply, say nothing; a failed one says it failed.

"A client attached" is a live client transport on the conversation (``_session_live_transports``): the app or a
Desktop window that has it open. Each phone can turn kinds off (``POST /devices {"alerts": {...}}``), and the host
can too (``plugins.entries.hermes_voice.settings.alerts``: ``enabled``, ``approval``, ``clarify``, ``turn_done``,
``grace_s``, ``previews``). With ``previews: false`` no conversation text (the reply, the question, what needs
approving, the conversation's title) goes through APNs: the phone shows a generic line and opens the conversation
to answer.

Payload (``push.Apns.push_alert`` sends it as ``apns-push-type: alert`` to the app's own topic):
``{"aps": {"alert": {title, body}, "category": "HERMES_APPROVAL" | "HERMES_CLARIFY" | "HERMES_TURN_DONE",
"thread-id": <stored session id>, "sound": "default"}, "hermes": {"kind", "session_id", "profile", "request_id",
"choices" (approval), "questions" (clarify)}}``.
"""

from __future__ import annotations

import logging
import re
import sys
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from . import hermes, push

logger = logging.getLogger("hermes_voice")

KINDS = push.ALERT_KINDS
CATEGORIES = {"approval": "HERMES_APPROVAL", "clarify": "HERMES_CLARIFY", "turn_done": "HERMES_TURN_DONE"}
# Server request methods that alert, and as which kind.
REQUEST_KINDS = {"approval": "approval", "clarify": "clarify"}
APPROVAL_CHOICES = ("once", "session", "always", "deny")
DEFAULT_TITLE = "Hermes"
GENERIC = {
    "approval": "Hermes is waiting for your approval.",
    "clarify": "Hermes has a question for you.",
    "turn_done": "Hermes finished.",
    "failed": "Hermes stopped: the turn failed.",
}
TITLE_CHARS = 80
BODY_CHARS = 240
QUESTION_CHARS = 300
POLL_S = 0.5
IDLE_POLL_S = 5.0  # this process doesn't serve the dashboard (yet)
DEFAULT_GRACE_S = 5.0
SETTINGS_CACHE_S = 5.0
REPLIES_KEPT = 200
TURNS_KEPT = 500


# ── settings ───────────────────────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class AlertSettings:
    enabled: bool = True
    kinds: frozenset[str] = frozenset(KINDS)
    # How long a request (or a finished turn) waits with no client attached before the phone hears about it.
    grace_s: float = DEFAULT_GRACE_S
    # Whether conversation text (reply, question, what needs approving) goes into the alert.
    previews: bool = True

    @classmethod
    def from_plugin_settings(cls, own: dict) -> "AlertSettings":
        raw = own.get("alerts") if isinstance(own, dict) else None
        raw = raw if isinstance(raw, dict) else {}
        try:
            grace = min(120.0, max(0.0, float(raw.get("grace_s", DEFAULT_GRACE_S))))
        except (TypeError, ValueError):
            grace = DEFAULT_GRACE_S
        return cls(
            enabled=_flag(raw.get("enabled"), True),
            kinds=frozenset(kind for kind in KINDS if _flag(raw.get(kind), True)),
            grace_s=grace,
            previews=_flag(raw.get("previews"), True),
        )


def _flag(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


_settings_cache: tuple[float, Optional[AlertSettings]] = (0.0, None)
_settings_lock = threading.Lock()


def current_settings() -> AlertSettings:
    """The host's alert settings, re-read at most every few seconds."""
    global _settings_cache
    with _settings_lock:
        at, settings = _settings_cache
        if settings is None or time.monotonic() - at > SETTINGS_CACHE_S:
            settings = AlertSettings.from_plugin_settings(hermes.plugin_settings())
            _settings_cache = (time.monotonic(), settings)
        return settings


# ── payloads ───────────────────────────────────────────────────────────────────────────────────────────────


def clip(text: Any, limit: int) -> str:
    """One line of at most `limit` characters (whitespace collapsed, an ellipsis when cut)."""
    line = " ".join(str(text or "").split())
    return line if len(line) <= limit else line[: max(0, limit - 1)].rstrip() + "…"


_FENCE = re.compile(r"^\s*(```|~~~).*$", re.MULTILINE)
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+", re.MULTILINE)
_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
_MARKS = re.compile(r"(\*\*|__|~~|`|^\s*>\s?|^\s*[-*+]\s+(?=\S))", re.MULTILINE)


def plain(text: Any) -> str:
    """A Markdown reply as a notification line: the words without fences, headings, emphasis or link targets."""
    if not isinstance(text, str):
        return ""
    words = _MARKS.sub("", _LINK.sub(r"\1", _HEADING.sub("", _FENCE.sub("", text))))
    return " ".join(words.split())


def is_silent(text: Any) -> bool:
    """Hermes' exact no-notification reply."""
    return isinstance(text, str) and " ".join(text.split()).casefold() == "[silent]"


def build(kind: str, *, title: str, body: str, session_id: str, profile: str, request_id: str = "",
          choices: Optional[list[str]] = None, questions: Optional[list[dict]] = None) -> dict[str, Any]:
    """An alert payload as the app expects it (see the module doc), at most APNs' 4 KB."""
    data: dict[str, Any] = {"kind": kind, "session_id": session_id, "profile": profile or "default"}
    if kind in ("approval", "clarify"):
        data["request_id"] = request_id
    if kind == "approval":
        data["choices"] = list(choices or APPROVAL_CHOICES)
    if kind == "clarify":
        data["questions"] = list(questions or [])
    payload = {
        "aps": {
            "alert": {"title": clip(title, TITLE_CHARS) or DEFAULT_TITLE, "body": clip(body, BODY_CHARS)},
            "category": CATEGORIES[kind],
            "thread-id": session_id,
            "sound": "default",
        },
        "hermes": data,
    }
    return fit(payload)


def fit(payload: dict[str, Any]) -> dict[str, Any]:
    """Shrink a payload until it fits APNs' 4 KB: shorter question texts and body first, then no questions at all
    (the phone opens the conversation to answer; a cut choice would answer something else), then a shorter title."""
    alert = payload["aps"]["alert"]
    data = payload["hermes"]

    def shorter_questions() -> None:
        for question in data.get("questions") or []:
            question["question"] = clip(question.get("question"), 100)

    steps: list[Callable[[], None]] = [
        shorter_questions,
        lambda: alert.update(body=clip(alert.get("body"), 100)),
        lambda: data.update(questions=[]) if "questions" in data else None,
        lambda: alert.update(title=clip(alert.get("title"), 40)),
        lambda: alert.update(body=clip(alert.get("body"), 40)),
    ]
    for step in steps:
        if len(push.encode_alert(payload)) <= push.MAX_ALERT_BYTES:
            break
        step()
    return payload


def approval_choices(params: dict) -> list[str]:
    offered = params.get("choices")
    if not isinstance(offered, list):
        return list(APPROVAL_CHOICES)
    chosen = [str(choice) for choice in offered if str(choice) in APPROVAL_CHOICES]
    return list(dict.fromkeys(chosen)) or ["once", "deny"]


def clarify_questions(params: dict) -> list[dict]:
    """The questions as the gateway sent them (``{qid, question, choices, multi_select}``); choices verbatim, since
    the phone answers with them. Empty when any question is malformed (the phone then opens the conversation)."""
    questions = params.get("questions")
    if not isinstance(questions, list):
        return []
    wire = []
    for item in questions:
        if not isinstance(item, dict) or not isinstance(item.get("qid"), str) or not item["qid"]:
            return []
        choices = item.get("choices")
        if choices is not None and not (isinstance(choices, list) and all(isinstance(c, str) for c in choices)):
            return []
        wire.append({"qid": item["qid"], "question": clip(item.get("question"), QUESTION_CHARS),
                     "choices": list(choices) if choices is not None else None,
                     "multi_select": bool(item.get("multi_select"))})
    return wire


def request_alert(kind: str, params: dict, *, request_id: str, title: str, session_id: str, profile: str,
                  previews: bool) -> dict[str, Any]:
    """The alert for an open approval or clarify request."""
    title = title if previews else DEFAULT_TITLE  # a conversation's title is made from what was said in it
    if kind == "approval":
        # The description only: the command, even redacted, stays off APNs and the lock screen.
        body = clip(params.get("description"), BODY_CHARS) if previews else ""
        return build(kind, title=title, body=body or GENERIC[kind], session_id=session_id, profile=profile,
                     request_id=request_id, choices=approval_choices(params))
    questions = clarify_questions(params) if previews else []
    body = ""
    if questions:
        body = questions[0]["question"]
        if len(questions) > 1:
            body = f"{clip(body, BODY_CHARS - 20)} (+{len(questions) - 1} more)"
    return build(kind, title=title, body=body or GENERIC[kind], session_id=session_id, profile=profile,
                 request_id=request_id, questions=questions)


def turn_alert(outcome: str, reply: str, *, title: str, session_id: str, profile: str,
               previews: bool) -> dict[str, Any]:
    body = GENERIC["failed"] if outcome == "failed" else (plain(reply) if previews else "") or GENERIC["turn_done"]
    return build("turn_done", title=title if previews else DEFAULT_TITLE, body=body, session_id=session_id,
                 profile=profile)


# ── what the dashboard's session host says (read-only) ─────────────────────────────────────────────────────


def live_sessions(server: Any) -> dict[str, dict]:
    """Runtime sid -> record of the conversations the host has live now."""
    sessions = getattr(server, "_sessions", None)
    if not isinstance(sessions, dict):
        return {}
    for _ in range(3):  # pool threads add and drop sessions: copy, and try again if it changed under us
        try:
            items = list(sessions.items())
            break
        except RuntimeError:
            continue
    else:
        return {}
    return {str(sid): record for sid, record in items if isinstance(record, dict) and not record.get("_finalized")}


def open_requests(server: Any, sid: str) -> list[dict]:
    """Server requests still waiting on the conversation's client, oldest first (with a compute-host child's)."""
    reader = getattr(server, "_open_requests", None)
    if not callable(reader):
        reader = getattr(sys.modules.get("tui_gateway.server_requests"), "open_requests", None)
    if not callable(reader):
        return []
    try:
        found = reader(sid)
    except Exception:  # noqa: BLE001 - a host that can't say has nothing to alert about
        logger.debug("hermes_voice: open requests unreadable", exc_info=True)
        return []
    return [item for item in found if isinstance(item, dict)] if isinstance(found, list) else []


def client_attached(server: Any, record: dict) -> bool:
    """A client (the app, a Desktop window, the dashboard's chat) has the conversation open."""
    peers = getattr(server, "_session_live_transports", None)
    if callable(peers):
        try:
            return bool(peers(record))
        except Exception:  # noqa: BLE001
            logger.debug("hermes_voice: session transports unreadable", exc_info=True)
    transport = record.get("transport")
    sinks = {id(getattr(server, name, None)) for name in ("_detached_ws_transport", "_stdio_transport")}
    if transport is None or id(transport) in sinks:
        return False
    fanout = getattr(transport, "transports", None)
    if callable(fanout):
        try:
            return any(id(peer) not in sinks for peer in fanout())
        except Exception:  # noqa: BLE001
            return True
    return True


def session_profile(record: dict) -> str:
    home = record.get("profile_home")
    if home:
        try:
            from hermes_constants import profile_name_for_home
            name = profile_name_for_home(home)
        except Exception:  # noqa: BLE001 - an older Hermes: the dashboard's own profile
            name = None
        if name:
            return str(name)
    return hermes.profile_name()


# ── the watcher ────────────────────────────────────────────────────────────────────────────────────────────


@dataclass
class _Waiting:
    """An open approval or clarify request."""

    kind: str
    sid: str
    unattached_since: Optional[float] = None
    sent: bool = False


@dataclass
class _TurnEnd:
    sid: str  # runtime session
    session_id: str  # stored id when the turn ended
    record: dict
    outcome: str  # done | failed
    reply: str
    due: float


@dataclass
class _View:
    """One live conversation as the host showed it on this tick."""

    sid: str
    record: dict
    attached: bool
    running: bool
    host_turn: str
    requests: list[dict] = field(default_factory=list)


class Alerts:
    """Finds what the phone should hear about, and sends it (``tick``, every ``POLL_S`` on its own thread)."""

    def __init__(
        self,
        pusher: Optional[Callable[[], Any]] = None,
        settings: Callable[[], AlertSettings] = current_settings,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.pusher = pusher or _hub_pusher
        self.settings = settings
        self.clock = clock
        self.lock = threading.Lock()
        self.waiting: dict[str, _Waiting] = {}
        self.turns: list[_TurnEnd] = []
        # Compute-host turns seen running: runtime sid -> (turn id, the conversation's record). The record is kept
        # because the dashboard may drop a conversation nobody has open right after its turn ended.
        self.host_turns: dict[str, tuple[str, dict]] = {}
        # Stored session id -> the reply of its turn that is ending (post_llm_call, then on_session_end).
        self.replies: OrderedDict[str, str] = OrderedDict()
        self.ended: OrderedDict[str, None] = OrderedDict()
        self.sent = 0
        self.thread: Optional[threading.Thread] = None
        self.stopping = threading.Event()
        # Stopped because the plugin unloaded: loading it again resumes watching.
        self.paused = False

    # ── hooks (agent threads of this process) ────────────────────────────────────────────────────────────

    def note_reply(self, session_id: str, reply: Any) -> None:
        """``post_llm_call``: the reply of a turn that is about to end, for its alert."""
        if not session_id or not isinstance(reply, str) or hermes.find_live(session_id) is None:
            return
        with self.lock:
            self.replies[session_id] = reply[:4000]
            self.replies.move_to_end(session_id)
            while len(self.replies) > REPLIES_KEPT:
                self.replies.popitem(last=False)

    def turn_ended(self, session_id: str, turn_id: Any = None, *, completed: Any = None, failed: Any = None,
                   interrupted: Any = None) -> None:
        """``on_session_end``: a turn of a conversation this dashboard hosts ended; alert once the grace ran out."""
        with self.lock:
            reply = self.replies.pop(session_id, "") if session_id else ""
        settings = self.settings()
        if not session_id or interrupted or not settings.enabled or "turn_done" not in settings.kinds:
            return
        found = hermes.find_live(session_id)
        if found is None:  # a subagent, a side task, a conversation of another process
            return
        if client_attached(hermes.tui_server(), found[1]):
            return  # the reply arrived on a screen
        if failed is not True and (completed or failed is False):
            if is_silent(reply):
                return
            outcome = "done"
        else:
            outcome = "failed"
        self._turn_over(found[0], session_id, found[1], outcome, reply, f"{session_id}:{turn_id or ''}",
                        settings)

    def _turn_over(self, sid: str, session_id: str, record: dict, outcome: str, reply: str, key: str,
                   settings: AlertSettings) -> None:
        with self.lock:
            if key in self.ended:
                return
            self.ended[key] = None
            while len(self.ended) > TURNS_KEPT:
                self.ended.popitem(last=False)
            self.turns = [turn for turn in self.turns if turn.sid != sid]  # the newest turn speaks for them all
            self.turns.append(_TurnEnd(sid, session_id, record, outcome, reply, self.clock() + settings.grace_s))

    # ── the watcher ──────────────────────────────────────────────────────────────────────────────────────

    def tick(self) -> int:
        """One look at the host: alerts whatever is due now. Returns how many went to APNs."""
        settings = self.settings()
        server = hermes.tui_server()
        if not settings.enabled or server is None:
            with self.lock:
                self.waiting.clear()
                self.turns.clear()
                self.host_turns.clear()
            return 0
        views = {sid: self._view(server, sid, record) for sid, record in live_sessions(server).items()}
        now = self.clock()
        requests: list[tuple[str, str, _View, dict]] = []
        with self.lock:
            seen: set[str] = set()
            for view in views.values():
                for request in view.requests:
                    rid, kind = str(request.get("id") or ""), REQUEST_KINDS.get(str(request.get("method") or ""))
                    if not rid or kind is None:
                        continue
                    seen.add(rid)
                    waiting = self.waiting.setdefault(rid, _Waiting(kind, view.sid))
                    if view.attached:
                        waiting.unattached_since = None
                        continue
                    if waiting.unattached_since is None:
                        waiting.unattached_since = now
                    if (not waiting.sent and kind in settings.kinds
                            and now - waiting.unattached_since >= settings.grace_s):
                        waiting.sent = True
                        params = request.get("params") if isinstance(request.get("params"), dict) else {}
                        requests.append((kind, rid, view, params))
            for rid in [rid for rid in self.waiting if rid not in seen]:
                del self.waiting[rid]
            host_ended = self._host_turns(views)
        for sid, record, turn_id in host_ended:
            if "turn_done" in settings.kinds and not client_attached(server, record):
                stored = hermes.record_session_id(record) or sid
                self._turn_over(sid, stored, record, "done", "", f"{stored}:{turn_id}", settings)
        with self.lock:
            due = [turn for turn in self.turns if turn.due <= now]
            self.turns = [turn for turn in self.turns if turn.due > now]
        sent = 0
        for kind, rid, view, params in requests:
            stored = hermes.record_session_id(view.record) or view.sid
            payload = request_alert(kind, params, request_id=rid, title=self._title(view.sid, view.record),
                                    session_id=stored, profile=session_profile(view.record),
                                    previews=settings.previews)
            sent += self._send(kind, payload, rid)
        for turn in due:
            view = views.get(turn.sid)
            if view is not None and (view.attached or view.running or view.host_turn):
                continue  # someone is looking, or it went on with another turn (whose end alerts)
            if self._on_call(turn.session_id, turn.sid):
                continue  # the user is talking with it
            payload = turn_alert(turn.outcome, turn.reply, title=self._title(turn.sid, turn.record),
                                 session_id=turn.session_id, profile=session_profile(turn.record),
                                 previews=settings.previews)
            sent += self._send("turn_done", payload, f"turn-{turn.session_id}")
        return sent

    def _view(self, server: Any, sid: str, record: dict) -> _View:
        return _View(sid, record, client_attached(server, record), bool(record.get("running")),
                     str(record.get("_compute_host_turn_id") or ""), open_requests(server, sid))

    def _host_turns(self, views: dict[str, _View]) -> list[tuple[str, dict, str]]:
        """Compute-host turns (``dashboard.turn_isolation``) that ended since the last tick, as (runtime sid,
        record, turn id). Their hooks run in the child, so the watcher follows the turn id the dashboard keeps on
        the conversation while one runs. A turn that was stopped (Stop, or the conversation closed or reaped
        mid-turn) says nothing. Caller holds the lock."""
        ended = []
        for sid, (turn_id, record) in list(self.host_turns.items()):
            current = str(record.get("_compute_host_turn_id") or "")
            if current == turn_id:
                continue
            del self.host_turns[sid]
            if not current and not record.get("_turn_cancel_requested"):
                ended.append((sid, record, turn_id))  # (a next turn already running alerts when it ends)
        for sid, view in views.items():
            if view.host_turn:
                self.host_turns[sid] = (view.host_turn, view.record)
        return ended

    def _title(self, sid: str, record: dict) -> str:
        try:
            return hermes.session_title(sid, record) or DEFAULT_TITLE
        except Exception:  # noqa: BLE001
            return DEFAULT_TITLE

    def _on_call(self, session_id: str, sid: str) -> bool:
        try:
            from . import hub as hub_module
            hub = hub_module.get_hub()
            with hub.lock:
                call = hub.slot
            if call is None:
                return False
            return call.owner.owns(session_id) or bool(sid and call.owner.runtime_sid == sid)
        except Exception:  # noqa: BLE001
            return False

    def _send(self, kind: str, payload: dict[str, Any], collapse_id: str) -> int:
        try:
            pusher = self.pusher()
            send = getattr(pusher, "push_alert", None)
            if not callable(send):
                return 0
            result = send(kind, payload, collapse_id=collapse_id)
        except Exception as error:  # noqa: BLE001 - an alert must never take the watcher down
            # The type only: a message or traceback could carry a request URL (with the device token).
            logger.warning("hermes_voice: a %s alert failed (%s)", kind, type(error).__name__)
            return 0
        if getattr(result, "ok", False):
            self.sent += 1
            logger.info("hermes_voice: sent a %s alert to %d phone(s)", kind, getattr(result, "delivered", 0))
            return 1
        logger.info("hermes_voice: no %s alert sent: %s", kind, getattr(result, "reason", "") or "refused")
        return 0

    # ── the thread ───────────────────────────────────────────────────────────────────────────────────────

    def start(self) -> None:
        with self.lock:
            if self.running():
                return
            self.stopping = threading.Event()
            self.thread = hermes.spawn_thread(self._run, self.stopping, name="hermes-voice-alerts")

    def stop(self) -> None:
        self.stopping.set()

    def running(self) -> bool:
        return self.thread is not None and self.thread.is_alive() and not self.stopping.is_set()

    def _run(self, stopping: threading.Event) -> None:
        from . import hub as hub_module

        warned = False
        delay = POLL_S
        while not stopping.wait(delay):
            if not hub_module.routes_mounted():
                delay = IDLE_POLL_S  # not the dashboard serving the phone (or not yet)
                continue
            delay = POLL_S
            try:
                self.tick()
            except Exception:  # noqa: BLE001 - keep watching
                logger.log(logging.DEBUG if warned else logging.WARNING, "hermes_voice: alert watcher failed",
                           exc_info=True)
                warned = True

    def status(self) -> dict[str, Any]:
        settings = self.settings()
        try:
            devices = sum(1 for device in self.pusher().store.devices() if device.alert_token)
        except Exception:  # noqa: BLE001
            devices = 0
        return {"enabled": settings.enabled, "kinds": sorted(settings.kinds), "watching": self.running(),
                "devices": devices, "sent": self.sent}


def _hub_pusher() -> Any:
    """The hub's APNs client: alerts share its provider token with the VoIP pushes."""
    from . import hub as hub_module
    return hub_module.get_hub().pusher


# ── one watcher per process ────────────────────────────────────────────────────────────────────────────────

_KEY = "_hermes_voice_alerts"
_LOCK = sys.__dict__.setdefault("_hermes_voice_alerts_lock", threading.Lock())


def alerts() -> Alerts:
    with _LOCK:
        found = sys.__dict__.get(_KEY)
        if found is None:
            found = Alerts()
            sys.__dict__[_KEY] = found
        return found


def install(instance: Optional[Alerts]) -> None:
    """Replace the process's watcher (tests)."""
    with _LOCK:
        old = sys.__dict__.pop(_KEY, None)
        if old is not None and old is not instance:
            old.stop()
        if instance is not None:
            sys.__dict__[_KEY] = instance


def start() -> None:
    """Start watching (the dashboard's routes call this once they are mounted)."""
    alerts().start()


def stop() -> None:
    alerts().stop()


def pause() -> None:
    """The plugin unloads (disabled, reloaded): stop watching, and remember to resume if it loads again."""
    watcher = alerts()
    if watcher.running():
        watcher.paused = True
        watcher.stop()


def resume() -> None:
    """The plugin loaded again in a process whose watcher an unload paused."""
    watcher = alerts()
    if watcher.paused:
        watcher.paused = False
        watcher.start()
