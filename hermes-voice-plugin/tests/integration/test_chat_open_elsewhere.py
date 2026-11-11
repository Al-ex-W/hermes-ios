"""Opt-in (see conftest.py): a call whose chat another Hermes process holds, in a real Hermes.

Hermes keeps one writer per conversation: the process that ran a turn in a chat holds it (a lease in
``<HERMES_HOME>/runtime/active_sessions.json``) while it has the chat open, and every other process's
``prompt.submit`` for it is refused with 4090 / ``SESSION_NOT_OWNED`` ("This chat is open in another Hermes
window/terminal"). The dashboard (``hermes serve --isolated``) serves the phone here; a second process in the same
home holds the chat the user calls in:

- a backend the Desktop app would spawn (``hermes serve --isolated`` with ``HERMES_DESKTOP=1`` and a session token:
  Hermes' own test for a Desktop-owned backend). It loads this plugin, attends on the dashboard's hub socket, and
  puts the call's notice and turns into its own live session; its agent answers through the hub socket;
- a process without the plugin that took the lease the way the classic CLI does (``try_acquire_active_session``).
  Nothing can write the chat: the user hears so at once, the ring log says so, and once that process is gone the
  call's notice and what the user said meanwhile are put in, in order, marked as delayed.
"""

from __future__ import annotations

import asyncio
import contextlib
import inspect
import json
import os
import secrets
import shutil
import signal
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Iterator, Optional

import pytest
import websockets

from hermes_sandbox import READY, Dashboard, Gateway, Phone, Sandbox, StubModel, free_port, hermes_python
from scenario import Agent

pytestmark = pytest.mark.integration

HELD_SPOKEN = "I can't reach this chat right now"


class DesktopBackend:
    """A second ``hermes serve`` in the sandbox's home, as the Desktop app spawns its local backend: its own port,
    ``HERMES_DESKTOP=1`` and a session token only the Desktop knows (clients open ``/api/ws?token=…``)."""

    def __init__(self, box: Sandbox) -> None:
        self.box = box
        self.port = free_port()
        self.token = secrets.token_hex(16)
        self.log_path = box.root / "desktop-backend.log"
        self.proc: Optional[subprocess.Popen] = None

    def start(self, timeout: float = 180.0) -> None:
        env = self.box.env()
        env.update(HERMES_DESKTOP="1", HERMES_DASHBOARD_SESSION_TOKEN=self.token)
        self._log = open(self.log_path, "a", encoding="utf-8")  # noqa: SIM115 - closed in stop()
        self.proc = subprocess.Popen(
            [str(self.box.python), "-m", "hermes_cli.main", "serve", "--isolated", "--host", "127.0.0.1",
             "--port", str(self.port)],
            cwd=str(self.box.home), env=env, stdin=subprocess.DEVNULL, stdout=self._log, stderr=subprocess.STDOUT,
            start_new_session=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"the Desktop backend exited ({self.proc.returncode}):\n{self.log_tail()}")
            if READY.search(self.log_tail(20000)):
                return
            time.sleep(0.25)
        raise RuntimeError(f"the Desktop backend did not come up in {timeout:.0f}s:\n{self.log_tail()}")

    def log_tail(self, size: int = 4000) -> str:
        try:
            return self.log_path.read_text(encoding="utf-8", errors="replace")[-size:]
        except OSError:
            return ""

    async def gateway(self) -> Gateway:
        socket = await websockets.connect(f"ws://127.0.0.1:{self.port}/api/ws?token={self.token}", proxy=None,
                                          max_size=8 * 1024 * 1024, open_timeout=20)
        gateway = Gateway(socket)
        await gateway.event("gateway.ready", timeout=60)
        return gateway

    def stop(self) -> None:
        _stop(self.proc)
        with contextlib.suppress(Exception):
            self._log.close()


def _stop(proc: Optional[subprocess.Popen]) -> None:
    if proc is None:
        return
    for sig, wait in ((signal.SIGTERM, 20), (signal.SIGKILL, 10)):
        if proc.poll() is not None:
            return
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(proc.pid, sig)
        with contextlib.suppress(subprocess.TimeoutExpired):
            proc.wait(timeout=wait)


@pytest.fixture(scope="module")
def home(request) -> Iterator[tuple[Sandbox, StubModel, DesktopBackend]]:
    if os.environ.get("HERMES_VOICE_INTEGRATION") != "1":
        pytest.skip("set HERMES_VOICE_INTEGRATION=1 to run against a real Hermes")
    python, why = hermes_python()
    if python is None:
        pytest.skip(why)
    model = StubModel(Agent())
    root = os.environ.get("HERMES_VOICE_IT_TMP")
    box = Sandbox(python, model, root=Path(root) if root else None, ring_timeout_s=10.0)
    backend = DesktopBackend(box)
    failed_before = request.session.testsfailed
    try:
        box.start()
        backend.start()
        yield box, model, backend
    finally:
        backend.stop()
        box.stop()
        model.stop()
        if request.session.testsfailed > failed_before:
            print(f"\nhermes sandbox kept for inspection: {box.root}\n{box.log_tail(3000)}\n"
                  f"--- desktop backend\n{backend.log_tail(3000)}\n{box.agent_logs(4000)}")
        else:
            shutil.rmtree(box.root, ignore_errors=True)


@contextlib.asynccontextmanager
async def signed_in(box: Sandbox):
    dashboard = Dashboard(box)
    try:
        assert (await dashboard.sign_in()).status_code == 200
        assert (await dashboard.post("/api/plugins/hermes_voice_it/arm")).status_code == 200
        yield dashboard
    finally:
        await dashboard.close()


def leases(box: Sandbox) -> dict[str, dict[str, Any]]:
    """Hermes' live-session leases by stored session id (``runtime/active_sessions.json``)."""
    try:
        data = json.loads((box.hermes_home / "runtime" / "active_sessions.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return {str(entry.get("session_id")): entry for entry in data.get("entries") or []}


def ring_log(box: Sandbox, call_id: str) -> list[dict[str, Any]]:
    path = box.hermes_home / "hermes-voice" / "rings.jsonl"
    entries = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    return [entry for entry in entries if entry.get("call_id") == call_id]


async def chat_with_a_turn(gateway: Gateway, text: str) -> tuple[str, str]:
    """A new conversation with one finished turn: (runtime session id, stored id)."""
    created = await gateway.call("session.create", {"source": "desktop"})
    seen = len(gateway.events)
    await gateway.call("prompt.submit", {"session_id": created["session_id"], "text": text})
    await gateway.event("message.complete", after=seen, timeout=90)
    return created["session_id"], created["stored_session_id"]


async def deliveries_for(dashboard: Dashboard, call_id: str) -> list[dict]:
    return [d for d in await dashboard.deliveries() if d["call_id"] == call_id]


async def until(check, timeout: float = 30.0, what: str = "") -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if inspect.isawaitable(value):
            value = await value
        if value:
            return value
        await asyncio.sleep(0.2)
    raise AssertionError(f"never: {what}")


def test_a_call_in_a_chat_a_desktop_backend_holds_is_put_in_by_that_backend(home):
    """The owner's case: the chat is open in the Desktop app, and the user calls from the phone in it."""
    box, model, backend = home

    async def scenario() -> None:
        desktop = await backend.gateway()
        async with signed_in(box) as dashboard:
            _, stored = await chat_with_a_turn(desktop, "hello from the desktop")
            held = leases(box)[stored]
            assert held["pid"] == backend.proc.pid and held["surface"] == "desktop", held
            # Hermes itself refuses the dashboard: the refusal this plugin's deliveries used to end in.
            viewer = await Gateway.open(dashboard)
            copy = await viewer.call("session.resume", {"session_id": stored, "source": "desktop"})
            with pytest.raises(RuntimeError, match="open in another Hermes window") as refused:
                await viewer.call("prompt.submit", {"session_id": copy["session_id"], "text": "typed in the app"})
            assert "4090" in str(refused.value) and "SESSION_NOT_OWNED" in str(refused.value)

            call_id = uuid.uuid4().hex
            phone = await Phone.dial(dashboard, call_id, "user", session_id=stored, title="Desktop chat")
            assert phone.ready["state"] == "live"
            # The Desktop backend's agent gets the notice.
            await asyncio.to_thread(model.wait_for, "[Voice call started]", 60)
            await phone.say("can you hear me")
            await phone.heard("You said can you hear me.", timeout=90)  # answered from the backend, into the call
            await phone.say("and again")
            await phone.heard("You said and again.", timeout=90)
            mine = await deliveries_for(dashboard, call_id)
            assert [d["ok"] for d in mine] == [True, True, True], mine
            # The notice and the first turn went through the process that holds the chat; once its agent spoke
            # into the call, that process takes the call's turns itself (its subscription).
            assert mine[0]["via"].startswith("holder:") and mine[1]["via"].startswith("holder:"), mine
            assert not any(HELD_SPOKEN in str(m.get("text")) for m in phone.messages)
            await phone.hang_up()
            await asyncio.to_thread(model.wait_for, "[Voice call ended by user]", 60)
            assert not [e for e in ring_log(box, call_id) if e["event"] in ("chat_held", "undelivered")]
            await viewer.close()
        await desktop.close()

    asyncio.run(scenario())


LEASE_HOLDER = """
import sys, time
from hermes_cli.active_sessions import try_acquire_active_session
lease, refusal = try_acquire_active_session(session_id=sys.argv[1], surface="cli", config={},
                                            metadata={"live_session_id": sys.argv[1]})
print("held" if lease is not None and refusal is None else f"refused: {refusal}", flush=True)
time.sleep(600)
"""


def test_a_chat_no_reachable_process_holds_is_announced_then_delivered_late(home):
    """The chat is held by a process that can't be asked (the classic CLI's lease; a Hermes without this plugin).
    The user hears at once that the chat can't be reached; when the holder is gone, everything arrives in order."""
    box, model, backend = home

    async def scenario() -> None:
        async with signed_in(box) as dashboard:
            gateway = await Gateway.open(dashboard)
            sid, stored = await chat_with_a_turn(gateway, "hello from the dashboard")
            await gateway.call("session.close", {"session_id": sid})  # the dashboard lets go of the chat
            await until(lambda: stored not in leases(box), what="the dashboard's lease released")
            out = box.root / "lease-holder.out"
            with open(out, "w", encoding="utf-8") as log:
                holder = subprocess.Popen([str(box.python), "-c", LEASE_HOLDER, stored], cwd=str(box.home),
                                          env=box.env(), stdin=subprocess.DEVNULL, stdout=log,
                                          stderr=subprocess.STDOUT, start_new_session=True)
            try:
                await until(lambda: out.read_text(encoding="utf-8").strip(), what="lease taken")
                assert out.read_text(encoding="utf-8").strip() == "held", out.read_text(encoding="utf-8")
                assert leases(box)[stored]["pid"] == holder.pid

                call_id = uuid.uuid4().hex
                phone = await Phone.dial(dashboard, call_id, "user", session_id=stored, title="CLI chat")
                await phone.heard(HELD_SPOKEN, timeout=30)  # at once, from the hub itself
                await phone.say("are you there")
                await asyncio.sleep(5.0)  # a retry or two: still held
                assert await deliveries_for(dashboard, call_id) == []
                assert "[Voice call started]" not in model.seen().split("hello from the dashboard")[-1]
                held = [e for e in ring_log(box, call_id) if e["event"] == "chat_held"]
                assert len(held) == 1 and held[0]["announced"] is True and held[0]["holder"] == "cli", held
            finally:
                _stop(holder)
            await phone.heard("You said are you there.", timeout=90)  # the kept turn, answered into the call
            seen = model.seen()
            assert seen.index("[Voice call started]", seen.index("hello from the dashboard")) < seen.index(
                "[Voice] are you there")
            assert "Delayed by" in seen and "open in another Hermes window" in seen
            mine = await until(lambda: deliveries_for(dashboard, call_id), what="late deliveries")
            assert all(d["ok"] for d in mine), mine
            assert len([m for m in phone.messages if HELD_SPOKEN in str(m.get("text"))]) == 1  # said once
            await phone.hang_up()
            log = ring_log(box, call_id)
            assert [e["what"] for e in log if e["event"] == "delivered_late"] == ["call_started", "turn"], log
            assert not [e for e in log if e["event"] == "undelivered"], log
            assert "are you there" not in json.dumps(log) and HELD_SPOKEN not in json.dumps(log)
            await gateway.close()

    asyncio.run(scenario())
