"""Calls that ring later (schedule.py): reading the time, the schedule file, ringing at the due time, what the
policy is asked and when, busy and unanswered rings, a host that was down, cancelling, the hub socket, the ring log
and ``/status``. The schedulers here are ticked by the tests, on a clock the tests set."""

from __future__ import annotations

import asyncio
import json
import stat
import time
import types
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import pytest

from support import PLUGIN_DIR, FakePusher, Phone, RecordingInjector, serving, tool, until

BERLIN = "Europe/Berlin"
# 2026-03-10 21:30 in Berlin (UTC+1), a Tuesday.
NOW = datetime(2026, 3, 10, 21, 30, tzinfo=ZoneInfo(BERLIN)).timestamp()


def at_berlin(*parts: int) -> float:
    return datetime(*parts, tzinfo=ZoneInfo(BERLIN)).timestamp()


class World:
    """A hub whose policy and schedule read the test's clock, with its files in the fake HERMES_HOME."""

    def __init__(self, core, fake, make_hub, now: float = NOW, **settings) -> None:
        self.core, self.fake, self.make_hub = core, fake, make_hub
        self.now = now
        self.folder = fake.home / "hermes-voice"
        self.settings = core.config.Settings(**{"fake_tts": True, "ring_timeout_s": 10.0, **settings})
        self.pusher = FakePusher()
        self.injector = RecordingInjector()
        self.hub = self.boot()

    def boot(self):
        """A dashboard (re)start: a new hub over the same folder."""
        policy = self.core.policy.Policy(lambda: self.settings, log_dir=lambda: self.folder, clock=lambda: self.now)
        self.hub = self.make_hub(settings=self.settings, pusher=self.pusher, injector=self.injector, policy=policy)
        return self.hub

    @property
    def schedule(self):
        return self.hub.schedule

    def origin(self, session_id: str = "s1", **fields):
        return self.core.hermes.Origin(**{"session_id": session_id, "source": "desktop", **fields})

    def later(self, text: str = "Time to get up.", session_id: str = "s1", **when) -> dict:
        return self.schedule.schedule(self.origin(session_id), text, **(when or {"in_minutes": 10}))

    def file(self) -> dict:
        return json.loads((self.folder / "scheduled.json").read_text())

    def log(self, *events: str) -> list[dict]:
        path = self.folder / "rings.jsonl"
        entries = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [entry for entry in entries if not events or entry["event"] in events]

    def notices(self, session_id: str = "s1") -> list[str]:
        return [text for sid, text in self.injector.delivered if sid == session_id]

    def wait_notices(self, count: int, session_id: str = "s1") -> list[str]:
        deadline = time.monotonic() + 5
        while len(self.notices(session_id)) < count and time.monotonic() < deadline:
            time.sleep(0.01)
        return self.notices(session_id)


@pytest.fixture
def world(core, fake, make_hub):
    fake.host.add("s1", title="Morning chat")
    return World(core, fake, make_hub)


# ── reading the time ───────────────────────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(("minutes", "seconds"), [(10, 600.0), (0.5, 30.0), ("15", 900.0), (1440, 86400.0)])
def test_in_minutes_counts_from_now(core, minutes, seconds):
    assert core.schedule.parse_when(minutes, None, NOW, BERLIN) == (NOW + seconds, "")


@pytest.mark.parametrize("minutes", [0, -5, True, "soon", float("nan"), float("inf")])
def test_in_minutes_must_be_a_number_above_zero(core, minutes):
    moment, problem = core.schedule.parse_when(minutes, None, NOW, BERLIN)
    assert moment is None and "in_minutes must be a number above 0" in problem


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("23:15", at_berlin(2026, 3, 10, 23, 15)),  # later today
        ("07:00", at_berlin(2026, 3, 11, 7, 0)),  # has passed today: tomorrow
        ("7:00", at_berlin(2026, 3, 11, 7, 0)),
        ("21:30", at_berlin(2026, 3, 11, 21, 30)),  # the clock shows it right now: the next time is tomorrow
        ("21:30:30", at_berlin(2026, 3, 10, 21, 30, 30)),
        ("7am", at_berlin(2026, 3, 11, 7, 0)),
        ("11:45 PM", at_berlin(2026, 3, 10, 23, 45)),
        ("12:10 a.m.", at_berlin(2026, 3, 11, 0, 10)),
    ],
)
def test_a_clock_time_is_the_next_time_the_clock_shows_it(core, text, expected):
    assert core.schedule.parse_when(None, text, NOW, BERLIN) == (expected, "")


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("2026-03-12T07:00", at_berlin(2026, 3, 12, 7, 0)),  # no offset: the same clock
        ("2026-03-12 07:00:30", at_berlin(2026, 3, 12, 7, 0, 30)),
        ("2026-03-12T07:00:00+09:00", datetime(2026, 3, 11, 22, 0, tzinfo=timezone.utc).timestamp()),
        ("2026-03-11T06:00:00Z", datetime(2026, 3, 11, 6, 0, tzinfo=timezone.utc).timestamp()),
        ("2026-03-10T21:29:55", NOW),  # a few seconds ago: now
    ],
)
def test_an_iso_date_time_is_that_moment(core, text, expected):
    assert core.schedule.parse_when(None, text, NOW, BERLIN) == (expected, "")


def test_the_clock_is_the_zone_given_else_the_hosts(core):
    tokyo, _ = core.schedule.parse_when(None, "07:00", NOW, "Asia/Tokyo")
    assert datetime.fromtimestamp(tokyo, ZoneInfo("Asia/Tokyo")).strftime("%d %H:%M") == "11 07:00"
    assert tokyo < core.schedule.parse_when(None, "07:00", NOW, BERLIN)[0]
    host, _ = core.schedule.parse_when(None, "07:00", NOW, "")
    assert datetime.fromtimestamp(host).strftime("%H:%M") == "07:00" and 0 < host - NOW <= 86400
    unknown, _ = core.schedule.parse_when(None, "07:00", NOW, "Mars/Olympus")  # falls back to the host's clock
    assert unknown == host
    assert core.schedule.local_text(at_berlin(2026, 3, 11, 7, 0), BERLIN) == "2026-03-11 07:00"


@pytest.mark.parametrize(
    ("in_minutes", "at", "says"),
    [
        (10, "07:00", "either in_minutes or at, not both"),
        (None, None, "No time given"),
        (None, "2026-03-10T20:00", "in the past"),
        (None, "2026-03-25T07:00", "more than 7 days ahead"),
        (8 * 24 * 60, None, "more than 7 days ahead"),
        (None, "2026-03-12", "no time of day"),
        (None, "25:00", "not a clock time"),
        (None, "13pm", "not a clock time"),
        (None, "tomorrow morning", "Can't read the time"),
        (None, 700, "at must be a string"),
    ],
)
def test_times_that_cant_be_used_say_why(core, in_minutes, at, says):
    moment, problem = core.schedule.parse_when(in_minutes, at, NOW, BERLIN)
    assert moment is None and says in problem


def test_null_and_empty_arguments_count_as_not_given(core):
    assert not core.schedule.given(None) and not core.schedule.given("") and not core.schedule.given("  ")
    assert core.schedule.given(0) and core.schedule.given("07:00") and core.schedule.given(10)
    assert core.schedule.parse_when(10, "", NOW) == (NOW + 600, "")
    assert core.schedule.parse_when("10 min", None, NOW) == (NOW + 600, "")
    later = core.schedule.wants_later
    assert later(10, None) and later(None, "07:00") and later(0, "07:00") and later(-5, None) and later("x", "")
    # A model that fills in every parameter: "in 0 minutes" with no clock time is a call now.
    assert not later(None, None) and not later(0, "") and not later("0", None) and not later(0.0, None)


def test_in_minutes_zero_rings_now(world):
    async def scenario():
        return await tool(world.core.tools.start_call, {"text": "Hi.", "mode": "async", "in_minutes": 0, "at": ""})

    result = asyncio.run(scenario())
    assert result["status"] == "ringing" and world.pusher.pushed.wait(5) and world.schedule.count() == 0


# ── scheduling: the result, the file, a restart ────────────────────────────────────────────────────────────


def test_scheduling_returns_at_once_and_keeps_the_call_in_a_private_file(world):
    result = world.later(text="Good morning, it is seven.", at="07:00")
    assert result["status"] == "scheduled" and result["scheduled_id"].startswith("sc-")
    assert result["rings_at"] == world.core.schedule.local_text(result_time := world.file()["calls"][0]["rings_at"])
    assert 0 < result_time - NOW <= 86400
    assert result["pending"] == [{"scheduled_id": result["scheduled_id"], "rings_at": result["rings_at"],
                                  "text": "Good morning, it is seven."}]
    note = result["note"]
    assert "mode is ignored for a scheduled call" in note and "[Voice] messages" in note
    assert "rings again after 5 min" in note
    assert f'List or cancel with scheduled_calls (cancel: "{result["scheduled_id"]}").' in note
    assert 'tell the user the time the way people say it ("tomorrow at seven")' in note
    assert world.pusher.payloads == []  # nothing rings now
    path = world.folder / "scheduled.json"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    stored = world.file()
    assert stored["version"] == 1 and len(stored["calls"]) == 1
    call = stored["calls"][0]
    assert call["text"] == "Good morning, it is seven." and call["session_id"] == "s1" and call["source"] == "desktop"
    assert call["title"] == "" and call["due_at"] == call["rings_at"] and call["rings"] == []
    assert not list(world.folder.glob(".scheduled.json.*"))  # written through a temp file, then renamed
    assert world.hub.status()["scheduled"] == 1
    logged = world.log("scheduled")
    assert [entry["scheduled"] for entry in logged] == [result["scheduled_id"]]
    assert "Good morning" not in (world.folder / "rings.jsonl").read_text()  # never the line's text


def test_the_tool_schedules_with_in_minutes_or_at_and_ignores_mode(world):
    core = world.core
    schema = core.tools.start_call_schema()
    assert {"in_minutes", "at"} <= set(schema["parameters"]["properties"])
    assert schema["parameters"]["required"] == ["text"]
    assert ('To ring later ("call me in ten", a wake-up), set in_minutes or at; the plugin rings on time itself. '
            "Never wait in a turn or use cron. List or cancel with scheduled_calls.") in schema["description"]
    # Hanging up and the schedule are two tools: end_call has no argument that could be read as "hang up all".
    assert set(core.tools.END_CALL["parameters"]["properties"]) == {"text"}
    assert "scheduled" not in core.tools.END_CALL["description"]
    assert set(core.tools.SCHEDULED_CALLS["parameters"]["properties"]) == {"cancel"}
    assert "required" not in core.tools.SCHEDULED_CALLS["parameters"]
    assert core.tools.SCHEDULED_CALLS["description"] == (
        "List the calls this conversation scheduled with start_call (in_minutes / at), or cancel them: pass "
        '`cancel` with a scheduled_id, or "all". Returns {pending, cancelled, note}; it never rings or hangs up.')

    async def scenario():
        first = await tool(core.tools.start_call, {"text": "Ten minutes are up.", "in_minutes": 10, "mode": "sync"})
        second = await tool(core.tools.start_call, {"text": "Wake up.", "at": "07:00", "in_minutes": None})
        both = await tool(core.tools.start_call, {"text": "x", "at": "07:00", "in_minutes": 5})
        bad = await tool(core.tools.start_call, {"text": "x", "at": "next week"})
        listed = await tool(core.tools.scheduled_calls, {})
        hang_up = await tool(core.tools.end_call, {})
        return first, second, both, bad, listed, hang_up

    first, second, both, bad, listed, hang_up = asyncio.run(scenario())
    assert first["status"] == "scheduled" and second["status"] == "scheduled"
    assert world.file()["calls"][0]["rings_at"] == NOW + 600 and world.file()["calls"][0]["title"] == "Morning chat"
    assert both == {"error": "Give either in_minutes or at, not both."}
    assert "Can't read the time 'next week'" in bad["error"] and "It is now" in bad["error"]
    assert [entry["scheduled_id"] for entry in second["pending"]] == [first["scheduled_id"], second["scheduled_id"]]
    assert listed == {"pending": second["pending"], "cancelled": [],
                      "note": "2 calls scheduled in this conversation. Nothing was changed."}
    # end_call only hangs up; with no call running it points at what is scheduled, and at the tool for it.
    assert hang_up["outcome"] is None and "2 scheduled for later" in hang_up["note"]
    assert "scheduled_calls cancels them" in hang_up["note"]
    assert hang_up["pending"] == second["pending"]
    assert world.pusher.payloads == []


def test_a_scheduled_call_survives_a_restart_and_rings_at_its_time(world):
    scheduled = world.later()
    world.hub.schedule.stop()
    hub = world.boot()  # the dashboard restarted
    assert hub.status()["scheduled"] == 1 and hub.schedule.pending(world.origin()) == scheduled["pending"]
    world.now = NOW + 599
    assert hub.schedule.tick() == 0 and world.pusher.payloads == []
    world.now = NOW + 600
    assert hub.schedule.tick() == 1
    assert world.pusher.pushed.wait(5)
    payload = world.pusher.payloads[0]
    assert payload["session_id"] == "s1" and payload["mode"] == "async" and payload["title"] == "Morning chat"
    call = hub.slot
    assert call.call_id == payload["call_id"] and call.state == "ringing" and call.scheduled.id == scheduled["scheduled_id"]
    assert world.file()["calls"][0]["call_id"] == call.call_id  # marked as ringing, so it is not rung twice
    assert hub.schedule.tick() == 0 and len(world.pusher.payloads) == 1


def test_an_unreadable_schedule_file_is_set_aside(world):
    world.folder.mkdir(parents=True, exist_ok=True)
    (world.folder / "scheduled.json").write_text("{not json")
    assert world.schedule.count() == 0 and (world.folder / "scheduled.json.broken").exists()
    assert world.later()["status"] == "scheduled" and world.schedule.count() == 1
    # A malformed entry is skipped, the others stay.
    data = world.file()
    data["calls"].append({"id": "sc-bad"})
    (world.folder / "scheduled.json").write_text(json.dumps(data))
    assert world.schedule.count() == 1


def test_only_one_dashboard_rings_a_folders_schedule(core, fake, make_hub, world):
    other = World(core, fake, make_hub)
    assert world.schedule._take() is True and world.schedule.running()
    assert other.schedule._take() is False and not other.schedule.running()
    world.schedule.stop()
    assert other.schedule._take() is True
    other.schedule.stop()


def test_the_dashboard_process_rings_once_it_serves_and_stops_when_the_plugin_unloads(world, monkeypatch):
    import sys

    hub_module = world.core.hub
    monkeypatch.delenv("HERMES_VOICE_SCHEDULE", raising=False)
    sys.__dict__.pop(hub_module._SCHEDULE_KEY, None)
    world.fake.bound_host = None  # the web server is imported, not serving yet
    try:
        hub_module.run_schedule_when_ready()
        time.sleep(0.2)
        assert not world.schedule.running()
        world.later(in_minutes=0.001)
        world.now = NOW + 1
        world.fake.bound_host = "127.0.0.1"  # it serves: the schedule starts, and rings what is due
        assert world.pusher.pushed.wait(5) and world.schedule.running()
        hub_module.pause_schedule()  # the plugin unloads
        assert not world.schedule.running()
        hub_module.resume_schedule()  # and loads again
        deadline = time.monotonic() + 5
        while not world.schedule.running() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert world.schedule.running()
    finally:
        hub_module.pause_schedule()
        sys.__dict__.pop(hub_module._SCHEDULE_KEY, None)


def test_the_runner_thread_rings_what_is_due(world):
    world.later(in_minutes=0.001)
    world.now = NOW + 1
    world.schedule.start()
    try:
        assert world.pusher.pushed.wait(5)
        assert world.hub.slot is not None and world.hub.slot.scheduled is not None
    finally:
        world.schedule.stop()
    assert not world.schedule.running()


# ── the ring: answered, spoken, replied to ─────────────────────────────────────────────────────────────────


def test_the_ring_is_answered_the_line_spoken_and_the_reply_injected(world):
    core, fake, hub = world.core, world.fake, world.hub
    scheduled = world.later(text="Time to get up.")
    fake.host.sessions.clear()  # nobody has the conversation open at ring time

    async def scenario():
        async with serving(core) as port:
            world.now = NOW + 600
            await asyncio.to_thread(hub.schedule.tick)
            await asyncio.to_thread(world.pusher.pushed.wait, 5)
            payload = world.pusher.payloads[-1]
            phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push", session_id="s1")
            await phone.send({"type": "ringing"})
            await phone.send({"type": "answered"})
            line = await phone.expect("speech_start")
            await phone.expect("speech_end")
            await until(lambda: phone.played_at)
            await world.injector.wait_for(1)
            await phone.say("I'm up, thanks.")
            await world.injector.wait_for(2)
            status = hub.status()
            await phone.hang_up()
            await world.injector.wait_for(3)
            return payload, line, status

    payload, line, status = asyncio.run(scenario())
    assert line["text"] == "Time to get up."
    assert status["scheduled"] == 0 and status["active_call"]["call_id"] == payload["call_id"]
    started, turn, ended = world.notices()
    assert started.startswith("[Voice call started] Automated notice from HermesVoice, not something the user said.")
    assert (f"The user answered the call you scheduled for {scheduled['rings_at']} (scheduled_id "
            f"{scheduled['scheduled_id']}, call {payload['call_id']}) and is hearing the line you gave then: "
            '"Time to get up.".') in started
    assert "late" not in started and "Don't speak yet" in started
    assert ("The line is as old as its scheduling: check anything that may have changed since before you say more."
            in started)
    assert turn.startswith("[Voice] I'm up, thanks. (Reply out loud with start_call")
    assert ended.startswith("[Voice call ended by user]") and "scheduled" not in ended
    assert not (world.folder / "scheduled.json").exists()  # done: nothing of it stays on disk
    assert hub.status()["scheduled"] == 0
    ring = world.log("ring")[0]
    assert ring["scheduled"] == scheduled["scheduled_id"] and ring["attempt"] == 1 and "late_s" not in ring
    done = world.log("scheduled_done")
    assert [(entry["outcome"], entry["rings"]) for entry in done] == [("answered", 1)]


def test_quiet_hours_and_rate_limits_dont_refuse_a_scheduled_ring(core, fake, make_hub):
    fake.host.add("s1")
    local = datetime.fromtimestamp(NOW + 600)
    minute = local.hour * 60 + local.minute
    quiet = core.config.QuietHours(start=(minute - 60) % 1440, end=(minute + 60) % 1440)
    world = World(core, fake, make_hub, policy=core.config.PolicyConfig(rings_per_session=1, rings_global=1,
                                                                         quiet_hours=quiet))
    scheduled = world.later()
    assert scheduled["status"] == "scheduled"  # scheduling inside quiet hours is not refused either ...
    assert "inside the user's quiet hours; a call they asked for rings anyway" in scheduled["note"]
    world.now = NOW + 600
    world.hub.policy.record_ring(world.origin(), "a" * 32)  # ... and the limits are used up by then
    now = world.hub.begin_call(world.origin(session_id="s1"), "Hi").result
    assert now["status"] == "not_allowed"  # a ring the agent asks for now is refused
    assert world.schedule.tick() == 1
    assert world.pusher.pushed.wait(5) and world.hub.slot.scheduled.id == scheduled["scheduled_id"]
    ring = world.log("ring")[-1]
    assert ring["scheduled"] == scheduled["scheduled_id"] and ring["quiet_hours"] is True
    # It counts like any ring for what comes after it.
    assert len(world.hub.policy.rings) == 2


def test_a_scheduled_line_is_spoken_into_the_conversations_own_live_call(world):
    core, fake, hub = world.core, world.fake, world.hub
    scheduled = world.later(text="The ten minutes are up.")

    async def scenario():
        async with serving(core) as port:
            phone = await Phone.dial(port, fake, session_id="s1")  # the user called this conversation meanwhile
            await world.injector.wait_for(1)
            world.now = NOW + 600
            await asyncio.to_thread(hub.schedule.tick)
            line = await phone.expect("speech_start")
            await world.injector.wait_for(2)
            await phone.hang_up()
            return line

    line = asyncio.run(scenario())
    assert line["text"] == "The ten minutes are up." and world.pusher.payloads == []  # no ring
    assert world.notices()[1].startswith(f"[Voice line spoken: the call scheduled for {scheduled['rings_at']}] "
                                         "Automated notice from HermesVoice, not something the user said.")
    assert hub.status()["scheduled"] == 0 and world.log("scheduled_spoken")


# ── the policy when scheduling ─────────────────────────────────────────────────────────────────────────────


def test_a_ring_that_would_be_refused_is_refused_when_scheduling(world):
    core, schedule = world.core, world.schedule
    cron = schedule.schedule(world.origin(is_cron=True), "Wake up.", at="07:00")
    assert cron["status"] == "not_allowed" and cron["scheduled_id"] is None
    assert cron["note"].startswith("Scheduled jobs can't call the user. Report in text instead.")
    assert "start_call with at or in_minutes" in cron["note"]
    assert schedule.schedule(world.origin(is_subagent=True), "x", in_minutes=5)["status"] == "not_allowed"
    assert schedule.schedule(world.origin(source="oneshot"), "x", in_minutes=5)["status"] == "not_allowed"
    group = world.origin(source="", platform="telegram", chat_type="group", user_id="42")
    assert schedule.schedule(group, "x", in_minutes=5)["status"] == "not_allowed"
    assert schedule.schedule(world.origin(session_id=""), "x", in_minutes=5)["status"] == "not_allowed"
    assert not (world.folder / "scheduled.json").exists() and schedule.count() == 0
    refused = world.log("refused")
    assert [entry["reason"] for entry in refused] == ["cron", "subagent", "source", "group"]
    assert all(entry["scheduling"] is True for entry in refused)
    # With the setting on, a cron job may schedule like it may ring.
    world.settings = core.config.Settings(fake_tts=True, policy=core.config.PolicyConfig(allow_cron=True))
    assert schedule.schedule(world.origin(is_cron=True), "Wake up.", at="07:00")["status"] == "scheduled"


def test_a_refused_cron_or_one_shot_ring_points_to_scheduling(world):
    for origin in (world.origin(is_cron=True), world.origin(source="oneshot")):
        refused = world.hub.begin_call(origin, "Wake up.").result
        assert refused["status"] == "not_allowed"
        assert refused["note"].endswith("For a call at a set time, the conversation the user asked in schedules it "
                                        "itself: start_call with at or in_minutes. That needs no cron job.")
    other = world.hub.begin_call(world.origin(source="api_server"), "Hi").result
    assert other["note"] == "Conversations from api_server can't call the user."


def test_how_many_calls_can_wait(world):
    schedule = world.core.schedule
    for index in range(schedule.PER_CONVERSATION):
        assert world.later(in_minutes=10 + index)["status"] == "scheduled"
    full = world.later()
    assert full["status"] == "not_allowed" and "already has 5 calls scheduled" in full["note"]
    assert len(full["pending"]) == 5 and world.schedule.count() == 5
    for index in range(schedule.OVERALL - schedule.PER_CONVERSATION):
        assert world.later(session_id=f"other-{index}")["status"] == "scheduled"
    assert "20 calls are already scheduled on this host" in world.later(session_id="one-more")["note"]


def test_scheduling_warns_when_the_phone_cant_be_rung_and_about_a_long_line(world):
    world.pusher.configured = lambda: (False, "HERMES_VOICE_APNS_KEY_PATH is not set")
    result = world.later(text="word " * 80)
    assert result["status"] == "scheduled"
    assert "Warning: the phone can't be rung as things are (HERMES_VOICE_APNS_KEY_PATH is not set)" in result["note"]
    assert "Long line: about" in result["note"]
    assert result["pending"][0]["text"].endswith("…") and len(result["pending"][0]["text"]) <= 81


# ── busy, not answered ─────────────────────────────────────────────────────────────────────────────────────


def test_while_the_user_is_on_another_call_it_tries_again_shortly(world):
    hub, schedule = world.hub, world.core.schedule
    scheduled = world.later()
    world.fake.host.add("s2")
    other = hub.begin_call(world.origin("s2"), "Hello from the other chat.").call
    assert world.pusher.pushed.wait(5)
    world.now = NOW + 600
    pushes = len(world.pusher.payloads)
    assert world.schedule.tick() == 1 and hub.slot is other
    entry = world.file()["calls"][0]
    assert entry["call_id"] == "" and entry["rings"] == [] and entry["busy_tries"] == 1
    assert entry["due_at"] == NOW + 600 + schedule.BUSY_RETRY_S and entry["rings_at"] == NOW + 600
    assert world.schedule.tick() == 0  # not before the retry is due
    hub.finish(other, "ended_by_agent")
    world.now += schedule.BUSY_RETRY_S
    assert world.schedule.tick() == 1 and hub.slot.scheduled.id == scheduled["scheduled_id"]
    deadline = time.monotonic() + 5
    while len(world.pusher.payloads) <= pushes and time.monotonic() < deadline:
        time.sleep(0.01)
    assert world.pusher.payloads[-1]["call_id"] == hub.slot.call_id
    assert [entry["try"] for entry in world.log("scheduled_busy")] == [1]
    assert world.notices() == []


def test_a_line_that_stays_busy_is_dropped_and_the_conversation_told(world):
    hub, schedule = world.hub, world.core.schedule
    scheduled = world.later(text="Time to get up.")
    world.fake.host.add("s2")
    hub.begin_call(world.origin("s2"), "A long call.")
    world.now = NOW + 600
    for _ in range(schedule.BUSY_TRIES + 1):
        assert world.schedule.tick() == 1
        world.now += schedule.BUSY_RETRY_S
    assert world.schedule.count() == 0 and world.schedule.tick() == 0
    notice, = world.wait_notices(1)
    assert notice.startswith(f"[Voice call not placed: scheduled for {scheduled['rings_at']}] Automated notice from "
                             "HermesVoice, not something the user said.")
    assert "the user was on another call at that time, and still was 6 tries and about 3 min later" in notice
    assert 'Nothing was spoken; its line was: "Time to get up."' in notice
    dropped = world.log("scheduled_dropped")
    assert [(entry["scheduled"], entry["reason"]) for entry in dropped] == [(scheduled["scheduled_id"], "busy")]


def test_not_answered_it_rings_once_more_then_tells_the_conversation(world):
    hub = world.hub
    scheduled = world.later(text="Time to get up.")
    world.now = NOW + 600
    world.schedule.tick()
    first = hub.slot
    hub._ring_expired(first)  # the ring ran out: no phone ever connected
    assert first.outcome == "unreachable" and hub.slot is None
    entry = world.file()["calls"][0]
    assert entry["call_id"] == "" and entry["rings"] == [NOW + 600] and entry["due_at"] == NOW + 600 + 300
    assert world.notices() == []  # nothing is said yet: it rings again
    retry = world.log("scheduled_retry")[0]
    assert retry["scheduled"] == scheduled["scheduled_id"] and retry["outcome"] == "unreachable"
    world.now = NOW + 899
    assert world.schedule.tick() == 0
    world.now = NOW + 900
    assert world.schedule.tick() == 1
    second = hub.slot
    assert second is not first and second.scheduled.attempt == 2 and second.scheduled.earlier == (NOW + 600,)
    hub.finish(second, "no_answer")
    notice, = world.wait_notices(1)
    clock = world.core.schedule.clock_text
    assert notice.startswith("[Voice call not answered] Automated notice from HermesVoice, not something the user "
                             "said.")
    assert notice.endswith(
        f" This was the call you scheduled for {scheduled['rings_at']} (scheduled_id {scheduled['scheduled_id']}): "
        f"it was tried at {clock(NOW + 600)} and {clock(NOW + 900)}, and will not be tried again by itself. Its "
        'line was: "Time to get up.".')
    assert not (world.folder / "scheduled.json").exists()
    assert [entry["attempt"] for entry in world.log("ring")] == [1, 2]
    assert [(entry["outcome"], entry["rings"]) for entry in world.log("scheduled_done")] == [("no_answer", 2)]


@pytest.mark.parametrize(("retries", "outcome"), [(0, "no_answer"), (1, "declined"), (3, "declined")])
def test_no_repeat_with_retries_off_or_after_a_declined_ring(core, fake, make_hub, retries, outcome):
    fake.host.add("s1")
    world = World(core, fake, make_hub, scheduled=core.config.ScheduledConfig(retries=retries, retry_after_s=60))
    scheduled = world.later()
    assert ("rings again" in scheduled["note"]) == bool(retries)
    world.now = NOW + 600
    world.schedule.tick()
    world.hub.finish(world.hub.slot, outcome)
    notice, = world.wait_notices(1)
    assert notice.startswith("[Voice call not answered]") and "This was the call you scheduled for" in notice
    assert world.schedule.count() == 0 and world.log("scheduled_retry") == []


def test_retry_settings_are_read_and_bounded(core):
    load = core.config.Settings.from_config
    assert load({}, {}).scheduled == core.config.ScheduledConfig(retries=1, retry_after_s=300.0, late_limit_s=900.0)
    custom = {"plugins": {"entries": {"hermes_voice": {"settings": {"scheduled": {
        "retries": 2, "retry_after_s": 120, "late_limit_s": 0}}}}}}
    assert load(custom, {}).scheduled == core.config.ScheduledConfig(retries=2, retry_after_s=120.0, late_limit_s=0.0)
    wild = {"plugins": {"entries": {"hermes_voice": {"settings": {"scheduled": {
        "retries": 99, "retry_after_s": 0, "late_limit_s": "soon"}}}}}}
    assert load(wild, {}).scheduled == core.config.ScheduledConfig(retries=5, retry_after_s=5.0, late_limit_s=900.0)


# ── the host was down at the time ──────────────────────────────────────────────────────────────────────────


def test_a_call_the_host_missed_by_a_little_rings_late_and_says_so(world):
    core, fake = world.core, world.fake
    scheduled = world.later(text="Time to get up.")
    world.hub.schedule.stop()
    world.now = NOW + 600 + 8 * 60  # the dashboard comes back eight minutes after the call's time
    hub = world.boot()

    async def scenario():
        async with serving(core) as port:
            await asyncio.to_thread(hub.schedule.tick)
            await asyncio.to_thread(world.pusher.pushed.wait, 5)
            payload = world.pusher.payloads[-1]
            phone = await Phone.dial(port, fake, call_id=payload["call_id"], initiated_by="push", session_id="s1")
            await phone.send({"type": "answered"})
            await phone.expect("speech_end")
            await world.injector.wait_for(1)
            await phone.hang_up()

    asyncio.run(scenario())
    started = world.notices()[0]
    assert f"the call you scheduled for {scheduled['rings_at']}" in started
    assert ("It rang about 8 min late: Hermes was not running (or the host was asleep) at the scheduled time. Say so "
            "if it matters.") in started
    assert world.log("ring")[0]["late_s"] == 480


def test_a_call_the_host_missed_by_too_much_is_dropped_with_a_notice(world):
    scheduled = world.later(text="Time to get up.")
    world.hub.schedule.stop()
    world.now = NOW + 600 + 16 * 60 + 1
    hub = world.boot()
    assert hub.schedule.tick() == 1
    assert world.pusher.payloads == [] and hub.slot is None and hub.schedule.count() == 0
    notice, = world.wait_notices(1)
    assert notice.startswith(f"[Voice call not placed: scheduled for {scheduled['rings_at']}] Automated notice from "
                             "HermesVoice, not something the user said.")
    assert (f"The call you scheduled for {scheduled['rings_at']} (scheduled_id {scheduled['scheduled_id']}) was not "
            "placed: Hermes was not running (or the host was asleep) at that time and was back about 16 min late, "
            "more than the 15 min a late call may still ring after.") in notice
    assert 'its line was: "Time to get up.". Tell the user in text what happened' in notice
    dropped, = world.log("scheduled_dropped")
    assert dropped["reason"] == "late" and dropped["late_s"] == 961 and "text" not in dropped


def test_a_repeat_the_host_missed_says_that_it_rang_before(world):
    scheduled = world.later()
    world.now = NOW + 600
    world.schedule.tick()
    world.hub.finish(world.hub.slot, "no_answer")  # rings again in five minutes
    world.hub.schedule.stop()
    world.now = NOW + 900 + 3600  # ... but the host was asleep for an hour by then
    hub = world.boot()
    assert hub.schedule.tick() == 1 and world.pusher.payloads[1:] == []
    notice, = world.wait_notices(1)
    clock = world.core.schedule.clock_text(NOW + 600)
    assert (f"The call you scheduled for {scheduled['rings_at']} (scheduled_id {scheduled['scheduled_id']}) rang at "
            f"{clock} without an answer, and its repeat was not placed: Hermes was not running") in notice


def test_a_ring_the_dashboard_died_during_is_due_again_when_it_is_back(world):
    world.later()
    world.now = NOW + 600
    world.schedule.tick()
    assert world.file()["calls"][0]["call_id"]
    world.hub.schedule.stop()
    world.pusher = FakePusher()
    world.now += 20
    hub = world.boot()  # a new process: it knows nothing of that ring
    assert hub.schedule.tick() == 0  # still marked as ringing
    hub.schedule.recover()  # what taking over the schedule does first
    assert world.file()["calls"][0]["call_id"] == ""
    assert hub.schedule.tick() == 1 and world.pusher.pushed.wait(5)
    assert hub.slot.scheduled.attempt == 2


# ── cancelling and listing ─────────────────────────────────────────────────────────────────────────────────


def test_scheduled_calls_lists_cancels_one_or_all(world):
    core = world.core
    first, second, third = (world.later(in_minutes=minutes) for minutes in (10, 20, 30))
    other = world.later(session_id="s2")
    world.fake.host.add("s3")

    async def scenario():
        async def calls(args=None, session_id="s1"):
            return await tool(core.tools.scheduled_calls, args, session_id)

        return [
            await calls(),  # no argument: only list
            await calls({"cancel": None}),
            await calls({"cancel": ""}),
            await calls({"cancel": other["scheduled_id"]}),  # another conversation's call
            await calls({"cancel": "sc-nope"}),
            await calls({"cancel": f" {second['scheduled_id'].upper()} "}),
            await calls({"cancel": "all"}),
            await calls({"cancel": "all"}),
            await calls({}, session_id="s3"),  # a conversation with nothing scheduled
            await calls({"cancel": "all"}, session_id="s3"),
            await calls({"cancel": "sc-1234abcd"}, session_id="s3"),
        ]

    listed, null, empty, foreign, unknown, one, rest, again, nothing, nothing_all, nothing_one = asyncio.run(scenario())
    schedule = world.schedule
    assert list(listed) == ["pending", "cancelled", "note"]
    assert [entry["scheduled_id"] for entry in listed["pending"]] == [
        first["scheduled_id"], second["scheduled_id"], third["scheduled_id"]]
    assert listed["cancelled"] == [] and listed["note"] == ("3 calls scheduled in this conversation. Nothing was "
                                                            "changed.")
    assert null == listed and empty == listed
    assert foreign["cancelled"] == [] and len(foreign["pending"]) == 3
    assert unknown["cancelled"] == [] and len(unknown["pending"]) == 3
    assert unknown["note"] == ("This conversation has no scheduled call 'sc-nope'; nothing was cancelled. 3 calls "
                               "scheduled here (see pending).")
    assert one["cancelled"] == [second["scheduled_id"]]
    assert one["note"] == "Cancelled 1 call; nothing was hung up. 2 calls still scheduled in this conversation."
    assert [entry["scheduled_id"] for entry in one["pending"]] == [first["scheduled_id"], third["scheduled_id"]]
    assert sorted(rest["cancelled"]) == sorted([first["scheduled_id"], third["scheduled_id"]])
    assert rest["pending"] == [] and rest["note"] == ("Cancelled 2 calls; nothing was hung up. Nothing else is "
                                                      "scheduled in this conversation.")
    assert again == {"pending": [], "cancelled": [], "note": "This conversation has no calls scheduled."}
    assert nothing == {"pending": [], "cancelled": [],
                       "note": "No calls scheduled in this conversation. Nothing was changed."}
    assert nothing_all == again
    assert nothing_one["cancelled"] == [] and "no scheduled call 'sc-1234abcd'" in nothing_one["note"]
    assert "No calls scheduled here" in nothing_one["note"]
    assert schedule.count() == 1  # the other conversation's call stays
    world.now = NOW + 600
    assert schedule.tick() == 1 and world.hub.slot.owner.session_id == "s2"
    assert sorted(entry["scheduled"] for entry in world.log("scheduled_cancelled")) == sorted(
        [first["scheduled_id"], second["scheduled_id"], third["scheduled_id"]])


def test_cancelling_hangs_nothing_up_and_end_call_cancels_nothing(world):
    core, hub = world.core, world.hub
    scheduled = world.later()
    kept = world.later(in_minutes=20)
    call = hub.begin_call(world.origin(), "Hello.").call  # the conversation is ringing the phone meanwhile

    async def scenario():
        cancelled = await tool(core.tools.scheduled_calls, {"cancel": scheduled["scheduled_id"]})
        ringing = hub.slot is call and call.state == "ringing"
        # An end_call that still carries the old argument just hangs up: it is no way to cancel any more.
        hung_up = await tool(core.tools.end_call, {"scheduled_id": "all"})
        return cancelled, ringing, hung_up

    cancelled, ringing, hung_up = asyncio.run(scenario())
    assert cancelled["cancelled"] == [scheduled["scheduled_id"]] and ringing  # the call went on
    assert [entry["scheduled_id"] for entry in cancelled["pending"]] == [kept["scheduled_id"]]
    assert hung_up["outcome"] == "ended_by_agent" and hub.slot is None
    assert world.schedule.count() == 1  # the other scheduled call is untouched
    world.now = NOW + 600
    assert world.schedule.tick() == 0


def test_the_skill_says_how_to_list_and_cancel_and_that_a_missed_call_is_always_told(core):
    skill = " ".join((PLUGIN_DIR / "skills" / "voice-calls" / "SKILL.md").read_text(encoding="utf-8").split())
    later = skill[skill.index("## Calling later"):skill.index("## When a call ends")]
    for said in ("`scheduled_calls` lists this conversation's scheduled calls (`pending`)",
                 '`cancel: "all"` cancels them all', "never rings or hangs up (`end_call` only hangs up)",
                 "write one that still makes sense then", "This is your wake-up call",
                 "check anything time-dependent", "A scheduled call never fails silently",
                 "reply in text, and schedule again only if the user asks",
                 'say `rings_at` the way people say times ("tomorrow at seven")'):
        assert said in later, said
    assert "with `scheduled_id` cancels" not in skill and '"list"' not in later


def test_a_call_cancelled_while_it_rings_is_not_repeated(world):
    scheduled = world.later()
    world.now = NOW + 600
    world.schedule.tick()
    call = world.hub.slot
    cancelled = world.schedule.calls(world.origin(), "all")
    assert cancelled["cancelled"] == [scheduled["scheduled_id"]]
    assert "One of them is ringing right now: end_call hangs up." in cancelled["note"]
    world.hub.finish(call, "no_answer")
    assert world.schedule.count() == 0 and world.log("scheduled_retry") == []
    notice, = world.wait_notices(1)
    assert notice.startswith("[Voice call not answered]") and "scheduled" not in notice


def test_scheduled_calls_follow_the_conversation_through_compression(world):
    scheduled = world.later()
    world.fake.host.rotate("rt-s1", "s1-compressed")
    world.hub.note_turn_start("s1-compressed", parent_session_id="s1", user_message="go on")
    entry = world.file()["calls"][0]
    assert entry["session_id"] == "s1-compressed" and entry["session_ids"] == ["s1", "s1-compressed"]
    assert world.schedule.pending(world.origin("s1-compressed")) == scheduled["pending"]
    assert world.schedule.calls(world.origin("s1-compressed"), "all")["cancelled"] == [scheduled["scheduled_id"]]


# ── other processes: the hub socket ────────────────────────────────────────────────────────────────────────


@pytest.fixture
def remote(core, world, monkeypatch):
    mods = types.SimpleNamespace(remote=core.loader.module("remote", PLUGIN_DIR),
                                 hubsock=core.loader.module("hubsock", PLUGIN_DIR))
    monkeypatch.setattr(mods.remote, "_contexts", [])
    server = mods.hubsock.HubServer(world.hub, world.folder).start()
    yield mods.remote
    server.close()


def test_a_conversation_in_another_process_schedules_and_cancels_through_the_socket(world, remote):
    fake = world.fake
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    fake.env["HERMES_SESSION_KEY"] = "cli-7"
    scheduled = remote.schedule_call("cli-7", "The build is done.", 10, None)
    assert scheduled["status"] == "scheduled" and scheduled["rings_at"]
    entry = world.file()["calls"][0]
    assert entry["session_id"] == "cli-7" and entry["source"] == "cli" and entry["session_key"] == "cli-7"
    assert remote.status()["scheduled"] == 1
    assert remote.schedule_call("cli-7", "x", None, "yesterday")["error"].startswith("Can't read the time")
    assert remote.scheduled_calls("cli-7") == {"pending": scheduled["pending"], "cancelled": [],
                                               "note": "1 call scheduled in this conversation. Nothing was changed."}
    fake.env["HERMES_SESSION_KEY"] = "cli-8"  # another conversation: nothing of this one is its to see or cancel
    assert remote.scheduled_calls("cli-8")["pending"] == []
    assert remote.scheduled_calls("cli-8", "all")["note"] == "This conversation has no calls scheduled."
    fake.env["HERMES_SESSION_KEY"] = "cli-7"
    assert remote.scheduled_calls("cli-7", "sc-nope")["cancelled"] == [] and world.schedule.count() == 1
    # The ring belongs to that conversation; with its process gone, the dashboard reopens the stored session.
    world.now = NOW + 600
    assert world.schedule.tick() == 1 and world.pusher.pushed.wait(5)
    call = world.hub.slot
    assert call.owner.session_id == "cli-7" and call.owner.source == "cli" and not call.owner.remote
    world.hub.finish(call, "declined")
    assert world.wait_notices(1, "cli-7")[0].startswith("[Voice call not answered]")
    again = remote.schedule_call("cli-7", "Later.", None, "07:00")
    assert remote.scheduled_calls("cli-7", again["scheduled_id"])["cancelled"] == [again["scheduled_id"]]
    assert world.schedule.count() == 0


def test_scheduling_from_a_cron_job_or_another_profile_is_refused_through_the_socket(world, remote):
    fake = world.fake
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    fake.env["HERMES_CRON_SESSION"] = "1"
    cron = remote.schedule_call("cron-1", "Wake up.", None, "07:00")
    assert cron["status"] == "not_allowed" and "start_call with at or in_minutes" in cron["note"]
    del fake.env["HERMES_CRON_SESSION"]
    with remote.Client.connect() as client:  # a process of another profile, which found this dashboard's hub
        origin = {**remote.payload(remote.origin_for("w-1")), "profile": "work"}
        foreign = client.request("schedule", {"origin": origin, "text": "Wake up.", "in_minutes": 5})
        assert foreign["status"] == "not_allowed" and "'work' profile" in foreign["note"]
        with pytest.raises(remote.RemoteError, match="text is required"):
            client.request("schedule", {"origin": origin, "in_minutes": 5})
    assert world.schedule.count() == 0


def test_a_messaging_chat_is_told_its_replies_cant_reach_it_and_is_never_reopened(world, remote):
    fake = world.fake
    fake.env.clear()
    fake.env.update({"HERMES_SESSION_PLATFORM": "telegram", "HERMES_SESSION_CHAT_TYPE": "dm",
                     "HERMES_SESSION_USER_ID": "42", "HERMES_SESSION_KEY": "agent:main:telegram:dm:42"})
    fake.secrets["GATEWAY_ALLOWED_USERS"] = "42"
    scheduled = remote.schedule_call("tg-1", "Wake up.", 10, None)
    assert scheduled["status"] == "scheduled"
    assert "what the user says on that call can't be put into it" in scheduled["note"]
    world.now = NOW + 600
    assert world.schedule.tick() == 1 and world.pusher.pushed.wait(5)
    call = world.hub.slot
    assert call.owner.source == "telegram" and call.owner.remote and call.route is None
    world.hub.finish(call, "declined")
    deadline = time.monotonic() + 5
    while not world.log("undelivered") and time.monotonic() < deadline:
        time.sleep(0.01)
    assert world.log("undelivered")[0]["what"] == "notice" and world.notices("tg-1") == []


def test_without_a_dashboard_or_with_an_older_one_scheduling_says_so(core, fake, make_hub, monkeypatch):
    remote = core.loader.module("remote", PLUGIN_DIR)
    fake.env["HERMES_SESSION_SOURCE"] = "cli"
    missing = remote.schedule_call("cli-7", "Hi", 10, None)
    assert missing["status"] == "not_available" and "hermes serve" in missing["note"]

    class Old:
        def __enter__(self):
            return self

        def __exit__(self, *_):
            return None

        def request(self, op, params=None, **_):
            raise remote.RemoteError("unknown_op", f"unknown op {op!r}")

    monkeypatch.setattr(remote.Client, "connect", classmethod(lambda cls, folders=None: Old()))
    old = remote.schedule_call("cli-7", "Hi", 10, None)
    assert "older hermes_voice that can't schedule calls" in old["error"] and "Nothing was scheduled" in old["error"]


def test_the_tools_schedule_through_the_socket_outside_the_dashboard(core, world, remote, monkeypatch):
    world.fake.env["HERMES_SESSION_SOURCE"] = "tui"
    monkeypatch.setattr(core.hub, "routes_mounted", lambda: False)

    async def scenario():
        scheduled = await tool(core.tools.start_call, {"text": "Stand-up in five.", "in_minutes": 5}, "tui-1")
        listed = await tool(core.tools.scheduled_calls, {}, "tui-1")
        cancelled = await tool(core.tools.scheduled_calls, {"cancel": "all"}, "tui-1")
        return scheduled, listed, cancelled

    scheduled, listed, cancelled = asyncio.run(scenario())
    assert scheduled["status"] == "scheduled" and listed["pending"] == scheduled["pending"]
    assert cancelled["cancelled"] == [scheduled["scheduled_id"]] and cancelled["pending"] == []
    assert [entry["event"] for entry in world.log("scheduled", "scheduled_cancelled")] == ["scheduled",
                                                                                           "scheduled_cancelled"]


# ── status ─────────────────────────────────────────────────────────────────────────────────────────────────


def test_status_counts_scheduled_calls_without_their_text(world):
    core = world.core
    world.later(text="A private line.")
    world.later(session_id="s2")

    async def scenario():
        import httpx

        async with serving(core) as port:
            async with httpx.AsyncClient() as client:
                return (await client.get(f"http://127.0.0.1:{port}/api/plugins/hermes_voice/status")).json()

    status = asyncio.run(scenario())
    assert status["scheduled"] == 2 and "A private line." not in json.dumps(status)
