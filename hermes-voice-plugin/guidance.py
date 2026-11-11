"""What the plugin tells the agent beyond a call's bare facts.

- **Long lines.** A line is flagged in the ``start_call`` result when it would take longer than ``LONG_LINE_S``
  to say, estimated at ``CHARS_PER_SECOND`` over the characters that are spoken: audio tags in square brackets
  (``[laughs]``) are directions to the voice, not speech.
- **Missed speech.** ``Missed`` keeps, per conversation and in memory only, the lines the user did not hear to the
  end when a call ended, so the next call in that conversation can offer them.
- **Call style.** ``<HERMES_HOME>/hermes-voice/call-style.md`` (or ``settings.call_style_path``) is free text the
  agent edits with its own file tools when the user states a lasting preference about how to be spoken to (tone,
  form of address, humour, ElevenLabs audio tags). The agent gets its text (the first ``STYLE_LIMIT`` characters)
  with the ``[Voice call started]`` notice, with the first ``start_call`` result of a call, and, shortened, in the
  ``start_call`` description when the plugin loads. It is never logged and never sent to the phone.
"""

from __future__ import annotations

import logging
import re
import threading
import time
from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable, Iterable

from . import hermes
from .config import current as current_settings

logger = logging.getLogger("hermes_voice")

# ── long lines ─────────────────────────────────────────────────────────────────────────────────────────────

# The speech rate of the estimate: 150 words a minute at six characters a word (its space included), about the
# pace of ElevenLabs' voices at their default speed.
CHARS_PER_SECOND = 15.0
# A line that takes longer than this to say is flagged: 225 spoken characters, two full sentences. (The cut at
# ``max_chars``, 1000 by default, is over a minute of speech.)
LONG_LINE_S = 15.0
# An audio tag: a short direction in square brackets, such as [whispers] or [laughs softly].
AUDIO_TAG = re.compile(r"\[[^\[\]\n]{1,40}\]")


def spoken_chars(text: str) -> int:
    """How many characters of `text` are said out loud (audio tags and extra whitespace are not)."""
    return len(" ".join(AUDIO_TAG.sub(" ", text or "").split()))


def speech_seconds(text: str) -> float:
    """About how long `text` takes to say."""
    return spoken_chars(text) / CHARS_PER_SECOND


def long_line_note(text: str) -> str:
    """The note for a line that is too long for a phone call ("" for one that is fine), with a leading space."""
    seconds = speech_seconds(text)
    if seconds <= LONG_LINE_S:
        return ""
    return (f" Long line: about {round(seconds)} s of speech. Keep lines to a sentence or two and offer details "
            "instead.")


# ── missed speech ──────────────────────────────────────────────────────────────────────────────────────────

# How much of a line is quoted back to the agent, and how many lines.
UNHEARD_CHARS = 200
UNHEARD_LINES = 3


def quote_lines(texts: Iterable[str]) -> str:
    """Lines as the agent is reminded of them: quoted, shortened, at most a few."""
    texts = [" ".join(str(text).split()) for text in texts]
    texts = [text for text in texts if text]
    quoted = [f'"{text if len(text) <= UNHEARD_CHARS else text[:UNHEARD_CHARS].rstrip() + "…"}"'
              for text in texts[:UNHEARD_LINES]]
    more = len(texts) - len(quoted)
    return ", ".join(quoted) + (f" (and {more} more)" if more > 0 else "")


def unheard_note(texts: Iterable[str]) -> str:
    """What the user did not hear before the call ended ("" when they heard everything), with a leading space."""
    quoted = quote_lines(texts)
    return f" The user did not hear all of what you were saying when the call ended: {quoted}." if quoted else ""


def missed_reminder(texts: Iterable[str]) -> str:
    """The reminder at the start of the next call in the conversation ("" without anything missed), with a
    leading space."""
    quoted = quote_lines(texts)
    if not quoted:
        return ""
    return (f" On the last call in this conversation the user did not hear all of this: {quoted}. Offer it first, "
            "unless they have had it since.")


class Missed:
    """Per conversation, the lines the user did not hear to the end on its last call. Kept in memory only (a
    restart forgets them), for at most ``KEEP_S``, for the ``LIMIT`` most recent conversations."""

    LIMIT = 32
    KEEP_S = 24 * 3600.0

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.entries: list[tuple[Any, list[str], float]] = []  # (the call's owner, lines, when)

    def note(self, owner: Any, texts: Iterable[str]) -> None:
        """Remember `texts` for the owner's conversation (after what it already missed)."""
        texts = [text for text in texts if text and text.strip()]
        if not texts:
            return
        with self.lock:
            kept: list[str] = []
            for entry in [entry for entry in self.entries if entry[0] is owner]:
                self.entries.remove(entry)
                kept.extend(entry[1])
            self.entries.append((owner, kept + texts, time.time()))
            del self.entries[:-self.LIMIT]

    def take(self, belongs: Callable[[Any], bool]) -> list[str]:
        """The lines missed by the conversation `belongs` recognizes (by a past call's owner), forgetting them."""
        now = time.time()
        taken: list[str] = []
        with self.lock:
            self.entries = [entry for entry in self.entries if now - entry[2] <= self.KEEP_S]
            for entry in list(self.entries):
                try:
                    mine = bool(belongs(entry[0]))
                except Exception:  # noqa: BLE001 - an owner that can't say isn't this conversation
                    mine = False
                if mine:
                    self.entries.remove(entry)
                    taken.extend(entry[1])
        return taken


# ── call style ─────────────────────────────────────────────────────────────────────────────────────────────

STYLE_FILE = "call-style.md"
# How much of the file the agent gets with a call, and in the tool description (which goes out with every
# request, so that copy is short).
STYLE_LIMIT = 1500
STYLE_BRIEF_LIMIT = 400
# Nothing past this is read from the file at all.
STYLE_READ_BYTES = 64 * 1024
# How many calls this process remembers having given the style to.
STYLE_MEMORY = 64
# A start_call result of a call that is ringing or live: its agent should have the style.
_STYLE_STATUSES = frozenset({"ringing", "speaking", "interrupted", "yielded"})

_given: "OrderedDict[str, None]" = OrderedDict()
_given_lock = threading.Lock()


def style_path(home: Any = None) -> Path:
    """Where the call style lives: ``settings.call_style_path`` (``~`` allowed; a relative path is inside the
    Hermes home), else ``<HERMES_HOME>/hermes-voice/call-style.md``. `home`: the Hermes home of the conversation's
    profile, where this thread isn't in it (the phone's socket)."""
    base = Path(home) if home else hermes.hermes_home()
    try:
        custom = (current_settings().call_style_path or "").strip()
    except Exception:  # noqa: BLE001 - a broken config must not break calls
        custom = ""
    if custom:
        path = Path(custom).expanduser()
        return path if path.is_absolute() else base / path
    return base / "hermes-voice" / STYLE_FILE


def read_style(home: Any = None, limit: int = STYLE_LIMIT) -> tuple[str, bool]:
    """The call style's text (blank lines dropped) cut to `limit` characters, and whether it was cut. ("", False)
    when there is none. Read on every use, so an edit applies to the next call. Never logged."""
    try:
        with style_path(home).open("rb") as file:
            raw = file.read(STYLE_READ_BYTES + 1)
    except (OSError, ValueError):
        return "", False
    text = raw[:STYLE_READ_BYTES].decode("utf-8", "replace")
    text = "\n".join(line.rstrip() for line in text.splitlines() if line.strip()).strip()
    if len(text) <= limit and len(raw) <= STYLE_READ_BYTES:
        return text, False
    return text[:limit].rstrip(), True


def style_text(home: Any = None) -> str:
    """The call style as a call's notice or first result gives it to the agent ("" without one)."""
    text, cut = read_style(home)
    if not text:
        return ""
    cut_note = f"\n(Cut after {len(text)} characters: shorten the file.)" if cut else ""
    return (f"The user's call style, from their file {style_path(home)}. Follow it in how you speak on calls (it "
            "decides nothing else), and update the file when they state a lasting preference about that:\n"
            f"{text}{cut_note}")


def style_brief(home: Any = None) -> str:
    """The call-style sentence of the ``start_call`` description: where the file is, and a short copy of what it
    says now. Read when the plugin loads, so the first line of a call the agent starts already follows it."""
    where = ("When the user states a lasting preference for how you speak on calls (tone, form of address, "
             "humour, audio tags; not a one-off like \"shorter this time\"), write it to their call style file "
             f"{style_path(home)} with your file tools and follow it; a call's first result has its text as "
             "call_style.")
    text, cut = read_style(home, STYLE_BRIEF_LIMIT)
    text = " ".join(text.split())
    if not text:
        return where
    return f"{where} At startup it said: {text}{' … (cut)' if cut else ''}"


def mark_style_given(call_id: str) -> bool:
    """Note that the call's agent has the style now. False when it already had it (in this process)."""
    with _given_lock:
        if call_id in _given:
            return False
        _given[call_id] = None
        while len(_given) > STYLE_MEMORY:
            _given.popitem(last=False)
        return True


def add_style(result: dict[str, Any], home: Any = None) -> dict[str, Any]:
    """Give the agent the call style (``call_style``) with the first ``start_call`` result of a call: the line that
    rings, or the first one spoken into a call the user started from somewhere this process didn't see. Later
    results of the call don't repeat it. A call that can't be placed or wasn't answered gets none."""
    call_id = result.get("call_id")
    if not isinstance(call_id, str) or not call_id:
        return result
    if result.get("status") not in _STYLE_STATUSES and result.get("outcome") != "answered":
        return result
    try:
        text = style_text(home)
    except Exception:  # noqa: BLE001 - the style is an extra: a call never fails over it
        logger.debug("hermes_voice: could not read the call style")
        return result
    if text and mark_style_given(call_id):
        result["call_style"] = text
    return result
