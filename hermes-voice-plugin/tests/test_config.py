"""Settings and credentials (ported from hermes-voice-mcp's config tests).

The shared bearer token is gone: secrets come from Hermes' secret scope (``get_secret``), settings from
config.yaml, and the phone's socket is admitted by the dashboard's own WebSocket auth, which must never raise.
"""

from __future__ import annotations

import asyncio
import logging
import sys
import types

import httpx
import pytest


def _key_seen_by_elevenlabs(core) -> str:
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.headers["xi-api-key"])
        return httpx.Response(200, content=b"\x00\x00")

    tts = core.tts.ElevenLabs(lambda: core.config.Settings(), transport=httpx.MockTransport(handler))

    async def run():
        return [chunk async for chunk in tts.stream("hi")]

    asyncio.run(run())
    return seen[0]


def test_elevenlabs_key_comes_from_the_secret_scope(core, fake):
    fake.secrets["ELEVENLABS_API_KEY"] = "scoped-key"
    assert core.hermes.get_secret("ELEVENLABS_API_KEY") == "scoped-key"
    assert _key_seen_by_elevenlabs(core) == "scoped-key"


def test_the_secret_scope_wins_over_the_environment(core, fake, monkeypatch):
    # get_secret is Hermes' authority: under a scope, the process environment is not consulted for a hit.
    fake.secrets["ELEVENLABS_API_KEY"] = "in-scope"
    monkeypatch.setenv("ELEVENLABS_API_KEY", "exported")
    assert core.hermes.get_secret("ELEVENLABS_API_KEY") == "in-scope"


def test_the_environment_is_used_without_hermes(core, fake, monkeypatch):
    monkeypatch.setitem(sys.modules, "agent.secret_scope", None)  # import fails: no Hermes here
    monkeypatch.setenv("ELEVENLABS_API_KEY", " exported ")
    assert core.hermes.get_secret("ELEVENLABS_API_KEY") == "exported"
    monkeypatch.setenv("ELEVENLABS_API_KEY", "")
    assert core.hermes.get_secret("ELEVENLABS_API_KEY") is None


def test_an_unscoped_secret_fails_closed_without_logging_values(core, fake, monkeypatch, caplog):
    class UnscopedSecretError(RuntimeError):
        pass

    fake.secret_error = UnscopedSecretError("get_secret('ELEVENLABS_API_KEY') with no scope; value hunter2")
    monkeypatch.setenv("ELEVENLABS_API_KEY", "hunter2")
    with caplog.at_level(logging.WARNING, logger="hermes_voice"):
        assert core.hermes.get_secret("ELEVENLABS_API_KEY") is None
    assert "UnscopedSecretError" in caplog.text and "hunter2" not in caplog.text


def test_settings_follow_hermes_tts_config_then_plugin_settings(core, fake, caplog):
    config = {
        "tts": {"elevenlabs": {"voice_id": "hermesVoice1", "streaming_model_id": "eleven_turbo_v2_5",
                               "base_url": "https://eu.example.test/"}},
        "plugins": {"entries": {"hermes_voice": {"settings": {
            "model_id": "eleven_flash_v2_5", "max_chars": 99999, "ring_timeout_s": "30",
            "policy": {"allowed_sources": ["Desktop"], "owner_ids": [123], "quiet_hours": {
                "start": "22:30", "end": "7:00", "action": "confirm", "timezone": "Europe/Stockholm"}},
        }}}},
    }
    settings = core.config.Settings.from_config(config, {})
    assert (settings.voice_id, settings.model_id) == ("hermesVoice1", "eleven_flash_v2_5")
    assert settings.elevenlabs_base_url == "https://eu.example.test"
    assert settings.max_chars == 5000 and settings.ring_timeout_s == 30.0 and settings.fake_tts is False
    assert settings.policy.allowed_sources == ("desktop",) and settings.policy.owner_ids == ("123",)
    quiet = settings.policy.quiet_hours
    assert (quiet.start, quiet.end, quiet.action, quiet.timezone) == (1350, 420, "confirm", "Europe/Stockholm")

    defaults = core.config.Settings.from_config({}, {"HERMES_VOICE_FAKE_TTS": "1"})
    assert defaults.fake_tts is True and defaults.max_chars == 1000
    assert defaults.voice_id == core.config.DEFAULT_VOICE_ID and defaults.policy.quiet_hours is None
    fake.config = config
    assert core.config.Settings.load().voice_id == "hermesVoice1"


class _Socket:
    def __init__(self, ticket: str | None) -> None:
        self.query_params = {} if ticket is None else {"ticket": ticket}
        self.headers = {}


def _install_checks(monkeypatch, auth, allowed=lambda ws: True) -> None:
    module = types.ModuleType("hermes_cli.web_server_chat")
    module._ws_auth_ok, module._ws_request_is_allowed = auth, allowed
    monkeypatch.setitem(sys.modules, "hermes_cli.web_server_chat", module)


async def _async_true(ws):
    return True


async def _async_false(ws):
    return False


def _boom(ws):
    raise RuntimeError("auth layer broke")


@pytest.mark.parametrize(
    ("case", "expected"),
    [
        ("good ticket", None),
        ("reused ticket", 4401),
        ("no ticket", 4401),
        ("host refused", 4401),
        ("auth check raises", 4401),
        ("async check admits", None),
        ("async check refuses", 4401),
        ("host check raises", 4401),
        ("no dashboard auth in this Hermes", 4401),
    ],
)
def test_phone_socket_auth_never_raises(core, fake, monkeypatch, case, expected):
    ticket = fake.ticket()
    socket = _Socket(ticket)
    if case == "reused ticket":
        asyncio.run(core.api.authorize(_Socket(ticket)))
    elif case == "no ticket":
        socket = _Socket(None)
    elif case == "host refused":
        fake.host_allowed = False
    elif case == "auth check raises":
        _install_checks(monkeypatch, _boom)
    elif case == "async check admits":
        _install_checks(monkeypatch, _async_true)
    elif case == "async check refuses":
        _install_checks(monkeypatch, _async_false)
    elif case == "host check raises":
        _install_checks(monkeypatch, lambda ws: True, _boom)
    elif case == "no dashboard auth in this Hermes":
        monkeypatch.setitem(sys.modules, "hermes_cli.web_server_chat", None)
    assert asyncio.run(core.api.authorize(socket)) == expected
