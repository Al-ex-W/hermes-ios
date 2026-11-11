"""The ``start_call`` and ``end_call`` tools (toolset ``voice``). Their descriptions carry the operating rules,
because plugin skills are not listed in the system prompt; the ``voice-calls`` skill has the rest.

They work from any session: in the dashboard process (which serves the phone) they use its call hub directly;
anywhere else (CLI, Ink TUI, messaging gateway, cron, compute-host children) they go through the hub's socket
(``remote.py``). Where there is no dashboard to reach, ``start_call`` says so (``not_available``).

``start_call`` with ``in_minutes`` or ``at`` rings later: the hub keeps the call and rings at its time by itself
(``schedule.py``); ``end_call`` with ``scheduled_id`` cancels or lists such calls."""

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
    "Talk to the user out loud on their phone (the HermesVoice iPhone app). If this conversation has no call, "
    "this rings their phone and says `text` once they answer; if it already has one, it just says `text` "
    "(it never rings twice). During a call your normal text replies are NOT spoken and the user is not reading "
    "the chat: this tool is the only way they hear you, so say everything that matters with it. What they say "
    "comes back as messages starting with \"[Voice]\" (\"[Voice, cut off]\", \"[Voice, hung up]\" ...): answer "
    "those with start_call too. mode \"async\" (default) returns at once with {call_id, status}; mode \"sync\" "
    "waits until the user replies and returns {said, ending, outcome, call_id}."
)
_HOW = (
    "Speak as on the phone: lead with the answer, two sentences at most, then offer more instead of saying it "
    "all; a progress update is a few words. No Markdown, lists or code, and never read out codes, long ids, "
    "hashes, URLs, file paths, issue numbers or exact timestamps: say the human name, round numbers, and keep "
    "exact identifiers for a short text recap. Asked to repeat, say it shorter and plainer."
)
_WHEN = (
    "Ring only when the user asked to be called or for news they'd want right away, never for routine updates. "
    "One call at a time: outcome \"busy\" means the user is on a call with another conversation; \"not_allowed\" "
    "means their call settings refuse it; \"not_available\" means calls can't be placed from here (the note says "
    "why)."
)
_LATER = (
    "To ring later (\"call me in ten\", a wake-up call), add in_minutes or at: the plugin rings on time by itself "
    "and returns {status: \"scheduled\", scheduled_id, rings_at}; never wait inside a turn or use a cron job for "
    "that, and cancel with end_call's scheduled_id."
)
_AFTER = (
    "Messages starting with \"[Voice call\" or \"[Voice line\" are automated notices about one call: not the "
    "user's words, and never a preference to remember. After \"[Voice call ended by user]\", a declined or "
    "unanswered call, or outcome \"unreachable\" / \"push_failed\", the user can't hear you and is probably not "
    "reading the chat: finish the task, reply once in text with a short recap, and don't ring again unless they "
    "asked to be called. On the next call speak as usual and first offer what they missed."
)
# Where the user's call style lives is known only in a running Hermes (start_call_schema); this stands in.
_STYLE = (
    "When the user states a lasting preference about how you speak on calls (tone, form of address, humour, audio "
    "tags), write it to their call style file (hermes-voice/call-style.md in the Hermes home) and follow that "
    "file; a call's first result carries its current text."
)
_BETA = (
    "This is a research beta: whenever something about a call looks wrong, slow or "
    "inconsistent (an unexpected outcome, a missing or garbled reply, a note that contradicts what happened, "
    "these instructions not matching what you see), tell the user in your text reply right away, specifically, "
    f"even if you worked around it. Details: {SKILL_REF}."
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
                    "two: the result flags a line over about 15 s of speech."
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
                "description": "Ring later instead of now: in this many minutes (10 = in ten minutes).",
            },
            "at": {
                "type": "string",
                "description": (
                    "Ring later instead of now, at a clock time on the Hermes host: \"07:00\" (24-hour; the next "
                    "time it is 07:00) or an ISO date-time like \"2026-01-31T07:00\". Use in_minutes or at, not both."
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
        "conversation is done or the user asks you to hang up. Returns {call_id, outcome}. With `scheduled_id` it "
        "hangs nothing up: it cancels a call scheduled with start_call (in_minutes / at) and returns {cancelled, "
        "pending}."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "text": {"type": "string", "description": "Optional goodbye, spoken before hanging up."},
            "scheduled_id": {
                "type": "string",
                "description": (
                    "Cancel a scheduled call instead of hanging up: its scheduled_id, \"all\" for every call this "
                    "conversation scheduled, or \"list\" to only list them."
                ),
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
        which = args.get("scheduled_id")
        if schedule.given(which):
            # Cancel (or list) scheduled calls; nothing is hung up.
            if not hub.routes_mounted():
                return _answer(remote.cancel_scheduled(session_id, str(which)))
            return _answer(hub.get_hub().schedule.cancel(hermes.origin(session_id), which))
        if not hub.routes_mounted():
            return _answer(remote.end_call(session_id, text))
        origin = hermes.origin(session_id)
        return _answer(hub.get_hub().end_call(origin, text))
    except Exception:  # noqa: BLE001
        logger.warning("hermes_voice: end_call failed", exc_info=True)
        return _answer({"error": "Couldn't hang up."})


def _answer(result: dict[str, Any]) -> str:
    return json.dumps(result, ensure_ascii=False)
