"""What the plugin tells the agent beyond a call's bare facts.

- **Long lines.** A line is flagged in the ``start_call`` result when it would take longer than ``LONG_LINE_S``
  to say, estimated at ``CHARS_PER_SECOND`` over the characters that are spoken: audio tags in square brackets
  (``[laughs]``) are directions to the voice, not speech.
- **Missed speech.** ``Missed`` keeps, per conversation and in memory only, the lines the user did not hear to the
  end when a call ended, so the next call in that conversation can offer them.
- **Playback.** ``Playback`` is what the phone reports about one line (how much of it played, stalls, audio
  restarts, the output route, the volume). ``playback_note`` turns it into a short note for the agent, only when
  the line may not have been heard well (the thresholds are with it); ``heard_text`` says how much of a line the
  user heard when a call ended in the middle of it.
- **Call style.** ``<HERMES_HOME>/hermes-voice/call-style.md`` (or ``settings.call_style_path``) is free text the
  agent edits with its own file tools when the user states a lasting preference about how to be spoken to (tone,
  form of address, humour, ElevenLabs audio tags). The agent gets its text (the first ``STYLE_LIMIT`` characters)
  with the ``[Voice call started]`` notice, with the first ``start_call`` result of a call, and, shortened, in the
  ``start_call`` description when the plugin loads. It is never logged and never sent to the phone.
"""

from __future__ import annotations

import logging
import math
import re
import threading
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Optional

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


def quote_lines(texts: Iterable[str], heard: Iterable[str] = ()) -> str:
    """Lines as the agent is reminded of them: quoted, shortened, at most a few. `heard`: for each line, how much
    of it the user heard (``heard_text``), put in parentheses after the line ("" adds nothing)."""
    texts = [" ".join(str(text).split()) for text in texts]
    parts = list(heard) + [""] * len(texts)
    pairs = [(text, part) for text, part in zip(texts, parts) if text]
    quoted = [f'"{text if len(text) <= UNHEARD_CHARS else text[:UNHEARD_CHARS].rstrip() + "…"}"'
              + (f" ({part})" if part else "") for text, part in pairs[:UNHEARD_LINES]]
    more = len(pairs) - len(quoted)
    return ", ".join(quoted) + (f" (and {more} more)" if more > 0 else "")


def unheard_note(texts: Iterable[str], heard: Iterable[str] = ()) -> str:
    """What the user did not hear before the call ended ("" when they heard everything), with a leading space.
    `heard`: how much of each line they did hear (``heard_text``)."""
    quoted = quote_lines(texts, heard)
    return f" The user did not hear all of what you were saying when the call ended: {quoted}." if quoted else ""


def heard_text(heard_s: float, total_s: float) -> str:
    """How much of a line the user heard before the call ended, for the parentheses after the quoted line: "they
    heard about 2 of 9 s". It lets the agent tell "too long, they left" from "they heard it and left"."""
    total = max(1, round(total_s))
    heard = min(total, round(max(0.0, heard_s)))
    if heard_s < 0.5:
        return "they heard none of it"
    if heard >= total:
        return "they heard nearly all of it"
    return f"they heard about {heard} of {total} s"


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


# ── playback ───────────────────────────────────────────────────────────────────────────────────────────────

# Past these thresholds the agent is told that a line may not have been heard well; under them nothing is added
# to a result.
# The player ran dry while more of the line was still to come (the phone counts a gap of 0.1 s or more): told
# when the gaps add up to this much, or when there were this many of them.
STALL_NOTE_S = 0.5
STALL_NOTE_COUNT = 3
# The phone's output volume (0 to 1; iOS moves it in 16 steps): at or under two steps it is "very low". Told once
# per call.
LOW_VOLUME = 0.13
# A line acknowledged as played of which the phone says this much never reached the speaker.
MISSING_NOTE_S = 1.0
# The longest line a phone can report on.
_MAX_LINE_S = 900.0
ROUTES = frozenset({"receiver", "speaker", "bluetooth", "headphones", "car", "other"})
# How a line ended on the phone: played to the end, or not (the user hung up; the plugin cancelled it; its audio
# never all reached the speaker; the link dropped under it).
LINE_ENDINGS = frozenset({"played", "hang_up", "cancelled", "lost", "dropped"})

REPLAYED_BY_USER = "The user replayed your last line on their phone: say important things shorter and plainer."
SAME_AUDIO = (" Same text as your last line, so the audio kept from it is replayed (no new speech). To be "
              "understood better, say it shorter and plainer instead.")


def about_line(note: str, earlier: bool = False, before_this: bool = False) -> str:
    """A playback note ("Your last line …") with the line named for where it is read. `earlier`: the agent has
    spoken another line since ("an earlier line of yours"). `before_this`: it is read in the result of the next
    ``start_call``, where "your last line" would be taken for the line that result is about, which has not
    played yet ("your line before this one")."""
    which = "an earlier line of yours" if earlier else "your line before this one" if before_this else ""
    if not which:
        return note
    return note.replace("Your last line", which[0].upper() + which[1:]).replace("your last line", which)


def _number(value: Any, low: float, high: float) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return min(high, max(low, float(value)))


@dataclass(frozen=True)
class Playback:
    """What the phone reports about one line: in ``played {id, playback}`` once it was heard to the end, or in
    ``unplayed {id, reason, playback}`` when it wasn't. Every field is optional on the wire. An app from before
    this sends no ``playback`` at all: ``parse`` then gives None, and nothing is said about the line."""

    ended: str = "played"
    audio_s: Optional[float] = None    # audio the phone received for the line
    played_s: Optional[float] = None   # how much of it reached the speaker
    stalls: int = 0                    # times the player ran dry while more was still coming
    stall_s: float = 0.0               # those gaps, added up
    rebuilds: int = 0                  # audio engine restarts during the line
    route_changes: int = 0             # output route changes during the line
    route: str = ""                    # receiver | speaker | bluetooth | headphones | car | other
    volume: Optional[float] = None     # the system output volume, 0 to 1
    level_db: Optional[float] = None   # the line's speech level as received (dBFS), before the phone levels it
    gain_db: Optional[float] = None    # the gain the phone's leveller ended the line on

    @classmethod
    def parse(cls, value: Any, ended: Any = "played") -> Optional["Playback"]:
        """The ``playback`` object of a ``played`` or ``unplayed`` message; None when there is none."""
        if not isinstance(value, dict):
            return None

        def count(key: str) -> int:
            return int(_number(value.get(key), 0, 10_000) or 0)

        route = str(value.get("route") or "").strip().lower()[:20]
        return cls(
            ended=ended if ended in LINE_ENDINGS else "lost",
            audio_s=_number(value.get("audio_s"), 0, _MAX_LINE_S),
            played_s=_number(value.get("played_s"), 0, _MAX_LINE_S),
            stalls=count("stalls"),
            stall_s=_number(value.get("stall_s"), 0, _MAX_LINE_S) or 0.0,
            rebuilds=count("rebuilds"),
            route_changes=count("route_changes"),
            route=(route if route in ROUTES else "other") if route else "",
            volume=_number(value.get("volume"), 0, 1),
            level_db=_number(value.get("level_db"), -120, 0),
            gain_db=_number(value.get("gain_db"), -60, 60),
        )

    def problems(self) -> list[str]:
        """What may have kept the line from being heard well, as codes (for the ring log and ``playback_note``):
        ``stalled``, ``audio_restarted``, ``route_changed``, ``low_volume``, ``audio_missing``."""
        found: list[str] = []
        if self.stalls > 0 and (self.stall_s >= STALL_NOTE_S or self.stalls >= STALL_NOTE_COUNT):
            found.append("stalled")
        if self.rebuilds > 0:
            found.append("audio_restarted")
        elif self.route_changes > 0:
            found.append("route_changed")
        if self.volume is not None and self.volume <= LOW_VOLUME:
            found.append("low_volume")
        if (self.ended == "played" and self.audio_s is not None and self.played_s is not None
                and self.audio_s - self.played_s >= MISSING_NOTE_S):
            found.append("audio_missing")
        return found

    def log(self) -> dict[str, Any]:
        """The facts for the ring log: numbers and codes, never a line's text."""
        entry: dict[str, Any] = {"ended": self.ended}
        for key in ("audio_s", "played_s", "volume", "level_db", "gain_db"):
            if (value := getattr(self, key)) is not None:
                entry[key] = round(value, 2)
        for key in ("stalls", "stall_s", "rebuilds", "route_changes"):
            if value := getattr(self, key):
                entry[key] = round(value, 2)
        if self.route:
            entry["route"] = self.route
        if problems := self.problems():
            entry["problems"] = problems
        return entry


def _times(count: int) -> str:
    return {1: "once", 2: "twice"}.get(count, f"{count} times")


def playback_note(facts: Optional[Playback], volume_told: bool = False) -> str:
    """The note for a line the phone played to the end, but maybe not well ("" when playback was fine).
    `volume_told`: the agent already heard on this call that the volume is very low."""
    if facts is None:
        return ""
    problems = [code for code in facts.problems() if not (volume_told and code == "low_volume")]
    if not problems:
        return ""
    said = {
        "stalled": f"playback stalled {_times(facts.stalls)} ({facts.stall_s:.1f} s of gaps)",
        "audio_restarted": "the phone's audio restarted while it played",
        "route_changed": "the phone's audio output changed while it played",
        "low_volume": "the phone's volume is very low",
        "audio_missing": "part of its audio was not played",
    }
    again, louder = "if it mattered, say it again shorter and plainer", "ask them to turn the volume up"
    if problems == ["low_volume"]:
        advice = louder
    elif "low_volume" in problems:
        advice = f"{again}, and {louder}"
    else:
        advice = again
    return (f"Your last line may not have been heard well: {'; '.join(said[code] for code in problems)}. "
            f"{advice[0].upper()}{advice[1:]}.")


def unplayed_note(facts: Optional[Playback], total_s: float = 0.0) -> str:
    """The note for a line the phone did not play to the end while the call went on (its audio never all reached
    the speaker), or never confirmed."""
    if facts is None or facts.played_s is None:
        return ("Your last line may not have been heard: the phone did not confirm it played it. If it mattered, "
                "say it again.")
    total = max(total_s, facts.audio_s or 0.0)
    return (f"Your last line was not played to the end on the phone ({heard_text(facts.played_s, total)}). If it "
            "mattered, say it again.")


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
