"""The ``start_call``, ``end_call`` and ``scheduled_calls`` tools (toolset ``voice``). Their descriptions carry the operating rules,
because plugin skills are not listed in the system prompt; the ``voice-calls`` skill has the rest.

They work from any session: in the dashboard process (which serves the phone) they use its call hub directly;
anywhere else (CLI, Ink TUI, messaging gateway, cron, compute-host children) they go through the hub's socket
(``remote.py``). Where there is no dashboard to reach, ``start_call`` says so (``not_available``).

``start_call`` with ``in_minutes`` or ``at`` rings later: the hub keeps the call and rings at its time by itself
(``schedule.py``); ``scheduled_calls`` lists and cancels such calls."""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from . import guidance, hermes, hub, remote, schedule

logger = logging.getLogger("hermes_voice")

TOOLSET = "voice"
SKILL = "voice-calls"
SKILL_REF = f'skill_view("hermes_voice:{SKILL}")'

# The start_call description, in parts. It is sent with every request, so it stays compact; it still has to work
# for a model that reads nothing else but the tool results.
_WHAT = (
    "Speak to the user on their phone (HermesVoice iPhone app). Rings and says `text` once they answer; if a call "
    "is already open it just says `text`. During a call your text replies are NOT spoken or read: if it matters, "
    "say it, in several short lines. \"[Voice]\" / \"[Voice, …]\" messages are the user's words: answer with "
    "start_call. Messages starting \"[Voice call\" or \"[Voice line\" are automated notices, not their words or "
    "preferences. mode \"async\" (default) returns {call_id, status} at once; \"sync\" waits for the reply: "
    "{said, ending, outcome, call_id}."
)
_HOW = (
    "Speak as on the phone: lead with the answer, two sentences at most per line, then offer more; a progress "
    "update is a few words. No Markdown, lists or code. Never read out codes, long ids, hashes, URLs, file paths "
    "or issue numbers: say the human name, round numbers, times the way people say them (\"tomorrow at seven\"), "
    "and keep exact values for the text recap. If a result's note says \"Long line\", say the next lines shorter. "
    "Asked to repeat, say it shorter and plainer."
)
_WHEN = (
    "Ring only when they asked to be called or for news they'd want right away, never for routine updates. "
    "One call at a time: \"busy\" = they are on a call with another conversation; \"not_allowed\" = their call "
    "settings refuse it; \"not_available\" = no calls from here (see the note)."
)
_LATER = (
    "To ring later (\"call me in ten\", a wake-up), set in_minutes or at; the plugin rings on time itself. Never "
    "wait in a turn or use cron. List or cancel with scheduled_calls."
)
_AFTER = (
    "After a hang-up, a declined or unanswered call, or \"unreachable\" / \"push_failed\": finish the task, "
    "reply once in text with a short recap, don't ring again unless they asked to be called. Next call, first "
    "offer what they missed."
)
# Where the user's call style lives is known only in a running Hermes (start_call_schema); this stands in.
_STYLE = (
    "When the user states a lasting preference for how you speak on calls (tone, form of address, humour, audio "
    "tags; not a one-off like \"shorter this time\"), write it to their call style file "
    "(hermes-voice/call-style.md in this profile's Hermes home) and follow it; a call's first result has its "
    "text as call_style."
)
_BETA = (
    "Research beta: if anything about a call looks wrong, slow or inconsistent (odd outcome, missing or garbled "
    "reply, notes that contradict what happened), say so specifically, even if you worked around it: a few spoken "
    f"words during a call, details in text. Details: {SKILL_REF}."
)

START_CALL: dict[str, Any] = {
    "name": "start_call",
    "description": " ".join((_WHAT, _HOW, _WHEN, _LATER, _AFTER, _STYLE, _BETA)),
    "parameters": {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "description": (
                    "What to say, as plain conversational speech (it is read out as written). A sentence or "
                    "two: the result's note flags a line over about 15 s of speech."
                ),
            },
            "mode": {
                "type": "string",
                "enum": ["async", "sync"],
                "description": (
                    "\"async\" (default): return at once; the reply arrives later as a [Voice] message. "
                    "\"sync\": wait for the user's spoken reply and return it."
                ),
            },
            "in_minutes": {
                "type": "number",
                "description": "Ring later instead of now: in this many minutes (10 = in ten minutes). Not with at.",
            },
            "at": {
                "type": "string",
                "description": (
                    "Ring later instead of now, at a clock time on the Hermes host: \"07:00\" (24-hour; the next "
                    "time it is 07:00) or an ISO date-time like \"2026-01-31T07:00\". Not with in_minutes."
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

SCHEDULED_CALLS: dict[str, Any] = {
    "name": "scheduled_calls",
    "description": (
        "List the calls this conversation scheduled with start_call (in_minutes / at), or cancel them: pass `cancel` "
        "with a scheduled_id, or \"all\". Returns {pending, cancelled, note}; it never rings or hangs up."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "cancel": {
                "type": "string",
                "description": "The scheduled_id of the call to cancel, or \"all\". Leave out to only list.",
            },
        },
    },
}


def start_call_schema() -> dict[str, Any]:
    """START_CALL as registered: its description names the user's call style file and carries a short copy of what
    the file says as the plugin loads, so the first line of a call the agent starts already follows it (a restart
    refreshes the copy; a call's first result carries the current text)."""
    try:
        style = guidance.style_brief()
    except Exception:  # noqa: BLE001 - registering the tool must not fail over the style
        logger.debug("hermes_voice: could not read the call style for the tool description")
        style = _STYLE
    return {**START_CALL, "description": " ".join((_WHAT, _HOW, _WHEN, _LATER, _AFTER, style, _BETA))}


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
        in_minutes, at = args.get("in_minutes"), args.get("at")
        if schedule.wants_later(in_minutes, at):
            # A call for later: the hub keeps it and rings at its time (schedule.py); mode plays no part.
            if not hub.routes_mounted():
                return _answer(remote.schedule_call(session_id, text, in_minutes, at))
            return _answer(hub.get_hub().schedule.schedule(hermes.origin(session_id), text, in_minutes, at))
        if mode not in ("async", "sync"):
            return _answer({"error": 'mode must be "async" or "sync".'})
        # The call style is read here, in the conversation's own process and profile (not in the hub's).
        if not hub.routes_mounted():
            return _answer(guidance.add_style(remote.start_call(session_id, text, mode)))
        origin = hermes.origin(session_id)
        if not origin.session_id:
            return _answer(hub._refusal(mode, "not_allowed", "This conversation can't place a call."))
        cap = hermes.tool_wait_cap(started) if mode == "sync" else None
        return _answer(guidance.add_style(hub.get_hub().start_call(origin, text, mode, cap_s=cap)))
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


def scheduled_calls(args: Any, session_id: Any = None, task_id: Any = None, **_: Any) -> str:
    """List this conversation's scheduled calls, after cancelling what ``cancel`` names (``schedule.py``)."""
    args = args if isinstance(args, dict) else {}
    try:
        cancel = args.get("cancel")
        if not hub.routes_mounted():
            return _answer(remote.scheduled_calls(session_id, cancel))
        return _answer(hub.get_hub().schedule.calls(hermes.origin(session_id), cancel))
    except Exception:  # noqa: BLE001 - a tool must never raise
        logger.warning("hermes_voice: scheduled_calls failed", exc_info=True)
        return _answer({"error": "Couldn't read the scheduled calls. Tell the user."})


def _answer(result: dict[str, Any]) -> str:
    return json.dumps(result, ensure_ascii=False)
