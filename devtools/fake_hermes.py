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

Run (from hermes-voice-mcp, to reuse its venv):
  uv run python ../devtools/fake_hermes.py --port 9311 --voice-url http://127.0.0.1:8765 --voice-token <token>
Sign in as test / test. Every RPC, event, server request and speak result is logged to stdout with the prefix FAKE.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
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

from fake_voice_plugin import FakeVoicePlugin  # the fake hermes_voice plugin: /api/plugins/hermes_voice/*, start_call

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
        return [{"text": f"@{p['name']}", "display": f"@{p['name']}", "meta": p["description"] or "agent profile"}
                for p in DEMO_PROFILES if p["name"].startswith(prefix.lower())]

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
        profiles = [{"name": p["name"], "path": p["path"], "is_default": p["is_default"], "model": "fake-hermes",
                     "provider": "fake", "has_env": True, "skill_count": p["skill_count"], "gateway_running": False,
                     "description": p["description"], "description_auto": False, "display_name": "",
                     "bot_title": "", "distribution_name": None, "distribution_version": None,
                     "distribution_source": None, "has_alias": False, "role": None} for p in DEMO_PROFILES]
        log("http GET /api/profiles -> 200")
        return JSONResponse({"profiles": profiles})

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
        names = [p["name"] for p in DEMO_PROFILES if scope == "all" or p["name"] == scope]
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


class FakeHermes(ChatFeatures):
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
        self.voice_plugin = FakeVoicePlugin(self, args)
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
        totals = {p["name"]: sum(r["profile"] == p["name"] for r in rows) for p in DEMO_PROFILES
                  if profile == "all" or p["name"] == profile}
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
        }.get(method) or self.chat_methods(conn, params).get(method)
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
