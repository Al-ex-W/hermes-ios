"""Putting what the user said (and call notices) into the conversation that owns the call.

The dashboard process hosts dashboard / desktop sessions itself (``tui_gateway.server``), so this goes through the
host's own method table, the way the desktop client would (pattern from Hermes Conduit's ``pulse_host.py``):

1. ``session.redirect``: ``redirected`` / ``queued`` = done. ``rejected`` or error 4010 -> 2.
2. ``session.steer``: ``queued`` (or ``redirected``) = done. ``rejected``, or 4010 while not running -> 3.
3. ``prompt.submit`` (without ``queued``: an idle session starts a new turn now).

The target is the owner's live runtime session (``server._find_live_session_by_key``), else the stored id is
reopened with ``session.resume`` (which follows a compression rotation to its tip). A stale runtime id (4001 /
4007) is resolved again once.

Every host method runs with Hermes' drop sink bound as its transport (``hermes.detached_transport``): this thread
has no client, and the host's fallback is its stdout, where a reopened conversation would stream from then on.

A call owned by a conversation in another process (CLI, Ink TUI, messaging gateway, cron, a compute-host child)
gets its turns over the hub's socket, and ``deliver_here`` puts them in in that process (``remote.py``):

1. The process hosts the session itself (Ink TUI): the chain above, without reopening anything.
2. A turn is running (``Turns``, from the ``pre_llm_call`` / ``on_session_end`` hooks): the agent's own
   ``redirect()`` (a model request is cancelled and retried with the turn; during tools it becomes a steer), else
   ``steer()`` (read after the current tool batch). A steer the turn ends without reading is taken back at
   ``on_session_end`` and starts a turn instead.
3. Idle: ``ctx.inject_message`` with the conversation's route key (``get_current_session_key()``, captured when
   the call started) starts a turn. Hermes allows that in a messaging or Ink TUI session only with
   ``plugins.entries.hermes_voice.allow_gateway_injection: true``; the classic CLI needs nothing.

What can't be delivered there is marked ``fallback``: the dashboard's hub then tries its own session host, which
holds the session when turns run in compute-host children (``dashboard.turn_isolation``).
"""

from __future__ import annotations

import logging
import threading
import time
import uuid
import weakref
from dataclasses import dataclass, field
from typing import Any, Callable, Optional, Protocol

from . import hermes

logger = logging.getLogger("hermes_voice")

REDIRECT, STEER, SUBMIT, RESUME = "session.redirect", "session.steer", "prompt.submit", "session.resume"
DONE = frozenset({"redirected", "queued"})
STALE_CODES = frozenset({4001, 4007})
UNSUPPORTED = 4010

REPLY_HINT = "(Reply out loud with start_call; your text replies are not spoken.)"
HUNG_UP_HINT = "(The user hung up, so the call is over; reply in text.)"
INJECTION_OFF = (
    "Hermes doesn't let hermes_voice start a turn in this conversation (plugins.entries.hermes_voice."
    "allow_gateway_injection is off), so what the user says while it is idle can't reach it"
)
MARKERS = {
    "end_of_speech": "",
    "cut_off": "cut off",
    "hang_up": "hung up",
    "muted": "muted",
    "dropped": "line dropped",
    "provider_error": "speech recognition failed",
}


# ── texts ──────────────────────────────────────────────────────────────────────────────────────────────────


def turn_text(kind: str, text: str, error: Optional[str] = None) -> Optional[str]:
    """``[Voice] <said>`` with the way the turn ended, and the hint; None when there is nothing to tell."""
    said = " ".join((text or "").split())
    marker = MARKERS.get(kind, kind.replace("_", " "))
    if not said:
        if kind != "provider_error":
            return None  # silence that ended (mute, hang-up, drop): the call notices cover it
        detail = f": {' '.join(str(error).split())[:120]}" if error else ""
        return f"[Voice, {marker}{detail}] {REPLY_HINT}"
    prefix = f"[Voice, {marker}]" if marker else "[Voice]"
    return f"{prefix} {said} {HUNG_UP_HINT if kind == 'hang_up' else REPLY_HINT}"


def started_notice(call_id: str) -> str:
    return (
        f"[Voice call started] The user is calling you from the HermesVoice app (call {call_id}). Your text replies "
        "are not spoken: talk to them with start_call (mode \"sync\" waits for their answer) and hang up with "
        "end_call. What they say arrives as messages starting with \"[Voice]\"."
    )


def outcome_notice(outcome: str, detail: str = "") -> Optional[str]:
    """The notice for a call that ended without anyone waiting on it (async start_call, user-started calls)."""
    detail = " ".join((detail or "").split())[:200]
    if outcome in ("no_answer", "declined"):
        why = "they declined it" if outcome == "declined" else "they didn't pick up"
        return f"[Voice call not answered] The user didn't take the call ({why}). Reply in text."
    if outcome == "push_failed":
        return f"[Voice line not delivered: the phone couldn't be rung ({detail or 'push failed'})] Reply in text."
    if outcome == "unreachable":
        return "[Voice line not delivered: the phone never answered the ring] Reply in text."
    if outcome == "lost":
        return ("[Voice call ended: the phone's connection was lost and didn't come back] Reply in text; call "
                "again with start_call only if it's worth it.")
    if outcome == "ended_by_user":
        return "[Voice call ended by user] Reply in text from now on; don't call back unless they ask."
    return None


def line_notice(message: str) -> str:
    return f"[Voice line not delivered: {' '.join(message.split())[:240]}]"


# ── delivery ───────────────────────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Delivery:
    ok: bool
    via: str = ""  # redirect / steer / submit / inject
    status: str = ""
    detail: str = ""
    # Not delivered where the conversation runs, and not refused there either: the dashboard may still reach it.
    fallback: bool = False


class Owner(Protocol):
    session_id: str
    runtime_sid: str
    profile: str
    profile_home: Optional[str]
    scoped: bool  # profile_home is known (else the live lookup matches any profile)
    source: str

    def rekey(self, session_id: str, runtime_sid: str = "") -> None: ...


class Injector(Protocol):
    def deliver(self, owner: Any, text: str) -> Delivery: ...


class TuiInjector:
    """In-process delivery into dashboard / desktop sessions."""

    def __init__(self) -> None:
        self.lock = threading.Lock()  # one delivery at a time: the host's methods aren't re-entrant per session

    def deliver(self, owner: Any, text: str, reopen: bool = True) -> Delivery:
        """Into the owner's live session here; with `reopen`, a conversation nobody has open is reopened."""
        table = hermes.methods()
        if table is None or not all(name in table for name in (REDIRECT, STEER, SUBMIT, RESUME)):
            return Delivery(False, detail="this process hosts no dashboard sessions")
        with self.lock:
            for attempt in range(2):
                sid, why = self._target(owner, table, again=attempt > 0, reopen=reopen)
                if not sid:
                    return Delivery(False, detail=why)
                delivery = self._chain(table, sid, text)
                if delivery is not None:
                    return delivery
            return Delivery(False, detail="the conversation kept going away")

    def deliver_live(self, owner: Any, text: str) -> Delivery:
        """Only into a session this process has open now (never reopens one)."""
        return self.deliver(owner, text, reopen=False)

    def _target(self, owner: Any, table: dict, again: bool, reopen: bool = True) -> tuple[str, str]:
        if not again:
            record = hermes.live_record(owner.runtime_sid) if owner.runtime_sid else None
            if record is not None:
                owner.rekey(hermes.record_session_id(record) or owner.session_id, owner.runtime_sid)
                return owner.runtime_sid, ""
            live = (hermes.find_live(owner.session_id, owner.profile_home) if owner.scoped
                    else hermes.find_live(owner.session_id))
            if live is not None:
                owner.rekey(hermes.record_session_id(live[1]) or owner.session_id, live[0])
                return live[0], ""
        if not reopen:
            return "", "the conversation isn't open in this process"
        params: dict[str, Any] = {"session_id": owner.session_id, "source": owner.source or "desktop"}
        if owner.profile and owner.profile not in ("default", "custom"):
            params["profile"] = owner.profile
        response = _call(table, RESUME, params)
        result = response.get("result") if isinstance(response, dict) else None
        sid = str((result or {}).get("session_id") or "") if isinstance(result, dict) else ""
        if not sid:
            return "", f"couldn't reopen the conversation: {_message(response)}"
        record = hermes.live_record(sid)
        owner.rekey((hermes.record_session_id(record) if record else "") or owner.session_id, sid)
        return sid, ""

    def _chain(self, table: dict, sid: str, text: str) -> Optional[Delivery]:
        """Redirect, else steer, else submit. None when the runtime id went stale (resolve it again)."""
        response = _call(table, REDIRECT, {"session_id": sid, "text": text})
        if _stale(response):
            return None
        if _status(response) in DONE:
            return Delivery(True, "redirect", _status(response))
        response = _call(table, STEER, {"session_id": sid, "text": text})
        if _stale(response):
            return None
        if _status(response) in DONE:
            return Delivery(True, "steer", _status(response))
        response = _call(table, SUBMIT, {"session_id": sid, "text": text})
        if _stale(response):
            return None
        if _ok(response):
            return Delivery(True, "submit", _status(response) or "streaming")
        return Delivery(False, "submit", "", _message(response))


def _call(table: dict, method: str, params: dict) -> Any:
    try:
        with hermes.detached_transport():
            return table[method](f"hermes-voice-{uuid.uuid4().hex[:12]}", params)
    except Exception as error:  # noqa: BLE001 - a host method blowing up is a refusal, not a crash
        logger.warning("hermes_voice: %s failed: %s", method, type(error).__name__, exc_info=True)
        return {"error": {"code": 5000, "message": f"{method} failed ({type(error).__name__})"}}


def _ok(response: Any) -> bool:
    return isinstance(response, dict) and "error" not in response and isinstance(response.get("result"), dict)


def _status(response: Any) -> str:
    return str(response["result"].get("status") or "") if _ok(response) else ""


def _code(response: Any) -> Optional[int]:
    error = response.get("error") if isinstance(response, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    return code if isinstance(code, int) else None


def _stale(response: Any) -> bool:
    return _code(response) in STALE_CODES


def _message(response: Any) -> str:
    error = response.get("error") if isinstance(response, dict) else None
    if isinstance(error, dict):
        return str(error.get("message") or error.get("code") or "unknown error")[:200]
    return "unknown error"


# ── delivery in the conversation's own process (calls from other processes) ───────────────────────────────


class LocalOwner:
    """A conversation by its stored id, for ``TuiInjector`` in a process that hosts it (the Ink TUI)."""

    def __init__(self, session_id: str) -> None:
        self.session_id = session_id
        self.runtime_sid = ""
        self.profile = "default"
        self.profile_home: Optional[str] = None
        self.scoped = False
        self.source = ""

    def rekey(self, session_id: str, runtime_sid: str = "") -> None:
        self.session_id = session_id or self.session_id
        self.runtime_sid = runtime_sid or self.runtime_sid


@dataclass
class AgentTarget:
    """Where a call's turns go in the process that runs its conversation: the agent running it (a weak
    reference: the process may drop the agent between turns), the conversation's ids, and the plugin context that
    can start a turn in it (``ctx.inject_message``)."""

    session_id: str
    session_key: str = ""
    agent_ref: Optional[Callable[[], Any]] = None
    context: Any = None
    owner: LocalOwner = field(init=False)

    def __post_init__(self) -> None:
        self.owner = LocalOwner(self.session_id)

    @classmethod
    def capture(cls, session_id: str, session_key: str, agent: Any, context: Any) -> "AgentTarget":
        ref: Optional[Callable[[], Any]] = None
        if agent is not None:
            try:
                ref = weakref.ref(agent)
            except TypeError:
                ref = lambda: agent  # noqa: E731
        return cls(session_id, session_key, ref, context)

    def agent(self) -> Any:
        try:
            return self.agent_ref() if self.agent_ref is not None else None
        except Exception:  # noqa: BLE001
            return None

    def ids(self) -> set[str]:
        ids = {self.session_id, self.owner.session_id}
        agent = self.agent()
        current = getattr(agent, "session_id", None) if agent is not None else None
        if isinstance(current, str) and current:
            ids.add(current)
        ids.discard("")
        return ids

    def rekey(self, session_id: str) -> None:
        if session_id:
            self.session_id = session_id
            self.owner.rekey(session_id)


class Turns:
    """Which conversations in this process have a turn running (``pre_llm_call`` .. ``on_session_end``), and the
    voice turns steered into them that are still in the agent's buffer."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.running: dict[str, float] = {}
        self.steers: dict[str, list[tuple[Any, Any, str, AgentTarget]]] = {}

    def start(self, session_id: str) -> None:
        if not session_id:
            return
        with self.lock:
            self.running[session_id] = time.time()
            if len(self.running) > 500:
                for key in list(self.running)[:100]:
                    self.running.pop(key, None)

    def end(self, session_id: str) -> list[tuple[AgentTarget, str]]:
        """The turn is over. Returns the voice turns it never read (taken back from the agent's buffer), which
        must start a turn now."""
        with self.lock:
            self.running.pop(session_id, None)
            held = self.steers.pop(session_id, [])
        unread: list[tuple[AgentTarget, str]] = []
        for agent_ref, ticket, text, target in held:
            agent = agent_ref()
            withdraw = getattr(agent, "withdraw_steer", None) if agent is not None else None
            try:
                if callable(withdraw) and withdraw(ticket):
                    unread.append((target, text))
            except Exception:  # noqa: BLE001 - a broken withdraw leaves the steer where it is
                logger.debug("hermes_voice: withdraw_steer failed", exc_info=True)
        return unread

    def busy(self, target: AgentTarget) -> bool:
        with self.lock:
            return any(sid in self.running for sid in target.ids())

    def hold(self, session_id: str, agent: Any, ticket: Any, text: str, target: AgentTarget) -> None:
        try:
            ref: Any = weakref.ref(agent)
        except TypeError:
            ref = lambda: agent  # noqa: E731
        with self.lock:
            self.steers.setdefault(session_id, []).append((ref, ticket, text, target))


def deliver_here(target: AgentTarget, text: str, turns: Turns) -> Delivery:
    """Put a voice turn into the conversation, in the process that runs it (see the module docs)."""
    table = hermes.methods()
    if table is not None and hermes.find_live(target.session_id) is not None:
        delivery = TuiInjector().deliver_live(target.owner, text)
        if delivery.ok:
            return delivery
    agent = target.agent()
    if agent is not None and turns.busy(target):
        delivery = _steer_agent(agent, target, text, turns)
        if delivery is not None:
            return delivery
    return inject_idle(target, text)


def _steer_agent(agent: Any, target: AgentTarget, text: str, turns: Turns) -> Optional[Delivery]:
    redirect = getattr(agent, "redirect", None)
    try:
        if callable(redirect) and redirect(text):
            return Delivery(True, "redirect", "redirected")
    except Exception:  # noqa: BLE001 - fall through to steer
        logger.debug("hermes_voice: redirect failed", exc_info=True)
    steer = getattr(agent, "steer", None)
    if not callable(steer):
        return None
    ticket = object()
    try:
        try:
            accepted = steer(text, ticket=ticket)
        except TypeError:  # a Hermes without steer tickets: a steer left over becomes the next turn anyway
            ticket = None
            accepted = steer(text)
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: steer failed", exc_info=True)
        return None
    if not accepted:
        return None
    if ticket is not None:
        turns.hold(str(getattr(agent, "session_id", None) or target.session_id), agent, ticket, text, target)
    return Delivery(True, "steer", "queued")


def inject_idle(target: AgentTarget, text: str) -> Delivery:
    """Start a turn with ``ctx.inject_message`` (the conversation is idle)."""
    ctx = target.context
    inject = getattr(ctx, "inject_message", None) if ctx is not None else None
    if not callable(inject):
        return Delivery(False, "inject", detail="this Hermes can't start a turn for a plugin", fallback=True)
    try:
        accepted = bool(inject(text, session_key=target.session_key or None))
    except Exception as error:  # noqa: BLE001
        logger.warning("hermes_voice: inject_message failed: %s", type(error).__name__)
        accepted = False
    if accepted:
        return Delivery(True, "inject", "submitted")
    if not classic_cli(ctx) and not hermes.gateway_injection_allowed():
        return Delivery(False, "inject", detail=INJECTION_OFF, fallback=True)
    return Delivery(False, "inject", detail="Hermes has no live session here to take it", fallback=True)


def classic_cli(ctx: Any) -> bool:
    """The plugin runs in the classic CLI, whose REPL takes injected messages without any setting."""
    manager = getattr(ctx, "_manager", None) if ctx is not None else None
    return getattr(manager, "_cli_ref", None) is not None
