"""Opt-in (see conftest.py): a call from a dashboard conversation whose turns run in a compute-host child
(``dashboard.turn_isolation``), in a real Hermes.

The child holds a copy of the dashboard's session, but its turns are the dashboard's to start. What the user says
while the conversation is idle must go through the dashboard's own ``prompt.submit`` (which sends the turn to the
child): then the dashboard shows the conversation running, and a prompt the user types meanwhile is queued after
the voice turn instead of being refused as "session busy" by the child.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import time
from pathlib import Path
from typing import Iterator

import pytest

import hermes_sandbox as hs
from scenario import Agent, start_call_result
from test_alerts_real_hermes import _alive, _descendants

pytestmark = pytest.mark.integration


class IsolatedSandbox(hs.Sandbox):
    def _write(self, ring_timeout_s: float) -> None:
        super()._write(ring_timeout_s)
        path = self.hermes_home / "config.yaml"
        config = json.loads(path.read_text(encoding="utf-8"))
        config["dashboard"]["turn_isolation"] = True
        path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")

    def stop(self) -> None:
        """Also ends the compute-host children (each runs in a session of its own)."""
        children = _descendants(self.proc.pid) if self.proc is not None else []
        super().stop()
        deadline = time.monotonic() + 10.0
        for pid in children:
            while _alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            if _alive(pid):
                try:
                    os.kill(pid, 9)
                except (ProcessLookupError, PermissionError):
                    pass


@pytest.fixture(scope="module")
def isolated(request) -> Iterator[tuple[IsolatedSandbox, hs.StubModel, Agent]]:
    if os.environ.get("HERMES_VOICE_INTEGRATION") != "1":
        pytest.skip("set HERMES_VOICE_INTEGRATION=1 to run against a real Hermes")
    python, why = hs.hermes_python()
    if python is None:
        pytest.skip(why)
    agent = Agent()
    model = hs.StubModel(agent)
    root = os.environ.get("HERMES_VOICE_IT_TMP")
    sandbox = IsolatedSandbox(python, model, root=Path(root) if root else None, ring_timeout_s=10.0)
    failures = request.session.testsfailed
    started = False
    try:
        sandbox.start()
        started = True
        yield sandbox, model, agent
    finally:
        sandbox.stop()
        model.stop()
        if not started or request.session.testsfailed > failures:
            print(f"\nhermes sandbox kept for inspection: {sandbox.root}\n{sandbox.log_tail(3000)}")
        else:
            for _ in range(20):
                shutil.rmtree(sandbox.root, ignore_errors=True)
                if not sandbox.root.exists():
                    break
                time.sleep(0.5)


async def delivery_of(dashboard: hs.Dashboard, call_id: str, prefix: str, timeout: float = 45.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for delivery in await dashboard.deliveries():
            if delivery["call_id"] == call_id and delivery["text"].startswith(prefix):
                return delivery
        await asyncio.sleep(0.2)
    raise AssertionError(f"nothing delivered for {prefix!r}: {await dashboard.deliveries()}")


def test_an_idle_voice_turn_is_started_by_the_dashboard_and_a_typed_prompt_waits_for_it(isolated):
    sandbox, model, agent = isolated
    agent.slow["pasta"] = 6.0  # keeps the voice turn running while the user types

    async def scenario():
        dashboard = hs.Dashboard(sandbox)
        gateway = None
        try:
            assert (await dashboard.sign_in()).status_code == 200
            assert (await dashboard.post(f"{hs.HELPER}/arm")).status_code == 200
            gateway = await hs.Gateway.open(dashboard)
            created = await gateway.call("session.create", {"source": "desktop", "title": "Isolated call"})
            sid, stored = created["session_id"], created["stored_session_id"]
            mark = len(gateway.events)
            await gateway.call("prompt.submit", {"session_id": sid, "text": "call me async: What should we cook?"})
            await gateway.event("message.complete", lambda e: e.get("session_id") == sid, after=mark, timeout=90)
            started = start_call_result(model.requests, key="status")
            push = await dashboard.push_for(stored)
            phone = await hs.Phone.dial(dashboard, push["call_id"], "push", session_id=push["session_id"])
            await phone.send({"type": "ringing"})
            await phone.send({"type": "answered"})
            await phone.heard("What should we cook?")
            await asyncio.sleep(0.3)
            mark = len(gateway.events)
            await phone.say("pasta")
            voice = await delivery_of(dashboard, push["call_id"], "[Voice] pasta")
            assert voice["ok"] and voice["via"] == "submit", await dashboard.deliveries()
            await asyncio.to_thread(model.wait_for, "[Voice] pasta")
            await asyncio.sleep(1.0)  # the voice turn runs (the model takes 6 s)
            typed = await gateway.call("prompt.submit", {"session_id": sid, "text": "hello there"})
            heard = await phone.heard("You said pasta.", timeout=60)
            saw_typed = await asyncio.to_thread(model.wait_for, "hello there", 90)
            await asyncio.sleep(2.0)
            errors = [e for e in gateway.events[mark:] if e.get("type") == "message.complete"
                      and (e.get("payload") or {}).get("status") == "error"]
            deliveries = await dashboard.deliveries()
            await phone.hang_up()
            return started, push, typed, heard, saw_typed, errors, deliveries
        finally:
            if gateway is not None:
                await gateway.close()
            await dashboard.close()

    started, push, typed, heard, saw_typed, errors, deliveries = asyncio.run(scenario())
    assert started and started["status"] == "ringing", started
    # The dashboard knows the voice turn runs, so the typed prompt goes through its busy handling (queued, or a
    # correction of the running turn), and nothing fails as "session busy" in the child.
    assert typed.get("status") in ("queued", "redirected", "steered"), typed
    assert "hello there" in saw_typed and errors == [], errors
    assert heard["text"] == "You said pasta."
    voice = [d for d in deliveries if d["call_id"] == push["call_id"] and d["text"].startswith("[Voice] pasta")]
    assert voice and voice[0]["ok"] and voice[0]["via"] == "submit", deliveries
