"""Hermes Voice MCP server: `hermes-voice-mcp` runs it, `hermes-voice-mcp token` prints the token it uses."""

from __future__ import annotations

import argparse
import logging


def main() -> None:
    parser = argparse.ArgumentParser(prog="hermes-voice-mcp", description=__doc__)
    parser.add_argument("command", nargs="?", choices=["serve", "token"], default="serve")
    parser.add_argument("--host", help="bind address (default 127.0.0.1; use Tailscale Serve to reach it)")
    parser.add_argument("--port", type=int, help="port (default 8765)")
    args = parser.parse_args()

    from .config import Settings

    # Before loading settings, so a token conflict is logged in the same format (on stderr for `token`).
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    settings = Settings.load(host=args.host, port=args.port)
    if args.command == "token":
        print(settings.token)
        return

    import uvicorn

    from .server import build_app

    logger = logging.getLogger("hermes_voice")
    logger.info("using the shared token from %s", settings.token_source)
    if not settings.elevenlabs_api_key and not settings.fake_tts:
        logger.warning("ELEVENLABS_API_KEY is not set; speak will fail until it is.")
    uvicorn.run(build_app(settings), host=settings.host, port=settings.port, log_level="info")
