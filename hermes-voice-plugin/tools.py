"""The ``start_call`` and ``end_call`` tools (toolset ``voice``). Their descriptions carry the operating rules,
because plugin skills are not listed in the system prompt; the ``voice-calls`` skill has the rest."""

from __future__ import annotations

import json
import logging
from typing import Any

from . import hermes, hub

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
        "\"not_allowed\" means their call settings refuse it; after \"[Voice call ended by user]\" or a declined "
        f"call, don't ring again unless asked. Details: {SKILL_REF}."
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
    """Shown to the model only where calls work: the dashboard process that serves the phone's socket and hosts
    the conversation itself (not a compute-host child, not with dashboard.turn_isolation; other processes come
    with M6b)."""
    try:
        if hermes.is_compute_host_child() or not hub.routes_mounted():
            return False
        if hermes.methods() is None:
            return False
        return not hermes.turn_isolation()
    except Exception:  # noqa: BLE001 - a check must never raise
        return False


def start_call(args: Any, session_id: Any = None, task_id: Any = None, **_: Any) -> str:
    args = args if isinstance(args, dict) else {}
    mode = str(args.get("mode") or "async").strip().lower()
    try:
        text = args.get("text")
        if not isinstance(text, str) or not text.strip():
            return _answer({"error": "text is required: the words to say out loud."})
        if mode not in ("async", "sync"):
            return _answer({"error": 'mode must be "async" or "sync".'})
        origin = hermes.origin(session_id)
        if not origin.session_id:
            return _answer(hub._refusal(mode, "not_allowed", "This conversation can't place a call."))
        return _answer(hub.get_hub().start_call(origin, text, mode))
    except Exception:  # noqa: BLE001 - a tool must never raise
        logger.warning("hermes_voice: start_call failed", exc_info=True)
        return _answer({"error": "The call couldn't be set up. Tell the user in your text reply instead."})


def end_call(args: Any, session_id: Any = None, task_id: Any = None, **_: Any) -> str:
    args = args if isinstance(args, dict) else {}
    try:
        text = args.get("text")
        origin = hermes.origin(session_id)
        return _answer(hub.get_hub().end_call(origin, text if isinstance(text, str) else ""))
    except Exception:  # noqa: BLE001
        logger.warning("hermes_voice: end_call failed", exc_info=True)
        return _answer({"error": "Couldn't hang up."})


def _answer(result: dict[str, Any]) -> str:
    return json.dumps(result, ensure_ascii=False)
