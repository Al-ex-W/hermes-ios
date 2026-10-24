"""Settings for Hermes Voice, read from the environment, ~/.hermes/.env and ~/.hermes/config.yaml."""

from __future__ import annotations

import hmac
import logging
import os
import re
import secrets
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

import yaml

DEFAULT_VOICE_ID = "pNInz6obpgDQGcFmaJgB"  # Hermes' own ElevenLabs default (Adam)
DEFAULT_MODEL_ID = "eleven_flash_v2_5"  # low-latency and multilingual

logger = logging.getLogger("hermes_voice")


def hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")).expanduser()


def _read_dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.removeprefix("export ").partition("=")
        values[key.strip()] = _dotenv_value(value)
    return values


def _dotenv_value(raw: str) -> str:
    """A .env value read the way Hermes reads it, so both sides agree on HERMES_VOICE_TOKEN.

    Quotes are removed (with \\" and \\\\ unescaped inside double quotes), and an unquoted value
    ends at a ``#`` that follows whitespace.
    """
    value = raw.strip()
    quote = value[:1]
    if quote not in ("'", '"'):
        return re.split(r"\s+#", value, maxsplit=1)[0].strip()
    end = 1
    while end < len(value) and value[end] != quote:
        end += 2 if quote == '"' and value[end] == "\\" else 1
    if end >= len(value):
        return value  # unterminated quote: keep it as written
    inner = value[1:end]
    return re.sub(r'\\(["\\])', r"\1", inner) if quote == '"' else inner


def _hermes_tts_config(home: Path) -> dict:
    path = home / "config.yaml"
    if not path.is_file():
        return {}
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError:
        return {}
    tts = (data.get("tts") or {}).get("elevenlabs") or {}
    return tts if isinstance(tts, dict) else {}


def load_token(home: Path, dotenv: Mapping[str, str], environ: Mapping[str, str]) -> tuple[str, str]:
    """The shared token and where it came from.

    HERMES_VOICE_TOKEN resolves the way Hermes resolves it for its MCP headers: Hermes loads ~/.hermes/.env over
    its process environment, so a value there wins over an exported one. Else a random token kept in
    ~/.hermes/hermes-voice/token.
    """
    from_file = (dotenv.get("HERMES_VOICE_TOKEN") or "").strip()
    from_env = (environ.get("HERMES_VOICE_TOKEN") or "").strip()
    if from_file:
        if from_env and from_env != from_file:
            logger.warning(
                "HERMES_VOICE_TOKEN in the environment differs from the one in %s; using the file's, as Hermes does",
                home / ".env",
            )
        return from_file, str(home / ".env")
    if from_env:
        return from_env, "the environment"
    path = home / "hermes-voice" / "token"
    if path.is_file() and (token := path.read_text().strip()):
        return token, str(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    path.write_text(token + "\n")
    path.chmod(0o600)
    return token, str(path)


@dataclass
class Settings:
    host: str
    port: int
    token: str
    elevenlabs_api_key: str | None
    elevenlabs_base_url: str
    voice_id: str
    model_id: str
    max_chars: int
    fake_tts: bool
    token_source: str = "settings"

    @classmethod
    def load(cls, host: str | None = None, port: int | None = None) -> "Settings":
        home = hermes_home()
        dotenv = _read_dotenv(home / ".env")
        env = {**dotenv, **os.environ}
        tts = _hermes_tts_config(home)
        token, token_source = load_token(home, dotenv, os.environ)
        return cls(
            host=host or env.get("HERMES_VOICE_HOST", "127.0.0.1"),
            port=port or int(env.get("HERMES_VOICE_PORT", "8765")),
            token=token,
            elevenlabs_api_key=env.get("ELEVENLABS_API_KEY") or None,
            elevenlabs_base_url=(env.get("ELEVENLABS_BASE_URL") or tts.get("base_url") or "https://api.elevenlabs.io").rstrip("/"),
            voice_id=env.get("HERMES_VOICE_VOICE_ID") or tts.get("voice_id") or DEFAULT_VOICE_ID,
            model_id=env.get("HERMES_VOICE_MODEL_ID") or tts.get("streaming_model_id") or DEFAULT_MODEL_ID,
            max_chars=int(env.get("HERMES_VOICE_MAX_CHARS", "1000")),
            fake_tts=env.get("HERMES_VOICE_FAKE_TTS") == "1",
            token_source=token_source,
        )

    def authorized(self, authorization: str | None) -> bool:
        """Whether an Authorization header carries the shared token as a bearer token. Never raises."""
        scheme, _, supplied = (authorization or "").strip().partition(" ")
        supplied = supplied.strip()
        if scheme.lower() != "bearer" or not supplied:
            return False
        try:
            return hmac.compare_digest(supplied.encode("utf-8"), self.token.encode("utf-8"))
        except UnicodeError:
            return False
