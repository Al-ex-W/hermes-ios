"""Calls that ring later: ``start_call`` with ``in_minutes`` or ``at`` ("call me in ten", a wake-up call).

The agent can't wait for the time itself (a wait inside a turn ends at Hermes' tool deadline and dies with the
session), and a Hermes cron job is a scheduled origin the policy refuses. So the plugin keeps the schedule:

- **Where.** ``<HERMES_HOME>/hermes-voice/scheduled.json`` (0600, written atomically, gone when nothing is
  scheduled). It holds each call's line, its time and the conversation it belongs to. An entry is removed when its
  call was answered, given up, cancelled or dropped. Every change is a read-modify-write of the file under
  ``scheduled.lock`` (``flock``), so the file is the truth for every process that has the plugin loaded.
- **Who rings.** The dashboard process (``hermes serve``): its hub starts ``Scheduler.start`` once it serves. One
  dashboard per folder rings (``scheduled.runner``, a ``flock`` held while it runs; a second one waits and takes
  over). It looks at the file every ``TICK_S``, so a call rings within about a second of its time, with no chat,
  client or agent turn open. Conversations in other processes schedule through the hub socket (``hubsock.py``:
  ``schedule`` / ``cancel_scheduled``).
- **Policy.** Who may schedule is checked when scheduling (``Policy.check_schedule``: cron, subagent, group and
  source rules), so a call that could never ring is refused at once. At its time the ring is the call the user
  asked for: quiet hours and the ring rate limits are not asked again (the ring log names the ``scheduled`` id; the
  ring still counts for the limits of later rings).
- **The ring** belongs to the conversation that scheduled it (``Call.scheduled``): once answered the line is
  spoken, the conversation gets a ``[Voice call started]`` notice saying which scheduled call this is (and that it
  rang late, if it did), and what the user says is injected into it like any call's turns. A conversation nobody
  has open is reopened by the hub's injector (``session.resume``). A messaging chat is never reopened in the
  dashboard, so its turns have nowhere to go until its own process speaks into the call (the scheduling result
  says so).
- **Busy** (the user is on a call with another conversation, or this conversation's phone is ringing): tried again
  every ``BUSY_RETRY_S``, ``BUSY_TRIES`` times, then dropped with a notice. A conversation that is on a live call
  itself gets the line spoken into that call, without a ring.
- **Not answered** (``no_answer``, ``unreachable``, ``push_failed``): it rings again ``scheduled.retry_after_s``
  later, ``scheduled.retries`` times (default once, after 5 minutes); only the last one tells the conversation
  (the usual notice, plus which scheduled call it was and when it rang). A declined ring is not repeated.
- **Late** (the host was down or asleep at the time): a call at most ``scheduled.late_limit_s`` late rings as soon
  as the dashboard is back, and the started notice says how late; an older one is dropped with a
  ``[Voice call not placed: …]`` notice.

Ring log events (never the line's text): ``scheduled``, ``ring`` with ``scheduled`` / ``attempt`` (and ``late_s``,
``quiet_hours``), ``scheduled_busy``, ``scheduled_spoken``, ``scheduled_retry``, ``scheduled_done``,
``scheduled_cancelled``, ``scheduled_dropped``.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import logging
import math
import os
import re
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

from . import guidance, hermes, inject, policy

logger = logging.getLogger("hermes_voice")

FILE = "scheduled.json"
LOCK = "scheduled.lock"
RUNNER = "scheduled.runner"
VERSION = 1

# How far ahead a call can be scheduled, and how far in the past an ISO time may lie (it then rings now).
MAX_AHEAD_S = 7 * 24 * 3600.0
PAST_SLACK_S = 10.0
# Pending calls: per conversation, and on the host.
PER_CONVERSATION = 5
OVERALL = 20
# How often the runner looks at the schedule (and so how late a ring can be), and how often a dashboard that
# found another one ringing checks whether it can take over.
TICK_S = 1.0
RUNNER_RETRY_S = 3.0
# A ring later than this after its time counts as late (the conversation is told how late).
LATE_S = 60.0
# The user is on another call: try again this often, this many times.
BUSY_RETRY_S = 30.0
BUSY_TRIES = 6
# A ring that ended this way is repeated (``scheduled.retries``); a declined one is the user's answer.
RETRYABLE = frozenset({"no_answer", "unreachable", "push_failed"})
TEXT_PREVIEW = 80

FORMATS = ('at takes a clock time like "07:00" (24-hour; the next time it is 07:00) or an ISO date-time like '
           '"2026-01-31T07:00"; in_minutes takes a number of minutes from now')


# ── times ──────────────────────────────────────────────────────────────────────────────────────────────────

CLOCK = re.compile(r"(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?", re.IGNORECASE)


def zone_of(name: str) -> Any:
    """The tzinfo for a zone name, or None for the host's local time (also for a name nobody knows)."""
    if name:
        try:
            from zoneinfo import ZoneInfo
            return ZoneInfo(name)
        except Exception:  # noqa: BLE001 - an unknown zone: the host's local time
            logger.warning("hermes_voice: unknown timezone %r; using the host's local time", name)
    return None


def local(moment: float, zone: str = "") -> datetime:
    """`moment` (epoch seconds) on the clock the user reads: the zone's, else the host's."""
    tz = zone_of(zone)
    return datetime.fromtimestamp(moment, tz) if tz is not None else datetime.fromtimestamp(moment).astimezone()


def local_text(moment: float, zone: str = "") -> str:
    """A local date-time the agent can read back: ``2026-01-31 07:00``."""
    return local(moment, zone).strftime("%Y-%m-%d %H:%M")


def clock_text(moment: float, zone: str = "") -> str:
    return local(moment, zone).strftime("%H:%M")


def _wall(naive: datetime, zone: str) -> float:
    """A date-time without an offset, read on the zone's clock (else the host's)."""
    tz = zone_of(zone)
    return naive.replace(tzinfo=tz).timestamp() if tz is not None else naive.timestamp()


def span_text(seconds: float) -> str:
    """About how long: ``40 s``, ``10 min``, ``9 h 12 min``, ``2 days 3 h``."""
    seconds = max(0.0, seconds)
    if seconds < 90:
        return f"{max(1, round(seconds))} s"
    minutes = round(seconds / 60)
    if minutes < 60:
        return f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours} h {minutes} min" if minutes else f"{hours} h"
    days, hours = divmod(hours, 24)
    text = f"{days} day{'s' if days != 1 else ''}"
    return f"{text} {hours} h" if hours else text


def parse_when(in_minutes: Any, at: Any, now: float, zone: str = "") -> tuple[Optional[float], str]:
    """When a scheduled call rings (epoch seconds), or None and what is wrong with the time, for the agent.

    ``in_minutes``: a number above 0 (fractions allowed). ``at``: ``HH:MM`` (24-hour, or with am / pm) is the next
    time the clock shows that; an ISO 8601 date-time is that moment (one without an offset is read on the same
    clock). The clock is `zone`'s (the policy's quiet-hours zone), else the host's. At most ``MAX_AHEAD_S`` ahead;
    an ISO time up to ``PAST_SLACK_S`` in the past rings now."""
    has_minutes, has_at = given(in_minutes), given(at)
    if has_minutes and has_at:
        return None, "Give either in_minutes or at, not both."
    if not has_minutes and not has_at:
        return None, f"No time given: {FORMATS}."
    if has_minutes:
        minutes = _number(in_minutes)
        if not math.isfinite(minutes) or minutes <= 0:
            return None, "in_minutes must be a number above 0, for example 10 for \"in ten minutes\"."
        moment: Optional[float] = now + minutes * 60.0
    else:
        if not isinstance(at, str):
            return None, f"at must be a string: {FORMATS}."
        moment, problem = _parse_at(at.strip(), now, zone)
        if moment is None:
            return None, problem
    assert moment is not None
    if moment > now + MAX_AHEAD_S:
        return None, (f"That is more than {round(MAX_AHEAD_S / 86400)} days ahead ({local_text(moment, zone)}); a "
                      "call can be scheduled at most that far ahead.")
    return moment, ""


def _parse_at(text: str, now: float, zone: str) -> tuple[Optional[float], str]:
    here = local(now, zone)
    match = CLOCK.fullmatch(text)
    if match and (match.group(2) is not None or match.group(4)):
        hour, minute, second = int(match.group(1)), int(match.group(2) or 0), int(match.group(3) or 0)
        half = (match.group(4) or "").lower().replace(".", "")
        if half:
            if not 1 <= hour <= 12:
                return None, f"{text!r} is not a clock time: {FORMATS}."
            hour = hour % 12 + (12 if half == "pm" else 0)
        if hour > 23 or minute > 59 or second > 59:
            return None, f"{text!r} is not a clock time: {FORMATS}."
        day = here.replace(tzinfo=None, hour=hour, minute=minute, second=second, microsecond=0)
        moment = _wall(day, zone)
        if moment <= now:  # that time has passed today: the next time the clock shows it
            moment = _wall(day + timedelta(days=1), zone)
        return moment, ""
    try:
        parsed = datetime.fromisoformat(text[:-1] + "+00:00" if text[-1:] in ("Z", "z") else text)
    except ValueError:
        return None, f"Can't read the time {text[:40]!r}: {FORMATS}. It is now {local_text(now, zone)}."
    if len(text) <= 10:
        return None, f"{text!r} has no time of day: {FORMATS}."
    moment = parsed.timestamp() if parsed.tzinfo is not None else _wall(parsed, zone)
    if moment < now - PAST_SLACK_S:
        return None, (f"That time is in the past ({local_text(moment, zone)}); it is now {local_text(now, zone)}. "
                      "Give a later time, or in_minutes.")
    return max(moment, now), ""


def given(value: Any) -> bool:
    """Whether a tool argument was really passed (models send null or "" for the ones they leave out)."""
    return value is not None and not (isinstance(value, str) and not value.strip())


def wants_later(in_minutes: Any, at: Any) -> bool:
    """Whether a ``start_call`` asks for a later ring. ``in_minutes: 0`` with no ``at`` is a call now: a model
    that fills in every parameter means "in no minutes" by it."""
    if given(at):
        return True
    return given(in_minutes) and _number(in_minutes) != 0


def _number(value: Any) -> float:
    """``in_minutes`` as a number (also from "10" or "10 min"); NaN for anything else."""
    if isinstance(value, bool):
        return math.nan
    if isinstance(value, str):
        value = re.sub(r"\s*(m|min|mins|minute|minutes)\.?\s*$", "", value.strip(), flags=re.IGNORECASE)
    try:
        return float(value)
    except (TypeError, ValueError):
        return math.nan


# ── the file ───────────────────────────────────────────────────────────────────────────────────────────────


@dataclass
class Entry:
    """One scheduled call."""

    id: str
    text: str
    rings_at: float  # the time the user asked for
    due_at: float  # the next ring: rings_at, then a retry's time
    created_at: float
    session_id: str
    # Every stored id the conversation had (compression rotates it), and Hermes' route key for it.
    session_ids: list[str] = field(default_factory=list)
    session_key: str = ""
    profile: str = "default"
    profile_home: Optional[str] = None
    title: str = ""
    source: str = ""  # where the conversation runs (policy._surface)
    zone: str = ""  # the zone its time was given in ("": the host's)
    rings: list[float] = field(default_factory=list)  # when it rang
    busy_tries: int = 0
    call_id: str = ""  # the ring in progress

    @classmethod
    def parse(cls, raw: Any) -> Optional["Entry"]:
        if not isinstance(raw, dict):
            return None
        try:
            entry = cls(
                id=str(raw["id"]), text=str(raw["text"]), rings_at=float(raw["rings_at"]),
                due_at=float(raw["due_at"]), created_at=float(raw.get("created_at") or 0.0),
                session_id=str(raw["session_id"]),
                session_ids=[str(v) for v in raw.get("session_ids") or [] if v],
                session_key=str(raw.get("session_key") or ""), profile=str(raw.get("profile") or "default"),
                profile_home=str(raw["profile_home"]) if raw.get("profile_home") else None,
                title=str(raw.get("title") or ""), source=str(raw.get("source") or ""),
                zone=str(raw.get("zone") or ""), rings=[float(v) for v in raw.get("rings") or []],
                busy_tries=int(raw.get("busy_tries") or 0), call_id=str(raw.get("call_id") or ""),
            )
        except (KeyError, TypeError, ValueError):
            return None
        if not entry.id or not entry.session_id or not entry.text.strip():
            return None
        if entry.session_id not in entry.session_ids:
            entry.session_ids.append(entry.session_id)
        return entry

    def copy(self) -> "Entry":
        return replace(self, session_ids=list(self.session_ids), rings=list(self.rings))

    def belongs(self, origin: hermes.Origin) -> bool:
        if origin.session_id and origin.session_id in self.session_ids:
            return True
        return bool(origin.session_key and origin.session_key == self.session_key)

    def brief(self) -> dict[str, Any]:
        """The entry as a tool result lists it."""
        text = " ".join(self.text.split())
        return {"scheduled_id": self.id, "rings_at": local_text(self.rings_at, self.zone),
                "text": text if len(text) <= TEXT_PREVIEW else text[:TEXT_PREVIEW].rstrip() + "…"}


class Store:
    """``scheduled.json``: read whole, changed under a file lock, written atomically."""

    def __init__(self, folder: Callable[[], Path]) -> None:
        self.folder = folder
        self.lock = threading.RLock()
        # What the file said when it last looked like this (st_mtime_ns, st_size, st_ino).
        self.cache: Optional[tuple[tuple[int, int, int], list[Entry]]] = None

    def path(self) -> Path:
        return Path(self.folder()) / FILE

    def entries(self) -> list[Entry]:
        """What is scheduled now (copies)."""
        with self.lock:
            return [entry.copy() for entry in self._read()]

    def mutate(self, change: Callable[[list[Entry]], Any]) -> Any:
        """Run `change` on the entries as they are on disk and write them back if it changed them. Returns what
        `change` returned. Raises OSError when the folder can't be written."""
        with self.lock, self._locked():
            self.cache = None
            entries = self._read()
            before = [asdict(entry) for entry in entries]
            result = change(entries)
            if [asdict(entry) for entry in entries] != before:
                self._write(entries)
            return result

    @contextlib.contextmanager
    def _locked(self) -> Iterator[None]:
        folder = Path(self.folder())
        folder.mkdir(parents=True, exist_ok=True)
        fd = os.open(folder / LOCK, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)  # closing releases the lock

    def _read(self) -> list[Entry]:
        path = self.path()
        try:
            info = os.stat(path)
        except OSError:
            self.cache = None
            return []
        signature = (info.st_mtime_ns, info.st_size, info.st_ino)
        if self.cache is not None and self.cache[0] == signature:
            return [entry.copy() for entry in self.cache[1]]
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            raw = data["calls"] if isinstance(data, dict) else None
            if not isinstance(raw, list):
                raise ValueError("no calls list")
        except (OSError, ValueError, KeyError):
            logger.warning("hermes_voice: %s is unreadable; kept as %s.broken, starting with no scheduled calls",
                           path, FILE)
            with contextlib.suppress(OSError):
                os.replace(path, path.with_name(f"{FILE}.broken"))
            self.cache = None
            return []
        entries = [entry for entry in (Entry.parse(item) for item in raw) if entry is not None]
        if len(entries) != len(raw):
            logger.warning("hermes_voice: ignored %d malformed scheduled call(s) in %s", len(raw) - len(entries), path)
        self.cache = (signature, [entry.copy() for entry in entries])
        return entries

    def _write(self, entries: list[Entry]) -> None:
        path = self.path()
        self.cache = None
        if not entries:
            with contextlib.suppress(FileNotFoundError):
                path.unlink()
            return
        temp = path.with_name(f".{FILE}.{os.getpid()}.tmp")
        body = json.dumps({"version": VERSION, "calls": [asdict(entry) for entry in entries]}, ensure_ascii=False,
                          indent=1)
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, body.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(temp, 0o600)
        os.replace(temp, path)


# ── one ring ───────────────────────────────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Ring:
    """One ring of a scheduled call (``Call.scheduled``)."""

    id: str
    call_id: str
    text: str
    rings_at: float
    zone: str = ""
    attempt: int = 1
    # How late this ring is (0.0 unless more than ``LATE_S``).
    late_s: float = 0.0
    # When it rang before, unanswered.
    earlier: tuple[float, ...] = ()
    # A messaging chat: the dashboard never reopens it, so only its own process can take the call's turns.
    remote: bool = False


@dataclass(frozen=True)
class Over:
    """What the end of a scheduled ring means: it rings `again` (the conversation hears nothing yet), or `note`
    goes after the call's notice."""

    again: bool = False
    note: str = ""


def started_notice(ring: Ring, call_id: str, style: str = "") -> str:
    """The notice a conversation gets when the user answers the call it scheduled."""
    when = local_text(ring.rings_at, ring.zone)
    late = (f" It rang about {span_text(ring.late_s)} late: Hermes was not running (or the host was asleep) at the "
            "scheduled time. Say so if it matters." if ring.late_s else "")
    earlier = (f" They did not answer the ring at {_times(ring.earlier, ring.zone)}; this is the repeat."
               if ring.earlier else "")
    return (
        f"[Voice call started] {inject.NOTICE_HEAD} The user answered the call you scheduled for {when} "
        f"(scheduled_id {ring.id}, call {call_id}) and is hearing the line you gave then: "
        f"{guidance.quote_lines([ring.text])}.{late}{earlier} Don't speak yet: wait for their reply, which arrives "
        "as a message starting with \"[Voice]\", and answer that with start_call (your text replies are not "
        f"spoken). Hang up with end_call.{' ' + style if style else ''}"
    )


def _times(moments: Any, zone: str) -> str:
    """Clock times in a sentence: ``07:00``, ``07:00 and 07:05``, ``07:00, 07:05 and 07:10``."""
    times = [clock_text(at, zone) for at in moments]
    return times[0] if len(times) == 1 else f"{', '.join(times[:-1])} and {times[-1]}"


def unanswered_note(entry: Entry) -> str:
    """What follows the notice of a scheduled call nobody took (with a leading space)."""
    return (f" This was the call you scheduled for {local_text(entry.rings_at, entry.zone)} (scheduled_id "
            f"{entry.id}): it was tried at {_times(entry.rings, entry.zone)}, and will not be tried again by itself. "
            f"Its line was: {guidance.quote_lines([entry.text])}.")


def dropped_notice(entry: Entry, why: str) -> str:
    """The notice for a scheduled call that was never placed."""
    when = local_text(entry.rings_at, entry.zone)
    what = "was not placed"
    if entry.rings:  # it rang, nobody answered, and the repeat is what could not be placed
        what = f"rang at {_times(entry.rings, entry.zone)} without an answer, and its repeat was not placed"
    return (
        f"[Voice call not placed: scheduled for {when}] {inject.NOTICE_HEAD} The call you scheduled for {when} "
        f"(scheduled_id {entry.id}) {what}: {why}. Nothing was spoken; its line was: "
        f"{guidance.quote_lines([entry.text])}. Tell the user in text what happened and what the call was for. "
        "Schedule a new call only if they ask."
    )


def spoken_notice(entry: Entry) -> str:
    """The notice for a scheduled line said into a call the conversation was already on."""
    return (
        f"[Voice line spoken: the call scheduled for {local_text(entry.rings_at, entry.zone)}] "
        f"{inject.NOTICE_MARKER} {inject.THIS_LINE_ONLY} The user is on a call with this conversation, so the line "
        f"you scheduled (scheduled_id {entry.id}) was said into it without ringing: "
        f"{guidance.quote_lines([entry.text])}."
    )


# ── the scheduler ──────────────────────────────────────────────────────────────────────────────────────────


class Scheduler:
    """The hub's schedule: takes calls to ring later, and (in the dashboard process) rings them."""

    def __init__(self, hub: Any, folder: Optional[Callable[[], Path]] = None,
                 clock: Optional[Callable[[], float]] = None) -> None:
        self.hub = hub
        self.store = Store(folder or (lambda: Path(getattr(hub.policy, "log_dir", hermes.state_dir)())))
        self._clock = clock
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.stopping = threading.Event()
        self.thread: Optional[threading.Thread] = None
        self.runner_fd: Optional[int] = None

    def clock(self) -> float:
        if self._clock is not None:
            return self._clock()
        return getattr(self.hub.policy, "clock", time.time)()

    def zone(self) -> str:
        """The clock times are given and shown on: the policy's quiet-hours zone, else the host's ("")."""
        quiet = self.hub.settings().policy.quiet_hours
        name = quiet.timezone if quiet is not None else ""
        return name if name and zone_of(name) is not None else ""

    # ── the tools ────────────────────────────────────────────────────────────────────────────────────────

    def schedule(self, origin: hermes.Origin, text: str, in_minutes: Any = None, at: Any = None) -> dict[str, Any]:
        """``start_call`` with a time: ``{status: "scheduled", scheduled_id, rings_at, note, pending}``, a refusal
        (``status: "not_allowed"``) or ``{error}`` for a time that can't be used."""
        settings = self.hub.settings()
        if not origin.session_id:
            return _refused("This conversation can't place a call.")
        decision = self.hub.policy.check_schedule(origin)
        if not decision.allowed:
            return _refused(decision.note)
        now, zone = self.clock(), self.zone()
        rings_at, problem = parse_when(in_minutes, at, now, zone)
        if rings_at is None:
            return {"error": problem}
        text, clip_note = _clip(text, settings.max_chars)
        surface = policy._surface(origin)
        entry = Entry(
            id=f"sc-{uuid.uuid4().hex[:8]}", text=text, rings_at=rings_at, due_at=rings_at, created_at=now,
            session_id=origin.session_id, session_ids=[origin.session_id], session_key=origin.session_key,
            profile=origin.profile or "default", profile_home=origin.profile_home, title=origin.title,
            source=surface, zone=zone,
        )

        def add(entries: list[Entry]) -> str:
            if sum(1 for other in entries if other.belongs(origin)) >= PER_CONVERSATION:
                return "conversation"
            if len(entries) >= OVERALL:
                return "host"
            entries.append(entry)
            return ""

        try:
            full = self.store.mutate(add)
        except OSError as error:
            logger.warning("hermes_voice: could not store a scheduled call", exc_info=True)
            return {"error": f"The call could not be scheduled: the schedule file can't be written "
                             f"({type(error).__name__}). Tell the user."}
        if full:
            limit = (f"this conversation already has {PER_CONVERSATION} calls scheduled" if full == "conversation"
                     else f"{OVERALL} calls are already scheduled on this host")
            return {"status": "not_allowed", "scheduled_id": None, "pending": self.pending(origin),
                    "note": f"Not scheduled: {limit}. Cancel one first with end_call and its scheduled_id."}
        self.hub.policy.log({"event": "scheduled", "scheduled": entry.id, "session_id": origin.session_id,
                             "source": surface, "rings_at": _iso(rings_at)})
        logger.info("hermes_voice: call %s scheduled for %s by %s", entry.id, local_text(rings_at, zone),
                    origin.session_id)
        self.wake.set()
        cfg = settings.scheduled
        retry = (f"If they don't answer it rings again after {span_text(cfg.retry_after_s)}"
                 f"{f' (up to {cfg.retries} times)' if cfg.retries > 1 else ''}, then you get a notice."
                 if cfg.retries else "If they don't answer you get a notice.")
        note = (
            f"Scheduled: the phone rings at {entry.brief()['rings_at']} ({zone or 'host time'}), in "
            f"about {span_text(rings_at - now)}, by itself: tell the user the time, and don't wait for it. Your line "
            "is spoken once they answer. mode is ignored for a scheduled call: what they say then arrives as "
            f"[Voice] messages; answer them with start_call. {retry} Cancel with end_call and scheduled_id "
            f"\"{entry.id}\"."
            f"{self._warnings(rings_at, surface)}{clip_note}{guidance.long_line_note(text)}"
        )
        return {"status": "scheduled", "scheduled_id": entry.id, "rings_at": entry.brief()["rings_at"],
                "note": note, "pending": self.pending(origin)}

    def _warnings(self, rings_at: float, surface: str) -> str:
        """What the agent should know now about a ring that is still to come (each with a leading space)."""
        notes = ""
        quiet = self.hub.settings().policy.quiet_hours
        if quiet is not None and policy.in_quiet_hours(quiet, rings_at):
            notes += " That is inside the user's quiet hours; a call they asked for rings anyway."
        try:
            ready, reason = self.hub.pusher.configured()
            store = getattr(self.hub.pusher, "store", None)
            if ready and store is not None and not store.devices():
                ready, reason = False, "no iPhone has registered for calls yet"
        except Exception:  # noqa: BLE001 - a check must never fail the scheduling
            ready, reason = True, ""
        if not ready:
            notes += (f" Warning: the phone can't be rung as things are ({reason or 'push is not set up'}); tell "
                      "the user, or the call won't ring.")
        if policy.is_messaging(surface):
            notes += (" Note: this chat runs in the messaging gateway, and what the user says on that call can't "
                      "be put into it; put everything they need into the line.")
        return notes

    def cancel(self, origin: hermes.Origin, which: Any) -> dict[str, Any]:
        """``end_call`` with ``scheduled_id``: cancel one of the conversation's scheduled calls, ``"all"`` of them,
        or only ``"list"`` them. Returns ``{cancelled, pending, note}``; never hangs anything up."""
        wanted = str(which or "").strip()
        key = wanted.lower()
        if key == "list":
            pending = self.pending(origin)
            return {"cancelled": [], "pending": pending,
                    "note": f"{_count(len(pending))} scheduled in this conversation. Nothing was changed."}

        def remove(entries: list[Entry]) -> list[Entry]:
            mine = [entry for entry in entries if entry.belongs(origin)
                    and (key == "all" or entry.id.lower() in (key, f"sc-{key}"))]
            for entry in mine:
                entries.remove(entry)
            return mine

        try:
            removed = self.store.mutate(remove)
        except OSError:
            logger.warning("hermes_voice: could not change the schedule file", exc_info=True)
            return {"error": "The scheduled call could not be cancelled: the schedule file can't be written."}
        for entry in removed:
            self.hub.policy.log({"event": "scheduled_cancelled", "scheduled": entry.id,
                                 "session_id": origin.session_id})
        pending = self.pending(origin)
        if removed:
            ringing = any(entry.call_id for entry in removed)
            note = (f"Cancelled {_count(len(removed))}; nothing was hung up."
                    f"{' One of them is ringing right now: end_call without scheduled_id hangs up.' if ringing else ''}"
                    + (f" {_count(len(pending))} still scheduled in this conversation." if pending
                       else " Nothing else is scheduled in this conversation."))
        elif key == "all":
            note = "This conversation has no calls scheduled."
        else:
            note = (f"This conversation has no scheduled call {wanted[:40]!r}; nothing was cancelled. "
                    f"{_count(len(pending))} scheduled here (see pending).")
        return {"cancelled": [entry.id for entry in removed], "pending": pending, "note": note}

    def pending(self, origin: hermes.Origin) -> list[dict[str, Any]]:
        """The conversation's scheduled calls, soonest first, as tool results list them."""
        try:
            mine = [entry for entry in self.store.entries() if entry.belongs(origin)]
        except OSError:
            return []
        return [entry.brief() for entry in sorted(mine, key=lambda entry: entry.rings_at)]

    def count(self) -> int:
        try:
            return len(self.store.entries())
        except OSError:
            return 0

    def rekey(self, old: str, new: str) -> None:
        """The conversation `old` continues as `new` (compression): its scheduled calls follow."""
        if not old or not new or old == new:
            return
        try:
            if not any(old in entry.session_ids for entry in self.store.entries()):
                return

            def move(entries: list[Entry]) -> None:
                for entry in entries:
                    if old in entry.session_ids and new not in entry.session_ids:
                        entry.session_ids.append(new)
                        entry.session_id = new

            self.store.mutate(move)
        except OSError:
            logger.debug("hermes_voice: could not rekey scheduled calls", exc_info=True)

    # ── ringing (the dashboard process) ──────────────────────────────────────────────────────────────────

    def start(self) -> None:
        """Ring what is due from now on (once; the dashboard process)."""
        with self.lock:
            if self.thread is not None and self.thread.is_alive():
                return
            self.stopping.clear()
            self.thread = hermes.spawn_thread(self._run, name="hermes-voice-schedule")

    def stop(self) -> None:
        """Stop ringing (the plugin unloads); what is scheduled stays in the file."""
        with self.lock:
            thread, self.thread = self.thread, None
        self.stopping.set()
        self.wake.set()
        if thread is not None and thread is not threading.current_thread():
            thread.join(TICK_S + 2.0)
        self._release()

    def running(self) -> bool:
        return self.runner_fd is not None

    def _run(self) -> None:
        warned = False
        failed_at = 0.0
        try:
            while not self.stopping.is_set():
                nap = TICK_S
                try:
                    if self._take():
                        self.tick()
                        nap = self._nap()
                    else:
                        nap = RUNNER_RETRY_S
                        if not warned:
                            logger.warning("hermes_voice: another Hermes dashboard rings this home's scheduled "
                                           "calls; this one takes over when it stops")
                            warned = True
                except Exception:  # noqa: BLE001 - one bad entry or a full disk must not stop the schedule
                    if time.monotonic() - failed_at > 60.0:  # said once a minute, not on every tick
                        logger.warning("hermes_voice: the call schedule failed a tick", exc_info=True)
                        failed_at = time.monotonic()
                self.wake.wait(nap)
                self.wake.clear()
        finally:
            self._release()

    def _nap(self) -> float:
        try:
            due = [entry.due_at for entry in self.store.entries() if not entry.call_id]
        except OSError:
            return TICK_S
        return min(TICK_S, max(0.05, min(due) - self.clock())) if due else TICK_S

    def _take(self) -> bool:
        """Be the one dashboard that rings for this folder. On taking over, rings that a dashboard which is gone
        left in progress are due again (their lateness decides what happens to them)."""
        if self.runner_fd is not None:
            return True
        try:
            folder = Path(self.store.folder())
            folder.mkdir(parents=True, exist_ok=True)
            fd = os.open(folder / RUNNER, os.O_RDWR | os.O_CREAT, 0o600)
        except OSError:
            logger.warning("hermes_voice: can't open the schedule's runner lock", exc_info=True)
            return False
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return False
        self.runner_fd = fd
        try:
            self.recover()
            waiting = self.count()
            if waiting:
                logger.info("hermes_voice: %d scheduled call(s) waiting", waiting)
        except Exception:  # noqa: BLE001
            logger.warning("hermes_voice: could not look through the scheduled calls", exc_info=True)
        return True

    def _release(self) -> None:
        fd, self.runner_fd = self.runner_fd, None
        if fd is not None:
            with contextlib.suppress(OSError):
                os.close(fd)

    def recover(self) -> None:
        """Rings marked as in progress that this hub knows nothing of (the dashboard stopped mid-ring) are due
        again."""
        hub = self.hub
        with hub.lock:
            known = set(hub.history) | ({hub.slot.call_id} if hub.slot is not None else set())

        def reset(entries: list[Entry]) -> None:
            for entry in entries:
                if entry.call_id and entry.call_id not in known:
                    entry.call_id = ""

        self.store.mutate(reset)

    def tick(self) -> int:
        """Ring every call that is due (soonest first). Returns how many were handled."""
        now = self.clock()
        due = [entry for entry in self.store.entries() if not entry.call_id and entry.due_at <= now]
        for entry in sorted(due, key=lambda entry: entry.due_at):
            self._fire(entry, now)
        return len(due)

    def _fire(self, entry: Entry, now: float) -> None:
        cfg = self.hub.settings().scheduled
        late_s = max(0.0, now - entry.due_at)
        if late_s > max(cfg.late_limit_s, LATE_S):
            self._drop(entry, "late", (
                f"Hermes was not running (or the host was asleep) at that time and was back about "
                f"{span_text(late_s)} late, more than the {span_text(cfg.late_limit_s)} a late call may still "
                "ring after"), late_s=round(late_s))
            return
        call_id = uuid.uuid4().hex

        def claim(entries: list[Entry]) -> Optional[Entry]:
            mine = _find(entries, entry.id)
            if mine is None or mine.call_id or mine.due_at > now:
                return None  # cancelled or taken meanwhile
            mine.call_id = call_id
            mine.rings.append(now)
            return mine.copy()

        claimed = self.store.mutate(claim)
        if claimed is None:
            return
        ring = Ring(id=claimed.id, call_id=call_id, text=claimed.text, rings_at=claimed.rings_at, zone=claimed.zone,
                    attempt=len(claimed.rings), late_s=late_s if late_s > LATE_S else 0.0,
                    earlier=tuple(claimed.rings[:-1]), remote=policy.is_messaging(claimed.source))
        try:
            begun = self.hub.begin_call(self.origin_of(claimed), claimed.text, "async", scheduled=ring)
            status, call = str(begun.result.get("status") or ""), begun.call
        except Exception:  # noqa: BLE001 - tried again like a busy line
            logger.warning("hermes_voice: ringing scheduled call %s failed", claimed.id, exc_info=True)
            status, call = "busy", None
        if call is not None and call.call_id == call_id:
            return  # it rings (or its push already failed): ring_over says how it went
        if status == "speaking" and call is not None:
            self.store.mutate(lambda entries: _remove(entries, claimed.id, call_id))
            self.hub.policy.log({"event": "scheduled_spoken", "scheduled": claimed.id, "call_id": call.call_id,
                                 "session_id": claimed.session_id})
            call.inbox.put(spoken_notice(claimed), open_only=True)
            return

        def back(entries: list[Entry]) -> Optional[tuple[bool, Entry]]:
            mine = _find(entries, claimed.id)
            if mine is None or mine.call_id != call_id:
                return None
            mine.call_id = ""
            mine.rings.pop()
            mine.busy_tries += 1
            if mine.busy_tries > BUSY_TRIES:
                return False, mine.copy()
            mine.due_at = now + BUSY_RETRY_S
            return True, mine.copy()

        result = self.store.mutate(back)
        if result is None:
            return
        again, current = result
        if again:
            self.hub.policy.log({"event": "scheduled_busy", "scheduled": current.id,
                                 "session_id": current.session_id, "try": current.busy_tries})
            return
        self._drop(current, "busy", (
            f"the user was on another call at that time, and still was {BUSY_TRIES} tries and about "
            f"{span_text(BUSY_TRIES * BUSY_RETRY_S)} later"))

    def _drop(self, entry: Entry, reason: str, why: str, **more: Any) -> None:
        if self.store.mutate(lambda entries: _remove(entries, entry.id, "")) is None:
            return
        logger.warning("hermes_voice: scheduled call %s for %s dropped (%s)", entry.id,
                       local_text(entry.rings_at, entry.zone), reason)
        self.hub.policy.log({"event": "scheduled_dropped", "scheduled": entry.id, "session_id": entry.session_id,
                             "reason": reason, **more})
        self.hub.tell(self.origin_of(entry), dropped_notice(entry, why), remote=policy.is_messaging(entry.source))

    def origin_of(self, entry: Entry) -> hermes.Origin:
        """The entry's conversation as it is now: live in this process (then with its runtime session), or only
        stored."""
        found = hermes.find_live(entry.session_id)
        record = found[1] if found is not None else {}
        messaging = policy.is_messaging(entry.source)
        return hermes.Origin(
            session_id=entry.session_id, runtime_sid=found[0] if found is not None else "",
            profile=entry.profile or "default",
            profile_home=str(record.get("profile_home")) if record.get("profile_home") else entry.profile_home,
            title=(hermes.session_title(found[0], found[1]) if found is not None else "") or entry.title,
            source="" if messaging else entry.source,
            platform=entry.source if messaging else "", chat_type="dm" if messaging else "",
            session_key=entry.session_key,
        )

    def ring_log(self, ring: Ring) -> dict[str, Any]:
        """What the ring log says about a scheduled ring, beside the ring itself."""
        entry: dict[str, Any] = {"scheduled": ring.id, "attempt": ring.attempt}
        if ring.late_s:
            entry["late_s"] = round(ring.late_s)
        quiet = self.hub.settings().policy.quiet_hours
        if quiet is not None and policy.in_quiet_hours(quiet, self.clock()):
            entry["quiet_hours"] = True
        return entry

    # ── what the hub tells the schedule ──────────────────────────────────────────────────────────────────

    def answered(self, call: Any) -> str:
        """The user answered a scheduled ring: the call is done with the schedule. Returns the notice for its
        conversation."""
        ring: Ring = call.scheduled
        try:
            self.store.mutate(lambda entries: _remove(entries, ring.id, call.call_id))
            self.hub.policy.log({"event": "scheduled_done", "scheduled": ring.id, "call_id": call.call_id,
                                 "outcome": "answered", "rings": ring.attempt})
        except Exception:  # noqa: BLE001 - the call goes on; ring_over takes it off the schedule when it ends
            logger.warning("hermes_voice: could not take an answered call off the schedule", exc_info=True)
        from .hub import _style_for
        return started_notice(ring, call.call_id, _style_for(call))

    def ring_over(self, call: Any, outcome: str) -> Over:
        """A scheduled ring ended (any thread; never raises). Not answered and with retries left, it rings again;
        else the entry is done, and the conversation's notice says which scheduled call that was."""
        try:
            return self._ring_over(call, outcome)
        except Exception:  # noqa: BLE001 - the call's end must go through whatever the schedule file does
            logger.warning("hermes_voice: could not update the schedule after a ring", exc_info=True)
            return Over()

    def _ring_over(self, call: Any, outcome: str) -> Over:
        ring: Ring = call.scheduled
        if call.answered_at is not None:
            # Answered: off the schedule since then (again here, should that write have failed).
            self.store.mutate(lambda entries: _remove(entries, ring.id, call.call_id))
            return Over()
        cfg = self.hub.settings().scheduled
        now = self.clock()

        def settle(entries: list[Entry]) -> Optional[tuple[bool, Entry]]:
            mine = _find(entries, ring.id)
            if mine is None or mine.call_id != call.call_id:
                return None  # cancelled while it rang
            mine.call_id = ""
            if outcome in RETRYABLE and len(mine.rings) <= cfg.retries:
                mine.due_at = now + cfg.retry_after_s
                mine.busy_tries = 0
                return True, mine.copy()
            entries.remove(mine)
            return False, mine.copy()

        result = self.store.mutate(settle)
        if result is None:
            return Over()
        again, entry = result
        if again:
            self.hub.policy.log({"event": "scheduled_retry", "scheduled": entry.id, "call_id": call.call_id,
                                 "outcome": outcome, "next": _iso(entry.due_at)})
            self.wake.set()
            return Over(again=True)
        self.hub.policy.log({"event": "scheduled_done", "scheduled": entry.id, "call_id": call.call_id,
                             "outcome": outcome, "rings": len(entry.rings)})
        return Over(note=unanswered_note(entry))


def _find(entries: list[Entry], entry_id: str) -> Optional[Entry]:
    return next((entry for entry in entries if entry.id == entry_id), None)


def _remove(entries: list[Entry], entry_id: str, call_id: str) -> Optional[Entry]:
    """Take the entry out (when `call_id` is given: only while that ring is the one in progress)."""
    entry = _find(entries, entry_id)
    if entry is None or (call_id and entry.call_id != call_id):
        return None
    entries.remove(entry)
    return entry


def _refused(note: str) -> dict[str, Any]:
    return {"status": "not_allowed", "scheduled_id": None, "note": note}


def _clip(text: str, limit: int) -> tuple[str, str]:
    """The line cut to `limit` characters, and a note for the agent when it was cut."""
    from .hub import clip
    whole = len(text.strip())
    text, cut = clip(text, limit)
    return text, (f" Only the first {len(text)} of {whole} characters will be spoken; the rest was cut." if cut
                  else "")


def _count(number: int) -> str:
    return f"{number} call{'s' if number != 1 else ''}" if number else "No calls"


def _iso(moment: float) -> str:
    return datetime.fromtimestamp(moment, timezone.utc).isoformat(timespec="seconds")
