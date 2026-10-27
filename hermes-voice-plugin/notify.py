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
- **Turn done:** the watcher sees a turn end (the conversation's ``running`` going off, in the dashboard process or
  in a compute-host child under ``dashboard.turn_isolation``), and the ``on_session_end`` hook tells it of a turn too
  short to be seen running. How it ended comes from the turn's own ``message.complete`` event in the dashboard's
  replay ring (``complete`` / ``error`` / ``interrupted``, and the reply), else from the turn Hermes kept as failed
  (``inflight_turn`` with ``status: "error"``), else from the hook: Hermes skips ``on_session_end`` on its early
  returns (a provider error, retries used up), so the hook alone would miss most failed turns. It alerts when no
  client had the conversation open as the turn ended nor ``grace_s`` later (someone who watched the reply arrive
  doesn't need a push; one who left mid-turn does), the conversation hasn't started another turn by then (that
  one's end alerts instead) and it isn't on a call with the phone. An interrupted or muted turn, and an exact
  ``[SILENT]`` reply, say nothing; a failed one says it failed.

"A client attached" is a live client transport on the conversation (``_session_live_transports``): the app or a
Desktop window that has it open. Each phone can turn kinds off (``POST /devices {"alerts": {...}}``), and the host
can too (``plugins.entries.hermes_voice.settings.alerts``: ``enabled``, ``approval``, ``clarify``, ``turn_done``,
``grace_s``, ``previews``). With ``previews: false`` no conversation text (the reply, the question, what needs
approving, the conversation's title) goes through APNs: the phone shows a generic line and opens the conversation
to answer. With previews on, every text is passed through Hermes' secret redaction first (where that can't run, the
generic line goes instead), and a question whose choices redaction would change goes without its questions.

During the owner's quiet hours (``policy.quiet_hours``), and past a budget (one sounding turn_done per conversation
every 5 minutes, 20 sounding alerts an hour), alerts still go but silently: no sound, ``interruption-level:
passive``. A push APNs couldn't take for a passing reason (unreachable, 429, 5xx) is tried again a few times
(1, 2, 4, 8 s) while its request is still open.

Payload (``push.Apns.push_alert`` sends it as ``apns-push-type: alert`` to the app's own topic):
``{"aps": {"alert": {title, body}, "category": "HERMES_APPROVAL" | "HERMES_CLARIFY" | "HERMES_TURN_DONE",
"thread-id": <stored session id>, "sound": "default"}, "hermes": {"kind", "session_id", "profile", "request_id",
"choices" (approval), "questions" (clarify)}}``; a silent one has ``"interruption-level": "passive"`` instead of
``sound``.
"""

from __future__ import annotations

import logging
import re
import sys
import threading
import time
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from . import hermes, push
from .config import current as current_plugin_settings
from .policy import in_quiet_hours

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
# A turn-end the hook reported is matched with the end the watcher sees for this long.
HOOK_END_KEPT_S = 600.0
# Waits before trying a push again that APNs couldn't take for a passing reason.
RETRY_DELAYS = (1.0, 2.0, 4.0, 8.0)
# Sounding alerts: at most one turn_done per conversation this often, and this many an hour in all; past that they
# go silently.
TURN_DONE_EVERY_S = 300.0
SOUNDED_PER_HOUR = 20


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


def safe(text: Any) -> Optional[str]:
    """`text` as it may go through APNs: with credentials masked (Hermes' redaction), or None where redaction can't
    run (the caller then says something generic)."""
    line = " ".join(str(text or "").split())
    if not line:
        return ""
    return hermes.redact(line)


def build(kind: str, *, title: str, body: str, session_id: str, profile: str, request_id: str = "",
          choices: Optional[list[str]] = None, questions: Optional[list[dict]] = None,
          quiet: bool = False) -> dict[str, Any]:
    """An alert payload as the app expects it (see the module doc), at most APNs' 4 KB. A `quiet` one makes no
    sound and doesn't light the screen (quiet hours, or over the budget)."""
    data: dict[str, Any] = {"kind": kind, "session_id": session_id, "profile": profile or "default"}
    if kind in ("approval", "clarify"):
        data["request_id"] = request_id
    if kind == "approval":
        data["choices"] = list(choices or APPROVAL_CHOICES)
    if kind == "clarify":
        data["questions"] = list(questions or [])
    aps: dict[str, Any] = {
        "alert": {"title": clip(title, TITLE_CHARS) or DEFAULT_TITLE, "body": clip(body, BODY_CHARS)},
        "category": CATEGORIES[kind],
        "thread-id": session_id,
    }
    if quiet:
        aps["interruption-level"] = "passive"
    else:
        aps["sound"] = "default"
    return fit({"aps": aps, "hermes": data})


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
    """The questions as the gateway sent them (``{qid, question, choices, multi_select}``), each question's text
    redacted; choices verbatim, since the phone answers with them. Empty when any question is malformed, or when
    redaction would change a choice or can't run (the phone then opens the conversation)."""
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
        question = safe(item.get("question"))
        if question is None:
            return []
        for choice in choices or []:
            if safe(choice) != " ".join(choice.split()):
                return []  # an answer with a masked choice would answer something else
        wire.append({"qid": item["qid"], "question": clip(question, QUESTION_CHARS),
                     "choices": list(choices) if choices is not None else None,
                     "multi_select": bool(item.get("multi_select"))})
    return wire


def request_alert(kind: str, params: dict, *, request_id: str, title: str, session_id: str, profile: str,
                  previews: bool, quiet: bool = False) -> dict[str, Any]:
    """The alert for an open approval or clarify request."""
    # A conversation's title is made from what was said in it.
    title = (safe(title) or DEFAULT_TITLE) if previews else DEFAULT_TITLE
    if kind == "approval":
        # The description only: the command, even redacted, stays off APNs and the lock screen.
        body = (safe(params.get("description")) or "") if previews else ""
        return build(kind, title=title, body=body or GENERIC[kind], session_id=session_id, profile=profile,
                     request_id=request_id, choices=approval_choices(params), quiet=quiet)
    questions = clarify_questions(params) if previews else []
    body = ""
    if questions:
        body = questions[0]["question"]
        if len(questions) > 1:
            body = f"{clip(body, BODY_CHARS - 20)} (+{len(questions) - 1} more)"
    return build(kind, title=title, body=body or GENERIC[kind], session_id=session_id, profile=profile,
                 request_id=request_id, questions=questions, quiet=quiet)


def turn_alert(outcome: str, reply: str, *, title: str, session_id: str, profile: str,
               previews: bool, quiet: bool = False) -> dict[str, Any]:
    if outcome == "failed":
        body = GENERIC["failed"]
    else:
        body = (safe(plain(reply)) or "") if previews else ""
    return build("turn_done", title=(safe(title) or DEFAULT_TITLE) if previews else DEFAULT_TITLE,
                 body=body or GENERIC["turn_done"], session_id=session_id, profile=profile, quiet=quiet)


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


def _replay() -> Any:
    """The host's per-session event ring (``tui_gateway.event_replay``), once the host has written an event."""
    module = sys.modules.get("tui_gateway.event_replay")
    return module if callable(getattr(module, "events_since", None)) else None


def latest_seq(sid: str) -> int:
    reader = getattr(_replay(), "latest_seq", None)
    try:
        return int(reader(sid)) if callable(reader) else 0
    except Exception:  # noqa: BLE001
        return 0


def last_complete(sid: str, after: int) -> tuple[Optional[dict], int]:
    """The last ``message.complete`` payload of the conversation after event `after` (the turn's own end: its
    ``status`` is ``complete`` / ``error`` / ``interrupted``, and ``text`` its reply), and the last event seen. A
    compute-host child's events are relayed through the dashboard, so they are there too."""
    module = _replay()
    if module is None:
        return None, after
    try:
        events = module.events_since(sid, after)
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: event replay unreadable", exc_info=True)
        return None, after
    found: Optional[dict] = None
    seen = after
    for event in events if isinstance(events, list) else []:
        if not isinstance(event, dict):
            continue
        seq = event.get("seq")
        if isinstance(seq, int):
            seen = max(seen, seq)
        payload = event.get("payload")
        if event.get("type") == "message.complete" and isinstance(payload, dict):
            found = payload
    return found, seen


# ── the watcher ────────────────────────────────────────────────────────────────────────────────────────────


@dataclass
class _Waiting:
    """An open approval or clarify request."""

    kind: str
    sid: str
    unattached_since: Optional[float] = None
    sent: bool = False
    attempts: int = 0
    retry_at: float = 0.0


@dataclass
class _TurnEnd:
    sid: str  # runtime session
    session_id: str  # stored id when the turn ended
    record: dict
    outcome: str  # done | failed
    reply: str
    due: float
    attempts: int = 0


@dataclass
class _HookEnd:
    """What ``on_session_end`` said about a turn (when it fires: Hermes skips it on early returns)."""

    session_id: str
    record: dict
    outcome: str  # done | failed | interrupted | muted
    reply: str
    at: float
    turn_id: str = ""


@dataclass
class _Run:
    """A turn the watcher saw running."""

    record: dict
    seq: int  # the conversation's last event before the turn
    complete: Optional[dict] = None  # its message.complete, once seen


@dataclass
class _View:
    """One live conversation as the host showed it on this tick."""

    sid: str
    record: dict
    attached: bool
    running: bool
    host_turn: str
    requests: list[dict] = field(default_factory=list)


def _quiet_hours_now() -> bool:
    """The owner's quiet hours (``policy.quiet_hours``, the calls' own setting) are on now."""
    try:
        quiet = current_plugin_settings().policy.quiet_hours
        return quiet is not None and in_quiet_hours(quiet, time.time())
    except Exception:  # noqa: BLE001 - unreadable settings: not quiet
        return False


class Alerts:
    """Finds what the phone should hear about, and sends it (``tick``, every ``POLL_S`` on its own thread)."""

    def __init__(
        self,
        pusher: Optional[Callable[[], Any]] = None,
        settings: Callable[[], AlertSettings] = current_settings,
        clock: Callable[[], float] = time.monotonic,
        quiet_hours: Callable[[], bool] = _quiet_hours_now,
    ) -> None:
        self.pusher = pusher or _hub_pusher
        self.settings = settings
        self.clock = clock
        self.quiet_hours = quiet_hours
        self.lock = threading.Lock()
        self.waiting: dict[str, _Waiting] = {}
        self.turns: list[_TurnEnd] = []
        # Runtime sid -> the turn running there (and the record: the dashboard may drop a conversation nobody has
        # open right after its turn ended).
        self.runs: dict[str, _Run] = {}
        # Runtime sid -> the conversation's last event seen while it was idle.
        self.seqs: dict[str, int] = {}
        # Runtime sid -> what on_session_end said about its last turn, until the watcher sees that turn end.
        self.hook_ends: dict[str, _HookEnd] = {}
        # Stored session id -> the reply of its turn that is ending (post_llm_call, then on_session_end).
        self.replies: OrderedDict[str, str] = OrderedDict()
        # Sounding alerts sent: (clock, kind, stored session id), for the budget.
        self.sounded: deque[tuple[float, str, str]] = deque(maxlen=200)
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
                   interrupted: Any = None, muted: Any = None) -> None:
        """``on_session_end``: a turn of a conversation this dashboard hosts ended. The watcher alerts for it once it
        sees the conversation idle (this hook doesn't fire on every way out of a turn, and a turn too short for the
        watcher to see running still alerts through it)."""
        with self.lock:
            reply = self.replies.pop(session_id, "") if session_id else ""
        if not session_id:
            return
        found = hermes.find_live(session_id)
        if found is None:  # a subagent, a side task, a conversation of another process
            return
        if interrupted:
            outcome = "interrupted"
        elif muted is True:
            outcome = "muted"  # a background wake whose presentation Hermes muted
        elif failed is not True and (completed or failed is False):
            outcome = "done"
        else:
            outcome = "failed"
        turn = str(turn_id or "")
        with self.lock:
            known = self.hook_ends.get(found[0])
            if known is not None and turn and known.turn_id == turn:
                return  # the same turn told twice
            self.hook_ends[found[0]] = _HookEnd(session_id, found[1], outcome, reply, self.clock(), turn)

    # ── the watcher ──────────────────────────────────────────────────────────────────────────────────────

    def tick(self) -> int:
        """One look at the host: alerts whatever is due now. Returns how many went to APNs."""
        settings = self.settings()
        server = hermes.tui_server()
        if not settings.enabled or server is None:
            with self.lock:
                self.waiting.clear()
                self.turns.clear()
                self.runs.clear()
                self.hook_ends.clear()
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
                    if (not waiting.sent and kind in settings.kinds and now >= waiting.retry_at
                            and now - waiting.unattached_since >= settings.grace_s):
                        params = request.get("params") if isinstance(request.get("params"), dict) else {}
                        requests.append((kind, rid, view, params))
            for rid in [rid for rid in self.waiting if rid not in seen]:
                del self.waiting[rid]
        for sid, ended in self._turn_ends(server, views, now):
            if "turn_done" in settings.kinds:
                self._turn_over(sid, *ended, settings)
        with self.lock:
            due = [turn for turn in self.turns if turn.due <= now]
            self.turns = [turn for turn in self.turns if turn.due > now]
        sent = 0
        quiet_hours = self.quiet_hours()
        for kind, rid, view, params in requests:
            stored = hermes.record_session_id(view.record) or view.sid
            quiet = self._quiet(kind, stored, now, quiet_hours)
            payload = request_alert(kind, params, request_id=rid, title=self._title(view.sid, view.record),
                                    session_id=stored, profile=session_profile(view.record),
                                    previews=settings.previews, quiet=quiet)
            outcome = self._send(kind, payload, rid, quiet)
            sent += outcome == "sent"
            with self.lock:
                waiting = self.waiting.get(rid)
                if waiting is None:
                    continue
                if outcome == "retry" and waiting.attempts < len(RETRY_DELAYS):
                    waiting.retry_at = now + RETRY_DELAYS[waiting.attempts]
                    waiting.attempts += 1
                else:
                    waiting.sent = True  # sent, refused for good, or out of tries
            if outcome == "sent":
                self._sounded(kind, stored, now, quiet)
        for turn in due:
            view = views.get(turn.sid)
            if view is not None and (view.attached or view.running or view.host_turn):
                continue  # someone is looking, or it went on with another turn (whose end alerts)
            if self._on_call(turn.session_id, turn.sid):
                continue  # the user is talking with it
            quiet = self._quiet("turn_done", turn.session_id, now, quiet_hours)
            payload = turn_alert(turn.outcome, turn.reply, title=self._title(turn.sid, turn.record),
                                 session_id=turn.session_id, profile=session_profile(turn.record),
                                 previews=settings.previews, quiet=quiet)
            outcome = self._send("turn_done", payload, f"turn-{turn.session_id}", quiet)
            sent += outcome == "sent"
            if outcome == "sent":
                self._sounded("turn_done", turn.session_id, now, quiet)
            elif outcome == "retry" and turn.attempts < len(RETRY_DELAYS):
                with self.lock:
                    if not any(other.sid == turn.sid for other in self.turns):  # unless a newer one is waiting
                        turn.due, turn.attempts = now + RETRY_DELAYS[turn.attempts], turn.attempts + 1
                        self.turns.append(turn)
        return sent

    def _view(self, server: Any, sid: str, record: dict) -> _View:
        return _View(sid, record, client_attached(server, record), bool(record.get("running")),
                     str(record.get("_compute_host_turn_id") or ""), open_requests(server, sid))

    def _turn_ends(self, server: Any, views: dict[str, _View], now: float) -> list[tuple[str, tuple]]:
        """The turns that ended since the last tick, as (runtime sid, (stored id, record, outcome, reply, ended
        at)): a conversation the watcher saw running is idle now, or the hook told of a turn it never saw run.
        Turns that were stopped, muted or ended on a screen say nothing (not returned)."""
        ended: list[tuple[str, tuple]] = []
        with self.lock:
            for sid, hook in list(self.hook_ends.items()):
                if now - hook.at > HOOK_END_KEPT_S:
                    del self.hook_ends[sid]
            for sid, view in views.items():
                busy = view.running or bool(view.host_turn)
                run = self.runs.get(sid)
                if busy:
                    if run is None:
                        run = self.runs[sid] = _Run(view.record, self.seqs.get(sid, latest_seq(sid)))
                    complete, run.seq = last_complete(sid, run.seq)
                    run.complete = complete or run.complete
                    continue
                if run is not None or sid in self.hook_ends:
                    self.runs.pop(sid, None)
                    result = self._ended(sid, view.record, run, self.hook_ends.pop(sid, None), now)
                    if result is not None and not view.attached:
                        ended.append((sid, result))
                self.seqs[sid] = latest_seq(sid)
            # Conversations gone from the host (closed, or reaped right after their turn): a turn that was over by
            # then still alerts; one closed mid-turn doesn't.
            for sid in [sid for sid in self.runs if sid not in views]:
                run = self.runs.pop(sid)
                record = run.record
                if record.get("running") or record.get("_compute_host_turn_id"):
                    continue
                result = self._ended(sid, record, run, self.hook_ends.pop(sid, None), now)
                if result is not None and not client_attached(server, record):
                    ended.append((sid, result))
            for sid in [sid for sid in self.hook_ends if sid not in views]:
                hook = self.hook_ends.pop(sid)
                result = self._ended(sid, hook.record, None, hook, now)
                if result is not None:
                    ended.append((sid, result))
            for sid in [sid for sid in self.seqs if sid not in views]:
                del self.seqs[sid]
        return ended

    def _ended(self, sid: str, record: dict, run: Optional[_Run], hook: Optional[_HookEnd],
               now: float) -> Optional[tuple]:
        """How a turn ended: (stored id, record, "done" | "failed", reply, ended at), or None when it says nothing.
        Caller holds the lock."""
        stored = hermes.record_session_id(record) or (hook.session_id if hook else "") or sid
        at = hook.at if hook is not None else now
        reply = hook.reply if hook is not None else ""
        if record.get("_turn_cancel_requested") or (hook is not None and hook.outcome == "interrupted"):
            return None
        complete, _ = last_complete(sid, run.seq if run is not None else self.seqs.get(sid, 0))
        complete = complete or (run.complete if run is not None else None)
        if complete is not None:
            status = str(complete.get("status") or "complete")
            if status == "interrupted":
                return None
            if status == "error":
                return stored, record, "failed", "", at
            text = complete.get("text")
            reply = text if isinstance(text, str) and text.strip() else reply
            return None if is_silent(reply) else (stored, record, "done", reply, at)
        inflight = record.get("inflight_turn")
        if isinstance(inflight, dict) and inflight.get("status") == "error":
            return stored, record, "failed", "", at
        if hook is not None:
            if hook.outcome == "muted" or (hook.outcome == "done" and is_silent(reply)):
                return None
            return stored, record, hook.outcome, reply, at
        if _replay() is not None:
            return None  # a turn that ended with no message.complete (a muted wake, a manual compaction)
        return stored, record, "done", "", at

    def _turn_over(self, sid: str, session_id: str, record: dict, outcome: str, reply: str, at: float,
                   settings: AlertSettings) -> None:
        with self.lock:
            self.turns = [turn for turn in self.turns if turn.sid != sid]  # the newest turn speaks for them all
            self.turns.append(_TurnEnd(sid, session_id, record, outcome, reply, at + settings.grace_s))

    def _quiet(self, kind: str, session_id: str, now: float, quiet_hours: bool) -> bool:
        """Whether this alert goes silently: quiet hours, or over the budget."""
        if quiet_hours:
            return True
        with self.lock:
            recent = [(at, k, sid) for at, k, sid in self.sounded if now - at < 3600.0]
        if len(recent) >= SOUNDED_PER_HOUR:
            return True
        return kind == "turn_done" and any(k == "turn_done" and sid == session_id and now - at < TURN_DONE_EVERY_S
                                           for at, k, sid in recent)

    def _sounded(self, kind: str, session_id: str, now: float, quiet: bool) -> None:
        if not quiet:
            with self.lock:
                self.sounded.append((now, kind, session_id))

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

    def _send(self, kind: str, payload: dict[str, Any], collapse_id: str, quiet: bool = False) -> str:
        """Push one alert: "sent", "retry" (APNs couldn't take it for a passing reason) or "failed"."""
        try:
            pusher = self.pusher()
            send = getattr(pusher, "push_alert", None)
            if not callable(send):
                return "failed"
            result = send(kind, payload, collapse_id=collapse_id)
        except Exception as error:  # noqa: BLE001 - an alert must never take the watcher down
            # The type only: a message or traceback could carry a request URL (with the device token).
            logger.warning("hermes_voice: a %s alert failed (%s)", kind, type(error).__name__)
            return "retry"
        if getattr(result, "ok", False):
            self.sent += 1
            logger.info("hermes_voice: sent a %s alert to %d phone(s)%s", kind, getattr(result, "delivered", 0),
                        " silently (quiet hours or the alert budget)" if quiet else "")
            return "sent"
        retry = getattr(result, "retry", False) is True
        logger.info("hermes_voice: no %s alert sent: %s%s", kind, getattr(result, "reason", "") or "refused",
                    " (will try again)" if retry else "")
        return "retry" if retry else "failed"

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
