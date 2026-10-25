"""A throwaway real Hermes for the integration tests, and the clients that drive it.

- ``StubModel``: an OpenAI-compatible chat-completions server on 127.0.0.1 (JSON and SSE streaming). Hermes is
  configured with it as a ``custom`` provider, so the agent loop, tool calls and the plugin's tools all run for real
  while a small responder decides what "the model" says.
- ``Sandbox``: ``hermes serve --isolated`` started with Hermes' own interpreter, with a temp HOME and HERMES_HOME,
  basic auth on, ``dashboard.public_url`` set (which engages the ticket gate, as on the VM), the plugin linked into
  ``<HERMES_HOME>/plugins/hermes_voice`` and enabled, and fake TTS. Nothing outside the temp folder is written:
  lazy dependency installs are off (``HERMES_DISABLE_LAZY_INSTALLS=1``, which also skips the launcher's
  source-update sync), bytecode writing is off, and the host rendezvous lock dir, XDG dirs and HOME are temp dirs.
- A small helper plugin (``hermes_voice_it``, written into the sandbox only) swaps the plugin's APNs sender for a
  recorder and exposes the pushes and deliveries: APNs is the one part that can't run here.
- ``Dashboard`` (cookie sign-in, ws-tickets, REST), ``Gateway`` (``/api/ws`` JSON-RPC) and ``Phone`` (the app's side
  of ``/api/plugins/hermes_voice/phone``).

Finding Hermes: ``HERMES_PYTHON`` (an interpreter with Hermes' dependencies), else the environment Hermes' package
manager committed for the checkout at ``HERMES_AGENT_DIR`` (default ``~/.hermes/hermes-agent``), read from
``<HERMES_ROOT>/installs/<key>/facts.json`` (default root ``~/.hermes``). Both are only read.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import os
import re
import secrets
import signal
import socket
import subprocess
import tempfile
import textwrap
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Optional, Union

import httpx
import websockets

PLUGIN_DIR = Path(__file__).resolve().parents[2]
PREFIX = "/api/plugins/hermes_voice"
HELPER = "/api/plugins/hermes_voice_it"
# The dashboard's public name (as Tailscale Serve's would be). It never resolves: clients connect to 127.0.0.1
# and send it as Host, which is what the dashboard's Host / Origin guards check.
PUBLIC_HOST = "hermes-voice-it.invalid"
MODEL_ID = "voice-it-model"
READY = re.compile(r"HERMES_DASHBOARD_READY port=(\d+)")
# A JSON-RPC event frame as the session host writes it to a transport (stdout's included).
EVENT_FRAME = re.compile(r'"method"\s*:\s*"event"')
REAP_GRACE_S = 2.0

_STRIP_SUFFIXES = ("_API_KEY", "_TOKEN", "_BASE_URL", "_SECRET", "_ACCESS_KEY", "_KEY_ID", "_KEY", "_PASSWORD")
_STRIP_PREFIXES = ("HERMES_", "OPENAI", "ANTHROPIC", "OPENROUTER", "AWS_", "AZURE_", "GOOGLE_", "GEMINI", "PYTEST_",
                   "NOUS_", "XAI_", "LLM_", "CUSTOM_", "TERMINAL_", "ELEVENLABS", "UV_", "XDG_", "VIRTUAL_ENV",
                   "PYTHON", "CONDA")
_PROXIES = ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy")


# ── finding Hermes ─────────────────────────────────────────────────────────────────────────────────────────


def hermes_checkout() -> Path:
    return Path(os.environ.get("HERMES_AGENT_DIR") or Path.home() / ".hermes" / "hermes-agent").expanduser()


def hermes_python() -> tuple[Optional[Path], str]:
    """Hermes' interpreter (with its dependencies), or None and why not."""
    explicit = os.environ.get("HERMES_PYTHON")
    if explicit:
        path = Path(explicit).expanduser()
        return (path, "") if path.exists() else (None, f"HERMES_PYTHON={explicit} does not exist")
    checkout = hermes_checkout()
    if not (checkout / "hermes_cli" / "main.py").is_file():
        return None, f"no Hermes checkout at {checkout} (set HERMES_AGENT_DIR)"
    root = Path(os.environ.get("HERMES_ROOT") or Path.home() / ".hermes").expanduser()
    key = hashlib.sha256(str(checkout.resolve()).encode("utf-8")).hexdigest()[:16]
    facts = root / "installs" / key / "facts.json"
    try:
        environment = json.loads(facts.read_text(encoding="utf-8"))["packages"]["venv"]["environment"]
    except (OSError, ValueError, KeyError, TypeError):
        return None, f"no committed Hermes environment in {facts} (set HERMES_PYTHON)"
    python = Path(environment) / "bin" / "python"
    return (python, "") if python.exists() else (None, f"{python} does not exist (set HERMES_PYTHON)")


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def iso(offset: float = 0.0) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=offset)).isoformat(timespec="milliseconds")


# ── the stub model ─────────────────────────────────────────────────────────────────────────────────────────


@dataclass
class Text:
    text: str
    delay: float = 0.0


@dataclass
class ToolCall:
    name: str
    args: dict[str, Any]
    delay: float = 0.0


Reply = Union[Text, ToolCall]


def message_text(message: dict[str, Any]) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(str(part.get("text") or "") for part in content if isinstance(part, dict))
    return ""


def since_last_reply(body: dict[str, Any]) -> list[dict[str, Any]]:
    """The messages after the model's last turn: the user's prompt or the tool results it is answering."""
    messages = body.get("messages") or []
    for index in range(len(messages) - 1, -1, -1):
        if messages[index].get("role") == "assistant":
            return messages[index + 1:]
    return messages


class StubModel:
    """Answers chat completions with ``responder(body)`` (main turns, the requests carrying tools); other requests
    (titles, summaries) get a short text. Records every main request."""

    def __init__(self, responder: Callable[[dict[str, Any]], Reply]) -> None:
        self.responder = responder
        self.api_key = "voice-it-" + secrets.token_hex(8)
        self.requests: list[dict[str, Any]] = []
        self.lock = threading.Lock()
        self.calls = 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, name="stub-model", daemon=True).start()

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def seen(self) -> str:
        """Everything Hermes has sent the model so far, as text."""
        with self.lock:
            bodies = list(self.requests)
        return "\n".join(message_text(m) for body in bodies for m in body.get("messages") or [])

    def wait_for(self, needle: str, timeout: float = 60.0) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            seen = self.seen()
            if needle in seen:
                return seen
            time.sleep(0.1)
        raise AssertionError(f"the model never saw {needle!r}")

    def tool_names(self) -> set[str]:
        with self.lock:
            bodies = list(self.requests)
        return {str((tool.get("function") or {}).get("name")) for body in bodies for tool in body.get("tools") or []}

    def _handler(self) -> type[BaseHTTPRequestHandler]:
        stub = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_: Any) -> None:
                pass

            def _json(self, status: int, payload: dict[str, Any]) -> None:
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self) -> None:  # noqa: N802
                if self.path.rstrip("/").endswith("/models"):
                    self._json(200, {"object": "list", "data": [{"id": MODEL_ID, "object": "model",
                                                                 "context_length": 128000}]})
                else:
                    self._json(404, {"error": {"message": "not found"}})

            def do_POST(self) -> None:  # noqa: N802
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                try:
                    body = json.loads(raw or b"{}")
                except ValueError:
                    return self._json(400, {"error": {"message": "invalid json"}})
                if self.headers.get("Authorization") != f"Bearer {stub.api_key}":
                    return self._json(401, {"error": {"message": "invalid api key", "type": "authentication_error"}})
                if not self.path.rstrip("/").endswith("/chat/completions"):
                    return self._json(404, {"error": {"message": f"unsupported path {self.path}"}})
                if body.get("tools"):
                    with stub.lock:
                        stub.requests.append(body)
                    try:
                        reply = stub.responder(body)
                    except Exception as error:  # noqa: BLE001 - a broken script answers in text
                        reply = Text(f"stub responder failed: {error!r}")
                else:
                    reply = Text("Voice call test")
                if reply.delay:
                    time.sleep(reply.delay)
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self._reply(reply, bool(body.get("stream")))

            def _reply(self, reply: Reply, stream: bool) -> None:
                usage = {"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110}
                if isinstance(reply, ToolCall):
                    with stub.lock:
                        stub.calls += 1
                        call_id = f"call_it_{stub.calls}"
                    calls = [{"id": call_id, "type": "function",
                              "function": {"name": reply.name, "arguments": json.dumps(reply.args)}}]
                    message: dict[str, Any] = {"role": "assistant", "content": None, "tool_calls": calls}
                    finish = "tool_calls"
                else:
                    message, finish = {"role": "assistant", "content": reply.text}, "stop"
                if not stream:
                    return self._json(200, {"id": "chatcmpl-it", "object": "chat.completion", "created": int(time.time()),
                                            "model": MODEL_ID, "usage": usage,
                                            "choices": [{"index": 0, "message": message, "finish_reason": finish}]})
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                self._event({"role": "assistant", "content": ""})
                if isinstance(reply, ToolCall):
                    call = message["tool_calls"][0]
                    self._event({"tool_calls": [{"index": 0, "id": call["id"], "type": "function",
                                                 "function": {"name": reply.name, "arguments": ""}}]})
                    self._event({"tool_calls": [{"index": 0, "function": {"arguments": call["function"]["arguments"]}}]})
                else:
                    self._event({"content": reply.text})
                self._event({}, finish, usage)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True

            def _event(self, delta: dict[str, Any], finish: Optional[str] = None,
                       usage: Optional[dict[str, Any]] = None) -> None:
                chunk: dict[str, Any] = {"id": "chatcmpl-it", "object": "chat.completion.chunk",
                                         "created": int(time.time()), "model": MODEL_ID,
                                         "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                if usage is not None:
                    chunk["usage"] = usage
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()

        return Handler


# ── the sandbox ────────────────────────────────────────────────────────────────────────────────────────────

# Written into the sandbox only. It swaps the plugin's APNs sender for a recorder (the payload the phone would get
# in its VoIP push) and shows the plugin's deliveries into conversations (which path each injection took).
HELPER_API = '''
import sys
import threading

from fastapi import APIRouter

router = APIRouter()
pushes = []
lock = threading.Lock()


class Recorder:
    def push_call(self, payload):
        with lock:
            pushes.append(dict(payload))
        return hub_module().push.PushResult(True, "", 1)

    def configured(self):
        return True, ""


def hub_module():
    return sys.modules["hermes_voice_loader"].module("hub")


def _hub():
    return hub_module().get_hub()


@router.post("/arm")
async def arm():
    _hub().pusher = Recorder()
    return {"ok": True}


@router.get("/pushes")
async def list_pushes():
    with lock:
        return {"pushes": list(pushes)}


@router.get("/deliveries")
async def deliveries():
    return {"deliveries": [{"call_id": call_id, "text": text, "ok": d.ok, "via": d.via, "status": d.status,
                            "detail": d.detail} for call_id, text, d in list(_hub().deliveries)]}
'''


class Sandbox:
    def __init__(self, python: Path, model: StubModel, root: Optional[Path] = None, ring_timeout_s: float = 6.0) -> None:
        self.python = python
        self.model = model
        self.root = Path(tempfile.mkdtemp(prefix="hv-it-", dir=str(root) if root else None)).resolve()
        # HOME and HERMES_HOME are separate temp dirs. Hermes treats $HOME/.hermes as the user's real install and
        # (rightly) won't open its state.db from a process under pytest; a HERMES_HOME elsewhere is a test home.
        self.home = self.root / "home"
        self.hermes_home = self.root / "hermes"
        self.port = free_port()
        self.username = "voice-it"
        self.password = secrets.token_urlsafe(18)
        self.public = f"http://{PUBLIC_HOST}:{self.port}"
        self.log_path = self.root / "hermes.log"
        self.proc: Optional[subprocess.Popen] = None
        self._write(ring_timeout_s)

    def _write(self, ring_timeout_s: float) -> None:
        home = self.hermes_home
        self.home.mkdir(parents=True)
        (home / "plugins").mkdir(parents=True)
        (self.root / "locks").mkdir()
        (self.root / "relay-plugins.toml").write_text("version = 1\n", encoding="utf-8")
        config = {
            "model": {"provider": "custom", "base_url": self.model.base_url, "default": MODEL_ID,
                      "key_env": "VOICE_IT_PROVIDER_KEY", "context_length": 128000},
            "agent": {"api_max_retries": 1},
            "compression": {"enabled": False},
            "updates": {"check": False},
            "telemetry": {"shared_metrics": {"enabled": False}},
            "dashboard": {
                "public_url": self.public,
                "basic_auth": {"username": self.username, "password": self.password,
                               "secret": secrets.token_hex(32)},
            },
            "plugins": {
                "enabled": ["hermes_voice", "hermes_voice_it"],
                "entries": {"hermes_voice": {"settings": {"ring_timeout_s": ring_timeout_s, "fake_tts": True}}},
            },
        }
        # JSON is valid YAML: no YAML library needed here.
        (home / "config.yaml").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        (home / ".env").write_text(f"VOICE_IT_PROVIDER_KEY={self.model.api_key}\n", encoding="utf-8")
        os.chmod(home / ".env", 0o600)
        (home / "plugins" / "hermes_voice").symlink_to(PLUGIN_DIR, target_is_directory=True)
        helper = home / "plugins" / "hermes_voice_it" / "dashboard"
        helper.mkdir(parents=True)
        (helper / "manifest.json").write_text(json.dumps({"name": "hermes_voice_it", "api": "plugin_api.py",
                                                          "tab": {"hidden": True}}), encoding="utf-8")
        (helper / "plugin_api.py").write_text(textwrap.dedent(HELPER_API), encoding="utf-8")

    def env(self) -> dict[str, str]:
        assert not self.root.is_relative_to(Path(os.path.expanduser("~")).resolve() / ".hermes"), self.root
        env = {k: v for k, v in os.environ.items()
               if not (k.endswith(_STRIP_SUFFIXES) or k.startswith(_STRIP_PREFIXES) or k in _PROXIES)}
        env.update(
            HOME=str(self.home),
            HERMES_HOME=str(self.hermes_home),
            XDG_STATE_HOME=str(self.home / ".local" / "state"),
            XDG_CONFIG_HOME=str(self.home / ".config"),
            XDG_CACHE_HOME=str(self.home / ".cache"),
            XDG_DATA_HOME=str(self.home / ".local" / "share"),
            # The host-backend rendezvous lives outside HERMES_HOME (one per OS user): keep it in the sandbox,
            # so this server never attaches to (or advertises itself as) the machine's real one.
            HERMES_GATEWAY_LOCK_DIR=str(self.root / "locks"),
            HERMES_NEMO_RELAY_PLUGINS_TOML=str(self.root / "relay-plugins.toml"),
            # No on-demand installs, and no source-update sync in the launcher (hermes_cli.venv_sync).
            HERMES_DISABLE_LAZY_INSTALLS="1",
            TIRITH_ENABLED="false",
            AWS_EC2_METADATA_DISABLED="true",
            PYTHONPATH=str(hermes_checkout()),
            PYTHONDONTWRITEBYTECODE="1",
            NO_COLOR="1",
            NO_PROXY="*",
            no_proxy="*",
            TZ="UTC",
            HERMES_VOICE_FAKE_TTS="1",
            # A conversation whose client went away is reaped this long after (default 20 s).
            HERMES_TUI_WS_ORPHAN_REAP_GRACE_S=str(REAP_GRACE_S),
        )
        return env

    def start(self, timeout: float = 180.0) -> None:
        log = open(self.log_path, "a", encoding="utf-8")  # noqa: SIM115 - closed in stop()
        self._log = log
        self.proc = subprocess.Popen(
            [str(self.python), "-m", "hermes_cli.main", "serve", "--isolated", "--host", "127.0.0.1",
             "--port", str(self.port)],
            cwd=str(self.home), env=self.env(), stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"hermes serve exited ({self.proc.returncode}):\n{self.log_tail()}")
            if READY.search(self.log_tail(20000)):
                return
            time.sleep(0.25)
        raise RuntimeError(f"hermes serve did not come up in {timeout:.0f}s:\n{self.log_tail()}")

    def log_tail(self, size: int = 6000) -> str:
        try:
            return self.log_path.read_text(encoding="utf-8", errors="replace")[-size:]
        except OSError:
            return ""

    def agent_logs(self, size: int = 6000) -> str:
        texts = []
        for path in sorted((self.hermes_home / "logs").glob("*.log")):
            with contextlib.suppress(OSError):
                texts.append(f"--- {path.name}\n" + path.read_text(encoding="utf-8", errors="replace")[-size:])
        return "\n".join(texts)

    def stop(self) -> None:
        proc = self.proc
        if proc is not None and proc.poll() is None:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                pass
        if proc is not None:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(proc.pid, signal.SIGKILL)
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=10)
        with contextlib.suppress(Exception):
            self._log.close()


# ── clients ────────────────────────────────────────────────────────────────────────────────────────────────


class Dashboard:
    """What the app's DashboardClient does: password sign-in (cookies), ws-tickets, JSON routes."""

    def __init__(self, sandbox: Sandbox) -> None:
        self.sandbox = sandbox
        self.http = httpx.AsyncClient(base_url=f"http://127.0.0.1:{sandbox.port}", trust_env=False, timeout=30.0,
                                      headers={"Host": f"{PUBLIC_HOST}:{sandbox.port}"})

    async def close(self) -> None:
        await self.http.aclose()

    async def sign_in(self) -> httpx.Response:
        return await self.http.post("/auth/password-login", headers={"Origin": self.sandbox.public}, json={
            "provider": "basic", "username": self.sandbox.username, "password": self.sandbox.password})

    async def get(self, path: str) -> httpx.Response:
        return await self.http.get(path, headers={"Accept": "application/json"})

    async def post(self, path: str, body: Optional[dict] = None) -> httpx.Response:
        return await self.http.post(path, json=body or {}, headers={"Origin": self.sandbox.public})

    async def ticket(self) -> str:
        response = await self.post("/api/auth/ws-ticket")
        response.raise_for_status()
        return response.json()["ticket"]

    async def socket(self, path: str, ticket: Optional[str] = None) -> Any:
        ticket = ticket or await self.ticket()
        uri = f"ws://{PUBLIC_HOST}:{self.sandbox.port}{path}?ticket={ticket}"
        return await websockets.connect(uri, host="127.0.0.1", port=self.sandbox.port, proxy=None,
                                        max_size=8 * 1024 * 1024, open_timeout=20)

    async def pushes(self) -> list[dict]:
        return (await self.get(f"{HELPER}/pushes")).json()["pushes"]

    async def push_for(self, session_id: str, seen: int = 0, timeout: float = 30.0) -> dict:
        """The next VoIP push for a session (after the first `seen` of them)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            mine = [p for p in await self.pushes() if p.get("session_id") == session_id]
            if len(mine) > seen:
                return mine[seen]
            await asyncio.sleep(0.2)
        raise AssertionError(f"no push for {session_id}")

    async def deliveries(self) -> list[dict]:
        return (await self.get(f"{HELPER}/deliveries")).json()["deliveries"]


class Gateway:
    """``/api/ws``: the dashboard's JSON-RPC gateway (``tui_gateway``), as the app's GatewayConnection uses it."""

    def __init__(self, socket: Any) -> None:
        self.socket = socket
        self.next_id = 0
        self.pending: dict[str, asyncio.Future] = {}
        self.events: list[dict] = []
        self.changed = asyncio.Event()
        self.reader = asyncio.ensure_future(self._read())

    @classmethod
    async def open(cls, dashboard: Dashboard) -> "Gateway":
        gateway = cls(await dashboard.socket("/api/ws"))
        await gateway.event("gateway.ready", timeout=60)
        return gateway

    async def _read(self) -> None:
        with contextlib.suppress(websockets.ConnectionClosed):
            async for raw in self.socket:
                if not isinstance(raw, str):
                    continue
                message = json.loads(raw)
                if message.get("method") == "event":
                    self.events.append(message.get("params") or {})
                    self.changed.set()
                elif "id" in message and str(message["id"]) in self.pending:
                    self.pending.pop(str(message["id"])).set_result(message)
                elif message.get("method"):
                    # A server request (approval, clarify…): nothing here should need one.
                    self.events.append({"type": f"request:{message['method']}", "payload": message.get("params")})
                    self.changed.set()

    async def call(self, method: str, params: dict, timeout: float = 60.0) -> dict:
        self.next_id += 1
        rid = f"it-{self.next_id}"
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        await self.socket.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}))
        response = await asyncio.wait_for(future, timeout)
        if "error" in response:
            raise RuntimeError(f"{method} failed: {response['error']}")
        return response.get("result") or {}

    async def event(self, kind: str, match: Callable[[dict], bool] = lambda _e: True, after: int = 0,
                    timeout: float = 60.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            for event in self.events[after:]:
                if event.get("type") == kind and match(event):
                    return event
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                kinds = [e.get("type") for e in self.events[-30:]]
                raise AssertionError(f"no {kind} event (last events: {kinds})")
            self.changed.clear()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.changed.wait(), min(remaining, 0.5))

    async def close(self) -> None:
        await self.socket.close()
        self.reader.cancel()


@dataclass
class Phone:
    """The app's side of ``/phone``: hello, ring / answer / decline, plays speech (acking each line) and says
    turns."""

    socket: Any
    ready: dict
    messages: list[dict] = field(default_factory=list)
    audio_bytes: int = 0
    auto_ack: bool = True
    changed: asyncio.Event = field(default_factory=asyncio.Event)
    reader: Optional[asyncio.Task] = None

    @classmethod
    async def dial(cls, dashboard: Dashboard, call_id: str, initiated_by: str, session_id: Optional[str] = None,
                   title: Optional[str] = None) -> "Phone":
        socket = await dashboard.socket(f"{PREFIX}/phone")
        hello = {"type": "hello", "call_id": call_id, "initiated_by": initiated_by, "app_version": "it"}
        if session_id:
            hello["session_id"] = session_id
        if title:
            hello["title"] = title
        await socket.send(json.dumps(hello))
        first = await asyncio.wait_for(socket.recv(), 20)
        phone = cls(socket, json.loads(first))
        phone.reader = asyncio.ensure_future(phone._read())
        return phone

    async def _read(self) -> None:
        with contextlib.suppress(websockets.ConnectionClosed):
            async for raw in self.socket:
                if isinstance(raw, bytes):
                    self.audio_bytes += len(raw)
                    continue
                message = json.loads(raw)
                self.messages.append(message)
                self.changed.set()
                if (self.auto_ack and message.get("type") == "speech_end" and not message.get("cancelled")
                        and not message.get("error")):
                    await self.send({"type": "played", "id": message["id"]})

    async def send(self, message: dict) -> None:
        await self.socket.send(json.dumps(message))

    async def say(self, text: str, ending: str = "end_of_speech") -> None:
        detail = {"detector": "apple_silence", "detail": 1.2} if ending == "end_of_speech" else {}
        await self.send({"type": "user_turn", "call_id": self.ready["call_id"], "text": text,
                         "ending": {"kind": ending, **detail}, "provider": "apple", "language": "en-US",
                         "started_at": iso(-0.1), "ended_at": iso()})

    async def expect(self, kind: str, match: Callable[[dict], bool] = lambda _m: True,
                     timeout: float = 30.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            for message in self.messages:
                if message.get("type") == kind and match(message) and not message.get("_taken"):
                    message["_taken"] = True
                    return message
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"phone got no {kind} (got {[m.get('type') for m in self.messages]})")
            self.changed.clear()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.changed.wait(), min(remaining, 0.5))

    async def heard(self, text: str, timeout: float = 30.0) -> dict:
        """Waits until a line saying `text` has been spoken to the end (and acked)."""
        start = await self.expect("speech_start", lambda m: text in str(m.get("text")), timeout)
        await self.expect("speech_end", lambda m: m.get("id") == start["id"], timeout)
        return start

    async def closed(self, timeout: float = 30.0) -> Optional[int]:
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(self.socket.wait_closed(), timeout)
        return self.socket.close_code

    async def hang_up(self, reason: str = "hang_up") -> Optional[int]:
        await self.send({"type": "bye", "reason": reason})
        return await self.closed()
