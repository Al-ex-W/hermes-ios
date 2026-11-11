"""Opt-in (see conftest.py): calls that ring later (``start_call`` with ``in_minutes``), in a real ``hermes serve``.

A dashboard conversation schedules a call and goes idle; its client leaves and Hermes reaps it. At the call's time
the plugin rings by itself, speaks the line once the scripted phone answers, tells the conversation which call this
is, and what the phone says becomes a stored turn of that conversation (the plugin reopens it), answered into the
call. Then: a ring nobody answers is repeated once and the conversation told; and a scheduled call survives a
restart of the dashboard.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import stat
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator

import pytest

import hermes_sandbox as hs
from scenario import Agent, invoke, start_call_result
from test_real_hermes import new_session, signed_in, submit, turn_done

pytestmark = pytest.mark.integration

CALL_LATER = re.compile(r"call me in (\d+(?:\.\d+)?) s: ([^\n]+)")
RETRY_AFTER_S = 8.0


class LaterAgent(Agent):
    """The scenario agent, which also schedules: ``call me in <seconds> s: <text>`` ->
    ``start_call {text, in_minutes}``."""

    def __call__(self, body: dict[str, Any]) -> Any:
        recent = hs.since_last_reply(body)
        last = recent[-1] if recent else {}
        match = CALL_LATER.search(hs.message_text(last)) if last.get("role") == "user" else None
        if match:
            return invoke(body, "start_call", {"text": match.group(2).strip(),
                                               "in_minutes": float(match.group(1)) / 60.0})
        return super().__call__(body)


class TimedSandbox(hs.Sandbox):
    def _write(self, ring_timeout_s: float) -> None:
        super()._write(ring_timeout_s)
        path = self.hermes_home / "config.yaml"
        config = json.loads(path.read_text(encoding="utf-8"))
        config["plugins"]["entries"]["hermes_voice"]["settings"]["scheduled"] = {"retry_after_s": RETRY_AFTER_S}
        path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")

    def restart(self) -> None:
        """Stop the dashboard and start it again in the same home (its log starts afresh: ``start`` waits for
        the ready line)."""
        self.stop()
        self.log_path.rename(self.root / "hermes.before-restart.log")
        self.start()

    @property
    def schedule_file(self) -> Path:
        return self.hermes_home / "hermes-voice" / "scheduled.json"

    def ring_log(self, *events: str) -> list[dict]:
        path = self.hermes_home / "hermes-voice" / "rings.jsonl"
        entries = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        return [entry for entry in entries if entry["event"] in events]

    def rang_after(self, scheduled_id: str) -> float:
        """How long after its time the scheduled call first rang, by the ring log (whole seconds)."""
        mine = [entry for entry in self.ring_log("scheduled", "ring") if entry.get("scheduled") == scheduled_id]
        due = datetime.fromisoformat(mine[0]["rings_at"])
        return (datetime.fromisoformat(mine[1]["at"]) - due).total_seconds()


@pytest.fixture(scope="module")
def timed(request) -> Iterator[tuple[TimedSandbox, hs.StubModel, LaterAgent]]:
    if os.environ.get("HERMES_VOICE_INTEGRATION") != "1":
        pytest.skip("set HERMES_VOICE_INTEGRATION=1 to run against a real Hermes")
    python, why = hs.hermes_python()
    if python is None:
        pytest.skip(why)
    agent = LaterAgent()
    model = hs.StubModel(agent)
    root = os.environ.get("HERMES_VOICE_IT_TMP")
    sandbox = TimedSandbox(python, model, root=Path(root) if root else None, ring_timeout_s=6.0)
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
            shutil.rmtree(sandbox.root, ignore_errors=True)


async def schedule(sandbox, model, title: str, seconds: float, text: str) -> tuple[str, dict, dict]:
    """A conversation that schedules a call and goes idle: its stored id, the tool result and ``/status``. Its
    client is gone when this returns."""
    async with signed_in(sandbox) as (dashboard, gateway):
        sid, stored = await new_session(gateway, title)
        await turn_done(gateway, sid, await submit(gateway, sid, f"call me in {seconds:g} s: {text}"))
        result = start_call_result(model.requests, key="scheduled_id")
        status = (await dashboard.get(f"{hs.PREFIX}/status")).json()
    assert result, "the agent got no scheduling result"
    return stored, result, status


def stored_turns(messages: list[dict], role: str) -> list[str]:
    return [hs.message_text(message) for message in messages if message.get("role") == role]


def test_a_scheduled_call_rings_an_idle_conversation_and_the_reply_becomes_its_turn(timed):
    sandbox, model, _ = timed

    async def scenario():
        stored, scheduled, status = await schedule(sandbox, model, "Timed call", 14, "Time to get up.")
        on_disk = sandbox.schedule_file.read_text(encoding="utf-8")
        mode = stat.S_IMODE(sandbox.schedule_file.stat().st_mode)
        await asyncio.sleep(hs.REAP_GRACE_S + 3)  # nobody has the conversation open: Hermes reaped it
        dashboard = hs.Dashboard(sandbox)
        try:
            assert (await dashboard.sign_in()).status_code == 200
            early = [p for p in await dashboard.pushes() if p.get("session_id") == stored]
            push = await dashboard.push_for(stored, timeout=40)
            phone = await hs.Phone.dial(dashboard, push["call_id"], "push", session_id=push["session_id"])
            await phone.send({"type": "ringing"})
            silent = list(phone.messages)
            await phone.send({"type": "answered"})
            await phone.heard("Time to get up.")
            await asyncio.to_thread(model.wait_for, "The user answered the call you scheduled")
            await asyncio.sleep(0.3)
            await phone.say("I am up")
            await phone.heard("You said I am up.", timeout=90)  # the reopened conversation answered into the call
            live = (await dashboard.get(f"{hs.PREFIX}/status")).json()
            code = await phone.hang_up()
            seen = await asyncio.to_thread(model.wait_for, "[Voice call ended by user]")
            await asyncio.sleep(2.0)  # the turn that notice started ends
            messages = await dashboard.messages(stored)
            deliveries = [d for d in await dashboard.deliveries() if d["call_id"] == push["call_id"]]
            return (stored, scheduled, status, on_disk, mode, early, push, silent, live, code, seen, messages,
                    deliveries)
        finally:
            await dashboard.close()

    (stored, scheduled, status, on_disk, mode, early, push, silent, live, code, seen, messages,
     deliveries) = asyncio.run(scenario())
    assert scheduled["status"] == "scheduled" and scheduled["scheduled_id"].startswith("sc-")
    assert re.fullmatch(r"\d{4}-\d\d-\d\d \d\d:\d\d", scheduled["rings_at"])
    assert scheduled["pending"][0]["scheduled_id"] == scheduled["scheduled_id"]
    assert status["scheduled"] == 1 and status["active_call"] is None
    assert mode == 0o600 and "Time to get up." in on_disk and stored in on_disk
    assert early == []  # nothing rang before its time
    assert 0 <= sandbox.rang_after(scheduled["scheduled_id"]) <= 2  # on time, within about a second
    assert push["session_id"] == stored and push["mode"] == "async" and silent == []
    assert live["active_call"]["call_id"] == push["call_id"] and live["scheduled"] == 0
    assert code == 1000
    assert not sandbox.schedule_file.exists()  # answered: the line is off the disk
    # The conversation was told which call this is, then got the user's words as a turn of its own.
    assert (f"The user answered the call you scheduled for {scheduled['rings_at']} (scheduled_id "
            f"{scheduled['scheduled_id']}, call {push['call_id']})") in seen
    users = stored_turns(messages, "user")
    assert any(text.startswith("[Voice call started]") and scheduled["scheduled_id"] in text for text in users), users
    assert any(text.startswith("[Voice] I am up (Reply out loud with start_call") for text in users), users
    assert all(d["ok"] for d in deliveries), deliveries
    assert [d["via"] for d in deliveries if d["text"].startswith("[Voice call started]")] == ["submit"]
    ring, = [e for e in sandbox.ring_log("ring") if e["call_id"] == push["call_id"]]
    assert ring["scheduled"] == scheduled["scheduled_id"] and ring["attempt"] == 1 and "late_s" not in ring
    assert "Time to get up" not in (sandbox.hermes_home / "hermes-voice" / "rings.jsonl").read_text(encoding="utf-8")


def test_a_scheduled_ring_nobody_answers_is_repeated_once_then_the_conversation_is_told(timed):
    sandbox, model, _ = timed

    async def scenario():
        stored, scheduled, _ = await schedule(sandbox, model, "Unanswered timed call", 3, "Anyone there?")
        dashboard = hs.Dashboard(sandbox)
        try:
            assert (await dashboard.sign_in()).status_code == 200
            first = await dashboard.push_for(stored, timeout=30)
            first_at = time.time()
            second = await dashboard.push_for(stored, seen=1, timeout=40)  # ring timeout 6 s, then the retry gap
            second_at = time.time()
            seen = await asyncio.to_thread(model.wait_for, "This was the call you scheduled for", 40)
            await asyncio.sleep(RETRY_AFTER_S + 3)
            pushes = [p for p in await dashboard.pushes() if p.get("session_id") == stored]
            status = (await dashboard.get(f"{hs.PREFIX}/status")).json()
            return scheduled, first, second, second_at - first_at, seen, pushes, status
        finally:
            await dashboard.close()

    scheduled, first, second, gap, seen, pushes, status = asyncio.run(scenario())
    assert first["call_id"] != second["call_id"] and len(pushes) == 2  # once more, and no third time
    assert 6.0 + RETRY_AFTER_S - 1.5 <= gap <= 6.0 + RETRY_AFTER_S + 6.0, gap
    assert "[Voice line not delivered: the phone never answered the ring]" in seen
    assert f"(scheduled_id {scheduled['scheduled_id']}): it was tried at" in seen
    assert 'Its line was: "Anyone there?".' in seen
    assert status["scheduled"] == 0 and not sandbox.schedule_file.exists()
    mine = [e for e in sandbox.ring_log("ring", "scheduled_retry", "scheduled_done")
            if e.get("scheduled") == scheduled["scheduled_id"]]
    assert [(e["event"], e.get("attempt") or e.get("outcome")) for e in mine] == [
        ("ring", 1), ("scheduled_retry", "unreachable"), ("ring", 2), ("scheduled_done", "unreachable")]


def test_a_scheduled_call_survives_a_restart_of_the_dashboard(timed):
    sandbox, model, _ = timed

    async def before():
        return await schedule(sandbox, model, "Wake-up call", 60, "Good morning.")

    async def after(stored: str):
        dashboard = hs.Dashboard(sandbox)
        try:
            assert (await dashboard.sign_in()).status_code == 200
            assert (await dashboard.post(f"{hs.HELPER}/arm")).status_code == 200  # the new process's push recorder
            status = (await dashboard.get(f"{hs.PREFIX}/status")).json()
            push = await dashboard.push_for(stored, timeout=90)
            phone = await hs.Phone.dial(dashboard, push["call_id"], "push", session_id=push["session_id"])
            await phone.send({"type": "ringing"})
            await phone.send({"type": "answered"})
            await phone.heard("Good morning.")
            await asyncio.to_thread(model.wait_for, f"call {push['call_id']})")
            await asyncio.sleep(0.3)
            await phone.say("morning to you")
            await phone.heard("You said morning to you.", timeout=90)
            code = await phone.hang_up()
            await asyncio.to_thread(model.wait_for, "[Voice call ended by user]")
            await asyncio.sleep(2.0)
            return status, push, code, await dashboard.messages(stored)
        finally:
            await dashboard.close()

    stored, scheduled, _ = asyncio.run(before())
    assert sandbox.schedule_file.exists()
    sandbox.restart()
    status, push, code, messages = asyncio.run(after(stored))
    # Back, with the push recorder armed, before the call's time: it was still scheduled and rang on time. (After
    # a restart that takes longer than that minute the ring is late and, unrecorded, repeated; not asserted.)
    assert status["scheduled"] == 1, "the restart took longer than the call's minute"
    assert 0 <= sandbox.rang_after(scheduled["scheduled_id"]) <= 2
    assert push["session_id"] == stored and code == 1000
    users = stored_turns(messages, "user")
    assert any(text.startswith("[Voice call started]") and scheduled["scheduled_id"] in text for text in users), users
    assert any(text.startswith("[Voice] morning to you") for text in users), users
    assert not sandbox.schedule_file.exists()
