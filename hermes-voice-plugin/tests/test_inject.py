"""Force-injection into dashboard / desktop sessions: redirect -> steer -> prompt.submit, the exact status mapping,
resolving the live session or reopening the stored one, and the texts."""

from __future__ import annotations

import pytest


def _owner(core, session_id: str = "s1", runtime_sid: str = "", profile: str = "default"):
    return core.hub.Owner(session_id, runtime_sid, profile=profile)


@pytest.mark.parametrize(
    ("answers", "methods", "via", "status"),
    [
        ({"session.redirect": "redirected"}, ["session.redirect"], "redirect", "redirected"),
        ({"session.redirect": "queued"}, ["session.redirect"], "redirect", "queued"),
        ({"session.redirect": "rejected", "session.steer": "queued"},
         ["session.redirect", "session.steer"], "steer", "queued"),
        ({"session.redirect": ("error", 4010), "session.steer": "queued"},
         ["session.redirect", "session.steer"], "steer", "queued"),
        ({"session.redirect": ("error", 4010), "session.steer": "rejected", "prompt.submit": "streaming"},
         ["session.redirect", "session.steer", "prompt.submit"], "submit", "streaming"),
        ({"session.redirect": "rejected", "session.steer": ("error", 4010), "prompt.submit": "streaming"},
         ["session.redirect", "session.steer", "prompt.submit"], "submit", "streaming"),
        ({"session.redirect": "rejected", "session.steer": "rejected", "prompt.submit": "queued"},
         ["session.redirect", "session.steer", "prompt.submit"], "submit", "queued"),
    ],
)
def test_status_mapping(core, fake, answers, methods, via, status):
    fake.host.add("s1")
    fake.host.answers.update(answers)
    delivery = core.inject.TuiInjector().deliver(_owner(core), "[Voice] hi")
    assert (delivery.ok, delivery.via, delivery.status) == (True, via, status)
    assert fake.host.methods_called() == methods
    name, params = fake.host.calls[-1]
    assert params == {"session_id": "rt-s1", "text": "[Voice] hi"}  # prompt.submit without "queued"


def test_a_refused_submit_is_reported(core, fake):
    fake.host.add("s1")
    fake.host.answers.update({"session.redirect": "rejected", "session.steer": "rejected",
                              "prompt.submit": ("error", 4090)})
    delivery = core.inject.TuiInjector().deliver(_owner(core), "[Voice] hi")
    assert not delivery.ok and delivery.via == "submit" and delivery.detail == "refused"


def test_a_conversation_nobody_has_open_is_reopened_by_its_stored_id(core, fake):
    owner = _owner(core, "stored-1", profile="work")
    delivery = core.inject.TuiInjector().deliver(owner, "[Voice call started] ...")
    assert delivery.ok and delivery.via == "redirect"
    assert fake.host.calls[0] == ("session.resume", {"session_id": "stored-1", "source": "desktop",
                                                     "profile": "work"})
    assert fake.host.calls[1][1]["session_id"] == "rt-resumed-stored-1"
    assert owner.runtime_sid == "rt-resumed-stored-1"


def test_a_stale_runtime_id_is_resolved_again_once(core, fake):
    owner = _owner(core, "s1", runtime_sid="rt-gone")
    fake.host.add("s1", sid="rt-gone")
    reaped = {"done": False}

    def redirect(params):
        if params["session_id"] == "rt-gone" and not reaped["done"]:
            reaped["done"] = True
            del fake.host.sessions["rt-gone"]  # reaped between lookup and call
            return {"error": {"code": 4001, "message": "session not found"}}
        return {"result": {"status": "redirected"}}

    fake.host.answers["session.redirect"] = redirect
    delivery = core.inject.TuiInjector().deliver(owner, "[Voice] hi")
    assert delivery.ok
    assert fake.host.methods_called() == ["session.redirect", "session.resume", "session.redirect"]
    assert owner.runtime_sid == "rt-resumed-s1"


def test_the_runtime_session_wins_after_compression(core, fake):
    runtime = fake.host.add("s1")
    owner = _owner(core, "s1", runtime_sid=runtime)
    fake.host.rotate(runtime, "s1-tip")
    delivery = core.inject.TuiInjector().deliver(owner, "[Voice] hi")
    assert delivery.ok and fake.host.calls[0][1]["session_id"] == runtime
    assert owner.session_id == "s1-tip" and owner.owns("s1")


def test_no_session_host_in_this_process(core, fake, monkeypatch):
    import sys
    monkeypatch.setitem(sys.modules, "tui_gateway.server", None)
    delivery = core.inject.TuiInjector().deliver(_owner(core), "[Voice] hi")
    assert not delivery.ok and "hosts no dashboard sessions" in delivery.detail


def test_texts(core):
    hint = core.inject.REPLY_HINT
    assert core.inject.turn_text("end_of_speech", "  hello\n there ") == f"[Voice] hello there {hint}"
    assert core.inject.turn_text("cut_off", "wait") == f"[Voice, cut off] wait {hint}"
    assert core.inject.turn_text("hang_up", "bye") == f"[Voice, hung up] bye {core.inject.HUNG_UP_HINT}"
    assert core.inject.turn_text("muted", "uh") == f"[Voice, muted] uh {hint}"
    assert core.inject.turn_text("dropped", "and") == f"[Voice, line dropped] and {hint}"
    assert core.inject.turn_text("hang_up", "") is None and core.inject.turn_text("end_of_speech", " ") is None
    assert core.inject.turn_text("provider_error", "", "timeout") == f"[Voice, speech recognition failed: timeout] {hint}"
    assert "start_call" in hint
    assert core.inject.outcome_notice("no_answer").startswith("[Voice call not answered]")
    assert core.inject.outcome_notice("declined").startswith("[Voice call not answered]")
    assert core.inject.outcome_notice("push_failed", "APNs 400 BadTopic").startswith(
        "[Voice line not delivered: the phone couldn't be rung (APNs 400 BadTopic)]")
    assert core.inject.outcome_notice("ended_by_user").startswith("[Voice call ended by user]")
    assert core.inject.outcome_notice("ended_by_agent") is None and core.inject.outcome_notice("answered") is None
    assert core.inject.started_notice("ab" * 16).startswith("[Voice call started]")
    assert "start_call" in core.inject.started_notice("ab" * 16) and "end_call" in core.inject.started_notice("x")


def test_a_call_the_user_started_finds_its_session_in_any_profile(core, fake):
    fake.host.add("s1", profile_home="/profiles/work")
    owner = core.hub.Owner("s1")  # from a hello: the profile isn't known
    delivery = core.inject.TuiInjector().deliver(owner, "[Voice] hi")
    assert delivery.ok and fake.host.methods_called() == ["session.redirect"]
    assert owner.runtime_sid == "rt-s1"
