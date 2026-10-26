# hermes_voice

A Hermes plugin that lets Hermes **call you** on the HermesVoice iPhone app and talk with you out loud. It replaces
`hermes-voice-mcp`: the phone's socket is served by the Hermes dashboard itself, behind the dashboard's own auth.

- **Tools** (toolset `voice`): `start_call(text, mode="async")` rings the phone (VoIP push straight to APNs) and
  says `text` once you answer, or just speaks if this conversation already has a call. `mode="sync"` waits for your
  spoken reply and returns `{said, ending, outcome, call_id}`; `async` returns `{call_id, status}` at once and your
  reply arrives in the conversation as a `[Voice] …` message. `end_call(text?)` hangs up.
- **Skill** `voice-calls`: the longer rules (`skill_view("hermes_voice:voice-calls")`).
- **Hooks**: `pre_llm_call` / `on_session_end` track which conversations are busy, and keep a call with its
  conversation when compression rotates the session id; `post_llm_call` / `on_session_end` also tell the alert
  pushes when a turn ended, and with what reply.
- **Alert pushes** (ordinary APNs notifications, not VoIP): an approval or a question waiting, or a turn done, in a
  dashboard conversation no client has open (see "Alert pushes").
- **Hub socket** `<HERMES_HOME>/hermes-voice/hub.sock`: how conversations in other Hermes processes (CLI, Ink TUI,
  the messaging gateway, cron, compute-host children) place and hear calls (see "Calls from any session").
- **Routes** under `/api/plugins/hermes_voice/`: `WS /phone?ticket=…`, `POST /devices`, `POST /scribe-token`,
  `GET /status`.

`POST /devices {voip_token, alert_token?, environment: "sandbox" | "production", bundle_id, alerts?}` registers a
phone: VoIP pushes go to `voip_token` (topic `<bundle_id>.voip`), alert pushes to `alert_token` (topic
`<bundle_id>`). `alerts: {"approval": bool, "clarify": bool, "turn_done": bool}` turns kinds off or back on for
that phone (a kind it never names stays on); a registration without `alert_token` keeps the stored one, and
`"alert_token": null` clears it. The answer is `{"ok": true}`.

One call at a time per host (the dashboard holds it for every process). A call belongs to one conversation; another
conversation that tries to speak gets `busy`. Speech is ElevenLabs streaming PCM made on the host; recognition happens on the phone (Apple
on-device, or ElevenLabs Scribe with a single-use token this plugin mints, so the API key stays on the host).

## Install

```bash
hermes plugins install Al-ex-W/hermes-ios/hermes-voice-plugin   # asks for the secrets below
hermes plugins enable hermes_voice      # prepares its Python dependency, h2 (APNs needs HTTP/2)
```

`hermes plugins install` clones Git sources only; a bare path is read as GitHub `owner/repo` shorthand. From a local
clone of this repo, run `hermes plugins install "file://$PWD#hermes-voice-plugin"` in its root (it installs the
checked-out branch as committed; `--ref <commit-sha>` pins a commit).

Restart the dashboard afterwards: plugin routes are mounted at startup. The tools show in every session; they work
wherever `hermes serve` runs on the same host (see "Calls from any session"), and otherwise `start_call` answers
`not_available`. With Hermes' Tool Search on
(`tools.tool_search.enabled`, the default), plugin tools are deferred: the model finds `start_call` in the
`tool_search` catalog listing and calls it through `tool_call`.

A delegated subagent can't ring the user unless `policy.allow_subagents` is on, and its calls belong to the top-level
conversation. (Hermes binds the agent running each turn as "the subagent parent", main agents included; the plugin
counts only an agent with a delegate depth as a subagent.)

Secrets, read with Hermes' `get_secret` (profile `.env` or the secret scope):

| Variable | What |
|---|---|
| `ELEVENLABS_API_KEY` | Hermes' voice on calls, and Scribe tokens for the phone |
| `HERMES_VOICE_APNS_KEY_PATH` | Path to the APNs auth key (`.p8`) on the host |
| `HERMES_VOICE_APNS_KEY_ID` | Its 10-character Key ID |
| `HERMES_VOICE_APNS_TEAM_ID` | Your Apple Developer Team ID |
| `HERMES_VOICE_FAKE_TTS=1` | Optional: test tones instead of ElevenLabs |

Settings live in `config.yaml` under `plugins.entries.hermes_voice.settings` (all optional):

```yaml
plugins:
  entries:
    hermes_voice:
      settings:
        voice_id: pNInz6obpgDQGcFmaJgB     # default: tts.elevenlabs.voice_id
        max_chars: 1000
        ring_timeout_s: 45
        sync_reply_timeout_s: 600
        policy:
          allowed_sources: [desktop, dashboard, tui, cli, local]   # local: a CLI / TUI session the gateway runs
          allow_owner_dms: true
          owner_ids: []                    # e.g. ["telegram:123456"]; empty: the gateway's allowlist / pairing
          allow_cron: false
          allow_subagents: false
          allow_groups: false
          rings_per_session: 3             # per session_window_s (600)
          rings_global: 10                 # per global_window_s (3600)
          quiet_hours: {start: "22:00", end: "07:00", action: refuse}   # or action: confirm
        alerts:
          enabled: true
          approval: true                   # each kind can be turned off for every phone here
          clarify: true
          turn_done: true
          grace_s: 5                       # how long nothing has the conversation open before an alert
          previews: true                   # false: no conversation text (or title) goes through APNs
      allow_gateway_injection: true        # not under settings: Hermes' own switch (see "Calls from any session")
```

Every ring, refusal and call outcome is logged to `<HERMES_HOME>/hermes-voice/rings.jsonl`; registered phones are
kept in `<HERMES_HOME>/hermes-voice/devices.json`.

**The owner's direct messages.** A DM may ring the phone when it comes from the owner: whoever `owner_ids` names
(a user id, or `"<platform>:<user id>"`), or, with no `owner_ids`, whoever the gateway was told to serve by name: its
platform allowlist (`TELEGRAM_ALLOWED_USERS` …) or `GATEWAY_ALLOWED_USERS`, or a pairing the owner approved. An
allow-all switch, a `*` wildcard, a group-only allowlist or a Discord role grant makes nobody the owner. Group
chats, scheduled jobs and subagents stay off unless their `allow_*` setting is on. The rate limits and quiet hours
count every ring on the host, whichever process it came from.

## Calls from any session

The phone's socket and the call slot live in the dashboard process (`hermes serve`). Once it serves, the plugin
opens a local socket next to its files, `<HERMES_HOME>/hermes-voice/hub.sock` (0600, folder 0700), with
`hub.token` beside it (0600, new on every start; a client sends it first). Tools in other processes (the CLI, the
Ink TUI, the messaging gateway, cron jobs, compute-host children under `dashboard.turn_isolation`) ring, speak and
end calls through it (`hubsock.py` has the protocol), and take the call's turns over it:

- **Mid-turn**, a turn goes to the agent itself: `redirect()` (a model request is retried with it; during tools it
  becomes a steer), else `steer()` (read after the current tool batch). A steer the turn ends without reading
  starts a new turn instead.
- **Idle**, it starts a turn with `ctx.inject_message` and the conversation's route key. Hermes allows that in a
  gateway session (messaging, or a local CLI / TUI session the gateway runs) only with

  ```yaml
  plugins:
    entries:
      hermes_voice:
        allow_gateway_injection: true
  ```

  Without it an async `start_call` from such a session is refused (`not_available`, the note says how to fix it);
  a sync one still returns the reply. The classic CLI REPL needs nothing; a compute-host child's idle turns are
  started by the dashboard, which holds the session.
- A sync wait runs in Hermes' human-wait window of the tool's own process. From a messaging chat it is capped at
  `approvals.timeout` + 60 s (Hermes' bound on one human wait inside a tool call); the result says so when it hits.

A call whose process goes away (and doesn't come back within 30 s) is hung up. A messaging gateway that serves the
dashboard app behind its own listener doesn't count as the dashboard: the phone connects to `hermes serve`.

## Alert pushes

The phone also hears, as an ordinary notification, about what needs it in a conversation the dashboard hosts while
nothing has that conversation open (no app, Desktop window or dashboard chat attached to it):

- **An approval or a question waiting.** A watcher in the dashboard process looks at every live conversation's open
  server requests (those of turns under `dashboard.turn_isolation` too). A request alerts once, after it waited
  `grace_s` with no client attached; a client that attaches restarts the wait.
- **A turn done**, when no client had the conversation open as the turn ended nor `grace_s` later, it didn't go on
  with another turn, and it isn't on a call with the phone. An interrupted turn, and a `[SILENT]` reply, say
  nothing; a failed turn says it failed. A turn run in a compute-host child says only "Hermes finished.".

Messaging and CLI conversations don't alert: they ask on their own surface, and the phone answers through the
dashboard. Each alert goes to every registered phone with an alert token that didn't turn the kind off; the host
turns kinds off for all phones under `settings.alerts`. Pushes are `apns-push-type: alert` to the app's own topic
(the bundle id), priority 10, kept by APNs for 15 minutes (an approval or question) or an hour (a turn done), with
a collapse id, at most 4 KB:

```json
{"aps": {"alert": {"title": "<conversation title or Hermes>", "body": "<short text>"},
         "category": "HERMES_APPROVAL | HERMES_CLARIFY | HERMES_TURN_DONE",
         "thread-id": "<stored session id>", "sound": "default"},
 "hermes": {"kind": "approval | clarify | turn_done", "session_id": "<stored session id>", "profile": "default",
            "request_id": "srq-…", "choices": ["once", "session", "always", "deny"],
            "questions": [{"qid": "…", "question": "…", "choices": ["…"], "multi_select": false}]}}
```

`request_id` comes with approvals and questions, `choices` (the subset the request offers) with approvals,
`questions` with questions: empty when they don't fit in 4 KB or previews are off, and the app then opens the
conversation to answer. The body of an approval is what needs approving (never the command); with
`previews: false` the title is "Hermes" and the body a generic line. The app answers with the gateway's `request.answer {id: request_id, result}` (`{choice}` for an
approval, `{answers: {qid: answer}}` for a question), from any socket. An APNs `410` or bad-token answer forgets
only the alert token: the phone still rings. Alerts aren't retried. The log names the kind, how many phones and
APNs' reason, never a token or the payload.

## Phone protocol

JSON text frames on `/phone` plus binary PCM (16-bit little-endian mono, 24 kHz):

| Direction | Messages |
|---|---|
| phone → plugin | `hello {call_id, session_id?, title?, initiated_by: user\|push, app_version}`, `ringing`, `answered`, `declined`, `played {id}`, `user_turn {call_id, text, ending {kind, detector?, detail?, error?}, provider, language?, started_at, ended_at}`, `ping`, `bye {reason?}` |
| plugin → phone | `ready {call_id, state: ringing\|live}`, `cancel {reason}`, `speech_start {id, text, sample_rate, format}` + PCM + `speech_end {id}` (or with `cancelled: true` / `error`), `pong`, `ended {outcome}` |

Close codes: 4401 auth (a bad or reused ticket, or a Host / Origin the dashboard refuses), 4400 bad hello, 4409
replaced by a newer link, 4429 another conversation holds the call, 1011 the link stopped taking frames. The
plugin accepts the socket before refusing it, so the phone sees the code. VoIP push payload:
`{call_id, session_id, profile, mode, title}`; the app turns the 32-hex `call_id` into the CallKit UUID.

- A push call is `ready {state: "ringing"}` until the phone says `answered`; nothing is spoken before that.
- `bye {reason}`: `hang_up` and `declined` end the call as `ended_by_user` / `declined`; `no_answer` (the phone's
  own ring timeout ran out) as `no_answer`; `error` (the phone gave up on the call) as `lost`.
- A hello for a call that is over gets `cancel {reason}` (never answered) or `ended {outcome}`, then close 1000; a
  push hello for a call the plugin doesn't know gets `cancel {reason: "unknown_call"}`.
- `GET /status` → `{calls, tts: "elevenlabs" | "fake", h2, apns_configured, scribe_configured, active_call, alerts}`,
  where `active_call` is `{call_id, session_id, title, state, initiated_by: "push" | "user"}` or null (the app's
  call button joins a call Hermes holds for the same chat) and `alerts` is `{enabled, kinds, watching, devices,
  sent}`. HTTP errors are `{detail}`.
- The VoIP push's `session_id` can be a conversation of another process (`local-…` for a CLI one the gateway runs,
  a messaging chat's), which the dashboard may not be able to open: the call works the same.

## Development

```bash
cd hermes-voice-plugin
uv run pytest -q
```

The tests stub every Hermes module the plugin imports, run the plugin's router on a real server (an OS-assigned
port) and drive it with a fake phone over a real WebSocket, plus a mock APNs and a mock ElevenLabs.

`tests/integration/` runs the plugin inside a real `hermes serve --isolated` (opt-in, about three minutes):

```bash
HERMES_VOICE_INTEGRATION=1 uv run pytest -q tests/integration
```

- `test_real_hermes.py`: dashboard conversations driven over `/api/ws` call the phone (sync, async, redirect while
  a turn runs, declined, rung out, `busy`, unreachable, the socket's auth).
- `test_calls_any_session.py`: `hermes chat -Q -q` in the same home (its turn runs in the gateway Hermes starts) calls
  through `hub.sock`: a sync call returns the reply to that process; an async one's reply becomes a stored user
  turn of the gateway session, answered into the same call.
- `test_alerts_real_hermes.py`, with turns in the dashboard and under `turn_isolation`: approval and question
  alerts once the client leaves, answered with `request.answer` from the alert's ids; and through the real APNs
  sender against a mock APNs, one approval alert per phone that takes them (ES256 provider token, headers, topic,
  payload), none for a phone that turned approvals off.

It starts Hermes with its own interpreter (`HERMES_PYTHON`, else the environment Hermes' package manager committed
for the checkout at `HERMES_AGENT_DIR`, default `~/.hermes/hermes-agent`) in a temp `HOME` and `HERMES_HOME`, with
basic auth, `dashboard.public_url`, the plugin linked into the temp home's `plugins/` and enabled, fake TTS, and a
stub OpenAI-compatible model on a free port. `HERMES_DISABLE_LAZY_INSTALLS=1` keeps Hermes from installing anything
(it also skips the launcher's source-update dependency sync), bytecode writing is off, and the host rendezvous and
XDG dirs are temp dirs too. A small helper plugin written into the temp home records the pushes instead of sending
them, or points the real sender at the mock APNs. A failed run keeps the temp folder (`hermes.log`, `hermes/logs/`);
`HERMES_VOICE_IT_TMP` picks where it goes, and `HERMES_VOICE_IT_PORTS=<low>-<high>` the ports the test servers take.
