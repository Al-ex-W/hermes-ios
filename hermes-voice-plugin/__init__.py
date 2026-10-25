"""hermes_voice: Hermes calls the user on the HermesVoice iPhone app, and talks with them out loud.

``register(ctx)`` adds the ``start_call`` / ``end_call`` tools (toolset ``voice``), the ``voice-calls`` skill and two
hooks (``pre_llm_call`` / ``on_session_end``: which conversations are busy, and the call following its
conversation through compression). The phone's socket and the device, Scribe-token and status routes live in
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


def _pre_llm_call(session_id: Any = None, parent_session_id: Any = None, user_message: Any = None,
                  **_: Any) -> None:
    hub = _core("hub")
    if not hub.routes_mounted():
        return None  # not the dashboard process: no calls here
    try:
        hub.get_hub().note_turn_start(str(session_id or ""), str(parent_session_id or ""), user_message)
    except Exception:  # noqa: BLE001 - a hook must never break a turn
        logger.debug("hermes_voice: pre_llm_call hook failed", exc_info=True)
    return None


def _on_session_end(session_id: Any = None, **_: Any) -> None:
    hub = _core("hub")
    if not hub.routes_mounted():
        return None
    try:
        hub.get_hub().note_turn_end(str(session_id or ""))
    except Exception:  # noqa: BLE001
        logger.debug("hermes_voice: on_session_end hook failed", exc_info=True)
    return None
