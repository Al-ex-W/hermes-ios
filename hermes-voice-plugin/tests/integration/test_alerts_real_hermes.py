"""Alert pushes inside a real ``hermes serve`` (opt-in; see conftest.py): a real approval and a real clarify question
waiting on a conversation no client has open reach the phone with the gateway's own request id, the phone answers
them with ``request.answer`` from a socket that isn't attached, and the finished turn alerts too. Through the
plugin's real APNs sender and a mock APNs, an approval alerts each phone that takes approval alerts exactly once.

This module runs its own sandboxes, one with turns in the dashboard process and one with ``dashboard.turn_isolation``
(turns in a compute-host child, whose requests the dashboard mirrors): manual approvals (the default guardian would
ask the stub model), alerts after a 1 s grace, a stub model that runs a dangerous command or asks a question, an
APNs provider key for the mock APNs, and the harness's helper plugin extended to record alert pushes as well.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import shutil
import signal
import subprocess
import textwrap
import time
from pathlib import Path
from typing import Any, Iterator

import pytest
import websockets

import hermes_sandbox as hs

pytestmark = pytest.mark.integration

# Appended to the helper plugin (hermes_sandbox.HELPER_API): its recorder takes alert pushes too.
ALERT_RECORDER = '''

import time as _time

alerts = []


def _push_alert(self, kind, payload, collapse_id=""):
    with lock:
        alerts.append({"kind": kind, "payload": payload, "collapse_id": collapse_id, "at": _time.time()})
    return hub_module().push.PushResult(True, "", 1)


Recorder.push_alert = _push_alert


@router.get("/alerts")
async def list_alerts():
    with lock:
        return {"alerts": list(alerts)}
'''


class AlertSandbox(hs.Sandbox):
    def __init__(self, *args: Any, isolated: bool = False, apns: hs.MockApns, **kwargs: Any) -> None:
        self.isolated = isolated  # read by _write, which the harness calls from __init__
        self.apns = apns
        super().__init__(*args, **kwargs)

    def _write(self, ring_timeout_s: float) -> None:
        super()._write(ring_timeout_s)
        self.apns.install(self)
        config_path = self.hermes_home / "config.yaml"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        config["approvals"] = {"mode": "manual", "timeout": 120}
        config["plugins"]["entries"]["hermes_voice"]["settings"]["alerts"] = {"grace_s": 1}
        config["dashboard"]["turn_isolation"] = self.isolated
        config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        helper = self.hermes_home / "plugins" / "hermes_voice_it" / "dashboard" / "plugin_api.py"
        helper.write_text(textwrap.dedent(hs.HELPER_API) + ALERT_RECORDER, encoding="utf-8")
        (self.root / "target").mkdir()

    def stop(self) -> None:
        """Also ends the processes the dashboard started: a compute-host child runs in a session of its own, which
        the harness's process-group kill doesn't reach."""
        children = _descendants(self.proc.pid) if self.proc is not None else []
        super().stop()
        deadline = time.monotonic() + 10.0
        for pid in children:
            while _alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            if _alive(pid):
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.kill(pid, signal.SIGKILL)


def _descendants(pid: int) -> list[int]:
    try:
        found = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True, timeout=5).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return []
    children = [int(child) for child in found if child.isdigit()]
    return children + [grandchild for child in children for grandchild in _descendants(child)]


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class Model:
    """``do the dangerous thing`` -> ``terminal rm -rf <a folder in the sandbox>`` (an approval); ``ask me`` ->
    ``clarify`` with one question; ``fail now`` -> the provider refuses the request; after a tool result -> a short
    reply."""

    def __init__(self) -> None:
        self.target = ""

    def __call__(self, body: dict[str, Any]) -> Any:
        recent = hs.since_last_reply(body)
        last = recent[-1] if recent else {}
        listed = {str((tool.get("function") or {}).get("name")) for tool in body.get("tools") or []}

        def call(name: str, args: dict) -> hs.ToolCall:
            if name in listed:
                return hs.ToolCall(name, args)
            return hs.ToolCall("tool_call", {"calls": [{"name": name, "arguments": args}]})

        if last.get("role") == "user":
            text = hs.message_text(last)
            if "fail now" in text:
                return hs.Fail(delay=1.0)  # a provider 400: the turn ends on an early return
            if "dangerous" in text:
                return call("terminal", {"command": f"rm -rf {self.target}"})
            if "ask me" in text:
                return call("clarify", {"questions": [{"question": "Which environment?",
                                                       "choices": ["staging", "production"]}]})
        if last.get("role") == "tool":
            return hs.Text("All done, deployed.")
        return hs.Text("Noted.")


@pytest.fixture(scope="module", params=["in-process", "turn-isolation"])
def hermes(request: pytest.FixtureRequest) -> Iterator[tuple[AlertSandbox, hs.StubModel]]:
    if os.environ.get("HERMES_VOICE_INTEGRATION") != "1":
        pytest.skip("set HERMES_VOICE_INTEGRATION=1 to run against a real Hermes")
    python, why = hs.hermes_python()
    if python is None:
        pytest.skip(why)
    responder = Model()
    model = hs.StubModel(responder)
    apns = hs.MockApns()
    root = os.environ.get("HERMES_VOICE_IT_TMP")
    sandbox = AlertSandbox(python, model, root=Path(root) if root else None,
                           isolated=request.param == "turn-isolation", apns=apns)
    responder.target = str(sandbox.root / "target")
    failures = request.session.testsfailed
    started = False
    try:
        sandbox.start()
        started = True
        yield sandbox, model
    finally:
        sandbox.stop()
        model.stop()
        apns.stop()
        if not started or request.session.testsfailed > failures:
            print(f"\nhermes sandbox kept for inspection: {sandbox.root}\n{sandbox.log_tail(3000)}")
        else:
            # A compute-host child can outlive its dashboard by a moment, still writing into the home.
            for _ in range(20):
                shutil.rmtree(sandbox.root, ignore_errors=True)
                if not sandbox.root.exists():
                    break
                time.sleep(0.5)


class Gateway(hs.Gateway):
    """The harness's gateway client, keeping the server requests it gets (with their ids)."""

    async def _read(self) -> None:
        self.requests: list[dict] = []
        with contextlib.suppress(websockets.ConnectionClosed):
            async for raw in self.socket:
                if not isinstance(raw, str):
                    continue
                message = json.loads(raw)
                if message.get("method") == "event":
                    self.events.append(message.get("params") or {})
                elif "id" in message and str(message["id"]) in self.pending:
                    self.pending.pop(str(message["id"])).set_result(message)
                    continue
                elif message.get("method"):
                    self.requests.append(message)
                    self.events.append({"type": f"request:{message['method']}", "payload": message.get("params")})
                self.changed.set()

    @classmethod
    async def answering(cls, dashboard: hs.Dashboard) -> "Gateway":
        """A client like the app: it says it answers server requests (else Hermes withdraws them)."""
        gateway = await cls.open(dashboard)
        await gateway.call("client.capabilities", {"server_requests": True})
        return gateway


async def alerts(dashboard: hs.Dashboard) -> list[dict]:
    return (await dashboard.get(f"{hs.HELPER}/alerts")).json()["alerts"]


async def alert_for(dashboard: hs.Dashboard, kind: str, session_id: str, timeout: float = 60.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for alert in await alerts(dashboard):
            if alert["kind"] == kind and alert["payload"]["hermes"]["session_id"] == session_id:
                return alert
        await asyncio.sleep(0.2)
    raise AssertionError(f"no {kind} alert for {session_id} (got {await alerts(dashboard)})")


async def signed_in(sandbox: AlertSandbox) -> hs.Dashboard:
    dashboard = hs.Dashboard(sandbox)
    assert (await dashboard.sign_in()).status_code == 200
    assert (await dashboard.post(f"{hs.HELPER}/arm")).status_code == 200
    return dashboard


def test_an_approval_alerts_once_the_client_leaves_and_is_answered_from_the_alert(hermes):
    sandbox, _ = hermes

    async def scenario():
        dashboard = await signed_in(sandbox)
        try:
            status = (await dashboard.get(f"{hs.PREFIX}/status")).json()
            gateway = await Gateway.answering(dashboard)
            created = await gateway.call("session.create", {"source": "desktop", "title": "Alerts A"})
            sid, stored = created["session_id"], created["stored_session_id"]
            await gateway.call("prompt.submit", {"session_id": sid, "text": "do the dangerous thing"})
            await gateway.event("request:approval", timeout=60)
            request = gateway.requests[-1]
            await asyncio.sleep(3.0)  # well past the grace: the client has it open, so nothing goes
            while_attached = await alerts(dashboard)
            await gateway.close()  # the user leaves
            alert = await alert_for(dashboard, "approval", stored)
            app = await Gateway.answering(dashboard)  # the notification's action: a socket not attached
            try:
                answer = await app.call("request.answer", {"id": alert["payload"]["hermes"]["request_id"],
                                                           "result": {"choice": "once"}})
                done = await alert_for(dashboard, "turn_done", stored)
            finally:
                await app.close()
            return status, request, while_attached, alert, answer, done, stored
        finally:
            await dashboard.close()

    status, request, while_attached, alert, answer, done, stored = asyncio.run(scenario())
    assert status["alerts"]["watching"] is True
    assert while_attached == []
    assert alert["collapse_id"] == request["id"] and request["id"].startswith("srq-")
    payload = alert["payload"]
    assert payload["aps"]["category"] == "HERMES_APPROVAL" and payload["aps"]["thread-id"] == stored
    assert payload["aps"]["sound"] == "default" and payload["aps"]["alert"]["title"]
    assert payload["aps"]["alert"]["body"] == request["params"]["description"]
    assert payload["hermes"] == {"kind": "approval", "session_id": stored, "profile": "default",
                                 "request_id": request["id"], "choices": request["params"]["choices"]}
    assert "rm -rf" not in json.dumps(payload)
    assert answer == {"status": "ok"}
    assert done["payload"]["aps"]["category"] == "HERMES_TURN_DONE"
    # A compute-host turn's message.complete is relayed through the dashboard: its alert has the reply too.
    assert done["payload"]["aps"]["alert"]["body"] == "All done, deployed."
    assert done["payload"]["hermes"] == {"kind": "turn_done", "session_id": stored, "profile": "default"}
    assert not (sandbox.root / "target").exists()  # approved once, and it ran


def test_a_question_alerts_with_its_questions_and_is_answered_from_the_alert(hermes):
    sandbox, model = hermes

    async def scenario():
        dashboard = await signed_in(sandbox)
        try:
            gateway = await Gateway.answering(dashboard)
            created = await gateway.call("session.create", {"source": "desktop", "title": "Alerts B"})
            sid, stored = created["session_id"], created["stored_session_id"]
            await gateway.call("prompt.submit", {"session_id": sid, "text": "please ask me something"})
            await gateway.event("request:clarify", timeout=60)
            await gateway.close()  # the user leaves with the question on screen
            alert = await alert_for(dashboard, "clarify", stored)
            question = alert["payload"]["hermes"]["questions"][0]
            app = await Gateway.answering(dashboard)
            try:
                answer = await app.call("request.answer", {"id": alert["payload"]["hermes"]["request_id"],
                                                           "result": {"answers": {question["qid"]: "staging"}}})
                done = await alert_for(dashboard, "turn_done", stored)
            finally:
                await app.close()
            return alert, answer, done, stored
        finally:
            await dashboard.close()

    alert, answer, done, stored = asyncio.run(scenario())
    payload = alert["payload"]
    assert payload["aps"]["category"] == "HERMES_CLARIFY" and payload["aps"]["thread-id"] == stored
    assert payload["aps"]["alert"]["body"] == "Which environment?"
    rid = payload["hermes"]["request_id"]
    assert rid.startswith("srq-") and alert["collapse_id"] == rid
    [question] = payload["hermes"]["questions"]
    assert set(question) == {"qid", "question", "choices", "multi_select"}
    assert question["question"] == "Which environment?" and len(question["choices"]) == 2
    assert answer == {"status": "ok"}
    assert done["payload"]["hermes"]["kind"] == "turn_done"
    model.wait_for("staging")  # the answer reached the model as the clarify result


def test_a_turn_the_provider_fails_alerts_that_it_failed(hermes):
    """A provider 400 ends the turn on an early return, which fires no on_session_end: the watcher sees the
    conversation go idle and its message.complete say "error" (relayed from the child under turn_isolation)."""
    sandbox, _ = hermes

    async def scenario():
        dashboard = await signed_in(sandbox)
        try:
            gateway = await Gateway.answering(dashboard)
            created = await gateway.call("session.create", {"source": "desktop", "title": "Alerts F"})
            sid, stored = created["session_id"], created["stored_session_id"]
            await gateway.call("prompt.submit", {"session_id": sid, "text": "fail now"})
            await gateway.close()  # nobody watches the turn end
            done = await alert_for(dashboard, "turn_done", stored)
            messages = await dashboard.messages(stored)
            return done, messages
        finally:
            await dashboard.close()

    done, messages = asyncio.run(scenario())
    assert done["payload"]["aps"]["alert"]["body"] == "Hermes stopped: the turn failed."
    assert done["payload"]["aps"]["category"] == "HERMES_TURN_DONE"
    assert any(m.get("role") == "user" and "fail now" in json.dumps(m.get("content")) for m in messages), messages


# Two phones: A takes every alert; B turned approval alerts off (POST /devices {"alerts": {"approval": false}}).
PHONE_A = {"voip_token": "a1" * 32, "alert_token": "a2" * 32, "environment": "sandbox",
           "bundle_id": "com.example.hermesvoice"}
PHONE_B = {"voip_token": "b1" * 32, "alert_token": "b2" * 32, "environment": "production",
           "bundle_id": "com.example.hermesvoice", "alerts": {"approval": False}}


def test_an_approval_with_no_client_attached_sends_one_apns_alert_to_each_phone_that_takes_them(hermes):
    sandbox, _ = hermes
    apns = sandbox.apns
    (sandbox.root / "target").mkdir(exist_ok=True)  # an earlier approval may have removed it

    async def scenario():
        dashboard = hs.Dashboard(sandbox)
        try:
            assert (await dashboard.sign_in()).status_code == 200
            for phone in (PHONE_A, PHONE_B):
                assert (await dashboard.post(f"{hs.PREFIX}/devices", phone)).json() == {"ok": True}
            assert (await dashboard.post(f"{hs.HELPER}/arm-apns", {"url": apns.url})).status_code == 200
            status = (await dashboard.get(f"{hs.PREFIX}/status")).json()
            before = len(apns.received())
            gateway = await Gateway.answering(dashboard)
            created = await gateway.call("session.create", {"source": "desktop", "title": "Alerts C"})
            sid, stored = created["session_id"], created["stored_session_id"]
            await gateway.call("prompt.submit", {"session_id": sid, "text": "do the dangerous thing"})
            await gateway.event("request:approval", timeout=60)
            request = gateway.requests[-1]
            await gateway.close()  # nobody has the conversation open now
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and not _of(apns.received()[before:], "HERMES_APPROVAL"):
                await asyncio.sleep(0.2)
            await asyncio.sleep(4.0)  # well past the grace again: still just the one
            approvals = _of(apns.received()[before:], "HERMES_APPROVAL")
            app = await Gateway.answering(dashboard)  # the notification's "Deny" action
            try:
                answer = await app.call("request.answer", {"id": request["id"], "result": {"choice": "deny"}})
                deadline = time.monotonic() + 60
                while time.monotonic() < deadline and len(_of(apns.received()[before:], "HERMES_TURN_DONE")) < 2:
                    await asyncio.sleep(0.2)
            finally:
                await app.close()
            done = _of(apns.received()[before:], "HERMES_TURN_DONE")
            return status, request, approvals, answer, done, stored
        finally:
            await dashboard.close()

    status, request, approvals, answer, done, stored = asyncio.run(scenario())
    assert status["apns_configured"] is True and status["alerts"]["devices"] >= 2
    [alert] = approvals  # phone B turned approvals off; phone A got exactly one
    assert alert["token"] == PHONE_A["alert_token"] and alert["host"] == "api.sandbox.push.apple.com"
    assert alert["token_ok"] is True  # an ES256 provider token signed with the host's key
    assert alert["headers"]["apns-push-type"] == "alert"
    assert alert["headers"]["apns-topic"] == "com.example.hermesvoice"  # the app's own topic, not .voip
    assert alert["headers"]["apns-priority"] == "10"
    assert alert["headers"]["apns-collapse-id"] == request["id"]
    assert int(alert["headers"]["apns-expiration"]) > time.time()
    aps, extra = alert["payload"]["aps"], alert["payload"]["hermes"]
    assert aps["category"] == "HERMES_APPROVAL" and aps["thread-id"] == stored and aps["sound"] == "default"
    assert aps["alert"]["title"] and aps["alert"]["body"] == request["params"]["description"]
    assert extra == {"kind": "approval", "session_id": stored, "profile": "default", "request_id": request["id"],
                     "choices": request["params"]["choices"]}
    assert "rm -rf" not in json.dumps(alert["payload"]) and alert["size"] <= 4096
    assert answer == {"status": "ok"}
    # The denied turn still finished: both phones take turn_done alerts (B only turned approvals off).
    assert sorted(push["token"] for push in done) == sorted([PHONE_A["alert_token"], PHONE_B["alert_token"]])
    assert {push["host"] for push in done} == {"api.sandbox.push.apple.com", "api.push.apple.com"}
    assert (sandbox.root / "target").exists()  # denied: the command never ran


def _of(pushes: list[dict], category: str) -> list[dict]:
    return [push for push in pushes if ((push.get("payload") or {}).get("aps") or {}).get("category") == category]
