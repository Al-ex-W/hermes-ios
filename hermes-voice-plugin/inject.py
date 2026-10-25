"""Putting what the user said (and call notices) into the conversation that owns the call.

The dashboard process hosts dashboard / desktop sessions itself (``tui_gateway.server``), so this goes through the
host's own method table, the way the desktop client would (pattern from Hermes Conduit's ``pulse_host.py``):

1. ``session.redirect``: ``redirected`` / ``queued`` = done. ``rejected`` or error 4010 -> 2.
2. ``session.steer``: ``queued`` (or ``redirected``) = done. ``rejected``, or 4010 while not running -> 3.
3. ``prompt.submit`` (without ``queued``: an idle session starts a new turn now).

The target is the owner's live runtime session (``server._find_live_session_by_key``), else the stored id is
reopened with ``session.resume`` (which follows a compression rotation to its tip). A stale runtime id (4001 /
4007) is resolved again once.
"""

from __future__ import annotations

import logging
import threading
import uuid
from dataclasses import dataclass
from typing import Any, Optional, Protocol

from . import hermes

logger = logging.getLogger("hermes_voice")

REDIRECT, STEER, SUBMIT, RESUME = "session.redirect", "session.steer", "prompt.submit", "session.resume"
DONE = frozenset({"redirected", "queued"})
STALE_CODES = frozenset({4001, 4007})
UNSUPPORTED = 4010

REPLY_HINT = "(Reply out loud with start_call; your text replies are not spoken.)"
HUNG_UP_HINT = "(The user hung up, so the call is over; reply in text.)"
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
    via: str = ""  # redirect / steer / submit
    status: str = ""
    detail: str = ""


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

    def deliver(self, owner: Any, text: str) -> Delivery:
        table = hermes.methods()
        if table is None or not all(name in table for name in (REDIRECT, STEER, SUBMIT, RESUME)):
            return Delivery(False, detail="this process hosts no dashboard sessions")
        with self.lock:
            for attempt in range(2):
                sid, why = self._target(owner, table, reopen=attempt > 0)
                if not sid:
                    return Delivery(False, detail=why)
                delivery = self._chain(table, sid, text)
                if delivery is not None:
                    return delivery
            return Delivery(False, detail="the conversation kept going away")

    def _target(self, owner: Any, table: dict, reopen: bool) -> tuple[str, str]:
        if not reopen:
            record = hermes.live_record(owner.runtime_sid) if owner.runtime_sid else None
            if record is not None:
                owner.rekey(hermes.record_session_id(record) or owner.session_id, owner.runtime_sid)
                return owner.runtime_sid, ""
            live = (hermes.find_live(owner.session_id, owner.profile_home) if owner.scoped
                    else hermes.find_live(owner.session_id))
            if live is not None:
                owner.rekey(hermes.record_session_id(live[1]) or owner.session_id, live[0])
                return live[0], ""
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
