"""hermes_voice: Hermes calls the user on the HermesVoice iPhone app, and talks with them out loud.

``register(ctx)`` adds the ``start_call`` / ``end_call`` tools (toolset ``voice``), the ``voice-calls`` skill and
the hooks: ``pre_llm_call`` / ``on_session_end`` tell which conversations are busy and keep a call with its
conversation through compression (in the dashboard process for its hub; anywhere else for the calls ``remote.py``
places through the hub's socket), and ``post_llm_call`` / ``on_session_end`` tell the alert pushes (``notify.py``)
when a turn ended. The phone's socket and the device, Scribe-token and status routes live in
``dashboard/plugin_api.py``. Both halves share one call hub per process through ``loader.py``, which both load by
path.
"""

from __future__ import annotations

import importlib.util
import logging
import sys
from pathlib import Path
from typing import Any

logger = logging.getLogger("hermes_voice")

PLUGIN_DIR = Path(__file__).resolve().parent
SKILL_PATH = PLUGIN_DIR / "skills" / "voice-calls" / "SKILL.md"
SKILL_DESCRIPTION = "How to call the user and talk with them out loud (start_call / end_call)."


def _loader() -> Any:
    """``loader.py``, loaded by path under one name, exactly as ``dashboard/plugin_api.py`` loads it."""
    module = sys.modules.get("hermes_voice_loader")
    if module is None:
        spec = importlib.util.spec_from_file_location("hermes_voice_loader", PLUGIN_DIR / "loader.py")
        if spec is None or spec.loader is None:
            raise ImportError("hermes_voice: loader.py is missing; reinstall the plugin")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sys.modules["hermes_voice_loader"] = module
    return module


def _core(name: str) -> Any:
    return _loader().module(name, PLUGIN_DIR)


def register(ctx: Any) -> None:
    tools = _core("tools")
    for schema, handler, emoji in ((tools.START_CALL, tools.start_call, "📞"), (tools.END_CALL, tools.end_call, "📵")):
        spec = {"name": schema["name"], "toolset": tools.TOOLSET, "schema": schema, "handler": handler,
                "check_fn": tools.available}
        try:
            try:
                ctx.register_tool(**spec, description=schema["description"], emoji=emoji)
            except TypeError:  # a Hermes without the display fields
                ctx.register_tool(**spec)
        except Exception:  # noqa: BLE001 - one refusal must not take the rest down
            logger.warning("hermes_voice: could not register %s", schema["name"], exc_info=True)
    if hasattr(ctx, "register_skill"):
        try:
            ctx.register_skill(tools.SKILL, SKILL_PATH, description=SKILL_DESCRIPTION)
        except Exception:  # noqa: BLE001
            logger.warning("hermes_voice: could not register the %s skill", tools.SKILL, exc_info=True)
    for name, callback in (("pre_llm_call", _pre_llm_call), ("on_session_end", _on_session_end)):
        try:
            ctx.register_hook(name, callback)
        except Exception:  # noqa: BLE001
            logger.warning("hermes_voice: could not register the %s hook", name, exc_info=True)
    _register_alerts(ctx)
    _bind_remote_calls(ctx)


def _pre_llm_call(session_id: Any = None, parent_session_id: Any = None, user_message: Any = None,
                  **_: Any) -> None:
    hub = _core("hub")
    if not hub.routes_mounted():
        return _remote_turn_start(session_id, parent_session_id, user_message)  # calls go through the hub socket
    try:
        hub.get_hub().note_turn_start(str(session_id or ""), str(parent_session_id or ""), user_message)
    except Exception:  # noqa: BLE001 - a hook must never break a turn
        logger.debug("hermes_voice: pre_llm_call hook failed", exc_info=True)
    return None


def _on_session_end(session_id: Any = None, **_: Any) -> None:
    hub = _core("hub")
    if not hub.routes_mounted():
        return _remote_turn_end(session_id)
    try:
        hub.get_hub().note_turn_end(str(session_id or ""))
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: on_session_end hook failed", exc_info=True)
    return None


# ── alert pushes (notify.py) ───────────────────────────────────────────────────────────────────────────────


def _register_alerts(ctx: Any) -> None:
    """Hooks for the alert pushes: the dashboard's watcher (started with its routes) finds waiting approvals and
    questions by itself; these tell it when a turn this process ran ended, and with what reply. They do nothing in
    a process that doesn't serve the phone (CLI, messaging gateway, a compute-host child)."""
    for name, callback in (("post_llm_call", _alert_reply), ("on_session_end", _alert_turn_end)):
        try:
            ctx.register_hook(name, callback)
        except Exception:  # noqa: BLE001
            logger.warning("hermes_voice: could not register the %s hook for alerts", name, exc_info=True)
    if hasattr(ctx, "on_unload"):
        try:
            ctx.on_unload(_pause_alerts)
        except Exception:  # noqa: BLE001
            logger.debug("hermes_voice: no unload callback for the alert watcher", exc_info=True)
    try:
        _core("notify").resume()  # loaded again (disabled, enabled) in the dashboard that serves the phone
        _core("hub").resume_socket()  # and the hub socket the unload closed
    except Exception:  # noqa: BLE001
        logger.warning("hermes_voice: could not resume the alert watcher", exc_info=True)


def _alert_reply(session_id: Any = None, assistant_response: Any = None, **_: Any) -> None:
    if not _core("hub").routes_mounted():
        return None
    try:
        _core("notify").alerts().note_reply(str(session_id or ""), assistant_response)
    except Exception:  # noqa: BLE001 - a hook must never break a turn
        logger.debug("hermes_voice: post_llm_call alert hook failed", exc_info=True)
    return None


def _alert_turn_end(session_id: Any = None, turn_id: Any = None, completed: Any = None, failed: Any = None,
                    interrupted: Any = None, **_: Any) -> None:
    if not _core("hub").routes_mounted():
        return None
    try:
        # A background wake whose presentation Hermes muted (agent/notification_presentation.py) says nothing.
        agent = _core("hermes").bound_agent()
        muted = getattr(agent, "_mute_notification_reply", False) is True
        _core("notify").alerts().turn_ended(str(session_id or ""), turn_id, completed=completed, failed=failed,
                                            interrupted=interrupted, muted=muted)
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: on_session_end alert hook failed", exc_info=True)
    return None


def _pause_alerts() -> None:
    """The plugin unloads: stop the alert watcher and close the hub socket, so no other process rings through a
    disabled plugin (both come back if it loads again)."""
    try:
        _core("notify").pause()
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: could not stop the alert watcher", exc_info=True)
    try:
        _core("hub").pause_socket()
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: could not close the hub socket", exc_info=True)


# ── calls from other processes (remote.py) ─────────────────────────────────────────────────────────────────


def _bind_remote_calls(ctx: Any) -> None:
    """Outside the dashboard, a call's turns start a turn in this process with ``ctx.inject_message``."""
    try:
        _core("remote").bind_context(ctx)
    except Exception:  # noqa: BLE001
        logger.warning("hermes_voice: could not set up calls from this process", exc_info=True)


def _remote_turn_start(session_id: Any, parent_session_id: Any, user_message: Any) -> None:
    try:
        _core("remote").note_turn_start(str(session_id or ""), str(parent_session_id or ""), user_message)
    except Exception:  # noqa: BLE001 - a hook must never break a turn
        logger.debug("hermes_voice: pre_llm_call hook failed", exc_info=True)
    return None


def _remote_turn_end(session_id: Any) -> None:
    try:
        _core("remote").note_turn_end(str(session_id or ""))
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: on_session_end hook failed", exc_info=True)
    return None
