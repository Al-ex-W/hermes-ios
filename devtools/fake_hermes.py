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

Chat screens (M2). More trigger words, combinable in one prompt, each turn ending with session.usage:
  think     thinking.delta + reasoning.delta, then the text; message.complete carries ``reasoning``
  tools     tool.generating/start/complete for search_files, terminal (output + exit code), patch and write_file
            (diffs, a changed-files summary) and a background terminal that shows up in process.list
  todo      two todo_list calls, each followed by todo.updated
  delegate  delegate_task with subagent.spawn_requested/start/thinking/tool/progress/complete
  image     a MEDIA: line pointing at an image GET /api/media serves (the last attached one, if any)
  fail      message.complete {status: "error", error, error_surface {layer, code, retryable}}
RPCs: commands.catalog, complete.slash/path, slash.exec, command.dispatch, model.options, config.set,
image.attach_bytes, file.attach, process.list/kill/stop, subagent.list, session.usage, session.context_breakdown,
session.workspace.move, session.branch, projects.list. REST: GET /api/profiles, /api/profiles/sessions/sidebar,
/api/sessions/search, /api/media; PATCH and DELETE /api/sessions/{id}. ``--seed demo`` (the default) adds chats
across two projects, two profiles and several days (one pinned, one archived, one unread, a cron and a Telegram
one); ``--seed minimal`` keeps only the welcome chat.

Settings screens (M3), from hermes_cli/web_routers/{config_env,models,memory_providers,oauth,profiles,status}.py
and tui_gateway/{methods_vault,methods_session}.py. Every route honours ``?profile=`` (each profile has its own
config.yaml, .env, SOUL.md, logins and vault; unknown -> 404, invalid name -> 400):
  GET  /api/config/schema         {fields: {dot.path: {type, description, category, options?}}, category_order},
                                  built from a slice of DEFAULT_CONFIG like _build_schema_from_config
  GET  /api/config                load_config() with the model flattened (+ model_context_length); include_defaults
  PUT  /api/config {config}       deep-merged over the file like the server; the fake also refuses a value whose
                                  type does not match its schema field (400), which the real server would save
  GET  /api/model/info|options|auxiliary|moa|recommended-default, POST /api/model/set, PUT /api/model/moa
  GET  /api/memory, GET/PUT /api/memory/providers/<name>/config?surface=declared (a declared "fake-recall")
  GET/PUT/DELETE /api/env, POST /api/env/reveal, POST /api/providers/validate (the fake never calls a provider:
                                  a key starting "bad" is rejected, one containing "offline" can't be checked)
  GET  /api/providers/oauth, POST .../{id}/start (device code, approved after --oauth-approve-after seconds),
       GET .../{id}/poll/{session}, DELETE .../{id}, DELETE .../sessions/{session}
  /api/profiles (+ POST create, PATCH rename, DELETE, /active, /{name}/soul, /{name}/export, /import, ...)
  GET  /api/status                the public liveness probe: versions and gateway state
RPCs vault.* (a local vault plus a fake 1Password; unlock with any master password but "wrong") and billing.*
(a Nous Portal account; money routes need billing.step_up first). Values typed into these routes (API keys,
passwords, vault secrets) are never logged.
The fake hermes_voice plugin's POST /devices also takes ``alert_token`` + ``alerts`` {approval, clarify, turn_done}
(listed by GET /status), and GET /api/plugins/hermes_voice/debug/alerts?session_id=… returns the alert pushes
the plugin would send ({aps, hermes}: approval or clarify waiting, turn done) and the alert tokens they go to.

Run (from hermes-voice-mcp, to reuse its venv):
  uv run python ../devtools/fake_hermes.py --port 9311 --voice-url http://127.0.0.1:8765 --voice-token <token>
Sign in as test / test. Every RPC, event, server request and speak result is logged to stdout with the prefix FAKE.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import copy
import inspect
import json
import os
import posixpath
import re
import secrets
import struct
import time
import uuid
import zlib
from collections import OrderedDict, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
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
from starlette.routing import BaseRoute, Route, WebSocketRoute
from starlette.websockets import WebSocket, WebSocketDisconnect

# The fake hermes_voice plugin: /api/plugins/hermes_voice/*, start_call.
from fake_voice_plugin import PREFIX as PLUGIN_PREFIX, FakeVoicePlugin

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
    # Sidebar flags and workspace (sessions columns), the runtime the chat runs on, and its usage counters.
    profile: str = "default"
    archived: bool = False
    pinned: bool = False
    hidden: bool = False
    unread: bool = False
    cwd: str = ""
    git_branch: str | None = None
    git_repo_root: str | None = None
    parent_session_id: str | None = None
    branched_from: str | None = None
    model: str = "fake-hermes"
    provider: str = "fake"
    reasoning_effort: str = "medium"
    fast: bool = False
    usage: dict[str, int] = field(default_factory=lambda: {"input": 0, "output": 0, "reasoning": 0, "calls": 0})
    tool_call_count: int = 0
    todo_state: dict[str, Any] | None = None

    def row(self) -> dict[str, Any]:
        visible = [m for m in self.messages if m["role"] in ("user", "assistant")]
        first_user = next((m["content"] for m in self.messages if m["role"] == "user"), "") or ""
        now = time.time()
        row = {
            "id": self.key, "source": self.source, "title": self.title, "preview": first_user[:60],
            "started_at": self.started_at, "last_active": self.last_active, "ended_at": None,
            "message_count": len(visible), "profile": self.profile, "is_default_profile": self.profile == "default",
            "is_active": now - self.last_active < 300, "archived": self.archived, "pinned": self.pinned,
            "hidden": self.hidden, "unread": self.unread, "cwd": self.cwd or None, "git_branch": self.git_branch,
            "git_repo_root": self.git_repo_root, "model": self.model, "input_tokens": self.usage["input"],
            "output_tokens": self.usage["output"], "tool_call_count": self.tool_call_count,
            "parent_session_id": self.parent_session_id,
        }
        if self.branched_from:
            row["_branched_from"] = self.branched_from
        return row


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
    # M2: images staged for the next prompt (image.attach_bytes), the ones the running turn took, what the
    # demos noted for the turn's close, a failed turn kept as ``inflight`` until the next one, and a model
    # switch deferred while a turn runs.
    attached_images: list[str] = field(default_factory=list)
    image_counter: int = 0
    turn_images: list[str] = field(default_factory=list)
    notes: TurnNotes | None = None
    failed_turn: dict[str, Any] | None = None
    pending_model: tuple[str, str] | None = None


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


# ── M2: chat (sidebar, transcript, composer) ──────────────────────────────────────────────────────
# Shapes from hermes_cli/web_routers/{profiles,sessions,files}.py, tui_gateway/{methods_tools,methods_complete,
# methods_prompt,prompt_attachments,methods_config_set,methods_session,methods_subagents,methods_projects,
# tool_progress,session_auto_continue,user_messages}.py, tools/{todo_tool,delegate_tool_progress,process_registry,
# file_operations_common}.py and agent/{display,error_surface,context_breakdown,turn_failure_copy}.py.

HOUR, DAY = 3600, 86400
DEMO_HOME = "/home/demo"
DEMO_HERMES_HOME = f"{DEMO_HOME}/.hermes"
DEMO_IMAGES = f"{DEMO_HERMES_HOME}/images"
DEMO_ATTACHMENTS = f"{DEMO_HERMES_HOME}/attachments"
DEMO_IMAGE = f"{DEMO_IMAGES}/fake-hermes-demo.png"
TOOL_SECONDS = 0.04
# Long enough for a client to call subagent.list between subagent.start and subagent.complete.
SUBAGENT_SECONDS = 0.15
ATTACH_MAX_BYTES = 25 * 1024 * 1024
# hermes_cli/cli_terminal_input.py _IMAGE_EXTENSIONS (no HEIC: a phone must convert first).
IMAGE_EXTENSIONS = frozenset({".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tiff", ".tif", ".svg", ".ico"})
IMAGE_MAGIC = ((b"\x89PNG\r\n\x1a\n", ".png"), (b"\xff\xd8\xff", ".jpg"), (b"GIF87a", ".gif"), (b"GIF89a", ".gif"),
               (b"BM", ".bmp"))
MEDIA_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
               ".webp": "image/webp", ".bmp": "image/bmp"}
REF_NEEDS_QUOTING = re.compile(r"""[\s()\[\]{}<>"'`]""")
FILE_REF = re.compile(r"""@file:(`[^`]+`|"[^"]+"|'[^']+'|\S+)""")
DATA_URL = re.compile(r"^data:[^;,]*(?:;[^;,=]+=[^;,]+)*;base64,(.*)$", re.DOTALL | re.IGNORECASE)
NUMBERED_TITLE = re.compile(r"^(.*?) #(\d+)$")
MAX_TITLE_LENGTH = 100

DEMO_PROFILES = (
    {"name": "default", "path": DEMO_HERMES_HOME, "is_default": True, "skill_count": 12, "description": ""},
    {"name": "research", "path": f"{DEMO_HERMES_HOME}/profiles/research", "is_default": False, "skill_count": 4,
     "description": "Reads papers and writes short summaries"},
)
# (id, slug, name, color, git branch); each project's folder is DEMO_HOME/projects/<slug>.
DEMO_PROJECTS = (
    ("p_a7a5c0de", "atlas", "Atlas", "#0053fd", "main"),
    ("p_be4c0a11", "beacon", "Beacon", "#c2410c", "release/1.4"),
)

AUTH_PY = ('import time\n\nTOKEN_TTL = 900\n\n\ndef issue_token(user, now=None):\n    now = now or time.time()\n'
           '    return {"sub": user.id, "exp": now + TOKEN_TTL}\n')
AUTH_DIFF = ("--- a/src/atlas/auth.py\n+++ b/src/atlas/auth.py\n@@ -5,4 +5,5 @@ TOKEN_TTL = 900\n \n"
             " def issue_token(user, now=None):\n-    now = now or time.time()\n+    if now is None:\n"
             "+        now = time.time()\n     return {\"sub\": user.id, \"exp\": now + TOKEN_TTL}\n")
CHANGELOG_MD = "# Changelog\n\n## 0.3.0\n- Token refresh.\n"
CHANGELOG_NEW = "# Changelog\n\n## Unreleased\n- Fix tokens issued with `now=0`.\n\n## 0.3.0\n- Token refresh.\n"
CHANGELOG_DIFF = ("--- a/CHANGELOG.md\n+++ b/CHANGELOG.md\n@@ -1,4 +1,7 @@\n # Changelog\n \n+## Unreleased\n"
                  "+- Fix tokens issued with `now=0`.\n+\n ## 0.3.0\n - Token refresh.\n")
PYTEST_FAILED = ("F...                                                                     [100%]\n"
                 "=================================== FAILURES ===================================\n"
                 "___________________________ test_token_at_epoch_zero ___________________________\n"
                 "    def test_token_at_epoch_zero():\n"
                 ">       assert issue_token(User(id=1), now=0)[\"exp\"] == TOKEN_TTL\n"
                 "E       AssertionError: assert 1793001234.5 == 900\n"
                 "tests/test_auth.py:14: AssertionError\n1 failed, 3 passed in 0.12s")
PYTEST_PASSED = "....                                                                     [100%]\n4 passed in 0.11s"
SEARCH_RESULT = {"total_count": 2, "matches": [
    {"path": "src/atlas/auth.py", "line": 6, "content": "def issue_token(user, now=None):"},
    {"path": "tests/test_auth.py", "line": 3, "content": "from atlas.auth import TOKEN_TTL, issue_token"}]}
DEMO_FILES = {
    "notes.md": "# Notes\n\n- Try the new release flow.\n- Clean up old branches.\n- Read the storage RFC.\n",
    "projects/atlas/AGENTS.md": "# Atlas\n\nRun `pytest -q` before you commit. Keep functions small.\n",
    "projects/atlas/README.md": "# Atlas\n\nA tiny token service.\n",
    "projects/atlas/CHANGELOG.md": CHANGELOG_MD,
    "projects/atlas/pyproject.toml": '[project]\nname = "atlas"\nversion = "0.3.0"\n',
    "projects/atlas/src/atlas/__init__.py": "",
    "projects/atlas/src/atlas/auth.py": AUTH_PY,
    "projects/atlas/src/atlas/storage.py": "def load_user(uid):\n    ...\n\n\ndef save_user(user):\n    ...\n",
    "projects/atlas/tests/test_auth.py": ("from atlas.auth import TOKEN_TTL, issue_token\n\n\n"
                                         "def test_token_at_epoch_zero():\n    ...\n"),
    "projects/atlas/tests/test_storage.py": "def test_round_trip():\n    ...\n",
    "projects/beacon/README.md": "# Beacon\n\nA small status server.\n",
    "projects/beacon/package.json": '{\n  "name": "beacon",\n  "version": "1.4.0"\n}\n',
    "projects/beacon/docs/release-notes.md": "# Release notes\n",
    "projects/beacon/src/index.ts": "export { serve } from './server'\n",
    "projects/beacon/src/server.ts": "export function serve(port = 8080) {}\n",
}

# agent/context_breakdown.py _CATEGORIES: (id, color, label, fixed fake size; rules and conversation are measured).
CONTEXT_CATEGORIES = (
    ("system_prompt", "var(--context-usage-system)", "System prompt", 3200),
    ("tool_definitions", "var(--context-usage-tools)", "Tool definitions", 9800),
    ("rules", "var(--context-usage-rules)", "Rules", 0),
    ("skills", "var(--context-usage-skills)", "Skills", 1400),
    ("memory", "var(--context-usage-memory)", "Memory", 600),
    ("conversation", "var(--context-usage-conversation)", "Conversation", 0),
)
CONTEXT_MAX = 200_000

# (slug, name, {model: (fast, reasoning, input price, output price)}).
DEMO_PROVIDERS = (
    ("fake", "Fake", {"fake-hermes": (True, True, "$1.00", "$4.00"), "fake-hermes-mini": (False, False, "free", "free"),
                      "fake-hermes-max": (True, True, "$15.00", "$75.00")}),
    ("echo-cloud", "Echo Cloud", {"echo-1": (False, True, "$0.50", "$1.50"),
                                  "echo-2-pro": (True, True, "$3.00", "$12.00")}),
)
EXPENSIVE_MODELS = {"fake-hermes-max"}
REASONING_LEVELS = ("none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra")
# methods_config_set.py _REASONING_DISPLAY_WORDS and _FAST_WORDS.
REASONING_DISPLAY = {"show": "show", "on": "show", "hide": "hide", "off": "hide", "full": "full", "all": "full",
                     "clamp": "clamp", "collapse": "clamp", "short": "clamp"}
FAST_WORDS = {"fast": "fast", "on": "fast", "normal": "normal", "off": "normal", "auto": "auto", "cold": "cold",
              "ultrafast": "ultrafast"}

# hermes_cli/commands.py COMMAND_REGISTRY, a slice: (name, description, category, args_hint, aliases, subcommands,
# desktop, argument_mode).
SLASH_COMMANDS = (
    ("new", "Start a new session (fresh session ID + history)", "Session", "[name]", ("reset",), (), None, None),
    ("retry", "Retry the last message (resend to agent)", "Session", "", (), (), None, None),
    ("undo", "Back up N user turns and re-prompt (default 1)", "Session", "[N]", (), (), None, None),
    ("title", "Set a title for the current session", "Session", "[name]", (), (), None, None),
    ("branch", "Branch the current session (new thread on Discord/Telegram/Slack/Matrix; --here stays here)",
     "Session", "[--here] [name]", ("fork",), (), None, None),
    ("compress", "Compress conversation context (add 'here [N]' to keep recent N turns; --preview shows what "
     "would happen)", "Session", "[here [N] | focus topic | --preview|--dry-run]", ("compact",), (), None, None),
    ("queue", "Queue a prompt for the next turn, or list/edit/rm/move/clear queued prompts", "Session",
     "[<prompt>|list|edit N <prompt>|rm N|move A B|clear]", ("q",), ("list", "edit", "rm", "move", "clear", "add"),
     None, None),
    ("stop", "Kill all running background processes", "Session", "", (), (), None, None),
    ("status", "Show session, model, token, and context info", "Session", "", (), (), None, None),
    ("model", "Switch model (session-scoped; --global to persist)", "Configuration",
     "[model] [--provider name] [--reasoning level] [--global|--session] [--refresh]", (), (), "hidden", None),
    ("personality", "Set a predefined personality", "Configuration", "[name]", (), (), None, "options"),
    ("reasoning", "Manage reasoning effort and display", "Configuration", "[level|show|hide|full|clamp] [--global]",
     (), (*REASONING_LEVELS, "show", "hide", "on", "off", "full", "clamp", "--global"), None, None),
    ("fast", "Fast mode — OpenAI Priority Processing / Anthropic Fast Mode (normal/fast/auto/cold)",
     "Configuration", "[normal|fast|auto|cold|status] [--global]",
     (), ("normal", "fast", "auto", "cold", "status", "on", "off", "--global"), "advanced", None),
    ("help", "Show available commands (/help skills lists skill commands, /help <text> filters)", "Info",
     "[skills|<filter>]", (), (), None, None),
    ("usage", "Show token usage and rate limits; `reset` redeems a banked Codex limit reset", "Info",
     "[reset [--force]]", (), (), None, None),
)
COMMAND_ALIASES = {alias: command[0] for command in SLASH_COMMANDS for alias in command[4]}
PERSONALITIES = {"none": "clear personality overlay", "concise": "Keep responses brief and to the point.",
                 "teacher": "Explain step by step."}
SKILL_COMMANDS = {"/release-notes": ("Draft release notes from the commits since the last tag", 7),
                  "/review-pr": ("Review the current branch like a careful reviewer", 2)}
# config quick_commands: name -> (type, command, canned output).
QUICK_COMMANDS = {"uptime": ("exec", "uptime", "10:24  up 3 days,  2:11, 1 user, load averages: 1.20 1.05 0.98")}
AT_HINTS = (("@diff", "git diff"), ("@staged", "staged diff"), ("@file:", "attach file"),
            ("@folder:", "attach folder"), ("@url:", "fetch url"), ("@git:", "git log"))

DEMO_REASONING = ("The prompt asks me to think first. I will check what is being asked, weigh two readings of it, "
                  "and then answer in one line.")
DEMO_FAILURE = "HTTP 429: rate limit reached for this model, retry after 20s"
FAILED_TURN_NOTICE = "Your request was not processed. Send it again if you still want me to carry it out."
PARTIAL_FAILED_TURN_NOTICE = ("This turn did not complete. Some actions may already have run; verify their effects "
                              "before resending.")
DIFF_ANSI = {"file": "\033[38;2;180;160;255m", "hunk": "\033[38;2;150;150;150m", "minus": "\033[38;2;255;120;120m",
             "plus": "\033[38;2;120;220;120m", "dim": "\033[38;2;140;140;140m"}


@dataclass
class TurnNotes:
    """What the demos of one turn leave for its close."""

    images: list[str] = field(default_factory=list)
    reasoning: str = ""
    error: tuple[str, dict[str, Any]] | None = None
    tools_ran: bool = False
    calls: int = 0


def project_path(slug: str) -> str:
    return f"{DEMO_HOME}/projects/{slug}"


def demo_dirs() -> set[str]:
    dirs = {DEMO_HOME, DEMO_HERMES_HOME, DEMO_IMAGES, DEMO_ATTACHMENTS}
    for rel in DEMO_FILES:
        parent = posixpath.dirname(f"{DEMO_HOME}/{rel}")
        while parent.startswith(DEMO_HOME):
            dirs.add(parent)
            parent = posixpath.dirname(parent)
    return dirs


def git_info(cwd: str) -> tuple[str | None, str | None]:
    """(branch, repo root) of a fake workspace: only the project folders are repositories."""
    for _pid, slug, _name, _color, branch in DEMO_PROJECTS:
        root = project_path(slug)
        if cwd == root or cwd.startswith(root + "/"):
            return branch, root
    return None, None


def project_ref(cwd: str) -> dict[str, Any] | None:
    for pid, slug, name, _color, _branch in DEMO_PROJECTS:
        root = project_path(slug)
        if cwd and (cwd == root or cwd.startswith(root + "/")):
            return {"id": pid, "slug": slug, "name": name, "primary_path": root}
    return None


def tool_context(name: str, args: dict[str, Any]) -> str:
    """The 80-char argument preview of a tool row (agent/display.py build_tool_preview)."""
    if name == "todo_list":
        todos = args.get("todos")
        if todos is None:
            return "reading task list"
        return f"{'updating' if args.get('merge') else 'planning'} {len(todos)} task(s)"
    key = {"terminal": "command", "read_file": "path", "write_file": "path", "patch": "path",
           "search_files": "pattern", "delegate_task": "goal"}.get(name)
    key = key or next((k for k in ("query", "text", "command", "path", "name", "prompt", "code", "goal") if k in args),
                      None)
    value = args.get(key) if key else None
    return " ".join(str(value).split())[:80] if value else ""


def tool_rows(tool_id: str, name: str, args: dict[str, Any], result: Any,
              metadata: dict[str, Any] | None = None) -> list[tuple[str, str, dict[str, Any]]]:
    """The stored assistant tool call + tool result rows of one call (metadata is the display sidecar)."""
    call = {"id": tool_id, "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}
    tool_extra: dict[str, Any] = {"tool_call_id": tool_id, "tool_name": name}
    if metadata:
        tool_extra["display_metadata"] = {"tool_result_metadata": metadata}
    return [("assistant", "", {"tool_calls": [call], "finish_reason": "tool_calls"}),
            ("tool", json.dumps(result, ensure_ascii=False), tool_extra)]


def inline_diff(diff: str) -> str:
    """tool.complete ``inline_diff``: the CLI rendering (review header, ``a/x → b/x``, colored hunks)."""
    lines, from_file = ["  ┊ review diff"], None
    for raw in diff.splitlines():
        if raw.startswith("--- "):
            from_file = raw[4:].strip()
            continue
        if raw.startswith("+++ "):
            lines.append(f"{DIFF_ANSI['file']}{from_file or 'a/?'} → {raw[4:].strip()}\033[0m")
            continue
        color = next((c for p, c in (("@@", "hunk"), ("-", "minus"), ("+", "plus"), (" ", "dim")) if raw.startswith(p)),
                     None)
        lines.append(f"{DIFF_ANSI[color]}{raw}\033[0m" if color else raw)
    return "\n".join(lines)


def diff_stats(diff: str) -> tuple[int, int]:
    body = [line for line in diff.splitlines() if not line.startswith(("--- ", "+++ "))]
    return sum(line.startswith("+") for line in body), sum(line.startswith("-") for line in body)


def demo_png(width: int = 64, height: int = 40, rgb: tuple[int, int, int] = (0x00, 0x53, 0xFD)) -> bytes:
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def image_meta(name: str, data: bytes) -> dict[str, Any]:
    """server.py _image_meta: name, plus size and a 512px-tile token estimate when the header is readable."""
    meta: dict[str, Any] = {"name": name}
    size = None
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        size = struct.unpack(">II", data[16:24])
    elif data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        size = struct.unpack("<HH", data[6:10])
    if size and size[0] > 0 and size[1] > 0:
        width, height = size
        meta.update(width=width, height=height, token_estimate=((width + 511) // 512) * ((height + 511) // 512) * 85)
    return meta


def decode_base64(raw: str, pattern: re.Pattern[str] | None = None) -> bytes | None:
    """Strip an optional ``data:…;base64,`` wrapper and whitespace, then decode strictly; None when invalid."""
    cleaned = (raw or "").strip()
    if pattern is not None and (match := pattern.match(cleaned)):
        cleaned = match.group(1)
    try:
        return base64.b64decode(re.sub(r"\s+", "", cleaned), validate=True)
    except (binascii.Error, ValueError):
        return None


def format_ref(value: str) -> str:
    if not value or not REF_NEEDS_QUOTING.search(value):
        return value
    return next((f"{q}{value}{q}" for q in ("`", '"', "'") if q not in value), value)


def sanitize_title(title: str | None) -> str | None:
    cleaned = " ".join(re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]", "",
                              title or "").split())
    if not cleaned:
        return None
    if len(cleaned) > MAX_TITLE_LENGTH:
        raise ValueError(f"Title too long ({len(cleaned)} chars, max {MAX_TITLE_LENGTH})")
    return cleaned


def turn_error_text(error: str, surface: dict[str, Any]) -> str:
    """tui_gateway/user_messages.py turn_error_text for the provider rate-limit failure."""
    provider = f" ({surface['provider']})" if surface.get("provider") else ""
    return (f"The model provider is rate-limiting requests{provider}. Your message was not answered.\n"
            f"Details: {error}\nWait a moment, then /retry.")


def busy_message(command: str) -> str:
    return (f"session busy — Hermes is still replying. Stop the current reply first (Stop button, "
            f"or Ctrl+C in a terminal), then run /{command.lstrip('/')}.")


def csv_list(value: str | None) -> list[str]:
    return [s.strip() for s in (value or "").split(",") if s.strip()]


def pinned_window(rows: list[dict[str, Any]], offset: int, cap: int) -> list[dict[str, Any]]:
    """``rows[offset:offset+cap]`` plus every pinned row past it (profiles.py _pinned_window)."""
    window = rows[offset:offset + cap]
    window.extend(r for r in rows[offset + cap:] if r.get("pinned"))
    return window


def search_snippet(content: str, tokens: list[str]) -> str | None:
    """An FTS5 ``snippet(…, '>>>', '<<<', '...', 40)`` lookalike for ``tok1* tok2*`` (every token must prefix a word);
    None when the content doesn't match."""
    words = content.split()
    stems = [re.sub(r"\W", "", w.lower()) for w in words]
    if not all(any(s.startswith(t) for s in stems) for t in tokens):
        return None
    hits = [i for i, s in enumerate(stems) if any(s.startswith(t) for t in tokens)]
    start = max(0, min(hits[0] - 10, len(words) - 40))
    shown = [f">>>{w}<<<" if i in hits else w for i, w in enumerate(words[start:start + 40], start)]
    return ("..." if start else "") + " ".join(shown) + ("..." if start + 40 < len(words) else "")


class ChatFeatures:
    """M2: the sidebar REST routes, the composer RPCs and the demo turns behind the chat screens. Mixed into
    FakeHermes, whose state (sessions, runtimes, emit, add_row…) it uses."""

    sessions: dict[str, StoredSession]
    runtimes: dict[str, Runtime]
    profiles: dict[str, "FakeProfile"]

    def _init_chat(self, args: argparse.Namespace) -> None:
        self.seed_mode = getattr(args, "seed", "demo")
        self.dirs = demo_dirs()
        self.files: dict[str, bytes] = {f"{DEMO_HOME}/{rel}": text.encode() for rel, text in DEMO_FILES.items()}
        self.media: dict[str, bytes] = {DEMO_IMAGE: demo_png()}
        self.processes: dict[str, dict[str, Any]] = {}
        self.subagents: dict[str, dict[str, dict[str, Any]]] = {}
        now = int(time.time())
        self.projects = [{
            "id": pid, "slug": slug, "name": name, "icon": None, "color": color, "board_slug": None,
            "primary_path": project_path(slug), "archived": False, "created_at": now - 60 * DAY,
            "folders": [{"path": project_path(slug), "label": None, "is_primary": True, "added_at": now - 60 * DAY}],
        } for pid, slug, name, color, _branch in DEMO_PROJECTS]

    # ── seed ──────────────────────────────────────────────────────────────────────────────────────

    def _seed_demo(self) -> None:
        """Chats across two projects, two profiles and several days, for the sidebar's groups and filters."""
        atlas, beacon = project_path("atlas"), project_path("beacon")
        todos = [{"id": "1", "content": "Reproduce the flaky test", "status": "completed"},
                 {"id": "2", "content": "Fix the token clock", "status": "completed"},
                 {"id": "3", "content": "Re-run the suite", "status": "completed"}]
        turns: list[tuple[str, str, dict[str, Any]]] = [
            ("user", "test_token_at_epoch_zero fails now and then. Can you find out why?", {})]
        for name, args, result, metadata in (
                ("todo_list", {"todos": todos[:1] + [dict(t, status="pending") for t in todos[1:]]},
                 {"todos": todos[:1] + [dict(t, status="pending") for t in todos[1:]], "revision": 1}, None),
                ("search_files", {"pattern": "def issue_token", "path": "src"}, SEARCH_RESULT, None),
                ("terminal", {"command": "pytest -q tests/test_auth.py"},
                 {"output": PYTEST_FAILED, "exit_code": 1, "error": None}, None),
                ("patch", {"mode": "replace", "path": "src/atlas/auth.py", "old_string": "    now = now or time.time()",
                           "new_string": "    if now is None:\n        now = time.time()"},
                 {"success": True, "diff": AUTH_DIFF, "files_modified": ["src/atlas/auth.py"]},
                 {"inline_diff": inline_diff(AUTH_DIFF)}),
                ("todo_list", {"todos": todos, "merge": True}, {"todos": todos, "revision": 2}, None),
                ("terminal", {"command": "pytest -q tests/test_auth.py"},
                 {"output": PYTEST_PASSED, "exit_code": 0, "error": None}, None)):
            turns += tool_rows("call_" + secrets.token_hex(6), name, args, result, metadata)
        turns.append(("assistant", "`issue_token` treated `now=0` as missing because of `now or time.time()`. It "
                      "checks `now is None` now, and the test passes:\n\n```python\nif now is None:\n"
                      "    now = time.time()\n```", {"finish_reason": "stop", "reasoning": (
                          "The failure only shows up when now is 0, which is falsy, so `or` replaces it. "
                          "Checking for None fixes it without changing other callers.")}))
        flaky = self.seed_chat("Fix flaky login test", age=2 * HOUR, cwd=atlas, pinned=True, turns=turns,
                               usage=(18400, 2100, 7))
        flaky.tool_call_count = 6
        flaky.todo_state = {"todos": todos, "revision": 2}
        self.start_process(flaky, "python -m http.server 8000", atlas, age=HOUR)
        self.seed_chat("Refactor storage layer", age=26 * HOUR, cwd=atlas, unread=True, usage=(5200, 640, 1), turns=[
            ("user", "Sketch a plan to split storage.py into a reader and a writer.", {}),
            ("assistant", "Here is a plan:\n\n1. Move `load_*` into `storage/reader.py`.\n2. Move `save_*` into "
             "`storage/writer.py`.\n3. Keep `storage/__init__.py` re-exporting both so imports keep working.\n\n"
             "Want me to start with step 1?", {"finish_reason": "stop"})])
        self.seed_chat("Release notes draft", age=3 * DAY, cwd=beacon, usage=(4100, 520, 1), turns=[
            ("user", "Draft release notes for 1.4.", {}),
            ("assistant", "## Beacon 1.4\n\n| Area | Change |\n|---|---|\n| Server | Graceful shutdown on SIGTERM |\n"
             "| CLI | `beacon serve --port` |\n| Docs | A new quick start |\n\n```bash\nnpm install beacon@1.4.0\n```",
             {"finish_reason": "stop"})])
        self.seed_chat("Benchmark ideas", age=9 * DAY, cwd=beacon, archived=True, usage=(2600, 300, 1), turns=[
            ("user", "List ideas for a benchmark of the server.", {}),
            ("assistant", "- Requests per second at 1, 10 and 100 connections\n- p99 latency under load\n"
             "- Memory after an hour", {"finish_reason": "stop"})])
        self.seed_chat("Old onboarding notes", age=35 * DAY, cwd=DEMO_HOME, usage=(1900, 210, 1), turns=[
            ("user", "Summarize notes.md", {}),
            ("assistant", "It lists three things to look at later: the new release flow, old branches to clean "
             "up, and the storage RFC.", {"finish_reason": "stop"})])
        self.seed_chat("Paper summary", age=2 * DAY, profile="research", usage=(3300, 410, 1), turns=[
            ("user", "Summarize the attention paper in three sentences.", {}),
            ("assistant", "It replaces recurrence with self-attention. Every token attends to every other token "
             "in parallel. That trains faster and translates better.", {"finish_reason": "stop"})])
        self.seed_chat("Daily digest", age=5 * HOUR, source="cron", usage=(900, 80, 1), turns=[
            ("user", "Run the daily digest job.", {}),
            ("assistant", "Nothing new in the watched folders today.", {"finish_reason": "stop"})])
        self.seed_chat("Telegram chat", age=50 * 60, source="telegram", usage=(700, 60, 1), turns=[
            ("user", "remind me what we decided about the release", {}),
            ("assistant", "Ship 1.4 on Thursday, after the docs review.", {"finish_reason": "stop"})])

    def seed_chat(self, title: str, *, age: float, turns: list[tuple[str, str, dict[str, Any]]], cwd: str = "",
                  profile: str = "default", source: str = "desktop", pinned: bool = False, archived: bool = False,
                  unread: bool = False, usage: tuple[int, int, int] = (0, 0, 0)) -> StoredSession:
        last = time.time() - age
        started = last - 30 * len(turns)
        branch, root = git_info(cwd)
        key = datetime.fromtimestamp(started).strftime("%Y%m%d_%H%M%S_") + secrets.token_hex(3)
        stored = StoredSession(key=key, source=source, title=title, started_at=started, profile=profile, cwd=cwd,
                               git_branch=branch, git_repo_root=root, pinned=pinned, archived=archived, unread=unread)
        stored.usage.update(input=usage[0], output=usage[1], calls=usage[2])
        self.sessions[key] = stored
        for index, (role, content, extra) in enumerate(turns):
            row = self.add_row(stored, role, content, **extra)
            row["timestamp"] = started + 30 * (index + 1)
        stored.last_active = last
        return stored

    # ── helpers ───────────────────────────────────────────────────────────────────────────────────

    def runtime(self, params: dict[str, Any], message: str = "session not found") -> Runtime:
        rt = self.runtimes.get(str(params.get("session_id") or ""))
        if rt is None:
            raise RpcError(4001, message)
        return rt

    def chat_info(self, stored: StoredSession | None) -> dict[str, Any]:
        """The SessionLiveInfo fields the chat screens read (model pills, workspace, project, usage)."""
        if stored is None:
            return {}
        return {"model": stored.model, "provider": stored.provider, "reasoning_effort": stored.reasoning_effort,
                "fast": stored.fast, "service_tier": "priority" if stored.fast else "", "cwd": stored.cwd,
                "branch": stored.git_branch, "project": project_ref(stored.cwd), "usage": self.usage_snapshot(stored)}

    def apply_create_params(self, stored: StoredSession, params: dict[str, Any]) -> None:
        """session.create's composer picks: workspace, model, effort, Fast, profile."""
        if cwd := str(params.get("cwd") or ""):
            stored.cwd = posixpath.normpath(cwd.replace("~", DEMO_HOME, 1) if cwd.startswith("~") else cwd)
            stored.git_branch, stored.git_repo_root = git_info(stored.cwd)
        if model := str(params.get("model") or ""):
            stored.model = model
            stored.provider = str(params.get("provider") or "") or self.provider_of(model) or stored.provider
        if effort := str(params.get("reasoning_effort") or ""):
            stored.reasoning_effort = effort
        if params.get("fast") is not None:
            stored.fast = bool(params.get("fast"))
        if profile := str(params.get("profile") or ""):
            stored.profile = profile

    def usage_snapshot(self, stored: StoredSession) -> dict[str, Any]:
        """server.py _get_usage: cumulative session counters plus the context window fields."""
        used = sum(tokens for _, _, _, tokens in self.context_categories(stored))
        u = stored.usage
        return {"model": stored.model, "input": u["input"], "output": u["output"], "reasoning": u["reasoning"],
                "prompt": u["input"], "completion": u["output"], "total": u["input"] + u["output"],
                "calls": u["calls"], "compressions": 0, "context_used": used, "context_max": CONTEXT_MAX,
                "context_percent": max(0, min(100, round(used / CONTEXT_MAX * 100))),
                "context_source": "provider_usage", "context_estimated": False}

    def context_categories(self, stored: StoredSession) -> list[tuple[str, str, str, int]]:
        conversation = sum(len(m.get("content") or "") for m in stored.messages) // 4
        rules = len(self.files.get(f"{stored.git_repo_root}/AGENTS.md", b"")) // 4 if stored.git_repo_root else 0
        sizes = {"rules": rules, "conversation": conversation}
        return [(cid, color, label, sizes.get(cid, fixed)) for cid, color, label, fixed in CONTEXT_CATEGORIES
                if sizes.get(cid, fixed) > 0 or cid == "conversation"]

    def count_turn_usage(self, stored: StoredSession, rt: Runtime, final: str) -> None:
        notes = rt.notes or TurnNotes()
        u = stored.usage
        u["input"] += sum(tokens for *_, tokens in self.context_categories(stored)) * (1 + notes.calls)
        u["output"] += max(1, len(final) // 4) + 40 * notes.calls
        u["reasoning"] += len(notes.reasoning) // 4
        u["calls"] += 1 + notes.calls

    def provider_of(self, model: str) -> str | None:
        return next((slug for slug, _name, models in DEMO_PROVIDERS if model in models), None)

    def capabilities(self, model: str) -> tuple[bool, bool]:
        """(fast, reasoning) of a model; unknown models get neither."""
        for _slug, _name, models in DEMO_PROVIDERS:
            if model in models:
                return models[model][0], models[model][1]
        return False, False

    def is_dir(self, path: str) -> bool:
        return path in self.dirs

    def entries(self, directory: str) -> list[tuple[str, bool]]:
        """(name, is_dir) of one fake directory, sorted."""
        prefix = directory.rstrip("/") + "/"
        names = {p[len(prefix):].split("/", 1)[0] for p in (*self.files, *self.dirs) if p.startswith(prefix)}
        return sorted((n, self.is_dir(prefix + n)) for n in names if n)

    def stage_turn_images(self, rt: Runtime, text: str) -> str:
        """Hand the staged images to the turn being submitted; the stored user row shows them as ``@image:`` refs."""
        rt.turn_images, rt.attached_images = rt.attached_images, []
        if not rt.turn_images:
            return text
        return text + "\n\n" + "\n".join(f"@image:{format_ref(p)}" for p in rt.turn_images)

    def turn_attachment_notes(self, rt: Runtime, text: str) -> list[str]:
        """What the scripted agent says about this turn's images and ``@file:`` refs."""
        notes = rt.notes or TurnNotes()
        out = []
        if notes.images:
            out.append(f"I got {len(notes.images)} image(s): " + ", ".join(posixpath.basename(p) for p in notes.images))
        stored = self.sessions.get(rt.key)
        workspace = (stored.cwd if stored else "") or DEMO_HOME
        for match in FILE_REF.finditer(text):
            ref = match.group(1).strip("`\"'")
            path = ref if ref.startswith("/") else posixpath.normpath(f"{workspace}/{ref}")
            if (data := self.files.get(path)) is not None:
                out.append(f"Read @file:{format_ref(ref)} ({len(data)} bytes).")
            else:
                out.append(f"@file:{format_ref(ref)} was not found.")
        return out

    def after_turn(self, rt: Runtime) -> None:
        """A failed turn stays as ``inflight`` until the next one; a model picked mid-turn applies now."""
        rt.inflight = rt.failed_turn
        if rt.pending_model and (stored := self.sessions.get(rt.key)):
            stored.model, stored.provider = rt.pending_model
            if not self.capabilities(stored.model)[0]:
                stored.fast = False
        rt.pending_model = None

    # ── demo turns ────────────────────────────────────────────────────────────────────────────────

    def chat_demos(self) -> dict[str, Callable[[Runtime, StoredSession], Awaitable[str]]]:
        """Trigger word -> demo, in the order they run within a turn."""
        return {"think": self.demo_think, "tools": self.demo_tools, "todo": self.demo_todo,
                "delegate": self.demo_delegate, "image": self.demo_image, "fail": self.demo_fail}

    async def run_native_tool(self, rt: Runtime, stored: StoredSession, name: str, args: dict[str, Any],
                              result: Any, *, metadata: dict[str, Any] | None = None,
                              extra: dict[str, Any] | None = None,
                              work: Callable[[str], Awaitable[None]] | None = None) -> str:
        """One built-in tool call (tool_progress.py): tool.generating, tool.start, the work, tool.complete with the
        parsed result and display metadata, then the stored assistant + tool rows."""
        tool_id = "call_" + secrets.token_hex(6)
        await self.emit(rt, "tool.generating", {"name": name})
        await asyncio.sleep(TOOL_SECONDS)
        await self.emit(rt, "tool.start", {"tool_id": tool_id, "name": name, "context": tool_context(name, args),
                                           "args": args})
        started = time.monotonic()
        if work is not None:
            await work(tool_id)
        await asyncio.sleep(TOOL_SECONDS)
        await self.emit(rt, "tool.complete", {"tool_id": tool_id, "name": name, "args": args, **(metadata or {}),
                                              "duration_s": round(time.monotonic() - started, 3), "result": result,
                                              **(extra or {})})
        for role, content, row_extra in tool_rows(tool_id, name, args, result, metadata):
            self.add_row(stored, role, content, **row_extra)
        stored.tool_call_count += 1
        if rt.notes is not None:
            rt.notes.calls += 1
            rt.notes.tools_ran = True
        return tool_id

    async def demo_think(self, rt: Runtime, stored: StoredSession) -> str:
        await self.emit(rt, "thinking.delta", {"text": "(◔_◔) pondering…"})
        for chunk in chunks(DEMO_REASONING, STREAM_CHUNKS):
            await asyncio.sleep(STREAM_SECONDS / STREAM_CHUNKS)
            await self.emit(rt, "reasoning.delta", {"text": chunk})
        if rt.notes is not None:
            rt.notes.reasoning += DEMO_REASONING
        return "After thinking it over: the answer is 42."

    async def demo_tools(self, rt: Runtime, stored: StoredSession) -> str:
        workspace = stored.cwd or project_path("atlas")
        await self.run_native_tool(rt, stored, "search_files", {"pattern": "def issue_token", "path": "src"},
                                   SEARCH_RESULT)
        test = {"command": "pytest -q tests/test_auth.py"}
        await self.run_native_tool(rt, stored, "terminal", test, {"output": PYTEST_FAILED, "exit_code": 1,
                                                                  "error": None})
        await self.run_native_tool(
            rt, stored, "patch", {"mode": "replace", "path": "src/atlas/auth.py",
                                  "old_string": "    now = now or time.time()",
                                  "new_string": "    if now is None:\n        now = time.time()"},
            {"success": True, "diff": AUTH_DIFF, "files_modified": ["src/atlas/auth.py"]},
            metadata={"inline_diff": inline_diff(AUTH_DIFF)})
        await self.run_native_tool(
            rt, stored, "write_file", {"path": "CHANGELOG.md", "content": CHANGELOG_NEW},
            {"bytes_written": len(CHANGELOG_NEW.encode()), "dirs_created": False, "verified": True},
            metadata={"inline_diff": inline_diff(CHANGELOG_DIFF)})
        await self.run_native_tool(rt, stored, "terminal", test, {"output": PYTEST_PASSED, "exit_code": 0,
                                                                  "error": None})
        server = {"command": "python -m http.server 8000", "background": True}
        proc = self.start_process(stored, server["command"], workspace)
        await self.run_native_tool(rt, stored, "terminal", server, {
            "output": "Background process started", "session_id": proc["id"], "pid": proc["pid"], "exit_code": 0,
            "error": None})
        changed = [(path, *diff_stats(diff)) for path, diff in (("src/atlas/auth.py", AUTH_DIFF),
                                                                ("CHANGELOG.md", CHANGELOG_DIFF))]
        return ("Found the bug, fixed it and re-ran the tests (1 failed, then 4 passed). The preview server runs "
                f"in the background as `{proc['id']}`.\n\n{len(changed)} files changed:\n"
                + "\n".join(f"- `{path}` +{added} -{removed}" for path, added, removed in changed))

    async def demo_todo(self, rt: Runtime, stored: StoredSession) -> str:
        plan = [{"id": "1", "content": "Reproduce the flaky test", "status": "completed"},
                {"id": "2", "content": "Fix the token clock", "status": "in_progress"},
                {"id": "3", "content": "Add a regression test", "status": "pending"}]
        await self.write_todos(rt, stored, plan, merge=False)
        progress = [{"id": "2", "content": "Fix the token clock", "status": "completed"},
                    {"id": "3", "content": "Add a regression test", "status": "in_progress"}]
        state = await self.write_todos(rt, stored, progress, merge=True)
        done = sum(t["status"] == "completed" for t in state["todos"])
        return f"Planned {len(state['todos'])} tasks; {done} done so far."

    async def write_todos(self, rt: Runtime, stored: StoredSession, todos: list[dict[str, Any]],
                          merge: bool) -> dict[str, Any]:
        """One todo_list call: tool.complete carries the snapshot, then a full-snapshot todo.updated."""
        current = list((stored.todo_state or {}).get("todos") or []) if merge else []
        by_id = {t["id"]: i for i, t in enumerate(current)}
        for todo in todos:
            if todo["id"] in by_id:
                current[by_id[todo["id"]]] = {**current[by_id[todo["id"]]], **todo}
            else:
                current.append(dict(todo))
        state = {"todos": current, "revision": int((stored.todo_state or {}).get("revision") or 0) + 1}
        summary = {"total": len(current), **{s: sum(t["status"] == s for t in current)
                                             for s in ("pending", "in_progress", "completed", "cancelled")}}
        await self.run_native_tool(rt, stored, "todo_list", {"todos": todos, "merge": merge},
                                   {**state, "summary": summary}, extra=state)
        stored.todo_state = state
        await self.emit(rt, "todo.updated", state)
        return state

    async def demo_delegate(self, rt: Runtime, stored: StoredSession) -> str:
        goal = "Survey the storage layer for unused helpers"
        summary = "storage.py has two helpers; save_user is only used by tests. Nothing else is unused."
        sid = f"sa-0-{secrets.token_hex(4)}"
        base = {"goal": goal, "task_count": 1, "task_index": 0, "subagent_id": sid,
                "child_session_id": self.new_key(), "delegation_id": "dlg_" + secrets.token_hex(6), "depth": 1,
                "model": stored.model, "toolsets": ["file", "terminal"]}
        roster = self.subagents.setdefault(rt.sid, {})
        started = time.time()
        entry = {"task_index": 0, "status": "completed", "summary": summary, "api_calls": 3, "duration_seconds": 0.0,
                 "exit_reason": "completed"}
        result = {"results": [entry], "total_duration_seconds": 0.0}

        async def work(tool_id: str) -> None:
            await self.emit(rt, "subagent.spawn_requested", {**base, "tool_count": 0, "text": goal})
            roster[sid] = {"subagent_id": sid, "parent_id": None, "depth": 1, "goal": goal,
                           "delegation_id": base["delegation_id"], "model": stored.model, "started_at": started,
                           "status": "running", "tool_count": 0, "last_tool": "", "accepting_steer": True}
            await self.emit(rt, "subagent.start", {**base, "tool_count": 0, "text": goal})
            await self.emit(rt, "subagent.thinking", {**base, "tool_count": 0,
                                                      "text": "Listing the storage helpers first."})
            for count, (tool, preview) in enumerate((("search_files", "def "), ("read_file", "src/atlas/storage.py")),
                                                    1):
                await asyncio.sleep(SUBAGENT_SECONDS)
                roster[sid].update(tool_count=count, last_tool=tool)
                await self.emit(rt, "subagent.tool", {**base, "tool_count": count, "tool_name": tool,
                                                      "text": preview, "tool_preview": preview})
            await self.emit(rt, "subagent.progress", {**base, "tool_count": 2, "text": "🔀 search_files, read_file"})
            await asyncio.sleep(SUBAGENT_SECONDS)
            roster.pop(sid, None)
            duration = round(time.time() - started, 2)
            entry["duration_seconds"] = result["total_duration_seconds"] = duration
            await self.emit(rt, "subagent.complete", {
                **base, "tool_count": 2, "text": summary[:160], "status": "completed", "summary": summary,
                "duration_seconds": duration, "input_tokens": 1830, "output_tokens": 212,
                "reasoning_tokens": 0, "api_calls": 3, "files_read": ["src/atlas/storage.py"],
                "output_tail": [{"tool": "read_file", "preview": "def load_user(uid): …", "is_error": False}]})

        try:
            await self.run_native_tool(rt, stored, "delegate_task", {"goal": goal, "toolsets": ["file", "terminal"]},
                                       result, work=work)
        finally:
            roster.pop(sid, None)
        return f"The subagent reports: {summary}"

    async def demo_image(self, rt: Runtime, stored: StoredSession) -> str:
        path = rt.notes.images[-1] if rt.notes and rt.notes.images else DEMO_IMAGE
        return f"Here is the image:\n\nMEDIA:{path}"

    async def demo_fail(self, rt: Runtime, stored: StoredSession) -> str:
        if rt.notes is not None:
            name = next((n for slug, n, _ in DEMO_PROVIDERS if slug == stored.provider), stored.provider)
            rt.notes.error = (DEMO_FAILURE, {"layer": "provider", "code": "rate_limit", "retryable": True,
                                             "provider": stored.provider, "model": stored.model,
                                             "provider_label": name})
        return ""

    async def fail_turn(self, rt: Runtime, stored: StoredSession, partial: str, usage: dict[str, Any]) -> None:
        """The terminal error frame (session_auto_continue.py _emit_terminal_turn_error) and the failed-turn row
        that closes the durable turn (agent/conversation_loop.py)."""
        assert rt.notes is not None and rt.notes.error is not None
        error, surface = rt.notes.error
        if partial:
            self.add_row(stored, "assistant", partial, finish_reason="error")
        self.add_row(stored, "assistant", PARTIAL_FAILED_TURN_NOTICE if rt.notes.tools_ran else FAILED_TURN_NOTICE,
                     display_kind="failed_turn", display_metadata={"error": error, "error_surface": surface})
        rt.failed_turn = {"user": (rt.inflight or {}).get("user", ""), "assistant": partial, "streaming": False,
                          "error": error, "status": "error", "recoverable": True, "error_surface": surface}
        await self.emit(rt, "message.complete", {
            "text": partial or turn_error_text(error, surface), "usage": usage, "status": "error", "error": error,
            "recoverable": True, "error_surface": surface, **({"partial": True} if partial else {})})

    def start_process(self, stored: StoredSession, command: str, cwd: str, age: float = 0) -> dict[str, Any]:
        """A tracked background process owned by the stored session (tools/process_registry.py)."""
        proc = {"id": "proc_" + secrets.token_hex(6), "session_key": stored.key, "command": command, "cwd": cwd,
                "pid": 40000 + secrets.randbelow(20000), "started_at": time.time() - age, "exited": False,
                "exit_code": None, "exited_at": None, "completion_reason": None,
                "output": "Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...\n"}
        self.processes[proc["id"]] = proc
        return proc

    @staticmethod
    def process_entry(proc: dict[str, Any]) -> dict[str, Any]:
        entry: dict[str, Any] = {
            "session_id": proc["id"], "command": proc["command"][:200], "cwd": proc["cwd"], "pid": proc["pid"],
            "owner_task_id": proc["session_key"],
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(proc["started_at"])),
            "uptime_seconds": int(time.time() - proc["started_at"]),
            "status": "exited" if proc["exited"] else "running", "output_preview": proc["output"][-200:],
            "output_tail": proc["output"][-4000:]}
        if proc["exited"]:
            entry.update(exit_code=proc["exit_code"], exited_at=proc["exited_at"],
                         completion_reason=proc["completion_reason"])
        return entry

    def kill(self, proc: dict[str, Any], source: str) -> dict[str, Any]:
        if proc["exited"]:
            return {"status": "already_exited", "session_id": proc["id"], "exit_code": proc["exit_code"],
                    "completion_reason": proc["completion_reason"], "output": proc["output"]}
        proc.update(exited=True, exit_code=-15, exited_at=time.time(), completion_reason="killed")
        return {"status": "killed", "session_id": proc["id"], "completion_reason": "killed",
                "termination_source": source, "output": proc["output"]}

    # ── RPCs ──────────────────────────────────────────────────────────────────────────────────────

    def chat_methods(self, conn: Conn, params: dict[str, Any]) -> dict[str, Callable[[], Any]]:
        return {
            "commands.catalog": self.commands_catalog,
            "complete.slash": lambda: self.complete_slash(params),
            "complete.path": lambda: self.complete_path(params),
            "slash.exec": lambda: self.slash_exec(params),
            "command.dispatch": lambda: self.command_dispatch(params),
            "model.options": lambda: self.model_options(params),
            "config.set": lambda: self.config_set(params),
            "config.get": lambda: self.config_get(params),
            "image.attach_bytes": lambda: self.image_attach_bytes(params),
            "image.detach": lambda: self.image_detach(params),
            "file.attach": lambda: self.file_attach(params),
            "process.list": lambda: self.process_list(params),
            "process.kill": lambda: self.process_kill(params),
            "process.stop": lambda: {"killed": self.stop_processes("process.stop")},
            "subagent.list": lambda: {"subagents": list(self.subagents.get(self.runtime(
                params, "session not found or not owned by this transport").sid, {}).values()), "delegations": []},
            "session.usage": lambda: self.usage_snapshot(self.sessions[self.runtime(params).key]),
            "session.context_breakdown": lambda: self.context_breakdown(params),
            "session.workspace.move": lambda: self.workspace_move(params),
            "session.branch": lambda: self.session_branch(conn, params),
            "projects.list": lambda: {"projects": [dict(p) for p in self.projects], "active_id": None},
        }

    def commands_catalog(self) -> dict[str, Any]:
        """methods_tools.py commands.catalog: registry pairs by category, quick commands, then skills."""
        pairs: list[list[str]] = []
        canon: dict[str, str] = {}
        commands: dict[str, dict[str, Any]] = {}
        categories: dict[str, list[list[str]]] = {}
        sub: dict[str, list[str]] = {}

        def add(key: str, desc: str, category: str) -> None:
            canon[key.lower()] = key
            pairs.append([key, desc])
            categories.setdefault(category, []).append([key, desc])

        for name, desc, category, hint, aliases, subs, desktop, mode in SLASH_COMMANDS:
            meta = {"argument_mode": mode or ("options" if subs else "text" if hint else None), "desktop": desktop}
            commands.update({f"/{key}": dict(meta) for key in (name, *aliases)})
            add(f"/{name}", f"{desc} (usage: /{name} {hint})" if hint else desc, category)
            canon.update({f"/{alias}": f"/{name}" for alias in aliases})
            if subs:
                sub[f"/{name}"] = list(subs)
        for name, (kind, command, _output) in sorted(QUICK_COMMANDS.items()):
            add(f"/{name}", f"{kind}: {command}", "User commands")
        skills = {}
        for key, (desc, used) in sorted(SKILL_COMMANDS.items()):
            pairs.append([key, desc])
            skills[key] = {"usage": used, "origin": "local"}
        return {"pairs": pairs, "sub": sub, "canon": canon, "commands": commands,
                "categories": [{"name": n, "pairs": rows} for n, rows in categories.items()], "skills": skills,
                "skill_count": len(skills), "warning": ""}

    def complete_slash(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_complete.py complete.slash: command names after ``/``, then argument words."""
        text = str(params.get("text") or "")
        if not text.startswith("/"):
            return {"items": []}
        if " " not in text:
            word = text[1:].lower()
            items = [{"text": f"{name} " if name == word else name, "display": f"/{name}", "meta": desc,
                      "kind": "command"}
                     for name, desc, *_ in SLASH_COMMANDS if name.startswith(word)]
            items += [{"text": key[1:], "display": key, "meta": f"⚡ {desc}", "kind": "skill"}
                      for key, (desc, _used) in sorted(SKILL_COMMANDS.items()) if key[1:].startswith(word)]
            return {"items": items, "replace_from": 1}
        base, _, rest = text[1:].partition(" ")
        base = COMMAND_ALIASES.get(base.lower(), base.lower())
        partial = "" if rest.endswith(" ") or not rest.split() else rest.split()[-1].lower()
        choices: list[tuple[str, str]] = []
        if base == "model":
            choices = [(m, name) for _slug, name, models in DEMO_PROVIDERS for m in models]
        elif base == "personality":
            choices = list(PERSONALITIES.items())
        else:
            choices = [(s, "") for c in SLASH_COMMANDS if c[0] == base for s in c[5]]
        items = [{"text": choice, "display": choice, "meta": meta, "kind": "command"}
                 for choice, meta in choices if choice.startswith(partial) and choice != partial]
        return {"items": items, "replace_from": text.rfind(" ") + 1}

    def complete_path(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_complete.py complete.path over the fake workspace: ``@`` hints, fuzzy ``@name``, listings."""
        word = str(params.get("word") or "")
        if not word:
            return {"items": []}
        rt = self.runtimes.get(str(params.get("session_id") or ""))
        stored = self.sessions.get(rt.key) if rt else None
        root = str(params.get("cwd") or "") or (stored.cwd if stored else "") or DEMO_HOME
        is_context = word.startswith("@")
        query = word[1:] if is_context else word
        if is_context and not query:
            return {"items": [{"text": t, "display": t, "meta": m} for t, m in AT_HINTS] + self.profile_mentions("")}
        if is_context and (query in ("file", "folder") or query.startswith(("file:", "folder:"))):
            tag, _, path_part = query.partition(":")
        else:
            tag, path_part = "", query
        bare = is_context and path_part and "/" not in path_part
        if bare and len(path_part.strip()) >= 2 and tag != "folder":
            items = self.fuzzy_paths(root, path_part, tag)
        else:
            items = self.listing(root, word, path_part, tag, is_context)
        if bare and not tag:
            items = self.profile_mentions(path_part) + items
        return {"items": items}

    def profile_mentions(self, prefix: str) -> list[dict[str, Any]]:
        return [{"text": f"@{p.name}", "display": f"@{p.name}", "meta": p.description or "agent profile"}
                for p in self.profiles.values() if p.name.startswith(prefix.lower())]

    def fuzzy_paths(self, root: str, query: str, tag: str) -> list[dict[str, Any]]:
        prefix = root.rstrip("/") + "/"
        ranked = []
        for path in sorted({*self.files, *self.dirs}):
            if not path.startswith(prefix) or "/." in path[len(prefix) - 1:]:
                continue
            rel, name, is_dir = path[len(prefix):], posixpath.basename(path), self.is_dir(path)
            lowered, q = name.lower(), query.lower()
            if q in lowered:
                ranked.append((0 if lowered.startswith(q) else 1, not is_dir, len(rel), rel, name, is_dir))
        ranked.sort()
        return [{"text": f"@{'folder' if is_dir else tag or 'file'}:{rel}{'/' if is_dir else ''}",
                 "display": name + ("/" if is_dir else ""), "meta": "dir" if is_dir else posixpath.dirname(rel)}
                for *_, rel, name, is_dir in ranked[:30]]

    def listing(self, root: str, word: str, path_part: str, tag: str, is_context: bool) -> list[dict[str, Any]]:
        expanded = path_part.replace("~", DEMO_HOME, 1) if path_part.startswith("~") else path_part or "."
        if expanded in (".", "") or expanded.endswith("/"):
            search, match = expanded or ".", ""
        else:
            search, match = posixpath.dirname(expanded) or ".", posixpath.basename(expanded)
        search = posixpath.normpath(search if search.startswith("/") else f"{root}/{search}")
        items = []
        for entry, is_dir in self.entries(search):
            if match and not entry.lower().startswith(match.lower()):
                continue
            if is_context and not tag and entry.startswith("."):
                continue
            if tag and (tag == "folder") != is_dir:
                continue
            rel = posixpath.relpath(f"{search}/{entry}", root)
            suffix = "/" if is_dir else ""
            if is_context:
                text = f"@{tag or ('folder' if is_dir else 'file')}:{rel}{suffix}"
            elif word.startswith("~"):
                text = "~/" + posixpath.relpath(f"{search}/{entry}", DEMO_HOME) + suffix
            else:
                text = ("./" if word.startswith("./") else "") + rel + suffix
            items.append({"text": text, "display": entry + suffix, "meta": "dir" if is_dir else ""})
        return items[:30]

    async def slash_exec(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_tools.py slash.exec: live commands answer here; skills, quick and pending-input commands go
        through command.dispatch."""
        rt = self.runtime(params)
        stored = self.sessions[rt.key]
        cmd = str(params.get("command") or "").strip()
        if not cmd:
            raise RpcError(4004, "empty command")
        parts = cmd.lstrip("/").split(maxsplit=1)
        base, arg = COMMAND_ALIASES.get(parts[0].lower(), parts[0].lower()), (parts[1] if len(parts) > 1 else "")
        if f"/{base}" in SKILL_COMMANDS:
            raise RpcError(4018, f"skill command: use command.dispatch for /{base}")
        if base in QUICK_COMMANDS or base in ("queue", "retry"):
            return await self.command_dispatch({"name": base, "arg": arg, "session_id": rt.sid})
        if base == "help":
            lines = []
            for category in dict.fromkeys(c[2] for c in SLASH_COMMANDS):
                lines.append(category)
                lines += [f"  /{n}{' ' + h if h else ''} — {d}" for n, d, c, h, *_ in SLASH_COMMANDS if c == category]
            lines.append("Skills: " + ", ".join(sorted(SKILL_COMMANDS)))
            return {"output": "\n".join(lines)}
        if base == "stop":
            return {"output": f"Stopped {self.stop_processes('slash.stop')} background process(es)."}
        if base in ("usage", "status"):
            u = self.usage_snapshot(stored)
            lines = [f"Model: {stored.model} ({stored.provider})", f"Tokens: {u['input']} in, {u['output']} out",
                     f"API calls: {u['calls']}",
                     f"Context: {u['context_used']:,} / {u['context_max']:,} ({u['context_percent']}%)"]
            if base == "status":
                lines = [f"Session: {stored.key}", f"Title: {stored.title or '(untitled)'}",
                         f"Workspace: {stored.cwd or DEMO_HOME}", f"Reasoning: {stored.reasoning_effort}",
                         f"Fast: {'on' if stored.fast else 'off'}", *lines]
            return {"output": "\n".join(lines)}
        if base == "title":
            if not arg.strip():
                return {"output": f"Title: {stored.title or '(untitled)'}"}
            title = self.set_title(stored, arg)
            await self.emit(rt, "session.title", {"session_id": stored.key, "title": title or ""})
            return {"output": f"Title set: {title}"}
        if base in ("model", "reasoning", "fast"):
            if base == "model" and not arg.strip():
                return {"output": f"Current model: {stored.model} (provider: {stored.provider})"}
            result = await self.config_set({"key": base, "value": arg.strip(), "session_id": rt.sid})
            return {"output": f"{base}: {result['value']}" + (" (applies after this turn)" if result.get("deferred")
                                                              else "")}
        if base in {c[0] for c in SLASH_COMMANDS}:
            return {"output": f"/{base} is not simulated by fake Hermes."}
        raise RpcError(4018, f"not a quick/plugin/bundle/skill command: {base}")

    async def command_dispatch(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_tools.py command.dispatch: quick > skill > built-in (/queue, /retry)."""
        name = str(params.get("name") or "").lstrip("/").lower()
        name = COMMAND_ALIASES.get(name, name)
        arg = str(params.get("arg") or "")
        rt = self.runtimes.get(str(params.get("session_id") or ""))
        if name in QUICK_COMMANDS:
            return {"type": "exec", "output": QUICK_COMMANDS[name][2]}
        if f"/{name}" in SKILL_COMMANDS:
            desc, _used = SKILL_COMMANDS[f"/{name}"]
            message = (f'[SYSTEM: The user invoked the "{name}" skill. {desc}.]\n\n'
                       f"User instruction: {arg or '(none)'}")
            return {"type": "skill", "message": message, "name": name,
                    "display": f"/{name}" + (f" {arg}" if arg else "")}
        if name == "queue":
            if not arg:
                raise RpcError(4004, "usage: /queue <prompt>")
            return {"type": "send", "message": arg}
        if name == "retry":
            return self.retry(rt)
        raise RpcError(4018, f"not a quick/plugin/bundle/skill command: {name}")

    def retry(self, rt: Runtime | None) -> dict[str, Any]:
        """/retry rewinds the last user turn out of the history and sends it again."""
        if rt is None:
            raise RpcError(4001, "no active session to retry")
        if rt.running:
            raise RpcError(4009, busy_message("retry"))
        if rt.attached_images:
            raise RpcError(4018, "retry cannot safely reconstruct or combine attached media")
        stored = self.sessions[rt.key]
        index = next((i for i in range(len(stored.messages) - 1, -1, -1) if stored.messages[i]["role"] == "user"),
                     None)
        if index is None:
            raise RpcError(4018, "no previous user message to retry")
        content = stored.messages[index]["content"] or ""
        del stored.messages[index:]
        rt.failed_turn = rt.inflight = None
        return {"type": "send", "message": content}

    def model_options(self, params: dict[str, Any]) -> dict[str, Any]:
        rt = self.runtimes.get(str(params.get("session_id") or ""))
        stored = self.sessions.get(rt.key) if rt else None
        model, provider = (stored.model, stored.provider) if stored else ("fake-hermes", "fake")
        providers = []
        for slug, name, models in DEMO_PROVIDERS:
            providers.append({
                "slug": slug, "name": name, "models": list(models), "total_models": len(models),
                "is_current": slug == provider, "is_user_defined": False, "source": "built-in", "authenticated": True,
                "capabilities": {m: {"fast": fast, "reasoning": reasoning, "can_disable_reasoning": reasoning}
                                 for m, (fast, reasoning, _i, _o) in models.items()},
                "pricing": {m: {"input": i, "output": o, "cache": None, "free": i == "free" and o == "free"}
                            for m, (_f, _r, i, o) in models.items()}})
        return {"providers": providers, "model": model, "provider": provider}

    def config_get(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_config.py config.get for the keys the app reads: reasoning, fast and the whole config (display)."""
        key = str(params.get("key") or "")
        rt = self.runtimes.get(str(params.get("session_id") or ""))
        stored = self.sessions.get(rt.key) if rt else None
        if key == "reasoning":
            return {"value": stored.reasoning_effort if stored else "medium", "display": "hide"}
        if key == "fast":
            return {"value": "fast" if stored and stored.fast else "normal"}
        if key == "full":
            return {"config": {"display": {"show_reasoning": True, "tool_progress": "all"},
                               "model": {"default": stored.model if stored else "fake-hermes"}}}
        raise RpcError(4002, f"unknown config key: {key}")

    async def config_set(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_config_set.py for the composer's pills: model, reasoning, fast (session-scoped)."""
        key, value = str(params.get("key") or ""), params.get("value", "")
        sid = str(params.get("session_id") or "")
        rt = self.runtimes.get(sid)
        if rt is None and sid and key in ("model", "fast", "reasoning") and params.get("scope") != "global":
            raise RpcError(4001, "session not found")
        stored = self.sessions.get(rt.key) if rt else None
        word = str(value or "").strip().lower()
        if key == "model":
            result = self.set_model(rt, stored, str(value or "").strip(), bool(params.get("confirm_expensive_model")))
            if result.get("confirm_required") or result.get("deferred"):
                return result
        elif key == "reasoning":
            if word in REASONING_DISPLAY:
                return {"key": key, "value": REASONING_DISPLAY[word]}
            if word not in REASONING_LEVELS:
                raise RpcError(4002, f"unknown reasoning value: {value}")
            if stored is not None:
                stored.reasoning_effort = word
            result = {"key": key, "value": word}
        elif key == "fast":
            current = "fast" if stored and stored.fast else "normal"
            if word == "status":
                return {"key": key, "value": current}
            mode = FAST_WORDS.get(word, ("normal" if current == "fast" else "fast") if word in ("", "toggle") else None)
            if mode is None:
                raise RpcError(4002, f"unknown fast mode: {value}")
            if mode in ("fast", "ultrafast") and stored is not None and not self.capabilities(stored.model)[0]:
                raise RpcError(4002, f"{mode} mode is not available for this model")
            if stored is not None:
                stored.fast = mode in ("fast", "ultrafast")
            result = {"key": key, "value": mode}
        else:
            raise RpcError(4002, f"unknown config key: {key}")
        if rt is not None:
            await self.emit(rt, "session.info", self.info(rt))
        return result

    def set_model(self, rt: Runtime | None, stored: StoredSession | None, value: str,
                  confirmed: bool) -> dict[str, Any]:
        if not value:
            raise RpcError(4002, "model value required")
        if rt is None or stored is None:
            raise RpcError(4001, "config.set model requires a live session; to change the profile default run "
                           "/setup, or use the Models page (dashboard) / Settings -> Models (Desktop)")
        tokens = value.split()
        model = tokens[0]
        provider = tokens[tokens.index("--provider") + 1] if "--provider" in tokens[:-1] else self.provider_of(model)
        if provider is None or self.provider_of(model) != provider:
            raise RpcError(4002, f"unknown model: {value}")
        base = {"key": "model", "value": model, "warning": "", "scope": "session"}
        if model in EXPENSIVE_MODELS and not confirmed:
            return {**base, "confirm_required": True,
                    "confirm_message": f"{model} costs $15.00/M input and $75.00/M output tokens. Switch anyway?"}
        if rt.running:
            rt.pending_model = (model, provider)
            return {**base, "confirm_required": False, "confirm_message": "", "deferred": True}
        stored.model, stored.provider = model, provider
        if not self.capabilities(model)[0]:
            stored.fast = False
        return {**base, "confirm_required": False, "confirm_message": ""}

    def image_attach_bytes(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_prompt.py image.attach_bytes: base64 in, queued for the next prompt.submit."""
        rt = self.runtime(params)
        raw = str(params.get("content_base64") or params.get("data") or "").strip()
        if not raw:
            raise RpcError(4015, "content_base64 required")
        data = decode_base64(raw, re.compile(r"^data:image/[a-zA-Z0-9.+-]*;base64,(.*)$", re.DOTALL))
        if data is None:
            raise RpcError(4017, "data is not valid base64")
        if not data:
            raise RpcError(4017, "image is empty")
        if len(data) > ATTACH_MAX_BYTES:
            raise RpcError(4018, f"image too large ({len(data)} bytes; cap is {ATTACH_MAX_BYTES // 2 ** 20} MB)")
        filename = str(params.get("filename") or "")
        hint = str(params.get("ext") or "").strip().lower()
        hint = hint if not hint or hint.startswith(".") else "." + hint
        ext = posixpath.splitext(filename or (f"x{hint}" if hint else ""))[1].lower()
        ext = ext or next((e for sig, e in IMAGE_MAGIC if data.startswith(sig)),
                          ".webp" if data[:4] == b"RIFF" and data[8:12] == b"WEBP" else ".png")
        if ext not in IMAGE_EXTENSIONS:
            raise RpcError(4016, f"unsupported image extension: {ext}")
        rt.image_counter += 1
        name = f"upload_{datetime.now().strftime('%Y%m%d_%H%M%S')}_{rt.image_counter}{ext}"
        path = f"{DEMO_IMAGES}/{name}"
        self.media[path] = data
        rt.attached_images.append(path)
        return {"attached": True, "path": path, "count": len(rt.attached_images), "remainder": "",
                "text": f"[User attached image: {name}]", "bytes": len(data), **image_meta(name, data)}

    def image_detach(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_prompt.py image.detach: drops one staged image so the next prompt doesn't carry it."""
        rt = self.runtime(params)
        path = str(params.get("path") or "").strip()
        if not path:
            raise RpcError(4015, "path required")
        before = len(rt.attached_images)
        rt.attached_images = [p for p in rt.attached_images if p != path]
        return {"detached": len(rt.attached_images) != before, "count": len(rt.attached_images)}

    def file_attach(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_prompt.py file.attach: a workspace file as-is, anything else staged into attachments/; the
        reply's ``ref_text`` goes into the prompt."""
        rt = self.runtime(params)
        stored = self.sessions[rt.key]
        raw, data_url, name = (str(params.get(k) or "").strip() for k in ("path", "data_url", "name"))
        if not raw and not data_url:
            raise RpcError(4015, "path or data_url required")
        workspace = stored.cwd or DEMO_HOME
        resolved = posixpath.normpath(raw if raw.startswith("/") else f"{workspace}/{raw}") if raw else ""
        if resolved in self.files and resolved.startswith(workspace.rstrip("/") + "/"):
            target, uploaded = resolved, False
        else:
            if resolved in self.files:
                payload, filename = self.files[resolved], posixpath.basename(resolved)
            elif data_url:
                decoded = decode_base64(data_url, DATA_URL)
                if decoded is None:
                    raise RpcError(5028, "invalid data_url payload")
                payload = decoded
                filename = posixpath.basename(name or raw)
            else:
                raise RpcError(5028, "file not found on gateway and no data_url provided")
            filename = re.sub(r"[\x00-\x1f]+", "_", filename).strip().strip(".") or "attachment"
            stem, suffix = posixpath.splitext(filename)
            target, counter = f"{DEMO_ATTACHMENTS}/{filename}", 2
            while target in self.files:
                target, counter = f"{DEMO_ATTACHMENTS}/{stem or 'attachment'}-{counter}{suffix}", counter + 1
            self.files[target] = payload
            uploaded = True
        prefix = workspace.rstrip("/") + "/"
        ref_path = target[len(prefix):] if target.startswith(prefix) else target
        return {"attached": True, "name": posixpath.basename(target), "path": target, "ref_path": ref_path,
                "ref_text": f"@file:{format_ref(ref_path)}", "uploaded": uploaded}

    def process_list(self, params: dict[str, Any]) -> dict[str, Any]:
        key = self.runtime(params).key
        return {"processes": [self.process_entry(p) for p in self.processes.values() if p["session_key"] == key]}

    def process_kill(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_tools.py process.kill: ONE process, scoped to the caller's session (process.stop kills all)."""
        rt = self.runtime(params)
        proc_id = str(params.get("process_id") or "")
        if not proc_id:
            raise RpcError(4012, "process_id required")
        proc = self.processes.get(proc_id)
        if proc is None or proc["session_key"] != rt.key:
            raise RpcError(4044, f"no such process: {proc_id}")
        return self.kill(proc, "process.kill")

    def stop_processes(self, source: str) -> int:
        running = [p for p in self.processes.values() if not p["exited"]]
        for proc in running:
            self.kill(proc, source)
        return len(running)

    def context_breakdown(self, params: dict[str, Any]) -> dict[str, Any]:
        stored = self.sessions[self.runtime(params).key]
        categories = [{"color": color, "id": cid, "label": label, "tokens": tokens}
                      for cid, color, label, tokens in self.context_categories(stored)]
        total = sum(c["tokens"] for c in categories)
        files = []
        if stored.git_repo_root and (rules := self.files.get(f"{stored.git_repo_root}/AGENTS.md")) is not None:
            files.append({"label": "AGENTS.md", "path": f"{stored.git_repo_root}/AGENTS.md", "chars": len(rules),
                          "est_tokens": len(rules) // 4, "loaded": True, "status": "loaded"})
        return {"categories": categories, "context_max": CONTEXT_MAX,
                "context_percent": max(0, min(100, round(total / CONTEXT_MAX * 100))), "context_used": total,
                "estimated_total": total, "context_estimated": False, "context_source": "provider_usage",
                "model": stored.model, "context_files": files}

    async def workspace_move(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_session.py session.workspace.move: re-home a STORED session (by key); a live one follows."""
        key, raw = str(params.get("session_key") or "").strip(), str(params.get("cwd") or "").strip()
        if not key:
            raise RpcError(4007, "session_key required")
        if not raw:
            raise RpcError(4016, "cwd required")
        cwd = posixpath.normpath(raw.replace("~", DEMO_HOME, 1) if raw.startswith("~") else raw)
        if not self.is_dir(cwd):
            raise RpcError(4017, f"working directory does not exist: {raw}")
        stored = self.sessions.get(key)
        if stored is None:
            raise RpcError(4007, "session not found")
        stored.cwd = cwd
        stored.git_branch, stored.git_repo_root = git_info(cwd)
        if (rt := self.find_runtime(key)) is not None:
            await self.emit(rt, "session.info", self.info(rt))
        return {"cwd": cwd, "branch": stored.git_branch, "git_repo_root": stored.git_repo_root}

    def session_branch(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        """methods_session.py _branch_live: a new stored session with the parent's history, bound to this client."""
        rt = self.runtime(params)
        idem = str(params.get("idempotency_key") or "")
        if idem and (child := self.runtimes.get(self.idempotency.get(idem, ""))) is not None:
            return self.branch_result(child)
        parent = self.sessions[rt.key]
        # _visible_branch_history: user and assistant rows with text; ``count`` counts those.
        history = [m for m in parent.messages if m["role"] in ("user", "assistant") and (m.get("content") or "").strip()]
        if not history:
            raise RpcError(4008, "nothing to branch — send a message first")
        if isinstance(count := params.get("count"), int) and count > 0:
            history = history[:count]
        title = params.get("name") or self.next_title(parent.title or "branch")
        child_stored = StoredSession(
            key=self.new_key(), source=parent.source, title=title, profile=parent.profile, cwd=parent.cwd,
            git_branch=parent.git_branch, git_repo_root=parent.git_repo_root, model=parent.model,
            provider=parent.provider, reasoning_effort=parent.reasoning_effort, fast=parent.fast,
            parent_session_id=parent.key, branched_from=parent.key)
        for row in history:
            copy = {**row, "id": self.next_row_id, "session_id": child_stored.key}
            self.next_row_id += 1
            child_stored.messages.append(copy)
        child_stored.persisted = True
        self.sessions[child_stored.key] = child_stored
        child = Runtime(sid=uuid.uuid4().hex[:8], key=child_stored.key)
        self.attach(child, conn)
        self.runtimes[child.sid] = child
        if idem:
            self.idempotency[idem] = child.sid
        return self.branch_result(child)

    def branch_result(self, child: Runtime) -> dict[str, Any]:
        stored = self.sessions[child.key]
        return {"session_id": child.sid, "stored_session_id": stored.key, "title": stored.title or "",
                "parent": stored.parent_session_id or "", "message_count": len(stored.messages),
                "messages": gateway_messages(stored), "info": self.info(child)}

    def next_title(self, base_title: str) -> str:
        """hermes_state_titles.py get_next_title_in_lineage: "chat" -> "chat #2" -> "chat #3"."""
        match = NUMBERED_TITLE.match(base_title)
        base = match.group(1) if match else base_title
        titles = [s.title for s in self.sessions.values() if s.title == base or (s.title or "").startswith(base + " #")]
        if not titles:
            return base
        numbers = [int(m.group(2)) for m in (NUMBERED_TITLE.match(t or "") for t in titles) if m]
        return f"{base} #{max([1, *numbers]) + 1}"

    def set_title(self, stored: StoredSession, title: str) -> str | None:
        """A user title: sanitized, unique across sessions; empty clears it (ValueError otherwise)."""
        cleaned = sanitize_title(title)
        if cleaned and (other := next((s for s in self.sessions.values()
                                       if s.title == cleaned and s.key != stored.key), None)):
            raise ValueError(f"Title '{cleaned}' is already in use by session {other.key}")
        stored.title = cleaned
        return cleaned

    # ── REST ──────────────────────────────────────────────────────────────────────────────────────

    def listed(self, stored: StoredSession, *, min_messages: int = 0, archived: str = "exclude",
               profile: str = "all") -> bool:
        if not stored.persisted or stored.hidden or stored.row()["message_count"] < min_messages:
            return False
        if (archived == "exclude" and stored.archived) or (archived == "only" and not stored.archived):
            return False
        return profile in ("all", "") or stored.profile == profile

    async def list_profiles(self, request: Request) -> Response:
        if not self.authed(request):
            return self.unauthorized(request)
        log("http GET /api/profiles -> 200")
        return JSONResponse({"profiles": [self.profile_row(p) for p in self.profiles.values()]})

    async def sidebar_sessions(self, request: Request) -> Response:
        """profiles.py /api/profiles/sessions/sidebar: recents / cron / messaging slices in one call."""
        if not self.authed(request):
            log("http GET /api/profiles/sessions/sidebar -> 401")
            return self.unauthorized(request)
        q = request.query_params
        try:
            caps = {key: min(max(int(q.get(f"{key}_limit", default)), 1), 500)
                    for key, default in (("recents", 20), ("cron", 50), ("messaging", 100))}
        except ValueError:
            return JSONResponse({"detail": "limits must be integers"}, status_code=422)
        scope = (q.get("recents_profile") or "all").strip() or "all"
        excludes = {"recents": csv_list(q.get("recents_exclude")), "messaging": csv_list(q.get("messaging_exclude"))}
        rows = [s.row() for s in self.sessions.values() if self.listed(s, min_messages=1, profile=scope)]
        rows.sort(key=lambda r: r["last_active"] or r["started_at"], reverse=True)

        def pick(key: str) -> list[dict[str, Any]]:
            if key == "cron":
                return [r for r in rows if r["source"] == "cron"]
            return [r for r in rows if r["source"] not in excludes[key]]

        recents = pick("recents")
        names = [name for name in self.profiles if scope == "all" or name == scope]
        usage = {name: {"tokens": sum(r["input_tokens"] + r["output_tokens"] for r in rows if r["profile"] == name),
                        "cost_usd": 0.0} for name in names}
        truncated = {name: sum(r["profile"] == name for r in recents) >= caps["recents"] for name in names}
        messaging = pick("messaging")
        log(f"http GET /api/profiles/sessions/sidebar -> 200 ({len(recents)} recents)")
        return JSONResponse({
            "recents": {"sessions": pinned_window(recents, 0, caps["recents"]), "profiles_truncated": truncated,
                        "profiles_usage": usage},
            "cron": {"sessions": pinned_window(pick("cron"), 0, caps["cron"])},
            "messaging": {"sessions": pinned_window(messaging, 0, caps["messaging"]), "total": len(messaging)},
            "errors": [], "storage": {}})

    async def search_sessions(self, request: Request) -> Response:
        """sessions.py /api/sessions/search: id matches first, then message content (prefix words), one profile."""
        if not self.authed(request):
            log("http GET /api/sessions/search -> 401")
            return self.unauthorized(request)
        q = request.query_params
        query = (q.get("q") or "").strip()
        if not query:
            return JSONResponse({"results": []})
        limit = max(1, min(int(q.get("limit") or 20), 100))
        profile = q.get("profile") or "default"
        include = [q["source"]] if q.get("source") else csv_list(q.get("sources"))
        exclude = set(csv_list(q.get("exclude_sources")))
        candidates = [s for s in self.sessions.values() if s.persisted and s.profile == profile
                      and (not include or s.source in include) and s.source not in exclude]
        candidates.sort(key=lambda s: s.last_active, reverse=True)
        tokens = [re.sub(r"\W", "", t.lower()) for t in query.split() if re.sub(r"\W", "", t)]
        results: dict[str, dict[str, Any]] = {}

        def add(stored: StoredSession, snippet: str, role: str | None) -> None:
            if stored.key in results or len(results) >= limit:
                return
            row = stored.row()
            results[stored.key] = {
                "snippet": snippet, "role": role, "source": stored.source, "model": stored.model,
                "session_started": stored.started_at, "session_id": stored.key, "lineage_root": stored.key,
                "profile": profile, "is_default_profile": profile == "default",
                **{k: row[k] for k in ("id", "title", "started_at", "ended_at", "last_active", "is_active",
                                       "message_count", "tool_call_count", "input_tokens", "output_tokens",
                                       "preview", "parent_session_id", "archived")}}

        for stored in candidates:
            if query.lower() in stored.key.lower():
                add(stored, stored.row()["preview"] or f"Session ID: {stored.key}", None)
        for stored in candidates:
            for message in stored.messages:
                if message["role"] in ("user", "assistant") and tokens and \
                        (snippet := search_snippet(message.get("content") or "", tokens)):
                    add(stored, snippet, message["role"])
                    break
        log(f"http GET /api/sessions/search q={query!r} -> 200 ({len(results)} results)")
        return JSONResponse({"results": list(results.values())})

    async def manage_session(self, request: Request) -> Response:
        """sessions.py PATCH (title / archived / hidden / pinned / unread) and DELETE /api/sessions/{id}."""
        sid = request.path_params["session_id"]
        if not self.authed(request):
            log(f"http {request.method} /api/sessions/{sid} -> 401")
            return self.unauthorized(request)
        if problem := self.origin_problem(request):
            log(f"http {request.method} /api/sessions/{sid} -> 403", problem)
            return JSONResponse({"detail": problem}, status_code=403)
        stored = self.sessions.get(sid)
        if stored is not None and not stored.persisted:
            stored = None
        if request.method == "DELETE":
            if stored is None:
                log(f"http DELETE /api/sessions/{sid} -> 200 (already absent)")
                return JSONResponse({"ok": True, "already_absent": True})
            if (rt := self.find_runtime(sid)) is not None and rt.running:
                log(f"http DELETE /api/sessions/{sid} -> 409 (turn running)")
                return JSONResponse({"detail": "session has an active turn; stop it first"}, status_code=409)
            for proc in [p for p in self.processes.values() if p["session_key"] == sid]:
                self.kill(proc, "session.delete")
            if rt is None:
                del self.sessions[sid]
            else:
                # The store only: a live runtime stays bound to its sockets (session.close ends it), so its row is
                # gone from every list while the runtime keeps what it holds.
                stored.messages.clear()
                stored.persisted = False
            log(f"http DELETE /api/sessions/{sid} -> 200")
            await self.broadcast("sessions.changed", {})
            return JSONResponse({"ok": True})
        if stored is None:
            log(f"http PATCH /api/sessions/{sid} -> 404")
            return JSONResponse({"detail": "Session not found"}, status_code=404)
        try:
            body = await request.json()
        except Exception:  # noqa: BLE001 - FastAPI answers a malformed body with 422
            return JSONResponse({"detail": "invalid JSON body"}, status_code=422)
        body = body if isinstance(body, dict) else {}
        flags = ("archived", "hidden", "pinned", "unread")
        if body.get("title") is None and all(body.get(f) is None for f in flags):
            return JSONResponse({"detail": "Nothing to update; provide 'title', 'archived', 'hidden', 'pinned', "
                                           "and/or 'unread'."}, status_code=400)
        if body.get("title") is not None:
            try:
                self.set_title(stored, str(body["title"]))
            except ValueError as exc:
                log(f"http PATCH /api/sessions/{sid} -> 400 ({exc})")
                return JSONResponse({"detail": str(exc)}, status_code=400)
        result: dict[str, Any] = {"ok": True}
        for flag in flags:
            if body.get(flag) is not None:
                setattr(stored, flag, bool(body[flag]))
                result[flag] = bool(body[flag])
        result["title"] = stored.title or ""
        log(f"http PATCH /api/sessions/{sid} -> 200 {short(result)}")
        await self.broadcast("sessions.changed", {})
        return JSONResponse(result)

    async def get_media(self, request: Request) -> Response:
        """files.py /api/media: a gateway-local image as a data URL for clients that can't read its disk."""
        if not self.authed(request):
            return self.unauthorized(request)
        path = posixpath.normpath(request.query_params.get("path") or "")
        ext = posixpath.splitext(path)[1].lower()
        if ext not in MEDIA_TYPES:
            return JSONResponse({"detail": "Unsupported media type"}, status_code=415)
        if not path.startswith(DEMO_HERMES_HOME + "/"):
            return JSONResponse({"detail": "Path outside media roots"}, status_code=403)
        if (data := self.media.get(path)) is None:
            return JSONResponse({"detail": "File not found"}, status_code=404)
        log(f"http GET /api/media {path} -> 200 ({len(data)} bytes)")
        return JSONResponse({"data_url": f"data:{MEDIA_TYPES[ext]};base64,{base64.b64encode(data).decode()}"})


# ── M3: settings, profiles, providers, alert pushes ───────────────────────────────────────────────
# Shapes from hermes_cli/web_routers/{config_env,models,memory_providers,oauth,profiles,status}.py,
# hermes_cli/{web_server_config,config_defaults,config_defaults_env,moa_config,profiles,credential_lifecycle}.py,
# hermes_cli/web_routers/_common.py, plugins/memory/config_schema.py, agent/vault_store.py and
# tui_gateway/{methods_vault,methods_session,billing_view}.py. Every route that takes ``?profile=`` reads and
# writes that profile's own config.yaml, .env, SOUL.md, logins and vault (unknown profile -> 404).

FAKE_VERSION = "0.42.0"
FAKE_RELEASE_DATE = "2026-10-01"
CONFIG_VERSION = 52
DEFAULT_SANDBOX_IMAGE = "nousresearch/hermes-sandbox:desktop"
# config_env.py _CATEGORY_ORDER
CATEGORY_ORDER = ["general", "agent", "terminal", "display", "delegation", "memory", "compression", "security",
                  "browser", "voice", "tts", "stt", "logging", "discord", "auxiliary"]
# web_server_config.py _AUX_TASK_SLOTS (UI order of GET /api/model/auxiliary).
AUX_TASK_SLOTS = ("vision", "compression", "skills_hub", "approval", "mcp", "title_generation", "review",
                  "voice_chat", "triage_specifier", "kanban_decomposer", "profile_describer", "curator")
FAKE_MEMORY_PROVIDER = "fake-recall"
# hermes_constants.PROFILE_ID_RE and profiles.py _RESERVED_NAMES.
PROFILE_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
RESERVED_PROFILE_NAMES = frozenset({"hermes", "default", "test", "tmp", "root", "sudo"})
PROFILE_NAME_RULE = "Use lowercase letters, numbers, '-' or '_', starting with a letter or number, up to 64 characters"
# hermes_cli/config.py _ENV_VAR_NAME_RE and a slice of the writer denylist.
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ENV_DENYLIST = frozenset({"PATH", "PYTHONPATH", "PYTHONHOME", "LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
                          "NODE_OPTIONS", "EDITOR", "VISUAL", "PAGER", "BROWSER", "SHELL", "HERMES_HOME",
                          "HERMES_YOLO_MODE"})
ENV_DENY_PREFIXES = ("LD_", "DYLD_", "GIT_CONFIG_")
REDACTED_WRITE_DETAIL = "Refusing to save a redacted credential preview; re-enter the full secret to replace it."
LEGACY_MASK = re.compile(r".{4}\.\.\..{4}")
# config_env.py _CREDENTIAL_PROBES: the keys POST /api/providers/validate can try against the provider.
CREDENTIAL_PROBES = frozenset({"OPENROUTER_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY", "GEMINI_API_KEY"})
REVEAL_MAX, REVEAL_WINDOW = 5, 30.0
# The fake's own provider metadata for the demo model providers (provider_catalog()).
DEMO_CONTEXT = {"fake-hermes": 200_000, "fake-hermes-mini": 128_000, "fake-hermes-max": 1_000_000,
                "echo-1": 64_000, "echo-2-pro": 256_000}
DEFAULT_SOUL = "You are Hermes, a helpful assistant. Keep answers short unless asked for detail. (Fake Hermes SOUL.md)"
# web_server_oauth.py _OAUTH_PROVIDER_CATALOG (status_fn dropped).
OAUTH_PROVIDERS = (
    {"id": "nous", "name": "Nous Portal", "flow": "device_code", "cli_command": "hermes auth add nous",
     "docs_url": "https://portal.nousresearch.com"},
    {"id": "openai-codex", "name": "ChatGPT or Codex Subscription", "flow": "device_code",
     "cli_command": "hermes auth add openai-codex", "docs_url": "https://platform.openai.com/docs"},
    {"id": "qwen-oauth", "name": "Qwen (via Qwen CLI)", "flow": "external", "cli_command": "hermes auth add qwen-oauth",
     "docs_url": "https://github.com/QwenLM/qwen-code"},
    {"id": "minimax-oauth", "name": "MiniMax (OAuth)", "flow": "device_code",
     "cli_command": "hermes auth add minimax-oauth", "docs_url": "https://www.minimax.io"},
    {"id": "xai-oauth", "name": "xAI Grok OAuth (SuperGrok / Premium+)", "flow": "device_code",
     "cli_command": "hermes auth add xai-oauth",
     "docs_url": "https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth"},
    {"id": "copilot-acp", "name": "GitHub Copilot (ACP)", "flow": "external", "cli_command": "copilot login",
     "docs_url": "https://docs.github.com/en/copilot"},
    {"id": "anthropic", "name": "Anthropic Account", "flow": "external", "cli_command": "hermes auth add anthropic",
     "docs_url": "https://docs.claude.com/en/api/getting-started"},
)
OAUTH_SESSION_TTL = 15 * 60
OAUTH_VERIFICATION_URL = "https://example.com/fake-hermes/device"
# tui_gateway/methods_vault.py and agent/vault_store.py.
VAULT_ERROR = 5095
VAULT_KINDS = ("login", "payment", "address")
LOGIN_IDENTIFIER_TYPES = ("email", "phone", "username")
VAULT_FIELDS = {"payment": ("card_number", "cardholder_name", "exp_month", "exp_year", "cvc", "billing_postal_code"),
                "address": ("address_line1", "address_line2", "city", "state", "postal_code", "country")}
VAULT_REQUIRED = {"payment": ("card_number", "exp_month", "exp_year", "cvc"),
                  "address": ("address_line1", "city", "postal_code", "country")}
# (name, display name, installed on the fake host). Unlock with any master password but "wrong".
PASSWORD_MANAGERS = (("onepassword", "1Password", True), ("bitwarden", "Bitwarden", False))
BILLING_SCOPE_MESSAGE = "This action needs the billing:manage scope."
# The alert pushes the hermes_voice plugin sends beside the VoIP ones (the app's App/Notifications.swift).
ALERT_KINDS = ("approval", "clarify", "turn_done")
ALERT_DEFAULTS = {"approval": True, "clarify": True, "turn_done": False}
ALERT_CATEGORIES = {"approval": "HERMES_APPROVAL", "clarify": "HERMES_CLARIFY", "turn_done": "HERMES_TURN_DONE"}
ALERT_MEMORY = 200


def aux_block(timeout: int, *, reasoning_effort: bool = True, **extra: Any) -> dict[str, Any]:
    """config_defaults.py _aux: the shared auxiliary-task block."""
    block: dict[str, Any] = {"provider": "auto", "model": "", "base_url": "", "api_key": "", "timeout": timeout,
                             "extra_body": {}}
    if reasoning_effort:
        block["reasoning_effort"] = ""
    block.update(extra)
    return block


def default_config() -> dict[str, Any]:
    """A slice of config_defaults.py DEFAULT_CONFIG in its order and with its values: the sections the settings
    pages read, and a few voice ones the app must leave out."""
    return {
        "model": "", "providers": {}, "fallback_providers": [], "toolsets": ["hermes-cli"],
        "agent": {"max_turns": None, "gateway_timeout": 1800, "api_max_retries": 3, "service_tier": "",
                  "fast_auto_seconds": 60, "tool_use_enforcement": "auto", "verify_on_stop": False,
                  "clarify_timeout": 3600, "image_input_mode": "auto", "disabled_toolsets": []},
        "terminal": {"backend": "local", "modal_mode": "auto", "cwd": ".", "timeout": 180, "env_passthrough": [],
                     "docker_image": DEFAULT_SANDBOX_IMAGE, "modal_image": DEFAULT_SANDBOX_IMAGE,
                     "daytona_image": DEFAULT_SANDBOX_IMAGE, "container_cpu": 1, "container_memory": 5120,
                     "docker_mount_cwd_to_workspace": False, "persistent_shell": True},
        "browser": {"inactivity_timeout": 120, "command_timeout": 30, "headed": False, "allow_private_urls": False,
                    "engine": "auto", "auto_local_for_private_urls": True, "cdp_url": "", "use_real_profile": False,
                    "dialog_policy": "must_respond"},
        "checkpoints": {"enabled": False, "max_snapshots": 20, "max_total_size_mb": 500, "max_file_size_mb": 10,
                        "auto_prune": True, "retention_days": 7, "min_interval_hours": 24},
        "file_read_max_chars": 100_000,
        "tool_output": {"max_bytes": 50000, "max_lines": 2000, "max_line_length": 2000},
        "compression": {"enabled": True, "threshold": 0.5, "threshold_tokens": None, "target_ratio": 0.2,
                        "tail_mode": "lean", "protect_last_n": 20, "max_attempts": 3, "protect_first_n": 3,
                        "codex_gpt55_autoraise": True, "in_place": True},
        "auxiliary": {
            "transient_retries": 2, "free_only": False, "openrouter_model": "", "stream_only_base_urls": [],
            "vision": aux_block(120, download_timeout=30), "compression": aux_block(120, no_progress_timeout=None),
            "skills_hub": aux_block(30), "approval": aux_block(30),
            "review": {"provider": "auto", "model": "", "base_url": "", "api_key": "", "api_mode": ""},
            "mcp": aux_block(30),
            "title_generation": {"enabled": True, "model_upgrade_enabled": True, "provider": "auto", "model": "",
                                 "prefer_fast_model": False, "base_url": "", "api_key": "", "timeout": 30,
                                 "extra_body": {}, "reasoning_effort": "", "language": ""},
            "voice_chat": {**aux_block(120), "reasoning_effort": "none"},
            "triage_specifier": aux_block(120), "kanban_decomposer": aux_block(180),
            "profile_describer": aux_block(60), "curator": aux_block(600),
            "moa_reference": aux_block(900, reasoning_effort=False),
            "moa_aggregator": aux_block(900, reasoning_effort=False)},
        "display": {"compact": False, "personality": "", "resume_display": "full", "busy_input_mode": "interrupt",
                    "show_reasoning": True, "streaming": False, "show_cost": False, "skin": "default"},
        "dashboard": {"theme": "default"},
        "tts": {"provider": "edge", "edge": {"voice": "en-US-AriaNeural"},
                "openai": {"model": "gpt-4o-mini-tts", "voice": "alloy"}},
        "stt": {"enabled": True, "provider": "local", "local": {"model": "base", "language": ""}},
        "voice": {"voice_chat_mode": "chained", "max_recording_seconds": 120, "auto_tts": False},
        "wake_word": {"enabled": False, "provider": "auto", "phrase": "hey hermes"},
        "human_delay": {"mode": "off", "min_ms": 800, "max_ms": 2500},
        "context": {"engine": "compressor"},
        "memory": {"memory_enabled": True, "user_profile_enabled": True, "prefetch_spill_enabled": False,
                   "write_approval": False, "memory_char_limit": 2200, "user_char_limit": 1375, "nudge_interval": 10,
                   "provider": ""},
        "delegation": {"backend": "default", "model": "", "provider": "", "base_url": "", "api_key": "",
                       "api_mode": "", "max_iterations": 250, "child_timeout_seconds": 0, "reasoning_effort": "",
                       "max_concurrent_children": 10, "max_spawn_depth": 1, "orchestrator_enabled": True,
                       "subagent_auto_approve": False},
        "moa": {"default_preset": "default", "active_preset": "", "save_traces": False, "trace_dir": "",
                "privacy_filter": "", "presets": {"default": {
                    "reference_models": [{"provider": "openai-codex", "model": "gpt-5.5"},
                                         {"provider": "openrouter", "model": "deepseek/deepseek-v4-pro"}],
                    "aggregator": {"provider": "openrouter", "model": "anthropic/claude-opus-4.8"}, "enabled": True}}},
        "timezone": "",
        "approvals": {"mode": "smart", "timeout": 300, "cron_mode": "deny", "single_query_mode": "deny",
                      "unattended_mode": "deny", "smart_policy": "", "denial_breaker_threshold": 3, "deny": [],
                      "mcp_reload_confirm": True, "destructive_slash_confirm": True},
        "command_allowlist": [],
        "personalities": {},
        "security": {"allow_private_urls": False, "redact_secrets": True, "protected_instruction_files": True,
                     "website_blocklist": {"enabled": False, "domains": []}, "allow_lazy_installs": True},
        "code_execution": {"mode": "project", "kernel_idle_timeout": 1800, "max_session_kernels": 4},
        "logging": {"level": "INFO", "max_size_mb": 5, "backup_count": 3},
        "sessions": {"auto_prune": False, "retention_days": 90, "auto_archive": False, "auto_archive_days": 3,
                     "show_subagents": False},
        "updates": {"check": True, "pre_update_backup": "quick", "backup_keep": 5,
                    "non_interactive_local_changes": "stash", "refresh_cua_driver": True},
        "vault": {"key_storage": "file", "onepassword": {"enabled": True, "account": "", "binary_path": ""},
                  "bitwarden": {"enabled": True, "binary_path": ""}},
        "desktop": {"font_family": "", "repo_scan_enabled": True, "repo_scan_roots": [], "repo_scan_exclude_paths": []},
        "_config_version": CONFIG_VERSION,
    }


def schema_select(description: str, *options: str, **extra: Any) -> dict[str, Any]:
    return {"type": "select", "description": description, "options": list(options), **extra}


def timezone_options() -> list[str]:
    try:
        import zoneinfo
        return sorted(zoneinfo.available_timezones()) or ["UTC"]
    except Exception:  # noqa: BLE001
        return ["UTC"]


# web_server_config.py _SCHEMA_OVERRIDES (the slice the fake's defaults reach).
SCHEMA_OVERRIDES: dict[str, dict[str, Any]] = {
    "timezone": schema_select("IANA timezone (e.g. America/New_York). Blank uses the system timezone.",
                              *timezone_options(), searchable=True, clearable=True),
    "memory.provider": schema_select("Memory provider plugin", "", FAKE_MEMORY_PROVIDER),
    "model": {"type": "string", "description": "Default model (e.g. anthropic/claude-sonnet-4.6)",
              "category": "general"},
    "model_context_length": {"type": "number", "description": "Context window override (0 = auto-detect from model "
                             "metadata)", "category": "general"},
    "terminal.backend": schema_select("Terminal execution backend", "local", "docker", "ssh", "modal", "daytona",
                                      "vercel_sandbox"),
    "terminal.modal_mode": schema_select("Modal sandbox mode", "sandbox", "function"),
    "wake_word.provider": schema_select("Wake engine. Auto selects a platform-supported engine; Porcupine requires "
                                        "PORCUPINE_ACCESS_KEY.", "auto", "openwakeword", "sherpa", "porcupine"),
    "tts.provider": schema_select("Text-to-speech provider", "edge", "elevenlabs", "openai", "xai", "minimax",
                                  "mistral", "gemini", "neutts", "kittentts", "piper"),
    "stt.provider": schema_select("Speech-to-text provider", "local", "groq", "openai", "mistral", "xai", "elevenlabs",
                                  "deepinfra"),
    "stt.local.model": schema_select("Local faster-whisper model size", "base", "tiny", "small", "medium", "large-v3",
                                     "turbo"),
    "display.skin": schema_select("CLI visual theme", "default", "ares", "mono", "slate"),
    "dashboard.theme": schema_select("Web dashboard visual theme", "default", "midnight", "ember", "mono", "cyberpunk",
                                     "rose"),
    "display.resume_display": schema_select("How resumed sessions display history", "minimal", "full", "off"),
    "display.busy_input_mode": schema_select("Input behavior while agent is running", "interrupt", "queue", "steer"),
    "approvals.mode": schema_select("Dangerous command approval mode", "manual", "smart", "off"),
    "context.engine": schema_select("Context management engine", "default", "custom"),
    "human_delay.mode": schema_select("Simulated typing delay mode", "off", "typing", "fixed"),
    "logging.level": schema_select("Log level for agent.log", "DEBUG", "INFO", "WARNING", "ERROR"),
    "agent.service_tier": schema_select("Fast mode: fast = always, auto = first N seconds of each turn, cold = first "
                                        "turn only", "", "normal", "fast", "auto", "cold"),
    "delegation.reasoning_effort": schema_select("Reasoning effort for delegated subagents", "", "minimal", "low",
                                                 "medium", "high", "xhigh", "max", "ultra"),
    "updates.non_interactive_local_changes": schema_select(
        "When the chat app / gateway updates Hermes (no terminal prompt), what to do with uncommitted local source "
        "edits. 'stash' keeps them and re-applies them after the update; 'discard' throws them away. Terminal "
        "updates always ask, regardless of this setting.", "stash", "discard"),
    "updates.refresh_cua_driver": {"type": "boolean", "description": "Refresh an already-installed cua-driver during "
                                   "hermes update. Disable this on non-admin macOS accounts where /Applications is "
                                   "not writable."},
    "browser.headed": {"type": "boolean", "description": "Run the local browser in headed mode (visible window). Also "
                       "keeps the window open between turns; idle sessions are still reaped after "
                       "browser.inactivity_timeout."},
}
# web_server_config.py _CATEGORY_MERGE (the slice the fake's defaults reach).
CATEGORY_MERGE = {"context": "agent", "checkpoints": "agent", "approvals": "security", "human_delay": "display",
                  "dashboard": "display", "code_execution": "agent", "updates": "general", "session": "general"}
SCHEMA_TYPES = ((bool, "boolean"), (int, "number"), (float, "number"), (list, "list"), (dict, "object"))


def build_config_schema(config: dict[str, Any], prefix: str = "") -> dict[str, dict[str, Any]]:
    """web_server_config.py _build_schema_from_config: DEFAULT_CONFIG walked into flat dot-path fields."""
    schema: dict[str, dict[str, Any]] = {}
    for key, value in config.items():
        path = f"{prefix}.{key}" if prefix else key
        if path == "_config_version":
            continue
        if isinstance(value, dict):
            schema.update(build_config_schema(value, path))
            continue
        entry: dict[str, Any] = {"type": next((ui for py, ui in SCHEMA_TYPES if isinstance(value, py)), "string"),
                                 "description": path.replace(".", " → ").replace("_", " ").title(),
                                 "category": prefix.split(".")[0] if prefix else "general"}
        entry.update(SCHEMA_OVERRIDES.get(path, {}))
        entry["category"] = CATEGORY_MERGE.get(entry["category"], entry["category"])
        schema[path] = entry
        if path == "model":
            schema["model_context_length"] = dict(SCHEMA_OVERRIDES["model_context_length"])
    return schema


DEFAULT_CONFIG = default_config()
CONFIG_SCHEMA = build_config_schema(DEFAULT_CONFIG)


def flatten(config: dict[str, Any], prefix: str = "") -> dict[str, Any]:
    out: dict[str, Any] = {}
    for key, value in config.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict) and value:
            out.update(flatten(value, path))
        else:
            out[path] = value
    return out


DEFAULT_FLAT = flatten(DEFAULT_CONFIG)


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """hermes_cli/config.py _deep_merge: dicts merge per key; None over a section is ignored."""
    result = dict(base)
    for key, value in override.items():
        over_dict = isinstance(result.get(key), dict)
        if over_dict and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        elif not (over_dict and value is None):
            result[key] = copy.deepcopy(value)
    return result


def strip_defaults(config: dict[str, Any], defaults: dict[str, Any], keep: set[str],
                   prefix: str = "") -> dict[str, Any]:
    """save_config's _strip_default_values: what equals the default is not written unless the user set it before."""
    out: dict[str, Any] = {}
    for key, value in config.items():
        path = f"{prefix}.{key}" if prefix else key
        default = defaults.get(key, _MISSING) if isinstance(defaults, dict) else _MISSING
        if path in NO_STRIP:
            if value != default or path in keep:
                out[key] = value
        elif isinstance(value, dict) and isinstance(default, dict) and value:
            if (stripped := strip_defaults(value, default, keep, path)) or path in keep:
                out[key] = stripped
        elif value != default or path in keep or key == "_config_version":
            out[key] = value
    return out


_MISSING: Any = object()
# Named maps a user's file states whole (moa_config.py apply_user_moa_presets): never stripped, never merged.
NO_STRIP = frozenset({"moa.presets"})
# apps/desktop/src/app/settings/constants.ts ENUM_OPTIONS choices the server's select options lack.
DESKTOP_ENUM_EXTRAS = {"terminal.backend": ("singularity",), "context.engine": ("compressor",)}


def explicit_paths(config: dict[str, Any], prefix: str = "") -> set[str]:
    paths: set[str] = set()
    for key, value in config.items():
        path = f"{prefix}.{key}" if prefix else key
        paths.add(path)
        if isinstance(value, dict):
            paths |= explicit_paths(value, path)
    return paths


# hermes_cli/config.py _SECRET_CONFIG_KEYS / _SECRET_CONFIG_KEY_SUFFIXES: config keys whose value is a credential.
SECRET_CONFIG_KEYS = frozenset({"api_key", "apikey", "key", "token", "access_token", "refresh_token", "id_token",
                                "secret", "client_secret", "password", "passwd", "authorization", "private_key",
                                "bearer", "jwt"})
SECRET_CONFIG_SUFFIXES = ("_api_key", "_token", "_secret", "_password", "_key", "_access_key")


def shown(path: str, value: Any) -> str:
    """A config value for an error message: credentials only as their length."""
    leaf = path.rsplit(".", 1)[-1].lower()
    if leaf in SECRET_CONFIG_KEYS or leaf.endswith(SECRET_CONFIG_SUFFIXES):
        return f"<{len(json.dumps(value))} chars>"
    return json.dumps(value, ensure_ascii=False)


def mask_secret(value: str) -> str:
    """agent/redact.py mask_secret: ``abcd...7890``; shorter than 12 -> ``***``."""
    return "***" if len(value) < 12 else f"{value[:4]}...{value[-4:]}"


def credential_preview(value: str | None) -> str | None:
    """_common.py redacted_credential_preview: a display-only sentinel that can never be written back."""
    return f"«redacted:{mask_secret(value)}»" if value else None


def is_credential_preview(value: Any) -> bool:
    text = str(value or "")
    return text.startswith("«redacted") or text == "***" or LEGACY_MASK.fullmatch(text) is not None


def format_money(value: Decimal | None) -> str:
    """agent/billing_view.py format_money: ``$X`` for whole dollars, ``$X.YY`` otherwise."""
    if value is None:
        return "—"
    if value == value.to_integral_value():
        return f"${format(value.to_integral_value(), 'f')}"
    return f"${format(value.quantize(Decimal('0.01')), 'f')}"


def normalize_origin(value: str) -> str:
    """agent/vault_store.py normalize_origin: ``scheme://host[:port]``, default ports dropped."""
    value = (value or "").strip()
    if not value:
        raise RpcError(VAULT_ERROR, "origin is required")
    if "://" not in value:
        raise RpcError(VAULT_ERROR, f"origin must include a scheme (got {value!r})")
    parts = urlsplit(value)
    scheme, host = (parts.scheme or "").lower(), (parts.hostname or "").lower()
    if not scheme or not host:
        raise RpcError(VAULT_ERROR, f"could not parse origin from {value!r}")
    try:
        port = parts.port
    except ValueError as exc:
        raise RpcError(VAULT_ERROR, f"invalid port in origin {value!r}") from exc
    return f"{scheme}://{host}" if port is None or port == {"http": 80, "https": 443}.get(scheme) \
        else f"{scheme}://{host}:{port}"


def env_entry(description: str, prompt: str, category: str, *, url: str | None = None, password: bool | None = None,
              advanced: bool = False, tools: list[str] | None = None) -> dict[str, Any]:
    """config_defaults_env.py _category entries: password/advanced defaults per category."""
    entry: dict[str, Any] = {"description": description, "prompt": prompt}
    if url is not None:
        entry["url"] = url
    if tools is not None:
        entry["tools"] = tools
    if password is None:
        password = category in ("provider", "tool", "skill")
    entry["password"] = password
    entry["category"] = category
    if advanced:
        entry["advanced"] = True
    return entry


# A slice of config_defaults.py OPTIONAL_ENV_VARS.
OPTIONAL_ENV_VARS = {
    "OPENROUTER_API_KEY": env_entry("OpenRouter API key (for vision, web scraping helpers, and MoA)",
                                    "OpenRouter API key", "provider", url="https://openrouter.ai/keys",
                                    tools=["vision_analyze"], advanced=True),
    "GEMINI_API_KEY": env_entry("Google AI Studio API key (alias for GOOGLE_API_KEY)", "Gemini API key", "provider",
                                url="https://aistudio.google.com/app/apikey", advanced=True),
    "XAI_API_KEY": env_entry("xAI API key", "xAI API key", "provider", url="https://console.x.ai/", advanced=True),
    "XAI_BASE_URL": env_entry("xAI base URL override", "xAI base URL (leave empty for default)", "provider",
                              password=False, advanced=True),
    "DEEPSEEK_API_KEY": env_entry("DeepSeek API key for direct DeepSeek access", "DeepSeek API Key", "provider",
                                  url="https://platform.deepseek.com/api_keys"),
    "EXA_API_KEY": env_entry("Exa API key for AI-native web search and contents", "Exa API key", "tool",
                             url="https://exa.ai/", tools=["web_search", "web_extract"]),
    "FIRECRAWL_API_KEY": env_entry("Firecrawl API key for web search and scraping", "Firecrawl API key", "tool",
                                   url="https://firecrawl.dev/", tools=["web_search", "web_extract"]),
    "FIRECRAWL_API_URL": env_entry("Firecrawl API URL for self-hosted instances (optional)",
                                   "Firecrawl API URL (leave empty for cloud)", "tool", password=False, advanced=True),
    "BROWSERBASE_API_KEY": env_entry("Browserbase API key for cloud browser (optional — local browser works without "
                                     "this)", "Browserbase API key", "tool", url="https://browserbase.com/",
                                     tools=["browser_exec"]),
    "FAL_KEY": env_entry("FAL API key for image and video generation", "FAL API key", "tool", url="https://fal.ai/",
                         tools=["image_generate", "video_generate"]),
    "ELEVENLABS_API_KEY": env_entry("ElevenLabs API key for premium text-to-speech voices and Scribe transcription",
                                    "ElevenLabs API key", "tool", url="https://elevenlabs.io/",
                                    tools=["elevenlabs_tts", "voice_transcription"]),
    "GITHUB_TOKEN": env_entry("GitHub token for Skills Hub (higher API rate limits, skill publish)", "GitHub Token",
                              "tool", url="https://github.com/settings/tokens"),
    "NOTION_API_KEY": env_entry("Notion integration token (used by the `notion` skill)", "Notion API key", "skill",
                                url="https://www.notion.so/my-integrations", advanced=True),
    "TELEGRAM_BOT_TOKEN": env_entry("Complete Telegram bot token created by @BotFather (numeric bot ID followed by a "
                                    "colon and secret)", "Telegram bot token", "messaging",
                                    url="https://t.me/BotFather", password=True),
    "SUDO_PASSWORD": env_entry("Sudo password for terminal commands requiring root access; set to an explicit empty "
                               "string to try empty without prompting", "Sudo password", "setting", password=True),
}
# config_env.py _catalog_provider_env_metadata for the same keys plus the catalog-only ones (provider_catalog()).
CATALOG_ENV = {
    "OPENROUTER_API_KEY": ("openrouter", "OpenRouter", "https://openrouter.ai/keys", True),
    "GEMINI_API_KEY": ("gemini", "Google AI Studio", "https://aistudio.google.com/app/apikey", False),
    "XAI_API_KEY": ("xai", "xAI", "https://console.x.ai/", True),
    "DEEPSEEK_API_KEY": ("deepseek", "DeepSeek", "https://platform.deepseek.com/api_keys", True),
    "OPENAI_API_KEY": ("openai", "OpenAI", "https://platform.openai.com/api-keys", True),
    "ECHO_CLOUD_API_KEY": ("echo-cloud", "Echo Cloud", None, True),
}
CHANNEL_MANAGED_ENV = frozenset({"TELEGRAM_BOT_TOKEN"})
# A declared memory provider (plugins/memory/config_schema.py fields): its config lands in <home>/<name>/config.json.
MEMORY_PROVIDERS = {FAKE_MEMORY_PROVIDER: {
    "label": "Fake Recall", "docs_url": "https://example.com/fake-recall", "description": "Fake vector memory",
    "fields": (
        {"key": "api_key", "label": "API key", "kind": "secret", "env_key": "FAKE_RECALL_API_KEY",
         "description": "Key for the fake recall service", "placeholder": "fr-…"},
        {"key": "region", "label": "Region", "kind": "select", "default": "eu",
         "options": ({"value": "eu", "label": "Europe"}, {"value": "us", "label": "United States"})},
        {"key": "top_k", "label": "Results per query", "kind": "number", "default": "5"},
        {"key": "rerank", "label": "Rerank results", "kind": "bool", "default": "false"},
        {"key": "namespace", "label": "Namespace", "kind": "text", "default": "", "placeholder": "default"},
    )}}


class HttpError(Exception):
    """A FastAPI HTTPException: ``{"detail": detail}`` with ``status``."""

    def __init__(self, status: int, detail: Any) -> None:
        super().__init__(str(detail))
        self.status = status
        self.detail = detail


def body_error(field_name: str, kind: str = "missing") -> HttpError:
    """FastAPI's 422 for a request model field (``missing`` or ``string_type``/``bool_type``/…)."""
    message = {"missing": "Field required", "string_type": "Input should be a valid string",
               "bool_type": "Input should be a valid boolean", "dict_type": "Input should be a valid dictionary",
               "list_type": "Input should be a valid list"}.get(kind, "Invalid input")
    return HttpError(422, [{"type": kind, "loc": ["body", field_name], "msg": message}])


def body_field(body: dict[str, Any], name: str, kind: type, *, required: bool = True, default: Any = None) -> Any:
    if name not in body:
        if required:
            raise body_error(name)
        return default
    value = body[name]
    if value is None and not required:
        return default
    if not isinstance(value, kind):  # bool is not an int here: no int field is read this way
        raise body_error(name, {str: "string_type", bool: "bool_type", dict: "dict_type", list: "list_type"}[kind])
    return value


@dataclass
class FakeProfile:
    """One Hermes home: config.yaml (sparse, as on disk), .env, SOUL.md, profile.yaml metadata, auth store, vault."""

    name: str
    path: str
    config: dict[str, Any] = field(default_factory=dict)
    env: dict[str, str] = field(default_factory=dict)
    soul: str | None = DEFAULT_SOUL
    description: str = ""
    description_auto: bool = False
    display_name: str = ""
    skill_count: int = 0
    # OAuth status cards by provider id (logged in only), the local vault items (with their secrets), the
    # password managers unlocked this session, and declared memory-provider config files.
    oauth: dict[str, dict[str, Any]] = field(default_factory=dict)
    vault: list[dict[str, Any]] = field(default_factory=list)
    unlocked: set[str] = field(default_factory=set)
    memory_files: dict[str, dict[str, Any]] = field(default_factory=dict)

    @property
    def is_default(self) -> bool:
        return self.name == "default"

    def loaded(self) -> dict[str, Any]:
        """load_config(): the defaults with the file over them (a file's MoA preset map replaces the defaults')."""
        merged = deep_merge(DEFAULT_CONFIG, self.config)
        moa = self.config.get("moa")
        if isinstance(moa, dict) and isinstance(moa.get("presets"), dict):
            merged["moa"]["presets"] = copy.deepcopy(moa["presets"])
        return merged

    def main_model(self) -> tuple[str, str]:
        model = self.loaded().get("model")
        if isinstance(model, dict):
            return str(model.get("default") or model.get("name") or ""), str(model.get("provider") or "")
        return str(model or ""), ""

    def save(self, merged: dict[str, Any]) -> None:
        """save_config: write ``merged`` with the defaults stripped (what the user set before stays)."""
        keep = explicit_paths(self.config)
        self.config = strip_defaults(merged, DEFAULT_CONFIG, keep)


def normalize_moa_slot(slot: Any, *, include_enabled: bool = False) -> dict[str, Any] | None:
    """moa_config.py _clean_slot."""
    if moa_slot_problem(slot) is not None:
        return None
    clean: dict[str, Any] = {"provider": str(slot["provider"]).strip(), "model": str(slot["model"]).strip()}
    effort = str(slot.get("reasoning_effort") or "").strip().lower()
    if effort in REASONING_LEVELS:
        clean["reasoning_effort"] = effort
    if include_enabled:
        enabled = slot.get("enabled")
        clean["enabled"] = True if enabled is None else bool(enabled)
    return clean


def moa_slot_problem(slot: Any) -> str | None:
    """moa_config.py _slot_problem."""
    if not isinstance(slot, dict):
        return "must be an object with 'provider' and 'model'"
    provider, model = str(slot.get("provider") or "").strip(), str(slot.get("model") or "").strip()
    if not provider and not model:
        return "provider and model are required"
    if not provider:
        return "provider is required"
    if not model:
        return f"model is required (provider '{provider}' has no model selected)"
    if provider.lower() == "moa":
        return "the Mixture of Agents provider cannot be used inside a preset (recursive MoA)"
    return None


def validate_moa(raw: dict[str, Any]) -> list[str]:
    """moa_config.py validate_moa_payload: what normalize would silently replace."""
    presets_raw = raw.get("presets")
    presets = presets_raw if isinstance(presets_raw, dict) and presets_raw else {"default": raw}
    problems: list[str] = []
    for name, preset in presets.items():
        label = str(name or "").strip() or "(unnamed)"
        if not isinstance(preset, dict):
            problems.append(f"preset '{label}': must be an object")
            continue
        refs = preset.get("reference_models")
        refs = refs if isinstance(refs, list) else [refs] if isinstance(refs, dict) else []
        issues = [(index, moa_slot_problem(slot)) for index, slot in enumerate(refs)]
        problems += [f"preset '{label}' reference {index + 1}: {issue}" for index, issue in issues if issue]
        if all(issue for _, issue in issues):
            problems.append(f"preset '{label}': needs at least one complete reference model")
        if agg := moa_slot_problem(preset.get("aggregator")):
            problems.append(f"preset '{label}' aggregator: {agg}")
    return problems


def normalize_moa_preset(raw: Any) -> dict[str, Any]:
    """moa_config.py _normalize_preset."""
    raw = raw if isinstance(raw, dict) else {}
    refs_raw = raw.get("reference_models")
    refs_raw = refs_raw if isinstance(refs_raw, list) else [refs_raw] if isinstance(refs_raw, dict) else []
    refs = [slot for slot in (normalize_moa_slot(item, include_enabled=True) for item in refs_raw) if slot]
    defaults = DEFAULT_CONFIG["moa"]["presets"]["default"]
    policy = str(raw.get("degraded_reference_policy") or "loud").strip().lower()

    def number(value: Any) -> float | None:
        try:
            return None if value in (None, "") or isinstance(value, bool) else float(value)
        except (TypeError, ValueError):
            return None

    timeout = number(raw.get("reference_timeout"))
    fanout = str(raw.get("fanout") or "").strip().lower()
    if not (fanout in ("per_iteration", "user_turn") or re.fullmatch(r"every_n:([2-9]|\d{2,})", fanout)):
        fanout = "user_turn"
    enabled = raw.get("enabled")
    return {
        "enabled": True if enabled is None else bool(enabled),
        "reference_models": refs or [{**slot, "enabled": True} for slot in defaults["reference_models"]],
        "aggregator": normalize_moa_slot(raw.get("aggregator")) or dict(defaults["aggregator"]),
        "reference_temperature": number(raw.get("reference_temperature")),
        "aggregator_temperature": number(raw.get("aggregator_temperature")),
        "reference_timeout": timeout if timeout and timeout > 0 else None,
        "degraded_reference_policy": policy if policy in ("loud", "silent") else "loud",
        "fanout": fanout}


def normalize_moa(raw: Any) -> dict[str, Any]:
    """moa_config.py normalize_moa_config: named presets plus the flattened default preset."""
    raw = raw if isinstance(raw, dict) else {}
    presets = {str(name).strip(): normalize_moa_preset(preset) for name, preset in (raw.get("presets") or {}).items()
               if str(name or "").strip()} if isinstance(raw.get("presets"), dict) else {}
    if not presets:
        presets["default"] = normalize_moa_preset(raw)
    default_name = str(raw.get("default_preset") or "").strip()
    if default_name not in presets:
        default_name = next(iter(presets))
    active = str(raw.get("active_preset") or "").strip()
    privacy = raw.get("privacy_filter")
    privacy = "full" if privacy is True else str(privacy or "").strip().lower()
    return {"default_preset": default_name, "active_preset": active if active in presets else "", "presets": presets,
            **copy.deepcopy(presets[default_name]),
            "privacy_filter": privacy if privacy in ("display", "full") else ""}


def alert_preferences(value: Any) -> tuple[dict[str, bool] | None, str | None]:
    """The device registration's ``alerts``: ``{approval, clarify, turn_done}`` booleans (None: not sent)."""
    if value is None:
        return None, None
    if not isinstance(value, dict):
        return None, "alerts must be an object of booleans"
    unknown = sorted(set(value) - set(ALERT_KINDS))
    if unknown:
        return None, f"alerts has unknown kinds {unknown}; known: {list(ALERT_KINDS)}"
    if any(not isinstance(flag, bool) for flag in value.values()):
        return None, "alerts values must be booleans"
    return {kind: bool(value.get(kind, False)) for kind in ALERT_KINDS}, None


class AlertVoicePlugin(FakeVoicePlugin):
    """The fake hermes_voice plugin plus the alert half of ``POST /devices``: ``alert_token`` with the ``alerts``
    the user opted into (kept per device, listed by ``GET /status``), and ``GET /debug/alerts``: the alert pushes
    the plugin would have sent (approval / clarify waiting, turn done) and to which alert tokens."""

    def routes(self) -> list[BaseRoute]:
        return [*super().routes(), Route(f"{PLUGIN_PREFIX}/debug/alerts", self.debug_alerts, methods=["GET"])]

    async def register_device(self, request: Request) -> Response:
        if (denied := self.gate(request, post=True)) is not None:
            return denied
        body = await self.json_body(request) or {}
        alerts, problem = alert_preferences(body.get("alerts"))
        if problem is None and alerts is not None and not body.get("alert_token"):
            problem = "alerts needs an alert_token"
        if problem is not None:
            self.log(f"http POST {PLUGIN_PREFIX}/devices -> 422 ({problem})")
            return JSONResponse({"detail": problem}, status_code=422)
        response = await super().register_device(request)
        if response.status_code == 200:
            device = self.devices[body["voip_token"]]
            device["alerts"] = alerts
            shown = "default alerts" if alerts is None else \
                ", ".join(k for k, on in alerts.items() if on) or "no alerts"
            if device.get("alert_token"):
                self.log(f"device {body['voip_token'][:8]}… alert token {device['alert_token'][:8]}… ({shown})")
        return response

    async def status(self, request: Request) -> Response:
        response = await super().status(request)
        if response.status_code != 200:
            return response
        payload = json.loads(bytes(response.body))
        payload["devices"] = [{"voip_token": voip, **device, "alerts": self.alerts_of(device)}
                              for voip, device in self.devices.items()]
        return JSONResponse(payload)

    @staticmethod
    def alerts_of(device: dict[str, Any]) -> dict[str, bool]:
        """What a device gets: its opt-ins, the app's defaults when it sent none, nothing without an alert token."""
        if not device.get("alert_token"):
            return {kind: False for kind in ALERT_KINDS}
        return device.get("alerts") or dict(ALERT_DEFAULTS)

    def alert_targets(self, kind: str) -> list[str]:
        return [device["alert_token"] for device in self.devices.values() if self.alerts_of(device).get(kind)]

    async def debug_alerts(self, request: Request) -> Response:
        """``?session_id=`` (stored or runtime id; omitted: every session) and ``?kind=``: the latest alert as
        ``alert`` ({aps, hermes}, the notification's userInfo), with ``sent_to`` and the whole history."""
        if (denied := self.gate(request, post=False)) is not None:
            return denied
        q = request.query_params
        key = None
        if q.get("session_id"):
            key = self.resolve_key(q["session_id"])
            if key is None:
                return JSONResponse({"detail": "Session not found"}, status_code=404)
        kind = q.get("kind") or None
        if kind is not None and kind not in ALERT_KINDS:
            return JSONResponse({"detail": f"kind must be one of {list(ALERT_KINDS)}"}, status_code=422)
        history = [entry for entry in self.fake.alerts if (key is None or entry["session_id"] == key)
                   and (kind is None or entry["kind"] == kind)]
        last = history[-1] if history else None
        return JSONResponse({"session_id": key, "alert": last["payload"] if last else None,
                             "kind": last["kind"] if last else None, "sent_to": last["sent_to"] if last else [],
                             "alerts": history})


class SettingsFeatures:
    """M3: the settings REST routes (config + schema, models, memory providers, .env keys, OAuth providers, profiles
    and SOUL.md, status), the vault.* and billing.* RPCs, and the alert pushes the voice plugin would send. Mixed
    into FakeHermes, whose sessions, runtimes and logging it uses."""

    sessions: dict[str, StoredSession]
    runtimes: dict[str, Runtime]
    voice_plugin: AlertVoicePlugin

    def _init_settings(self, args: argparse.Namespace) -> None:
        self.profiles: dict[str, FakeProfile] = {}
        for demo in DEMO_PROFILES:
            self.profiles[demo["name"]] = FakeProfile(name=demo["name"], path=demo["path"],
                                                      description=demo["description"], skill_count=demo["skill_count"])
        default, research = self.profiles["default"], self.profiles["research"]
        default.config = {"model": {"default": "fake-hermes", "provider": "fake"}}
        default.env = {"OPENROUTER_API_KEY": "or-demo-fake-0000000000000000", "MY_CUSTOM_TOKEN": "custom-demo"}
        default.oauth["openai-codex"] = {"logged_in": True, "source": "hermes-auth-store",
                                         "source_label": f"{DEMO_HERMES_HOME}/auth.json", "token_preview": "…f4k3",
                                         "expires_at": None, "has_refresh_token": True}
        default.vault.append({"id": "vault_" + secrets.token_hex(6), "kind": "login", "label": "Example site",
                              "origin": "https://example.com", "created_at": "2026-09-01T09:00:00+00:00",
                              "identifier": "demo@example.com", "identifier_type": "email",
                              "secret": {"password": "demo-password"}})
        research.config = {"model": {"default": "echo-1", "provider": "echo-cloud"}}
        research.soul = "You read papers and write short, sourced summaries. (Fake Hermes research SOUL.md)"
        self.sticky_profile = "default"
        self.profile_archives: dict[str, dict[str, Any]] = {}
        self.oauth_sessions: dict[str, dict[str, Any]] = {}
        self.oauth_approve_after = float(getattr(args, "oauth_approve_after", 2.0))
        self.reveals: deque[float] = deque()
        # billing.* (one Nous Portal account): balance, the billing:manage scope, charges by id and key.
        self.billing = {"balance": Decimal("12.34"), "scope": False, "auto_reload": False,
                        "threshold": Decimal("5"), "reload_to": Decimal("25"), "keep_going": False}
        self.charges: dict[str, dict[str, Any]] = {}
        self.charge_keys: dict[str, str] = {}
        self.charge_settle_after = 0.3
        self.alerts: deque[dict[str, Any]] = deque(maxlen=ALERT_MEMORY)

    # ── plumbing ──────────────────────────────────────────────────────────────────────────────────

    def settings_routes(self) -> list[Route]:
        r = self.rest
        return [
            Route("/api/status", self.get_status, methods=["GET"]),
            Route("/api/config", r(self.get_config), methods=["GET"]),
            Route("/api/config", r(self.put_config), methods=["PUT"]),
            # Public like dashboard_auth/public_paths.py PUBLIC_API_PATHS (with /api/status).
            Route("/api/config/schema", r(self.get_schema, public=True), methods=["GET"]),
            Route("/api/config/defaults", r(lambda request, body: copy.deepcopy(DEFAULT_CONFIG), public=True),
                  methods=["GET"]),
            Route("/api/model/info", r(self.model_info, public=True), methods=["GET"]),
            Route("/api/model/options", r(self.rest_model_options), methods=["GET"]),
            Route("/api/model/recommended-default", r(self.recommended_default), methods=["GET"]),
            Route("/api/model/auxiliary", r(self.auxiliary_models), methods=["GET"]),
            Route("/api/model/moa", r(self.get_moa), methods=["GET"]),
            Route("/api/model/moa", r(self.put_moa), methods=["PUT"]),
            Route("/api/model/set", r(self.set_model_assignment), methods=["POST"]),
            Route("/api/memory", r(self.memory_status), methods=["GET"]),
            Route("/api/memory/providers/{name}/config", r(self.memory_provider_config), methods=["GET"]),
            Route("/api/memory/providers/{name}/config", r(self.put_memory_provider_config), methods=["PUT"]),
            Route("/api/env", r(self.get_env), methods=["GET"]),
            Route("/api/env", r(self.put_env), methods=["PUT"]),
            Route("/api/env", r(self.delete_env), methods=["DELETE"]),
            Route("/api/env/reveal", r(self.reveal_env), methods=["POST"]),
            Route("/api/providers/validate", r(self.validate_credential), methods=["POST"]),
            Route("/api/providers/oauth", r(self.oauth_providers), methods=["GET"]),
            Route("/api/providers/oauth/sessions/{session_id}", r(self.cancel_oauth), methods=["DELETE"]),
            Route("/api/providers/oauth/{provider_id}", r(self.disconnect_oauth), methods=["DELETE"]),
            Route("/api/providers/oauth/{provider_id}/start", r(self.start_oauth), methods=["POST"]),
            Route("/api/providers/oauth/{provider_id}/submit", r(self.submit_oauth), methods=["POST"]),
            Route("/api/providers/oauth/{provider_id}/poll/{session_id}", r(self.poll_oauth), methods=["GET"]),
            Route("/api/profiles", r(self.create_profile), methods=["POST"]),
            Route("/api/profiles/active", r(self.active_profile), methods=["GET"]),
            Route("/api/profiles/active", r(self.set_active_profile), methods=["POST"]),
            Route("/api/profiles/import", r(self.import_profile), methods=["POST"]),
            Route("/api/profiles/{name}", r(self.rename_profile), methods=["PATCH"]),
            Route("/api/profiles/{name}", r(self.delete_profile), methods=["DELETE"]),
            Route("/api/profiles/{name}/soul", r(self.get_soul), methods=["GET"]),
            Route("/api/profiles/{name}/soul", r(self.put_soul), methods=["PUT"]),
            Route("/api/profiles/{name}/description", r(self.put_description), methods=["PUT"]),
            Route("/api/profiles/{name}/model", r(self.put_profile_model), methods=["PUT"]),
            Route("/api/profiles/{name}/setup-command", r(self.setup_command), methods=["GET"]),
            Route("/api/profiles/{name}/export", r(self.export_profile), methods=["POST"]),
        ]

    def rest(self, handler: Callable[[Request, dict[str, Any]], Any],
             public: bool = False) -> Callable[[Request], Awaitable[Response]]:
        """Sign-in (unless ``public``) and same-origin checks, the JSON body, HttpError -> ``{"detail"}``, and one log
        line per call (never with a value: bodies here carry API keys)."""
        async def endpoint(request: Request) -> Response:
            name = f"{request.method} {request.url.path}"
            if not public and not self.authed(request):
                log(f"http {name} -> 401")
                return self.unauthorized(request)
            if request.method != "GET" and (problem := self.origin_problem(request)):
                log(f"http {name} -> 403", problem)
                return JSONResponse({"detail": problem}, status_code=403)
            body: dict[str, Any] = {}
            if request.method != "GET":
                raw = await request.body()
                if raw.strip():
                    try:
                        parsed = json.loads(raw)
                    except ValueError:
                        log(f"http {name} -> 422 (body is not JSON)")
                        return JSONResponse({"detail": [{"type": "json_invalid", "loc": ["body"],
                                                         "msg": "JSON decode error"}]}, status_code=422)
                    if not isinstance(parsed, dict):
                        log(f"http {name} -> 422 (body is not an object)")
                        return JSONResponse({"detail": [{"type": "model_attributes_type", "loc": ["body"],
                                                         "msg": "Input should be a valid dictionary"}]},
                                            status_code=422)
                    body = parsed
            try:
                result = handler(request, body)
                if inspect.isawaitable(result):
                    result = await result
            except HttpError as exc:
                log(f"http {name} -> {exc.status} {short(exc.detail, 160)}")
                return JSONResponse({"detail": exc.detail}, status_code=exc.status)
            if isinstance(result, Response):
                return result
            log(f"http {name} -> 200")
            return JSONResponse(result)
        return endpoint

    def profile_named(self, name: str) -> FakeProfile:
        """web_server_profiles.py _resolve_profile_dir: the name as given (no lowercasing) must be a valid id, else
        400; a missing profile is 404."""
        if name != "default":
            if not PROFILE_ID.match(name):
                raise HttpError(400, self.invalid_name(name))
            if name in RESERVED_PROFILE_NAMES:
                raise HttpError(400, f"Profile name {name!r} is reserved — it collides with either the Hermes "
                                     "installation itself or a common system binary.  Pick a different name.")
        if name not in self.profiles:
            raise HttpError(404, f"Profile '{name}' does not exist.")
        return self.profiles[name]

    def scoped(self, request: Request, body: dict[str, Any] | None = None) -> FakeProfile:
        """``?profile=`` (or the body's ``profile``, which wins): None, "" and "current" are the dashboard's own."""
        name = str((body or {}).get("profile") or request.query_params.get("profile") or "").strip()
        return self.profiles["default"] if not name or name.lower() == "current" else self.profile_named(name)

    @staticmethod
    def invalid_name(name: str) -> str:
        suggestion = re.sub(r"[^a-z0-9_-]+", "-", name.strip().lower()).strip("-_")[:64]
        suggestion = suggestion if PROFILE_ID.match(suggestion) else "my-work"
        return (f"{name!r} is not a valid profile name. {PROFILE_NAME_RULE} (for example: {suggestion}). Then run "
                f"`hermes profile create {suggestion}`.")

    def canonical_name(self, name: Any) -> str:
        """profiles.py _canon_valid: normalize then validate (ValueError -> 400)."""
        if not isinstance(name, str) or not name.strip():
            raise HttpError(400, "profile name cannot be empty")
        canon = "default" if name.strip().casefold() == "default" else name.strip().lower()
        if canon == "default":
            return canon
        if not PROFILE_ID.match(canon):
            raise HttpError(400, self.invalid_name(canon))
        if canon in RESERVED_PROFILE_NAMES:
            raise HttpError(400, f"Profile name {canon!r} is reserved — it collides with either the Hermes "
                                 "installation itself or a common system binary.  Pick a different name.")
        return canon

    # ── status ────────────────────────────────────────────────────────────────────────────────────

    async def get_status(self, request: Request) -> Response:
        """status.py /api/status: the public liveness probe (no sign-in), on a gated bind (no paths)."""
        requested = (request.query_params.get("profile") or "").strip()
        if requested and requested.lower() != "current":
            try:
                self.profile_named(requested)
            except HttpError as exc:
                return JSONResponse({"detail": exc.detail}, status_code=exc.status)
        active = sum(1 for rt in self.runtimes.values() if rt.running)
        components = {"gateway": {"status": "ok", "state": "running"},
                      "dashboard": {"status": "ok"}, "storage": {"status": "ok"},
                      "platforms": {"status": "ok", "configured": 0, "connected": 0}}
        log("http GET /api/status -> 200")
        return JSONResponse({
            "version": FAKE_VERSION, "release_date": FAKE_RELEASE_DATE, "config_version": CONFIG_VERSION,
            "latest_config_version": CONFIG_VERSION, "can_update_hermes": False, "gateway_running": True,
            "gateway_state": "running", "gateway_platforms": {}, "gateway_exit_reason": None,
            "gateway_updated_at": datetime.now(timezone.utc).isoformat(), "gateway_heartbeat_stale_s": None,
            "gateway_shared_with": None, "active_agents": active, "gateway_busy": active > 0,
            "gateway_drainable": True, "restart_drain_timeout": 60, "active_sessions": len(self.runtimes),
            "auth_required": True, "auth_providers": ["basic"], "auth_flows": ["cookie", "native_pkce"],
            "nous_session_valid": "unknown", "shared_profile_warning": False, "components": components,
            "overall": "ok", "memory": {"pressure": "ok"}, "disk": {"pressure": "ok"},
            "profiles": list(self.profiles), "parked_profiles": [], "gateway_mode": "single",
            "multiplex_standalone_reason": None})

    # ── config ────────────────────────────────────────────────────────────────────────────────────

    def get_config(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """config_env.py GET /api/config: load_config() (or the raw file with include_defaults=false), the model
        flattened to its string plus model_context_length, ``_`` keys dropped."""
        profile = self.scoped(request)
        include = request.query_params.get("include_defaults", "true").lower() not in ("false", "0", "no")
        config = copy.deepcopy(profile.loaded() if include else profile.config)
        model = config.get("model")
        if isinstance(model, dict):
            context = model.get("context_length", 0)
            config["model"] = model.get("default", model.get("name", ""))
            config["model_context_length"] = context if isinstance(context, int) else 0
        else:
            config["model_context_length"] = 0
        return {key: value for key, value in config.items() if not key.startswith("_")}

    def get_schema(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        self.scoped(request)
        return {"fields": CONFIG_SCHEMA, "category_order": CATEGORY_ORDER}

    def put_config(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """config_env.py PUT /api/config {config, profile?}: deep-merged over the file. The fake also checks each
        schema field's value against its type (the real server saves whatever comes)."""
        config = body_field(body, "config", dict)
        profile = self.scoped(request, body)
        current = profile.loaded()
        if problem := self.config_problem(config, flatten(current)):
            raise HttpError(400, problem)
        incoming = self.denormalize(profile, config)
        profile.save(deep_merge(profile.config, incoming))
        return {"ok": True}

    @staticmethod
    def config_problem(config: dict[str, Any], current: dict[str, Any], prefix: str = "") -> str | None:
        for key, value in config.items():
            path = f"{prefix}.{key}" if prefix else key
            spec = CONFIG_SCHEMA.get(path)
            if path in ("_model_meta", "model") and (path == "_model_meta" or isinstance(value, (dict, str))):
                continue
            if spec is None:
                if isinstance(value, dict):
                    if problem := SettingsFeatures.config_problem(value, current, path):
                        return problem
                elif value is not None and any(name.startswith(path + ".") for name in CONFIG_SCHEMA):
                    return f"{path} is a section: send its fields, not {shown(path, value)}"
                continue
            if DEFAULT_FLAT.get(path, _MISSING) is None and not isinstance(value, (dict, list)):
                continue  # a field whose default is null takes any scalar (its schema type is only a guess)
            kind = spec["type"]
            expected = {"boolean": (bool,), "number": (int, float), "string": (str,), "list": (list,),
                        "object": (dict,), "select": (str,)}.get(kind, (object,))
            if not isinstance(value, expected) or kind == "number" and isinstance(value, bool):
                return f"Invalid value for {path}: expected a {kind}, got {shown(path, value)}"
            allowed = (*spec.get("options", ()), *DESKTOP_ENUM_EXTRAS.get(path, ()), current.get(path),
                       DEFAULT_FLAT.get(path), *(("",) if spec.get("clearable") else ()))
            if kind == "select" and value not in allowed:
                return f"Invalid value for {path}: {shown(path, value)} is not one of {spec['options']}"
        return None

    def denormalize(self, profile: FakeProfile, config: dict[str, Any]) -> dict[str, Any]:
        """web_server_config.py _denormalize_config_from_web: the flat model string and context override go back
        into the ``model`` dict; a model another provider serves switches the provider."""
        config = dict(config)
        config.pop("_model_meta", None)
        context_sent = "model_context_length" in config
        context = config.pop("model_context_length", 0)
        try:
            context = int(context) if not isinstance(context, bool) else 0
        except (TypeError, ValueError):
            context = 0
        model_value = config.get("model")
        has_model = isinstance(model_value, str) and bool(model_value)
        if not (has_model or context_sent):
            return config
        disk_model = copy.deepcopy(profile.loaded().get("model"))
        if isinstance(disk_model, dict):
            if has_model:
                previous, provider = str(disk_model.get("default") or ""), str(disk_model.get("provider") or "")
                if model_value != previous and provider:
                    serving = self.provider_of(model_value)
                    if serving and serving != provider:
                        disk_model["provider"] = serving
                disk_model["default"] = model_value
            if context_sent:
                if context > 0:
                    disk_model["context_length"] = context
                else:
                    disk_model.pop("context_length", None)
            config["model"] = disk_model
        elif context_sent and context > 0:
            default = model_value if has_model else disk_model if isinstance(disk_model, str) else ""
            config["model"] = {"default": default, "context_length": context}
        return config

    # ── models ────────────────────────────────────────────────────────────────────────────────────

    def model_info(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """models.py GET /api/model/info: detected vs configured context window and models.dev capabilities."""
        profile = self.scoped(request)
        model, provider = profile.main_model()
        if not model:
            return {"model": "", "provider": provider, "auto_context_length": 0, "config_context_length": 0,
                    "effective_context_length": 0, "capabilities": {}}
        model_cfg = profile.loaded().get("model")
        configured = model_cfg.get("context_length") if isinstance(model_cfg, dict) else None
        configured = configured if isinstance(configured, int) and configured > 0 else 0
        auto = DEMO_CONTEXT.get(model, 0)
        caps = {}
        if self.provider_of(model):
            fast, reasoning = self.capabilities(model)
            caps = {"supports_tools": True, "supports_vision": model != "fake-hermes-mini",
                    "supports_reasoning": reasoning, "context_window": auto, "max_output_tokens": 32_000,
                    "model_family": model.split("-")[0]}
        return {"model": model, "provider": provider, "auto_context_length": auto, "config_context_length": configured,
                "effective_context_length": configured or auto, "capabilities": caps}

    def rest_model_options(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """models.py GET /api/model/options: the model.options RPC's shape, current = the profile's main model."""
        model, provider = self.scoped(request).main_model()
        options = self.model_options({})
        for row in options["providers"]:
            row["is_current"] = row["slug"] == provider
        return {**options, "model": model, "provider": provider}

    def recommended_default(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        slug = (request.query_params.get("provider") or "").strip().lower()
        self.scoped(request)
        models = next((list(m) for s, _n, m in DEMO_PROVIDERS if s == slug), [])
        model = next((m for m in models if m not in EXPENSIVE_MODELS), models[0] if models else "")
        return {"provider": slug, "model": model, "free_tier": None}

    def auxiliary_models(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """models.py GET /api/model/auxiliary: every slot's own stored provider/model, and the main model."""
        profile = self.scoped(request)
        aux = profile.loaded().get("auxiliary") or {}

        def row(slot: str) -> dict[str, Any]:
            block = aux.get(slot) if isinstance(aux.get(slot), dict) else {}
            base_url = str(block.get("base_url") or "")
            return {"task": slot, "provider": str(block.get("provider") or "auto"),
                    "model": str(block.get("model") or ""), "base_url": base_url,
                    "reasoning_effort": str(block.get("reasoning_effort") or "") or None,
                    "local_endpoint": base_url.startswith(("http://localhost", "http://127.0.0.1"))}

        model, provider = profile.main_model()
        return {"tasks": [row(slot) for slot in AUX_TASK_SLOTS], "main": {"provider": provider, "model": model}}

    def get_moa(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        return normalize_moa(self.scoped(request).loaded().get("moa"))

    def put_moa(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """models.py PUT /api/model/moa: incomplete slots are refused (422), the submitted preset map is
        authoritative, privacy_filter survives a round trip."""
        profile = self.scoped(request, body)
        presets = body.get("presets") if isinstance(body.get("presets"), dict) else {}
        controls = ("reference_models", "aggregator", "reference_temperature", "aggregator_temperature",
                    "reference_timeout", "degraded_reference_policy", "fanout", "enabled")
        if presets:
            raw: dict[str, Any] = {"default_preset": body.get("default_preset") or "default",
                                   "active_preset": body.get("active_preset") or "",
                                   "presets": {name: {k: p.get(k) for k in controls if k in p}
                                               for name, p in presets.items() if isinstance(p, dict)}}
            bad = [name for name, p in presets.items() if not isinstance(p, dict)]
            if bad:
                raise HttpError(422, [{"type": "model_type", "loc": ["body", "presets", bad[0]],
                                       "msg": "Input should be a valid dictionary"}])
        else:
            raw = {k: body.get(k) for k in controls if k in body}
        if problems := validate_moa(raw):
            raise HttpError(422, "Invalid MoA config: " + "; ".join(problems))
        existing = profile.config.get("moa")
        if isinstance(existing, dict) and "privacy_filter" in existing:
            raw["privacy_filter"] = existing["privacy_filter"]
        normalized = normalize_moa(raw)
        stored = {k: normalized[k] for k in ("default_preset", "active_preset", "presets", "privacy_filter")}
        merged = profile.loaded()
        merged["moa"] = {**{k: v for k, v in (merged.get("moa") or {}).items() if k not in stored}, **stored}
        profile.save(merged)
        return {"ok": True, **normalized}

    def set_model_assignment(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """models.py POST /api/model/set {scope, provider, model, task?, reasoning_effort?, base_url?, api_key?,
        confirm_expensive_model?}."""
        scope = body_field(body, "scope", str).strip().lower()
        provider, model = body_field(body, "provider", str).strip(), body_field(body, "model", str).strip()
        task = str(body.get("task") or "").strip().lower()
        base_url, api_key = str(body.get("base_url") or "").strip(), str(body.get("api_key") or "").strip()
        if scope not in ("main", "auxiliary"):
            raise HttpError(400, "scope must be 'main' or 'auxiliary'")
        profile = self.scoped(request, body)
        if model and not body.get("confirm_expensive_model") and model in EXPENSIVE_MODELS:
            return {"ok": False, "scope": scope, "provider": provider, "model": model, "confirm_required": True,
                    "confirm_message": f"{model} costs $15.00/M input and $75.00/M output tokens. Use it anyway?"}
        config = profile.loaded()
        if scope == "main":
            if not provider or not model:
                raise HttpError(400, "provider and model required for main")
            if provider not in ("custom", "local") and self.provider_of(model) != provider:
                known = next((list(m) for s, _n, m in DEMO_PROVIDERS if s == provider), None)
                raise HttpError(400, f"Unknown provider '{provider}'." if known is None else
                                f"Model '{model}' is not available from {provider}. Available: {', '.join(known)}")
            block = config.get("model") if isinstance(config.get("model"), dict) else {}
            block = {k: v for k, v in block.items() if k not in ("base_url", "api_key", "api_mode")} \
                if block.get("provider") != provider else dict(block)
            block.update(default=model, provider=provider)
            if base_url:
                block["base_url"] = base_url
            if api_key:
                block["api_key"] = api_key
            config["model"] = block
            profile.save(config)
            aux = config.get("auxiliary") or {}
            stale = [{"task": slot, "provider": str(aux[slot].get("provider")),
                      "model": str(aux[slot].get("model") or "")}
                     for slot in AUX_TASK_SLOTS if isinstance(aux.get(slot), dict)
                     and str(aux[slot].get("provider") or "").lower() not in ("", "auto", "main", provider)]
            return {"ok": True, "scope": "main", "provider": provider, "model": model,
                    "base_url": block.get("base_url", ""), "gateway_tools": [], "stale_aux": stale}
        effort: Any = _MISSING
        if "reasoning_effort" in body:
            effort = body["reasoning_effort"]
            if effort is not None:
                effort = str(effort).strip().lower()
                effort = {"off": "none", "disabled": "none"}.get(effort, effort)
                if effort not in REASONING_LEVELS:
                    raise HttpError(400, "reasoning_effort must be one of: none, " + ", ".join(REASONING_LEVELS[1:]))
        aux = config.setdefault("auxiliary", {})
        if task == "__reset__":
            for slot in AUX_TASK_SLOTS:
                block = aux.setdefault(slot, {})
                block.update(provider="auto", model="")
                for key in ("reasoning_effort", "base_url", "api_key"):
                    block.pop(key, None)
            profile.save(config)
            return {"ok": True, "scope": "auxiliary", "reset": True}
        if not provider:
            raise HttpError(400, "provider required for auxiliary")
        targets = [task] if task else list(AUX_TASK_SLOTS)
        for slot in targets:
            if slot not in AUX_TASK_SLOTS:
                raise HttpError(400, f"unknown auxiliary task: {slot}")
            block = aux.setdefault(slot, {})
            previous = str(block.get("provider") or "").lower()
            block.update(provider=provider, model=model)
            if base_url:
                block["base_url"] = base_url
                if api_key:
                    block["api_key"] = api_key
            elif provider.lower() != previous and provider.lower() != "custom":
                block.pop("base_url", None)
                block.pop("api_key", None)
            if effort is None:
                if DEFAULT_CONFIG["auxiliary"].get(slot, {}).get("reasoning_effort"):
                    block["reasoning_effort"] = ""
                else:
                    block.pop("reasoning_effort", None)
            elif effort is not _MISSING:
                block["reasoning_effort"] = effort
        profile.save(config)
        result = {"ok": True, "scope": "auxiliary", "tasks": targets, "provider": provider, "model": model}
        if effort is not _MISSING:
            result["reasoning_effort"] = effort
        return result

    # ── memory providers ──────────────────────────────────────────────────────────────────────────

    def memory_status(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """ops.py GET /api/memory: the active provider, every discovered one, the built-in files' sizes."""
        profile = self.scoped(request)
        active = str((profile.loaded().get("memory") or {}).get("provider") or "")
        providers = []
        for name, spec in MEMORY_PROVIDERS.items():
            configured = bool(profile.env.get("FAKE_RECALL_API_KEY")) or name in profile.memory_files
            providers.append({"name": name, "description": spec["description"], "available": True,
                              "configured": configured, "status": "ready" if configured else "needs_config",
                              "setup": {"pip_dependencies": [], "python_dependencies_declared": True,
                                        "external_dependencies": [], "required_env": ["FAKE_RECALL_API_KEY"],
                                        "dependencies_installed": True}})
        return {"active": active, "providers": providers, "builtin_files": {"memory": 812, "user": 245}}

    def memory_provider_config(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """memory_providers.py GET .../config?surface=declared: the declared fields with their values (secrets
        only as is_set)."""
        name = request.path_params["name"]
        self.check_memory_name(name)
        profile = self.scoped(request)
        spec = MEMORY_PROVIDERS.get(name)
        if spec is None:
            return {"name": name, "label": name, "docs_url": "", "fields": []}
        stored = profile.memory_files.get(name, {})
        fields = []
        for f in spec["fields"]:
            entry = {"key": f["key"], "label": f["label"], "kind": f["kind"], "description": f.get("description", ""),
                     "info": "", "placeholder": f.get("placeholder", ""), "inline": False, "group": "",
                     "options": [{"value": o["value"], "label": o["label"], "description": ""}
                                 for o in f.get("options", ())]}
            if f["kind"] == "secret":
                entry.update(value="", is_set=bool(profile.env.get(f["env_key"])))
            else:
                native = stored.get(f["key"])
                value = ("true" if native else "false") if f["kind"] == "bool" and native is not None else \
                    json.dumps(native) if isinstance(native, (dict, list)) else \
                    str(native) if native is not None else f.get("default", "")
                entry.update(value=value, is_set=bool(value))
            fields.append(entry)
        return {"name": name, "label": spec["label"], "docs_url": spec["docs_url"], "fields": fields}

    def put_memory_provider_config(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """memory_providers.py PUT .../config?surface=declared {values}: secrets to .env, the rest coerced into
        the provider's config.json; memory.provider becomes this provider."""
        name = request.path_params["name"]
        self.check_memory_name(name)
        profile = self.scoped(request)
        spec = MEMORY_PROVIDERS.get(name)
        if spec is None:
            raise HttpError(404, f"Unknown memory provider: {name}")
        values = body.get("values") or {}
        if not isinstance(values, dict):
            raise body_error("values", "dict_type")
        text = {k: "" if v is None else ("true" if v else "false") if isinstance(v, bool) else
                json.dumps(v) if isinstance(v, (dict, list)) else str(v) for k, v in values.items()}
        stored = dict(profile.memory_files.get(name, {}))
        for f in spec["fields"]:
            if f["key"] not in text:
                continue
            value = text[f["key"]].strip()
            if f["kind"] == "secret":
                if value:
                    profile.env[f["env_key"]] = value
                continue
            if f["kind"] == "select":
                value = value or f.get("default", "")
                if value not in [o["value"] for o in f["options"]]:
                    raise HttpError(400, f"Invalid value for '{f['key']}'")
                stored[f["key"]] = value
            elif f["kind"] == "bool":
                stored[f["key"]] = value.lower() in ("1", "true", "yes", "on")
            elif not value:
                stored.pop(f["key"], None)
            elif f["kind"] == "number":
                try:
                    number = float(value)
                except ValueError:
                    raise HttpError(400, f"Invalid number for '{f['key']}'") from None
                stored[f["key"]] = int(number) if number.is_integer() else number
            else:
                stored[f["key"]] = value
        profile.memory_files[name] = stored
        config = profile.loaded()
        if (config.get("memory") or {}).get("provider") != name:
            config.setdefault("memory", {})["provider"] = name
            profile.save(config)
        return {"ok": True}

    @staticmethod
    def check_memory_name(name: str) -> None:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", name or ""):
            raise HttpError(404, f"Unknown memory provider: {name}")

    # ── .env keys ─────────────────────────────────────────────────────────────────────────────────

    def get_env(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """config_env.py GET /api/env: every known variable (OPTIONAL_ENV_VARS, then catalog providers, then the
        .env's own keys as custom secrets), values only as redacted previews."""
        profile = self.scoped(request)

        def row(name: str, info: dict[str, Any], custom: bool = False) -> dict[str, Any]:
            value = profile.env.get(name)
            catalog = CATALOG_ENV.get(name)
            return {
                "is_set": bool(value), "redacted_value": credential_preview(value),
                "description": info.get("description") or (f"{catalog[1]} API key" if catalog else ""),
                "url": info["url"] if info.get("url") is not None else (catalog[2] if catalog else None),
                "category": info.get("category") or ("provider" if catalog else ""),
                "is_password": info.get("password", bool(catalog)), "tools": info.get("tools", []),
                "advanced": info.get("advanced", False), "channel_managed": name in CHANNEL_MANAGED_ENV,
                "provider": catalog[0] if catalog else "", "provider_label": catalog[1] if catalog else "",
                "provider_profiles": [], "provider_primary": bool(catalog and catalog[3]), "custom": custom}

        result = {name: row(name, info) for name, info in OPTIONAL_ENV_VARS.items()}
        result.update({name: row(name, {}) for name in CATALOG_ENV if name not in result})
        for name in profile.env:
            if name not in result and name not in CHANNEL_MANAGED_ENV:
                result[name] = {**row(name, {}, custom=True), "category": "custom", "is_password": True}
        return result

    def put_env(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """config_env.py PUT /api/env {key, value, profile?, provider_setup?}: never a redacted preview."""
        key, value = body_field(body, "key", str), body_field(body, "value", str)
        if is_credential_preview(value):
            raise HttpError(400, REDACTED_WRITE_DETAIL)
        profile = self.scoped(request, body)
        self.check_env_name(key)
        profile.env[key] = value
        log(f"env {key} set for profile {profile.name} ({len(value)} characters)")
        return {"ok": True, "key": key, "config_updates": []}

    def delete_env(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """config_env.py DELETE /api/env {key, profile?}: 404 when nothing held it."""
        key = body_field(body, "key", str)
        profile = self.scoped(request, body)
        self.check_env_name(key)
        if profile.env.pop(key, None) is None:
            raise HttpError(404, f"{key} not found in .env")
        provider = CATALOG_ENV.get(key, ("",))[0]
        return {"ok": True, "key": key, "removed": True, "pool_pruned": 0, "providers": [provider] if provider else [],
                "config_scrubbed": [], "found": True}

    def reveal_env(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """config_env.py POST /api/env/reveal {key}: at most 5 per 30 s."""
        key = body_field(body, "key", str)
        profile = self.scoped(request, body)
        now = time.time()
        while self.reveals and self.reveals[0] <= now - REVEAL_WINDOW:
            self.reveals.popleft()
        if len(self.reveals) >= REVEAL_MAX:
            raise HttpError(429, "Too many reveal requests. Try again shortly.")
        self.reveals.append(now)
        if key not in profile.env:
            raise HttpError(404, f"{key} not found in .env")
        return {"key": key, "value": profile.env[key]}

    @staticmethod
    def check_env_name(key: str) -> None:
        if not ENV_NAME.match(key):
            raise HttpError(400, f"Invalid environment variable name: {key!r}")
        if key.upper() in ENV_DENYLIST or key.upper().startswith(ENV_DENY_PREFIXES):
            raise HttpError(400, f"Environment variable {key!r} is on the writer denylist. Names that influence "
                                 "subprocess execution (LD_PRELOAD, PYTHONPATH, PATH, EDITOR, ...) or Hermes runtime "
                                 "location and security policy (HERMES_HOME, HERMES_YOLO_MODE, ...) cannot be "
                                 "persisted via the env writer. If you really need this, edit ~/.hermes/.env "
                                 "directly.")

    def validate_credential(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """config_env.py POST /api/providers/validate {key, value}: the fake never calls a provider. A probed
        key starting with "bad" (or shorter than 8) is rejected, one containing "offline" can't be checked."""
        key, value = body_field(body, "key", str).strip(), body_field(body, "value", str).strip()
        if not value:
            return {"ok": False, "reachable": True, "message": "Enter a value first."}
        if key == "OPENAI_BASE_URL":
            url = value.rstrip("/") + ("" if value.rstrip("/").endswith("/v1") else "/v1")
            return {"ok": False, "reachable": False, "message": f"Could not reach {url}/models."}
        if key not in CREDENTIAL_PROBES:
            return {"ok": True, "reachable": False, "message": ""}
        if "offline" in value.lower():
            return {"ok": False, "reachable": False, "message": "Could not reach the provider to verify the key."}
        if value.lower().startswith("bad") or len(value) < 8:
            return {"ok": False, "reachable": True,
                    "message": "That API key was rejected. Double-check it and try again."}
        return {"ok": True, "reachable": True, "message": ""}

    # ── OAuth providers ───────────────────────────────────────────────────────────────────────────

    def oauth_status(self, profile: FakeProfile, provider_id: str) -> dict[str, Any]:
        return dict(profile.oauth.get(provider_id) or {"logged_in": False})

    def oauth_providers(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """oauth.py GET /api/providers/oauth: the catalog with each provider's status (token preview only)."""
        profile = self.scoped(request)
        rows = []
        for p in OAUTH_PROVIDERS:
            status = self.oauth_status(profile, p["id"])
            hint = self.disconnect_hint(p, status)
            rows.append({"id": p["id"], "name": p["name"], "flow": p["flow"], "cli_command": p["cli_command"],
                         "docs_url": p["docs_url"], "disconnect_hint": hint, "disconnect_command": None,
                         "disconnectable": hint is None, "status": status})
        return {"providers": rows}

    @staticmethod
    def disconnect_hint(provider: dict[str, Any], status: dict[str, Any]) -> str | None:
        if provider["flow"] == "external" and provider["id"] != "anthropic":
            return "Managed by that provider's CLI; remove it there."
        if status.get("source") == "env_var":
            return "Remove the API key from Settings → Keys instead."
        return None

    def oauth_profile(self, request: Request) -> str | None:
        name = (request.query_params.get("profile") or "").strip()
        if not name or name.lower() == "current":
            return None
        self.profile_named(name)
        return name

    def start_oauth(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """oauth.py POST .../{provider}/start: a device-code session the fake approves after
        ``oauth_approve_after`` seconds (a user code starting "DENY" is denied instead)."""
        provider_id = request.path_params["provider_id"]
        profile_name = self.oauth_profile(request)
        now = time.time()
        for sid in [s for s, sess in self.oauth_sessions.items() if sess["created_at"] < now - OAUTH_SESSION_TTL]:
            self.oauth_sessions.pop(sid, None)
        entry = next((p for p in OAUTH_PROVIDERS if p["id"] == provider_id), None)
        if entry is None:
            raise HttpError(400, f"Unknown provider {provider_id}")
        if entry["flow"] == "external":
            raise HttpError(400, f"{provider_id} uses an external CLI; run `{entry['cli_command']}` manually")
        sid = secrets.token_urlsafe(16)
        code = f"{secrets.token_hex(2).upper()}-{secrets.token_hex(2).upper()}"
        self.oauth_sessions[sid] = {"session_id": sid, "provider": provider_id, "flow": "device_code",
                                    "profile": profile_name, "created_at": now, "status": "pending",
                                    "error_message": None, "user_code": code, "expires_at": now + OAUTH_SESSION_TTL}
        return {"session_id": sid, "flow": "device_code", "user_code": code,
                "verification_url": f"{OAUTH_VERIFICATION_URL}?code={code}", "expires_in": OAUTH_SESSION_TTL,
                "poll_interval": 1}

    def submit_oauth(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        body_field(body, "session_id", str)
        body_field(body, "code", str)
        raise HttpError(400, f"submit not supported for {request.path_params['provider_id']}")

    async def poll_oauth(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """oauth.py GET .../poll/{session_id}?wait=: long-polls (25 s cap) until the session leaves pending."""
        provider_id, sid = request.path_params["provider_id"], request.path_params["session_id"]
        profile_name = self.oauth_profile(request)
        sess = self.oauth_sessions.get(sid)
        if sess is None:
            raise HttpError(404, "Session not found or expired")
        if sess["provider"] != provider_id:
            raise HttpError(400, "Provider mismatch for session")
        if sess["profile"] != profile_name:
            raise HttpError(400, "OAuth session profile mismatch")
        try:
            wait = min(max(float(request.query_params.get("wait") or 0), 0.0), 25.0)
        except ValueError:
            wait = 0.0
        deadline = time.monotonic() + wait
        while self.settle_oauth(sess) == "pending" and time.monotonic() < deadline:
            await asyncio.sleep(0.05)
        return {"session_id": sid, "status": sess["status"], "error_message": sess["error_message"],
                "expires_at": sess["expires_at"], "reason": sess.get("reason"),
                "account_email": sess.get("account_email"), "model": None, "handoff": None, "handoff_status": None,
                "retryable": sess.get("retryable"), "retry_after": None}

    def settle_oauth(self, sess: dict[str, Any]) -> str:
        if sess["status"] != "pending" or sess.get("cancelled"):
            return "cancelled" if sess.get("cancelled") else sess["status"]
        if time.time() >= sess["expires_at"]:
            sess.update(status="expired", error_message="The code expired before it was approved.")
        elif time.time() - sess["created_at"] >= self.oauth_approve_after:
            if sess["user_code"].startswith("DENY"):
                sess.update(status="denied", error_message="Access was denied.", reason="denied", retryable=True)
            else:
                profile = self.profiles.get(sess["profile"] or "default")
                if profile is not None:
                    profile.oauth[sess["provider"]] = {
                        "logged_in": True, "source": "hermes-auth-store", "source_label": f"{profile.path}/auth.json",
                        "token_preview": "…" + secrets.token_hex(2), "expires_at": None, "has_refresh_token": True}
                sess.update(status="approved", account_email="demo@example.com")
            log(f"oauth {sess['provider']} session {sess['session_id'][:8]}… {sess['status']}")
        return sess["status"]

    def cancel_oauth(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        sid = request.path_params["session_id"]
        profile_name = self.oauth_profile(request)
        sess = self.oauth_sessions.get(sid)
        if sess is None:
            return {"ok": False, "message": "session not found"}
        if sess["profile"] != profile_name:
            raise HttpError(400, "OAuth session profile mismatch")
        sess["cancelled"] = True
        self.oauth_sessions.pop(sid, None)
        return {"ok": True, "session_id": sid}

    def disconnect_oauth(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """oauth.py DELETE .../{provider}: 400 for CLI-managed providers, 409 when nothing was stored."""
        provider_id = request.path_params["provider_id"]
        profile = self.scoped(request)
        entry = next((p for p in OAUTH_PROVIDERS if p["id"] == provider_id), None)
        if entry is None:
            raise HttpError(400, f"Unknown provider: {provider_id}. Available: "
                                 f"{', '.join(sorted(p['id'] for p in OAUTH_PROVIDERS))}")
        if hint := self.disconnect_hint(entry, self.oauth_status(profile, provider_id)):
            raise HttpError(400, f"{entry['name']} cannot be disconnected automatically. {hint}")
        if profile.oauth.pop(provider_id, None) is None:
            raise HttpError(409, f"No stored credentials were removed for {entry['name']}.")
        return {"ok": True, "provider": provider_id}

    # ── profiles ──────────────────────────────────────────────────────────────────────────────────

    def profile_row(self, profile: FakeProfile) -> dict[str, Any]:
        """profiles.py _profile_to_dict."""
        model, provider = profile.main_model()
        return {"name": profile.name, "path": profile.path, "is_default": profile.is_default, "model": model or None,
                "provider": provider or None, "has_env": bool(profile.env), "skill_count": profile.skill_count,
                "gateway_running": False, "description": profile.description,
                "description_auto": profile.description_auto, "display_name": profile.display_name, "bot_title": "",
                "distribution_name": None, "distribution_version": None, "distribution_source": None,
                "has_alias": not profile.is_default, "role": None}

    def create_profile(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """profiles.py POST /api/profiles {name, soul?, clone_from?, clone_all?, description?, provider?, model?}:
        a fresh profile gets the default SOUL.md and an empty config; a clone copies the source's config, .env
        and SOUL.md (the soul in the request wins)."""
        raw_name = body_field(body, "name", str)
        soul = body_field(body, "soul", str, required=False)
        source_name = str(body.get("clone_from") or "").strip()
        if not source_name and (body.get("clone_all") or body.get("clone_from_default")):
            source_name = "default"
        if body.get("no_skills") and source_name:
            raise HttpError(400, "--no-skills is mutually exclusive with --clone / --clone-from / --clone-all "
                                 "(cloning explicitly copies skills from the source profile).")
        canon = self.canonical_name(raw_name)
        if canon == "default":
            raise HttpError(400, "Cannot create a profile named 'default' — it is the built-in profile (~/.hermes).")
        if canon in self.profiles:
            raise HttpError(400, f"A profile named '{canon}' already exists. Switch to it with `hermes profile use "
                                 f"{canon}`, see all profiles with `hermes profile list`, or choose a different name.")
        profile = FakeProfile(name=canon, path=f"{DEMO_HERMES_HOME}/profiles/{canon}",
                              description=str(body.get("description") or "").strip())
        if source_name:
            source = self.profiles.get(self.canonical_name(source_name))
            if source is None:
                raise HttpError(400, f"Profile '{source_name}' does not exist. Create it with: hermes profile create "
                                     f"{source_name}")
            profile.config, profile.env = copy.deepcopy(source.config), dict(source.env)
            profile.soul, profile.skill_count = source.soul, source.skill_count
        else:
            profile.skill_count = 0 if body.get("no_skills") else 12
        if soul is not None:
            profile.soul = soul
        model_set, model_error = False, ""
        provider, model = str(body.get("provider") or "").strip(), str(body.get("model") or "").strip()
        if provider and model:
            if self.provider_of(model) == provider:
                profile.config = deep_merge(profile.config, {"model": {"default": model, "provider": provider}})
                model_set = True
            else:
                model_error = f"Model '{model}' is not available from {provider}."
        self.profiles[canon] = profile
        return {"ok": True, "name": raw_name, "path": profile.path, "model_set": model_set, "model_error": model_error,
                "mcp_written": 0, "skills_disabled": 0, "hub_installs": [], "soul_set": soul is not None}

    def active_profile(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        return {"active": self.sticky_profile, "current": "default"}

    def set_active_profile(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        canon = self.canonical_name(body_field(body, "name", str))
        if canon not in self.profiles:
            raise HttpError(404, f"Profile '{canon}' does not exist. Create it with: hermes profile create {canon}")
        self.sticky_profile = canon
        return {"ok": True, "active": canon}

    def rename_profile(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """profiles.py PATCH /api/profiles/{name} {new_name}: the default profile only gets a display name."""
        new_name = body_field(body, "new_name", str)
        old = self.canonical_name(request.path_params["name"])
        if old == "default":
            if not new_name.strip():
                raise HttpError(400, "Display name cannot be empty.")
            self.profiles["default"].display_name = new_name.strip()
            return {"ok": True, "name": "default", "display_name": new_name.strip(),
                    "path": self.profiles["default"].path}
        new = self.canonical_name(new_name)
        if new == "default":
            raise HttpError(400, "Cannot rename to 'default' — it is reserved.")
        if old not in self.profiles:
            raise HttpError(404, f"No profile named '{old}'. See your profiles with: hermes profile list")
        if new in self.profiles:
            raise HttpError(400, f"A profile named '{new}' already exists. Switch to it with `hermes profile use "
                                 f"{new}`, see all profiles with `hermes profile list`, or choose a different name.")
        profile = self.profiles.pop(old)
        profile.name, profile.path = new, f"{DEMO_HERMES_HOME}/profiles/{new}"
        self.profiles[new] = profile
        for stored in self.sessions.values():
            if stored.profile == old:
                stored.profile = new
        if self.sticky_profile == old:
            self.sticky_profile = new
        return {"ok": True, "name": new, "path": profile.path}

    def delete_profile(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        canon = self.canonical_name(request.path_params["name"])
        if canon == "default":
            raise HttpError(400, "Cannot delete the default profile (~/.hermes).\nTo remove everything, use: "
                                 "hermes uninstall")
        profile = self.profiles.pop(canon, None)
        if profile is None:
            raise HttpError(404, f"No profile named '{canon}'. See your profiles with: hermes profile list")
        if self.sticky_profile == canon:
            self.sticky_profile = "default"
        return {"ok": True, "path": profile.path}

    def get_soul(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        profile = self.profile_named(request.path_params["name"])
        return {"content": profile.soul or "", "exists": profile.soul is not None}

    def put_soul(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        profile = self.profile_named(request.path_params["name"])
        profile.soul = body_field(body, "content", str)
        log(f"SOUL.md of {profile.name} saved ({len(profile.soul)} characters)")
        return {"ok": True}

    def put_description(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        profile = self.profile_named(request.path_params["name"])
        profile.description, profile.description_auto = str(body.get("description") or "").strip(), False
        return {"ok": True, "description": profile.description, "description_auto": False}

    def put_profile_model(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        profile = self.profile_named(request.path_params["name"])
        provider, model = body_field(body, "provider", str).strip(), body_field(body, "model", str).strip()
        if not provider or not model:
            raise HttpError(400, "provider and model are required")
        if self.provider_of(model) != provider:
            raise HttpError(400, f"Model '{model}' is not available from {provider}.")
        config = profile.loaded()
        block = config["model"] if isinstance(config.get("model"), dict) else {}
        config["model"] = {**block, "default": model, "provider": provider}
        profile.save(config)
        return {"ok": True, "provider": provider, "model": model}

    def setup_command(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        profile = self.profile_named(request.path_params["name"])
        return {"command": "hermes setup" if profile.is_default else f"{profile.name} setup"}

    def export_profile(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        """profiles.py POST .../export {extra_files?, output?}: an archive path on the host (credentials and the
        .env stay out). The fake keeps the archive in memory for POST /api/profiles/import."""
        extra = body.get("extra_files") or {}
        if not isinstance(extra, dict) or any(not isinstance(v, str) for v in extra.values()):
            raise body_error("extra_files", "dict_type")
        canon = self.canonical_name(request.path_params["name"])
        if canon not in self.profiles:
            raise HttpError(404, f"No profile named '{canon}'. See your profiles with: hermes profile list")
        profile = self.profiles[canon]
        output = str(body.get("output") or "").strip()
        archive = output if output.endswith((".tar.gz", ".tgz")) else (output + ".tar.gz") if output else \
            f"{DEMO_HERMES_HOME}/profile-exports/{canon}-{time.strftime('%Y%m%d-%H%M%S')}.tar.gz"
        self.profile_archives[archive] = {
            "root": canon, "config": copy.deepcopy(profile.config), "soul": profile.soul,
            "description": profile.description, "skill_count": profile.skill_count, "extra_files": dict(extra)}
        return {"ok": True, "archive": archive}

    def import_profile(self, request: Request, body: dict[str, Any]) -> dict[str, Any]:
        archive = body_field(body, "archive", str).strip()
        if not archive:
            raise HttpError(400, "archive path is required")
        snapshot = self.profile_archives.get(archive)
        if snapshot is None:
            raise HttpError(404, f"Archive not found: {archive}")
        canon = self.canonical_name(str(body.get("name") or "").strip() or snapshot["root"])
        if canon == "default":
            raise HttpError(400, "Cannot import as 'default' — that is the built-in root profile (~/.hermes). Specify "
                                 "a different name: hermes profile import <archive> --name <name>")
        if canon in self.profiles:
            raise HttpError(400, f"A profile named '{canon}' already exists. Switch to it with `hermes profile use "
                                 f"{canon}`, see all profiles with `hermes profile list`, or choose a different name.")
        profile = FakeProfile(name=canon, path=f"{DEMO_HERMES_HOME}/profiles/{canon}",
                              config=copy.deepcopy(snapshot["config"]), soul=snapshot["soul"],
                              description=snapshot["description"], skill_count=snapshot["skill_count"])
        self.profiles[canon] = profile
        return {"ok": True, "name": canon, "path": profile.path, "desktop": None}

    # ── vault.* and billing.* RPCs ────────────────────────────────────────────────────────────────

    def settings_methods(self, conn: Conn, params: dict[str, Any]) -> dict[str, Callable[[], Any]]:
        return {
            "vault.list": lambda: self.vault_list(params),
            "vault.sources": lambda: self.vault_sources(params),
            "vault.source.set": lambda: self.vault_source_set(params),
            "vault.unlock": lambda: self.vault_unlock(params),
            "vault.lock": lambda: self.vault_lock(params),
            "vault.add": lambda: self.vault_add(params),
            "vault.remove": lambda: self.vault_remove(params),
            "billing.state": lambda: self.billing_state(params),
            "billing.charge": lambda: self.billing_charge(params),
            "billing.charge_status": lambda: self.billing_charge_status(params),
            "billing.auto_reload": lambda: self.billing_auto_reload(params),
            "billing.keep_going_on_credits": lambda: self.billing_keep_going(params),
            "billing.step_up": lambda: self.billing_step_up(conn, params),
        }

    def rpc_profile(self, params: dict[str, Any]) -> FakeProfile:
        name = str(params.get("profile") or "").strip()
        if not name or name.lower() == "current":
            return self.profiles["default"]
        try:
            return self.profile_named(name)
        except HttpError as exc:
            raise RpcError(4004, str(exc.detail)) from None

    def manager_enabled(self, profile: FakeProfile, name: str) -> bool:
        installed = dict((n, i) for n, _d, i in PASSWORD_MANAGERS).get(name, False)
        return installed and (profile.loaded().get("vault") or {}).get(name, {}).get("enabled") is not False

    def vault_list(self, params: dict[str, Any]) -> dict[str, Any]:
        """Metadata only, across the local vault and the unlocked password managers."""
        profile = self.rpc_profile(params)
        items = [{**{k: v for k, v in item.items() if k != "secret" and v is not None}, "backend": "local"}
                 for item in profile.vault]
        if "onepassword" in profile.unlocked and self.manager_enabled(profile, "onepassword"):
            items.append({"id": "op_fake0001", "kind": "login", "label": "Example forum (1Password)",
                          "origin": "https://forum.example.com", "created_at": "2026-08-12T10:00:00+00:00",
                          "identifier": "demo", "identifier_type": "username", "backend": "onepassword"})
        return {"items": items}

    def vault_sources(self, params: dict[str, Any]) -> dict[str, Any]:
        profile = self.rpc_profile(params)
        rows = [{"name": "local", "display_name": "Hermes vault", "enabled": True, "needs_unlock": False,
                 "unlocked": True, "installed": True}]
        for name, display, installed in PASSWORD_MANAGERS:
            enabled = self.manager_enabled(profile, name)
            rows.append({"name": name, "display_name": display, "enabled": enabled, "needs_unlock": True,
                         "unlocked": enabled and name in profile.unlocked, "installed": installed})
        return {"sources": rows}

    def vault_source_set(self, params: dict[str, Any]) -> dict[str, Any]:
        profile = self.rpc_profile(params)
        name = str(params.get("name") or "")
        if name not in {n for n, _d, _i in PASSWORD_MANAGERS}:
            raise RpcError(VAULT_ERROR, f"unknown vault source: {name}")
        enabled = bool(params.get("enabled"))
        config = profile.loaded()
        section = config.setdefault("vault", {}).setdefault(name, {})
        if enabled:
            section.pop("enabled", None)
            profile.config.get("vault", {}).get(name, {}).pop("enabled", None)
        else:
            section["enabled"] = False
            profile.unlocked.discard(name)
        profile.save(config)
        return {"name": name, "enabled": enabled}

    def vault_unlock(self, params: dict[str, Any]) -> dict[str, Any]:
        profile = self.rpc_profile(params)
        name, password = str(params.get("name") or ""), str(params.get("password") or "")
        if not self.manager_enabled(profile, name):
            raise RpcError(VAULT_ERROR, f"{name} is not an enabled password manager")
        if not password:
            raise RpcError(VAULT_ERROR, "master password is required")
        if password == "wrong":
            raise RpcError(VAULT_ERROR, "[ERROR] invalid master password")
        profile.unlocked.add(name)
        return {"name": name, "unlocked": True}

    def vault_lock(self, params: dict[str, Any]) -> dict[str, Any]:
        profile = self.rpc_profile(params)
        name = params.get("name")
        if name:
            profile.unlocked.discard(str(name))
        else:
            profile.unlocked.clear()
        return {"locked": True}

    def vault_add(self, params: dict[str, Any]) -> dict[str, Any]:
        """agent/vault_store.py add_item: login = origin + identifier_type/identifier (metadata) + password."""
        profile = self.rpc_profile(params)
        secret = params.get("secret")
        if not isinstance(secret, dict) or not secret:
            raise RpcError(VAULT_ERROR, "secret payload is required")
        kind, label = str(params.get("kind") or ""), str(params.get("label") or "").strip()
        if kind not in VAULT_KINDS:
            raise RpcError(VAULT_ERROR, f"unknown vault kind {kind!r} (expected one of {VAULT_KINDS})")
        if not label:
            raise RpcError(VAULT_ERROR, "label is required")
        item: dict[str, Any] = {"id": f"vault_{uuid.uuid4().hex[:12]}", "kind": kind, "label": label, "origin": None,
                                "created_at": datetime.now(timezone.utc).isoformat()}
        secret = dict(secret)
        if kind == "login":
            if not params.get("origin"):
                raise RpcError(VAULT_ERROR, "origin is required for login items")
            item["origin"] = normalize_origin(str(params["origin"]))
            id_type = secret.pop("identifier_type", None)
            if id_type not in LOGIN_IDENTIFIER_TYPES:
                raise RpcError(VAULT_ERROR, f"identifier_type must be one of {LOGIN_IDENTIFIER_TYPES}")
            identifier = str(secret.pop("identifier", "") or "").strip()
            if not identifier or not secret.get("password"):
                raise RpcError(VAULT_ERROR, "login items require identifier and password")
            item.update(identifier=identifier, identifier_type=id_type)
            if otp := str(secret.get("otp_secret") or "").replace(" ", ""):
                item["has_otp"] = True
            secret = {"password": str(secret["password"]), **({"otp_secret": otp} if otp else {})}
        else:
            secret = {k: str(v) for k, v in secret.items() if k in VAULT_FIELDS[kind] and str(v or "").strip()}
            if missing := [f for f in VAULT_REQUIRED[kind] if f not in secret]:
                raise RpcError(VAULT_ERROR, f"{kind} items require {', '.join(missing)}")
            if params.get("origin"):
                item["origin"] = normalize_origin(str(params["origin"]))
        item["secret"] = secret
        profile.vault.append(item)
        return {"id": item["id"]}

    def vault_remove(self, params: dict[str, Any]) -> dict[str, Any]:
        profile = self.rpc_profile(params)
        item_id = str(params.get("id") or "")
        if not item_id:
            raise RpcError(VAULT_ERROR, "id is required")
        before = len(profile.vault)
        profile.vault[:] = [item for item in profile.vault if item["id"] != item_id]
        return {"removed": len(profile.vault) < before}

    def billing_state(self, params: dict[str, Any]) -> dict[str, Any]:
        """billing_view.py _serialize_billing_state (the contract's fields) for a signed-in Nous Portal account."""
        self.rpc_profile(params)
        b = self.billing
        presets = [Decimal("10"), Decimal("25"), Decimal("50")]
        return {
            "ok": True, "logged_in": True, "free_tier_account": False, "free_tier_model": None,
            "org_name": "Fake Org", "org_slug": "fake-org", "role": "owner", "is_admin": True,
            "can_change_plan": True, "can_charge": True, "balance_usd": str(b["balance"]),
            "balance_display": format_money(b["balance"]), "cli_billing_enabled": True,
            "charge_presets": [str(p) for p in presets], "charge_presets_display": [format_money(p) for p in presets],
            "min_usd": "5", "max_usd": "500",
            "card": {"brand": "visa", "last4": "4242", "masked": "•••• 4242", "display": "Visa •••• 4242",
                     "resolved_via": None},
            "payment_method": {"kind": "card", "brand": "visa", "last4": "4242", "wallet": None, "resolved_via": None},
            "monthly_cap": {"limit_usd": "200", "limit_display": "$200", "spent_this_month_usd": "37.5",
                            "spent_display": "$37.50", "is_default_ceiling": True},
            "auto_reload": {"enabled": b["auto_reload"], "threshold_usd": str(b["threshold"]),
                            "threshold_display": format_money(b["threshold"]), "reload_to_usd": str(b["reload_to"]),
                            "reload_to_display": format_money(b["reload_to"]), "card": {"kind": "canonical"}},
            "portal_url": "https://example.com/fake-portal/billing", "error": None, "usage": None}

    def billing_denied(self, extra: dict[str, Any] | None = None) -> dict[str, Any] | None:
        """billing:manage routes before billing.step_up: the insufficient_scope envelope."""
        if self.billing["scope"]:
            return None
        return {"ok": False, "error": "insufficient_scope", "message": BILLING_SCOPE_MESSAGE, "portal_url": None,
                "retry_after": None, "payload": {}, "actor": None, "code": None, "recovery": None, **(extra or {})}

    def billing_charge(self, params: dict[str, Any]) -> dict[str, Any]:
        """billing.charge {amount_usd, idempotency_key?}: pending until charge_settle_after, then settled."""
        self.rpc_profile(params)
        if params.get("amount_usd") is None:
            return {"ok": False, "error": "invalid_request", "message": "amount_usd is required"}
        key = str(params.get("idempotency_key") or uuid.uuid4().hex)
        if denied := self.billing_denied({"idempotency_key": key}):
            return denied
        if key in self.charge_keys:
            return {"ok": True, "charge_id": self.charge_keys[key], "idempotency_key": key}
        try:
            amount = Decimal(str(params["amount_usd"]))
        except ArithmeticError:
            amount = Decimal("-1")
        if not Decimal("5") <= amount <= Decimal("500"):
            return {"ok": False, "error": "invalid_amount", "message": "Choose an amount between $5 and $500.",
                    "portal_url": None, "retry_after": None, "payload": {}, "actor": None, "code": None,
                    "recovery": None, "idempotency_key": key}
        charge_id = "ch_" + secrets.token_hex(8)
        self.charges[charge_id] = {"amount": amount, "created": time.time(), "settled_at": None}
        self.charge_keys[key] = charge_id
        return {"ok": True, "charge_id": charge_id, "idempotency_key": key}

    def billing_charge_status(self, params: dict[str, Any]) -> dict[str, Any]:
        self.rpc_profile(params)
        charge_id = str(params.get("charge_id") or "")
        if not charge_id:
            return {"ok": False, "error": "invalid_charge_id", "message": "charge_id is required"}
        charge = self.charges.get(charge_id)
        if charge is None:
            return {"ok": False, "error": "not_found", "message": f"No charge {charge_id}."}
        if charge["settled_at"] is None and time.time() - charge["created"] >= self.charge_settle_after:
            charge["settled_at"] = datetime.now(timezone.utc).isoformat()
            self.billing["balance"] += charge["amount"]
        return {"ok": True, "status": "settled" if charge["settled_at"] else "pending",
                "amount_usd": str(charge["amount"]), "settled_at": charge["settled_at"], "reason": None}

    def billing_auto_reload(self, params: dict[str, Any]) -> dict[str, Any]:
        self.rpc_profile(params)
        if params.get("threshold") is None or params.get("top_up_amount") is None:
            return {"ok": False, "error": "invalid_request", "message": "threshold and top_up_amount are required"}
        if denied := self.billing_denied():
            return denied
        try:
            threshold, reload_to = Decimal(str(params["threshold"])), Decimal(str(params["top_up_amount"]))
        except ArithmeticError:
            return {"ok": False, "error": "invalid_request", "message": "threshold and top_up_amount must be numbers"}
        self.billing.update(auto_reload=bool(params.get("enabled")), threshold=threshold, reload_to=reload_to)
        return {"ok": True}

    def billing_keep_going(self, params: dict[str, Any]) -> dict[str, Any]:
        self.rpc_profile(params)
        if not isinstance(params.get("enabled"), bool):
            return {"ok": False, "error": "invalid_request", "message": "enabled (bool) is required"}
        if denied := self.billing_denied():
            return denied
        self.billing["keep_going"] = params["enabled"]
        return {"ok": True}

    async def billing_step_up(self, conn: Conn, params: dict[str, Any]) -> dict[str, Any]:
        """billing.step_up: the device-flow URL and code go out as billing.step_up.verification (to the session,
        or to this connection), then the fake grants billing:manage."""
        self.rpc_profile(params)
        sid = str(params.get("session_id") or "")
        payload = {"verification_url": f"{OAUTH_VERIFICATION_URL}?scope=billing", "user_code": "BILL-1234"}
        if sid in self.runtimes:
            await self.emit_to(sid, "billing.step_up.verification", payload)
        else:
            await conn.send({"jsonrpc": "2.0", "method": "event", "params": {
                "type": "billing.step_up.verification", "session_id": sid, "payload": payload}})
        await asyncio.sleep(0.1)
        self.billing["scope"] = True
        return {"ok": True, "granted": True}

    # ── alert pushes ──────────────────────────────────────────────────────────────────────────────

    def note_alert(self, stored: StoredSession, kind: str, body: str, *, request: ServerRequest | None = None) -> None:
        """Record the alert push the hermes_voice plugin would send for ``stored`` (``GET /debug/alerts``), and the
        alert tokens that opted into ``kind``. The payload is the notification's userInfo."""
        hermes: dict[str, Any] = {"kind": kind, "session_id": stored.key, "profile": stored.profile}
        if request is not None:
            hermes["request_id"] = request.id
        if kind == "approval" and request is not None:
            hermes["choices"] = list(request.params.get("choices") or ["once", "session", "always", "deny"])
        if kind == "clarify" and request is not None:
            keys = ("qid", "question", "choices", "multi_select")
            hermes["questions"] = [{k: q[k] for k in keys if q.get(k) is not None}
                                   for q in request.params.get("questions") or [] if q.get("qid") not in request.locked]
        titles = {"approval": "Approval needed", "clarify": "Hermes has a question"}
        title = titles.get(kind) or stored.title or "Hermes"
        payload = {"aps": {"alert": {"title": title, "body": body}, "category": ALERT_CATEGORIES[kind],
                           "thread-id": stored.key, "sound": "default"}, "hermes": hermes}
        sent_to = self.voice_plugin.alert_targets(kind)
        self.alerts.append({"at": time.time(), "session_id": stored.key, "kind": kind, "payload": payload,
                            "sent_to": sent_to})
        log(f"alert {kind} for {stored.key} "
            + (f"-> {len(sent_to)} device(s)" if sent_to else "(no device opted in)"))

    def note_request_alert(self, rt: Runtime, req: ServerRequest) -> None:
        stored = self.sessions.get(rt.key)
        if stored is None or req.method not in ("approval", "clarify"):
            return
        if req.method == "approval":
            command = str(req.params.get("command") or "")
            description = str(req.params.get("description") or "")
            body = f"Run {command}?" + (f" ({description})" if description else "") if command else description
        else:
            first = next(iter(req.params.get("questions") or []), {})
            body = str(first.get("question") or "")
            if first.get("choices"):
                body += "\n" + " · ".join(first["choices"])
        self.note_alert(stored, req.method, body or "Hermes is waiting for you.", request=req)

    def note_turn_done(self, rt: Runtime, text: str, status: str) -> None:
        stored = self.sessions.get(rt.key)
        if stored is None:
            return
        body = text.strip().replace("\n", " ")
        if status == "error":
            body = "The turn failed: " + body
        self.note_alert(stored, "turn_done", body[:177] + "…" if len(body) > 178 else body or "Done.")


class FakeHermes(ChatFeatures, SettingsFeatures):
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
        self.voice_plugin = AlertVoicePlugin(self, args)
        self._init_settings(args)
        self._init_chat(args)
        self._seed()
        if self.seed_mode == "demo":
            self._seed_demo()

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
            "profile_name": stored.profile if stored else "default", "lazy": False, **self.chat_info(stored),
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
                           ("pending_approval", pending), ("open_requests", self.open_requests(rt.sid)),
                           ("todo_state", stored.todo_state if stored else None)):
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
        archived, order = q.get("archived", "exclude"), q.get("order", "recent")
        if archived not in ("exclude", "only", "include"):
            return JSONResponse({"detail": "archived must be one of: exclude, only, include"}, status_code=400)
        if order not in ("created", "recent"):
            return JSONResponse({"detail": "order must be one of: created, recent"}, status_code=400)
        profile = q.get("profile") or "all"
        rows = [s.row() for s in self.sessions.values()
                if self.listed(s, min_messages=min_messages, archived=archived, profile=profile)]
        included = [q["source"]] if q.get("source") else csv_list(q.get("sources"))
        excluded = set(csv_list(q.get("exclude_sources")))
        rows = [r for r in rows if r["source"] not in excluded and (not included or r["source"] in included)]
        key = "last_active" if order == "recent" else "started_at"
        rows.sort(key=lambda r: r[key], reverse=True)
        window = pinned_window(rows, offset, limit)
        totals = {name: sum(r["profile"] == name for r in rows) for name in self.profiles
                  if profile == "all" or name == profile}
        log(f"http GET /api/profiles/sessions -> 200 ({len(window)} of {len(rows)})")
        return JSONResponse({"sessions": window, "total": len(rows), "profile_totals": totals,
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
        return JSONResponse({"session_id": sid, "profile": stored.profile, "messages": page,
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
        if method in ("vault.add", "vault.unlock"):
            return {k: f"<{len(json.dumps(v))} chars>" if k in ("secret", "password") else v for k, v in params.items()}
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
            "session.close": lambda: self.session_close(params),
            "approval.respond": lambda: self.approval_respond(params),
            "request.answer": lambda: self.request_answer(params),
            "clarify.lock": lambda: self.clarify_lock(params),
        }.get(method) or self.chat_methods(conn, params).get(method) or self.settings_methods(conn, params).get(method)
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
        self.apply_create_params(stored, params)
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
                "started_at": stored.started_at, "status": "idle",
                **({"todo_state": stored.todo_state} if stored.todo_state else {})}

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
        truncating = any(params.get(k) is not None for k in
                         ("truncate_before_user_ordinal", "truncate_before_row_id", "truncate_before_message_id"))
        if truncating:
            survivors = self.truncate_for_submit(rt, stored, params)
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
        row = self.add_row(stored, "user", self.stage_turn_images(rt, text))
        rt.running = True
        rt.turn_started_at = time.time()
        rt.loop_task = asyncio.create_task(self.turn_loop(rt, text))
        return {"status": "streaming", "user_row_id": row["id"], **({"survivor_user_row_ids": survivors} if truncating else {})}

    def truncate_for_submit(self, rt: Runtime, stored: StoredSession, params: dict[str, Any]) -> list[int]:
        """methods_prompt.py _truncate_history_for_submit by durable row id: a rewind drops the target prompt and
        everything after it, then the submitted text runs from there. Returns the surviving user row ids."""
        if rt.running:
            # A rewind never lands as a queued or steered prompt: the client stops the turn and retries.
            raise RpcError(4009, "session busy")
        if not params.get("confirm_truncate"):
            raise RpcError(4029, "truncation parameters require confirm_truncate=true; an ordinary prompt.submit must "
                                 "not drop session history")
        row_id = params.get("truncate_before_row_id")
        if not isinstance(row_id, int) or isinstance(row_id, bool):
            raise RpcError(4004, "the fake rewinds by truncate_before_row_id only")
        index = next((i for i, m in enumerate(stored.messages) if m["id"] == row_id and m["role"] == "user"), None)
        if index is None:
            raise RpcError(4018, f"target row_id {row_id} not found for session {rt.sid} (in-memory + durable)")
        if index == 0 and not params.get("confirm_empty_truncate"):
            raise RpcError(4028, "truncation would erase the entire session transcript; resubmit with "
                                 "confirm_empty_truncate=true if this is intended")
        log(f"prompt.submit: truncating {stored.key} {len(stored.messages)} -> {index} messages")
        del stored.messages[index:]
        rt.failed_turn = rt.inflight = None
        stored.todo_state = None
        return [m["id"] for m in stored.messages if m["role"] == "user"]

    async def session_close(self, params: dict[str, Any]) -> dict[str, Any]:
        """methods_session.py session.close: the runtime is popped and torn down (its turn and prompts end)."""
        rt = self.runtimes.pop(str(params.get("session_id") or ""), None)
        if rt is None:
            return {"closed": False}
        for task in (rt.turn_task, rt.loop_task, rt.reap_task):
            if task is not None and not task.done():
                task.cancel()
        await self.cancel_requests(rt.sid, "session_closed")
        self.resolve_approvals(rt, "deny", resolve_all=True)
        rt.running = False
        stored = self.sessions.get(rt.key)
        if stored is not None and not stored.persisted and not stored.messages:
            del self.sessions[rt.key]
        log(f"session.close {rt.sid}")
        return {"closed": True}

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
        self.note_request_alert(rt, req)  # M3: the alert push the voice plugin would send
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
                await self.emit(rt, "message.complete", {"text": "", "status": "interrupted",
                                                         "usage": self.usage_snapshot(self.sessions[rt.key])})
            rt.turn_task = None
            rt.running = False
            rt.inflight = None
            rt.turn_started_at = None
            self.after_turn(rt)
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
        rt.notes, rt.turn_images, rt.failed_turn = TurnNotes(images=rt.turn_images), [], None
        replies: list[str] = []
        streamed = ""
        try:
            await self.emit(rt, "message.start")
            for segment in segments(text):
                if (handled := await self.voice_plugin.handle(rt, stored, segment)) is not None:
                    replies.append(handled)  # the fake plugin's start_call / end_call turns (fake_voice_plugin.py)
                    continue
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
            replies += self.turn_attachment_notes(rt, text)
            final = "\n\n".join(reply for reply in replies if reply)
            for chunk in chunks(final, STREAM_CHUNKS):
                await asyncio.sleep(STREAM_SECONDS / STREAM_CHUNKS)
                streamed += chunk
                rt.inflight["assistant"] = streamed
                await self.emit(rt, "message.delta", {"text": chunk})
            # Live usage reaches the client before the close (server.py _start_usage_ticker).
            self.count_turn_usage(stored, rt, final)
            snapshot = self.usage_snapshot(stored)
            await self.emit(rt, "session.usage", {"usage": snapshot})
            reasoning = rt.notes.reasoning
            if rt.notes.error is not None:
                await self.fail_turn(rt, stored, final, snapshot)
            else:
                self.add_row(stored, "assistant", final, finish_reason="stop",
                             **({"reasoning": reasoning} if reasoning else {}))
                await self.emit(rt, "message.complete", {"text": final, "usage": snapshot, "status": "complete",
                                                         **({"reasoning": reasoning} if reasoning else {})})
            if stored.title is None:
                stored.title = title_for(text)
                await self.emit(rt, "session.title", {"session_id": stored.key, "title": stored.title})
            self.note_turn_done(rt, final, "error" if rt.notes.error is not None else "complete")
        except asyncio.CancelledError:
            log(f"turn on {rt.sid} interrupted")
            if streamed:
                self.add_row(stored, "assistant", streamed, finish_reason="interrupted")
            await self.emit(rt, "message.complete", {"text": streamed, "usage": self.usage_snapshot(stored),
                                                     "status": "interrupted",
                                                     **({"partial": True} if streamed else {})})

    async def reply_to(self, rt: Runtime, stored: StoredSession, segment: str) -> str:
        """Plain text: echo it, or run the chat demos and ask the client what its trigger words call for."""
        demos = {"approve": self.demo_approval, "clarify": self.demo_clarify, "secret": self.demo_secret,
                 "sudo": self.demo_sudo, "window": self.demo_window}
        lowered = segment.lower()
        shows = [demo for word, demo in self.chat_demos().items() if word in lowered]
        asks = [demo for word, demo in demos.items() if word in lowered]
        if not asks and not shows:
            return f"Echo: {segment}"
        return "\n\n".join(part for part in [await demo(rt, stored) for demo in (*shows, *asks)] if part)

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
    """session.resume ``messages`` (tui_gateway/session_history.py _history_to_messages): {role, text} rows, tool
    rows with their args (edit tools also with the stored result), reasoning and display kinds."""
    out: list[dict[str, Any]] = []
    rows = stored.messages if stored else []
    results = {row.get("tool_call_id"): row for row in rows if row["role"] == "tool"}
    for row in rows:
        if row["role"] in ("user", "assistant") and row.get("content"):
            message = {"role": row["role"], "text": row["content"], "timestamp": row["timestamp"], "row_id": row["id"]}
            for key in ("reasoning", "display_kind", "display_metadata"):
                if row.get(key):
                    message[key] = row[key]
            out.append(message)
        for call in row.get("tool_calls") or []:
            fn = call.get("function") or {}
            name, args = fn.get("name"), json.loads(fn.get("arguments") or "{}")
            tool: dict[str, Any] = {"role": "tool", "name": name, "context": tool_context(name, args)[:80],
                                    "tool_call_id": call.get("id"), **({"args": args} if args else {})}
            if name in ("write_file", "patch") and (result := results.get(call.get("id"))) is not None:
                tool["content"] = result.get("content")
            out.append(tool)
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
        *fake.voice_plugin.routes(),
        # M2: chat screens.
        Route("/api/profiles", fake.list_profiles, methods=["GET"]),
        Route("/api/profiles/sessions/sidebar", fake.sidebar_sessions, methods=["GET"]),
        Route("/api/sessions/search", fake.search_sessions, methods=["GET"]),
        Route("/api/sessions/{session_id}", fake.manage_session, methods=["PATCH", "DELETE"]),
        Route("/api/media", fake.get_media, methods=["GET"]),
        # M3: settings, profiles, providers.
        *fake.settings_routes(),
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
    FakeVoicePlugin.add_arguments(parser)
    parser.add_argument("--oauth-approve-after", type=float, default=2.0,
                        help="seconds before a provider sign-in (device code) started from Settings is approved")
    parser.add_argument("--seed", choices=("demo", "minimal"), default="demo",
                        help="stored chats at start: demo (two projects, two profiles, pinned/archived/unread, cron "
                             "and Telegram chats) or minimal (only the welcome chat)")
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
