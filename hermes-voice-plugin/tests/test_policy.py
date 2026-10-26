"""Who may ring the phone: sources, rate limits, quiet hours and the ring log."""

from __future__ import annotations

import json
from datetime import datetime

import pytest


def _policy(core, tmp_path, clock, **policy):
    settings = core.config.Settings(policy=core.config.PolicyConfig(**policy))
    return core.policy.Policy(lambda: settings, log_dir=lambda: tmp_path, clock=clock)


def _origin(core, **fields):
    return core.hermes.Origin(**{"session_id": "s1", "source": "desktop", **fields})


@pytest.mark.parametrize(
    ("fields", "allowed", "reason"),
    [
        ({"source": "desktop"}, True, ""),
        ({"source": "dashboard"}, True, ""),
        ({"source": "tui"}, True, ""),
        ({"source": ""}, False, "source"),
        ({"source": "api_server"}, False, "source"),
        ({"is_cron": True}, False, "cron"),
        ({"is_subagent": True}, False, "subagent"),
        ({"platform": "telegram", "chat_type": "group", "user_id": "42"}, False, "group"),
        ({"platform": "telegram", "chat_type": "dm", "user_id": "42"}, True, ""),
        ({"platform": "telegram", "chat_type": "dm", "user_id": "7"}, False, "not_owner"),
    ],
)
def test_sources(core, tmp_path, fields, allowed, reason):
    policy = _policy(core, tmp_path, lambda: 1_000_000.0, owner_ids=("42",))
    decision = policy.check(_origin(core, **fields))
    assert (decision.allowed, decision.reason) == (allowed, reason)
    assert allowed or decision.note


def test_owner_dms_can_be_turned_off_and_groups_on(core, tmp_path):
    policy = _policy(core, tmp_path, lambda: 0.0, owner_ids=("42",), allow_owner_dms=False, allow_groups=True)
    assert not policy.check(_origin(core, platform="discord", chat_type="dm", user_id="42")).allowed
    assert policy.check(_origin(core, platform="discord", chat_type="group")).allowed


def test_rate_limits_per_conversation_and_overall(core, tmp_path):
    now = [1000.0]
    policy = _policy(core, tmp_path, lambda: now[0], rings_per_session=2, session_window_s=600,
                     rings_global=3, global_window_s=3600)
    for _ in range(2):
        assert policy.check(_origin(core)).allowed
        policy.record_ring(_origin(core), "c" * 32)
    assert policy.check(_origin(core)).reason == "rate_session"
    assert policy.check(_origin(core, session_id="s2")).allowed
    policy.record_ring(_origin(core, session_id="s2"), "d" * 32)
    assert policy.check(_origin(core, session_id="s3")).reason == "rate_global"
    now[0] += 601  # the per-conversation window passed; the hourly one has not
    assert policy.check(_origin(core, session_id="s1")).reason == "rate_global"
    now[0] += 3600
    assert policy.check(_origin(core)).allowed


def _at(hour: int, minute: int = 0) -> float:
    return datetime(2026, 10, 25, hour, minute).timestamp()


def test_quiet_hours_refuse(core, tmp_path):
    now = [_at(23, 30)]
    quiet = core.config.QuietHours(start=22 * 60, end=7 * 60)
    policy = _policy(core, tmp_path, lambda: now[0], quiet_hours=quiet)
    assert policy.check(_origin(core)).reason == "quiet_hours"
    now[0] = _at(6, 59)
    assert policy.check(_origin(core)).reason == "quiet_hours"
    now[0] = _at(7, 0)
    assert policy.check(_origin(core)).allowed
    assert core.policy.in_quiet_hours(core.config.QuietHours(9 * 60, 17 * 60), _at(12))
    assert not core.policy.in_quiet_hours(core.config.QuietHours(9 * 60, 17 * 60), _at(18))


def test_quiet_hours_confirm_needs_a_user_turn_after_the_refusal(core, tmp_path):
    now = [_at(23)]
    quiet = core.config.QuietHours(start=22 * 60, end=7 * 60, action="confirm")
    policy = _policy(core, tmp_path, lambda: now[0], quiet_hours=quiet)
    refused = policy.check(_origin(core))
    assert refused.reason == "quiet_hours_confirm" and "Ask them" in refused.note
    now[0] += 1
    assert not policy.check(_origin(core)).allowed  # asking again without the user's go-ahead
    now[0] += 30
    policy.note_user_turn("s1")  # the user answered ("yes, call me")
    now[0] += 5
    assert policy.check(_origin(core)).allowed
    now[0] += 1
    assert not policy.check(_origin(core, session_id="s2")).allowed  # another conversation needs its own


def test_the_ring_log_records_decisions_and_outcomes(core, fake, make_hub, tmp_path):
    policy = _policy(core, tmp_path, lambda: 1_700_000_000.0)
    policy.check(_origin(core, is_cron=True))
    policy.record_ring(_origin(core), "a" * 32)
    entries = [json.loads(line) for line in (tmp_path / "rings.jsonl").read_text().splitlines()]
    assert [e["event"] for e in entries] == ["refused", "ring"]
    assert entries[0]["reason"] == "cron" and entries[1]["call_id"] == "a" * 32
    assert entries[1]["session_id"] == "s1" and entries[1]["source"] == "desktop"
    assert entries[0]["at"].startswith("2023-11-14T22:13:20")

    hub = make_hub()
    origin = _origin(core)
    call = core.hub.Call(hub, "b" * 32, core.hub.Owner.from_origin(origin), "agent", "ringing")
    hub.slot = call
    hub.finish(call, "no_answer")
    last = json.loads((tmp_path / "hermes-voice" / "rings.jsonl").read_text().splitlines()[-1])
    assert (last["event"], last["outcome"], last["call_id"]) == ("ended", "no_answer", "b" * 32)


@pytest.mark.parametrize(
    ("message", "own"),
    [
        ("yes, call me", True),
        ("  sure ", True),
        ([{"type": "text", "text": "yes please"}, {"type": "image_url", "image_url": {"url": "x"}}], True),
        ("", False),
        (None, False),
        ([{"type": "image_url", "image_url": {"url": "x"}}], False),
        ("[Voice] yes call me (Reply out loud with start_call; your text replies are not spoken.)", False),
        ("[Voice call ended by user] Reply in text from now on", False),
        ("[Continuing toward your standing goal]\nGoal: ship it", False),
        ("[System note: Your previous turn was interrupted mid-run", False),
        ("[IMPORTANT: Background process 12 exited (exit code 0).", False),
    ],
)
def test_only_the_users_own_messages_count_as_a_go_ahead(core, message, own):
    assert core.policy.users_own_message(message) is own


# ── messaging DMs: who the owner is ────────────────────────────────────────────────────────────────────────


def test_owner_ids_may_name_the_platform(core, tmp_path):
    policy = _policy(core, tmp_path, lambda: 0.0, owner_ids=("telegram:42", "@alice:matrix.org"))

    def dm(platform, user, **fields):
        return policy.check(_origin(core, platform=platform, chat_type="dm", user_id=user, **fields))

    assert dm("telegram", "42").allowed
    assert dm("discord", "42").reason == "not_owner"  # 42 is someone else there
    assert dm("matrix", "@alice:matrix.org").allowed  # a colon in an id is not a platform
    # With owner_ids set, they alone decide: the gateway's view doesn't widen them.
    assert dm("telegram", "7", is_owner=True).reason == "not_owner"


def test_without_owner_ids_the_gateway_decides_who_the_owner_is(core, tmp_path):
    policy = _policy(core, tmp_path, lambda: 0.0)
    assert policy.check(_origin(core, platform="telegram", chat_type="dm", user_id="42", is_owner=True)).allowed
    assert policy.check(_origin(core, platform="telegram", chat_type="dm", user_id="42")).reason == "not_owner"
    assert policy.check(_origin(core, platform="telegram", chat_type="dm", is_owner=True)).reason == "not_owner"


def test_the_owner_is_whoever_the_gateway_allowlists_by_name_or_paired(core, fake, monkeypatch):
    import sys
    import types

    pairing = types.ModuleType("gateway.pairing")
    approved = {("signal", "+4611")}
    pairing._allowlist_env_for_platform = lambda platform: f"{platform.upper()}_ALLOWED_USERS"
    pairing._read_allowlist_env = lambda name: fake.secrets.get(name, "")
    pairing._user_ids_match = lambda platform, left, right: left.lstrip("+") == right.lstrip("+")
    pairing.PairingStore = lambda: types.SimpleNamespace(
        is_approved=lambda platform, user: (platform, user) in approved)
    monkeypatch.setitem(sys.modules, "gateway.pairing", pairing)
    monkeypatch.setattr(sys.modules["gateway"], "pairing", pairing, raising=False)
    fake.secrets.update({"TELEGRAM_ALLOWED_USERS": "42, 43", "DISCORD_ALLOWED_USERS": "*",
                         "GATEWAY_ALLOWED_USERS": "99"})
    owner = core.policy.gateway_owner
    assert owner("telegram", "42") and owner("telegram", "43") and owner("telegram", "99")
    assert not owner("telegram", "7")
    assert not owner("discord", "7")  # a wildcard lets anyone write: nobody is the owner by it
    assert owner("signal", "+4611") and owner("signal", "4611") is False  # paired (the store matches exactly)
    assert not owner("desktop", "42") and not owner("telegram", "")


def test_a_go_ahead_reported_by_another_process_counts(core, tmp_path):
    now = [_at(23)]
    quiet = core.config.QuietHours(start=22 * 60, end=7 * 60, action="confirm")
    policy = _policy(core, tmp_path, lambda: now[0], quiet_hours=quiet)
    assert policy.check(_origin(core)).reason == "quiet_hours_confirm"
    now[0] += 10
    assert not policy.check(_origin(core, user_turn_at=now[0] + 60)).allowed  # a time still to come: ignored
    now[0] += 10
    assert policy.check(_origin(core, user_turn_at=now[0] - 5)).allowed
