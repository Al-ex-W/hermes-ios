"""Calls from conversations outside the dashboard process: the CLI, the Ink TUI, the messaging gateway, cron, and
compute-host children (``dashboard.turn_isolation``). The phone's socket and the call slot live in the dashboard's
hub; these processes reach it over its local socket (``hubsock.py``) and put what the user says into their own
conversation (``inject.deliver_here``).

- ``start_call`` sends ``ring`` (and, for a sync call, waits with ``await_turn`` inside Hermes' human-wait window
  while this tool thread watches for Stop and yield requests; the wait ends before Hermes' tool deadline would,
  ``hermes.tool_wait_cap``). With ``in_minutes`` / ``at`` it sends ``schedule`` instead: the hub keeps the call
  and rings at its time (``schedule.py``); nothing of it stays in this process.
- Every call this process starts or speaks into gets a subscription: a connection that takes the call's turns and
  puts each into the conversation (steering the running turn, or starting one).
- The ``pre_llm_call`` / ``on_session_end`` hooks tell which conversations are mid-turn (``inject.Turns``, with the
  agent's own state winning), keep the call with its conversation when compression gives it a new id, and note
  when the user wrote (quiet hours).
- A process that hosts sessions of its own (a Desktop backend, the Ink TUI) also attends the hub for the chats it
  holds (``Attendant``): a call the user starts from the phone in such a chat belongs to a dashboard session the
  dashboard may not write, so this process puts the call's notices and turns into its own live session.

No dashboard (or no plugin there): ``start_call`` answers ``not_available``.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import threading
import time
from collections import deque
from typing import Any, Callable, Optional

from . import hermes, hub, inject, policy
from .hubsock import PROTOCOL, SOCKET_NAME, TOKEN_NAME, socket_path

logger = logging.getLogger("hermes_voice")

CONNECT_TIMEOUT = 3.0
RING_TIMEOUT = 90.0  # a sync ring sends the push before answering
END_TIMEOUT = 90.0  # end_call speaks the goodbye first (up to a minute)
REQUEST_TIMEOUT = 15.0
POLL = 0.25
REFUSED = frozenset({"busy", "not_allowed", "not_available", "no_call"})

NOT_AVAILABLE = (
    "Voice calls aren't available here: no Hermes dashboard with the hermes_voice plugin is running on this host "
    "(start_call reaches the phone through `hermes serve`). Reply in text."
)


class NotAvailable(Exception):
    """No hub to talk to."""


class RemoteError(Exception):
    def __init__(self, error: str, message: str = "") -> None:
        super().__init__(f"{error}: {message}" if message else error)
        self.error = error


# ── the connection ─────────────────────────────────────────────────────────────────────────────────────────


class Client:
    """One connection to the hub's socket (JSON lines; see ``hubsock.py``)."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buffer = b""
        # Events that arrived while a request waited for its answer (a subscription's first turn can come
        # before the answer to subscribe_turns): recv() hands them out first.
        self.backlog: deque[dict] = deque()
        self.wlock = threading.Lock()
        self.next_id = 0
        self.closed = False

    @classmethod
    def connect(cls, folders: Optional[list] = None) -> "Client":
        """Connect and authenticate (the token file next to the socket). Tries this profile's folder, then the
        Hermes root's."""
        why = "no hub socket"
        for folder in folders if folders is not None else hermes.hub_folders():
            target = socket_path(folder)
            if target is None:
                continue
            try:
                token = (folder / TOKEN_NAME).read_text(encoding="utf-8").strip()
            except OSError:
                why = "the hub's token is unreadable"
                continue
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(CONNECT_TIMEOUT)
            try:
                sock.connect(target)
            except OSError as error:
                sock.close()
                why = f"the hub socket refused the connection ({type(error).__name__})"
                continue
            client = cls(sock)
            try:
                client.send({"op": "hello", "token": token, "version": PROTOCOL})
                answer = client.recv(CONNECT_TIMEOUT)
            except (OSError, ConnectionError):
                answer = None
            if isinstance(answer, dict) and answer.get("ok") is True:
                sock.settimeout(None)
                return client
            client.close()
            why = "the hub refused this process (stale token?)"
        raise NotAvailable(why)

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        for step in (lambda: self.sock.shutdown(socket.SHUT_RDWR), self.sock.close):
            try:
                step()
            except OSError:
                pass

    def send(self, message: dict) -> None:
        data = (json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with self.wlock:
            self.sock.sendall(data)

    def recv(self, timeout: Optional[float]) -> Optional[dict]:
        """The next message, or None when `timeout` passes first. Raises ConnectionError once the hub is gone."""
        if self.backlog:
            return self.backlog.popleft()
        return self._read(timeout)

    def _read(self, timeout: Optional[float]) -> Optional[dict]:
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line.strip():
                    try:
                        message = json.loads(line.decode("utf-8"))
                    except (UnicodeDecodeError, ValueError):
                        continue
                    if isinstance(message, dict):
                        return message
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                return None
            self.sock.settimeout(remaining)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            except OSError as error:
                raise ConnectionError(str(error)) from error
            if not chunk:
                raise ConnectionError("the hub closed the connection")
            self.buffer += chunk

    def request(self, op: str, params: Optional[dict] = None, timeout: Optional[float] = REQUEST_TIMEOUT,
                watch: Optional[Callable[[], list]] = None) -> dict:
        """Send a request and wait for its answer. `watch` runs while waiting: the signals it returns go to the
        hub for this request (``interrupt`` / ``yield``)."""
        self.next_id += 1
        rid = self.next_id
        self.send({"id": rid, "op": op, **(params or {})})
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            message = self._read(POLL)
            if message is None:
                if watch is not None:
                    for signal in watch():
                        self.send({"op": "signal", "ref": rid, **signal})
                if deadline is not None and time.monotonic() > deadline:
                    raise TimeoutError(f"the hub didn't answer {op}")
                continue
            if message.get("id") != rid:
                if "event" in message:
                    self.backlog.append(message)
                continue
            if message.get("ok") is True and isinstance(message.get("result"), dict):
                return message["result"]
            raise RemoteError(str(message.get("error") or "error"), str(message.get("message") or ""))


class _Watch:
    """What a waiting tool thread tells the hub: Stop (once), and each time Hermes asks the tool to yield. Also
    keeps Hermes' inactivity watchdog quiet."""

    def __init__(self, label: str = "voice call") -> None:
        self.beat = hermes.heartbeat(label)
        self.stopped = False

    def __call__(self) -> list:
        signals: list = []
        if not self.stopped and hermes.is_interrupted():
            self.stopped = True
            signals.append({"interrupt": True})
        elif not self.stopped and hermes.take_yield():
            signals.append({"yield": True})
        self.beat()
        return signals


# ── this process's conversations ───────────────────────────────────────────────────────────────────────────

_lock = threading.Lock()
_contexts: list[Any] = []
_user_turn_at: dict[str, float] = {}
_subscriptions: dict[str, "Subscription"] = {}


def bind_context(ctx: Any) -> None:
    """Remember the plugin context ``register(ctx)`` got (one per profile in a multi-profile gateway)."""
    with _lock:
        if ctx not in _contexts:
            _contexts.append(ctx)


def context() -> Any:
    """The plugin context for the profile this thread works in (a multi-profile gateway has one per profile).
    With several and none for this profile, None: another profile's context can't start a turn here."""
    with _lock:
        contexts = list(_contexts)
    if len(contexts) <= 1:
        return contexts[0] if contexts else None
    home = hermes.home_key(hermes.hermes_home())
    for ctx in contexts:
        manager = getattr(ctx, "_manager", None)
        key = getattr(manager, "scope_key", None) or getattr(manager, "home_path", None)
        if key is not None and hermes.home_key(key) == home:
            return ctx
    logger.warning("hermes_voice: no plugin context for this profile's home; turns can't be started here")
    return None


def note_turn_start(session_id: str, parent_session_id: str = "", user_message: Any = None) -> None:
    """``pre_llm_call`` in this process: the conversation is mid-turn; its call follows it under a new id after
    compression (the same agent, or a continuation of its id); the user's own message counts as their go-ahead
    during quiet hours."""
    if not session_id:
        return
    agent = hermes.bound_agent()
    TURNS.start(session_id, agent)
    if policy.users_own_message(user_message):
        with _lock:
            _user_turn_at[session_id] = time.time()
            if len(_user_turn_at) > 500:
                for key in list(_user_turn_at)[:100]:
                    _user_turn_at.pop(key, None)
    with _lock:
        subscriptions = list(_subscriptions.values())
    continuation = bool(parent_session_id) and hermes.subagent_parent() is None
    for subscription in subscriptions:
        target = subscription.target
        if session_id == target.session_id:
            continue
        if (agent is not None and target.agent() is agent) or (continuation and parent_session_id in target.ids()):
            subscription.rekey(session_id)


def note_turn_end(session_id: str) -> None:
    """``on_session_end``: the turn is over; voice turns steered into it that it never read start a turn now."""
    for target, text in TURNS.end(session_id, hermes.bound_agent()):
        hermes.spawn_thread(_late_delivery, target, text, name="hermes-voice-late-turn")


def _late_delivery(target: inject.AgentTarget, text: str) -> None:
    """A voice turn steered into a turn that ended without reading it. A compute-host child hands it back to the
    hub, which puts it through the dashboard (that starts the child's turns); anywhere else it starts a turn."""
    if hermes.is_compute_host_child():
        with _lock:
            found = [sub for sub in _subscriptions.values() if sub.target is target]
        if found and found[0].requeue(text):
            return
        logger.warning("hermes_voice: a voice turn the conversation didn't read was lost (its call is over)")
        return
    delivery = inject.inject_idle(target, text)
    if not delivery.ok:
        logger.warning("hermes_voice: a voice turn the conversation didn't read couldn't start a turn: %s",
                       delivery.detail)


TURNS = inject.Turns(late=_late_delivery)


def origin_for(session_id: Any) -> hermes.Origin:
    """The calling conversation as the hub sees it (see ``hubsock.origin_from``)."""
    origin = hermes.origin(session_id)
    origin.runtime_sid, origin.profile_home = "", None  # this process's, meaningless to the hub
    ctx = context()
    if not origin.source and not policy.is_messaging(origin.platform):
        # The client the session runs in (cli / tui / desktop, or a messaging platform); a local session whose
        # turns run in the gateway says only "local" otherwise.
        surface = ""
        reader = getattr(ctx, "session_surface", None) if ctx is not None else None
        if callable(reader):
            try:
                surface = str(reader() or "").strip().lower()
            except Exception:  # noqa: BLE001
                surface = ""
        if not surface and hermes.is_compute_host_child():
            surface = "dashboard"  # a dashboard session's turn, run in a child process
        if policy.is_messaging(surface):
            origin.platform = surface
        elif surface != origin.platform:
            origin.source = surface
    origin.session_key = hermes.current_session_key()
    platform = (origin.platform or "").strip().lower()
    if policy.is_messaging(platform) and origin.chat_type == "dm":
        origin.is_owner = policy.gateway_owner(platform, origin.user_id)
    with _lock:
        origin.user_turn_at = _user_turn_at.get(origin.session_id, 0.0)
    if not origin.title:
        origin.title = platform.capitalize() if policy.is_messaging(platform) else ""
    return origin


def target_for(origin: hermes.Origin) -> inject.AgentTarget:
    return inject.AgentTarget.capture(origin.session_id, origin.session_key, hermes.turn_agent(), context())


def idle_delivery_problem(target: inject.AgentTarget, origin: hermes.Origin) -> Optional[str]:
    """Why what the user says couldn't start a turn here while the conversation is idle, or None."""
    if inject.classic_cli(target.context) or hermes.is_compute_host_child():
        return None  # the CLI takes it as is; a compute-host child's dashboard takes it
    if hermes.methods() is not None and hermes.find_live(origin.session_id) is not None:
        return None  # the Ink TUI hosts this session itself
    # Anything else (the gateway's sessions: messaging chats, and local ones whose turns it runs) needs Hermes'
    # permission for a plugin to start a turn.
    return None if hermes.gateway_injection_allowed() else inject.INJECTION_OFF


# ── the tools ──────────────────────────────────────────────────────────────────────────────────────────────


def start_call(session_id: Any, text: str, mode: str) -> dict[str, Any]:
    """``start_call`` from this process, through the dashboard's hub."""
    started = time.monotonic()
    origin = origin_for(session_id)
    if not origin.session_id:
        return refusal(mode, "not_allowed", "This conversation can't place a call.")
    target = target_for(origin)
    try:
        client = Client.connect()
    except NotAvailable as why:
        logger.info("hermes_voice: no hub for start_call: %s", why)
        return refusal(mode, "not_available", NOT_AVAILABLE, error="not_available")
    problem = idle_delivery_problem(target, origin)
    if problem and mode == "async":
        client.close()
        return refusal(mode, "not_available", (
            f"{problem}. Set plugins.entries.hermes_voice.allow_gateway_injection: true in config.yaml, or use "
            "mode \"sync\", which returns the user's reply directly."), error="allow_gateway_injection")
    try:
        with client:
            result = client.request("ring", {"origin": payload(origin), "text": text, "mode": mode},
                                    timeout=RING_TIMEOUT)
            call_id = result.get("call_id")
            if isinstance(call_id, str) and call_id and result.get("status") not in REFUSED:
                subscribe(call_id, origin, target)
            waiter = result.get("waiter")
            if isinstance(waiter, str):
                params: dict[str, Any] = {"waiter": waiter}
                cap = hermes.tool_wait_cap(started)
                if cap:
                    params["cap_s"] = cap
                with hermes.human_wait():
                    result = client.request("await_turn", params, timeout=None, watch=_Watch())
    except (ConnectionError, OSError, TimeoutError, RemoteError) as error:
        logger.warning("hermes_voice: start_call through the hub failed: %s", error)
        return refusal(mode, "not_available", "The voice call service stopped answering. Reply in text.",
                       error="not_available")
    if problem:
        result["note"] = (f"{result.get('note') or ''} Note: {problem}; keep using mode \"sync\" on this call, "
                          "or what the user says while you're idle is lost.").strip()
    return result


def end_call(session_id: Any, text: str) -> dict[str, Any]:
    origin = origin_for(session_id)
    try:
        with Client.connect() as client:
            return client.request("end", {"origin": payload(origin), "text": text}, timeout=END_TIMEOUT,
                                  watch=_Watch("voice call goodbye"))
    except NotAvailable:
        return {"call_id": None, "outcome": None, "note": "This conversation has no voice call running."}
    except (ConnectionError, OSError, TimeoutError, RemoteError) as error:
        logger.warning("hermes_voice: end_call through the hub failed: %s", error)
        return {"error": "Couldn't hang up: the voice call service stopped answering."}


# A dashboard whose plugin is older than this one doesn't know the op (``unknown_op``): it must not ring now instead.
SCHEDULE_UNKNOWN = ("The Hermes dashboard runs an older hermes_voice that can't schedule calls; restart `hermes "
                    "serve`. Nothing was scheduled or cancelled: tell the user.")


def schedule_call(session_id: Any, text: str, in_minutes: Any, at: Any) -> dict[str, Any]:
    """``start_call`` with ``in_minutes`` / ``at`` from this process: the dashboard's hub keeps the call and rings
    at its time (``schedule.py``)."""
    return _scheduling("schedule", session_id, {"text": text, "in_minutes": in_minutes, "at": at})


def scheduled_calls(session_id: Any, cancel: Any = None) -> dict[str, Any]:
    """The ``scheduled_calls`` tool from this process: list this conversation's scheduled calls, or cancel."""
    return _scheduling("scheduled_calls", session_id, {"cancel": cancel})


def _scheduling(op: str, session_id: Any, params: dict[str, Any]) -> dict[str, Any]:
    origin = origin_for(session_id)
    if not origin.session_id:
        return {"status": "not_allowed", "scheduled_id": None, "note": "This conversation can't place a call."}
    try:
        with Client.connect() as client:
            return client.request(op, {"origin": payload(origin), **params})
    except NotAvailable:
        return {"status": "not_available", "scheduled_id": None, "note": NOT_AVAILABLE, "error": "not_available"}
    except RemoteError as error:
        logger.warning("hermes_voice: %s through the hub failed: %s", op, error)
        if error.error == "unknown_op":
            return {"error": SCHEDULE_UNKNOWN}
        return {"error": f"The voice call service refused that ({error}). Nothing was scheduled or cancelled."}
    except (ConnectionError, OSError, TimeoutError) as error:
        logger.warning("hermes_voice: %s through the hub failed: %s", op, error)
        return {"error": "The voice call service stopped answering. Nothing was scheduled or cancelled: tell the user."}


def status() -> Optional[dict[str, Any]]:
    """The hub's status, or None without one."""
    try:
        with Client.connect() as client:
            return client.request("status")
    except (NotAvailable, ConnectionError, OSError, TimeoutError, RemoteError):
        return None


def reachable() -> bool:
    """A hub socket exists for this profile (not checked further: that is what a call does)."""
    return any(socket_path(folder) is not None for folder in hermes.hub_folders())


def payload(origin: hermes.Origin) -> dict[str, Any]:
    return {
        "session_id": origin.session_id, "profile": origin.profile, "title": origin.title, "source": origin.source,
        "platform": origin.platform, "chat_type": origin.chat_type, "user_id": origin.user_id,
        "is_cron": origin.is_cron, "is_subagent": origin.is_subagent, "session_key": origin.session_key,
        "is_owner": origin.is_owner, "user_turn_at": origin.user_turn_at,
    }


def refusal(mode: str, outcome: str, note: str, error: str = "") -> dict[str, Any]:
    if mode == "sync":
        result: dict[str, Any] = {"said": "", "ending": None, "outcome": outcome, "call_id": None, "note": note}
    else:
        result = {"call_id": None, "status": outcome, "note": note}
    if error:
        result["error"] = error
    return result


# ── subscriptions ──────────────────────────────────────────────────────────────────────────────────────────


def subscribe(call_id: str, origin: hermes.Origin, target: inject.AgentTarget) -> "Subscription":
    """Take the call's turns in this process (once per call; a later call to it brings a fresher agent)."""
    with _lock:
        current = _subscriptions.get(call_id)
        if current is not None and not current.done.is_set():
            current.refresh(target)
            return current
        subscription = _subscriptions[call_id] = Subscription(call_id, origin, target)
    subscription.start()
    return subscription


def subscriptions() -> dict[str, "Subscription"]:
    with _lock:
        return dict(_subscriptions)


class Subscription:
    """The call's turns, put into this process's conversation as they come."""

    def __init__(self, call_id: str, origin: hermes.Origin, target: inject.AgentTarget) -> None:
        self.call_id = call_id
        self.origin = origin
        self.target = target
        self.client: Optional[Client] = None
        self.ready = threading.Event()
        self.done = threading.Event()
        self.outcome: Optional[str] = None
        self.deliveries: list[inject.Delivery] = []

    def start(self) -> None:
        try:
            hermes.spawn_thread(self._run, name=f"hermes-voice-turns-{self.call_id[:8]}")
        except RuntimeError:
            self._finish()

    def refresh(self, target: inject.AgentTarget) -> None:
        if target.agent() is not None:
            target.owner = self.target.owner
            self.target = target

    def rekey(self, session_id: str) -> None:
        self.target.rekey(session_id)
        self.origin.session_id = session_id
        self._tell({"op": "rekey", "call_id": self.call_id, "session_id": session_id})

    def requeue(self, text: str) -> bool:
        """Give the hub back a turn this process took but no turn read (a compute-host child): the dashboard puts
        it in. False when the call's connection is gone."""
        return not self.done.is_set() and self._tell({"op": "requeue", "call_id": self.call_id, "text": text})

    def _tell(self, message: dict) -> bool:
        client = self.client
        if client is None or client.closed:
            return False
        try:
            client.send(message)
            return True
        except OSError:
            return False

    def _run(self) -> None:
        try:
            client = self.client = Client.connect()
        except NotAvailable as why:
            logger.warning("hermes_voice: can't take call %s's turns: %s", self.call_id[:8], why)
            self._finish()
            return
        try:
            answer = client.request("subscribe_turns", {"call_id": self.call_id, "origin": payload(self.origin)})
            if answer.get("subscribed") is not True:
                self.outcome = answer.get("outcome")
                return
            self.ready.set()
            while True:
                message = client.recv(None)
                if message is None:
                    continue
                if message.get("event") == "turn":
                    self._turn(client, message)
                elif message.get("event") == "ended":
                    self.outcome = str(message.get("outcome") or "")
                    return
        except (ConnectionError, OSError, TimeoutError, RemoteError) as error:
            logger.info("hermes_voice: call %s's turns stopped: %s", self.call_id[:8], error)
        finally:
            client.close()
            self._finish()

    def _turn(self, client: Client, message: dict) -> None:
        text = message.get("text")
        if not isinstance(text, str) or not text:
            delivery = inject.Delivery(False, detail="empty turn")
        else:
            try:
                delivery = inject.deliver_here(self.target, text, TURNS)
            except Exception as error:  # noqa: BLE001 - report it, never drop the subscription
                logger.warning("hermes_voice: delivering a voice turn failed", exc_info=True)
                delivery = inject.Delivery(False, detail=type(error).__name__, fallback=True)
        self.deliveries.append(delivery)
        if not delivery.ok:
            logger.warning("hermes_voice: voice turn for %s not delivered here: %s", self.target.session_id,
                           delivery.detail)
        client.send({"op": "delivered", "call_id": self.call_id, "seq": message.get("seq"), "ok": delivery.ok,
                     "via": delivery.via, "status": delivery.status, "detail": delivery.detail,
                     "fallback": delivery.fallback, "held": delivery.held})

    def _finish(self) -> None:
        self.ready.set()
        self.done.set()
        with _lock:
            if _subscriptions.get(self.call_id) is self:
                del _subscriptions[self.call_id]


# ── the chats this process holds ───────────────────────────────────────────────────────────────────────────

# How often a process that hosts sessions looks for the dashboard's hub while it has no connection to it.
ATTEND_IDLE_S = 5.0


class Attendant:
    """This process's standing connection to the dashboard's hub, for the chats it holds.

    Hermes keeps one writer per conversation: a process that ran a turn in a chat holds it (a lease in
    ``runtime/active_sessions.json``) for as long as it has the chat open, and every other process's
    ``prompt.submit`` for it is refused. A Desktop backend holds every chat the Desktop app has open, so a call the
    user starts from the phone in one of them can't be written by the dashboard. This process can write it: it
    tells the hub it is there (``attend``), says whether it has a chat open when asked (``find``), and puts what the
    call has for it into its own live session (``deliver``), the way the dashboard does for its own.

    Runs wherever the plugin loads; connects only where this process hosts sessions and isn't the dashboard itself
    (``eligible``), and keeps looking for a hub while there is none (the dashboard may start later, or restart)."""

    def __init__(self, folders: Optional[list] = None, idle_s: float = ATTEND_IDLE_S) -> None:
        self.folders = folders
        self.idle_s = idle_s
        self.stop = threading.Event()
        self.attending = threading.Event()
        self.client: Optional[Client] = None
        self.injector = inject.TuiInjector()
        self.unsupported = False

    def start(self) -> None:
        hermes.spawn_thread(self._run, name="hermes-voice-attend")

    def close(self) -> None:
        self.stop.set()
        client = self.client
        if client is not None:
            client.close()

    def eligible(self) -> bool:
        """This process hosts sessions (``tui_gateway.server`` is loaded: a Desktop backend, the Ink TUI), isn't
        the dashboard (its hub delivers into its own sessions) and isn't a compute-host child (whose sessions are
        the dashboard's)."""
        return hermes.methods() is not None and not hub.routes_mounted() and not hermes.is_compute_host_child()

    def _run(self) -> None:
        while not self.stop.is_set():
            if self.eligible():
                try:
                    self._serve()
                except NotAvailable:
                    pass  # no dashboard with the plugin (yet)
                except RemoteError as error:
                    if not self.unsupported:  # an older plugin in the dashboard: it can't ask this process
                        logger.info("hermes_voice: the dashboard's hub doesn't take attending processes (%s)", error)
                    self.unsupported = True
                except (ConnectionError, OSError, TimeoutError) as error:
                    logger.info("hermes_voice: lost the dashboard's hub (%s); looking for it again", error)
                except Exception:  # noqa: BLE001 - never stop attending over one bad message
                    logger.warning("hermes_voice: attending the dashboard's hub failed", exc_info=True)
                finally:
                    self.attending.clear()
            self.stop.wait(self.idle_s * (12 if self.unsupported else 1))

    def _serve(self) -> None:
        client = self.client = Client.connect(self.folders)
        try:
            client.request("attend", {"pid": os.getpid()})
            self.unsupported = False
            self.attending.set()
            logger.info("hermes_voice: attending the dashboard's hub for the chats this process holds")
            while not self.stop.is_set():
                message = client.recv(self.idle_s)
                if message is None:
                    if not self.eligible():
                        return
                    continue
                seq, event = message.get("seq"), message.get("event")
                if event == "find":
                    client.send({"op": "attended", "seq": seq, **self.find(message.get("session_ids"))})
                elif event == "deliver":
                    delivery = self.deliver(message.get("session_id"), message.get("text"))
                    client.send({"op": "attended", "seq": seq, "ok": delivery.ok, "via": delivery.via,
                                 "status": delivery.status, "detail": delivery.detail, "held": delivery.held})
        finally:
            client.close()

    def find(self, session_ids: Any) -> dict[str, Any]:
        """Which of the chat's stored ids this process has open, and whether it holds the chat's lease."""
        for session_id in session_ids if isinstance(session_ids, list) else []:
            found = hermes.find_live(session_id) if isinstance(session_id, str) and session_id else None
            if found is not None:
                lease = found[1].get("active_session_lease")
                return {"session_id": session_id,
                        "holds": lease is not None and not getattr(lease, "released", False)}
        return {"session_id": None}

    def deliver(self, session_id: Any, text: Any) -> inject.Delivery:
        """Into the session this process has open for the chat (never reopening one). A chat that isn't open here
        any more, or that yet another process holds, is reported as held: the hub looks again."""
        if not isinstance(session_id, str) or not isinstance(text, str) or not text:
            return inject.Delivery(False, detail="bad delivery")
        if hermes.find_live(session_id) is None:
            return inject.Delivery(False, detail="the chat isn't open in this process any more", held=True)
        try:
            delivery = self.injector.deliver_live(inject.LocalOwner(session_id), text)
        except Exception as error:  # noqa: BLE001 - it may have been taken: reported, never retried
            logger.warning("hermes_voice: delivering into a chat this process holds failed", exc_info=True)
            return inject.Delivery(False, detail=type(error).__name__)
        if not delivery.ok and not delivery.held and hermes.find_live(session_id) is None:
            return inject.Delivery(False, delivery.via, delivery.status, delivery.detail, held=True)
        if delivery.ok:
            logger.info("hermes_voice: put a call's text into %s, which this process holds (%s)", session_id,
                        delivery.via)
        return delivery


_attendant: Optional[Attendant] = None


def attend() -> None:
    """Start this process's attendant (once; ``register(ctx)`` calls this in every process the plugin loads in).
    ``HERMES_VOICE_HUB_SOCKET=0`` turns it off, like the hub's socket itself."""
    global _attendant
    if os.environ.get("HERMES_VOICE_HUB_SOCKET", "").strip() == "0":
        return
    with _lock:
        if _attendant is not None:
            return
        attendant = _attendant = Attendant()
    try:
        attendant.start()
    except RuntimeError:
        with _lock:
            _attendant = None


def unattend() -> None:
    """The plugin unloads: stop taking deliveries (``attend`` starts again if it loads again)."""
    global _attendant
    with _lock:
        attendant, _attendant = _attendant, None
    if attendant is not None:
        attendant.close()


__all__ = ["Attendant", "Client", "NotAvailable", "SOCKET_NAME", "TURNS", "attend", "bind_context", "end_call",
           "note_turn_end", "note_turn_start", "origin_for", "reachable", "start_call", "status", "subscribe",
           "unattend"]
