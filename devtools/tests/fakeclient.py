"""Test harness: an in-process fake Hermes, a signed-in HTTP client, a gateway WebSocket client, and a small
JSON-schema checker for the pinned OpenRPC contract."""

from __future__ import annotations

import asyncio
import json
import os
import socket
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

import httpx
import uvicorn
import websockets

from fake_hermes import DEFAULT_CONTRACT, FakeHermes, build_app, build_parser

# The pinned contract when it exists, or HERMES_GATEWAY_CONTRACT (e.g. the one in a Hermes checkout).
CONTRACT_PATH = os.environ.get("HERMES_GATEWAY_CONTRACT") or (
    str(DEFAULT_CONTRACT) if DEFAULT_CONTRACT.is_file() else "")


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@asynccontextmanager
async def serving(**options: Any) -> AsyncIterator[tuple[FakeHermes, str]]:
    """Run a fake Hermes on a free port; yields it and its ``host:port``. Options override the CLI defaults."""
    args = build_parser().parse_args(["--voice-url", "", "--contract", CONTRACT_PATH])
    for name, value in options.items():
        setattr(args, name, value)
    fake = FakeHermes(args)
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(build_app(fake), host="127.0.0.1", port=port, log_level="warning",
                                           timeout_graceful_shutdown=1))
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            task.result()
        await asyncio.sleep(0.01)
    try:
        yield fake, f"127.0.0.1:{port}"
    finally:
        server.should_exit = True
        await task


@asynccontextmanager
async def signed_in(base: str) -> AsyncIterator[httpx.AsyncClient]:
    async with httpx.AsyncClient(base_url=f"http://{base}", timeout=10) as http:
        response = await http.post("/auth/password-login", json={"provider": "basic", "username": "test",
                                                                  "password": "test"})
        assert response.status_code == 200, response.text
        yield http


class RpcFailure(Exception):
    def __init__(self, error: dict[str, Any]) -> None:
        super().__init__(f"{error.get('code')}: {error.get('message')}")
        self.code = error.get("code")
        self.message = error.get("message")


class Gateway:
    """One /api/ws connection that records every frame."""

    def __init__(self, ws: Any) -> None:
        self.ws = ws
        self.next_id = 0
        self.pending: dict[int, asyncio.Future] = {}
        self.frames: list[dict[str, Any]] = []
        self.events: list[dict[str, Any]] = []
        self.results: list[tuple[str, dict[str, Any]]] = []
        self.inbox: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.requests: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.ready: dict[str, Any] = {}
        self.capabilities: dict[str, Any] | None = None
        self.reader = asyncio.create_task(self._read())

    @classmethod
    async def connect(cls, base: str, http: httpx.AsyncClient, capabilities: bool = True) -> "Gateway":
        ticket = (await http.post("/api/auth/ws-ticket")).json()["ticket"]
        gateway = cls(await websockets.connect(f"ws://{base}/api/ws?ticket={ticket}"))
        gateway.ready = await gateway.event("gateway.ready")
        if capabilities:
            gateway.capabilities = await gateway.call("client.capabilities", {"server_requests": True})
        return gateway

    async def _read(self) -> None:
        try:
            async for raw in self.ws:
                frame = json.loads(raw)
                self.frames.append(frame)
                if "method" not in frame:
                    if (future := self.pending.pop(frame.get("id"), None)) is not None and not future.done():
                        future.set_result(frame)
                elif frame["method"] == "event":
                    self.events.append(frame["params"])
                    await self.inbox.put(frame["params"])
                else:
                    await self.requests.put(frame)
        except websockets.ConnectionClosed:
            pass

    async def call_frame(self, method: str, params: dict[str, Any] | None = None, timeout: float = 5) -> dict:
        self.next_id += 1
        rid = self.next_id
        future = asyncio.get_running_loop().create_future()
        self.pending[rid] = future
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}}))
        frame = await asyncio.wait_for(future, timeout)
        if "result" in frame:
            self.results.append((method, frame["result"]))
        return frame

    async def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 5) -> dict[str, Any]:
        frame = await self.call_frame(method, params, timeout)
        if "error" in frame:
            raise RpcFailure(frame["error"])
        return frame["result"]

    async def event(self, kind: str, timeout: float = 5) -> dict[str, Any]:
        """The next event of ``kind`` (earlier ones of other kinds are skipped; all stay in ``events``)."""
        async with asyncio.timeout(timeout):
            while (event := await self.inbox.get())["type"] != kind:
                pass
        return event

    async def request(self, method: str | None = None, timeout: float = 5) -> dict[str, Any]:
        frame = await asyncio.wait_for(self.requests.get(), timeout)
        assert method is None or frame["method"] == method, frame
        return frame

    async def respond(self, rid: str, result: dict[str, Any]) -> None:
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}))

    async def fail(self, rid: str, code: int, message: str) -> None:
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}))

    async def close(self) -> None:
        await self.ws.close()
        await self.reader

    def kinds(self) -> list[str]:
        return [e["type"] for e in self.events]


async def until(predicate: Any, timeout: float = 5) -> None:
    async with asyncio.timeout(timeout):
        while not predicate():
            await asyncio.sleep(0.02)


class Contract:
    """Checks fake output against the OpenRPC contract: results, event payloads, server-request params."""

    def __init__(self, path: str) -> None:
        doc = json.loads(Path(path).read_text())
        self.schemas = doc["components"]["schemas"]
        self.results = {m["name"]: m["result"]["schema"] for m in doc["methods"]}
        self.events = {n["name"]: n["params"][0]["schema"] for n in doc["x-notifications"]}
        self.requests = {r["name"]: r["params"][0]["schema"] for r in doc["x-server-requests"]}

    def problems(self, schema: dict[str, Any], value: Any, at: str = "") -> list[str]:
        while "$ref" in schema:
            schema = self.schemas[schema["$ref"].rsplit("/", 1)[-1]]
        for key in ("anyOf", "oneOf"):
            if key in schema:
                options = [self.problems(option, value, at) for option in schema[key]]
                return [] if any(not p for p in options) else [f"{at or '.'}: matches no {key} option: {options}"]
        if "const" in schema and value != schema["const"]:
            return [f"{at}: {value!r} != const {schema['const']!r}"]
        if "enum" in schema and value not in schema["enum"]:
            return [f"{at}: {value!r} not in {schema['enum']}"]
        kind = schema.get("type")
        checks = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}
        if kind in checks and not isinstance(value, checks[kind]):
            return [f"{at}: {value!r} is not {kind}"]
        if kind in ("integer", "number") and (isinstance(value, bool) or not isinstance(
                value, int if kind == "integer" else (int, float))):
            return [f"{at}: {value!r} is not {kind}"]
        out: list[str] = []
        if isinstance(value, dict):
            props = schema.get("properties", {})
            out += [f"{at}.{key}: required" for key in schema.get("required", []) if key not in value]
            extra = schema.get("additionalProperties", True)
            for key, item in value.items():
                if key in props:
                    out += self.problems(props[key], item, f"{at}.{key}")
                elif extra is False:
                    out.append(f"{at}.{key}: not in the contract")
                elif isinstance(extra, dict):
                    out += self.problems(extra, item, f"{at}.{key}")
        if isinstance(value, list) and "items" in schema:
            for index, item in enumerate(value):
                out += self.problems(schema["items"], item, f"{at}[{index}]")
        return out

    def check_gateway(self, gateway: Gateway) -> list[str]:
        """Every result, event and server request this connection saw."""
        out: list[str] = []
        for method, result in gateway.results:
            out += [f"result {method}{p}" for p in self.problems(self.results[method], result)]
        for frame in gateway.frames:
            params = frame.get("params") or {}
            if frame.get("method") == "event":
                schema = self.events.get(params.get("type"))
                if schema is None:
                    out.append(f"event {params.get('type')}: not in the contract")
                elif "payload" in params:
                    out += [f"event {params['type']}{p}" for p in self.problems(schema, params["payload"])]
            elif "method" in frame:
                out += [f"request {frame['method']}{p}" for p in self.problems(self.requests[frame["method"]], params)]
        return out
