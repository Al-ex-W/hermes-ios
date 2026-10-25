"""Shared test helpers: fake Hermes modules, fake collaborators, a real server and a fake phone.

Every Hermes module the plugin imports (lazily) is replaced by a small fake in ``sys.modules``: secret scope,
homes, config, the dashboard's WebSocket auth, human-wait accounting, interrupts, session context, subagents and
the in-process session host (``tui_gateway.server``). A real uvicorn server serves the plugin's router on an
OS-assigned port, and a fake phone talks to it over a real WebSocket.
"""

from __future__ import annotations

import asyncio
import contextlib
import importlib.util
import json
import socket
import sys
import threading
import time
import types
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, AsyncIterator, Callable, Optional

import pytest
import uvicorn
import websockets

PLUGIN_DIR = Path(__file__).resolve().parent.parent
PREFIX = "/api/plugins/hermes_voice"


def _load(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# ── fake Hermes ────────────────────────────────────────────────────────────────────────────────────────────


class FakeHost:
    """``tui_gateway.server``: live sessions and the session methods inject.py calls."""

    ANY = object()

    def __init__(self) -> None:
        self.module = types.ModuleType("tui_gateway.server")
        self.sessions: dict[str, dict] = {}
        self.calls: list[tuple[str, dict]] = []
        # What each method answers: a status string, ("error", code) or a callable(params) -> response.
        self.answers: dict[str, Any] = {
            "session.redirect": "redirected", "session.steer": "queued", "prompt.submit": "streaming",
        }
        self.turn_isolation = False
        self.module._sessions = self.sessions
        self.module._methods = {
            name: self._method(name)
            for name in ("session.redirect", "session.steer", "prompt.submit", "session.resume")
        }
        self.module._find_live_session_by_key = self.find_live
        self.module._load_dashboard_process_isolation_config = lambda: {"turn_isolation": self.turn_isolation}
        self.module._session_live_title = lambda record, key: record.get("title") or ""

    def add(self, key: str, sid: Optional[str] = None, **extra: Any) -> str:
        sid = sid or f"rt-{key}"
        self.sessions[sid] = {"session_key": key, "agent": types.SimpleNamespace(session_id=key),
                              "source": "desktop", "running": False, **extra}
        return sid

    def rotate(self, sid: str, new_key: str) -> None:
        """Compression: same runtime session, new stored id."""
        self.sessions[sid]["session_key"] = new_key
        self.sessions[sid]["agent"].session_id = new_key

    def find_live(self, key: str, profile_home: Any = ANY) -> Optional[tuple[str, dict]]:
        for sid, record in list(self.sessions.items()):
            if record.get("_finalized"):
                continue
            if (getattr(record.get("agent"), "session_id", None) or record.get("session_key")) != key:
                continue
            if profile_home is not FakeHost.ANY and (record.get("profile_home") or None) != profile_home:
                continue
            return sid, record
        return None

    def _method(self, name: str) -> Callable[[str, dict], dict]:
        def handle(rid: str, params: dict) -> dict:
            self.calls.append((name, dict(params)))
            if name == "session.resume":
                live = self.find_live(params["session_id"])
                sid = live[0] if live else self.add(params["session_id"], f"rt-resumed-{params['session_id']}")
                return {"result": {"session_id": sid}}
            if params.get("session_id") not in self.sessions:
                return {"error": {"code": 4001, "message": "session not found"}}
            answer = self.answers.get(name)
            if callable(answer):
                return answer(params)
            if isinstance(answer, tuple):
                return {"error": {"code": answer[1], "message": "refused"}}
            return {"result": {"status": answer, "text": params.get("text")}}

        return handle

    def methods_called(self) -> list[str]:
        return [name for name, _ in self.calls]


def bound_agent(session_id: str, parent: Optional[Any] = None) -> types.SimpleNamespace:
    """The agent Hermes binds for the running turn (``agent.subagent_lifecycle``): the main agent itself (depth 0),
    or a delegated subagent (depth > 0) with a weak reference to the agent that spawned it."""
    if parent is None:
        return types.SimpleNamespace(session_id=session_id, _delegate_depth=0, _delegate_parent_ref=None)
    parent_agent = bound_agent(parent) if isinstance(parent, str) else parent
    return types.SimpleNamespace(session_id=session_id, _delegate_depth=parent_agent._delegate_depth + 1,
                                 _delegate_parent_ref=lambda: parent_agent)


class FakeHermes:
    def __init__(self, home: Path) -> None:
        self.home = home
        self.secrets: dict[str, str] = {}
        self.secret_error: Optional[Exception] = None
        self.config: dict = {}
        self.env: dict[str, str] = {"HERMES_SESSION_SOURCE": "desktop"}
        # What get_active_subagent_parent() returns: the agent running this turn (see bound_agent), or None.
        self.subagent_parent: Any = None
        self.interrupted: set[int] = set()
        self.interrupt_all = False
        self.tickets: set[str] = set()
        self.host_allowed = True
        self.waits = 0
        self.beats = 0
        self.host = FakeHost()

    def ticket(self) -> str:
        value = uuid.uuid4().hex
        self.tickets.add(value)
        return value

    def install(self, monkeypatch: pytest.MonkeyPatch) -> None:
        fake = self

        def module(name: str, **attrs: Any) -> types.ModuleType:
            mod = types.ModuleType(name)
            mod.__dict__.update(attrs)
            parent, _, child = name.rpartition(".")
            if parent and parent not in sys.modules:
                monkeypatch.setitem(sys.modules, parent, types.ModuleType(parent))
            monkeypatch.setitem(sys.modules, name, mod)
            return mod

        def get_secret(name: str, default: Optional[str] = None) -> Optional[str]:
            if fake.secret_error is not None:
                raise fake.secret_error
            return fake.secrets.get(name, default)

        @contextlib.contextmanager
        def human_wait_window(session_key: Optional[str] = None) -> Any:
            fake.waits += 1
            yield

        def activity_heartbeat(label: str) -> Callable[[], None]:
            def beat() -> None:
                fake.beats += 1
            return beat

        def spawn_context_thread(target: Callable, *, name: str, daemon: bool = True, args: tuple = (),
                                 kwargs: Optional[dict] = None) -> threading.Thread:
            import contextvars
            context = contextvars.copy_context()
            return threading.Thread(target=lambda: context.run(target, *args, **(kwargs or {})), name=name,
                                    daemon=daemon)

        def ws_auth_ok(ws: Any) -> bool:
            ticket = ws.query_params.get("ticket", "")
            if ticket in fake.tickets:
                fake.tickets.discard(ticket)  # single use
                return True
            return False

        module("agent.secret_scope", get_secret=get_secret)
        module("agent.memory_provider", spawn_context_thread=spawn_context_thread)
        module("agent.subagent_lifecycle", get_active_subagent_parent=lambda: fake.subagent_parent)
        module("hermes_constants", get_hermes_home=lambda: fake.home)
        module("hermes_cli.config", load_config_readonly=lambda: fake.config)
        module("hermes_cli.profiles", get_active_profile_name=lambda: "default")
        module("hermes_cli.web_server_chat", _ws_auth_ok=ws_auth_ok,
               _ws_request_is_allowed=lambda ws: fake.host_allowed)
        module("tools.approval_human_wait", human_wait_window=human_wait_window, activity_heartbeat=activity_heartbeat)
        module("tools.interrupt",
               is_interrupted=lambda: fake.interrupt_all or threading.get_ident() in fake.interrupted)
        module("gateway.session_context", get_session_env=lambda name, default="": fake.env.get(name, default))
        monkeypatch.setitem(sys.modules, "tui_gateway.server", self.host.module)


# ── fakes for the hub's collaborators ──────────────────────────────────────────────────────────────────────


class RecordingInjector:
    """Records deliveries; `gate` (when set) holds each delivery until released."""

    def __init__(self) -> None:
        self.delivered: list[tuple[str, str]] = []
        self.gate: Optional[threading.Event] = None
        self.lock = threading.Lock()

    def deliver(self, owner: Any, text: str) -> Any:
        if self.gate is not None:
            self.gate.wait(10)
        with self.lock:
            self.delivered.append((owner.session_id, text))
        from hermes_voice_core.inject import Delivery
        return Delivery(True, "redirect", "redirected")

    def texts(self) -> list[str]:
        with self.lock:
            return [text for _, text in self.delivered]

    async def wait_for(self, count: int, timeout: float = 5) -> list[str]:
        async with asyncio.timeout(timeout):
            while len(self.texts()) < count:
                await asyncio.sleep(0.02)
        return self.texts()


class FakePusher:
    def __init__(self, ok: bool = True, reason: str = "") -> None:
        self.ok, self.reason = ok, reason
        self.payloads: list[dict] = []
        self.pushed = threading.Event()

    def push_call(self, payload: dict) -> Any:
        from hermes_voice_core.push import PushResult
        self.payloads.append(payload)
        self.pushed.set()
        return PushResult(self.ok, self.reason, 1 if self.ok else 0)

    def configured(self) -> tuple[bool, str]:
        return True, ""


class PacedSpeech:
    """Fake TTS: one 0.1 s chunk of silence per word, `delay` seconds apart. Records every request."""

    def __init__(self, delay: float = 0.0) -> None:
        self.delay = delay
        self.requests: list[tuple[str, Optional[str]]] = []

    async def stream(self, text: str, voice_id: Optional[str] = None) -> AsyncIterator[bytes]:
        self.requests.append((text, voice_id))
        for _ in text.split():
            await asyncio.sleep(self.delay)
            yield b"\x00\x00" * 2400


# ── server and phone ───────────────────────────────────────────────────────────────────────────────────────


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@asynccontextmanager
async def serving(core: Any) -> AsyncIterator[int]:
    from fastapi import FastAPI

    app = FastAPI()
    app.include_router(core.api.router, prefix=PREFIX)
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning",
                                           timeout_graceful_shutdown=2))
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            task.result()
        await asyncio.sleep(0.01)
    try:
        yield port
    finally:
        server.should_exit = True
        await task


def iso(moment: Optional[float] = None, offset: float = 0.0) -> str:
    base = datetime.now(timezone.utc) if moment is None else datetime.fromtimestamp(moment, timezone.utc)
    return (base + timedelta(seconds=offset)).isoformat()


class Phone:
    """A fake HermesVoice app on /phone that records what the plugin sends."""

    def __init__(self, socket: Any, call_id: str, auto_ack: bool, ready: dict) -> None:
        self.socket = socket
        self.call_id = call_id
        self.auto_ack = auto_ack
        self.ready = ready
        self.messages: list[dict] = []
        self.audio = 0
        self.inbox: asyncio.Queue[dict] = asyncio.Queue()
        self.heard_audio = asyncio.Event()
        self.played_at: dict[str, float] = {}
        self.reader = asyncio.create_task(self._read())

    @classmethod
    async def dial(cls, port: int, fake: FakeHermes, call_id: Optional[str] = None, auto_ack: bool = True,
                   initiated_by: str = "user", session_id: str = "s1", title: str = "Test") -> "Phone":
        call_id = call_id or uuid.uuid4().hex
        ws = await websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={fake.ticket()}")
        await ws.send(json.dumps({"type": "hello", "call_id": call_id, "session_id": session_id, "title": title,
                                  "initiated_by": initiated_by, "app_version": "test"}))
        ready = json.loads(await ws.recv())
        assert ready["type"] == "ready" and ready["call_id"] == call_id, ready
        return cls(ws, call_id, auto_ack, ready)

    async def _read(self) -> None:
        try:
            async for frame in self.socket:
                if isinstance(frame, bytes):
                    self.audio += len(frame)
                    self.heard_audio.set()
                    continue
                message = json.loads(frame)
                self.messages.append(message)
                if self.auto_ack and message["type"] == "speech_end" and not message.keys() & {"cancelled", "error"}:
                    self.played_at[message["id"]] = time.time()
                    await self.socket.send(json.dumps({"type": "played", "id": message["id"]}))
                await self.inbox.put(message)
        except websockets.ConnectionClosed:
            pass

    async def expect(self, kind: str, timeout: float = 5) -> dict:
        async with asyncio.timeout(timeout):
            while (message := await self.inbox.get())["type"] != kind:
                pass
        return message

    async def send(self, message: dict) -> None:
        await self.socket.send(json.dumps(message))

    async def say(self, text: str, ending: str = "end_of_speech", started_at: Optional[str] = None,
                  **extra: Any) -> None:
        await self.send({"type": "user_turn", "call_id": self.call_id, "text": text,
                         "ending": {"kind": ending, **extra}, "provider": "apple", "language": "en-US",
                         "started_at": started_at or iso(), "ended_at": iso(offset=0.5)})

    async def hang_up(self) -> None:
        await self.send({"type": "bye"})
        await self.socket.close()
        await self.reader

    async def closed(self, timeout: float = 5) -> Optional[int]:
        await asyncio.wait_for(self.reader, timeout)
        return self.socket.close_code

    def kinds(self) -> list[str]:
        return [m["type"] for m in self.messages]


async def tool(handler: Callable[..., str], args: dict, session_id: str = "s1") -> dict:
    """Call a tool handler on a worker thread, the way Hermes runs tools."""
    return json.loads(await asyncio.to_thread(handler, args, session_id=session_id, task_id="t1"))


async def say_line(hub: Any, call: Any, text: str, timeout: float = 20) -> Any:
    """Queue a line on the call and wait for its result (a SpeakResult)."""
    line, _ = hub.enqueue_line(call, text)
    await asyncio.to_thread(line.done.wait, timeout)
    assert line.done.is_set(), "line never finished"
    return line.result


async def until(predicate: Callable[[], Any], timeout: float = 5) -> Any:
    async with asyncio.timeout(timeout):
        while not (value := predicate()):
            await asyncio.sleep(0.02)
    return value
