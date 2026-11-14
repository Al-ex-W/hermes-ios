"""The fake hermes_voice plugin's ``notify_user`` (hermes-voice-plugin/message.py): "notify me: <text>" typed in a
chat makes the fake agent call the tool, the alert lands in GET debug/alerts with the plugin's payload, a test alert
of the ``message`` kind is the plugin's own, and the result says when nothing could be sent."""

from __future__ import annotations

import asyncio

from fakeclient import Gateway, serving, signed_in
from fake_voice_plugin import PREFIX
from test_fake_hermes_settings import plugin_notify
from test_fake_voice_plugin import start_session, turn

VOIP, ALERT = "ab" * 32, "cd" * 32
OTHER_VOIP, OTHER_ALERT = "12" * 32, "34" * 32
DEVICE = {"voip_token": VOIP, "alert_token": ALERT, "environment": "sandbox", "bundle_id": "com.example.hermesvoice"}


def test_notify_me_sends_a_message_alert_to_the_phones_that_take_them():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sid, key = await start_session(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "notify me: no phone yet"})
                nobody = await turn(gateway)
                await http.post(f"{PREFIX}/devices", json=DEVICE)
                await http.post(f"{PREFIX}/devices", json={
                    "voip_token": OTHER_VOIP, "alert_token": OTHER_ALERT, "environment": "production",
                    "bundle_id": "com.example.hermesvoice", "alerts": {"message": False}})
                await gateway.call("prompt.submit", {"session_id": sid,
                                                     "text": "notify me urgently: Your train is 10 minutes late"})
                sent = await turn(gateway)
                await gateway.call("prompt.submit", {"session_id": sid, "text": "Notify me quietly"})
                quiet = await turn(gateway)
                alerts = (await http.get(f"{PREFIX}/debug/alerts", params={"session_id": key,
                                                                           "kind": "message"})).json()
                status = (await http.get(f"{PREFIX}/status")).json()
                await http.post(f"{PREFIX}/devices", json={**DEVICE, "alerts": {"message": False}})
                await gateway.call("prompt.submit", {"session_id": sid, "text": "notify me: anyone?"})
                off = await turn(gateway)
                rows = (await http.get(f"/api/sessions/{key}/messages")).json()["messages"]
                test = (await http.post(f"{PREFIX}/devices/test", json={"voip_token": OTHER_VOIP,
                                                                        "kind": "message"})).json()
                await http.post(f"{PREFIX}/devices", json={**DEVICE, "alerts": {"message": True}})
                tested = (await http.post(f"{PREFIX}/devices/test", json={"voip_token": VOIP,
                                                                          "kind": "message"})).json()
                listed = (await http.get(f"{PREFIX}/debug/test-alerts")).json()["tests"]
                await gateway.close()
            return key, nobody, sent, quiet, alerts, status, off, rows, test, tested, listed

    key, nobody, sent, quiet, alerts, status, off, rows, test, tested, listed = asyncio.run(scenario())
    [(name, args, result)] = nobody["tools"]
    assert name == "notify_user" and args == {"title": "Fake Hermes", "body": "no phone yet", "urgency": "normal"}
    assert (result["status"], result["reason"]) == ("not_sent", "no_phone")
    assert nobody["text"].startswith("No notification (not_sent):")

    [(name, args, result)] = sent["tools"]
    assert args == {"title": "Fake Hermes", "body": "Your train is 10 minutes late", "urgency": "time_sensitive"}
    assert result["status"] == "sent" and "also in this conversation" in result["note"]
    assert sent["text"] == "I sent you a notification."
    assert quiet["tools"][0][1]["urgency"] == "quiet" and quiet["tools"][0][2]["status"] == "sent"

    first, second = [entry for entry in alerts["alerts"]]
    assert first["payload"] == {
        "aps": {"alert": {"title": "Fake Hermes", "body": "Your train is 10 minutes late"},
                "category": "HERMES_MESSAGE", "thread-id": key, "sound": "default",
                "interruption-level": "time-sensitive"},
        "hermes": {"kind": "message", "session_id": key, "profile": "default"}}
    assert first["sent_to"] == [ALERT], "the other phone turned messages off"
    assert second["payload"]["aps"]["interruption-level"] == "passive" and "sound" not in second["payload"]["aps"]
    assert second["payload"]["aps"]["alert"]["body"] == "Fake Hermes has news for you."
    assert {device["voip_token"]: device["alerts"]["message"] for device in status["devices"]} == {
        VOIP: True, OTHER_VOIP: False}

    assert (off["tools"][0][2]["status"], off["tools"][0][2]["reason"]) == ("not_sent", "off_on_phone")
    # The text is in the conversation: the stored tool call carries it.
    calls = [row for row in rows if row["role"] == "assistant" and row.get("tool_calls")]
    assert any("Your train is 10 minutes late" in str(row["tool_calls"]) for row in calls)

    notify = plugin_notify()
    assert (test["status"], test["code"]) == ("failed", "off_on_phone")
    assert test["message"] == f"This iPhone has {notify.KIND_NAMES['message']} notifications turned off."
    assert tested["status"] == "sent" and tested["kind"] == "message"
    entry = next(entry for entry in listed if entry["test_id"] == tested["test_id"])
    assert entry["payload"] == notify.test_payload("message", tested["test_id"], "default")
