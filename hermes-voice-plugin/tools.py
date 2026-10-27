"""The ``start_call`` and ``end_call`` tools (toolset ``voice``). Their descriptions carry the operating rules,
because plugin skills are not listed in the system prompt; the ``voice-calls`` skill has the rest.

They work from any session: in the dashboard process (which serves the phone) they use its call hub directly;
anywhere else (CLI, Ink TUI, messaging gateway, cron, compute-host children) they go through the hub's socket
(``remote.py``). Where there is no dashboard to reach, ``start_call`` says so (``not_available``)."""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from . import hermes, hub, remote

logger = logging.getLogger("hermes_voice")

TOOLSET = "voice"
SKILL = "voice-calls"
SKILL_REF = f'skill_view("hermes_voice:{SKILL}")'

START_CALL: dict[str, Any] = {
    "name": "start_call",
    "description": (
        "Talk to the user out loud on their phone (the HermesVoice iPhone app). If this conversation has no call, "
        "this rings their phone and says `text` once they answer; if it already has one, it just says `text` "
        "(it never rings twice). During a call your normal text replies are NOT spoken: this tool is the only way "
        "the user hears you. What they say comes back as messages starting with \"[Voice]\" (\"[Voice, cut off]\", "
        "\"[Voice, hung up]\" ...): answer those with start_call too. mode \"async\" (default) returns at once with "
        "{call_id, status}; mode \"sync\" waits until the user replies and returns {said, ending, outcome, "
        "call_id}. Say short, natural, spoken sentences: no Markdown, lists, code or URLs (put detail in your text "
        "reply). Ring only when the user asked to be called or for news they'd want right away, never for routine "
        "updates. One call at a time: outcome \"busy\" means the user is on a call with another conversation; "
        "\"not_allowed\" means their call settings refuse it; \"not_available\" means calls can't be placed from "
        "here (the note says why). After \"[Voice call ended by user]\" or a declined call, don't ring again "
        f"unless asked. Details: {SKILL_REF}."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "description": "What to say, as plain conversational speech (it is read out as written).",
            },
            "mode": {
                "type": "string",
                "enum": ["async", "sync"],
                "description": (
                    "\"async\" (default): return at once; the reply arrives later as a [Voice] message. "
                    "\"sync\": wait for the user's spoken reply and return it."
                ),
            },
        },
        "required": ["text"],
    },
}

END_CALL: dict[str, Any] = {
    "name": "end_call",
    "description": (
        "Hang up this conversation's voice call, optionally saying `text` (a short goodbye) first. Use it when the "
        "conversation is done or the user asks you to hang up. Returns {call_id, outcome}."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "text": {"type": "string", "description": "Optional goodbye, spoken before hanging up."},
        },
    },
}


def available() -> bool:
    """Always shown: the tools work wherever the dashboard's hub is (this process, or its socket for every other
    Hermes process), and where it isn't, ``start_call`` answers ``not_available`` with the reason instead of the
    tool silently missing. (``reachable()`` tells whether a hub is there.)"""
    return True


def reachable() -> bool:
    """This process serves the phone, or the dashboard's hub socket is there for it."""
    try:
        return hub.routes_mounted() or remote.reachable()
    except Exception:  # noqa: BLE001 - a check must never raise
        return False


def start_call(args: Any, session_id: Any = None, task_id: Any = None, **_: Any) -> str:
    started = time.monotonic()
    args = args if isinstance(args, dict) else {}
    mode = str(args.get("mode") or "async").strip().lower()
    try:
        text = args.get("text")
        if not isinstance(text, str) or not text.strip():
            return _answer({"error": "text is required: the words to say out loud."})
        if mode not in ("async", "sync"):
            return _answer({"error": 'mode must be "async" or "sync".'})
        if not hub.routes_mounted():
            return _answer(remote.start_call(session_id, text, mode))
        origin = hermes.origin(session_id)
        if not origin.session_id:
            return _answer(hub._refusal(mode, "not_allowed", "This conversation can't place a call."))
        cap = hermes.tool_wait_cap(started) if mode == "sync" else None
        return _answer(hub.get_hub().start_call(origin, text, mode, cap_s=cap))
    except Exception:  # noqa: BLE001 - a tool must never raise
        logger.warning("hermes_voice: start_call failed", exc_info=True)
        return _answer({"error": "The call couldn't be set up. Tell the user in your text reply instead."})


def end_call(args: Any, session_id: Any = None, task_id: Any = None, **_: Any) -> str:
    args = args if isinstance(args, dict) else {}
    try:
        text = args.get("text")
        text = text if isinstance(text, str) else ""
        if not hub.routes_mounted():
            return _answer(remote.end_call(session_id, text))
        origin = hermes.origin(session_id)
        return _answer(hub.get_hub().end_call(origin, text))
    except Exception:  # noqa: BLE001
        logger.warning("hermes_voice: end_call failed", exc_info=True)
        return _answer({"error": "Couldn't hang up."})


def _answer(result: dict[str, Any]) -> str:
    return json.dumps(result, ensure_ascii=False)
