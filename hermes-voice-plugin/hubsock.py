"""The call hub's local socket: conversations in other Hermes processes (the CLI, the Ink TUI, the messaging gateway,
cron, compute-host children) ring the phone, speak and hear the user through the dashboard process's hub.

Where: ``<HERMES_HOME>/hermes-voice/hub.sock`` (0600, in a 0700 folder), opened once the dashboard serves, and
``hub.token`` next to it (0600): a fresh random token every time the dashboard starts. A client has to read the
token file and connect to the socket (so it runs as this user) and proves it by sending the token first; where the
OS reports the peer's user id it must be ours too. A socket path too long for ``AF_UNIX`` is bound in a private
temporary folder instead, with ``hub.sock`` a symlink to it (``remote.py`` connects to the target).

Protocol: one JSON object per line (UTF-8, at most 64 KiB). The client starts with
``{"op": "hello", "token", "version": 1}`` -> ``{"op": "hello", "ok": true, "version": 1}`` (else
``{"ok": false, "error"}`` and the socket closes). Then requests ``{"id": <int>, "op", ...}``, each answered once with
``{"id", "ok": true, "result"}`` or ``{"id", "ok": false, "error", "message"}``:

- ``status``: the hub's ``/status`` view.
- ``ring {origin, text, mode}``: ``start_call`` for that conversation (rings when it has no call, else speaks).
  ``mode: "sync"`` answers ``{call_id, status: "waiting", waiter}`` (or a refusal / outcome): the reply is collected
  with ``await_turn`` on the same connection; closing it gives the wait up.
- ``speak {origin, text}``: speak into the conversation's call; never rings (``status: "no_call"`` without one).
- ``await_turn {waiter, cap_s?}``: wait for the reply (``{said, ending, outcome, call_id, note?}``, as a sync
  ``start_call`` returns it). ``cap_s`` bounds the wait.
- ``end {origin, text?}``: ``end_call`` (the goodbye is spoken first, up to a minute).
- ``subscribe_turns {call_id, origin}``: the conversation's process takes the call's turns from now on. Events
  follow on this connection: ``{"event": "turn", call_id, seq, text}`` (the client answers
  ``{"op": "delivered", seq, ok, via?, status?, detail?, fallback?}``) and ``{"event": "ended", call_id, outcome}``.

And three one-way messages: ``{"op": "signal", ref: <request id>, interrupt?: true, yield?: true}`` (the tool
thread waiting on ``await_turn`` / ``end`` was stopped, or Hermes asked it to yield), ``delivered`` (above) and
``{"op": "rekey", call_id, session_id}`` (the subscriber's conversation continues under a new id after compression).

``origin`` is ``hermes.Origin`` as fields (no runtime session: that is the other process's). The policy, rate limits
and quiet hours run here, for every process.
"""

from __future__ import annotations

import atexit
import hmac
import json
import logging
import os
import secrets
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
from contextlib import nullcontext
from pathlib import Path
from typing import Any, Callable, Optional

from . import hermes, inject
from .hub import Call, CallHub, Signals, Waiter

logger = logging.getLogger("hermes_voice")

PROTOCOL = 1
SOCKET_NAME = "hub.sock"
TOKEN_NAME = "hub.token"
MAX_LINE = 64 * 1024
HELLO_TIMEOUT = 5.0
# A send the client doesn't take for this long means it is gone.
SEND_TIMEOUT = 10.0
# How long a call's turns wait for its conversation's process to (re)subscribe; past it the call is over.
SUBSCRIBER_GRACE = 30.0
# How long the conversation's process may take to put one turn in.
ACK_TIMEOUT = 20.0
MAX_REQUESTS = 16
MAX_TEXT = 20_000
# sockaddr_un.sun_path: 104 bytes on macOS, 108 on Linux (with the terminating NUL).
SUN_PATH_MAX = 103 if sys.platform == "darwin" else 107

_STRINGS = ("session_id", "profile", "title", "source", "platform", "chat_type", "user_id", "session_key")
_FLAGS = ("is_cron", "is_subagent", "is_owner")


class ProtocolError(ValueError):
    """A request this server won't run (``error`` is its code)."""

    def __init__(self, error: str, message: str) -> None:
        super().__init__(message)
        self.error = error


def origin_from(payload: Any) -> hermes.Origin:
    """A conversation in another process, from a request's ``origin``. Its runtime session id and profile folder
    mean nothing here, so they are never taken."""
    if not isinstance(payload, dict):
        raise ProtocolError("bad_request", "origin must be an object")
    values: dict[str, Any] = {}
    for name in _STRINGS:
        value = payload.get(name)
        values[name] = str(value).strip()[:256] if isinstance(value, (str, int)) and not isinstance(value, bool) else ""
    for name in _FLAGS:
        values[name] = payload.get(name) is True
    turn_at = payload.get("user_turn_at")
    values["user_turn_at"] = float(turn_at) if isinstance(turn_at, (int, float)) and not isinstance(turn_at, bool) else 0.0
    if not values["session_id"]:
        raise ProtocolError("bad_request", "origin.session_id is required")
    values["profile"] = values["profile"] or "default"
    return hermes.Origin(**values)


def peer_uid(sock: socket.socket) -> Optional[int]:
    """The user id of the process on the other end, where the OS says (Linux ``SO_PEERCRED``, macOS
    ``LOCAL_PEERCRED``); None elsewhere."""
    try:
        if hasattr(socket, "SO_PEERCRED"):
            data = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
            return int(struct.unpack("3i", data)[1])
        if sys.platform == "darwin":
            # struct xucred {u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[16];}
            data = sock.getsockopt(0, 0x001, struct.calcsize("IIh16I"))  # SOL_LOCAL, LOCAL_PEERCRED
            return int(struct.unpack("IIh16I", data)[1])
    except (OSError, struct.error):
        return None
    return None


# ── signals and routes ─────────────────────────────────────────────────────────────────────────────────────


class RemoteSignals(Signals):
    """A wait's signals from the tool thread in the client's process. Hermes' human-wait window and heartbeat run
    there, around the request, so here they are no-ops. A client that goes away stops its waits."""

    def __init__(self, conn: "Conn") -> None:
        self.conn = conn
        self.stop = threading.Event()
        self.yields = 0
        self.lock = threading.Lock()

    def interrupted(self) -> bool:
        return self.stop.is_set() or self.conn.closed.is_set()

    def take_yield(self) -> bool:
        with self.lock:
            if self.yields:
                self.yields -= 1
                return True
            return False

    def window(self) -> Any:
        return nullcontext()

    def beater(self) -> Callable[[], None]:
        return lambda: None

    def signal(self, message: dict) -> None:
        if message.get("interrupt") is True:
            self.stop.set()
        if message.get("yield") is True:
            with self.lock:
                self.yields += 1


class _Ack:
    def __init__(self) -> None:
        self.event = threading.Event()
        self.delivery = inject.Delivery(False, detail="no answer from the conversation's process")


class Route:
    """Where a call's turns go when its conversation runs in another process: that process's subscription.

    A call started from another process gets its route at once; its turns wait up to SUBSCRIBER_GRACE for the
    process to subscribe, and the call ends when no process holds it for that long. A call the conversation's
    process subscribes to later (one the user started from the app, for a dashboard session whose turns run in a
    compute-host child) goes back to this process's own delivery when the subscriber leaves."""

    def __init__(self, server: "HubServer", call: Call) -> None:
        self.server = server
        self.call = call
        self.cond = threading.Condition()
        self.conn: Optional[Conn] = None
        self.seq = 0
        self.acks: dict[int, _Ack] = {}
        self.closed = False
        self.timer: Optional[threading.Timer] = None
        self._arm()

    def attach(self, conn: "Conn") -> None:
        with self.cond:
            closed = self.closed
            if not closed:
                previous, self.conn = self.conn, conn
                timer, self.timer = self.timer, None
                self.cond.notify_all()
        if closed:  # the call ended meanwhile: the subscriber hears so (after its answer, see remote.Client)
            conn.send({"event": "ended", "call_id": self.call.call_id, "outcome": self.call.outcome or "ended"})
            return
        if timer is not None:
            timer.cancel()
        if previous is not None and previous is not conn:
            previous.routes.discard(self)
        conn.routes.add(self)

    def detach(self, conn: "Conn") -> None:
        with self.cond:
            if self.conn is not conn:
                return
            self.conn = None
            pending, self.acks = self.acks, {}
            if not self.closed:
                self._arm()
        for ack in pending.values():
            ack.delivery = inject.Delivery(False, detail="the conversation's process went away", fallback=True)
            ack.event.set()

    def _arm(self) -> None:
        timer = threading.Timer(SUBSCRIBER_GRACE, self._unclaimed)
        timer.daemon = True
        self.timer = timer
        timer.start()

    def _unclaimed(self) -> None:
        with self.cond:
            if self.conn is not None or self.closed:
                return
            self.timer = None
        hub, call = self.server.hub, self.call
        if not call.owner.remote:
            with hub.lock:
                if call.route is self:
                    call.route = None
            return
        logger.info("hermes_voice: no process holds call %s's conversation; ending it", call.call_id[:8])
        hub.finish(call, "ended_by_agent", "the conversation's Hermes process went away")

    def deliver(self, text: str) -> inject.Delivery:
        """Hand a turn to the subscriber and wait for what it did with it (InjectQueue thread)."""
        deadline = time.monotonic() + SUBSCRIBER_GRACE
        with self.cond:
            if self.conn is None and not self.call.owner.remote:
                # A dashboard session's call whose subscriber left: this process delivers it at once.
                return inject.Delivery(False, detail="the conversation's process isn't connected", fallback=True)
            while self.conn is None and not self.closed:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return inject.Delivery(False, detail="the conversation's process isn't connected", fallback=True)
                self.cond.wait(remaining)
            if self.closed or self.conn is None:
                return inject.Delivery(False, detail="the call is over")
            self.seq += 1
            seq, conn = self.seq, self.conn
            ack = self.acks[seq] = _Ack()
        if not conn.send({"event": "turn", "call_id": self.call.call_id, "seq": seq, "text": text}):
            self.detach(conn)
            return inject.Delivery(False, detail="the conversation's process went away", fallback=True)
        if not ack.event.wait(ACK_TIMEOUT):
            with self.cond:
                self.acks.pop(seq, None)
            return inject.Delivery(False, detail="the conversation's process didn't say whether it took the turn")
        return ack.delivery

    def acked(self, conn: "Conn", message: dict) -> None:
        seq = message.get("seq")
        with self.cond:
            ack = self.acks.pop(seq, None) if self.conn is conn and isinstance(seq, int) else None
        if ack is None:
            return
        ack.delivery = inject.Delivery(
            message.get("ok") is True, _text(message.get("via"), 40), _text(message.get("status"), 40),
            _text(message.get("detail"), 300), message.get("fallback") is True)
        ack.event.set()

    def close(self, outcome: str) -> None:
        """The call is over (after its last delivery): tell the subscriber, and stop waiting for one."""
        with self.cond:
            if self.closed:
                return
            self.closed = True
            conn, self.conn = self.conn, None
            timer, self.timer = self.timer, None
            pending, self.acks = self.acks, {}
            self.cond.notify_all()
        if timer is not None:
            timer.cancel()
        for ack in pending.values():
            ack.event.set()
        if conn is not None:
            conn.routes.discard(self)
            conn.send({"event": "ended", "call_id": self.call.call_id, "outcome": outcome})


# ── connections ────────────────────────────────────────────────────────────────────────────────────────────


class Conn:
    """One client connection: its requests run on their own threads; signals and acks are handled as they come."""

    def __init__(self, server: "HubServer", sock: socket.socket) -> None:
        self.server = server
        self.sock = sock
        self.wlock = threading.Lock()
        self.closed = threading.Event()
        self.signals: dict[int, RemoteSignals] = {}
        self.waiters: set[str] = set()
        self.routes: set[Route] = set()
        self.lock = threading.Lock()
        self.buffer = b""

    def send(self, message: dict) -> bool:
        data = (json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with self.wlock:
            if self.closed.is_set():
                return False
            try:
                self.sock.sendall(data)
                return True
            except OSError:
                pass
        self.close()
        return False

    def read_line(self, deadline: Optional[float] = None) -> Optional[bytes]:
        """The client's next line; None once it is gone, sent too long a line, or `deadline` passed."""
        while not self.closed.is_set():
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line.strip():
                    return line
            if len(self.buffer) > MAX_LINE:
                logger.warning("hermes_voice: hub socket client sent an oversized line; closing it")
                return None
            if deadline is not None and time.monotonic() > deadline:
                return None
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue  # an idle subscription
            except OSError:
                return None
            if not chunk:
                return None
            self.buffer += chunk
        return None

    def close(self) -> None:
        if self.closed.is_set():
            return
        self.closed.set()
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
        for route in list(self.routes):
            route.detach(self)
        self.routes.clear()
        self.server.drop_waiters(self)
        self.server.conns.discard(self)


# ── the server ─────────────────────────────────────────────────────────────────────────────────────────────


class HubServer:
    def __init__(self, hub: CallHub, folder: Path) -> None:
        self.hub = hub
        self.folder = Path(folder)
        self.path = self.folder / SOCKET_NAME
        self.token_path = self.folder / TOKEN_NAME
        self.token = secrets.token_hex(32)
        self.sock: Optional[socket.socket] = None
        self.bound: Optional[str] = None  # where the socket really is
        self.short_dir: Optional[str] = None
        self.closed = threading.Event()
        self.conns: set[Conn] = set()
        self.waiters: dict[str, tuple[Call, Waiter, Conn]] = {}
        self.lock = threading.Lock()

    # ── lifecycle ────────────────────────────────────────────────────────────────────────────────────────

    def start(self) -> "HubServer":
        self.folder.mkdir(parents=True, exist_ok=True)
        os.chmod(self.folder, 0o700)
        if _answers(self.path):
            raise RuntimeError(f"another Hermes dashboard already serves {self.path}")
        _remove_stale(self.path)
        # The token first: a client that can connect to the new socket reads the new token.
        _write_private(self.token_path, self.token + "\n")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            target = str(self.path)
            if len(os.fsencode(target)) > SUN_PATH_MAX:
                self.short_dir = tempfile.mkdtemp(prefix="hermes-voice-", dir=_short_tmp())
                target = os.path.join(self.short_dir, SOCKET_NAME)
            sock.bind(target)
            os.chmod(target, 0o600)
            if self.short_dir is not None:
                os.symlink(target, self.path)
            sock.listen(16)
            sock.settimeout(0.5)  # accept() wakes up to see close(): closing alone doesn't wake it everywhere
        except BaseException:
            sock.close()
            self._remove_files()
            raise
        self.sock, self.bound = sock, target
        hermes.spawn_thread(self._accept, name="hermes-voice-hubsock-accept")
        logger.info("hermes_voice: hub socket open at %s", self.path)
        return self

    def close(self) -> None:
        if self.closed.is_set():
            return
        self.closed.set()
        sock, self.sock = self.sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass
        for conn in list(self.conns):
            conn.close()
        self._remove_files()

    def _remove_files(self) -> None:
        """Remove the socket and token if they are still this server's (a newer dashboard may have replaced
        them)."""
        try:
            if self.token_path.read_text(encoding="utf-8").strip() == self.token:
                self.token_path.unlink()
        except OSError:
            pass
        try:
            if self.path.is_symlink():
                if self.bound is not None and os.readlink(self.path) == self.bound:
                    self.path.unlink()
            elif self.bound == str(self.path) and self.path.exists():
                self.path.unlink()
        except OSError:
            pass
        if self.short_dir is not None:
            shutil.rmtree(self.short_dir, ignore_errors=True)

    def _accept(self) -> None:
        while not self.closed.is_set():
            sock = self.sock
            if sock is None:
                return
            try:
                client, _ = sock.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.closed.is_set():
                    return
                time.sleep(0.05)
                continue
            client.settimeout(SEND_TIMEOUT)
            conn = Conn(self, client)
            self.conns.add(conn)
            try:
                hermes.spawn_thread(self._serve, conn, name="hermes-voice-hubsock-conn")
            except RuntimeError:
                conn.close()

    # ── one connection ───────────────────────────────────────────────────────────────────────────────────

    def _serve(self, conn: Conn) -> None:
        try:
            if not self._admit(conn):
                return
            while (raw := conn.read_line()) is not None:
                try:
                    message = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    conn.send({"ok": False, "error": "bad_json", "message": "not a JSON object"})
                    continue
                if not isinstance(message, dict):
                    conn.send({"ok": False, "error": "bad_json", "message": "not a JSON object"})
                    continue
                self._handle(conn, message)
        except Exception:  # noqa: BLE001 - one broken client must not take the server down
            logger.warning("hermes_voice: hub socket connection failed", exc_info=True)
        finally:
            conn.close()

    def _admit(self, conn: Conn) -> bool:
        uid = peer_uid(conn.sock)
        if uid is not None and hasattr(os, "getuid") and uid != os.getuid():
            logger.warning("hermes_voice: hub socket refused a connection from another user (uid %s)", uid)
            return False
        conn.sock.settimeout(0.5)
        try:
            first = conn.read_line(time.monotonic() + HELLO_TIMEOUT)
        finally:
            if not conn.closed.is_set():
                conn.sock.settimeout(SEND_TIMEOUT)
        try:
            hello = json.loads(first.decode("utf-8")) if first else None
        except (UnicodeDecodeError, ValueError):
            hello = None
        token = hello.get("token") if isinstance(hello, dict) and hello.get("op") == "hello" else None
        if not isinstance(token, str) or not hmac.compare_digest(token.encode("utf-8"), self.token.encode("utf-8")):
            conn.send({"op": "hello", "ok": False, "error": "auth"})
            return False
        return conn.send({"op": "hello", "ok": True, "version": PROTOCOL})

    def _handle(self, conn: Conn, message: dict) -> None:
        op = message.get("op")
        if op == "signal":
            signals = conn.signals.get(message.get("ref"))  # type: ignore[arg-type]
            if signals is not None:
                signals.signal(message)
            return
        if op == "delivered":
            for route in list(conn.routes):
                if route.call.call_id == message.get("call_id"):
                    route.acked(conn, message)
            return
        if op == "rekey":
            self._rekey(conn, message)
            return
        rid = message.get("id")
        if not isinstance(rid, int) or isinstance(rid, bool):
            conn.send({"ok": False, "error": "bad_request", "message": "a request needs an integer id"})
            return
        with conn.lock:
            if rid in conn.signals or len(conn.signals) >= MAX_REQUESTS:
                conn.send({"id": rid, "ok": False, "error": "busy", "message": "too many requests at once"})
                return
            signals = conn.signals[rid] = RemoteSignals(conn)
        try:
            hermes.spawn_thread(self._run, conn, rid, message, signals, name="hermes-voice-hubsock-request")
        except RuntimeError:
            conn.signals.pop(rid, None)
            conn.send({"id": rid, "ok": False, "error": "internal", "message": "no thread for the request"})

    def _run(self, conn: Conn, rid: int, message: dict, signals: RemoteSignals) -> None:
        try:
            result = self._dispatch(conn, str(message.get("op") or ""), message, signals)
            reply: dict[str, Any] = {"id": rid, "ok": True, "result": result}
        except ProtocolError as error:
            reply = {"id": rid, "ok": False, "error": error.error, "message": str(error)}
        except Exception as error:  # noqa: BLE001
            logger.warning("hermes_voice: hub socket request %s failed", message.get("op"), exc_info=True)
            reply = {"id": rid, "ok": False, "error": "internal", "message": type(error).__name__}
        finally:
            conn.signals.pop(rid, None)
        conn.send(reply)

    def _dispatch(self, conn: Conn, op: str, message: dict, signals: RemoteSignals) -> dict[str, Any]:
        if op == "status":
            return self.hub.status()
        if op == "ring":
            origin, text = origin_from(message.get("origin")), _speech(message.get("text"))
            mode = message.get("mode") or "async"
            if mode not in ("async", "sync"):
                raise ProtocolError("bad_request", 'mode must be "async" or "sync"')
            begun = self.hub.begin_call(origin, text, mode, route=lambda call: Route(self, call))
            if begun.waiter is None or begun.call is None:
                return begun.result
            return {**begun.result, "waiter": self._register(conn, begun.call, begun.waiter)}
        if op == "speak":
            return self.hub.speak(origin_from(message.get("origin")), _speech(message.get("text")))
        if op == "await_turn":
            return self._await(conn, message, signals)
        if op == "end":
            text = message.get("text")
            return self.hub.end_call(origin_from(message.get("origin")), text if isinstance(text, str) else "",
                                     signals)
        if op == "subscribe_turns":
            return self._subscribe(conn, message)
        raise ProtocolError("unknown_op", f"unknown op {op!r}")

    def _register(self, conn: Conn, call: Call, waiter: Waiter) -> str:
        waiter_id = secrets.token_hex(8)
        with self.lock:
            self.waiters[waiter_id] = (call, waiter, conn)
        conn.waiters.add(waiter_id)
        if conn.closed.is_set():
            self.drop_waiters(conn)
        return waiter_id

    def _await(self, conn: Conn, message: dict, signals: RemoteSignals) -> dict[str, Any]:
        waiter_id = message.get("waiter")
        with self.lock:
            entry = self.waiters.get(waiter_id) if isinstance(waiter_id, str) else None
        if entry is None or entry[2] is not conn:
            raise ProtocolError("unknown_waiter", "no such wait on this connection")
        call, waiter, _ = entry
        cap = message.get("cap_s")
        cap_s = float(cap) if isinstance(cap, (int, float)) and not isinstance(cap, bool) and cap > 0 else None
        try:
            return self.hub.wait_reply(call, waiter, signals, cap_s)
        finally:
            with self.lock:
                self.waiters.pop(waiter_id, None)  # type: ignore[arg-type]
            conn.waiters.discard(waiter_id)  # type: ignore[arg-type]

    def drop_waiters(self, conn: Conn) -> None:
        """A connection closed: waits it registered and never collected give their turns back."""
        for waiter_id in list(conn.waiters):
            with self.lock:
                entry = self.waiters.pop(waiter_id, None)
            conn.waiters.discard(waiter_id)
            if entry is not None:
                self.hub.abandon(entry[0], entry[1])

    def _subscribe(self, conn: Conn, message: dict) -> dict[str, Any]:
        """Take the call's turns. A call that just ended still has its last notices to deliver (an async ring
        whose push failed at once ends before its process subscribes): the subscriber gets those, then the end."""
        origin = origin_from(message.get("origin"))
        call_id = message.get("call_id")
        if not isinstance(call_id, str):
            raise ProtocolError("bad_request", "call_id is required")
        call = self.hub.current(call_id)
        with self.hub.lock:
            if call is None:
                past = self.hub.history.get(call_id)
                if past is None or past.inbox.finished:
                    return {"subscribed": False, "call_id": call_id, "outcome": past.outcome if past else None}
                call = past
        if not call.owner.matches(origin):
            raise ProtocolError("not_owner", "that call belongs to another conversation")
        with self.hub.lock:
            route = call.route
            if route is None:
                route = call.route = Route(self, call)
        route.attach(conn)
        with self.hub.lock:
            over = call.inbox.finished
        if over:  # the call's last delivery was done before this route existed
            route.close(call.outcome or "ended")
        return {"subscribed": True, "call_id": call.call_id}

    def _rekey(self, conn: Conn, message: dict) -> None:
        session_id = _text(message.get("session_id"), 256)
        for route in list(conn.routes):
            if route.call.call_id == message.get("call_id") and session_id:
                route.call.owner.rekey(session_id)


# ── helpers ────────────────────────────────────────────────────────────────────────────────────────────────


def serve(hub: CallHub, folder: Optional[Path] = None) -> HubServer:
    """Open the hub's socket (dashboard process) and close it when the process exits."""
    server = HubServer(hub, folder or hermes.state_dir()).start()
    atexit.register(server.close)
    return server


def socket_path(folder: Path) -> Optional[str]:
    """Where to connect for the hub socket in `folder` (following the symlink for a long path), or None."""
    path = Path(folder) / SOCKET_NAME
    try:
        if not path.exists():
            return None
        target = os.path.realpath(path)
    except OSError:
        return None
    return target if len(os.fsencode(target)) <= SUN_PATH_MAX else None


def _answers(path: Path) -> bool:
    """A live hub serves this socket."""
    target = socket_path(path.parent) if path.name == SOCKET_NAME else None
    if target is None:
        return False
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(1.0)
    try:
        probe.connect(target)
        return True
    except OSError:
        return False
    finally:
        probe.close()


def _remove_stale(path: Path) -> None:
    """A socket left by a dashboard that is gone (and its private folder, for a long path)."""
    try:
        if path.is_symlink():
            target = os.readlink(path)
            path.unlink()
            folder = os.path.dirname(target)
            if os.path.basename(folder).startswith("hermes-voice-") and os.path.basename(target) == SOCKET_NAME:
                shutil.rmtree(folder, ignore_errors=True)
        elif path.exists():
            path.unlink()
    except OSError:
        logger.debug("hermes_voice: could not remove a stale hub socket", exc_info=True)


def _write_private(path: Path, text: str) -> None:
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def _short_tmp() -> str:
    folder = tempfile.gettempdir()
    # Room for "/hermes-voice-XXXXXXXX/hub.sock".
    return folder if len(os.fsencode(folder)) + 32 <= SUN_PATH_MAX else "/tmp"


def _speech(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ProtocolError("bad_request", "text is required")
    return value[:MAX_TEXT]


def _text(value: Any, limit: int) -> str:
    return str(value)[:limit] if isinstance(value, (str, int, float)) and not isinstance(value, bool) else ""
