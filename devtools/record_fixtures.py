"""Records gateway frames for the app's decoding tests (HermesVoiceTests/GatewayFixtureTests.swift).

    cd hermes-voice-mcp
    uv run python ../devtools/record_fixtures.py                    # from an in-process fake_hermes.py
    uv run python ../devtools/record_fixtures.py --url 'ws://127.0.0.1:PORT/api/ws?token=TOKEN' \\
        --source 'hermes serve' --out hermes-serve.json --reap-wait 4

The second form records a throwaway `hermes serve --isolated --host 127.0.0.1 --port PORT` started with
`HERMES_HOME=<empty temp dir>`, `HERMES_DASHBOARD_SESSION_TOKEN=TOKEN` and `HERMES_TUI_WS_ORPHAN_REAP_GRACE_S=2`
(its first start installs a runtime into that home). Never point it at the dashboard you use. That scenario needs
no model: sessions, re-attach, replay and a prompt that fails. Paths, the user name and the host name are
scrubbed before the file is written; read it before committing anyway.
"""

from __future__ import annotations

import argparse
import asyncio
import getpass
import json
import os
import socket
import sys
import tempfile
from pathlib import Path
from typing import Any

import httpx
import websockets

HERE = Path(__file__).resolve().parent
FIXTURES = HERE.parent / "HermesVoice" / "HermesVoiceTests" / "Fixtures"
# Recorded frames kept per result method, event type or request method.
KEEP = 3


class Recorder:
    """One /api/ws connection; every frame it gets goes into the shared `frames` list."""

    def __init__(self, ws: Any, frames: list[dict[str, Any]]) -> None:
        self.ws = ws
        self.frames = frames
        self.next_id = 0
        self.pending: dict[int, tuple[str, asyncio.Future]] = {}
        self.events: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.requests: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.reader = asyncio.create_task(self._read())

    async def _read(self) -> None:
        try:
            async for raw in self.ws:
                frame = json.loads(raw)
                if "method" not in frame:
                    method, future = self.pending.pop(frame.get("id"), ("", None))
                    if "result" in frame and method:
                        self.frames.append({"kind": "result", "method": method, "result": frame["result"]})
                    if future is not None and not future.done():
                        future.set_result(frame)
                elif frame["method"] == "event":
                    self.frames.append({"kind": "event", "params": frame["params"]})
                    await self.events.put(frame["params"])
                else:
                    self.frames.append({"kind": "request", "frame": frame})
                    await self.requests.put(frame)
        except websockets.ConnectionClosed:
            pass

    async def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 30) -> dict[str, Any]:
        self.next_id += 1
        future = asyncio.get_running_loop().create_future()
        self.pending[self.next_id] = (method, future)
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}}))
        frame = await asyncio.wait_for(future, timeout)
        if "error" in frame:
            raise RuntimeError(f"{method}: {frame['error']}")
        return frame["result"]

    async def event(self, kind: str, timeout: float = 10) -> dict[str, Any]:
        async with asyncio.timeout(timeout):
            while (event := await self.events.get())["type"] != kind:
                pass
        return event

    async def request(self, method: str, timeout: float = 10) -> dict[str, Any]:
        async with asyncio.timeout(timeout):
            while (frame := await self.requests.get())["method"] != method:
                pass
        return frame

    async def respond(self, rid: str, result: dict[str, Any] | None = None, error: tuple[int, str] | None = None):
        body = {"error": {"code": error[0], "message": error[1]}} if error else {"result": result}
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, **body}))

    async def close(self) -> None:
        await self.ws.close()
        await self.reader


async def handshake(ws_url: str, frames: list[dict[str, Any]]) -> Recorder:
    gateway = Recorder(await websockets.connect(ws_url, max_size=16 * 1024 * 1024), frames)
    await gateway.event("gateway.ready")
    await gateway.call("client.capabilities", {"server_requests": True})
    return gateway


async def fake_scenario(frames: list[dict[str, Any]]) -> None:
    sys.path.insert(0, str(HERE))
    sys.path.insert(0, str(HERE / "tests"))
    from fakeclient import serving, signed_in

    async with serving(reap_grace=0.3) as (fake, base):
        async with signed_in(base) as http:
            async def dial() -> Recorder:
                ticket = (await http.post("/api/auth/ws-ticket")).json()["ticket"]
                return await handshake(f"ws://{base}/api/ws?ticket={ticket}", frames)

            gateway = await dial()
            created = await gateway.call("session.create", {"cols": 96, "source": "desktop"})
            sid, key = created["session_id"], created["stored_session_id"]
            await gateway.call("prompt.submit", {"session_id": sid, "text": "hello there"})
            await gateway.event("message.complete")
            await gateway.call("prompt.submit", {"session_id": sid, "text": "approve, clarify, sudo, window"})
            approval = await gateway.request("approval")
            # Listed twice while open: in open_requests and as pending_approval.
            await gateway.call("session.activate", {"session_id": sid, "cols": 96, "omit_messages": True})
            await gateway.respond(approval["id"], {"choice": "once"})
            clarify = await gateway.request("clarify")
            await gateway.call("session.resume", {"session_id": key, "cols": 96, "source": "desktop",
                                                  "omit_messages": True})
            await gateway.respond(clarify["id"], {"answers": {"q0": "Red", "q1": None, "q2": "no"}})
            sudo = await gateway.request("sudo")
            await gateway.respond(sudo["id"], {"value": "pw"})
            window = await gateway.request("window.read")
            await gateway.respond(window["id"], error=(4404, "not shown"))
            await gateway.event("message.complete")
            await gateway.call("session.events.since", {"session_id": sid, "last_seen": 0})
            await gateway.call("prompt.submit", {"session_id": sid, "text": "stop me"})
            await gateway.event("message.start")
            await gateway.call("session.interrupt", {"session_id": sid})
            await gateway.event("message.complete")
            await gateway.close()
            # Reaped while away: activate is refused, resume mints a new runtime.
            await asyncio.sleep(0.8)
            late = await dial()
            await late.call("session.resume", {"session_id": key, "cols": 96, "source": "desktop",
                                               "omit_messages": True})
            await late.close()


async def hermes_scenario(ws_url: str, frames: list[dict[str, Any]], reap_wait: float) -> None:
    gateway = await handshake(ws_url, frames)
    created = await gateway.call("session.create", {"cols": 96, "source": "desktop"})
    sid, key = created["session_id"], created["stored_session_id"]
    await gateway.call("session.activate", {"session_id": sid, "cols": 96, "omit_messages": True})
    await gateway.call("session.resume", {"session_id": key, "cols": 96, "source": "desktop", "omit_messages": True})
    try:
        await gateway.call("prompt.submit", {"session_id": sid, "text": "hello there"})
        # Without a model the turn ends in an error; wait for it to settle.
        await asyncio.sleep(5)
    except RuntimeError as error:
        print("prompt.submit:", error, file=sys.stderr)
    await gateway.call("session.events.since", {"session_id": sid, "last_seen": 0})
    await gateway.close()
    if reap_wait > 0:
        await asyncio.sleep(reap_wait)
        late = await handshake(ws_url, frames)
        await late.call("session.resume", {"session_id": key, "cols": 96, "source": "desktop", "omit_messages": True})
        await late.close()


def scrub(value: Any, replacements: list[tuple[str, str]]) -> Any:
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [scrub(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: scrub(item, replacements) for key, item in value.items()}
    return value


def keep(frames: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """At most KEEP frames per result method, event type and request method, in arrival order."""
    seen: dict[str, int] = {}
    out = []
    for frame in frames:
        name = frame.get("method") or frame.get("params", {}).get("type") or frame.get("frame", {}).get("method")
        tag = f"{frame['kind']}:{name}"
        seen[tag] = seen.get(tag, 0) + 1
        if seen[tag] <= KEEP:
            out.append(frame)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", help="a running gateway's ws URL with its credential (default: in-process fake)")
    parser.add_argument("--source", default="devtools/fake_hermes.py", help="what the frames came from")
    parser.add_argument("--out", default="fake-hermes.json", help=f"file name under {FIXTURES.name}/")
    parser.add_argument("--reap-wait", type=float, default=0, help="with --url: wait this long, then resume cold")
    parser.add_argument("--scrub", action="append", default=[], metavar="TEXT=REPLACEMENT",
                        help="another string to replace before writing (repeatable)")
    args = parser.parse_args()

    frames: list[dict[str, Any]] = []
    if args.url:
        asyncio.run(hermes_scenario(args.url, frames, args.reap_wait))
    else:
        asyncio.run(fake_scenario(frames))

    home = str(Path.home())
    replacements = [tuple(item.split("=", 1)) for item in args.scrub]
    replacements += [(os.path.realpath(tempfile.gettempdir()), "/tmp"), (tempfile.gettempdir(), "/tmp"),
                     (home, "/Users/user"), (getpass.getuser(), "user"), (socket.gethostname(), "host")]
    kept = scrub(keep(frames), [(old, new) for old, new in replacements if old])
    FIXTURES.mkdir(parents=True, exist_ok=True)
    out = FIXTURES / args.out
    lines = ",\n".join("  " + json.dumps(frame, sort_keys=True, ensure_ascii=False) for frame in kept)
    out.write_text(f'{{"source": {json.dumps(args.source)}, "frames": [\n{lines}\n]}}\n', encoding="utf-8")
    print(f"wrote {len(kept)} of {len(frames)} frames to {out.relative_to(HERE.parent)}")


if __name__ == "__main__":
    main()
