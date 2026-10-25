# hermes_voice

A Hermes plugin that lets Hermes **call you** on the HermesVoice iPhone app and talk with you out loud. It replaces
`hermes-voice-mcp`: the phone's socket is served by the Hermes dashboard itself, behind the dashboard's own auth.

- **Tools** (toolset `voice`): `start_call(text, mode="async")` rings the phone (VoIP push straight to APNs) and
  says `text` once you answer, or just speaks if this conversation already has a call. `mode="sync"` waits for your
  spoken reply and returns `{said, ending, outcome, call_id}`; `async` returns `{call_id, status}` at once and your
  reply arrives in the conversation as a `[Voice] …` message. `end_call(text?)` hangs up.
- **Skill** `voice-calls`: the longer rules (`skill_view("hermes_voice:voice-calls")`).
- **Hooks**: `pre_llm_call` / `on_session_end` track which conversations are busy, and keep a call with its
  conversation when compression rotates the session id.
- **Routes** under `/api/plugins/hermes_voice/`: `WS /phone?ticket=…`, `POST /devices`, `POST /scribe-token`,
  `GET /status`.

One call at a time per Hermes process. A call belongs to one conversation; another conversation that tries to
speak gets `busy`. Speech is ElevenLabs streaming PCM made on the host; recognition happens on the phone (Apple
on-device, or ElevenLabs Scribe with a single-use token this plugin mints, so the API key stays on the host).

## Install

```bash
hermes plugins install Al-ex-W/hermes-ios/hermes-voice-plugin   # asks for the secrets below
hermes plugins enable hermes_voice      # prepares its Python dependency, h2 (APNs needs HTTP/2)
```

`hermes plugins install` clones Git sources only; a bare path is read as GitHub `owner/repo` shorthand. From a local
clone of this repo, run `hermes plugins install "file://$PWD#hermes-voice-plugin"` in its root (it installs the
checked-out branch as committed; `--ref <commit-sha>` pins a commit).

Restart the dashboard afterwards: plugin routes are mounted at startup. The tools only show in the dashboard
process (where the phone's socket is), and not with `dashboard.turn_isolation` on. With Hermes' Tool Search on
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
          allowed_sources: [desktop, dashboard, tui]
          allow_owner_dms: true
          owner_ids: []                    # your user id on a messaging platform, for DMs
          allow_cron: false
          allow_subagents: false
          allow_groups: false
          rings_per_session: 3             # per session_window_s (600)
          rings_global: 10                 # per global_window_s (3600)
          quiet_hours: {start: "22:00", end: "07:00", action: refuse}   # or action: confirm
```

Every ring, refusal and call outcome is logged to `<HERMES_HOME>/hermes-voice/rings.jsonl`; registered phones are
kept in `<HERMES_HOME>/hermes-voice/devices.json`.

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
- `GET /status` → `{calls, tts: "elevenlabs" | "fake", h2, apns_configured, scribe_configured, active_call}`, where
  `active_call` is `{call_id, session_id, title, state, initiated_by: "push" | "user"}` or null: the app's call
  button joins a call Hermes holds for the same chat. HTTP errors are `{detail}`.

## Development

```bash
cd hermes-voice-plugin
uv run pytest -q
```

The tests stub every Hermes module the plugin imports, run the plugin's router on a real server (an OS-assigned
port) and drive it with a fake phone over a real WebSocket, plus a mock APNs and a mock ElevenLabs.

`tests/integration/` runs the plugin inside a real `hermes serve --isolated` (opt-in, about 30 s):

```bash
HERMES_VOICE_INTEGRATION=1 uv run pytest -q tests/integration
```

It starts Hermes with its own interpreter (`HERMES_PYTHON`, else the environment Hermes' package manager committed
for the checkout at `HERMES_AGENT_DIR`, default `~/.hermes/hermes-agent`) in a temp `HOME` and `HERMES_HOME`, with
basic auth, `dashboard.public_url`, the plugin linked into the temp home's `plugins/` and enabled, fake TTS, and a
stub OpenAI-compatible model on a free port. `HERMES_DISABLE_LAZY_INSTALLS=1` keeps Hermes from installing anything
(it also skips the launcher's source-update dependency sync), bytecode writing is off, and the host rendezvous and
XDG dirs are temp dirs too. A small helper plugin written into the temp home records the VoIP pushes instead of
sending them. A failed run keeps the temp folder (`hermes.log`, `hermes/logs/`); `HERMES_VOICE_IT_TMP` picks where it
goes.
