"""The fake hermes_voice plugin's location half (hermes-voice-plugin/location.py): the ``location`` flag of a device
registration, ``get_location`` asked by the fake agent, the phone's answer by POST /location (the background push
path) and over the call's link, and what the fake says when no phone shares or none answers."""

from __future__ import annotations

import asyncio
import uuid

from fakeclient import Gateway, serving, signed_in
from fake_voice_plugin import LOCATION_SHARING_OFF, PREFIX
from test_fake_voice_plugin import Phone, stamp, start_session, turn

VOIP, ALERT = "ab" * 32, "cd" * 32
DEVICE = {"voip_token": VOIP, "alert_token": ALERT, "environment": "sandbox", "bundle_id": "com.example.hermesvoice"}
FIX = {"latitude": 59.0, "longitude": 18.0, "accuracy_m": 12.5}


def fix(request_id: str, **over) -> dict:
    return {"voip_token": VOIP, "request_id": request_id, **FIX, "fixed_at": stamp(), **over}


def test_the_agent_gets_the_fix_the_phone_posts_after_a_background_push():
    async def scenario():
        async with serving(location_timeout=5.0) as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                nobody = (await http.post(f"{PREFIX}/debug/location-request")).json()
                await http.post(f"{PREFIX}/devices", json=DEVICE)
                off = (await http.post(f"{PREFIX}/debug/location-request")).json()
                registered = await http.post(f"{PREFIX}/devices", json={
                    **DEVICE, "location": {"enabled": True, "background": True}})
                status = (await http.get(f"{PREFIX}/status")).json()
                await gateway.call("prompt.submit", {"session_id": sid, "text": "where am I?"})
                await gateway.event("tool.start")
                [asked] = (await http.get(f"{PREFIX}/debug/location")).json()["requests"]
                refused = {
                    "nobody asked": await http.post(f"{PREFIX}/location", json=fix("0" * 16)),
                    "unknown phone": await http.post(f"{PREFIX}/location", json=fix(asked["request_id"],
                                                                                    voip_token="ef" * 32)),
                    "no token": await http.post(f"{PREFIX}/location", json={**FIX, "request_id": asked["request_id"]}),
                    "bad fix": await http.post(f"{PREFIX}/location", json=fix(asked["request_id"], latitude=100)),
                }
                posted = await http.post(f"{PREFIX}/location", json=fix(asked["request_id"], speed_mps=1.5))
                answered = await turn(gateway)
                # A registration that doesn't name location keeps it; a young fix is given without asking again.
                await http.post(f"{PREFIX}/devices", json={**DEVICE, "alerts": {"turn_done": False}})
                await gateway.call("prompt.submit", {"session_id": sid, "text": "Where am I now?"})
                cached = await turn(gateway)
                known = (await http.get(f"{PREFIX}/debug/location")).json()
                after = (await http.get(f"{PREFIX}/status")).json()
                await gateway.close()
            return nobody, off, registered, status, asked, refused, posted, answered, cached, known, after

    nobody, off, registered, status, asked, refused, posted, answered, cached, known, after = asyncio.run(scenario())
    assert nobody["status"] == "no_phone" and off == {"status": "sharing_off", "note": LOCATION_SHARING_OFF}
    assert registered.status_code == 200
    assert status["location"] == {"enabled": True, "sharing": True, "phones": 1, "background": 1,
                                  "last_fix_age_s": None}
    assert status["devices"][0]["location"] == {"enabled": True, "background": True}
    assert asked["via"] == "push" and asked["status"] == "pending" and asked["sent_to"] == [ALERT]
    assert asked["payload"] == {"aps": {"content-available": 1},
                                "hermes": {"kind": "location_request", "request_id": asked["request_id"],
                                           "profile": "default"}}
    assert {name: answer.status_code for name, answer in refused.items()} == {
        "nobody asked": 409, "unknown phone": 404, "no token": 400, "bad fix": 400}
    assert posted.status_code == 200 and posted.json() == {"ok": True}
    [(name, args, result)] = answered["tools"]
    assert (name, args) == ("get_location", {})
    assert result == {"status": "ok", **FIX, "age_s": result["age_s"], "fixed_at": result["fixed_at"],
                      "source": "push", "speed_mps": 1.5, "note": "A fresh fix from the phone."}
    assert answered["text"].startswith("You are at 59.0, 18.0 (within 12.5 m, ") and "via push" in answered["text"]
    assert cached["tools"][0][2]["source"] == "cached" and len(known["requests"]) == 1
    assert known["sharing"] is True and known["fix"]["latitude"] == 59.0
    assert known["requests"][0]["status"] == "answered"
    assert after["location"]["last_fix_age_s"] is not None and "59.0" not in str(after["location"])


def test_on_a_call_the_fake_asks_over_the_link():
    async def scenario():
        async with serving(location_timeout=5.0) as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                await http.post(f"{PREFIX}/devices", json={**DEVICE, "location": {"enabled": True}})
                phone = await Phone.dial(base, http, uuid.uuid4().hex, "user", session_id=key)
                await phone.next("ready")
                await phone.hear()
                await turn(gateway)
                asked = (await http.post(f"{PREFIX}/debug/location-request")).json()
                request = await phone.next("location_request")
                await phone.send({"type": "location", "id": "0" * 16, **FIX, "fixed_at": stamp()})  # ignored
                await phone.send({"type": "location", "id": request["id"], **FIX, "fixed_at": stamp()})
                await phone.send({"type": "ping"})
                await phone.next("pong")
                known = (await http.get(f"{PREFIX}/debug/location")).json()
                refused = (await http.post(f"{PREFIX}/debug/location-request")).json()
                again = await phone.next("location_request")
                await phone.send({"type": "location", "id": again["id"], "error": "denied"})
                await phone.send({"type": "ping"})
                await phone.next("pong")
                failed = (await http.get(f"{PREFIX}/debug/location")).json()["requests"][-1]
                await phone.hang_up()
                await gateway.close()
            return asked, request, known, refused, failed

    asked, request, known, refused, failed = asyncio.run(scenario())
    assert asked["via"] == "call" and asked["payload"] is None and asked["sent_to"] == []
    assert request == {"type": "location_request", "id": asked["request_id"]}
    assert known["fix"]["source"] == "call" and known["fix"]["accuracy_m"] == 12.5
    assert [entry["status"] for entry in known["requests"]] == ["answered"]
    assert refused["via"] == "call" and (failed["status"], failed["error"]) == ("failed", "denied")


def test_no_answer_and_sharing_turned_off():
    async def scenario():
        async with serving(location_timeout=0.3) as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                await http.post(f"{PREFIX}/devices", json={**DEVICE, "location": {"enabled": True}})
                await gateway.call("prompt.submit", {"session_id": sid, "text": "where am i"})
                silent = await turn(gateway)
                # A late answer is kept as the last fix; turning sharing off drops it.
                [asked] = (await http.get(f"{PREFIX}/debug/location")).json()["requests"]
                late = await http.post(f"{PREFIX}/location", json=fix(asked["request_id"]))
                kept = (await http.get(f"{PREFIX}/debug/location")).json()["fix"]
                bad = await http.post(f"{PREFIX}/devices", json={**DEVICE, "location": {"enabled": "yes"}})
                await http.post(f"{PREFIX}/devices", json={**DEVICE, "location": {"enabled": False}})
                gone = (await http.get(f"{PREFIX}/debug/location")).json()
                not_sharing = await http.post(f"{PREFIX}/location", json=fix(asked["request_id"]))
                await gateway.call("prompt.submit", {"session_id": sid, "text": "where am i"})
                off = await turn(gateway)
                await gateway.close()
            return silent, late, kept, bad, gone, not_sharing, off

    silent, late, kept, bad, gone, not_sharing, off = asyncio.run(scenario())
    assert silent["tools"][0][2]["status"] == "no_answer" and "background push" in silent["tools"][0][2]["note"]
    assert silent["text"].startswith("No location (no_answer): ")
    assert late.status_code == 200 and kept["latitude"] == 59.0
    assert bad.status_code == 422
    assert gone == {"sharing": False, "fix": None, "requests": gone["requests"]}
    assert not_sharing.status_code == 403
    assert off["tools"][0][2] == {"status": "sharing_off", "note": LOCATION_SHARING_OFF}
    assert "Settings → Location" in off["text"]
