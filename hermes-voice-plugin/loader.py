"""One copy of the plugin's core modules per process.

Hermes imports this plugin twice in the dashboard process: the plugin manager imports the folder as a package
(for ``register(ctx)``: tools, hooks, skill), and the web server imports ``dashboard/plugin_api.py`` on its own,
by path, at startup. Both halves must share one call hub, so neither imports ``hub.py`` relative to itself: both
load this file by path (as ``hermes_voice_loader``) and ask it for the core modules, which it loads once under a
fixed package name kept on ``sys.__dict__`` (shared by every copy of this file; ``dict.setdefault`` is atomic).

The package object is created by hand, so the folder's ``__init__.py`` (``register``) never runs a second time.
"""

from __future__ import annotations

import importlib
import sys
import threading
import types
from pathlib import Path
from typing import Any

PACKAGE = "hermes_voice_core"
_KEY = "_hermes_voice_core_package"
_LOCK_KEY = "_hermes_voice_core_lock"

PLUGIN_DIR = Path(__file__).resolve().parent


def package(plugin_dir: Path | str | None = None) -> types.ModuleType:
    """The shared core package, created on first use from ``plugin_dir`` (default: this file's folder)."""
    lock = sys.__dict__.setdefault(_LOCK_KEY, threading.RLock())
    with lock:
        pkg = sys.__dict__.get(_KEY)
        if pkg is None:
            pkg = types.ModuleType(PACKAGE, "Hermes Voice plugin core (loaded once per process)")
            pkg.__path__ = [str(Path(plugin_dir or PLUGIN_DIR).resolve())]
            pkg.__package__ = PACKAGE
            sys.modules[PACKAGE] = pkg
            sys.__dict__[_KEY] = pkg
        return pkg


def module(name: str, plugin_dir: Path | str | None = None) -> Any:
    """A core module (``hub``, ``tools``, ``inject`` ...) from the shared package."""
    package(plugin_dir)
    lock = sys.__dict__[_LOCK_KEY]
    with lock:
        return importlib.import_module(f"{PACKAGE}.{name}")


def reset() -> None:
    """Forget the shared package and its modules (tests only)."""
    lock = sys.__dict__.setdefault(_LOCK_KEY, threading.RLock())
    with lock:
        sys.__dict__.pop(_KEY, None)
        for key in [k for k in sys.modules if k == PACKAGE or k.startswith(PACKAGE + ".")]:
            del sys.modules[key]
