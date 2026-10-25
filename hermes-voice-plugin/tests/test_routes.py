"""The dashboard routes: phone socket admission, device registration, Scribe tokens and status."""

from __future__ import annotations

import asyncio
import json
from datetime import datetime, timezone

import httpx
import pytest
import websockets

from support import PREFIX, serving

TOKEN = "ab" * 32


def test_the_phone_socket_is_admitted_only_by_the_dashboard_auth(core, fake, make_hub):
    fake.host.add("s1")
    make_hub()

    async def scenario():
        async with serving(core) as port:
            codes = {}
            fake.host_allowed = False
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={fake.ticket()}") as ws:
                await ws.wait_closed()
                codes["host refused"] = ws.close_code
            fake.host_allowed = True
            ticket = fake.ticket()
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={ticket}") as ws:
                await ws.send(json.dumps({"type": "hello", "call_id": "f" * 32, "session_id": "s1"}))
                ready = json.loads(await ws.recv())
                await ws.send(json.dumps({"type": "ping"}))
                pong = json.loads(await ws.recv())
                await ws.send(json.dumps({"type": "bye"}))
                await ws.wait_closed()
                codes["bye"] = ws.close_code
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={ticket}") as ws:
                await ws.wait_closed()
                codes["ticket reused"] = ws.close_code
            return codes, ready, pong

    codes, ready, pong = asyncio.run(scenario())
    assert codes == {"host refused": 4401, "bye": 1000, "ticket reused": 4401}
    assert ready == {"type": "ready", "call_id": "f" * 32, "state": "live"}
    assert pong == {"type": "pong"}


def test_devices_are_registered_per_profile(core, fake, make_hub, tmp_path):
    make_hub()
    body = {"voip_token": TOKEN.upper(), "alert_token": "cd" * 32, "environment": "sandbox",
            "bundle_id": "com.example.hermesvoice"}

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                ok = await http.post("/devices", json=body)
                again = await http.post("/devices", json={**body, "environment": "production"})
                bad = await http.post("/devices", json={**body, "environment": "dev"})
                huge = await http.post("/devices", content=b"{" + b" " * 5000 + b"}")
                return ok, again, bad, huge

    ok, again, bad, huge = asyncio.run(scenario())
    assert ok.status_code == 200 and ok.json() == {"ok": True} and again.status_code == 200
    assert bad.status_code == 400 and "environment" in bad.json()["detail"]
    assert huge.status_code == 413
    stored = json.loads((tmp_path / "hermes-voice" / "devices.json").read_text())
    assert len(stored) == 1 and stored[0]["voip_token"] == TOKEN and stored[0]["environment"] == "production"
    assert oct((tmp_path / "hermes-voice" / "devices.json").stat().st_mode & 0o777) == "0o600"


def test_scribe_tokens_are_minted_with_the_hosts_key(core, fake, make_hub, monkeypatch):
    make_hub()
    seen: list[httpx.Request] = []

    def elevenlabs(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200, json={"token": "sutkn_123"})

    monkeypatch.setattr(core.api, "SCRIBE_TRANSPORT", httpx.MockTransport(elevenlabs))

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}{PREFIX}") as http:
                missing = await http.post("/scribe-token")
                fake.secrets["ELEVENLABS_API_KEY"] = "xi-test"
                minted = await http.post("/scribe-token")
                status = (await http.get("/status")).json()
                return missing, minted, status

    missing, minted, status = asyncio.run(scenario())
    assert missing.status_code == 503 and "ELEVENLABS_API_KEY" in missing.json()["detail"]
    assert minted.status_code == 200 and minted.headers["cache-control"] == "no-store"
    assert minted.json()["token"] == "sutkn_123"
    expires = datetime.fromisoformat(minted.json()["expires_at"])
    assert 14 * 60 < (expires - datetime.now(timezone.utc)).total_seconds() <= 15 * 60
    assert str(seen[0].url) == "https://api.elevenlabs.io/v1/single-use-token/realtime_scribe"
    assert seen[0].method == "POST" and seen[0].headers["xi-api-key"] == "xi-test"
    assert status["scribe_configured"] is True
    assert "xi-test" not in json.dumps(status)


@pytest.mark.parametrize(("answer", "status"), [
    (httpx.Response(401, json={"detail": "invalid key"}), 502),
    (httpx.Response(200, json={"nope": 1}), 502),
    (httpx.Response(200, content=b"<html>"), 502),
])
def test_scribe_token_failures_are_502(core, fake, make_hub, monkeypatch, answer, status):
    make_hub()
    fake.secrets["ELEVENLABS_API_KEY"] = "xi-test"
    monkeypatch.setattr(core.api, "SCRIBE_TRANSPORT", httpx.MockTransport(lambda request: answer))

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient() as http:
                return await http.post(f"http://127.0.0.1:{port}{PREFIX}/scribe-token")

    response = asyncio.run(scenario())
    assert response.status_code == status and "detail" in response.json()
    assert "xi-test" not in response.text


def test_scribe_tokens_are_rate_limited(core, fake, make_hub, monkeypatch):
    make_hub()
    fake.secrets["ELEVENLABS_API_KEY"] = "xi-test"
    monkeypatch.setattr(core.api, "SCRIBE_TRANSPORT",
                        httpx.MockTransport(lambda request: httpx.Response(200, json={"token": "t"})))
    monkeypatch.setattr(core.api, "_scribe_limiter", core.api._Limiter(2, 60.0))

    async def scenario():
        async with serving(core) as port:
            async with httpx.AsyncClient() as http:
                return [(await http.post(f"http://127.0.0.1:{port}{PREFIX}/scribe-token")).status_code
                        for _ in range(3)]

    assert asyncio.run(scenario()) == [200, 200, 429]


def test_status_reports_the_active_call(core, fake, make_hub):
    fake.host.add("s1")
    make_hub()

    async def scenario():
        async with serving(core) as port:
            async with websockets.connect(f"ws://127.0.0.1:{port}{PREFIX}/phone?ticket={fake.ticket()}") as ws:
                await ws.send(json.dumps({"type": "hello", "call_id": "e" * 32, "session_id": "s1",
                                          "title": "Notes"}))
                await ws.recv()
                async with httpx.AsyncClient() as http:
                    status = (await http.get(f"http://127.0.0.1:{port}{PREFIX}/status")).json()
                await ws.send(json.dumps({"type": "bye"}))
                await ws.wait_closed()
            return status

    status = asyncio.run(scenario())
    assert status["calls"] == 1 and status["apns_configured"] is True
    assert status["active_call"] == {"call_id": "e" * 32, "session_id": "s1", "title": "Notes", "state": "live",
                                     "initiated_by": "user"}
