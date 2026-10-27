"""Who may ring the user's phone, how often, and when.

Only a new ring is checked: speaking into a call the conversation already has is always allowed. Defaults:
dashboard / desktop / TUI / CLI conversations and the owner's own messaging DMs may call; scheduled jobs, subagents,
group chats, finite runs nobody is at the keyboard for (``oneshot``: ``hermes chat -q``, ``hermes -z``) and
third-party integrations (``tool``) may not; at most 3 rings per conversation per 10 minutes and 10 per hour
overall; no quiet hours.
Every decision and every call's outcome goes to ``<HERMES_HOME>/hermes-voice/rings.jsonl``.

The policy runs in the dashboard process's hub for every process (calls from other processes come in over
``hubsock.py``), so the rate limits and quiet hours count every ring, wherever it came from. Who the owner of a
messaging DM is gets decided in the process that hosts the chat (``gateway_owner``), where the gateway's own
allowlist and pairing records are.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional

from . import hermes
from .config import QuietHours, Settings

logger = logging.getLogger("hermes_voice")

# Surfaces that are not a human messaging channel (mirrors Hermes' NON_MESSAGING_SESSION_SURFACES, plus the
# dashboard and "oneshot": a finite `hermes chat -q` / `hermes -z` run, see hermes.unattended_source).
NON_MESSAGING = frozenset({
    "", "api_server", "cli", "codex", "desktop", "gateway", "kanban", "local", "msgraph_webhook", "tool", "tui",
    "webhook", "dashboard", "oneshot",
})
PLATFORM_NAME = re.compile(r"[a-z][a-z0-9_]{1,31}")
RING_LOG_MAX_LINES = 1000
CONFIRM_WINDOW_S = 900.0


@dataclass(frozen=True)
class Decision:
    allowed: bool
    reason: str = ""
    note: str = ""


class Policy:
    def __init__(
        self,
        settings: Callable[[], Settings],
        log_dir: Callable[[], Path] = hermes.state_dir,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.settings = settings
        self.log_dir = log_dir
        self.clock = clock
        self.lock = threading.Lock()
        self.rings: deque[tuple[float, str]] = deque(maxlen=1000)
        # Quiet-hours confirmation: when a conversation was refused, and when its user last wrote.
        self.refused_at: dict[str, float] = {}
        self.user_turn_at: dict[str, float] = {}

    # ── decisions ────────────────────────────────────────────────────────────────────────────────────────

    def check(self, origin: hermes.Origin) -> Decision:
        decision = self._decide(origin)
        if not decision.allowed:
            self.log({"event": "refused", "session_id": origin.session_id, "source": _surface(origin),
                      "reason": decision.reason})
        return decision

    def _decide(self, origin: hermes.Origin) -> Decision:
        cfg = self.settings().policy
        if origin.is_cron and not cfg.allow_cron:
            return Decision(False, "cron", "Scheduled jobs can't call the user. Report in text instead.")
        if origin.is_subagent and not cfg.allow_subagents:
            return Decision(False, "subagent",
                            "Only the main conversation can call the user. Report back; it can call.")
        surface = _surface(origin)
        if surface not in NON_MESSAGING:
            if origin.chat_type != "dm":
                if not cfg.allow_groups:
                    return Decision(False, "group", "Calls can't be placed from group chats.")
            elif not (cfg.allow_owner_dms and is_owner(origin, cfg.owner_ids)):
                return Decision(False, "not_owner",
                                "Only the owner's own direct messages may call them. Reply in text.")
        elif surface not in cfg.allowed_sources:
            return Decision(False, "source", f"Conversations from {surface or 'this surface'} can't call the user.")
        now = self.clock()
        with self.lock:
            recent = [(at, sid) for at, sid in self.rings if now - at < max(cfg.global_window_s, cfg.session_window_s)]
            global_count = sum(1 for at, _ in recent if now - at < cfg.global_window_s)
            session_count = sum(1 for at, sid in recent if sid == origin.session_id and now - at < cfg.session_window_s)
        if session_count >= cfg.rings_per_session:
            return Decision(False, "rate_session",
                            "This conversation has rung the user too often just now. Reply in text instead.")
        if global_count >= cfg.rings_global:
            return Decision(False, "rate_global", "Too many calls lately. Reply in text instead.")
        quiet = cfg.quiet_hours
        if quiet is not None and in_quiet_hours(quiet, now):
            if quiet.action == "confirm" and self._confirmed(origin.session_id, now, origin.user_turn_at):
                return Decision(True, "confirmed")
            with self.lock:
                self.refused_at[origin.session_id] = now
            if quiet.action == "confirm":
                return Decision(False, "quiet_hours_confirm", (
                    "It's the user's quiet hours. Ask them in text whether they want a call now; only if they say "
                    "yes, call start_call again."))
            return Decision(False, "quiet_hours", "It's the user's quiet hours, so calls are off. Reply in text.")
        return Decision(True)

    def _confirmed(self, session_id: str, now: float, reported: float = 0.0) -> bool:
        """The user wrote in the conversation after it was refused for quiet hours. A conversation in another
        process reports its user's last message itself (``reported``; same host, same clock)."""
        with self.lock:
            refused = self.refused_at.get(session_id)
            wrote = max(self.user_turn_at.get(session_id) or 0.0, reported if 0 < reported <= now else 0.0)
        return bool(refused and wrote and wrote > refused and now - refused < CONFIRM_WINDOW_S)

    def note_user_turn(self, session_id: str) -> None:
        """The user wrote in this conversation (only their own messages: see ``users_own_message``)."""
        if session_id:
            with self.lock:
                self.user_turn_at[session_id] = self.clock()
                if len(self.user_turn_at) > 500:
                    for key in list(self.user_turn_at)[:100]:
                        del self.user_turn_at[key]

    def record_ring(self, origin: hermes.Origin, call_id: str) -> None:
        with self.lock:
            self.rings.append((self.clock(), origin.session_id))
            self.refused_at.pop(origin.session_id, None)
        self.log({"event": "ring", "call_id": call_id, "session_id": origin.session_id, "source": _surface(origin)})

    # ── ring log ─────────────────────────────────────────────────────────────────────────────────────────

    def log(self, entry: dict[str, Any]) -> None:
        entry = {"at": datetime.fromtimestamp(self.clock(), timezone.utc).isoformat(timespec="seconds"), **entry}
        try:
            folder = self.log_dir()
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / "rings.jsonl"
            with self.lock:
                fresh = not path.exists()
                with path.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
                if fresh:
                    os.chmod(path, 0o600)  # session ids and sources: the owner's business only
                if path.stat().st_size > RING_LOG_MAX_LINES * 400:
                    lines = path.read_text(encoding="utf-8").splitlines()[-RING_LOG_MAX_LINES // 2:]
                    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        except OSError:
            logger.warning("hermes_voice: could not write the ring log", exc_info=True)


def users_own_message(message: Any) -> bool:
    """Whether a turn's message (``pre_llm_call``'s ``user_message``) is one the user wrote. Hermes starts turns on
    its own too, each with a bracketed text: goal continuation ("[Continuing toward your standing goal]"),
    "[System note: …]" after a crash, "[IMPORTANT: Background process …]" notices; this plugin injects
    "[Voice …]". None of those is the user saying yes to a call. Fails closed: a message of the user's own that
    starts with "[" doesn't count either, so at worst the agent asks again."""
    if isinstance(message, str):
        text = message
    elif isinstance(message, list):  # multimodal content parts
        text = " ".join(str(part.get("text") or "") for part in message
                        if isinstance(part, dict) and part.get("type") in ("text", "input_text"))
    else:
        return False
    text = text.lstrip()
    return bool(text) and not text.startswith("[")


def is_owner(origin: hermes.Origin, owner_ids: tuple[str, ...] = ()) -> bool:
    """Whether a messaging DM comes from the owner: named in ``owner_ids`` (a user id, or
    ``"<platform>:<user id>"``) when that is set, else as the process hosting the chat found it
    (``origin.is_owner``, from ``gateway_owner``)."""
    user = (origin.user_id or "").strip()
    if not user:
        return False
    if owner_ids:
        platform = (origin.platform or "").strip().lower()
        for entry in owner_ids:
            scope, sep, rest = entry.partition(":")
            # "telegram:123" names a platform; "@alice:matrix.org" is a whole id.
            if sep and PLATFORM_NAME.fullmatch(scope.strip().lower()):
                if scope.strip().lower() != platform:
                    continue
                entry = rest
            if hermes.same_user(platform, entry.strip(), user):
                return True
        return False
    return bool(origin.is_owner)


def gateway_owner(platform: str, user_id: str) -> bool:
    """Whether the messaging gateway was told to serve this user: named in the platform's allowlist
    (``TELEGRAM_ALLOWED_USERS`` ...) or ``GATEWAY_ALLOWED_USERS``, or paired with a code the owner approved. An
    allow-all switch, a ``*`` wildcard, a group-only allowlist or an adapter's role grant makes nobody the owner:
    those let strangers write to Hermes. Runs in the process that hosts the chat (the gateway)."""
    platform, user_id = (platform or "").strip().lower(), (user_id or "").strip()
    if not platform or not user_id or platform in NON_MESSAGING:
        return False
    if any(hermes.same_user(platform, name, user_id) for name in hermes.gateway_allowed_users(platform)):
        return True
    return hermes.gateway_paired(platform, user_id)


def is_messaging(surface: str) -> bool:
    """A messaging platform rather than one of the owner's own clients (``_surface`` values)."""
    return (surface or "").strip().lower() not in NON_MESSAGING


def _surface(origin: hermes.Origin) -> str:
    """Where the conversation runs: the messaging platform when there is one, else the session source."""
    platform = (origin.platform or "").strip().lower()
    if platform and platform not in NON_MESSAGING:
        return platform
    return (origin.source or platform or "").strip().lower()


def in_quiet_hours(quiet: QuietHours, now: float) -> bool:
    moment = _local(now, quiet.timezone)
    minute = moment.hour * 60 + moment.minute
    if quiet.start < quiet.end:
        return quiet.start <= minute < quiet.end
    return minute >= quiet.start or minute < quiet.end  # spans midnight


def _local(now: float, zone: str) -> datetime:
    if zone:
        try:
            from zoneinfo import ZoneInfo
            return datetime.fromtimestamp(now, ZoneInfo(zone))
        except Exception:  # noqa: BLE001 - unknown zone: the host's local time
            logger.warning("hermes_voice: unknown quiet_hours timezone %r; using local time", zone)
    return datetime.fromtimestamp(now)
