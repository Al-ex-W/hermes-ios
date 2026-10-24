#!/usr/bin/env python3
"""Fake Hermes dashboard for end-to-end tests of the HermesVoice app (Simulator or device).

It speaks exactly the slice of the Hermes web dashboard the app uses, with the shapes taken from the Hermes
source (hermes_cli/dashboard_auth/routes.py, web_routers/profiles.py + sessions.py, tui_gateway/ws.py,
server.py, server_requests.py, event_replay.py, methods_session.py, methods_prompt.py, session_lifecycle.py,
session_auto_continue.py, contracts/):

  POST /auth/password-login       {provider, username, password} -> {ok, next} + HttpOnly cookie hermes_session_at
  POST /auth/logout               clears the cookies, 302 -> /login
  POST /api/auth/ws-ticket        -> {ticket, ttl_seconds} (single use, 30 s)
  GET  /api/profiles/sessions     -> {sessions: [...], total, profile_totals, limit, offset, errors, storage}
  GET  /api/sessions/{id}/messages -> {session_id, profile, messages: [...], pagination}
  WS   /api/ws?ticket=…           JSON-RPC 2.0; gateway.ready {replay_epoch, heartbeat} first; events
                                  {type, session_id: <runtime id>, seq, payload}; server→client requests

Gateway behaviour mirrored from Hermes: every session event gets a per-session ``seq`` and lands in a 512-frame
replay ring (``session.events.since``); a session whose last socket closes is detached and reaped after
``--reap-grace`` seconds unless a client re-attaches (``session.activate`` / ``session.resume`` /
``prompt.submit``); server→client requests (``srq-<12 hex>`` ids) wait for a response frame, survive reconnects
as ``open_requests`` and are withdrawn with ``request.cancel``. Params are checked against the pinned gateway
contract when it exists (unknown keys -> 4000). Unauthenticated /api/* calls get Hermes' 401 JSON envelope.
Everything lives in memory.

The "agent" is scripted. Per prompt it streams a short turn (~0.3 s):
  "[Voice call started] call_id: <32 hex>"  -> tool mcp__hermes_voice__speak("Hi, I am fake Hermes. I can hear you.")
                                               over MCP (streamable HTTP + bearer token), then "Call connected (text only)."
  "[Voice] <text>"                          -> speak("You said: <text>"), then the same as text
  "[Voice call ended] ..."                  -> "Call ended." (no speak)
  text containing approve / clarify / secret / sudo / window
                                            -> the matching server→client request (approval, clarify, secret,
                                               sudo, window.read), then a reply describing the answer
  anything else                             -> "Echo: <text>"
Prompts queued while a turn runs merge into one slot (Hermes' text-only queue merge) and run after it.

Run (from hermes-voice-mcp, to reuse its venv):
  uv run python ../devtools/fake_hermes.py --port 9311 --voice-url http://127.0.0.1:8765 --voice-token <token>
Sign in as test / test. Every RPC, event, server request and speak result is logged to stdout with the prefix FAKE.
"""

from __future__ import annotations

import argparse
import asyncio
import inspect
import json
import os
import re
import secrets
import time
import uuid
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Awaitable, Callable
from urllib.parse import urlsplit

import httpx2  # the mcp SDK's streamable HTTP client takes an httpx2.AsyncClient
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from starlette.routing import Route, WebSocketRoute
from starlette.websockets import WebSocket, WebSocketDisconnect

SESSION_AT_COOKIE = "hermes_session_at"  # hermes_cli/dashboard_auth/cookies.py
SESSION_PROVIDER_COOKIE = "hermes_session_provider"
TICKET_TTL = 30  # hermes_cli/dashboard_auth/ws_tickets.py: 30 s, single use
COOKIE_MAX_AGE = 24 * 3600
SPEAK_TOOL = "mcp__hermes_voice__speak"
HELLO_TEXT = "Hi, I am fake Hermes. I can hear you."
CALL_ID = re.compile(r"call_id:\s*([0-9a-fA-F]{32})")
MARKERS = ("[Voice call started]", "[Voice call ended]", "[Voice]")
STREAM_SECONDS = 0.3
STREAM_CHUNKS = 6
DEFAULT_CONTRACT = Path(__file__).resolve().parent.parent / "HermesVoice" / "Contract" / "gateway-contract.openrpc.json"

# tui_gateway/event_replay.py
REPLAY_BUFFER_MAX = 512
REPLAY_SESSIONS_MAX = 64
# tui_gateway/server.py _resolve_ws_orphan_reap_grace (dashboard.ws_orphan_reap_grace_s, 0 = park forever)
REAP_GRACE = 20.0
# tui_gateway/server.py _MINTED_SESSION_KEY_RE: the stored keys session.create mints.
MINTED_KEY = re.compile(r"\d{8}_\d{6}_[0-9a-f]{6}")
# contracts.SERVER_REQUESTS, as client.capabilities lists them.
SERVER_REQUESTS = sorted(["approval", "clarify", "display.install.sudo", "preview.act", "preview.read", "secret",
                          "sudo", "terminal.read", "tour", "vault.code", "vault.save_login", "vault.unlock_prompt",
                          "window.read"])
# tui_gateway/server_requests.py: a client's "no window here shows this session" decline.
NOT_SHOWN_CODE = 4404
NOT_SHOWN_MESSAGE = ("No Hermes Desktop window is showing this chat, so its preview, terminal and tour are out "
                     "of reach. Ask the user to open this chat in the Desktop app, then retry.")
# Requests whose answers are never logged.
SECRET_REQUESTS = {"secret", "sudo", "display.install.sudo", "vault.code", "vault.save_login", "vault.unlock_prompt"}
# server.py _ask callers: secret 300 s, sudo 120 s, window.read 30 s; approval and clarify have no deadline.
ASK_TIMEOUTS = {"secret": 300.0, "sudo": 120.0, "window.read": 30.0}
DEMO_COMMAND = "rm -rf /tmp/fake-hermes-demo"
DEMO_SUDO_COMMAND = "sudo apt-get install -y fake-hermes-demo"
DEMO_QUESTIONS = [
    {"qid": "q0", "question": "Which color should the demo use?", "choices": ["Blue (Recommended)", "Green", "Red"],
     "multi_select": False},
    {"qid": "q1", "question": "Which extras should it add?", "choices": ["Logs", "Metrics"], "multi_select": True},
    {"qid": "q2", "question": "Anything else?", "choices": None, "multi_select": False},
]


def log(*parts: Any) -> None:
    print("FAKE", time.strftime("%H:%M:%S"), *parts, flush=True)


def short(value: Any, limit: int = 160) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    text = text.replace("\n", "\\n")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def redacted(result: Any) -> Any:
    if not isinstance(result, dict):
        return result
    return {k: f"<{len(v)} chars>" if isinstance(v, str) else v for k, v in result.items()}


# ── state ─────────────────────────────────────────────────────────────────────────────────────────


@dataclass
class StoredSession:
    """A ``sessions`` row plus its ``messages`` rows (hermes_state_common.py schema, the fields the app reads)."""

    key: str
    source: str = "desktop"
    title: str | None = None
    started_at: float = field(default_factory=time.time)
    last_active: float = field(default_factory=time.time)
    messages: list[dict[str, Any]] = field(default_factory=list)
    # Hermes writes no row for a draft: it appears with the first prompt (methods_session.py _create_session).
    persisted: bool = False
    # The call_id of the "[Voice call started]" still running in this chat (the model would remember it).
    call_id: str | None = None

    def row(self) -> dict[str, Any]:
        visible = [m for m in self.messages if m["role"] in ("user", "assistant")]
        first_user = next((m["content"] for m in self.messages if m["role"] == "user"), "") or ""
        now = time.time()
        return {
            "id": self.key, "source": self.source, "title": self.title, "preview": first_user[:60],
            "started_at": self.started_at, "last_active": self.last_active, "ended_at": None,
            "message_count": len(visible), "profile": "default", "is_default_profile": True,
            "is_active": now - self.last_active < 300, "archived": False, "pinned": False, "hidden": False,
        }


@dataclass(eq=False)
class ServerRequest:
    """One open server→client request (tui_gateway/server_requests.py ServerRequest)."""

    sid: str
    method: str
    params: dict[str, Any]
    qids: list[str] | None = None
    on_result: Callable[[dict[str, Any] | None], None] | None = None
    id: str = field(default_factory=lambda: f"srq-{uuid.uuid4().hex[:12]}")
    created_at: float = field(default_factory=time.time)
    locked: dict[str, str | None] = field(default_factory=dict)
    declined: set["Conn"] = field(default_factory=set)
    result: dict[str, Any] | None = None
    answered: bool = False
    done: asyncio.Event = field(default_factory=asyncio.Event)

    def frame(self) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": self.id, "method": self.method,
                "params": {"session_id": self.sid, **self.params}}

    def snapshot(self) -> dict[str, Any]:
        """``open_requests`` entry: the request as sent, plus the batch answers locked so far."""
        params = {"session_id": self.sid, **self.params}
        if self.locked:
            params["answers"] = dict(self.locked)
        return {"id": self.id, "method": self.method, "params": params}

    def settle(self) -> None:
        if self.on_result is not None:
            self.on_result(self.result if self.answered else None)
        self.done.set()


@dataclass(eq=False)
class Approval:
    """One pending gateway approval (tools/approval_gateway_wait.py _ApprovalEntry)."""

    data: dict[str, Any]
    choice: str | None = None
    done: asyncio.Event = field(default_factory=asyncio.Event)


@dataclass
class Runtime:
    """A live gateway session (tui_gateway ``_sessions[sid]``): 8-hex runtime id bound to a stored key."""

    sid: str
    key: str
    created_at: float = field(default_factory=time.time)
    running: bool = False
    turn_started_at: float | None = None
    inflight: dict[str, Any] | None = None
    # Hermes' text-only queue: one slot, later prompts merge into it with a blank line (_enqueue_prompt).
    queued: str | None = None
    queued_row: dict[str, Any] | None = None
    transports: set["Conn"] = field(default_factory=set)
    approvals: list[Approval] = field(default_factory=list)
    loop_task: asyncio.Task | None = None
    turn_task: asyncio.Task | None = None
    reap_task: asyncio.Task | None = None


class Conn:
    """One /api/ws connection. Sends are serialized so frames never interleave."""

    def __init__(self, ws: WebSocket, peer: str) -> None:
        self.ws = ws
        self.peer = peer
        self.lock = asyncio.Lock()
        self.closed = False
        # client.capabilities {server_requests: true} (server_requests.advertise).
        self.answers_requests = False

    async def send(self, frame: dict[str, Any]) -> bool:
        if self.closed:
            return False
        try:
            async with self.lock:
                await self.ws.send_text(json.dumps(frame, ensure_ascii=False))
            return True
        except Exception as exc:  # noqa: BLE001 - a dead peer is dropped, like WSTransport latching _closed
            self.closed = True
            log(f"ws send failed peer={self.peer}: {type(exc).__name__}")
            return False


class FakeHermes:
    def __init__(self, args: argparse.Namespace) -> None:
        self.username = args.username
        self.password = args.password
        self.voice_url = args.voice_url.rstrip("/") if args.voice_url else None
        self.voice_token = args.voice_token or os.environ.get("HERMES_VOICE_TOKEN") or ""
        self.speak_timeout = args.speak_timeout
        self.reap_grace = args.reap_grace
        self.replay_max = args.replay_max
        self.replay_sessions_max = REPLAY_SESSIONS_MAX
        self.ask_timeouts = dict(ASK_TIMEOUTS)
        self.param_keys = load_param_keys(Path(args.contract)) if args.contract else {}
        self.access_tokens: dict[str, float] = {}
        self.tickets: dict[str, float] = {}
        self.sessions: dict[str, StoredSession] = {}
        self.runtimes: dict[str, Runtime] = {}
        self.idempotency: dict[str, str] = {}
        self.conns: set[Conn] = set()
        self.requests: dict[str, ServerRequest] = {}
        self.next_row_id = 1
        self.replay_epoch = uuid.uuid4().hex
        self.next_seq: dict[str, int] = {}
        self.rings: OrderedDict[str, deque[tuple[int, dict[str, Any]]]] = OrderedDict()
        self.evicted_through: dict[str, int] = {}
        self._seed()

    # ── helpers ───────────────────────────────────────────────────────────────────────────────────

    def new_key(self) -> str:
        # Server-minted keys are %Y%m%d_%H%M%S_ + 6 hex (tui_gateway/server.py _MINTED_SESSION_KEY_RE).
        return datetime.now().strftime("%Y%m%d_%H%M%S_") + secrets.token_hex(3)

    def add_row(self, stored: StoredSession, role: str, content: str | None, **extra: Any) -> dict[str, Any]:
        row = {
            "id": self.next_row_id, "session_id": stored.key, "role": role, "content": content,
            "tool_call_id": None, "tool_calls": None, "tool_name": None, "timestamp": time.time(),
            "finish_reason": None, "display_kind": None,
        }
        row.update(extra)
        self.next_row_id += 1
        stored.messages.append(row)
        stored.last_active = time.time()
        stored.persisted = True
        return row

    def resequence(self, stored: StoredSession, row: dict[str, Any]) -> None:
        """Move a queued prompt's row (written at accept, as Hermes does) behind the turn it waited for."""
        if row in stored.messages and stored.messages[-1] is not row:
            stored.messages.remove(row)
            row["id"] = self.next_row_id
            self.next_row_id += 1
            stored.messages.append(row)

    def _seed(self) -> None:
        stored = StoredSession(key=self.new_key(), title="Fake Hermes welcome", started_at=time.time() - 3600)
        self.sessions[stored.key] = stored
        self.add_row(stored, "user", "Hello fake Hermes")
        args = {"text": "This line was spoken in an earlier call.", "call_id": "0" * 32}
        tool_id = "call_" + secrets.token_hex(6)
        self.add_row(stored, "assistant", "", tool_calls=[{
            "id": tool_id, "type": "function", "function": {"name": SPEAK_TOOL, "arguments": json.dumps(args)}}])
        self.add_row(stored, "tool", json.dumps({"result": "Spoken to the user (2.0s of audio)."}),
                     tool_call_id=tool_id, tool_name=SPEAK_TOOL)
        self.add_row(stored, "assistant", "Hi! I am the fake Hermes dashboard. Start a call with the phone button.",
                     finish_reason="stop")
        stored.last_active = time.time() - 1800

    def info(self, rt: Runtime) -> dict[str, Any]:
        """session.info / result ``info`` (contracts/common.py SessionLiveInfo, the fields that matter here)."""
        stored = self.sessions.get(rt.key)
        return {
            "model": "fake-hermes", "provider": "fake", "tools": {}, "skills": {}, "cwd": "",
            "running": rt.running, "turn_started_at": rt.turn_started_at,
            "title": (stored.title if stored else None) or "", "stored_session_id": rt.key,
            "profile_name": "default", "lazy": False,
        }

    def find_runtime(self, key: str) -> Runtime | None:
        return next((rt for rt in self.runtimes.values() if rt.key == key), None)

    @staticmethod
    def live(rt: Runtime | None) -> list[Conn]:
        return [c for c in rt.transports if not c.closed] if rt else []

    def attach(self, rt: Runtime, conn: Conn) -> None:
        """Bind a client to the session alongside the others and cancel a pending orphan reap."""
        rt.transports.add(conn)
        if rt.reap_task is not None:
            rt.reap_task.cancel()
            rt.reap_task = None

    def live_status(self, rt: Runtime) -> str:
        # server.py _session_live_status
        if any(r.sid == rt.sid for r in self.requests.values()):
            return "waiting"
        return "working" if rt.running else "idle"

    def live_payload(self, rt: Runtime, omit: bool) -> dict[str, Any]:
        """session.activate / fast-path session.resume (server.py _live_session_payload)."""
        stored = self.sessions.get(rt.key)
        messages = [] if omit else gateway_messages(stored)
        payload: dict[str, Any] = {
            "info": self.info(rt), "message_count": len(stored.messages if stored else []) if omit else len(messages),
            "messages": messages, "messages_omitted": omit, "running": rt.running,
            "turn_started_at": rt.turn_started_at, "session_id": rt.sid, "session_key": rt.key,
            "started_at": rt.created_at, "status": self.live_status(rt),
        }
        pending = approval_payload(rt.approvals[0].data) if rt.approvals else None
        for key, value in (("inflight", dict(rt.inflight) if rt.inflight else None),
                           ("queued", {"user": rt.queued} if rt.queued else None),
                           ("pending_approval", pending), ("open_requests", self.open_requests(rt.sid))):
            if value:
                payload[key] = value
        return payload

    # ── HTTP ──────────────────────────────────────────────────────────────────────────────────────

    def authed(self, request: Request) -> bool:
        token = request.cookies.get(SESSION_AT_COOKIE)
        expiry = self.access_tokens.get(token or "")
        return expiry is not None and expiry > time.time()

    @staticmethod
    def unauthorized(request: Request) -> JSONResponse:
        # hermes_cli/dashboard_auth/middleware.py _unauth_response, /api/* branch.
        return JSONResponse({"error": "unauthenticated", "detail": "Unauthorized", "reason": "no_session",
                             "login_url": "/login"}, status_code=401)

    @staticmethod
    def origin_problem(request: Request) -> str | None:
        """Hermes trusts only its own origin on state-changing requests; the app sends Origin on every POST."""
        origin = request.headers.get("origin")
        if not origin:
            return None
        host = request.headers.get("host", "")
        parts = urlsplit(origin)
        return None if parts.netloc == host else f"Origin {origin} does not match Host {host}"

    async def password_login(self, request: Request) -> Response:
        if problem := self.origin_problem(request):
            log("http POST /auth/password-login -> 403", problem)
            return JSONResponse({"detail": problem}, status_code=403)
        try:
            body = await request.json()
            provider, username, password = body["provider"], body["username"], body["password"]
        except Exception:  # noqa: BLE001 - FastAPI answers a malformed body with 422
            log("http POST /auth/password-login -> 422 (bad body)")
            return JSONResponse({"detail": "provider, username and password are required"}, status_code=422)
        if provider != "basic":
            log(f"http POST /auth/password-login provider={provider!r} -> 404")
            return JSONResponse({"detail": "Unknown provider"}, status_code=404)
        if username != self.username or password != self.password:
            log(f"http POST /auth/password-login user={username!r} -> 401")
            return JSONResponse({"detail": "Invalid credentials"}, status_code=401)
        token = secrets.token_urlsafe(32)
        self.access_tokens[token] = time.time() + COOKIE_MAX_AGE
        response = JSONResponse({"ok": True, "next": "/"})
        response.set_cookie(SESSION_AT_COOKIE, token, max_age=COOKIE_MAX_AGE, path="/", httponly=True, samesite="lax")
        response.set_cookie(SESSION_PROVIDER_COOKIE, provider, max_age=COOKIE_MAX_AGE, path="/", httponly=True,
                            samesite="lax")
        log(f"http POST /auth/password-login user={username!r} -> 200 (cookie set)")
        return response

    async def logout(self, request: Request) -> Response:
        self.access_tokens.pop(request.cookies.get(SESSION_AT_COOKIE) or "", None)
        response = RedirectResponse("/login", status_code=302)
        for name in (SESSION_AT_COOKIE, SESSION_PROVIDER_COOKIE):
            response.delete_cookie(name, path="/", httponly=True, samesite="lax")
        log("http POST /auth/logout -> 302 /login (session ended)")
        return response

    async def login_page(self, request: Request) -> Response:
        return HTMLResponse("<!doctype html><title>Fake Hermes</title><p>Fake Hermes dashboard. Sign in from the app.")

    async def ws_ticket(self, request: Request) -> Response:
        if not self.authed(request):
            log("http POST /api/auth/ws-ticket -> 401")
            return self.unauthorized(request)
        if problem := self.origin_problem(request):
            log("http POST /api/auth/ws-ticket -> 403", problem)
            return JSONResponse({"detail": problem}, status_code=403)
        ticket = secrets.token_urlsafe(24)
        self.tickets[ticket] = time.time() + TICKET_TTL
        log("http POST /api/auth/ws-ticket -> 200")
        return JSONResponse({"ticket": ticket, "ttl_seconds": TICKET_TTL})

    async def list_sessions(self, request: Request) -> Response:
        if not self.authed(request):
            log("http GET /api/profiles/sessions -> 401")
            return self.unauthorized(request)
        q = request.query_params
        limit, offset = int(q.get("limit", 20)), int(q.get("offset", 0))
        min_messages = int(q.get("min_messages", 0))
        rows = [s.row() for s in self.sessions.values() if s.persisted]
        rows = [r for r in rows if r["message_count"] >= min_messages]
        excluded = {s.strip() for s in (q.get("exclude_sources") or "").split(",") if s.strip()}
        rows = [r for r in rows if r["source"] not in excluded]
        key = "last_active" if q.get("order", "recent") == "recent" else "started_at"
        rows.sort(key=lambda r: r[key], reverse=True)
        window = rows[offset:offset + limit]
        log(f"http GET /api/profiles/sessions -> 200 ({len(window)} of {len(rows)})")
        return JSONResponse({"sessions": window, "total": len(rows), "profile_totals": {"default": len(rows)},
                             "limit": limit, "offset": offset, "errors": [], "storage": {}})

    async def session_messages(self, request: Request) -> Response:
        sid = request.path_params["session_id"]
        if not self.authed(request):
            log(f"http GET /api/sessions/{sid}/messages -> 401")
            return self.unauthorized(request)
        stored = self.sessions.get(sid)
        if stored is None or not stored.persisted:
            log(f"http GET /api/sessions/{sid}/messages -> 404")
            return JSONResponse({"detail": "Session not found"}, status_code=404)
        q = request.query_params
        rows = stored.messages
        limit = min(int(q["limit"]), 500) if q.get("limit") else 500
        offset = int(q.get("offset", 0))
        order = q.get("order") or ("latest" if not q.get("limit") else "oldest")
        if order == "latest":
            end = max(len(rows) - offset, 0)
            page = rows[max(end - limit, 0):end]
        else:
            page = rows[offset:offset + limit]
        log(f"http GET /api/sessions/{sid}/messages -> 200 ({len(page)} rows)")
        return JSONResponse({"session_id": sid, "profile": "default", "messages": page,
                             "pagination": {"limit": limit, "offset": offset, "order": order, "returned": len(page)}})

    # ── WebSocket gateway ─────────────────────────────────────────────────────────────────────────

    async def gateway_ws(self, ws: WebSocket) -> None:
        peer = f"{ws.client.host}:{ws.client.port}" if ws.client else "?"
        ticket = ws.query_params.get("ticket", "")
        expiry = self.tickets.pop(ticket, None)
        if expiry is None or expiry < time.time():
            log(f"ws /api/ws peer={peer} rejected: ticket invalid -> close 4401")
            await ws.close(code=4401)
            return
        await ws.accept()
        conn = Conn(ws, peer)
        log(f"ws /api/ws accepted peer={peer}")
        if await conn.send({"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {
                "skin": {}, "change_events": True, "heartbeat": True, "replay_epoch": self.replay_epoch}}}):
            self.conns.add(conn)  # register_live_transport: reached by session-less broadcasts
        reason = "?"
        try:
            while True:
                raw = (await ws.receive_text()).strip()
                if not raw:
                    continue
                try:
                    req = json.loads(raw)
                except json.JSONDecodeError:
                    await conn.send(_err(None, -32700, "parse error"))
                    continue
                if isinstance(req, dict) and req.get("method") == "gateway.ping":
                    # Answered on the read loop (ws.py), never queued behind a handler. Not logged: every 15 s.
                    await conn.send({"jsonrpc": "2.0", "result": {"ok": True}, "id": req.get("id")})
                    continue
                if is_response_frame(req):
                    self.resolve_response(req, conn)  # the client answering one of our requests: no reply
                    continue
                if not isinstance(req, dict):
                    await conn.send(_err(None, -32600, "invalid request: expected an object"))
                    continue
                method, rid, params = req.get("method"), req.get("id"), req.get("params", {})
                if not isinstance(method, str) or not method:
                    await conn.send(_err(rid, -32600, "invalid request: method must be a non-empty string"))
                    continue
                if params is not None and not isinstance(params, dict):
                    await conn.send(_err(rid, -32602, "invalid params: expected an object"))
                    continue
                params = params or {}
                log(f"rpc <- {method} id={rid} params={short(self.loggable(method, params))}")
                response = await self.dispatch(conn, rid, method, params)
                if "error" in response:
                    log(f"rpc -> {method} id={rid} ERROR {short(response['error'])}")
                else:
                    log(f"rpc -> {method} id={rid} result={short(response['result'])}")
                await conn.send(response)
        except WebSocketDisconnect as exc:
            reason = f"client_disconnect(code={exc.code})"
        except Exception as exc:  # noqa: BLE001
            reason = f"{type(exc).__name__}: {exc}"
        finally:
            conn.closed = True
            self.conns.discard(conn)
            # Detach only: the session keeps running (and its turn too); events reach nobody but the replay ring
            # until a client re-attaches. A session left without clients is reaped after the grace.
            detached = 0
            for rt in list(self.runtimes.values()):
                if conn in rt.transports:
                    rt.transports.discard(conn)
                    if not self.live(rt):
                        detached += 1
                        self.schedule_reap(rt)
            log(f"ws /api/ws closed peer={peer} reason={reason} detached_sessions={detached}")

    def loggable(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "request.answer" and (req := self.requests.get(str(params.get("id")))) is not None \
                and req.method in SECRET_REQUESTS:
            return {**params, "result": redacted(params.get("result"))}
        return params

    async def dispatch(self, conn: Conn, rid: Any, method: str, params: dict[str, Any]) -> dict[str, Any]:
        handler = {
            "ping": lambda: {"pong": True},
            "client.capabilities": lambda: self.client_capabilities(conn, params),
            "session.create": lambda: self.session_create(conn, params),
            "session.resume": lambda: self.session_resume(conn, params),
            "session.activate": lambda: self.session_activate(conn, params),
            "session.events.since": lambda: self.events_since(params),
            "prompt.submit": lambda: self.prompt_submit(conn, params),
            "session.interrupt": lambda: self.session_interrupt(params),
            "approval.respond": lambda: self.approval_respond(params),
            "request.answer": lambda: self.request_answer(params),
            "clarify.lock": lambda: self.clarify_lock(params),
        }.get(method)
        if handler is None:
            return _err(rid, -32601, f"unknown method: {method} — the client and the Hermes backend are out of sync "
                        "(different versions); run `hermes update` and restart both")
        allowed = self.param_keys.get(method)
        if allowed is not None and (extra := next((k for k in params if k not in allowed), None)) is not None:
            # contracts/registry.py validate_params: unknown keys only; required/type errors are the handler's.
            return _err(rid, 4000, f"invalid params for {method}: {extra}: Extra inputs are not permitted — the "
                        "client and the Hermes backend are out of sync (different versions); run `hermes update` "
                        "and restart both")
        try:
            result = handler()
            if inspect.isawaitable(result):
                result = await result
        except RpcError as exc:
            return _err(rid, exc.code, exc.message)
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    def client_capabilities(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        conn.answers_requests = bool(params.get("server_requests"))
        return {"server_requests": SERVER_REQUESTS, "declines_not_shown": True}

    def session_create(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        idem = params.get("idempotency_key")
        if idem and (sid := self.idempotency.get(idem)) and (rt := self.runtimes.get(sid)):
            # A retry returns the same session without binding this socket (methods_session.py).
            return {"session_id": rt.sid, "stored_session_id": rt.key, "message_count": 0, "messages": [],
                    "info": self.info(rt)}
        stored = StoredSession(key=self.new_key(), source=str(params.get("source") or "desktop"),
                               title=params.get("title") or None)
        self.sessions[stored.key] = stored
        rt = Runtime(sid=uuid.uuid4().hex[:8], key=stored.key)
        self.attach(rt, conn)
        self.runtimes[rt.sid] = rt
        if idem:
            self.idempotency[idem] = rt.sid
        return {"session_id": rt.sid, "stored_session_id": rt.key, "message_count": 0, "messages": [],
                "info": self.info(rt)}

    def session_resume(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        key = params.get("session_id") or ""
        if not key:
            raise RpcError(4006, "session_id required")
        omit = bool(params.get("omit_messages"))
        stored = self.sessions.get(key)
        rt = self.find_runtime(key)
        if rt is not None:
            # Fast path: reattach this client to the live session (methods_session.py _resume_reuse_live).
            self.attach(rt, conn)
            return {**self.live_payload(rt, omit), "resumed": key}
        if stored is None or not stored.persisted:
            # A minted key without a row (a draft whose runtime was reaped before its first prompt) gets an empty
            # row and resumes cold (methods_session.py _resume_materialize_minted), not 4007.
            if not MINTED_KEY.fullmatch(key):
                raise RpcError(4007, "session not found")
            if stored is None:
                stored = self.sessions[key] = StoredSession(key=key, source=str(params.get("source") or "desktop"))
            stored.persisted = True
            log(f"materialized an empty row for minted key {key}")
        rt = Runtime(sid=uuid.uuid4().hex[:8], key=key)
        self.attach(rt, conn)
        self.runtimes[rt.sid] = rt
        # Cold resume (methods_session.py _resume_response).
        return {"session_id": rt.sid, "resumed": key, "message_count": len(stored.messages),
                "messages": [] if omit else gateway_messages(stored), "messages_omitted": omit,
                "info": self.info(rt), "inflight": None, "running": False, "session_key": key,
                "started_at": stored.started_at, "status": "idle"}

    def session_activate(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        """Re-attach by RUNTIME id (methods_session.py): 4001 once the runtime is gone (reaped, or never existed)."""
        rt = self.runtimes.get(str(params.get("session_id") or ""))
        if rt is None:
            raise RpcError(4001, "session not found")
        self.attach(rt, conn)
        return self.live_payload(rt, bool(params.get("omit_messages")))

    def events_since(self, params: dict[str, Any]) -> dict[str, Any]:
        sid = str(params.get("session_id") or "")
        try:
            last_seen = int(params.get("last_seen", 0))
        except (TypeError, ValueError):
            raise RpcError(-32602, "invalid params: last_seen must be an integer") from None
        frames = [event for seq, event in self.rings.get(sid, ()) if seq > last_seen]
        return {"events": frames, "latest_seq": self.next_seq.get(sid, 0),
                "truncated": last_seen < self.evicted_through.get(sid, 0), "count": len(frames),
                "epoch": self.replay_epoch, "open_requests": self.open_requests(sid)}

    def prompt_submit(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        rt = self.runtimes.get(params.get("session_id") or "")
        if rt is None:
            raise RpcError(4001, "session not found")
        text = params.get("text")
        if not isinstance(text, str) or not text.strip():
            raise RpcError(4002, "text required")
        self.attach(rt, conn)  # prompt.submit rebinds the session to the submitting transport
        stored = self.sessions[rt.key]
        if rt.running:
            # Busy: queue (queued=True forces queue mode). Without it Hermes' default busy_input_mode
            # "interrupt" redirects or interrupts the live turn and queues the prompt; the fake interrupts + queues.
            if rt.queued is None:
                rt.queued = text
                rt.queued_row = self.add_row(stored, "user", text)  # durable at accept
            else:
                rt.queued = f"{rt.queued}\n\n{text}"  # text-only prompts merge into one slot
                if rt.queued_row is not None:
                    rt.queued_row["content"] = rt.queued
            if not params.get("queued") and rt.turn_task is not None:
                log(f"busy prompt without queued: interrupting the running turn of {rt.sid}")
                rt.turn_task.cancel()
            return {"status": "queued"}
        row = self.add_row(stored, "user", text)
        rt.running = True
        rt.turn_started_at = time.time()
        rt.loop_task = asyncio.create_task(self.turn_loop(rt, text))
        return {"status": "streaming", "user_row_id": row["id"]}

    async def session_interrupt(self, params: dict[str, Any]) -> dict[str, Any]:
        rt = self.runtimes.get(params.get("session_id") or "")
        if rt is None:
            raise RpcError(4001, "session not found")
        # session_lifecycle.py _interrupt_session_turn: Stop also drops the queue and withdraws open requests.
        if rt.queued_row is not None:
            stored = self.sessions[rt.key]
            if rt.queued_row in stored.messages:
                stored.messages.remove(rt.queued_row)
        rt.queued, rt.queued_row = None, None
        if rt.turn_task is not None and not rt.turn_task.done():
            rt.turn_task.cancel()
        await self.cancel_requests(rt.sid, "interrupted")
        self.resolve_approvals(rt, "deny", resolve_all=True)
        return {"status": "interrupted"}

    def approval_respond(self, params: dict[str, Any]) -> dict[str, Any]:
        rt = self.runtimes.get(params.get("session_id") or "")
        if rt is None:
            # methods_prompt.py _approval_respond_session_fallback: the request id, then a stored session id.
            request_id = str(params.get("request_id") or "")
            rt = next((r for r in self.runtimes.values()
                       if request_id and any(a.data["request_id"] == request_id for a in r.approvals)), None)
            rt = rt or self.find_runtime(str(params.get("session_id") or ""))
            if rt is None:
                raise RpcError(4001, "session not found")
        resolved = self.resolve_approvals(rt, params.get("choice", "deny"), resolve_all=bool(params.get("all")),
                                          request_id=params.get("request_id"))
        return {"resolved": resolved}

    def request_answer(self, params: dict[str, Any]) -> dict[str, Any]:
        """Answer an open request out of band (methods_prompt.py): ``expired`` once it already ended."""
        request_id, result = str(params.get("id") or ""), params.get("result")
        if not request_id or not isinstance(result, dict):
            raise RpcError(4002, "id and an object result required")
        resolved = self.resolve_response({"jsonrpc": "2.0", "id": request_id, "result": result}, None)
        return {"status": "ok" if resolved else "expired"}

    def clarify_lock(self, params: dict[str, Any]) -> dict[str, Any]:
        request_id, question_id = str(params.get("request_id") or ""), str(params.get("question_id") or "")
        if not request_id or not question_id:
            raise RpcError(4002, "request_id and question_id required")
        answer = params.get("answer", "")
        if answer is not None and not isinstance(answer, str):
            answer = json.dumps(answer, ensure_ascii=False)
        try:
            remaining = self.lock_answer(request_id, question_id, answer)
        except ValueError as exc:
            raise RpcError(4002, str(exc)) from None
        if remaining is None:
            return {"status": "expired"}
        return {"status": "ok", "remaining": remaining}

    # ── orphan reaping (session_lifecycle.py _schedule_ws_orphan_reap) ───────────────────────────────

    def schedule_reap(self, rt: Runtime) -> None:
        if self.reap_grace <= 0:
            return
        if rt.reap_task is not None:
            rt.reap_task.cancel()
        rt.reap_task = asyncio.create_task(self.reap_later(rt))

    async def reap_later(self, rt: Runtime) -> None:
        await asyncio.sleep(self.reap_grace)
        rt.reap_task = None
        if self.runtimes.get(rt.sid) is not rt or self.live(rt):
            return
        if rt.running:
            # Client-absent but producing (a turn, or one waiting on a human): re-check each grace.
            log(f"reap of {rt.sid} deferred: its turn is still running")
            self.schedule_reap(rt)
            return
        self.runtimes.pop(rt.sid, None)
        for idem in [k for k, sid in self.idempotency.items() if sid == rt.sid]:
            del self.idempotency[idem]
        log(f"reaped detached session {rt.sid} (stored {rt.key}) after {self.reap_grace:g}s")
        await self.broadcast("session.reclaimed", {"session_id": rt.sid, "stored_session_id": rt.key,
                                                   "reason": "ws_orphan_reap"})

    # ── events + replay ring (event_replay.py) ──────────────────────────────────────────────────────

    def stamp(self, params: dict[str, Any]) -> None:
        """Give one event its per-session seq and keep it for session.events.since."""
        sid = params.get("session_id") or ""
        if not sid:
            return  # session-less broadcasts are re-fetchable via their own RPCs
        seq = self.next_seq.get(sid, 0) + 1
        self.next_seq[sid] = seq
        params["seq"] = seq
        ring = self.rings.get(sid)
        if ring is None:
            ring = self.rings[sid] = deque()
            while len(self.rings) > self.replay_sessions_max:
                # FIFO eviction drops the ring but keeps the numbering; any older watermark now has a gap.
                oldest, _ = self.rings.popitem(last=False)
                self.evicted_through[oldest] = max(self.evicted_through.get(oldest, 0),
                                                   self.next_seq.get(oldest, 0))
        ring.append((seq, params))
        while len(ring) > self.replay_max:
            evicted, _ = ring.popleft()
            self.evicted_through[sid] = max(self.evicted_through.get(sid, 0), evicted)

    async def emit(self, rt: Runtime, kind: str, payload: dict[str, Any] | None = None) -> None:
        await self.emit_to(rt.sid, kind, payload)

    async def emit_to(self, sid: str, kind: str, payload: dict[str, Any] | None = None) -> None:
        params: dict[str, Any] = {"type": kind, "session_id": sid}
        if payload is not None:
            params["payload"] = payload
        self.stamp(params)
        rt = self.runtimes.get(sid)
        targets = self.live(rt)
        detail = "" if payload is None else " " + short(payload, 120)
        log(f"event {kind} sid={sid} seq={params['seq']}{detail}" + ("" if targets else " (no client attached)"))
        frame = {"jsonrpc": "2.0", "method": "event", "params": params}
        for conn in targets:
            if not await conn.send(frame) and rt is not None:
                rt.transports.discard(conn)

    async def broadcast(self, kind: str, payload: dict[str, Any]) -> None:
        """A session-less event to every connected client (server.py _broadcast_global_event): no seq."""
        log(f"broadcast {kind} {short(payload, 120)}")
        frame = {"jsonrpc": "2.0", "method": "event", "params": {"type": kind, "session_id": "", "payload": payload}}
        for conn in list(self.conns):
            await conn.send(frame)

    # ── server→client requests (server_requests.py) ─────────────────────────────────────────────────

    def answerable(self, rt: Runtime) -> bool:
        """False only when every attached client never advertised server_requests (an app build too old)."""
        clients = self.live(rt)
        return not clients or any(c.answers_requests for c in clients)

    def open_requests(self, sid: str) -> list[dict[str, Any]]:
        reqs = sorted((r for r in self.requests.values() if r.sid == sid), key=lambda r: r.created_at)
        return [r.snapshot() for r in reqs]

    async def register(self, rt: Runtime, req: ServerRequest) -> None:
        self.requests[req.id] = req
        targets = self.live(rt)
        log(f"srq -> {req.method} id={req.id} sid={rt.sid} params={short(req.params, 120)}"
            + ("" if targets else " (no client attached: waits in open_requests)"))
        for conn in targets:
            await conn.send(req.frame())

    async def send_request(self, rt: Runtime, method: str, params: dict[str, Any], *, timeout: float | None,
                           qids: list[str] | None = None) -> dict[str, Any] | None:
        """One request whose answer the turn waits for; None when nobody answered (error, timeout, cancel)."""
        if not self.answerable(rt):
            log(f"srq {method} for {rt.sid} not sent: the attached client never sent client.capabilities")
            return None
        req = ServerRequest(rt.sid, method, params, qids=qids)
        await self.register(rt, req)
        try:
            await asyncio.wait_for(req.done.wait(), timeout)
        except asyncio.TimeoutError:
            pass
        except asyncio.CancelledError:
            if self.requests.pop(req.id, None) is req:
                await self.emit_cancel(req, "interrupted")
            raise
        timed_out = self.requests.pop(req.id, None) is req
        if req.answered:
            return req.result
        if timed_out:
            await self.emit_cancel(req, "timeout")
            if req.qids is not None:
                return {"answers": dict(req.locked), "outcome": "timed_out"}
        return None

    async def send_request_async(
            self, rt: Runtime, method: str, params: dict[str, Any],
            on_result: Callable[[dict[str, Any] | None], None]) -> Callable[[str], Awaitable[None]]:
        """A request whose wait is owned elsewhere (the approval queue); returns ``settle(reason)``."""
        async def noop(reason: str) -> None:
            return None

        if not self.answerable(rt):
            log(f"srq {method} for {rt.sid} not sent: the attached client never sent client.capabilities")
            on_result(None)
            return noop
        req = ServerRequest(rt.sid, method, params, on_result=on_result)
        await self.register(rt, req)

        async def settle(reason: str) -> None:
            if self.requests.pop(req.id, None) is req:
                await self.emit_cancel(req, reason)

        return settle

    async def emit_cancel(self, req: ServerRequest, reason: str) -> None:
        await self.emit_to(req.sid, "request.cancel", {"id": req.id, "method": req.method, "reason": reason})

    def resolve_response(self, frame: dict[str, Any], conn: Conn | None) -> bool:
        """Route one client response to its open request; False when nothing waits for that id."""
        rid = frame.get("id")
        if not isinstance(rid, str):
            log(f"srq <- id={rid!r} dropped: not a server request id")
            return False
        error = frame.get("error")
        if isinstance(error, dict) and error.get("code") == NOT_SHOWN_CODE:
            return self.decline(rid, conn)
        req = self.requests.pop(rid, None)
        if req is None:
            log(f"srq <- id={rid} dropped: request no longer open")
            return False
        if "error" in frame:
            log(f"srq <- {req.method} id={rid} ERROR {short(error)}")
            req.result, req.answered = None, False
        else:
            result = frame.get("result")
            log(f"srq <- {req.method} id={rid} result="
                f"{short(redacted(result) if req.method in SECRET_REQUESTS else result)}")
            req.result = result if isinstance(result, dict) else {}
            if req.qids and "answers" in req.result:
                # Answers locked early via clarify.lock belong to the final set.
                answers = req.result.get("answers")
                merged = dict(req.locked)
                if isinstance(answers, dict):
                    merged.update(answers)
                req.result = {**req.result, "answers": merged, "outcome": "submitted"}
            elif req.qids:
                req.result = {"answers": dict(req.locked), "outcome": "cancelled"}
            req.answered = True
        req.settle()
        return True

    def decline(self, rid: str, conn: Conn | None) -> bool:
        """One client's 4404: settles only once every answering client attached to the session declined."""
        req = self.requests.get(rid)
        if req is None:
            log(f"srq <- id={rid} decline dropped: request no longer open")
            return False
        clients = {c for c in self.live(self.runtimes.get(req.sid)) if c.answers_requests} if conn else set()
        if conn is not None:
            req.declined.add(conn)
        log(f"srq <- {req.method} id={rid} declined (4404) by {len(req.declined & clients)} of {len(clients)} clients")
        if not clients or not clients <= req.declined:
            return True
        self.requests.pop(rid, None)
        req.result, req.answered = {"value": json.dumps({"success": False, "error": NOT_SHOWN_MESSAGE})}, True
        req.settle()
        return True

    def lock_answer(self, request_id: str, question_id: str, answer: str | None) -> list[str] | None:
        req = self.requests.get(request_id)
        if req is None or req.qids is None:
            return None
        if question_id not in req.qids:
            raise ValueError(f"unknown question_id {question_id!r}")
        req.locked[question_id] = answer
        remaining = [qid for qid in req.qids if qid not in req.locked]
        if not remaining:
            self.requests.pop(request_id, None)
            req.result, req.answered = {"answers": dict(req.locked), "outcome": "submitted"}, True
            req.settle()
        return remaining

    async def cancel_requests(self, sid: str, reason: str) -> int:
        """Withdraw every open request of one session, each with a request.cancel."""
        targets = [r for r in self.requests.values() if r.sid == sid]
        for req in targets:
            self.requests.pop(req.id, None)
            if req.qids is not None:
                req.result, req.answered = {"answers": dict(req.locked), "outcome": "cancelled"}, True
            else:
                req.result, req.answered = None, False
        for req in targets:
            req.settle()
            await self.emit_cancel(req, reason)
        return len(targets)

    # ── approvals (tools/approval.py gateway queue) ─────────────────────────────────────────────────

    def resolve_approvals(self, rt: Runtime, choice: Any, *, resolve_all: bool = False,
                          request_id: str | None = None) -> int:
        if request_id:
            targets = [a for a in rt.approvals if a.data.get("request_id") == request_id]
        elif resolve_all:
            targets = list(rt.approvals)
        else:
            targets = rt.approvals[:1]
        for entry in targets:
            rt.approvals.remove(entry)
            entry.choice = choice
            entry.done.set()
        return len(targets)

    async def await_approval(self, rt: Runtime, data: dict[str, Any]) -> str | None:
        """Queue one approval, ask the client, and wait; None when it was withdrawn (nobody could answer)."""
        entry = Approval(data={"request_id": uuid.uuid4().hex, **data})
        rt.approvals.append(entry)

        def on_result(result: dict[str, Any] | None) -> None:
            if result is None:
                # No client can answer (never advertised, or answered with an error): a withdrawal, not a deny.
                if entry in rt.approvals:
                    rt.approvals.remove(entry)
                entry.done.set()
                return
            self.resolve_approvals(rt, str(result.get("choice") or "deny"), resolve_all=bool(result.get("all")),
                                   request_id=entry.data["request_id"])

        settle = await self.send_request_async(rt, "approval", approval_payload(entry.data), on_result)
        state = "set"
        try:
            await entry.done.wait()
        except asyncio.CancelledError:
            state = "interrupted"
            raise
        finally:
            if entry in rt.approvals:
                rt.approvals.remove(entry)
            await settle(state if state != "set" else "resolved" if entry.choice is not None else "session_closed")
        return entry.choice

    # ── the scripted agent ────────────────────────────────────────────────────────────────────────

    async def turn_loop(self, rt: Runtime, text: str) -> None:
        """Runs a turn, then any prompt queued meanwhile (session_auto_continue.py _drain_queued_prompt)."""
        next_text: str | None = text
        while next_text is not None:
            rt.turn_task = asyncio.create_task(self.run_turn(rt, next_text))
            await asyncio.wait({rt.turn_task})
            if rt.turn_task.cancelled():  # cancelled before it started: still close the turn
                await self.emit(rt, "message.complete", {"text": "", "status": "interrupted", "usage": usage(0)})
            rt.turn_task = None
            rt.running = False
            rt.inflight = None
            rt.turn_started_at = None
            await self.emit(rt, "session.info", self.info(rt))
            next_text, rt.queued = rt.queued, None
            if next_text is not None:
                if rt.queued_row is not None:
                    self.resequence(self.sessions[rt.key], rt.queued_row)
                rt.queued_row = None
                rt.running = True
                rt.turn_started_at = time.time()
                log(f"draining queued prompt on {rt.sid}: {short(next_text, 80)}")

    async def run_turn(self, rt: Runtime, text: str) -> None:
        stored = self.sessions[rt.key]
        rt.inflight = {"user": text, "assistant": "", "streaming": True}
        replies: list[str] = []
        streamed = ""
        try:
            await self.emit(rt, "message.start")
            for segment in segments(text):
                if segment.startswith("[Voice call started]"):
                    match = CALL_ID.search(segment)
                    if match is None:
                        replies.append("That call announcement has no call_id, so I can't speak on it.")
                        continue
                    stored.call_id = match.group(1).lower()
                    await self.speak(rt, stored, HELLO_TEXT, stored.call_id)
                    replies.append("Call connected (text only).")
                elif segment.startswith("[Voice call ended]"):
                    stored.call_id = None
                    replies.append("Call ended.")
                elif segment.startswith("[Voice]"):
                    said = segment[len("[Voice]"):].strip()
                    reply = f"You said: {said}"
                    if stored.call_id is None:
                        replies.append(f"{reply} (no voice call is running in this chat, so text only)")
                        continue
                    result, ok = await self.speak(rt, stored, reply, stored.call_id)
                    replies.append(reply if ok and result.startswith("Spoken") else f"{reply} (speak: {result})")
                else:
                    replies.append(await self.reply_to(rt, stored, segment))
            final = "\n\n".join(replies)
            for chunk in chunks(final, STREAM_CHUNKS):
                await asyncio.sleep(STREAM_SECONDS / STREAM_CHUNKS)
                streamed += chunk
                rt.inflight["assistant"] = streamed
                await self.emit(rt, "message.delta", {"text": chunk})
            self.add_row(stored, "assistant", final, finish_reason="stop")
            await self.emit(rt, "message.complete", {"text": final, "usage": usage(len(final.split())),
                                                     "status": "complete"})
            if stored.title is None:
                stored.title = title_for(text)
                await self.emit(rt, "session.title", {"session_id": stored.key, "title": stored.title})
        except asyncio.CancelledError:
            log(f"turn on {rt.sid} interrupted")
            if streamed:
                self.add_row(stored, "assistant", streamed, finish_reason="interrupted")
            await self.emit(rt, "message.complete", {"text": streamed, "usage": usage(0), "status": "interrupted",
                                                     **({"partial": True} if streamed else {})})

    async def reply_to(self, rt: Runtime, stored: StoredSession, segment: str) -> str:
        """Plain text: echo it, or ask the client what its trigger words call for."""
        demos = {"approve": self.demo_approval, "clarify": self.demo_clarify, "secret": self.demo_secret,
                 "sudo": self.demo_sudo, "window": self.demo_window}
        lowered = segment.lower()
        asks = [demo for word, demo in demos.items() if word in lowered]
        if not asks:
            return f"Echo: {segment}"
        return "\n\n".join([await demo(rt, stored) for demo in asks])

    async def demo_approval(self, rt: Runtime, stored: StoredSession) -> str:
        choice: str | None = None

        async def work() -> tuple[str, bool]:
            nonlocal choice
            choice = await self.await_approval(rt, {
                "command": DEMO_COMMAND, "description": "recursive delete", "pattern_key": "recursive delete",
                "pattern_keys": ["recursive delete"], "tool_name": "terminal"})
            if choice in ("once", "session", "always"):
                return json.dumps({"output": "", "exit_code": 0}), True
            if choice is None:
                return "BLOCKED: the approval prompt was withdrawn because no client could answer it.", False
            return "BLOCKED: User denied this command.", False

        await self.run_tool(rt, stored, "terminal", {"command": DEMO_COMMAND}, DEMO_COMMAND, work)
        if choice in ("once", "session", "always"):
            return f"Approved ({choice}): ran `{DEMO_COMMAND}`."
        if choice is None:
            return f"No client could answer the approval, so `{DEMO_COMMAND}` did not run."
        return f"Denied ({choice}): `{DEMO_COMMAND}` did not run."

    async def demo_clarify(self, rt: Runtime, stored: StoredSession) -> str:
        reply = {"answers": {}, "outcome": "undelivered"}

        async def work() -> tuple[str, bool]:
            nonlocal reply
            reply = await self.send_request(rt, "clarify", {"questions": DEMO_QUESTIONS}, timeout=None,
                                            qids=[q["qid"] for q in DEMO_QUESTIONS]) or reply
            return json.dumps(reply, ensure_ascii=False), True

        await self.run_tool(rt, stored, "clarify", {"questions": DEMO_QUESTIONS}, DEMO_QUESTIONS[0]["question"], work)
        answers = reply.get("answers") or {}
        parts = [f"{q['qid']}: {answers[q['qid']] if answers.get(q['qid']) not in (None, '') else '(skipped)'}"
                 for q in DEMO_QUESTIONS if q["qid"] in answers]
        return f"Clarify {reply.get('outcome')}" + (": " + "; ".join(parts) if parts else ".")

    async def demo_secret(self, rt: Runtime, stored: StoredSession) -> str:
        env_var = "FAKE_HERMES_API_KEY"
        result = await self.send_request(rt, "secret", {"env_var": env_var, "prompt": f"Enter {env_var}"},
                                         timeout=self.ask_timeouts["secret"])
        value = text_value(result)
        return f"Saved {env_var} ({len(value)} characters)." if value else f"{env_var} skipped."

    async def demo_sudo(self, rt: Runtime, stored: StoredSession) -> str:
        password = ""

        async def work() -> tuple[str, bool]:
            nonlocal password
            password = text_value(await self.send_request(rt, "sudo", {"command": DEMO_SUDO_COMMAND},
                                                          timeout=self.ask_timeouts["sudo"]))
            if not password:
                return "sudo password skipped", False
            return json.dumps({"output": "", "exit_code": 0}), True

        await self.run_tool(rt, stored, "terminal", {"command": DEMO_SUDO_COMMAND}, DEMO_SUDO_COMMAND, work)
        if not password:
            return f"No sudo password, so `{DEMO_SUDO_COMMAND}` did not run."
        return f"Got a sudo password ({len(password)} characters) and ran `{DEMO_SUDO_COMMAND}`."

    async def demo_window(self, rt: Runtime, stored: StoredSession) -> str:
        value = text_value(await self.send_request(rt, "window.read", {}, timeout=self.ask_timeouts["window.read"]))
        if value == json.dumps({"success": False, "error": NOT_SHOWN_MESSAGE}):
            return f"window.read declined by every client: {NOT_SHOWN_MESSAGE}"
        return f"window.read: {short(value, 120)}" if value else "window.read got no answer."

    async def run_tool(self, rt: Runtime, stored: StoredSession, name: str, args: dict[str, Any], context: str,
                       work: Callable[[], Awaitable[tuple[str, bool]]]) -> tuple[str, bool]:
        """One tool call: tool.start, the work, tool.complete, and the stored assistant + tool rows."""
        tool_id = "call_" + secrets.token_hex(6)
        await self.emit(rt, "tool.start", {"tool_id": tool_id, "name": name, "context": context[:80], "args": args})
        started = time.monotonic()
        result, ok = await work()
        duration = time.monotonic() - started
        # tools/mcp_tool_handlers.py wraps the MCP text as {"result": …}; tool.complete carries it parsed.
        wrapped = {"result": result} if ok else {"error": result}
        await self.emit(rt, "tool.complete", {"tool_id": tool_id, "name": name, "args": args,
                                              "duration_s": round(duration, 3), "result": wrapped,
                                              "summary": result[:120]})
        self.add_row(stored, "assistant", "", finish_reason="tool_calls", tool_calls=[{
            "id": tool_id, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}])
        self.add_row(stored, "tool", json.dumps(wrapped, ensure_ascii=False), tool_call_id=tool_id, tool_name=name)
        return result, ok

    async def speak(self, rt: Runtime, stored: StoredSession, text: str, call_id: str) -> tuple[str, bool]:
        """One speak tool call: the real MCP call to the voice server."""
        async def work() -> tuple[str, bool]:
            started = time.monotonic()
            result, ok = await self.call_speak(text, call_id)
            log(f"speak result ({time.monotonic() - started:.1f}s, {'ok' if ok else 'error'}): {result}")
            return result, ok

        return await self.run_tool(rt, stored, SPEAK_TOOL, {"text": text, "call_id": call_id}, text, work)

    async def call_speak(self, text: str, call_id: str) -> tuple[str, bool]:
        if not self.voice_url:
            return "No --voice-url given, so the fake cannot reach the voice server.", False
        headers = {"Authorization": f"Bearer {self.voice_token}"} if self.voice_token else {}
        try:
            async with httpx2.AsyncClient(headers=headers, timeout=httpx2.Timeout(self.speak_timeout, connect=5)) as http:
                async with streamable_http_client(f"{self.voice_url}/mcp", http_client=http) as (read, write, *_):
                    async with ClientSession(read, write) as session:
                        await session.initialize()
                        result = await session.call_tool("speak", {"text": text, "call_id": call_id},
                                                         read_timeout_seconds=self.speak_timeout)
        except asyncio.CancelledError:
            raise
        except BaseException as exc:  # noqa: BLE001 - ExceptionGroup from the SDK's task groups included
            task = asyncio.current_task()
            if task is not None and task.cancelling():
                raise asyncio.CancelledError() from exc  # interrupted mid-call; run_turn reports it
            return f"MCP call to the voice server failed: {describe(exc)}", False
        content = getattr(result, "content", None) or []
        text_out = "".join(getattr(part, "text", "") for part in content)
        return text_out, not bool(getattr(result, "isError", False))


class RpcError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _err(rid: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def is_response_frame(obj: Any) -> bool:
    """A client response: an ``id`` and a ``result``/``error`` member but no ``method``."""
    return isinstance(obj, dict) and "method" not in obj and "id" in obj and ("result" in obj or "error" in obj)


def approval_payload(data: dict[str, Any]) -> dict[str, Any]:
    """The ``approval`` request params / ``pending_approval`` (server.py _approval_request_payload)."""
    payload = dict(data)
    if "choices" not in payload:
        choices = ["once"]
        if not payload.get("smart_denied") and payload.get("allow_session") is not False:
            choices.append("session")
            if payload.get("allow_permanent") is not False:
                choices.append("always")
        payload["choices"] = choices + ["deny"]
    return payload


def text_value(result: dict[str, Any] | None) -> str:
    """The one-string answer of a sudo/secret/GUI-read request (server.py _ask): '' when skipped."""
    value = (result or {}).get("value", "")
    return value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)


def load_param_keys(path: Path) -> dict[str, frozenset[str] | None]:
    """Allowed top-level param keys per method from the OpenRPC contract (None: any key is accepted)."""
    if not path.is_file():
        log(f"no gateway contract at {path}: params are not checked")
        return {}
    doc = json.loads(path.read_text())
    schemas = doc.get("components", {}).get("schemas", {})
    rules: dict[str, frozenset[str] | None] = {}
    for method in doc.get("methods", []):
        schema = (method.get("params") or [{}])[0].get("schema", {})
        while "$ref" in schema:
            schema = schemas.get(schema["$ref"].rsplit("/", 1)[-1], {})
        closed = schema.get("additionalProperties") is False
        rules[method["name"]] = frozenset(schema.get("properties", {})) if closed else None
    log(f"params checked against {path.name} ({len(rules)} methods)")
    return rules


def describe(exc: BaseException) -> str:
    if isinstance(exc, BaseExceptionGroup) and exc.exceptions:
        return describe(exc.exceptions[0])
    return f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__


def usage(output: int) -> dict[str, Any]:
    return {"model": "fake-hermes", "input": 0, "output": output, "total": output, "calls": 1}


def segments(text: str) -> list[str]:
    """A merged queue slot is prompts joined by blank lines; split it back where a new [Voice…] prompt begins."""
    parts: list[str] = []
    for block in text.split("\n\n"):
        if parts and not block.lstrip().startswith(MARKERS):
            parts[-1] += "\n\n" + block
        else:
            parts.append(block.strip())
    return [p for p in parts if p]


def chunks(text: str, count: int) -> list[str]:
    if not text:
        return []
    size = max(1, -(-len(text) // count))
    return [text[i:i + size] for i in range(0, len(text), size)]


def title_for(text: str) -> str:
    if text.startswith("[Voice call started]"):
        return "Voice call"
    first = text.strip().splitlines()[0] if text.strip() else "Untitled"
    return first[:40]


def gateway_messages(stored: StoredSession | None) -> list[dict[str, Any]]:
    """session.resume ``messages`` (tui_gateway/session_history.py _history_to_messages): {role, text} rows."""
    out: list[dict[str, Any]] = []
    for row in stored.messages if stored else []:
        if row["role"] in ("user", "assistant") and row.get("content"):
            out.append({"role": row["role"], "text": row["content"]})
        for call in row.get("tool_calls") or []:
            fn = call.get("function") or {}
            args = json.loads(fn.get("arguments") or "{}")
            context = args.get("text") or args.get("command") or ""
            out.append({"role": "tool", "name": fn.get("name"), "context": str(context)[:80]})
    return out


def build_app(fake: FakeHermes) -> Starlette:
    return Starlette(routes=[
        Route("/auth/password-login", fake.password_login, methods=["POST"]),
        Route("/auth/logout", fake.logout, methods=["POST"]),
        Route("/login", fake.login_page, methods=["GET"]),
        Route("/api/auth/ws-ticket", fake.ws_ticket, methods=["POST"]),
        Route("/api/profiles/sessions", fake.list_sessions, methods=["GET"]),
        Route("/api/sessions/{session_id}/messages", fake.session_messages, methods=["GET"]),
        WebSocketRoute("/api/ws", fake.gateway_ws),
    ])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Fake Hermes dashboard for HermesVoice end-to-end tests.")
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default 127.0.0.1; the Simulator reaches it)")
    parser.add_argument("--port", type=int, default=9311)
    parser.add_argument("--voice-url", default="http://127.0.0.1:8765", help="Hermes Voice MCP server base URL")
    parser.add_argument("--voice-token", default=None, help="bearer token for the voice server (or HERMES_VOICE_TOKEN)")
    parser.add_argument("--username", default="test")
    parser.add_argument("--password", default="test")
    parser.add_argument("--speak-timeout", type=float, default=300.0, help="seconds to wait for one speak call")
    parser.add_argument("--reap-grace", type=float, default=REAP_GRACE,
                        help="seconds a session without a client is kept before it is reaped (0 = never)")
    parser.add_argument("--replay-max", type=int, default=REPLAY_BUFFER_MAX, help="replay ring size per session")
    parser.add_argument("--contract", default=str(DEFAULT_CONTRACT),
                        help="OpenRPC contract whose param schemas reject unknown keys ('' = no check)")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    fake = FakeHermes(args)
    log(f"fake Hermes dashboard on http://{args.host}:{args.port} (sign in {args.username!r}); "
        f"voice server {fake.voice_url} ({'token set' if fake.voice_token else 'NO TOKEN'}); "
        f"reap grace {fake.reap_grace:g}s")
    uvicorn.run(build_app(fake), host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
