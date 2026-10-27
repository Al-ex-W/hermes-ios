"""Plugin settings: ``plugins.entries.hermes_voice.settings`` in config.yaml, Hermes' own ``tts.elevenlabs`` section
and a few environment overrides. Secrets (ElevenLabs key, APNs key) never live here: they are read with
``get_secret`` when used."""

from __future__ import annotations

import logging
import os
import re
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Optional

from . import hermes

logger = logging.getLogger("hermes_voice")

DEFAULT_VOICE_ID = "pNInz6obpgDQGcFmaJgB"  # Hermes' own ElevenLabs default
DEFAULT_MODEL_ID = "eleven_flash_v2_5"  # low latency, multilingual
DEFAULT_BASE_URL = "https://api.elevenlabs.io"
VOICE_ID = re.compile(r"[A-Za-z0-9]{1,64}")
MODEL_ID = re.compile(r"[A-Za-z0-9_.-]{1,64}")
CACHE_SECONDS = 5.0


@dataclass(frozen=True)
class QuietHours:
    start: int  # minutes after midnight
    end: int
    action: str = "refuse"  # or "confirm"
    timezone: str = ""


@dataclass(frozen=True)
class PolicyConfig:
    # Session sources (HERMES_SESSION_SOURCE, or the plugin's session surface) whose conversations may ring the
    # phone: the owner's own local clients ("local": a CLI / TUI session whose turns run in the gateway). Left out:
    # "oneshot" (`hermes chat -q`, `hermes -z`) and "tool" (`--source tool` integrations), runs nobody is at the
    # keyboard for, which a prompt injection in what they read could otherwise make ring.
    allowed_sources: tuple[str, ...] = ("desktop", "dashboard", "tui", "cli", "local")
    # The owner's own direct messages on a messaging platform. The owner is whoever owner_ids names (a user id,
    # or "<platform>:<user id>"); with no owner_ids, whoever the gateway's allowlist names or pairing approved.
    allow_owner_dms: bool = True
    owner_ids: tuple[str, ...] = ()
    # Other profiles whose processes may ring through this dashboard's hub (one without a dashboard of its own
    # finds the root profile's). Their DMs ring only for a user owner_ids names: this profile can't vouch for
    # another profile's allowlist or pairings.
    allowed_profiles: tuple[str, ...] = ()
    allow_cron: bool = False
    allow_subagents: bool = False
    allow_groups: bool = False
    rings_per_session: int = 3
    session_window_s: float = 600.0
    rings_global: int = 10
    global_window_s: float = 3600.0
    quiet_hours: Optional[QuietHours] = None


@dataclass(frozen=True)
class Settings:
    elevenlabs_base_url: str = DEFAULT_BASE_URL
    voice_id: str = DEFAULT_VOICE_ID
    model_id: str = DEFAULT_MODEL_ID
    max_chars: int = 1000
    fake_tts: bool = False
    ring_timeout_s: float = 45.0
    sync_reply_timeout_s: float = 600.0
    policy: PolicyConfig = field(default_factory=PolicyConfig)

    @classmethod
    def load(cls) -> "Settings":
        config = hermes.load_config()
        return cls.from_config(config, os.environ)

    @classmethod
    def from_config(cls, config: dict, environ: Any) -> "Settings":
        own = hermes.plugin_settings(config)
        tts = ((config.get("tts") or {}).get("elevenlabs") or {}) if isinstance(config.get("tts"), dict) else {}
        tts = tts if isinstance(tts, dict) else {}
        voice = str(environ.get("HERMES_VOICE_VOICE_ID") or own.get("voice_id") or tts.get("voice_id") or "")
        if voice and not VOICE_ID.fullmatch(voice):
            # The voice id goes into the request URL path: anything but a plain id is refused.
            logger.warning("hermes_voice: ignoring invalid voice_id %r; using the default voice", voice[:80])
            voice = ""
        model = str(
            environ.get("HERMES_VOICE_MODEL_ID") or own.get("model_id") or tts.get("streaming_model_id")
            or tts.get("model_id") or ""
        )
        if model and not MODEL_ID.fullmatch(model):
            logger.warning("hermes_voice: ignoring invalid model_id %r", model[:80])
            model = ""
        base = str(environ.get("ELEVENLABS_BASE_URL") or tts.get("base_url") or DEFAULT_BASE_URL).rstrip("/")
        return cls(
            elevenlabs_base_url=base,
            voice_id=voice or DEFAULT_VOICE_ID,
            model_id=model or DEFAULT_MODEL_ID,
            max_chars=_int(own.get("max_chars"), 1000, 50, 5000),
            fake_tts=str(environ.get("HERMES_VOICE_FAKE_TTS") or own.get("fake_tts") or "").strip().lower()
            in ("1", "true", "yes", "on"),
            ring_timeout_s=_float(own.get("ring_timeout_s"), 45.0, 10.0, 120.0),
            sync_reply_timeout_s=_float(own.get("sync_reply_timeout_s"), 600.0, 30.0, 3600.0),
            policy=_policy(own.get("policy") if isinstance(own.get("policy"), dict) else {}),
        )


def _policy(raw: dict) -> PolicyConfig:
    default = PolicyConfig()
    sources = raw.get("allowed_sources")
    return PolicyConfig(
        allowed_sources=tuple(str(s).strip().lower() for s in sources if str(s).strip())
        if isinstance(sources, list) else default.allowed_sources,
        allow_owner_dms=_bool(raw.get("allow_owner_dms"), default.allow_owner_dms),
        owner_ids=tuple(str(v).strip() for v in raw.get("owner_ids") or [] if str(v).strip())
        if isinstance(raw.get("owner_ids"), list) else (),
        allowed_profiles=tuple(str(v).strip() for v in raw.get("allowed_profiles") or [] if str(v).strip())
        if isinstance(raw.get("allowed_profiles"), list) else (),
        allow_cron=_bool(raw.get("allow_cron"), False),
        allow_subagents=_bool(raw.get("allow_subagents"), False),
        allow_groups=_bool(raw.get("allow_groups"), False),
        rings_per_session=_int(raw.get("rings_per_session"), default.rings_per_session, 1, 100),
        session_window_s=_float(raw.get("session_window_s"), default.session_window_s, 10.0, 86400.0),
        rings_global=_int(raw.get("rings_global"), default.rings_global, 1, 1000),
        global_window_s=_float(raw.get("global_window_s"), default.global_window_s, 10.0, 86400.0),
        quiet_hours=_quiet_hours(raw.get("quiet_hours")),
    )


def _quiet_hours(raw: Any) -> Optional[QuietHours]:
    if not isinstance(raw, dict):
        return None
    start, end = _clock(raw.get("start")), _clock(raw.get("end"))
    if start is None or end is None or start == end:
        if raw:
            logger.warning("hermes_voice: quiet_hours needs start and end as HH:MM; ignoring it")
        return None
    action = str(raw.get("action") or "refuse").strip().lower()
    return QuietHours(start, end, action if action in ("refuse", "confirm") else "refuse",
                      str(raw.get("timezone") or "").strip())


def _clock(value: Any) -> Optional[int]:
    match = re.fullmatch(r"\s*(\d{1,2}):(\d{2})\s*", str(value or ""))
    if not match:
        return None
    hours, minutes = int(match.group(1)), int(match.group(2))
    return hours * 60 + minutes if hours < 24 and minutes < 60 else None


def _bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def _int(value: Any, default: int, low: int, high: int) -> int:
    try:
        return min(high, max(low, int(value)))
    except (TypeError, ValueError):
        return default


def _float(value: Any, default: float, low: float, high: float) -> float:
    try:
        return min(high, max(low, float(value)))
    except (TypeError, ValueError):
        return default


_cache: tuple[float, Optional[Settings]] = (0.0, None)
_cache_lock = threading.Lock()


def current() -> Settings:
    """Settings, re-read at most every few seconds (config.yaml edits apply without a restart)."""
    global _cache
    with _cache_lock:
        at, settings = _cache
        if settings is None or time.monotonic() - at > CACHE_SECONDS:
            settings = Settings.load()
            _cache = (time.monotonic(), settings)
        return settings
