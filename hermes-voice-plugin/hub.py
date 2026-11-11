"""The call hub: one call slot per process, the phone's WebSocket, speech streaming and turn routing.

There is one global call slot ``{call_id, owner, state ringing|live|ended, waiter?}``. The owner is the
conversation the call belongs to (its stored session id, every id it had since compression rotated it, and its live
runtime session); only it can speak into the call, and any other conversation that tries gets ``busy``.

Phone protocol on ``/api/plugins/hermes_voice/phone`` (JSON text frames plus binary PCM):

- phone ``hello {call_id, session_id?, title?, initiated_by, app_version}`` -> ``ready {call_id, state}``
- phone ``ringing`` / ``answered`` / ``declined`` while ringing; plugin ``cancel {reason}`` ends a ring
- plugin ``speech_start {id, text, sample_rate, format}``, PCM frames, ``speech_end {id}`` (or with
  ``cancelled: true`` / ``error``); the phone answers a normal end with ``played {id}`` once it was heard
- phone ``user_turn {call_id, text, ending {kind, ...}, provider, language?, started_at, ended_at}``
- plugin ``location_request {id}`` -> phone ``location {id, latitude, longitude, accuracy_m, fixed_at, ...}`` or
  ``location {id, error}`` (``location.py``: the ``get_location`` tool, when the phone shares its location)
- phone ``ping`` -> ``pong``; phone ``bye {reason?}`` hangs up (``hang_up``, ``declined``, ``no_answer`` when its own
  ring timeout ran out, ``error``); plugin ``ended {outcome}`` when it ends the call
- close codes: 4401 auth, 4400 bad hello, 4409 replaced by a newer link for the call, 4429 another conversation
  holds the call slot, 1011 the link stopped taking frames (the phone reconnects)

Turn routing: a sync ``start_call`` waiting on the call takes the first turn that reached the plugin after the
phone confirmed its line played (``Waiter.accepts``); every other turn is force-injected into the owner's
conversation (``inject.py``).

The hub lives in the dashboard process. Conversations in other Hermes processes reach it over a local socket
(``hubsock.py``, opened once the dashboard serves): their calls carry a ``route`` that hands each turn to the
conversation's own process, which injects it there (``remote.py``).

A chat another Hermes process holds (Hermes keeps one writer per conversation; typically a Desktop backend that
has the chat open while the user calls from the app): this process's ``prompt.submit`` is refused (``Delivery.held``).
The turn then goes to the process that holds the chat, when it runs this plugin (``holders``: it attends on the hub
socket and injects into its own live session). Otherwise it stays at the head of the call's queue and is tried again
every ``HELD_RETRY_S`` for ``HELD_RETRY_LIMIT_S`` (later turns wait behind it, so order holds and nothing is put in
twice), the user hears once per call that the chat can't be reached (``inject.CHAT_HELD_SPOKEN``, the hub's own
line), and the ring log says ``chat_held``, then ``delivered_late`` or ``undelivered``: never silence.

Calls that ring later (``start_call`` with ``in_minutes`` / ``at``) are kept and rung by ``schedule.py``
(``CallHub.schedule``): at its time a scheduled call claims the slot like any other (``begin_call`` with
``scheduled``), without asking the policy again.

Threads: tool handlers run on agent threads, the socket on the dashboard's event loop (captured on the first
request). Call state is guarded by ``lock``; links and speech run on the loop only.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sys
import threading
import time
import uuid
from collections import OrderedDict, deque
from contextlib import aclosing
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Optional

from . import guidance, hermes, inject, push, schedule
from .config import Settings
from .config import current as current_settings
from .policy import Policy, is_messaging, users_own_message
from .tts import SAMPLE_RATE, ElevenLabs, TextToSpeech

try:
    from starlette.websockets import WebSocketDisconnect
except ImportError:  # pragma: no cover - Hermes always ships Starlette

    class WebSocketDisconnect(Exception):  # type: ignore[no-redef]
        def __init__(self, code: int = 1000) -> None:
            super().__init__(code)
            self.code = code


logger = logging.getLogger("hermes_voice")

# Time allowed beyond the audio's own length for the phone to confirm it played.
PLAYBACK_MARGIN = 15.0
# Upper bound on speaking one line.
PLAYBACK_WAIT_LIMIT = 270.0
# How long a line waits for a dropped phone link to come back before giving up on it.
RECONNECT_GRACE = 6.0
# How long a dropped link keeps the call (and its pending acks) for a reconnect; past it the call is lost.
DROP_RETENTION = 60.0
HELLO_TIMEOUT = 15.0
# Bound on the send that tells the phone a failed or cancelled line is over; past it the link is stalled.
NOTICE_TIMEOUT = 2.0
# A link that takes no frame for this long has stopped reading (a half-open path): it is dropped.
SEND_TIMEOUT = 5.0
# How long end_call waits for its goodbye to be heard.
GOODBYE_WAIT = 60.0
# How far the phone's clock (a turn's started_at) may be behind the host's.
TURN_CLOCK_SLACK = 1.0
HISTORY_LIMIT = 50
# How long after the dashboard's import the hub waits for it to serve before opening its socket.
SOCKET_WAIT_LIMIT = 600.0
# A delivery refused because another Hermes process holds the chat is tried again this often, for this long after
# it was queued (the lease goes when that process closes the chat or exits); then it is given up and logged.
HELD_RETRY_S = 3.0
HELD_RETRY_LIMIT_S = 120.0
# How long the line that tells the user waits for the phone's link (a call the user starts fails its first
# delivery while the link is still coming up).
HELD_LINK_WAIT = 5.0

OUTCOMES = frozenset({
    "answered", "no_answer", "declined", "push_failed", "unreachable", "lost", "tts_failed", "ended_by_user",
    "ended_by_agent", "busy", "not_allowed", "not_available",
})
# Ended by the phone itself: nothing to tell it.
PHONE_ENDED = frozenset({"declined", "ended_by_user"})

# Ended without the user hearing a line to the end (the call's own notice or result says what to do next).
UNHEARD_OUTCOMES = frozenset({"ended_by_user", "lost"})
# Ended before anyone answered: whatever the agent was to offer on this call is still to be offered on the next.
NEVER_ANSWERED = frozenset({"no_answer", "declined", "push_failed", "unreachable"})

CALL_ENDED = (
    "The call ended while this line was being spoken, so the user may not have heard all of it. They can't hear "
    "you now: put what matters in a short text recap."
)
CALL_DROPPED = (
    "The phone lost its connection while this line was being spoken, so the user may not have heard all of it. "
    "The phone reconnects by itself: say it again with start_call on the next [Voice] message."
)

CALL_ID = re.compile(r"[0-9a-f]{32}")
ENDINGS = frozenset(inject.MARKERS)

# What a send on a socket the phone has dropped (or the server has closed) raises.
_SOCKET_GONE = (WebSocketDisconnect, RuntimeError, OSError)


def normalize_call_id(value: Any) -> Optional[str]:
    """The call_id as the app and the plugin use it (32 lowercase hex characters), else None."""
    call_id = str(value or "").strip().lower()
    return call_id if CALL_ID.fullmatch(call_id) else None


def new_call_id() -> str:
    return uuid.uuid4().hex


# ── calls ──────────────────────────────────────────────────────────────────────────────────────────────────


class Owner:
    """The conversation a call belongs to. Compression rotates the stored id; the runtime session stays."""

    def __init__(self, session_id: str, runtime_sid: str = "", profile: str = "default",
                 profile_home: Optional[str] = None, scoped: bool = False, title: str = "",
                 source: str = "", key: str = "", remote: bool = False) -> None:
        self.lock = threading.Lock()
        self.session_id = session_id
        self.lineage: set[str] = {session_id} if session_id else set()
        self.runtime_sid = runtime_sid
        self.profile = profile or "default"
        self.profile_home = profile_home
        # Whether profile_home is known (else the live lookup matches any profile).
        self.scoped = scoped
        self.title = title
        self.source = source
        # Hermes' route key for the conversation (a messaging chat keeps it through compression).
        self.key = key
        # The conversation runs in another process: its turns go there (``Call.route``), not into this one.
        self.remote = remote

    @classmethod
    def from_origin(cls, origin: hermes.Origin, remote: bool = False) -> "Owner":
        return cls(origin.session_id, origin.runtime_sid, origin.profile, origin.profile_home,
                   scoped=bool(origin.runtime_sid), title=origin.title, source=_surface_of(origin),
                   key=origin.session_key, remote=remote)

    def rekey(self, session_id: str, runtime_sid: str = "") -> None:
        with self.lock:
            if session_id and session_id != self.session_id:
                logger.info("hermes_voice: call owner %s continues as %s", self.session_id, session_id)
                self.session_id = session_id
                self.lineage.add(session_id)
            if runtime_sid:
                self.runtime_sid = runtime_sid

    def matches(self, origin: hermes.Origin) -> bool:
        with self.lock:
            if origin.session_id and origin.session_id in self.lineage:
                return True
            if origin.session_key and origin.session_key == self.key:
                return True
            return bool(origin.runtime_sid and origin.runtime_sid == self.runtime_sid)

    def owns(self, session_id: str) -> bool:
        with self.lock:
            return session_id in self.lineage


@dataclass(frozen=True)
class Hello:
    call_id: str
    session_id: str
    title: str
    initiated_by: str
    app_version: str

    @classmethod
    def parse(cls, message: Any) -> Optional["Hello"]:
        if not isinstance(message, dict) or message.get("type") != "hello":
            return None
        call_id = normalize_call_id(message.get("call_id"))
        initiated = str(message.get("initiated_by") or "user")
        if call_id is None or initiated not in ("user", "push"):
            return None
        return cls(call_id, _optional_str(message.get("session_id")) or "", _optional_str(message.get("title")) or "",
                   initiated, _optional_str(message.get("app_version")) or "")


@dataclass(frozen=True)
class Turn:
    """What the user said and how their turn ended, as the phone's speech provider reported it."""

    call_id: str
    text: str
    ending: str
    started_at: float
    ended_at: float
    provider: str = ""
    language: Optional[str] = None
    detector: Optional[str] = None
    detail: Optional[float] = None
    error: Optional[str] = None
    received_at: float = 0.0

    @classmethod
    def parse(cls, message: dict, call_id: str) -> Optional["Turn"]:
        ending = message.get("ending")
        kind = ending.get("kind") if isinstance(ending, dict) else None
        started = _timestamp(message.get("started_at"))
        if kind not in ENDINGS or started is None:
            return None
        claimed = normalize_call_id(message.get("call_id"))
        if claimed is not None and claimed != call_id:
            return None
        detail = ending.get("detail")
        return cls(
            call_id=call_id,
            text=str(message.get("text") or "")[:4000],
            ending=kind,
            started_at=started,
            ended_at=_timestamp(message.get("ended_at")) or started,
            provider=_optional_str(message.get("provider")) or "",
            language=_optional_str(message.get("language")),
            detector=_optional_str(ending.get("detector")),
            detail=float(detail) if isinstance(detail, (int, float)) and not isinstance(detail, bool) else None,
            error=_optional_str(ending.get("error")),
            received_at=time.time(),
        )


@dataclass(frozen=True)
class SpeakResult:
    # played | unconfirmed | cut_off | not_connected | failed | cancelled | not_delivered
    status: str
    message: str
    seconds: float = 0.0
    resumed: bool = False


class Line:
    """One thing to say on the call. Lines are spoken in order, once the call is live."""

    def __init__(self, text: str, mode: str = "async", note: str = "") -> None:
        self.id = uuid.uuid4().hex[:12]
        self.text = text
        self.mode = mode
        self.note = note
        self.state = "queued"
        self.result: Optional[SpeakResult] = None
        # Wall-clock (host) times: speech_start first went out; the phone should have finished playing it (the
        # audio's length after its first frame, or the speech_end send if streaming was slower); its played ack.
        self.sent_at: Optional[float] = None
        self.heard_by: Optional[float] = None
        self.played_at: Optional[float] = None
        self.done = threading.Event()
        self.task: Optional[asyncio.Task] = None


class Waiter:
    """A sync start_call waiting for the user's reply to its line."""

    def __init__(self, line: Line) -> None:
        self.line = line
        self.turn: Optional[Turn] = None
        self.superseded = False

    def accepts(self, turn: Turn) -> bool:
        """Whether `turn` is the reply to this line (called under the hub's lock as the turn arrives).

        The phone's mic is paused while a line plays, and it sends a line's ``played`` before any turn that
        follows it (after a reconnect too: the ack is repeated on ``ready``, ahead of the turns kept meanwhile).
        So a turn that arrives after the ack and started after the line went out is the reply, however late the
        ack got here. ``started_at`` is the phone's clock, compared with the host's only against the start of the
        line, which is a line's length away from any real reply. A turn that Hermes' speech cut off began before
        that speech. A line the phone never confirmed takes turns that started after it should have been heard."""
        line = self.line
        if turn.ending == "cut_off":
            return False
        if line.played_at is not None and line.sent_at is not None:
            return turn.started_at >= line.sent_at - TURN_CLOCK_SLACK
        if line.state == "unconfirmed" and line.heard_by is not None:
            return turn.started_at >= line.heard_by - TURN_CLOCK_SLACK
        return False


class Signals:
    """What a sync wait listens to and keeps going while it waits. The default is the tool's own thread in this
    process: Stop (``is_interrupted``), Hermes asking the tool to yield, Hermes' human-wait window and the
    inactivity heartbeat. A wait for a tool in another process gets these from that process (``hubsock.py``)."""

    def interrupted(self) -> bool:
        return hermes.is_interrupted()

    def take_yield(self) -> bool:
        return hermes.take_yield()

    def window(self) -> Any:
        return hermes.human_wait()

    def beater(self) -> Callable[[], None]:
        return hermes.heartbeat("voice call")


@dataclass
class Begun:
    """What starting a call (or speaking into one) did: an async ``start_call``'s result, or a sync one's waiter."""

    result: dict[str, Any]
    call: Optional["Call"] = None
    waiter: Optional[Waiter] = None


class Call:
    def __init__(self, hub: "CallHub", call_id: str, owner: Owner, initiated_by: str, state: str) -> None:
        self.call_id = call_id
        self.owner = owner
        self.initiated_by = initiated_by  # agent | user
        self.state = state  # ringing | live | ended
        self.outcome: Optional[str] = None
        self.detail = ""
        self.created_at = time.time()
        self.answered_at: Optional[float] = time.time() if state == "live" else None
        self.ended_at: Optional[float] = None
        self.connected = False  # a phone link said hello for this call
        self.pushed = 0  # phones APNs accepted the VoIP push for (0: not rung by a push, or not yet)
        self.rang = False  # the phone reported it is ringing
        self.lines: deque[Line] = deque()
        self.speaker: Optional[asyncio.Task] = None
        self.waiter: Optional[Waiter] = None
        self.ring_timer: Optional[threading.Timer] = None
        self.hang_up_turn = False  # an injected "[Voice, hung up]" turn already told the agent
        # The lines the user did not hear to the end when the call ended (told to the agent, then offered on the
        # conversation's next call), and what an earlier call left to offer on this one (`offer_pending`: the
        # agent hasn't been reminded yet).
        self.unheard: list[str] = []
        self.offer: list[str] = []
        self.offer_pending = False
        # Where turns go when the conversation runs in another process (hubsock.Route): deliver(text), close().
        self.route: Any = None
        self.inbox = InjectQueue(hub, self)
        # Another Hermes process holds the call's chat: logged (once), and said into the call (once).
        self.held_logged = False
        self.held_announced = False
        # The ring of a scheduled call (``schedule.Ring``): the schedule hears how it went.
        self.scheduled: Optional[schedule.Ring] = None

    def info(self) -> dict[str, Any]:
        """The call as ``GET /status`` shows it (``active_call``), so the app's call button can join it.
        ``initiated_by`` uses the hello's words: "push" for a call Hermes rang, "user" for one the user started."""
        return {"call_id": self.call_id, "session_id": self.owner.session_id, "title": self.owner.title,
                "state": self.state, "initiated_by": "push" if self.initiated_by == "agent" else "user"}


class InjectQueue:
    """Deliveries into the owner's conversation, one at a time and in order, off the event loop. For a call the
    user started, the "[Voice call started]" notice goes first, so turns wait until it is delivered. Once the call
    is over, its route (if any) hears so after the last delivery.

    A delivery refused because another Hermes process holds the chat (``Delivery.held``: nothing was written) is
    tried again here until it is in or ``HELD_RETRY_LIMIT_S`` old, with everything queued after it waiting its
    turn. What gets in late says so (``inject.delayed``)."""

    END = None

    def __init__(self, hub: "CallHub", call: Call) -> None:
        self.hub = hub
        self.call = call
        # (text, when it was queued: time.monotonic()), or END.
        self.items: deque[Optional[tuple[str, float]]] = deque()
        # Since when the chat has refused as held (None: it takes deliveries), when it last took one again, and
        # how many deliveries were given up meanwhile. Only the queue's own thread touches these.
        self.held_since: Optional[float] = None
        self.freed_at = 0.0
        self.lost = 0
        self.lock = threading.Lock()
        self.running = False
        # Everything the call had to deliver is done (a route attached after this hears the end at once).
        self.finished = False
        # The end is queued: nothing more goes through the route.
        self.closing = False

    def close(self) -> None:
        """After what is queued: the call is over; tell its route, if it has one by then."""
        self.put(InjectQueue.END)

    def put(self, text: Optional[str], open_only: bool = False) -> bool:
        """Queue `text` (``END`` closes the queue). With `open_only`, False instead once the queue is closed."""
        with self.lock:
            if open_only and self.closing:
                return False
            if text is InjectQueue.END:
                self.closing = True
            self.items.append(None if text is InjectQueue.END else (text, time.monotonic()))
            if self.running:
                return True
            self.running = True
        try:
            hermes.spawn_thread(self._run, name=f"hermes-voice-inject-{self.call.call_id[:8]}")
        except RuntimeError:
            with self.lock:
                self.running = False
            logger.warning("hermes_voice: could not start an injection thread")
        return True

    def _run(self) -> None:
        while True:
            with self.lock:
                if not self.items:
                    self.running = False
                    return
                item = self.items.popleft()
            if item is InjectQueue.END:
                with self.hub.lock:
                    self.finished = True
                    route = self.call.route
                try:
                    if route is not None:
                        route.close(self.call.outcome or "ended")
                except Exception:  # noqa: BLE001
                    logger.debug("hermes_voice: closing a call's route failed", exc_info=True)
                continue
            self._deliver(*item)

    def _deliver(self, text: str, queued: float) -> None:
        """One delivery. While another Hermes process holds the chat it is tried again (what is queued behind it
        waits), until it is in or too old; anything else that fails is final (it may have been taken)."""
        hub, call = self.hub, self.call
        refused = False
        while True:
            # Late: refused before, or it waited behind something that was.
            late = refused or self.held_since is not None or queued < self.freed_at
            waited = time.monotonic() - queued
            try:
                sent = inject.delayed(text, waited, call.state == "ended", self.lost) if late else text
                delivery = hub.deliver(call, sent)
            except Exception as error:  # noqa: BLE001
                logger.warning("hermes_voice: injection failed", exc_info=True)
                delivery = inject.Delivery(False, detail=type(error).__name__)
            if delivery.ok:
                if self.held_since is not None:
                    self.held_since, self.freed_at, self.lost = None, time.monotonic(), 0
                break
            if not delivery.held:
                break
            refused = True
            if self.held_since is None:
                self.held_since = time.monotonic()
            hub.chat_held(call, delivery)
            if time.monotonic() - queued >= HELD_RETRY_LIMIT_S:
                self.lost += 1
                break
            time.sleep(HELD_RETRY_S)
        hub.delivered(call, text, delivery, waited=time.monotonic() - queued, late=late)


# ── phone links (event loop only) ──────────────────────────────────────────────────────────────────────────


class PhoneLink:
    """One phone connection for a call. A reconnect gets a new PhoneLink that takes over the lock and acks."""

    def __init__(self, call_id: str, socket: Any) -> None:
        self.call_id = call_id
        self.socket = socket
        # One line at a time per call, so two lines never interleave audio.
        self.lock = asyncio.Lock()
        # Lines waiting for the phone's `played`, and the ones it has acknowledged.
        self.played: dict[str, asyncio.Event] = {}
        self.acked: set[str] = set()
        # Set once this link is over: bye, disconnect, replaced by a newer one, or stalled.
        self.ended = asyncio.Event()

    def ack(self, speech_id: str) -> bool:
        if (event := self.played.get(speech_id)) is not None:
            self.acked.add(speech_id)
            event.set()
            return True
        return False

    def wake(self) -> None:
        for event in self.played.values():
            event.set()


# ── the hub ────────────────────────────────────────────────────────────────────────────────────────────────


class CallHub:
    def __init__(
        self,
        *,
        settings: Optional[Callable[[], Settings]] = None,
        tts: Optional[TextToSpeech] = None,
        pusher: Any = None,
        injector: Optional[inject.Injector] = None,
        policy: Optional[Policy] = None,
    ) -> None:
        self.settings = settings or current_settings
        self.tts = tts or ElevenLabs(self.settings)
        self.pusher = pusher or push.Apns()
        self.injector = injector or inject.TuiInjector()
        self.policy = policy or Policy(self.settings)
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.slot: Optional[Call] = None
        self.history: OrderedDict[str, Call] = OrderedDict()
        self.loop: Optional[asyncio.AbstractEventLoop] = None
        self.links: dict[str, PhoneLink] = {}
        self.dropped: dict[str, PhoneLink] = {}
        # Background closes of replaced, stalled or finished links.
        self.closing: set[asyncio.Task] = set()
        # Conversations with a turn running now (pre_llm_call .. on_session_end).
        self.busy: dict[str, float] = {}
        self.deliveries: deque[tuple[str, str, inject.Delivery]] = deque(maxlen=200)
        # What each conversation's user did not hear to the end on its last call (memory only).
        self.missed = guidance.Missed()
        # Asks the Hermes processes that attend on the hub socket to put a text into a chat one of them holds:
        # (the chat's stored ids, text) -> how it went, or None when none of them has it (``hubsock.HubServer``).
        self.holders: Optional[Callable[[list[str], str], Optional[inject.Delivery]]] = None
        # Calls that ring later (kept on disk; rung by the dashboard process once ``schedule.start`` runs).
        self.schedule = schedule.Scheduler(self)

    # ── loop plumbing ────────────────────────────────────────────────────────────────────────────────────

    def capture_loop(self) -> None:
        """Remember the dashboard's event loop (lazily: on the first request that reaches the plugin)."""
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        current = self.loop
        if current is None or current.is_closed() or not current.is_running():
            self.loop = loop

    def _soon(self, fn: Callable[..., Any], *args: Any) -> bool:
        loop = self.loop
        if loop is None or loop.is_closed():
            return False
        try:
            loop.call_soon_threadsafe(fn, *args)
        except RuntimeError:
            return False
        return True

    def _track(self, coro: Awaitable[None]) -> None:
        task = asyncio.ensure_future(coro)
        self.closing.add(task)
        task.add_done_callback(self.closing.discard)

    # ── links (ported from hermes-voice-mcp) ─────────────────────────────────────────────────────────────

    def connect_link(self, call_id: str, socket: Any) -> tuple[PhoneLink, Optional[PhoneLink]]:
        """Register a link. Also returns the call's earlier link if it was still live, to be closed."""
        link = PhoneLink(call_id, socket)
        live = self.links.get(call_id)
        previous = live or self.dropped.pop(call_id, None)
        if previous is not None:
            # An in-flight line keeps its lock, and an ack on the new socket resolves it.
            link.lock, link.played, link.acked = previous.lock, previous.played, previous.acked
            previous.ended.set()
        self.links[call_id] = link
        return link, live

    def disconnect_link(self, link: PhoneLink, hung_up: bool) -> None:
        """A link closed. A hang-up (or a finished call) ends it; a drop keeps the call DROP_RETENTION."""
        link.ended.set()
        if self.links.get(link.call_id) is not link:
            return  # replaced by a newer link, which now owns the pending acks
        del self.links[link.call_id]
        call = self.current(link.call_id)
        if hung_up or call is None:
            link.wake()
            return
        logger.info("hermes_voice: call %s dropped; keeping it %.0fs for a reconnect", link.call_id[:8],
                    DROP_RETENTION)
        self.dropped[link.call_id] = link
        asyncio.get_running_loop().call_later(DROP_RETENTION, self._expire_link, link)

    def stall(self, link: PhoneLink) -> None:
        """A send on this link got stuck (the phone stopped reading): stop using it and close it, so the phone
        reconnects. Its handler disconnects it as a drop once the socket is really gone."""
        if not link.ended.is_set():
            logger.info("hermes_voice: call %s stalled; closing its link", link.call_id[:8])
            link.ended.set()
            self.retire(link.socket, 1011)

    def retire(self, socket: Any, code: int) -> None:
        """Close a link in the background: one that stopped reading can't hold anything else up."""
        self._track(_close_quietly(socket, code))

    def _expire_link(self, link: PhoneLink) -> None:
        if self.dropped.get(link.call_id) is link:
            del self.dropped[link.call_id]
            link.wake()
            call = self.current(link.call_id)
            if call is not None:
                logger.info("hermes_voice: call %s lost: no reconnect", link.call_id[:8])
                self.finish(call, "lost")

    def link_over(self, call_id: str) -> bool:
        return call_id not in self.links and call_id not in self.dropped

    async def line(self, call_id: str, avoid: Any = None) -> Optional[PhoneLink]:
        """The call's live link, waiting up to RECONNECT_GRACE for one if it dropped (or if `avoid` failed)."""
        deadline = time.monotonic() + RECONNECT_GRACE
        while True:
            link = self.links.get(call_id)
            if link is not None and link.socket is not avoid and not link.ended.is_set():
                return link
            if self.link_over(call_id) or time.monotonic() >= deadline:
                return None
            await asyncio.sleep(0.05)

    def cut_off(self, call: Call) -> str:
        """The result for a line the call went away during."""
        return CALL_ENDED if call.state == "ended" and call.outcome != "lost" else CALL_DROPPED

    def problem(self, call: Call) -> str:
        """Why nothing can be spoken on the call right now."""
        if call.state == "ended":
            return (f"Voice call {call.call_id} has ended, so nothing was spoken. Put it in a short text recap; "
                    "start_call would ring the user again.")
        return (f"The phone on voice call {call.call_id} is not connected right now (it may be reconnecting), so "
                "nothing was spoken. Say it again with start_call on the next [Voice] message.")

    # ── calls ────────────────────────────────────────────────────────────────────────────────────────────

    def current(self, call_id: str) -> Optional[Call]:
        with self.lock:
            slot = self.slot
            return slot if slot is not None and slot.call_id == call_id else None

    def _remember(self, call: Call) -> None:
        self.history[call.call_id] = call
        self.history.move_to_end(call.call_id)
        while len(self.history) > HISTORY_LIMIT:
            self.history.popitem(last=False)

    def finish(self, call: Call, outcome: str, detail: str = "") -> bool:
        """End the call (any thread). Wakes everyone waiting on it, tells the phone, and, unless a sync
        start_call is there to return it, tells the conversation with a notice."""
        with self.lock:
            if call.state == "ended":
                return False
            was = call.state
            call.state, call.outcome, call.detail, call.ended_at = "ended", outcome, detail, time.time()
            if self.slot is call:
                self.slot = None
            self._remember(call)
            timer, call.ring_timer = call.ring_timer, None
            if outcome in UNHEARD_OUTCOMES:
                # Still queued or playing: the phone never confirmed it heard these out.
                call.unheard = [line.text for line in call.lines if line.played_at is None]
            for line in [line for line in call.lines if line.state == "queued"]:
                self._settle(call, line, SpeakResult("not_delivered", self.problem(call)))
            waiting = call.waiter is not None
            # A "[Voice, hung up]" turn already said the call is over, but not what went unheard.
            quiet = outcome == "ended_by_user" and call.hang_up_turn and not call.unheard
            unheard = list(call.unheard)
            still_to_offer = call.offer if call.offer_pending or outcome in NEVER_ANSWERED else []
            call.offer, call.offer_pending = [], False
            self.changed.notify_all()
        self.missed.note(call.owner, still_to_offer + unheard)
        if timer is not None:
            timer.cancel()
        logger.info("hermes_voice: call %s ended: %s", call.call_id[:8], outcome)
        self.policy.log({"event": "ended", "call_id": call.call_id, "session_id": call.owner.session_id,
                         "outcome": outcome, **({"detail": detail[:200]} if detail else {})})
        # A scheduled ring nobody took rings again later (its conversation hears nothing yet), or is given up.
        over = self.schedule.ring_over(call, outcome) if call.scheduled is not None else schedule.Over()
        if not waiting and not quiet and not over.again:
            notice = inject.outcome_notice(outcome, detail, unheard)
            if notice:
                call.inbox.put(f"{notice}{over.note}")
        call.inbox.close()
        self._soon(self._close_out, call, was, outcome)
        return True

    def _close_out(self, call: Call, was: str, outcome: str) -> None:
        """On the loop: tell the phone the call is over (cancel while ringing, ended once live) and close it."""
        link = self.links.get(call.call_id)
        if link is not None:
            del self.links[call.call_id]
        else:
            link = self.dropped.pop(call.call_id, None)
        if link is None:
            return
        link.ended.set()
        link.wake()
        message = None
        if outcome not in PHONE_ENDED:
            message = ({"type": "cancel", "reason": outcome} if was == "ringing"
                       else {"type": "ended", "outcome": outcome})
        self._track(_goodbye(link.socket, message))

    def _ring_expired(self, call: Call) -> None:
        with self.lock:
            if call.state != "ringing":
                return
            outcome = "no_answer" if call.connected else "unreachable"
            detail = _ring_expiry_detail(call)
        self.finish(call, outcome, detail)

    def _push(self, call: Call, mode: str) -> None:
        payload = {"call_id": call.call_id, "session_id": call.owner.session_id, "profile": call.owner.profile,
                   "mode": mode, "title": (call.owner.title if _previews() else "") or "Hermes"}
        try:
            result = self.pusher.push_call(payload)
        except Exception as error:  # noqa: BLE001
            logger.warning("hermes_voice: push failed", exc_info=True)
            result = push.PushResult(False, f"push failed ({type(error).__name__})")
        if not result.ok:
            logger.warning("hermes_voice: call %s not rung: %s", call.call_id[:8], result.reason)
            self.finish(call, "push_failed", result.reason)
            return
        with self.lock:
            call.pushed = result.delivered
        self.policy.log({"event": "pushed", "call_id": call.call_id, "phones": result.delivered})

    # ── the tools ────────────────────────────────────────────────────────────────────────────────────────

    def start_call(self, origin: hermes.Origin, text: str, mode: str = "async",
                   signals: Optional[Signals] = None, cap_s: Optional[float] = None) -> dict[str, Any]:
        """Speak `text` on this conversation's call, ringing the phone first when it has none (tool thread). A sync
        call waits for the reply here, for at most `cap_s` (what Hermes' tool deadline leaves it)."""
        begun = self.begin_call(origin, text, mode)
        if begun.waiter is None or begun.call is None:
            return begun.result
        return self.wait_reply(begun.call, begun.waiter, signals or Signals(), cap_s)

    def speak(self, origin: hermes.Origin, text: str) -> dict[str, Any]:
        """Speak into the call this conversation has; never rings."""
        return self.begin_call(origin, text, "async", ring=False).result

    def begin_call(self, origin: hermes.Origin, text: str, mode: str = "async", ring: bool = True,
                   route: Optional[Callable[[Call], Any]] = None,
                   scheduled: Optional[schedule.Ring] = None) -> Begun:
        """Queue `text` on this conversation's call, claiming the call slot and ringing the phone first when it has
        none (with `ring`). A sync call gets a waiter for the reply (``wait_reply``). `route` makes the route for a
        call this starts for a conversation in another process (``hubsock.py``).

        `scheduled`: this is a scheduled call's ring (``schedule.py``, at its time). The policy was asked when it
        was scheduled, so quiet hours and the rate limits don't refuse it now. Its line goes into a call the
        conversation is live on, or rings a call of its own; while the phone rings for anything else it is
        ``busy`` (the schedule tries again)."""
        settings = self.settings()
        text, clip_note = clip(text, settings.max_chars)
        # What the result says about the line itself: that it was cut, and that it is long for a phone call.
        line_note = f"{clip_note}{guidance.long_line_note(text)}"
        with self.lock:
            call = self.slot
            if call is not None and not call.owner.matches(origin):
                return Begun(_refusal(mode, "busy", (
                    f"The user is on a call with {_quote(call.owner.title) or 'another conversation'}. Reply in "
                    "text; you can call once that call is over.")))
            if call is not None and scheduled is not None and call.state != "live":
                return Begun(_refusal(mode, "busy", "The phone is ringing for this conversation already."))
            if call is not None:
                call.owner.rekey(origin.session_id, origin.runtime_sid)
        rang = False
        if call is None:
            if not ring:
                return Begun({"call_id": None, "status": "no_call",
                              "note": "This conversation has no voice call; start_call rings the user."})
            if scheduled is None:
                decision = self.policy.check(origin)
                if not decision.allowed:
                    return Begun(_refusal(mode, "not_allowed", decision.note))
            with self.lock:
                if self.slot is not None:  # another call won the slot meanwhile
                    if not self.slot.owner.matches(origin) or scheduled is not None:
                        return Begun(_refusal(mode, "busy", "The user is on another call. Reply in text."))
                    call = self.slot
                else:
                    remote = route is not None or (scheduled is not None and scheduled.remote)
                    call = Call(self, scheduled.call_id if scheduled is not None else new_call_id(),
                                Owner.from_origin(origin, remote=remote), "agent", "ringing")
                    call.scheduled = scheduled
                    if route is not None:
                        call.route = route(call)
                    self.slot = call
                    timer = threading.Timer(settings.ring_timeout_s, self._ring_expired, args=(call,))
                    timer.daemon = True
                    call.ring_timer = timer
                    timer.start()
                    rang = True
                    # What this conversation's last call left unheard: the agent is reminded with this call's
                    # first result (now for an async call, with the reply for a sync one).
                    call.offer = self.missed.take(lambda owner: owner.matches(origin))
                    call.offer_pending = bool(call.offer)
            if rang:
                self.policy.record_ring(origin, call.call_id,
                                        **(self.schedule.ring_log(scheduled) if scheduled is not None else {}))
                logger.info("hermes_voice: ringing for %s (call %s%s)", origin.session_id, call.call_id[:8],
                            f", scheduled {scheduled.id}" if scheduled is not None else "")
        _, waiter = self.enqueue_line(call, text, mode, line_note, wait=mode == "sync")
        if rang:
            if mode == "sync":
                self._push(call, mode)
            else:
                hermes.spawn_thread(self._push, call, mode, name=f"hermes-voice-push-{call.call_id[:8]}")
        if waiter is not None:
            return Begun({"call_id": call.call_id, "status": "waiting"}, call, waiter)
        with self.lock:
            status = "speaking" if call.state == "live" else "ringing" if call.state == "ringing" else "ended"
            reminder = self._offer_reminder(call) if status != "ended" else ""
        note = {
            "ringing": "The phone is ringing; your line is spoken once the user answers.",
            "speaking": "Your line is being spoken.",
            "ended": "The call ended before your line could be spoken.",
        }[status]
        note += " What the user says arrives as [Voice] messages; answer them with start_call."
        return Begun({"call_id": call.call_id, "status": status, "note": f"{note}{line_note}{reminder}"}, call)

    def _offer_reminder(self, call: Call) -> str:
        """Once per call (under lock): the reminder to offer what the conversation's last call left unheard."""
        if not call.offer_pending:
            return ""
        call.offer_pending = False
        return guidance.missed_reminder(call.offer)

    def end_call(self, origin: hermes.Origin, text: str = "", signals: Optional[Signals] = None) -> dict[str, Any]:
        signals = signals or Signals()
        live = False
        with self.lock:
            call = self.slot
            mine = call is not None and call.owner.matches(origin)
            if mine:
                call.owner.rekey(origin.session_id, origin.runtime_sid)
                live = call.state == "live"
        if not mine:
            pending = self.schedule.pending(origin)
            later = (f" It has {len(pending)} scheduled for later (see pending); scheduled_calls cancels them."
                     if pending else "")
            return {"call_id": None, "outcome": None, "note": f"This conversation has no voice call running.{later}",
                    **({"pending": pending} if pending else {})}
        note = ""
        if text.strip() and live:
            text, clip_note = clip(text.strip(), self.settings().max_chars)
            line, _ = self.enqueue_line(call, text, "sync", clip_note)
            deadline = time.monotonic() + GOODBYE_WAIT
            while not line.done.wait(0.2):
                if signals.interrupted() or time.monotonic() > deadline:
                    self.cancel_line(call, line)
                    line.done.wait(NOTICE_TIMEOUT + 1)
                    break
            note = f" {line.result.message}" if line.result else ""
        self.finish(call, "ended_by_agent")
        return {"call_id": call.call_id, "outcome": "ended_by_agent", "note": f"Hung up.{note}"}

    def enqueue_line(self, call: Call, text: str, mode: str = "async", note: str = "",
                     wait: bool = False) -> tuple[Line, Optional[Waiter]]:
        """Queue a line on the call (any thread); it is spoken once the call is live. With `wait`, a sync
        waiter for the reply to it takes over the call's turns."""
        line = Line(text, mode, note)
        waiter = Waiter(line) if wait else None
        with self.lock:
            if call.state == "ended":
                self._settle(call, line, SpeakResult("not_delivered", self.problem(call)))
                if waiter is not None:
                    call.waiter = waiter  # returns the outcome at once
                return line, waiter
            if waiter is not None:
                if call.waiter is not None:
                    call.waiter.superseded = True
                call.waiter = waiter
                self.changed.notify_all()
            call.lines.append(line)
            live = call.state == "live"
        if live:
            self._soon(self._kick, call)
        return line, waiter

    def cancel_line(self, call: Call, line: Line) -> None:
        if not self._soon(self._cancel_now, call, line):
            with self.lock:
                if line.state == "queued":
                    self._settle(call, line, SpeakResult("cancelled", "Stopped before it was spoken."))

    def _cancel_now(self, call: Call, line: Line) -> None:
        with self.lock:
            if line.state == "queued":
                self._settle(call, line, SpeakResult("cancelled", "Stopped before it was spoken."))
                return
        if line.task is not None and not line.task.done():
            line.task.cancel()

    def wait_reply(self, call: Call, waiter: Waiter, signals: Signals,
                   cap_s: Optional[float] = None) -> dict[str, Any]:
        """A sync start_call: wait (as a human wait, which extends Hermes' tool deadline) for the reply. `cap_s`
        bounds the whole wait: Hermes extends the deadline by at most approvals.timeout + 60 s per human wait, and
        abandons a tool that runs past it (``hermes.tool_wait_cap``)."""
        settings = self.settings()
        deadline = time.monotonic() + settings.ring_timeout_s + PLAYBACK_WAIT_LIMIT + settings.sync_reply_timeout_s
        capped = cap_s is not None and cap_s > 0 and time.monotonic() + cap_s < deadline
        if capped:
            deadline = time.monotonic() + float(cap_s or 0)
        beat = signals.beater()
        line = waiter.line
        interrupted = False
        with signals.window():
            while True:
                interrupted = signals.interrupted()
                # A message for the conversation is parked until this tool returns: let it through.
                yielded = not interrupted and signals.take_yield()
                with self.lock:
                    late = time.monotonic() > deadline
                    result = self._sync_result(call, waiter, interrupted, late, yielded,
                                               cap_s if capped else None)
                    if result is not None:
                        if call.waiter is waiter:
                            call.waiter = None
                        about_line = line.note.strip()
                        if about_line and line.sent_at is not None and about_line not in (result.get("note") or ""):
                            # However the wait ended, a line that went out long (or cut) is said to be so.
                            result["note"] = f"{result.get('note') or ''} {about_line}".strip()
                        if call.state != "ended" and (reminder := self._offer_reminder(call)):
                            result["note"] = f"{result.get('note') or ''}{reminder}".strip()
                        self.changed.notify_all()
                        break
                    self.changed.wait(0.25)
                beat()
        if interrupted and not line.done.is_set():
            self.cancel_line(call, line)
        return result

    def abandon(self, call: Call, waiter: Waiter) -> None:
        """A sync wait nobody will collect (its process went away): turns go back to the conversation."""
        with self.lock:
            waiter.superseded = True
            if call.waiter is waiter:
                call.waiter = None
            self.changed.notify_all()

    def _sync_result(self, call: Call, waiter: Waiter, interrupted: bool, late: bool,
                     yielded: bool = False, cap_s: Optional[float] = None) -> Optional[dict[str, Any]]:
        line = waiter.line
        if waiter.turn is not None:
            turn = waiter.turn
            if turn.ending == "hang_up":
                note = f"{_outcome_note('ended_by_user', '')} {line.note.strip()}".strip()
                return _sync(call, " ".join(turn.text.split()), turn.ending, "ended_by_user", note)
            return _sync(call, " ".join(turn.text.split()), turn.ending, "answered", line.note.strip())
        if waiter.superseded:
            return {"call_id": call.call_id, "status": "superseded",
                    "note": "A newer start_call on this call took over waiting for the reply."}
        if call.state == "ended":
            return _sync(call, "", None, call.outcome or "lost",
                         _outcome_note(call.outcome or "", call.detail, call.unheard))
        if line.state == "failed":
            return _sync(call, "", None, "tts_failed", line.result.message if line.result else "")
        if line.state in ("not_connected", "cut_off", "cancelled", "not_delivered") and not interrupted:
            return _sync(call, "", None, "answered", line.result.message if line.result else "")
        if interrupted:
            return {"call_id": call.call_id, "status": "interrupted",
                    "note": "Stopped waiting. The call stays open; what the user says next arrives as a [Voice] "
                            "message."}
        if yielded:
            spoken = "was spoken" if line.played_at is not None else "is still being spoken"
            return {"call_id": call.call_id, "status": "yielded",
                    "note": f"Stopped waiting: a message for you came in (it follows this result). The call stays "
                            f"open and your line {spoken}; what the user says next arrives as a [Voice] message."}
        if late and cap_s is not None:
            return _sync(call, "", None, "answered", (
                f"Stopped waiting after {cap_s:.0f} s: a tool call may wait for a person only that long (Hermes' "
                "tool deadline, timeouts.tools.sequential_call, plus approvals.timeout + 60 s). The call stays "
                "open; the user's reply will arrive as a [Voice] message."))
        if late:
            return _sync(call, "", None, "answered",
                         "The user hasn't answered yet; their reply will arrive as a [Voice] message.")
        return None

    # ── speaking (event loop) ────────────────────────────────────────────────────────────────────────────

    def _kick(self, call: Call) -> None:
        if call.speaker is None or call.speaker.done():
            call.speaker = asyncio.ensure_future(self._speaker(call))

    async def _speaker(self, call: Call) -> None:
        """Speak the call's queued lines in order while it is live."""
        while True:
            with self.lock:
                if call.state != "live":
                    return
                line = next((item for item in call.lines if item.state == "queued"), None)
                if line is None:
                    return
                line.state = "speaking"
            task = line.task = asyncio.ensure_future(self._speak_line(call, line))
            try:
                await asyncio.wait({task})
            except asyncio.CancelledError:
                task.cancel()
                raise
            if task.cancelled():
                result = SpeakResult("cancelled", "Stopped before the user heard all of it.")
            elif task.exception() is not None:
                error = task.exception()
                result = SpeakResult("failed", f"Could not speak: {error or type(error).__name__}")
            else:
                result = task.result()
            with self.lock:
                tell = self._settle(call, line, result)
            if tell:
                call.inbox.put(inject.line_notice(result.message))

    def _settle(self, call: Call, line: Line, result: SpeakResult) -> bool:
        """Record a line's result (under lock). True when the conversation should hear that it failed."""
        line.state, line.result = result.status, result
        try:
            call.lines.remove(line)
        except ValueError:
            pass
        line.done.set()
        self.changed.notify_all()
        return (line.mode == "async" and call.state != "ended"
                and result.status in ("failed", "not_connected", "cut_off"))

    def mark_played(self, call: Call, speech_id: str) -> None:
        with self.lock:
            for line in call.lines:
                if line.id == speech_id and line.played_at is None:
                    line.played_at = time.time()
                    self.changed.notify_all()

    async def _speak_line(self, call: Call, line: Line) -> SpeakResult:
        """Stream the line to the call and wait until the phone has played it."""
        loop = asyncio.get_running_loop()
        give_up_at = loop.time() + PLAYBACK_WAIT_LIMIT
        link = await self.line(call.call_id)
        if link is None:
            return SpeakResult("not_connected", self.problem(call))
        async with link.lock:
            speech_id = line.id
            played = link.played[speech_id] = asyncio.Event()
            acked = link.acked
            start = {"type": "speech_start", "id": speech_id, "text": line.text, "sample_rate": SAMPLE_RATE,
                     "format": "pcm_s16le"}
            utterance = _Utterance(self, call.call_id, start)
            try:
                if not await utterance.send():
                    return SpeakResult("not_connected", self.problem(call))
                with self.lock:
                    line.sent_at = time.time()
                sent = 0
                audio_started: Optional[float] = None
                carry = b""
                async with aclosing(self.tts.stream(line.text, None)) as audio:
                    async for chunk in audio:
                        chunk = carry + chunk
                        # Keep whole 16-bit samples per frame; hold back an odd trailing byte.
                        cut = len(chunk) - (len(chunk) % 2)
                        carry = chunk[cut:]
                        if not cut:
                            continue
                        if audio_started is None:
                            audio_started = loop.time()
                        if not await utterance.send(chunk[:cut]):
                            return SpeakResult("cut_off", self.cut_off(call))
                        sent += cut
                if not await utterance.send({"type": "speech_end", "id": speech_id}):
                    return SpeakResult("cut_off", self.cut_off(call))
                seconds = sent / 2 / SAMPLE_RATE
                # The phone plays as audio arrives: it finishes `seconds` after the first frame, or just
                # after the last one if the stream was slower than real time.
                now = loop.time()
                playing_until = max((audio_started or now) + seconds, now)
                with self.lock:
                    line.heard_by = time.time() + (playing_until - now)
                wait_until = min(playing_until + PLAYBACK_MARGIN, give_up_at)
                try:
                    await asyncio.wait_for(played.wait(), max(0.0, wait_until - loop.time()))
                except asyncio.TimeoutError:
                    pass
                if speech_id in acked:
                    gap = " The connection dropped briefly, so they may have missed part." if utterance.resumed else ""
                    return SpeakResult("played", f"Spoken to the user ({seconds:.1f}s of audio).{gap}", seconds,
                                       utterance.resumed)
                if call.call_id not in self.links:
                    return SpeakResult("cut_off", self.cut_off(call), seconds)
                return SpeakResult("unconfirmed",
                                   "The phone did not confirm it played the audio, so the user may not have heard it.",
                                   seconds)
            except Exception as error:  # noqa: BLE001 - report TTS and other failures back to the agent
                reason = str(error) or type(error).__name__
                logger.warning("hermes_voice: speaking failed on call %s: %s", call.call_id[:8], reason)
                if utterance.started:
                    await utterance.notify({"type": "speech_end", "id": speech_id, "error": reason[:200]})
                return SpeakResult("failed", f"Could not speak: {reason}")
            except BaseException:
                # Cancelled (the user pressed Stop, or end_call): the phone drops the line's queued audio and
                # resumes listening. The send is shielded and bounded.
                if utterance.started:
                    await utterance.notify({"type": "speech_end", "id": speech_id, "cancelled": True}, shield=True)
                raise
            finally:
                link.played.pop(speech_id, None)
                acked.discard(speech_id)

    # ── the phone socket (event loop) ────────────────────────────────────────────────────────────────────

    async def serve_phone(self, ws: Any, authorize: Callable[[Any], Awaitable[Optional[int]]]) -> None:
        """One phone link. `authorize` returns None to admit the socket, else the close code."""
        self.capture_loop()
        refusal = await authorize(ws)
        # Accept first, so a refusal reaches the phone as a close code rather than a bare HTTP 403.
        await ws.accept()
        if refusal is not None:
            await _close_quietly(ws, refusal)
            return
        link: Optional[PhoneLink] = None
        call: Optional[Call] = None
        hung_up = False
        bye_reason = ""
        current = False
        try:
            try:
                hello = Hello.parse(await asyncio.wait_for(_next_message(ws), HELLO_TIMEOUT))
            except asyncio.TimeoutError:
                hello = None
            verdict, call = self.admit(hello) if hello is not None else ("bad", None)
            if verdict != "attach":
                self._log_phone(hello.call_id if hello is not None else "", f"turned away ({verdict})")
            if verdict in ("bad", "busy"):
                await _close_quietly(ws, 4400 if verdict == "bad" else 4429)
                return
            if verdict == "over":
                await _turn_away(ws, call)
                return
            assert call is not None
            # The call can end on another thread (ring timer, end_call, a failed push) at any point here. Its
            # close-out runs on this loop and closes whatever link the call has by then, so the link is
            # registered under the same lock that ends calls: either the call is already over (turned away
            # here), or it ends later and the close-out finds this link.
            with self.lock:
                state = call.state
            if state == "ended":
                await _turn_away(ws, call)
                return
            await ws.send_json({"type": "ready", "call_id": call.call_id, "state": state})
            previous = None
            with self.lock:
                if call.state != "ended":
                    link, previous = self.connect_link(call.call_id, ws)
                    call.connected = True
                live = call.state == "live"
            if link is None:
                await _turn_away(ws, call)
                return
            if previous is not None:
                # Closed in the background: a replaced link that stopped reading must not hold up this one.
                self.retire(previous.socket, 4409)
            if live:
                self._kick(call)  # back after a drop: carry on with what is queued
            logger.info("hermes_voice: call %s connected (%s)", call.call_id[:8], call.state)
            self._log_phone(call.call_id, f"connected ({state})")
            while not hung_up:
                message = await _next_message(ws) or {}
                kind = message.get("type")
                if kind == "played":
                    if link.ack(str(message.get("id"))):
                        self.mark_played(call, str(message.get("id")))
                elif kind == "ping":
                    await ws.send_json({"type": "pong"})
                elif link.ended.is_set():
                    continue  # replaced or stalled: only acks still count
                elif kind == "ringing":
                    with self.lock:
                        call.rang = True
                    self._log_phone(call.call_id, "ringing")
                elif kind == "answered":
                    self._log_phone(call.call_id, "answered")
                    self.on_answered(call)
                elif kind == "declined":
                    self._log_phone(call.call_id, "declined")
                    with self.lock:
                        ringing = call.state == "ringing"
                    self.finish(call, "declined" if ringing else "ended_by_user")
                elif kind == "user_turn":
                    turn = Turn.parse(message, call.call_id)
                    if turn is not None:
                        self.on_turn(call, turn)
                elif kind == "location":
                    from . import location  # the phone's answer to a location_request (location.py)
                    location.locations().phone_frame(message)
                elif kind == "bye":
                    hung_up = True
                    bye_reason = str(message.get("reason") or "")
        except _SOCKET_GONE:
            pass
        finally:
            if link is not None:
                current = self.links.get(link.call_id) is link
                self.disconnect_link(link, hung_up)
            if hung_up and current and call is not None:
                with self.lock:
                    ringing = call.state == "ringing"
                self.finish(call, *bye_outcome(bye_reason, ringing))
        if hung_up:
            await _close_quietly(ws, 1000)

    def admit(self, hello: Hello) -> tuple[str, Optional[Call]]:
        """What a hello gets: ("attach", call), ("busy", None), ("over", past call or None) or ("bad", None)."""
        started: Optional[Call] = None
        with self.lock:
            slot = self.slot
            if slot is not None:
                return ("attach", slot) if slot.call_id == hello.call_id else ("busy", None)
            past = self.history.get(hello.call_id)
            if past is not None:
                if past.outcome != "lost":
                    return "over", past
                # A link that was gone past the retention comes back: the call carries on.
                call = Call(self, past.call_id, past.owner, past.initiated_by, "live")
                del self.history[past.call_id]
                self.slot = call
                logger.info("hermes_voice: call %s is back after it was lost", call.call_id[:8])
                return "attach", call
            if hello.initiated_by != "user":
                return "over", None  # rung, but that ring is over (or was never ours)
            if not hello.session_id:
                return "bad", None
            found = hermes.find_live(hello.session_id)
            owner = Owner(hello.session_id, found[0] if found else "",
                          profile_home=(found[1].get("profile_home") if found else None), scoped=found is not None,
                          title=hello.title, source="desktop")
            started = Call(self, hello.call_id, owner, "user", "live")
            self.slot = started
        logger.info("hermes_voice: the user started call %s in %s", started.call_id[:8], hello.session_id)
        self.policy.log({"event": "start", "call_id": started.call_id, "session_id": hello.session_id,
                         "source": "phone"})
        missed = self.missed.take(lambda owner: owner.owns(hello.session_id))
        started.inbox.put(inject.started_notice(started.call_id, missed, _style_for(started)))
        return "attach", started

    def _log_phone(self, call_id: str, what: str) -> None:
        """What the phone did, in the ring log: the only record of why a ring never reached it."""
        self.policy.log({"event": "phone", "call_id": call_id, "what": what})

    def on_answered(self, call: Call) -> None:
        with self.lock:
            if call.state != "ringing":
                return
            call.state, call.answered_at = "live", time.time()
            timer, call.ring_timer = call.ring_timer, None
            self.changed.notify_all()
        if timer is not None:
            timer.cancel()
        logger.info("hermes_voice: call %s answered", call.call_id[:8])
        if call.scheduled is not None:
            # No turn of the conversation is waiting for this call: it hears which call this is before the reply.
            call.inbox.put(self.schedule.answered(call))
        self._kick(call)

    def tell(self, origin: hermes.Origin, text: str, remote: bool = False) -> None:
        """Put a notice into a conversation that has no call (a scheduled call that was never placed), the way a
        call's notices get there: reopened if nobody has it open, retried while another process holds it, logged
        if it never gets in."""
        carrier = Call(self, new_call_id(), Owner.from_origin(origin, remote=remote), "agent", "ended")
        carrier.outcome = "not_placed"
        carrier.inbox.put(text)
        carrier.inbox.close()

    def on_turn(self, call: Call, turn: Turn) -> None:
        """Route a user turn: to the sync start_call waiting for it, else into the conversation."""
        with self.lock:
            waiter = call.waiter
            if waiter is not None and waiter.accepts(turn):
                waiter.turn = turn
                call.waiter = None
                # A sync start_call returning a hang-up already tells the agent the call is over.
                call.hang_up_turn = call.hang_up_turn or turn.ending == "hang_up"
                self.changed.notify_all()
                return
            text = inject.turn_text(turn.ending, turn.text, turn.error)
            if text is None:
                return
            if turn.ending == "hang_up":
                call.hang_up_turn = True
        call.inbox.put(text)

    def deliver(self, call: Call, text: str) -> inject.Delivery:
        """Put `text` into the call owner's conversation (InjectQueue thread). When Hermes refuses it here because
        another Hermes process holds the chat, that process puts it in, if it attends on the hub socket
        (``holders``, set by ``hubsock.HubServer``); else the refusal stands and the queue tries again."""
        delivery = self._deliver(call, text)
        holders = self.holders
        if delivery.ok or not delivery.held or holders is None:
            return delivery
        owner = call.owner
        with owner.lock:
            ids = [owner.session_id, *sorted(owner.lineage - {owner.session_id})]
        try:
            through = holders([sid for sid in ids if sid], text)
        except Exception:  # noqa: BLE001 - the refusal stands
            logger.warning("hermes_voice: asking the process that holds the chat failed", exc_info=True)
            through = None
        return delivery if through is None else through

    def _deliver(self, call: Call, text: str) -> inject.Delivery:
        """Into a conversation of this process through its session host. A conversation in another process
        gets it there, through the call's route. What that process can't deliver while the conversation is idle
        is tried here too, but only into a session this process has open (turns that run in compute-host
        children belong to dashboard sessions); a messaging chat is never reopened here."""
        route = call.route
        if route is None and not call.owner.remote:
            return self.injector.deliver(call.owner, text)
        delivery = route.deliver(text) if route is not None else inject.Delivery(
            False, detail="the conversation's process isn't connected", fallback=True)
        if delivery.ok or not delivery.fallback or is_messaging(call.owner.source):
            return delivery
        live = getattr(self.injector, "deliver_live", None)
        local = live(call.owner, text) if callable(live) else self.injector.deliver(call.owner, text)
        if local.ok or local.held:
            return local
        return inject.Delivery(False, delivery.via, delivery.status, delivery.detail)

    def requeue(self, call: Call, text: str) -> None:
        """A turn the conversation's process took but no turn there read (a compute-host child, whose turns the
        dashboard starts): deliver it again, after what is queued. Once the call is over it goes straight into the
        session this process holds."""
        if call.inbox.put(text, open_only=True):
            return

        def late() -> None:
            live = getattr(self.injector, "deliver_live", None)
            delivery = live(call.owner, text) if callable(live) else inject.Delivery(False, detail="no session host")
            self.delivered(call, text, delivery)

        try:
            hermes.spawn_thread(late, name=f"hermes-voice-requeue-{call.call_id[:8]}")
        except RuntimeError:
            logger.warning("hermes_voice: a voice turn handed back after the call ended was lost")

    def delivered(self, call: Call, text: str, delivery: inject.Delivery, waited: float = 0.0,
                  late: bool = False) -> None:
        """How a delivery ended. One that failed, or got in late, goes into the ring log (what it was, never its
        text): nothing a call had for its chat is lost without a record."""
        self.deliveries.append((call.call_id, text, delivery))
        entry = {"call_id": call.call_id, "session_id": call.owner.session_id, "what": inject.kind_of(text)}
        if not delivery.ok:
            logger.warning("hermes_voice: couldn't deliver to %s: %s", call.owner.session_id, delivery.detail)
            reason = "chat_held" if delivery.held else " ".join((delivery.detail or "unknown").split())[:160]
            self.policy.log({"event": "undelivered", **entry, "reason": reason,
                             **({"waited_s": round(waited)} if delivery.held else {})})
        elif late:
            logger.info("hermes_voice: delivered to %s after %.0fs (the chat was held by another Hermes process)",
                        call.owner.session_id, waited)
            self.policy.log({"event": "delivered_late", **entry, "waited_s": round(waited)})

    def chat_held(self, call: Call, delivery: inject.Delivery) -> None:
        """Another Hermes process holds the call's chat, and what the call has for it can't be put in (InjectQueue
        thread, on every refusal). The user hears so through the hub's own speech, once per call and only while
        they are on it; the ring log gets it when first seen and when it is said."""
        with self.lock:
            announce = call.state == "live" and not call.held_announced
            first = not call.held_logged
            call.held_announced = call.held_announced or announce
            call.held_logged = True
        if announce:
            # A call the user starts fails its first delivery while the phone's link is still coming up.
            deadline = time.monotonic() + HELD_LINK_WAIT
            while not call.connected and call.state == "live" and time.monotonic() < deadline:
                time.sleep(0.05)
            self.enqueue_line(call, inject.CHAT_HELD_SPOKEN, mode="hub")  # "hub": no notice for the chat if it fails
        if first or announce:
            holder = re.search(r"opened by ([\w:.-]+)", delivery.detail or "")
            logger.warning("hermes_voice: call %s can't reach its chat %s: another Hermes process holds it%s",
                           call.call_id[:8], call.owner.session_id, " (told the user)" if announce else "")
            self.policy.log({"event": "chat_held", "call_id": call.call_id, "session_id": call.owner.session_id,
                             "holder": holder.group(1) if holder else "", "announced": announce})

    # ── hooks ────────────────────────────────────────────────────────────────────────────────────────────

    def note_turn_start(self, session_id: str, parent_session_id: str = "", user_message: Any = None) -> None:
        """pre_llm_call: the conversation is busy now; if it is the call's owner under a new id (compression
        rotated it), the call follows. A turn the user wrote themselves counts as their go-ahead for a call
        during quiet hours (``action: confirm``); Hermes' own follow-up turns and this plugin's injections don't."""
        if not session_id:
            return
        self.busy[session_id] = time.time()
        if len(self.busy) > 500:
            for key in list(self.busy)[:100]:
                self.busy.pop(key, None)
        if users_own_message(user_message):
            self.policy.note_user_turn(session_id)
        if parent_session_id and parent_session_id != session_id and hermes.subagent_parent() is None:
            self.schedule.rekey(parent_session_id, session_id)  # compression: its scheduled calls follow
        with self.lock:
            call = self.slot
        if call is None or call.owner.owns(session_id):
            return
        owner = call.owner
        record = hermes.live_record(owner.runtime_sid) if owner.runtime_sid else None
        if record is not None and hermes.record_session_id(record) == session_id:
            owner.rekey(session_id)
        elif parent_session_id and owner.owns(parent_session_id) and hermes.subagent_parent() is None:
            owner.rekey(session_id)

    def note_turn_end(self, session_id: str) -> None:
        self.busy.pop(session_id, None)

    def status(self) -> dict[str, Any]:
        settings = self.settings()
        with self.lock:
            active = self.slot.info() if self.slot is not None else None
        try:
            apns, _ = self.pusher.configured()
        except Exception:  # noqa: BLE001
            apns = False
        return {
            "calls": len(self.links),
            "tts": "fake" if settings.fake_tts else "elevenlabs",
            "h2": push.h2_available(),
            "apns_configured": bool(apns),
            "scribe_configured": bool(hermes.get_secret("ELEVENLABS_API_KEY")),
            "active_call": active,
            "hub_socket": socket_state(),
            # How many calls are scheduled to ring later (never what they say).
            "scheduled": self.schedule.count(),
        }


# ── results ────────────────────────────────────────────────────────────────────────────────────────────────


def bye_outcome(reason: str, ringing: bool) -> tuple[str, str]:
    """How a call ends when the phone says bye (outcome, detail). The phone's reasons: hang_up, declined,
    no_answer (its own ring timeout ran out first), error (it gave up on the call, e.g. its audio failed)."""
    if ringing:
        return ("no_answer", "") if reason == "no_answer" else ("declined", "")
    if reason == "error":
        return "lost", "the phone ended the call after an error"
    return "ended_by_user", ""


def _sync(call: Call, said: str, ending: Optional[str], outcome: str, note: str = "") -> dict[str, Any]:
    result: dict[str, Any] = {"said": said, "ending": ending, "outcome": outcome, "call_id": call.call_id}
    if note:
        result["note"] = note
    return result


def _ring_expiry_detail(call: Call) -> str:
    """Why a ring ran out, for the ring log: what APNs took and what the phone did with it."""
    if call.connected:
        return "the phone rang but nobody answered" if call.rang else "the phone connected but never reported ringing"
    if call.pushed:
        return (f"APNs accepted the push for {call.pushed} phone(s), but no phone connected for this call "
                "(push not delivered, app didn't wake, or the phone couldn't reach the dashboard)")
    return "no phone connected for this call"


def _refusal(mode: str, outcome: str, note: str) -> dict[str, Any]:
    if mode == "sync":
        return {"said": "", "ending": None, "outcome": outcome, "call_id": None, "note": note}
    return {"call_id": None, "status": outcome, "note": note}


def _outcome_note(outcome: str, detail: str, unheard: Any = ()) -> str:
    """How a call ended, for a sync start_call's result: what happened, that it is no preference of the user's,
    what they did not hear, and what to do now (the same as the notice an async call gets)."""
    if outcome == "ended_by_agent":
        return "The call was ended with end_call."
    what = {
        "no_answer": "The user didn't pick up.",
        "declined": "The user declined the call.",
        "push_failed": f"The phone couldn't be rung: {detail or 'the push failed'}.",
        "unreachable": "The phone never answered the ring (it may be offline).",
        "lost": "The call's connection was lost.",
        "ended_by_user": "The user hung up.",
    }.get(outcome)
    if what is None:
        return detail
    return f"{what} {inject.RESULT_SCOPE}{guidance.unheard_note(unheard)} {inject.after_call(outcome, unheard)}"


def _style_for(call: Call) -> str:
    """The user's call style for the notice that opens a call they placed ("" without one, or if it can't be
    read), from the conversation's own profile. The call's first start_call result then doesn't repeat it."""
    try:
        style = guidance.style_text(call.owner.profile_home)
    except Exception:  # noqa: BLE001 - the style is an extra: a call never fails over it
        logger.debug("hermes_voice: could not read the call style")
        return ""
    if style:
        guidance.mark_style_given(call.call_id)
    return style


def _previews() -> bool:
    """``alerts.previews``: whether conversation text (titles included) may go through APNs at all."""
    try:
        from .notify import current_settings as alert_settings
        return alert_settings().previews
    except Exception:  # noqa: BLE001
        return True


def _surface_of(origin: hermes.Origin) -> str:
    """Where the conversation runs: its messaging platform, else its session source."""
    platform = (origin.platform or "").strip().lower()
    return platform if is_messaging(platform) else (origin.source or platform or "").strip().lower()


def _quote(title: str) -> str:
    title = " ".join((title or "").split())[:80]
    return f'"{title}"' if title else ""


def clip(text: str, limit: int) -> tuple[str, str]:
    """Cut text to `limit` characters (at a word break when one is near) and say so in a note for the agent."""
    text = text.strip()
    if len(text) <= limit:
        return text, ""
    cut = text.rfind(" ", 0, limit + 1)
    clipped = text[: cut if cut > limit // 2 else limit].rstrip()
    return clipped, (
        f" Only the first {len(clipped)} of {len(text)} characters were spoken; the rest was cut. Say what still "
        "matters in a short next line."
    )


# ── socket helpers (ported from hermes-voice-mcp) ──────────────────────────────────────────────────────────


class _Utterance:
    """Sends one line to whichever link the call has now, restarting it on a new socket after a reconnect."""

    def __init__(self, hub: CallHub, call_id: str, start: dict[str, Any]) -> None:
        self.hub = hub
        self.call_id = call_id
        self.start = start
        self.socket: Any = None
        self.started = False
        self.resumed = False

    async def send(self, payload: bytes | dict[str, Any] | None = None) -> bool:
        """Send `payload` (after speech_start, if this socket has not had it). False once the call is gone."""
        avoid: Any = None
        while (link := await self.hub.line(self.call_id, avoid=avoid)) is not None:
            try:
                if link.socket is not self.socket:
                    self.resumed = self.resumed or self.started
                    self.started = True
                    await _send_on(link, self.start)
                    self.socket = link.socket
                if payload is not None:
                    await _send_on(link, payload)
                return True
            except _Stalled:
                self.hub.stall(link)
                avoid = link.socket
            except _SOCKET_GONE:
                avoid = link.socket
        return False

    async def notify(self, message: dict[str, Any], shield: bool = False) -> None:
        """Time-bounded send on the current link, without waiting for a reconnect. A link that doesn't take it
        is stalled like in `send`: otherwise the phone would wait on the line (and keep its microphone paused)
        for as long as the link stays up. Once closed, the phone drops the line and reconnects."""
        link = self.hub.links.get(self.call_id)
        if link is None or link.ended.is_set():
            return  # gone or already stalled: the phone drops the line when that link closes

        async def deliver() -> None:
            try:
                await _send_on(link, message, timeout=NOTICE_TIMEOUT)
            except Exception:  # noqa: BLE001 - _Stalled or the socket going away
                self.hub.stall(link)

        sending = asyncio.ensure_future(deliver())
        if not shield:
            await sending
            return
        try:
            await asyncio.shield(sending)
        except asyncio.CancelledError:
            pass  # cancelled again: it still finishes in the background, bounded by NOTICE_TIMEOUT


class _Stalled(Exception):
    """A link didn't take a frame: it was replaced meanwhile, or stopped reading."""


async def _send_on(link: PhoneLink, payload: bytes | dict[str, Any], timeout: Optional[float] = None) -> None:
    """Send one frame on the link. A send waits while the socket's write buffer is full, which on a half-open
    path never ends, so it gives up (raising _Stalled) once the link is replaced or `timeout` (default
    SEND_TIMEOUT) passes. Cancelling it is clean: uvicorn writes a frame whole after its only wait."""
    socket = link.socket
    sending = asyncio.ensure_future(
        socket.send_bytes(payload) if isinstance(payload, bytes) else socket.send_json(payload)
    )
    replaced = asyncio.ensure_future(link.ended.wait())
    try:
        await asyncio.wait(
            {sending, replaced},
            timeout=SEND_TIMEOUT if timeout is None else timeout,
            return_when=asyncio.FIRST_COMPLETED,
        )
    except BaseException:
        sending.cancel()
        raise
    finally:
        replaced.cancel()
    if not sending.done():
        sending.cancel()
        raise _Stalled
    sending.result()


async def _next_message(ws: Any) -> Optional[dict[str, Any]]:
    """The phone's next JSON object; None for any other frame. Raises WebSocketDisconnect when it goes away."""
    message = await ws.receive()
    if message["type"] == "websocket.disconnect":
        raise WebSocketDisconnect(message.get("code", 1000))
    try:
        data = json.loads(message.get("text") or "")
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


async def _turn_away(ws: Any, past: Optional[Call]) -> None:
    """A hello for a call that is over: say how it ended (cancel if it never went live), then close."""
    if past is None:
        message: dict[str, Any] = {"type": "cancel", "reason": "unknown_call"}
    elif past.answered_at is None:
        message = {"type": "cancel", "reason": past.outcome or "ended"}
    else:
        message = {"type": "ended", "outcome": past.outcome or "ended_by_agent"}
    await _goodbye(ws, message)


async def _goodbye(ws: Any, message: Optional[dict[str, Any]]) -> None:
    if message is not None:
        try:
            await asyncio.wait_for(ws.send_json(message), NOTICE_TIMEOUT)
        except Exception:  # noqa: BLE001 - the phone is gone or not reading: closing is all that's left
            pass
    await _close_quietly(ws, 1000)


async def _close_quietly(ws: Any, code: int) -> None:
    try:
        await ws.close(code=code)
    except Exception:  # noqa: BLE001 - already closed
        pass


def _optional_str(value: Any) -> Optional[str]:
    return str(value)[:200] if value else None


def _timestamp(value: Any) -> Optional[float]:
    """An ISO-8601 time as epoch seconds (a time without a zone is UTC)."""
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        moment = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


# ── one hub per process ────────────────────────────────────────────────────────────────────────────────────

_HUB_KEY = "_hermes_voice_hub"
_ROUTES_KEY = "_hermes_voice_routes_mounted"
_HUB_LOCK = sys.__dict__.setdefault("_hermes_voice_hub_lock", threading.Lock())


def get_hub() -> CallHub:
    """The process's call hub, shared by the tools and the dashboard routes (kept on sys.__dict__)."""
    with _HUB_LOCK:
        hub = sys.__dict__.get(_HUB_KEY)
        if hub is None:
            hub = CallHub()
            sys.__dict__[_HUB_KEY] = hub
        return hub


def install_hub(hub: Optional[CallHub]) -> None:
    """Replace the process's hub (tests)."""
    with _HUB_LOCK:
        if hub is None:
            sys.__dict__.pop(_HUB_KEY, None)
        else:
            sys.__dict__[_HUB_KEY] = hub


def mark_routes_mounted() -> None:
    sys.__dict__[_ROUTES_KEY] = True
    serve_socket_when_ready()
    run_schedule_when_ready()


_SOCKET_KEY = "_hermes_voice_hub_socket"
# Its states: absent (not opened), "waiting" (a thread waits to open it), a HubServer, "taken" (another dashboard
# serves the folder; the thread keeps trying), "paused" (the plugin unloaded) or None (opening failed).
_WAITING, _TAKEN, _PAUSED = "waiting", "taken", "paused"
# How often a dashboard whose hub socket another one holds checks whether it can take it over.
SOCKET_RETRY_S = 3.0


def serve_socket_when_ready() -> None:
    """Open the hub's socket for the other Hermes processes (``hubsock.py``) once this process serves the
    dashboard: the routes are mounted at import, before the web server binds, and other processes import them too
    without serving. Once per process (and again after ``resume_socket``); ``HERMES_VOICE_HUB_SOCKET=0`` turns it
    off (the unit tests do)."""
    if os.environ.get("HERMES_VOICE_HUB_SOCKET", "").strip() == "0":
        return
    with _HUB_LOCK:
        if _SOCKET_KEY in sys.__dict__:
            return
        sys.__dict__[_SOCKET_KEY] = _WAITING
    try:
        hermes.spawn_thread(_open_socket, name="hermes-voice-hubsock")
    except RuntimeError:
        sys.__dict__.pop(_SOCKET_KEY, None)


def _open_socket() -> None:
    """Wait until this process serves, then open the socket. While another live dashboard holds it (a second
    `hermes serve` in the same home, or one still shutting down), keep trying, and take over once it stops."""
    deadline = time.monotonic() + SOCKET_WAIT_LIMIT
    while not hermes.dashboard_serving():
        if time.monotonic() > deadline:
            with _HUB_LOCK:
                if sys.__dict__.get(_SOCKET_KEY) == _WAITING:
                    sys.__dict__.pop(_SOCKET_KEY, None)
            return  # imported, never served (an Ink TUI showing an image imports the web server)
        time.sleep(0.5)
    from . import hubsock
    warned = False
    while True:
        with _HUB_LOCK:
            if sys.__dict__.get(_SOCKET_KEY) not in (_WAITING, _TAKEN):
                return  # the plugin unloaded meanwhile
        try:
            server: Any = hubsock.serve(get_hub())
        except hubsock.Taken as error:
            if not warned:
                logger.warning("hermes_voice: %s; calls from other Hermes processes ring through that one until "
                               "it stops, then through this one", error)
                warned = True
            with _HUB_LOCK:
                if sys.__dict__.get(_SOCKET_KEY) == _WAITING:
                    sys.__dict__[_SOCKET_KEY] = _TAKEN
            time.sleep(SOCKET_RETRY_S)
            continue
        except Exception:  # noqa: BLE001 - calls from this process still work
            logger.warning("hermes_voice: could not open the hub socket for other processes", exc_info=True)
            server = None
        with _HUB_LOCK:
            if sys.__dict__.get(_SOCKET_KEY) in (_WAITING, _TAKEN):
                sys.__dict__[_SOCKET_KEY] = server
                return
        if server is not None:
            server.close()  # unloaded while it opened
        return


def socket_state() -> str:
    """The hub socket as ``GET /status`` shows it: open, waiting, taken (another dashboard serves it), paused
    (the plugin unloaded), failed or off."""
    state = sys.__dict__.get(_SOCKET_KEY, "off")
    if state is None:
        return "failed"
    return state if isinstance(state, str) else "open"


def pause_socket() -> None:
    """The plugin unloads: stop serving other processes (their calls answer not_available), until it loads again."""
    with _HUB_LOCK:
        state = sys.__dict__.get(_SOCKET_KEY)
        if _SOCKET_KEY not in sys.__dict__:
            return
        sys.__dict__[_SOCKET_KEY] = _PAUSED
    close = getattr(state, "close", None)
    if callable(close):
        close()


def resume_socket() -> None:
    """The plugin loaded again in a process whose hub socket an unload closed."""
    with _HUB_LOCK:
        if sys.__dict__.get(_SOCKET_KEY) != _PAUSED:
            return
        del sys.__dict__[_SOCKET_KEY]
    serve_socket_when_ready()


# Scheduled calls ring from the dashboard process. The key's states: absent (not started), "waiting" (a thread
# waits for the dashboard to serve), "running", or "paused" (the plugin unloaded).
_SCHEDULE_KEY = "_hermes_voice_schedule"
_RUNNING = "running"


def run_schedule_when_ready() -> None:
    """Start ringing the scheduled calls (``schedule.py``) once this process serves the dashboard, as with the hub
    socket: other processes mount the routes too, without serving. Once per process (and again after
    ``resume_schedule``); ``HERMES_VOICE_SCHEDULE=0`` turns it off (the unit tests drive their own)."""
    if os.environ.get("HERMES_VOICE_SCHEDULE", "").strip() == "0":
        return
    with _HUB_LOCK:
        if _SCHEDULE_KEY in sys.__dict__:
            return
        sys.__dict__[_SCHEDULE_KEY] = _WAITING
    try:
        hermes.spawn_thread(_start_schedule, name="hermes-voice-schedule-start")
    except RuntimeError:
        sys.__dict__.pop(_SCHEDULE_KEY, None)


def _start_schedule() -> None:
    deadline = time.monotonic() + SOCKET_WAIT_LIMIT
    while not hermes.dashboard_serving():
        if time.monotonic() > deadline:
            with _HUB_LOCK:
                if sys.__dict__.get(_SCHEDULE_KEY) == _WAITING:
                    sys.__dict__.pop(_SCHEDULE_KEY, None)
            return  # imported, never served
        time.sleep(0.5)
    with _HUB_LOCK:
        if sys.__dict__.get(_SCHEDULE_KEY) != _WAITING:
            return  # the plugin unloaded meanwhile
        sys.__dict__[_SCHEDULE_KEY] = _RUNNING
    get_hub().schedule.start()


def pause_schedule() -> None:
    """The plugin unloads: stop ringing scheduled calls (they stay in the file) until it loads again."""
    with _HUB_LOCK:
        if _SCHEDULE_KEY not in sys.__dict__:
            return
        state, sys.__dict__[_SCHEDULE_KEY] = sys.__dict__[_SCHEDULE_KEY], _PAUSED
        hub = sys.__dict__.get(_HUB_KEY)
    if state == _RUNNING and hub is not None:
        hub.schedule.stop()


def resume_schedule() -> None:
    """The plugin loaded again in a process whose schedule an unload stopped."""
    with _HUB_LOCK:
        if sys.__dict__.get(_SCHEDULE_KEY) != _PAUSED:
            return
        del sys.__dict__[_SCHEDULE_KEY]
    run_schedule_when_ready()


def routes_mounted() -> bool:
    """The phone's routes are mounted in this process and it serves them: the dashboard's web server is running
    here (other processes import it, and so mount the routes, without serving anything)."""
    return bool(sys.__dict__.get(_ROUTES_KEY)) and hermes.dashboard_serving()
