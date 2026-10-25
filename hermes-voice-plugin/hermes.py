"""Everything the plugin takes from Hermes, in one place.

Each helper imports its Hermes module lazily and has a plain fallback, so the plugin's core runs (and is tested)
without Hermes. The session host (``tui_gateway.server``) is only ever looked up in ``sys.modules``: importing it
anywhere else would start one.
"""

from __future__ import annotations

import contextlib
import contextvars
import logging
import os
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

logger = logging.getLogger("hermes_voice")

PLUGIN_ID = "hermes_voice"
_ANY = object()


# ── secrets, homes, config ─────────────────────────────────────────────────────────────────────────────────


def get_secret(name: str) -> Optional[str]:
    """A credential from Hermes' secret scope (profile ``.env`` overlay), else the process environment."""
    try:
        from agent.secret_scope import get_secret as hermes_get_secret
    except ImportError:
        value = os.environ.get(name)
    else:
        try:
            value = hermes_get_secret(name)
        except Exception as error:  # noqa: BLE001 - UnscopedSecretError under multiplexing: fail closed
            logger.warning("hermes_voice: %s is not readable here (%s)", name, type(error).__name__)
            return None
    value = (value or "").strip()
    return value or None


def hermes_home() -> Path:
    try:
        from hermes_constants import get_hermes_home
    except ImportError:
        return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes").expanduser()
    return Path(get_hermes_home())


def state_dir() -> Path:
    """This profile's folder for the plugin's own files (devices, ring log)."""
    return hermes_home() / "hermes-voice"


def profile_name() -> str:
    value = session_env("HERMES_SESSION_PROFILE")
    if value:
        return value
    try:
        from hermes_cli.profiles import get_active_profile_name
    except ImportError:
        return "default"
    try:
        return str(get_active_profile_name() or "default")
    except Exception:  # noqa: BLE001
        return "default"


def load_config() -> dict:
    """Hermes' merged config.yaml (read-only), or {} outside Hermes."""
    try:
        from hermes_cli.config import load_config_readonly
    except ImportError:
        return _read_yaml(hermes_home() / "config.yaml")
    try:
        config = load_config_readonly()
    except Exception:  # noqa: BLE001 - a broken config must not break calls
        logger.warning("hermes_voice: could not read config.yaml", exc_info=True)
        return {}
    return config if isinstance(config, dict) else {}


def _read_yaml(path: Path) -> dict:
    try:
        import yaml  # type: ignore[import-not-found]
    except ImportError:
        return {}
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except (OSError, ValueError, yaml.YAMLError):
        return {}
    return data if isinstance(data, dict) else {}


def plugin_settings(config: Optional[dict] = None) -> dict:
    """``plugins.entries.hermes_voice.settings`` from config.yaml."""
    config = load_config() if config is None else config
    entry = ((config.get("plugins") or {}).get("entries") or {}).get(PLUGIN_ID) or {}
    settings = entry.get("settings") if isinstance(entry, dict) else None
    return settings if isinstance(settings, dict) else {}


# ── threads, waits, interrupts ─────────────────────────────────────────────────────────────────────────────


def spawn_thread(target: Callable[..., Any], *args: Any, name: str) -> threading.Thread:
    """Start a daemon thread that runs under the caller's contextvars (profile and secret scope)."""
    try:
        from agent.memory_provider import spawn_context_thread
    except ImportError:
        context = contextvars.copy_context()
        thread = threading.Thread(target=context.run, args=(target, *args), name=name, daemon=True)
    else:
        thread = spawn_context_thread(target, name=name, args=args)
    thread.start()
    return thread


@contextlib.contextmanager
def human_wait() -> Iterator[None]:
    """Mark a sync call's wait as time spent waiting on the human: Hermes' tool-batch deadline excludes it."""
    try:
        from tools.approval_human_wait import human_wait_window
    except ImportError:
        yield
        return
    try:
        window = human_wait_window()
        window.__enter__()
    except Exception:  # noqa: BLE001 - no approval context here: wait without the window
        logger.debug("hermes_voice: human_wait_window unavailable", exc_info=True)
        yield
        return
    try:
        yield
    finally:
        window.__exit__(None, None, None)


def heartbeat(label: str) -> Callable[[], None]:
    """Keeps the agent's inactivity watchdog quiet while a sync call waits for the user."""
    try:
        from tools.approval_human_wait import activity_heartbeat
        beat = activity_heartbeat(label)
    except Exception:  # noqa: BLE001
        return lambda: None

    def safe() -> None:
        try:
            beat()
        except Exception:  # noqa: BLE001
            pass

    return safe


def is_interrupted() -> bool:
    """The user pressed Stop (or the turn was interrupted) on the thread running this tool."""
    try:
        from tools.interrupt import is_interrupted as hermes_is_interrupted
    except ImportError:
        return False
    try:
        return bool(hermes_is_interrupted())
    except Exception:  # noqa: BLE001
        return False


# ── the calling session ────────────────────────────────────────────────────────────────────────────────────


def session_env(name: str) -> str:
    try:
        from gateway.session_context import get_session_env
    except ImportError:
        return os.environ.get(name, "")
    try:
        return str(get_session_env(name, "") or "")
    except Exception:  # noqa: BLE001
        return ""


def subagent_parent() -> Any:
    """The top-level agent when this tool runs inside a delegated subagent, else None.

    Hermes binds the agent running the current turn (``bind_subagent_parent(self)`` in ``agent/turn_facade.py``:
    it is "the parent" of any subagent that turn spawns), so outside a subagent this is the main agent itself.
    Only an agent with ``_delegate_depth > 0`` is a subagent; its conversation is the top of its
    ``_delegate_parent_ref`` chain (the subagent itself when that chain is gone).
    """
    try:
        from agent.subagent_lifecycle import get_active_subagent_parent
    except ImportError:
        return None
    try:
        agent = get_active_subagent_parent()
    except Exception:  # noqa: BLE001
        return None
    if agent is None or not _delegate_depth(agent):
        return None
    top = agent
    for _ in range(32):  # bounded: delegation is shallow, and a cycle must not hang a tool
        ref = getattr(top, "_delegate_parent_ref", None)
        try:
            parent = ref() if callable(ref) else None
        except Exception:  # noqa: BLE001
            parent = None
        if parent is None:
            break
        top = parent
        if not _delegate_depth(top):
            break
    return top


def _delegate_depth(agent: Any) -> int:
    depth = getattr(agent, "_delegate_depth", 0)
    return depth if isinstance(depth, int) and not isinstance(depth, bool) and depth > 0 else 0


def is_compute_host_child() -> bool:
    return os.environ.get("HERMES_COMPUTE_HOST_CHILD") == "1"


# ── the in-process session host (dashboard / desktop sessions) ─────────────────────────────────────────────


def tui_server() -> Any:
    """``tui_gateway.server`` when this process already hosts sessions, else None (never imported here)."""
    return sys.modules.get("tui_gateway.server")


def methods() -> Optional[dict]:
    server = tui_server()
    table = getattr(server, "_methods", None) if server is not None else None
    return table if isinstance(table, dict) else None


def live_record(runtime_sid: str) -> Optional[dict]:
    server = tui_server()
    sessions = getattr(server, "_sessions", None) if server is not None else None
    if not runtime_sid or not isinstance(sessions, dict):
        return None
    record = sessions.get(runtime_sid)
    if not isinstance(record, dict) or record.get("_finalized"):
        return None
    return record


def record_session_id(record: dict) -> str:
    """The stored id a live record answers to now (follows compression rotation)."""
    return str(getattr(record.get("agent"), "session_id", None) or record.get("session_key") or "")


def find_live(session_key: str, profile_home: Any = _ANY) -> Optional[tuple[str, dict]]:
    """``(runtime sid, record)`` of the live session for a stored id, via the host's own lookup."""
    server = tui_server()
    finder = getattr(server, "_find_live_session_by_key", None) if server is not None else None
    if not session_key or not callable(finder):
        return None
    try:
        found = finder(session_key) if profile_home is _ANY else finder(session_key, profile_home)
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: live session lookup failed", exc_info=True)
        return None
    if isinstance(found, tuple) and len(found) == 2 and isinstance(found[1], dict):
        return str(found[0]), found[1]
    return None


def session_title(runtime_sid: str, record: Optional[dict]) -> str:
    server = tui_server()
    if record is not None and server is not None:
        titler = getattr(server, "_session_live_title", None)
        if callable(titler):
            with contextlib.suppress(Exception):
                title = titler(record, record_session_id(record))
                if title:
                    return str(title)[:120]
        if record.get("title"):
            return str(record["title"])[:120]
    return ""


def turn_isolation() -> bool:
    """``dashboard.turn_isolation``: turns run in compute-host children, where the call hub isn't."""
    server = tui_server()
    reader = getattr(server, "_load_dashboard_process_isolation_config", None) if server is not None else None
    if callable(reader):
        try:
            return bool((reader() or {}).get("turn_isolation"))
        except Exception:  # noqa: BLE001
            return False
    dashboard = load_config().get("dashboard") or {}
    return str(dashboard.get("turn_isolation", "")).strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Origin:
    """Who is asking for a call: the conversation the call will belong to, and where it runs."""

    session_id: str
    runtime_sid: str = ""
    profile: str = "default"
    profile_home: Optional[str] = None
    title: str = ""
    source: str = ""
    platform: str = ""
    chat_type: str = ""
    user_id: str = ""
    is_cron: bool = False
    is_subagent: bool = False


def origin(session_id: Any) -> Origin:
    """The calling conversation. A subagent's call belongs to its parent's conversation."""
    parent = subagent_parent()
    is_subagent = parent is not None
    sid = str(getattr(parent, "session_id", None) or "") if is_subagent else ""
    sid = sid or (session_id.strip() if isinstance(session_id, str) else "")
    found = find_live(sid) if sid else None
    runtime_sid, record = found if found is not None else ("", None)
    source = session_env("HERMES_SESSION_SOURCE") or str((record or {}).get("source") or "")
    return Origin(
        session_id=sid,
        runtime_sid=runtime_sid,
        profile=profile_name(),
        profile_home=(str(record.get("profile_home")) if record and record.get("profile_home") else None),
        title=session_title(runtime_sid, record),
        source=source,
        platform=session_env("HERMES_SESSION_PLATFORM"),
        chat_type=session_env("HERMES_SESSION_CHAT_TYPE"),
        user_id=session_env("HERMES_SESSION_USER_ID"),
        is_cron=session_env("HERMES_CRON_SESSION") == "1" or bool(os.environ.get("HERMES_KANBAN_TASK")),
        is_subagent=is_subagent,
    )
