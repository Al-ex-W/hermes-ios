"""Settings: where the shared token comes from, and how the Authorization header is checked."""

from __future__ import annotations

import logging

import pytest

from hermes_voice_mcp.config import Settings


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    for name in ("HERMES_VOICE_TOKEN", "HERMES_VOICE_MAX_CHARS", "HERMES_VOICE_PORT"):
        monkeypatch.delenv(name, raising=False)
    return tmp_path


def test_token_comes_from_hermes_dotenv(home):
    (home / ".env").write_text("HERMES_VOICE_TOKEN=s3cret # shared with Hermes\nHERMES_VOICE_PORT=9999\n")
    settings = Settings.load()
    assert settings.token == "s3cret"
    assert settings.port == 9999
    assert settings.token_source == str(home / ".env")
    assert settings.authorized("Bearer s3cret")
    assert not (home / "hermes-voice" / "token").exists()


def test_dotenv_token_wins_over_the_environment_as_in_hermes(home, monkeypatch, caplog):
    # Hermes loads ~/.hermes/.env with override=True, so its MCP header carries the file's token.
    (home / ".env").write_text('HERMES_VOICE_TOKEN="tok-in-file"\n')
    monkeypatch.setenv("HERMES_VOICE_TOKEN", "tok-exported")
    with caplog.at_level(logging.WARNING, logger="hermes_voice"):
        settings = Settings.load()
    assert settings.token == "tok-in-file"
    assert settings.token_source == str(home / ".env")
    assert "differs" in caplog.text, caplog.text
    assert "tok-in-file" not in caplog.text and "tok-exported" not in caplog.text


def test_environment_token_is_used_when_dotenv_has_none(home, monkeypatch, caplog):
    (home / ".env").write_text("HERMES_VOICE_PORT=9999\n")
    monkeypatch.setenv("HERMES_VOICE_TOKEN", "tok-exported")
    with caplog.at_level(logging.WARNING, logger="hermes_voice"):
        settings = Settings.load()
    assert (settings.token, settings.token_source) == ("tok-exported", "the environment")
    assert caplog.text == ""


def test_the_same_token_in_both_places_does_not_warn(home, monkeypatch, caplog):
    (home / ".env").write_text("HERMES_VOICE_TOKEN=tok\n")
    monkeypatch.setenv("HERMES_VOICE_TOKEN", "tok")
    with caplog.at_level(logging.WARNING, logger="hermes_voice"):
        settings = Settings.load()
    assert (settings.token, settings.token_source) == ("tok", str(home / ".env"))
    assert caplog.text == ""


def test_generated_token_is_kept_when_none_is_set(home):
    first = Settings.load()
    assert first.token_source == str(home / "hermes-voice" / "token")
    assert Settings.load().token == first.token
    assert first.max_chars == 1000


@pytest.mark.parametrize(
    ("header", "expected"),
    [
        ("Bearer tok", True),
        ("bearer  tok ", True),
        ("Bearer tok2", False),
        ("tok", False),
        ("Basic tok", False),
        ("Bearer ", False),
        (None, False),
        ("Bearer \xe9\xff", False),
        ("Bearer \ud800", False),
    ],
)
def test_authorized_never_raises(header, expected):
    settings = Settings(
        host="127.0.0.1",
        port=0,
        token="tok",
        elevenlabs_api_key=None,
        elevenlabs_base_url="",
        voice_id="v",
        model_id="m",
        max_chars=1000,
        fake_tts=True,
    )
    assert settings.authorized(header) is expected
