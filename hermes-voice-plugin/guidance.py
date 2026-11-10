"""What the plugin tells the agent beyond a call's bare facts.

- **Long lines.** A line is flagged in the ``start_call`` result when it would take longer than ``LONG_LINE_S``
  to say, estimated at ``CHARS_PER_SECOND`` over the characters that are spoken: audio tags in square brackets
  (``[laughs]``) are directions to the voice, not speech.
- **Missed speech.** ``Missed`` keeps, per conversation and in memory only, the lines the user did not hear to the
  end when a call ended, so the next call in that conversation can offer them.
"""

from __future__ import annotations

import logging
import re
import threading
import time
from typing import Any, Callable, Iterable

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
