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
import time
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


def take_yield() -> bool:
    """Hermes asked the tool on this thread to yield (this takes the request). A message that reaches the
    conversation while its tools run (``redirect()`` during tool execution: a steer plus ``request_yield`` on the
    tool threads) is delivered only once the tool returns."""
    try:
        from tools.interrupt import acting_for_tid, consume_yield
    except ImportError:
        return False
    try:
        tids = {threading.get_ident(), acting_for_tid.get()}
        return any([consume_yield(tid) for tid in tids if tid is not None])
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


@contextlib.contextmanager
def detached_transport() -> Iterator[None]:
    """Run host methods with Hermes' drop sink as the request's transport. With no client bound, the host falls
    back to its stdio transport, so a conversation the plugin reopens (``session.resume``) or queues into
    (``session.redirect`` -> ``queued``) would stream every later frame of it (tool arguments, replies,
    reasoning) to the dashboard's stdout, i.e. its log. The drop sink is where Hermes parks conversations whose
    client went away; a client that opens the conversation later attaches as usual."""
    server = tui_server()
    transport = sys.modules.get("tui_gateway.transport")
    sink = getattr(server, "_detached_ws_transport", None) if server is not None else None
    bind = getattr(transport, "bind_transport", None)
    reset = getattr(transport, "reset_transport", None)
    if sink is None or not callable(bind) or not callable(reset):
        yield
        return
    token = bind(sink)
    try:
        yield
    finally:
        reset(token)


def dashboard_serving() -> bool:
    """This process runs the dashboard's web server (``start_server`` set ``app.state.bound_host``), rather than
    only importing it: other processes import ``hermes_cli.web_server`` too (a TUI resume that shows an attached
    image does), which mounts the plugin's routes without ever serving them. A messaging gateway that serves the
    same app behind its own API listener (``gateway/run_api.py``: ``app.state.gateway_runner``) isn't it either:
    the phone connects to ``hermes serve``, and the gateway's conversations reach it over the hub's socket."""
    web = sys.modules.get("hermes_cli.web_server")
    state = getattr(getattr(web, "app", None), "state", None) if web is not None else None
    try:
        if getattr(state, "gateway_runner", None) is not None:
            return False
        if getattr(sys.modules.get("gateway.run_api"), "_ACTIVE_RUNNER", None) is not None:
            return False
        return bool(getattr(state, "bound_host", None))
    except Exception:  # noqa: BLE001
        return False


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
    # Set for conversations in other processes (``remote.py``): Hermes' route key for the conversation (a
    # messaging chat keeps it through compression), whether a messaging DM comes from someone the gateway was
    # told to serve (its allowlist or pairing), and when the user last wrote there (quiet-hours confirmation).
    session_key: str = ""
    is_owner: bool = False
    user_turn_at: float = 0.0


def origin(session_id: Any) -> Origin:
    """The calling conversation. A subagent's call belongs to its parent's conversation."""
    parent = subagent_parent()
    is_subagent = parent is not None
    sid = str(getattr(parent, "session_id", None) or "") if is_subagent else ""
    sid = sid or (session_id.strip() if isinstance(session_id, str) else "")
    found = find_live(sid) if sid else None
    runtime_sid, record = found if found is not None else ("", None)
    source = (unattended_source() or session_env("HERMES_SESSION_SOURCE")
              or str((record or {}).get("source") or ""))
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


# ── other Hermes processes (CLI, Ink TUI, messaging gateway, cron, compute-host children) ──────────────────


def current_session_key() -> str:
    """Hermes' route key for the conversation this tool or hook runs for (``get_current_session_key``: the gateway's
    ``agent:<profile>:<platform>:...`` key, the CLI's session id), or "" (never Hermes' fallback ``default``)."""
    try:
        from tools.approval_context import get_current_session_key
    except ImportError:
        key = session_env("HERMES_SESSION_KEY")
    else:
        try:
            key = str(get_current_session_key("") or "")
        except Exception:  # noqa: BLE001
            key = ""
    key = key.strip()
    return "" if key == "default" else key[:256]


def bound_agent() -> Any:
    """The agent Hermes binds for the turn running in this context (a delegated subagent's own agent included), or
    None outside a turn. Hooks run inside that binding, so this is the agent whose turn the hook is about."""
    try:
        from agent.subagent_lifecycle import get_active_subagent_parent
    except ImportError:
        return None
    try:
        return get_active_subagent_parent()
    except Exception:  # noqa: BLE001
        return None


def turn_agent() -> Any:
    """The top-level agent whose turn runs in this context: the agent Hermes binds for the turn, or the top of a
    delegated subagent's parent chain. None outside a turn."""
    try:
        from agent.subagent_lifecycle import get_active_subagent_parent
    except ImportError:
        return None
    try:
        agent = get_active_subagent_parent()
    except Exception:  # noqa: BLE001
        return None
    if agent is None:
        return None
    return subagent_parent() or agent


# Room left between the end of a sync wait and Hermes' tool deadline, for the result to get back.
TOOL_DEADLINE_MARGIN_S = 20.0


def tool_wait_cap(started: float) -> Optional[float]:
    """How long a sync start_call that began at `started` (``time.monotonic()``) may still wait inside its tool call
    before Hermes abandons the tool with a generic timeout: the sequential tool deadline
    (``timeouts.tools.sequential_call``, default 420 s), extended by the time spent in a human-wait window but by
    at most ``human_wait_ceiling()`` (``approvals.timeout`` + 60 s) per window, less the time already spent and a
    margin. None when Hermes sets no deadline (or outside Hermes)."""
    deadline = _sequential_tool_deadline()
    ceiling = human_wait_ceiling()
    if deadline is None or ceiling is None:
        return None
    return max(1.0, deadline + ceiling - (time.monotonic() - started) - TOOL_DEADLINE_MARGIN_S)


def _sequential_tool_deadline() -> Optional[float]:
    try:
        from agent import tool_executor
        resolver = getattr(tool_executor, "_resolve_sequential_tool_timeout", None)
        if callable(resolver):
            value = resolver()
        else:
            from agent.deadline import resolve_timeout
            value = resolve_timeout("tools.sequential_call", default=420.0)
    except Exception:  # noqa: BLE001 - outside Hermes (or an older one): no deadline known
        return None
    try:
        value = float(value) if value is not None else None
    except (TypeError, ValueError):
        return None
    return value if value is not None and value > 0 else None


def human_wait_ceiling() -> Optional[float]:
    """How long one human wait may hold a tool past Hermes' tool deadline: ``approvals.timeout`` + 60 s (None
    outside Hermes)."""
    try:
        from tools.approval_human_wait import human_wait_ceiling as ceiling
    except ImportError:
        return None
    try:
        value = float(ceiling())
    except Exception:  # noqa: BLE001
        return None
    return value if value > 0 else None


def redact(text: str) -> Optional[str]:
    """``text`` with credentials masked the way Hermes masks them before any client sees them
    (``agent.redact.redact_sensitive_text``, forced on), or None where that isn't available."""
    try:
        from agent.redact import redact_sensitive_text
    except ImportError:
        return None
    try:
        return str(redact_sensitive_text(text, force=True))
    except Exception:  # noqa: BLE001 - fail closed: the caller says something generic instead
        return None


def unattended_source() -> str:
    """A label for a turn nobody is at the keyboard for, else "": ``oneshot`` for a finite run (``hermes chat -q``,
    ``hermes -z``: Hermes answers its prompts itself, since no user is there to), ``tool`` for a third-party
    integration (``hermes chat --source tool``). Hermes runs both as the CLI, so their session surface says ``cli``;
    the launch policy keeps their own label."""
    label = ""
    try:
        from gateway.session_policy import active_policy
        policy = active_policy()
        label = str(getattr(policy, "source", "") or "").strip().lower() if policy is not None else ""
    except Exception:  # noqa: BLE001 - no gateway package, or no launch policy for this turn
        label = ""
    if label in ("oneshot", "tool"):
        return label
    try:
        from gateway.session_finite import finite_turn_required, unattended_turn
        if finite_turn_required() is True or unattended_turn() is True:
            return "oneshot"
    except Exception:  # noqa: BLE001
        pass
    if session_env("HERMES_SINGLE_QUERY_SESSION").strip().lower() in ("1", "true", "yes", "on"):
        return "oneshot"
    return ""


def home_key(path: Any) -> str:
    """A Hermes home as Hermes keys it (``hermes_home_key``: resolved, case-normalized), so two spellings of one
    folder (a symlink, /tmp vs /private/tmp) compare equal."""
    try:
        from hermes_constants import hermes_home_key
        return str(hermes_home_key(path))
    except Exception:  # noqa: BLE001 - an older Hermes, or outside Hermes
        try:
            return os.path.normcase(os.path.realpath(os.path.expanduser(str(path))))
        except (OSError, ValueError):
            return str(path)


def gateway_injection_allowed() -> bool:
    """``plugins.entries.hermes_voice.allow_gateway_injection: true``: Hermes lets this plugin start a turn in a
    messaging (or Ink TUI / desktop) session with ``ctx.inject_message``."""
    entry = ((load_config().get("plugins") or {}).get("entries") or {}).get(PLUGIN_ID) or {}
    return isinstance(entry, dict) and entry.get("allow_gateway_injection") is True


def gateway_allowed_users(platform: str) -> list[str]:
    """The user ids the messaging gateway's allowlists name for ``platform`` (``<PLATFORM>_ALLOWED_USERS`` and
    ``GATEWAY_ALLOWED_USERS``), read the way the gateway reads them (the profile's secret scope). Wildcards are
    left out."""
    names: list[str] = []
    try:
        from gateway import pairing
        env_name = pairing._allowlist_env_for_platform(platform)
    except Exception:  # noqa: BLE001 - not a gateway-capable Hermes
        pairing, env_name = None, None
    for name in (env_name, "GATEWAY_ALLOWED_USERS"):
        if not name:
            continue
        raw = ""
        reader = getattr(pairing, "_read_allowlist_env", None) if pairing is not None else None
        try:
            raw = str(reader(name) if callable(reader) else (get_secret(name) or ""))
        except Exception:  # noqa: BLE001 - an unreadable allowlist names nobody
            raw = ""
        names.extend(part.strip() for part in raw.split(",") if part.strip() and part.strip() != "*")
    return names


def gateway_paired(platform: str, user_id: str) -> bool:
    """The user paired with this Hermes on ``platform`` (a code the owner approved)."""
    try:
        from gateway.pairing import PairingStore
        return bool(PairingStore().is_approved(platform, user_id))
    except Exception:  # noqa: BLE001
        return False


def same_user(platform: str, left: str, right: str) -> bool:
    """Two user ids for one person on ``platform`` (the gateway's own aliasing, e.g. WhatsApp phone / JID)."""
    try:
        from gateway.pairing import _user_ids_match
        return bool(_user_ids_match(platform, left, right))
    except Exception:  # noqa: BLE001
        return bool(left) and left.strip() == right.strip()


def hub_folders() -> list[Path]:
    """Where to look for the dashboard hub's socket: this profile's folder, then the Hermes root's (a dashboard
    serves every profile from its own home)."""
    folders = [state_dir()]
    try:
        from hermes_constants import get_default_hermes_root
        folders.append(Path(get_default_hermes_root()) / "hermes-voice")
    except Exception:  # noqa: BLE001
        pass
    unique: list[Path] = []
    for folder in folders:
        if folder not in unique:
            unique.append(folder)
    return unique
