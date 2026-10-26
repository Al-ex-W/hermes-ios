"""A Hermes process that isn't the dashboard (a messaging gateway, say), for test_remote.py: it loads the plugin's
core the way Hermes does, with a fake plugin context and a fake agent running the conversation, and calls through
the hub socket of the test process's hub (``remote.py``).

Driven over stdin / stdout, one JSON object per line: each command gets one answer.

- ``{"do": "start_call", "session_id", "text", "mode"}`` / ``{"do": "end_call", "session_id", "text"}``: the tools
- ``{"do": "turn_start", "session_id", "parent_session_id"?, "user_message"?}`` / ``{"do": "turn_end",
  "session_id"}``: the hooks
- ``{"do": "injected"}``: what reached the conversation (``ctx.inject_message``, the agent's redirect / steer)
- ``{"do": "subscriptions"}``: the calls this process takes turns for
- ``{"do": "status"}``: the hub's status

Usage: ``python remote_client.py <plugin dir>``. The environment carries the session (``HERMES_HOME``,
``HERMES_SESSION_*``, ``GATEWAY_ALLOWED_USERS``) as a gateway's would.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import threading
import types
from pathlib import Path
from typing import Any


class Agent:
    """The agent running the conversation (``get_active_subagent_parent``)."""

    def __init__(self, session_id: str) -> None:
        self.session_id = session_id
        self._delegate_depth = 0
        self._delegate_parent_ref = None
        self.redirects: list[str] = []
        self.steers: list[str] = []
        self.lock = threading.Lock()

    def redirect(self, text: str) -> bool:
        with self.lock:
            self.redirects.append(text)
        return True

    def steer(self, text: str, *, ticket: Any = None) -> bool:
        with self.lock:
            self.steers.append(text)
        return True


class Context:
    """The plugin context: ``inject_message`` starts a turn (allowed here: see the config below)."""

    def __init__(self) -> None:
        self._manager = types.SimpleNamespace(_cli_ref=None, home_path=None)
        self.injected: list[tuple[Any, str]] = []
        self.lock = threading.Lock()

    def inject_message(self, content: str, role: str = "user", *, session_key: Any = None,
                       origin: Any = None) -> bool:
        with self.lock:
            self.injected.append((session_key, content))
        return True

    def session_surface(self) -> str:
        return "telegram"


def main() -> None:
    plugin_dir = Path(sys.argv[1]).resolve()
    agent = Agent("tg-1")
    config = {"plugins": {"entries": {"hermes_voice": {"allow_gateway_injection": True}}}}
    for name, attrs in (("agent.subagent_lifecycle", {"get_active_subagent_parent": lambda: agent}),
                        ("hermes_cli.config", {"load_config_readonly": lambda: config})):
        parent = name.rpartition(".")[0]
        sys.modules.setdefault(parent, types.ModuleType(parent))
        module = types.ModuleType(name)
        module.__dict__.update(attrs)
        sys.modules[name] = module
    spec = importlib.util.spec_from_file_location("hermes_voice_loader", plugin_dir / "loader.py")
    assert spec is not None and spec.loader is not None
    loader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loader)
    sys.modules["hermes_voice_loader"] = loader
    remote = loader.module("remote", plugin_dir)
    ctx = Context()
    remote.bind_context(ctx)

    for line in sys.stdin:
        if not line.strip():
            continue
        command = json.loads(line)
        do = command.get("do")
        if do == "start_call":
            answer: Any = remote.start_call(command["session_id"], command["text"], command.get("mode", "async"))
        elif do == "end_call":
            answer = remote.end_call(command["session_id"], command.get("text", ""))
        elif do == "turn_start":
            remote.note_turn_start(command["session_id"], command.get("parent_session_id", ""),
                                   command.get("user_message"))
            answer = {"ok": True}
        elif do == "turn_end":
            remote.note_turn_end(command["session_id"])
            answer = {"ok": True}
        elif do == "injected":
            with ctx.lock, agent.lock:
                answer = {"inject": ctx.injected, "redirect": agent.redirects, "steer": agent.steers}
        elif do == "subscriptions":
            answer = {"calls": sorted(remote.subscriptions())}
        elif do == "status":
            answer = remote.status()
        else:
            answer = {"error": f"unknown command {do!r}"}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
