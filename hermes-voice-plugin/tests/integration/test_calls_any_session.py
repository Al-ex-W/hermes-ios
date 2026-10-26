"""Opt-in (see conftest.py): ``start_call`` from a conversation outside the dashboard process, in a real Hermes.

The dashboard (``hermes serve --isolated``) serves the phone and the hub socket (``hub.sock``). A second Hermes
process in the same home runs the conversation: ``hermes chat -Q -q`` hands its turn to the gateway Hermes starts
for it (a session on the ``local`` platform; ``hermes -z`` goes the same way). Its ``start_call`` reaches the phone
through the hub socket:

- sync: the spoken reply comes back as the tool result in that process;
- async: the tool returns at once (the one-shot turn ends while the phone rings), and what the user says on the
  call starts a new turn in the gateway session (``ctx.inject_message``, allowed by ``allow_gateway_injection``):
  a user message stored in that session's transcript, whose ``start_call`` speaks into the same call.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import signal
import stat
import subprocess
import time
from pathlib import Path
from typing import Iterator, Optional

import pytest

from hermes_sandbox import Dashboard, Phone, Sandbox, StubModel, hermes_python
from scenario import Agent, tool_results

pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def sandbox(request) -> Iterator[tuple[Sandbox, StubModel]]:
    if os.environ.get("HERMES_VOICE_INTEGRATION") != "1":
        pytest.skip("set HERMES_VOICE_INTEGRATION=1 to run against a real Hermes")
    python, why = hermes_python()
    if python is None:
        pytest.skip(why)
    model = StubModel(Agent())
    root = os.environ.get("HERMES_VOICE_IT_TMP")
    box = Sandbox(python, model, root=Path(root) if root else None, ring_timeout_s=20.0)
    config_path = box.hermes_home / "config.yaml"
    config = json.loads(config_path.read_text(encoding="utf-8"))  # the sandbox writes JSON (valid YAML)
    config["plugins"]["entries"]["hermes_voice"]["allow_gateway_injection"] = True
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    failed_before = request.session.testsfailed
    try:
        box.start()
        yield box, model
    finally:
        _stop_gateway(box)
        box.stop()
        model.stop()
        if request.session.testsfailed > failed_before:
            print(f"\nhermes sandbox kept for inspection: {box.root}\n{box.log_tail(3000)}")
        else:
            shutil.rmtree(box.root, ignore_errors=True)


def _stop_gateway(box: Sandbox) -> None:
    """The gateway Hermes started for ``chat -q`` runs detached from the dashboard: stop it by its own pid file."""
    try:
        record = (box.hermes_home / "gateway.pid").read_text(encoding="utf-8").strip()
        pid = int(json.loads(record)["pid"]) if record.startswith("{") else int(record)
    except (OSError, ValueError, KeyError, TypeError):
        return
    for sig, wait in ((signal.SIGTERM, 15.0), (signal.SIGKILL, 5.0)):
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.kill(pid, sig)
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.2)


class Cli:
    """A Hermes command-line process in the sandbox's home (``hermes chat -Q -q …``): stdout and stderr go to files
    in the sandbox."""

    def __init__(self, box: Sandbox, name: str, *args: str) -> None:
        self.paths = (box.root / f"{name}.out", box.root / f"{name}.log")
        with open(self.paths[0], "w", encoding="utf-8") as out, open(self.paths[1], "w", encoding="utf-8") as log:
            self.proc = subprocess.Popen(
                [str(box.python), "-m", "hermes_cli.main", *args], cwd=str(box.home), env=box.env(),
                stdin=subprocess.DEVNULL, stdout=out, stderr=log, start_new_session=True)

    def output(self) -> str:
        texts = []
        for path in self.paths:
            with contextlib.suppress(OSError):
                texts.append(path.read_text(encoding="utf-8", errors="replace")[-3000:])
        return "\n".join(texts)

    async def wait(self, timeout: float = 90.0) -> int:
        return await asyncio.to_thread(self.proc.wait, timeout)

    def kill(self) -> None:
        if self.proc.poll() is None:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(self.proc.pid, signal.SIGKILL)


async def next_push(dashboard: Dashboard, seen: int, cli: Cli, timeout: float = 120.0) -> Optional[dict]:
    """The first VoIP push after the first `seen`, while the CLI process runs (or within 5 s of it exiting)."""
    deadline = time.monotonic() + timeout
    exited: Optional[float] = None
    while time.monotonic() < deadline:
        pushes = await dashboard.pushes()
        if len(pushes) > seen:
            return pushes[seen]
        if cli.proc.poll() is not None:
            exited = exited or time.monotonic()
            if time.monotonic() - exited > 5:
                return None
        await asyncio.sleep(0.3)
    return None


async def stored(dashboard: Dashboard, session_id: str, needle: str, timeout: float = 30.0) -> list[dict]:
    """The session's stored messages, once one of them says `needle`."""
    deadline = time.monotonic() + timeout
    messages: list[dict] = []
    while time.monotonic() < deadline:
        messages = await dashboard.messages(session_id)
        if any(needle in content(message) for message in messages):
            return messages
        await asyncio.sleep(0.5)
    raise AssertionError(f"{session_id}'s stored messages never said {needle!r}: {messages[-6:]}")


def content(message: dict) -> str:
    return json.dumps(message.get("content"), ensure_ascii=False)


def rings(box: Sandbox) -> list[dict]:
    path = box.hermes_home / "hermes-voice" / "rings.jsonl"
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def test_a_sync_call_from_a_cli_turn_returns_the_reply_to_that_process(sandbox):
    box, model = sandbox

    async def scenario():
        folder = box.hermes_home / "hermes-voice"
        deadline = time.monotonic() + 30
        while not (folder / "hub.sock").exists() and time.monotonic() < deadline:
            await asyncio.sleep(0.2)
        modes = (stat.S_IMODE(os.stat(folder / "hub.sock").st_mode), stat.S_IMODE(folder.stat().st_mode),
                 stat.S_IMODE((folder / "hub.token").stat().st_mode))
        dashboard = Dashboard(box)
        cli = None
        try:
            assert (await dashboard.sign_in()).status_code == 200
            assert (await dashboard.post("/api/plugins/hermes_voice_it/arm")).status_code == 200
            cli = Cli(box, "cli-sync", "chat", "-Q", "-q", "call me sync: Ship it?")
            push = await next_push(dashboard, 0, cli)
            assert push, cli.output()
            phone = await Phone.dial(dashboard, push["call_id"], "push", session_id=push["session_id"])
            await phone.send({"type": "ringing"})
            await phone.send({"type": "answered"})
            await phone.heard("Ship it?")
            await asyncio.sleep(0.3)
            await phone.say("yes please")
            code = await cli.wait(90)
            # The conversation is idle now: what the user says starts a turn in the gateway session.
            await phone.say("one more thing")
            answer = await phone.heard("You said one more thing", timeout=90)
            messages = await stored(dashboard, push["session_id"], "[Voice] one more thing")
            deliveries = await dashboard.deliveries()
            pushes = await dashboard.pushes()
            await phone.hang_up()
            return modes, push, code, cli.output(), answer, messages, deliveries, pushes
        finally:
            if cli is not None:
                cli.kill()
            await dashboard.close()

    modes, push, code, output, answer, messages, deliveries, pushes = asyncio.run(scenario())
    assert modes == (0o600, 0o700, 0o600)
    assert push["mode"] == "sync" and push["session_id"].startswith("local-")
    assert code == 0, output
    with model.lock:
        bodies = list(model.requests)
    replies = [r for r in tool_results(bodies) if r.get("call_id") == push["call_id"] and "said" in r]
    assert replies and replies[0]["said"] == "yes please" and replies[0]["outcome"] == "answered"
    assert answer["text"] == "You said one more thing."
    assert len(pushes) == 1  # the gateway's own start_call spoke into the call: no second ring
    injected = [d for d in deliveries if d["text"].startswith("[Voice] one more thing")]
    assert injected and injected[0]["ok"] and injected[0]["via"] == "inject", deliveries
    users = [content(m) for m in messages if m.get("role") == "user"]
    assert any("[Voice] one more thing" in text for text in users), messages
    # The sync reply went back to the tool, never into the conversation as a turn of its own.
    assert not any("[Voice] yes please" in text for text in users), messages
    assert rings(box)[0]["event"] == "ring" and rings(box)[0]["source"] == "cli"


def test_an_async_call_from_a_finished_cli_turn_injects_the_reply_into_its_session(sandbox):
    box, model = sandbox

    async def scenario():
        dashboard = Dashboard(box)
        cli = None
        try:
            assert (await dashboard.sign_in()).status_code == 200
            assert (await dashboard.post("/api/plugins/hermes_voice_it/arm")).status_code == 200
            seen = len(await dashboard.pushes())
            cli = Cli(box, "cli-async", "chat", "-Q", "-q", "call me async: The build is green.")
            push = await next_push(dashboard, seen, cli)
            assert push, cli.output()
            # An async start_call returns at once: the CLI's turn ends while the phone still rings.
            code = await cli.wait(90)
            phone = await Phone.dial(dashboard, push["call_id"], "push", session_id=push["session_id"])
            await phone.send({"type": "ringing"})
            await phone.send({"type": "answered"})
            await phone.heard("The build is green.")
            await asyncio.sleep(0.3)
            await phone.say("great, deploy it")
            answer = await phone.heard("You said great, deploy it", timeout=90)
            messages = await stored(dashboard, push["session_id"], "[Voice] great, deploy it")
            deliveries = await dashboard.deliveries()
            await phone.hang_up()
            return push, code, cli.output(), answer, messages, deliveries
        finally:
            if cli is not None:
                cli.kill()
            await dashboard.close()

    push, code, output, answer, messages, deliveries = asyncio.run(scenario())
    assert push["mode"] == "async" and push["session_id"].startswith("local-")
    assert code == 0, output
    with model.lock:
        bodies = list(model.requests)
    started = [r for r in tool_results(bodies) if r.get("call_id") == push["call_id"] and "status" in r]
    assert started and started[0]["status"] == "ringing", started
    assert "allow_gateway_injection" not in str(started[0].get("note"))
    assert answer["text"] == "You said great, deploy it."
    injected = [d for d in deliveries if d["call_id"] == push["call_id"] and d["text"].startswith("[Voice] great")]
    assert injected and injected[0]["ok"] and injected[0]["via"] == "inject", deliveries
    # What the user said is a user turn of that gateway session, stored in its transcript.
    users = [content(m) for m in messages if m.get("role") == "user"]
    assert any("[Voice] great, deploy it" in text for text in users), messages
    assert [r["source"] for r in rings(box) if r.get("event") == "ring"][-1] == "cli"
