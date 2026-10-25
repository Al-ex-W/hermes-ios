"""Fixtures: the plugin's core loaded the way Hermes loads it (one shared copy per process), fake Hermes modules,
and hubs built from fakes. Helpers live in support.py."""

from __future__ import annotations

import types
from pathlib import Path
from typing import Any

import pytest

from support import PLUGIN_DIR, FakeHermes, FakePusher, PacedSpeech, RecordingInjector, _load


@pytest.fixture(scope="session")
def core() -> types.SimpleNamespace:
    """The plugin's core modules (one shared copy, as in Hermes) and the dashboard API module."""
    loader = _load("hermes_voice_loader", PLUGIN_DIR / "loader.py")
    names = ("hub", "tools", "inject", "policy", "push", "tts", "config", "hermes")
    mods = types.SimpleNamespace(loader=loader, **{n: loader.module(n, PLUGIN_DIR) for n in names})
    mods.api = _load("hermes_dashboard_plugin_hermes_voice", PLUGIN_DIR / "dashboard" / "plugin_api.py")
    return mods


@pytest.fixture
def fake(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> FakeHermes:
    hermes = FakeHermes(tmp_path)
    hermes.install(monkeypatch)
    monkeypatch.delenv("ELEVENLABS_API_KEY", raising=False)
    monkeypatch.delenv("HERMES_VOICE_FAKE_TTS", raising=False)
    return hermes


@pytest.fixture
def make_hub(core: Any, fake: FakeHermes, tmp_path: Path) -> Any:
    """Build a hub with fakes (overridable), installed as the process's hub."""
    hubs: list[Any] = []

    def build(settings: Any = None, tts: Any = None, pusher: Any = None, injector: Any = None,
              policy: Any = None, **settings_kw: Any) -> Any:
        values = dict(fake_tts=True, max_chars=1000, ring_timeout_s=10.0, sync_reply_timeout_s=30.0)
        values.update(settings_kw)
        fixed = settings or core.config.Settings(**values)
        hub = core.hub.CallHub(
            settings=lambda: fixed,
            tts=tts or PacedSpeech(),
            pusher=pusher or FakePusher(),
            injector=injector or RecordingInjector(),
            policy=policy or core.policy.Policy(lambda: fixed, log_dir=lambda: tmp_path / "hermes-voice"),
        )
        core.hub.install_hub(hub)
        hubs.append(hub)
        return hub

    core.hub.mark_routes_mounted()
    yield build
    for hub in hubs:
        with hub.lock:
            call = hub.slot
        if call is not None:
            hub.finish(call, "ended_by_agent")
    core.hub.install_hub(None)
