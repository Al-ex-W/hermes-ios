"""The app's edits of a stored session against a real ``hermes serve``: since Hermes 0.22.3 a rename, a sidebar flag
or a delete must name the state it applies to (``GET /api/sessions/{id}/mutation-snapshot``, then ``request_id`` /
``expected_revision`` / ``expected_generation``), or Hermes answers 409 ``client_upgrade_required``.

This is the contract ``DashboardClient.mutateSession`` (HermesVoice/HermesVoice/REST/Sessions.swift) and
``devtools/fake_hermes.py`` are written against; nothing here touches the plugin."""

from __future__ import annotations

import asyncio
import uuid

import pytest

from test_chat_open_elsewhere import chat_with_a_turn
from test_real_hermes import signed_in

pytestmark = pytest.mark.integration


def test_a_stored_session_is_renamed_flagged_and_deleted_against_its_revision(hermes):
    box, _model, _agent = hermes

    async def scenario():
        async with signed_in(box) as (dashboard, gateway):
            runtime_id, stored_id = await chat_with_a_turn(gateway, "say hello")
            path = f"/api/sessions/{stored_id}"
            origin = {"Origin": box.public}

            async def snapshot() -> dict:
                response = await dashboard.get(f"{path}/mutation-snapshot")
                assert response.status_code == 200, response.text
                return response.json()

            def identity(state: dict) -> dict:
                fields = {"request_id": str(uuid.uuid4()), "expected_revision": state["runtime_revision"]}
                if state["exists"]:
                    fields["expected_generation"] = state["runtime_generation"]
                return fields

            bare = await dashboard.http.patch(path, json={"pinned": True}, headers=origin)
            assert bare.status_code == 409 and "client_upgrade_required" in bare.text, bare.text
            bare_delete = await dashboard.http.delete(path, headers=origin)
            assert bare_delete.status_code == 409 and "client_upgrade_required" in bare_delete.text, bare_delete.text

            before = await snapshot()
            assert before["session_id"] == stored_id and before["exists"] is True
            assert isinstance(before["runtime_revision"], int) and isinstance(before["runtime_generation"], int)

            first = identity(before)
            renamed = await dashboard.http.patch(path, json={"title": "Fenced rename", **first}, headers=origin)
            assert renamed.status_code == 200 and renamed.json().get("ok") is True, renamed.text
            replayed = await dashboard.http.patch(path, json={"title": "Fenced rename", **first}, headers=origin)
            assert replayed.status_code == 200, replayed.text

            after = await snapshot()
            assert after["runtime_revision"] > before["runtime_revision"]
            behind = await dashboard.http.patch(path, json={"pinned": True, **identity(before)}, headers=origin)
            assert behind.status_code == 409 and "revision_conflict" in behind.text, behind.text

            pinned = await dashboard.http.patch(path, json={"pinned": True, "unread": True, **identity(after)}, headers=origin)
            assert pinned.status_code == 200, pinned.text
            row = (await dashboard.get(path)).json()
            assert row["title"] == "Fenced rename" and row.get("pinned") in (True, 1), row

            await gateway.call("session.close", {"session_id": runtime_id})
            deleted = await dashboard.http.delete(path, params=identity(await snapshot()), headers=origin)
            assert deleted.status_code == 200 and deleted.json().get("ok") is True, deleted.text
            gone = await snapshot()
            assert gone["exists"] is False and gone["runtime_generation"] is None
            # A delete that names an absent row's state (revision 0, no generation) is refused, so the app answers
            # "already gone" from the snapshot and sends nothing; one that still names the row it saw is told so.
            again = await dashboard.http.delete(path, params=identity(gone), headers=origin)
            assert (again.status_code, again.json().get("detail")) == (400, "invalid_params"), again.text
            late = await dashboard.http.delete(path, params=identity(after), headers=origin)
            assert late.status_code == 200 and late.json().get("already_absent") is True, late.text
            print("rename receipt:", sorted(renamed.json()), "| delete receipt:", sorted(deleted.json()))

    asyncio.run(scenario())
