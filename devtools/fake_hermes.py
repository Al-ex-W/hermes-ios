#!/usr/bin/env python3
"""Fake Hermes dashboard for end-to-end tests of the HermesVoice app (Simulator or device).

It speaks exactly the slice of the Hermes web dashboard the app uses, with the shapes taken from the Hermes
source (hermes_cli/dashboard_auth/routes.py, web_routers/profiles.py + sessions.py, tui_gateway/ws.py,
methods_session.py, methods_prompt.py, session_auto_continue.py, contracts/events.py):

  POST /auth/password-login       {provider, username, password} -> {ok, next} + HttpOnly cookie hermes_session_at
  POST /auth/logout               clears the cookies, 302 -> /login
  POST /api/auth/ws-ticket        -> {ticket, ttl_seconds} (single use, 30 s)
  GET  /api/profiles/sessions     -> {sessions: [...], total, profile_totals, limit, offset, errors, storage}
  GET  /api/sessions/{id}/messages -> {session_id, profile, messages: [...], pagination}
  WS   /api/ws?ticket=…           JSON-RPC 2.0; gateway.ready first; events {type, session_id: <runtime id>, payload}

Unauthenticated /api/* calls get Hermes' 401 JSON envelope. Everything lives in memory.

The "agent" is scripted. Per prompt it streams a short turn (~0.3 s):
  "[Voice call started] call_id: <32 hex>"  -> tool mcp__hermes_voice__speak("Hi, I am fake Hermes. I can hear you.")
                                               over MCP (streamable HTTP + bearer token), then "Call connected (text only)."
  "[Voice] <text>"                          -> speak("You said: <text>"), then the same as text
  "[Voice call ended] ..."                  -> "Call ended." (no speak)
  anything else                             -> "Echo: <text>"
Prompts queued while a turn runs merge into one slot (Hermes' text-only queue merge) and run after it.

Run (from hermes-voice-mcp, to reuse its venv):
  uv run python ../devtools/fake_hermes.py --port 9311 --voice-url http://127.0.0.1:8765 --voice-token <token>
Sign in as test / test. Every RPC, event and speak result is logged to stdout with the prefix FAKE.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import secrets
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any
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


def log(*parts: Any) -> None:
    print("FAKE", time.strftime("%H:%M:%S"), *parts, flush=True)


def short(value: Any, limit: int = 160) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    text = text.replace("\n", "\\n")
    return text if len(text) <= limit else text[: limit - 1] + "…"


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
    loop_task: asyncio.Task | None = None
    turn_task: asyncio.Task | None = None


class Conn:
    """One /api/ws connection. Sends are serialized so frames never interleave."""

    def __init__(self, ws: WebSocket, peer: str) -> None:
        self.ws = ws
        self.peer = peer
        self.lock = asyncio.Lock()
        self.closed = False

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
        self.access_tokens: dict[str, float] = {}
        self.tickets: dict[str, float] = {}
        self.sessions: dict[str, StoredSession] = {}
        self.runtimes: dict[str, Runtime] = {}
        self.idempotency: dict[str, str] = {}
        self.next_row_id = 1
        self.replay_epoch = uuid.uuid4().hex
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
        await conn.send({"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {
            "skin": {}, "change_events": True, "heartbeat": True, "replay_epoch": self.replay_epoch}}})
        reason = "?"
        try:
            while True:
                raw = await ws.receive_text()
                try:
                    req = json.loads(raw)
                except json.JSONDecodeError:
                    await conn.send({"jsonrpc": "2.0", "error": {"code": -32700, "message": "parse error"}, "id": None})
                    continue
                if not isinstance(req, dict):
                    continue
                method, rid, params = req.get("method"), req.get("id"), req.get("params") or {}
                if method == "gateway.ping":
                    # Answered on the read loop (ws.py), never queued behind a handler. Not logged: every 15 s.
                    await conn.send({"jsonrpc": "2.0", "result": {"ok": True}, "id": rid})
                    continue
                log(f"rpc <- {method} id={rid} params={short(params)}")
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
            # Detach only: the session keeps running (and its turn too); events go nowhere until a resume.
            for rt in self.runtimes.values():
                rt.transports.discard(conn)
            log(f"ws /api/ws closed peer={peer} reason={reason}")

    async def dispatch(self, conn: Conn, rid: Any, method: Any, params: dict[str, Any]) -> dict[str, Any]:
        handler = {
            "ping": lambda: {"pong": True},
            "client.capabilities": lambda: {"server_requests": [], "declines_not_shown": True},
            "session.create": lambda: self.session_create(conn, params),
            "session.resume": lambda: self.session_resume(conn, params),
            "prompt.submit": lambda: self.prompt_submit(conn, params),
            "session.interrupt": lambda: self.session_interrupt(params),
        }.get(method)
        if handler is None:
            return _err(rid, -32601, f"unknown method: {method} — the client and the Hermes backend are out of sync")
        try:
            result = handler()
        except RpcError as exc:
            return _err(rid, exc.code, exc.message)
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    def session_create(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        idem = params.get("idempotency_key")
        if idem and (sid := self.idempotency.get(idem)) and (rt := self.runtimes.get(sid)):
            rt.transports.add(conn)
            return {"session_id": rt.sid, "stored_session_id": rt.key, "message_count": 0, "messages": [],
                    "info": self.info(rt)}
        stored = StoredSession(key=self.new_key(), source=str(params.get("source") or "desktop"),
                               title=params.get("title") or None)
        self.sessions[stored.key] = stored
        rt = Runtime(sid=uuid.uuid4().hex[:8], key=stored.key)
        rt.transports.add(conn)
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
            # Fast path: reattach this client to the live session (server.py _live_session_payload).
            rt.transports.add(conn)
            payload: dict[str, Any] = {
                "info": self.info(rt), "message_count": len(stored.messages) if stored else 0,
                "messages": [] if omit else gateway_messages(stored), "messages_omitted": omit,
                "running": rt.running, "turn_started_at": rt.turn_started_at, "session_id": rt.sid,
                "session_key": rt.key, "stored_session_id": rt.key, "started_at": rt.created_at,
                "status": "streaming" if rt.running else "idle", "resumed": key,
            }
            if rt.inflight:
                payload["inflight"] = dict(rt.inflight)
            if rt.queued:
                payload["queued"] = {"user": rt.queued}
            return payload
        if stored is None or not stored.persisted:
            raise RpcError(4007, "session not found")
        rt = Runtime(sid=uuid.uuid4().hex[:8], key=key)
        rt.transports.add(conn)
        self.runtimes[rt.sid] = rt
        # Cold resume (methods_session.py _resume_response).
        return {"session_id": rt.sid, "resumed": key, "message_count": len(stored.messages),
                "messages": [] if omit else gateway_messages(stored), "messages_omitted": omit,
                "info": self.info(rt), "inflight": None, "running": False, "session_key": key,
                "stored_session_id": key, "started_at": stored.started_at, "status": "idle"}

    def prompt_submit(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        rt = self.runtimes.get(params.get("session_id") or "")
        if rt is None:
            raise RpcError(4001, "session not found")
        text = params.get("text")
        if not isinstance(text, str) or not text.strip():
            raise RpcError(4002, "text required")
        rt.transports.add(conn)  # prompt.submit rebinds the session to the submitting transport
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

    def session_interrupt(self, params: dict[str, Any]) -> dict[str, Any]:
        rt = self.runtimes.get(params.get("session_id") or "")
        if rt is None:
            raise RpcError(4001, "session not found")
        # session_lifecycle.py _interrupt_session_turn: Stop also drops the queue.
        if rt.queued_row is not None:
            stored = self.sessions[rt.key]
            if rt.queued_row in stored.messages:
                stored.messages.remove(rt.queued_row)
        rt.queued, rt.queued_row = None, None
        if rt.turn_task is not None and not rt.turn_task.done():
            rt.turn_task.cancel()
        return {"status": "interrupted"}

    # ── the scripted agent ────────────────────────────────────────────────────────────────────────

    async def emit(self, rt: Runtime, kind: str, payload: dict[str, Any] | None = None) -> None:
        params: dict[str, Any] = {"type": kind, "session_id": rt.sid}
        if payload is not None:
            params["payload"] = payload
        frame = {"jsonrpc": "2.0", "method": "event", "params": params}
        targets = [c for c in rt.transports if not c.closed]
        detail = "" if payload is None else " " + short(payload, 120)
        log(f"event {kind} sid={rt.sid}{detail}" + ("" if targets else " (no client attached: dropped)"))
        for conn in targets:
            if not await conn.send(frame):
                rt.transports.discard(conn)

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
                    replies.append(f"Echo: {segment}")
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

    async def speak(self, rt: Runtime, stored: StoredSession, text: str, call_id: str) -> tuple[str, bool]:
        """One speak tool call: tool.start, the real MCP call to the voice server, tool.complete, stored rows."""
        tool_id = "call_" + secrets.token_hex(6)
        args = {"text": text, "call_id": call_id}
        await self.emit(rt, "tool.start", {"tool_id": tool_id, "name": SPEAK_TOOL, "context": text[:80], "args": args})
        started = time.monotonic()
        result, ok = await self.call_speak(text, call_id)
        duration = time.monotonic() - started
        log(f"speak result ({duration:.1f}s, {'ok' if ok else 'error'}): {result}")
        # tools/mcp_tool_handlers.py wraps the MCP text as {"result": …}; tool.complete carries it parsed.
        wrapped = {"result": result} if ok else {"error": result}
        await self.emit(rt, "tool.complete", {"tool_id": tool_id, "name": SPEAK_TOOL, "args": args,
                                              "duration_s": round(duration, 3), "result": wrapped,
                                              "summary": result[:120]})
        self.add_row(stored, "assistant", "", finish_reason="tool_calls", tool_calls=[{
            "id": tool_id, "type": "function", "function": {"name": SPEAK_TOOL, "arguments": json.dumps(args)}}])
        self.add_row(stored, "tool", json.dumps(wrapped, ensure_ascii=False), tool_call_id=tool_id,
                     tool_name=SPEAK_TOOL)
        return result, ok

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
            out.append({"role": "tool", "name": fn.get("name"), "context": str(args.get("text", ""))[:80]})
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


def main() -> None:
    parser = argparse.ArgumentParser(description="Fake Hermes dashboard for HermesVoice end-to-end tests.")
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default 127.0.0.1; the Simulator reaches it)")
    parser.add_argument("--port", type=int, default=9311)
    parser.add_argument("--voice-url", default="http://127.0.0.1:8765", help="Hermes Voice MCP server base URL")
    parser.add_argument("--voice-token", default=None, help="bearer token for the voice server (or HERMES_VOICE_TOKEN)")
    parser.add_argument("--username", default="test")
    parser.add_argument("--password", default="test")
    parser.add_argument("--speak-timeout", type=float, default=300.0, help="seconds to wait for one speak call")
    args = parser.parse_args()
    fake = FakeHermes(args)
    log(f"fake Hermes dashboard on http://{args.host}:{args.port} (sign in {args.username!r}); "
        f"voice server {fake.voice_url} ({'token set' if fake.voice_token else 'NO TOKEN'})")
    uvicorn.run(build_app(fake), host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
