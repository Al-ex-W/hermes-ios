"""Text to speech for calls: ElevenLabs streaming PCM (16-bit little-endian mono at SAMPLE_RATE), or short tones
per word with ``HERMES_VOICE_FAKE_TTS=1`` for testing without a key."""

from __future__ import annotations

import asyncio
import json
import logging
import math
import re
import struct
from typing import Any, AsyncIterator, Callable, Optional, Protocol

import httpx

from . import hermes
from .config import VOICE_ID, Settings

logger = logging.getLogger("hermes_voice")

SAMPLE_RATE = 24_000


class TextToSpeech(Protocol):
    def stream(self, text: str, voice_id: Optional[str] = None) -> AsyncIterator[bytes]: ...


class ElevenLabs:
    """ElevenLabs' streaming endpoint, asked for raw PCM so the phone plays it as it arrives."""

    def __init__(
        self,
        settings: Callable[[], Settings],
        api_key: Callable[[], Optional[str]] = lambda: hermes.get_secret("ELEVENLABS_API_KEY"),
        transport: Optional[httpx.AsyncBaseTransport] = None,
    ) -> None:
        self.settings = settings
        self.api_key = api_key
        self.transport = transport

    @property
    def fake(self) -> bool:
        return self.settings().fake_tts

    async def stream(self, text: str, voice_id: Optional[str] = None) -> AsyncIterator[bytes]:
        settings = self.settings()
        if settings.fake_tts:
            async for chunk in fake_speech(text):
                yield chunk
            return
        voice = voice_id or settings.voice_id
        # The voice id goes into the URL path, so only plain ids may reach it.
        if not VOICE_ID.fullmatch(voice):
            raise ValueError(f"Invalid voice_id {voice[:80]!r}.")
        key = self.api_key()
        if not key:
            raise RuntimeError("ELEVENLABS_API_KEY is not set on the Hermes host.")
        url = f"{settings.elevenlabs_base_url}/v1/text-to-speech/{voice}/stream"
        body = {"text": text, "model_id": settings.model_id}
        headers = {"xi-api-key": key, "Accept": "audio/pcm"}
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0, read=60.0), transport=self.transport) as client:
            async with client.stream(
                "POST", url, params={"output_format": f"pcm_{SAMPLE_RATE}"}, json=body, headers=headers
            ) as response:
                if response.status_code >= 400:
                    raise RuntimeError(elevenlabs_error(response.status_code, await response.aread()))
                async for chunk in response.aiter_bytes():
                    if chunk:
                        yield chunk


def elevenlabs_error(status: int, body: bytes) -> str:
    """A short error for the agent; the response body itself only goes to the log."""
    logger.warning("ElevenLabs returned %s: %s", status, body[:500].decode("utf-8", "replace"))
    try:
        reason: Any = json.loads(body)["detail"]["status"]
    except (ValueError, KeyError, TypeError):
        reason = None
    if isinstance(reason, str) and re.fullmatch(r"[a-z_]{1,64}", reason):
        return f"ElevenLabs returned HTTP {status} ({reason})."
    return f"ElevenLabs returned HTTP {status}."


async def fake_speech(text: str) -> AsyncIterator[bytes]:
    """A short tone per word (at most 40), for testing without an ElevenLabs key."""
    for index, _ in enumerate(text.split()[:40]):
        freq = 440 + 60 * (index % 5)
        samples = int(SAMPLE_RATE * 0.18)
        frames = b"".join(
            struct.pack("<h", int(6000 * math.sin(2 * math.pi * freq * n / SAMPLE_RATE))) for n in range(samples)
        )
        yield frames + b"\x00\x00" * int(SAMPLE_RATE * 0.05)
        await asyncio.sleep(0)
