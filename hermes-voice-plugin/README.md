# hermes_voice

A Hermes plugin that lets Hermes **call you** on the HermesVoice iPhone app and talk with you out loud. It replaces
`hermes-voice-mcp`: the phone's socket is served by the Hermes dashboard itself, behind the dashboard's own auth.

- **Tools** (toolset `voice`): `start_call(text, mode="async")` rings the phone (VoIP push straight to APNs) and
  says `text` once you answer, or just speaks if this conversation already has a call. `mode="sync"` waits for your
  spoken reply and returns `{said, ending, outcome, call_id}`; `async` returns `{call_id, status}` at once and your
  reply arrives in the conversation as a `[Voice] …` message. `end_call(text?)` hangs up.
- **Skill** `voice-calls`: the longer rules (`skill_view("hermes_voice:voice-calls")`).
- **Call style** `<HERMES_HOME>/hermes-voice/call-style.md`: the user's own preferences for how Hermes speaks on
  calls, which the agent reads at every call and edits itself (see "Call style").
- **Hooks**: `pre_llm_call` / `on_session_end` track which conversations are busy, and keep a call with its
  conversation when compression rotates the session id; `post_llm_call` / `on_session_end` also tell the alert
  pushes when a turn ended, and with what reply, and `on_session_finalize` lets them read how a turn ended
  before the dashboard drops a conversation nobody has open.
- **Alert pushes** (ordinary APNs notifications, not VoIP): an approval or a question waiting, or a turn done, in a
  dashboard conversation no client has open (see "Alert pushes").
- **Hub socket** `<HERMES_HOME>/hermes-voice/hub.sock`: how conversations in other Hermes processes (CLI, Ink TUI,
  the messaging gateway, cron, compute-host children, backends the Hermes Desktop app spawns) place and hear
  calls (see "Calls from any session").
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
        max_chars: 1000                    # longest line spoken at once (a line over ~15 s of speech is flagged)
        call_style_path: hermes-voice/call-style.md   # the user's call style; relative: inside the Hermes home
        ring_timeout_s: 45
        sync_reply_timeout_s: 600
        policy:
          allowed_sources: [desktop, dashboard, tui, cli, local]   # local: a CLI / TUI session the gateway runs
                                           # add oneshot (`chat -q`, `-z`) or tool (`--source tool`) to let those ring
          allow_owner_dms: true
          owner_ids: []                    # e.g. ["telegram:123456"]; empty: the gateway's allowlist / pairing
          allowed_profiles: []             # other profiles whose processes may ring through this dashboard
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
          previews: true                   # false: no conversation text or title goes through APNs (alerts
                                           # and the call push alike)
      allow_gateway_injection: true        # not under settings: Hermes' own switch (see "Calls from any session")
```

Every ring, refusal and call outcome is logged to `<HERMES_HOME>/hermes-voice/rings.jsonl`, with what APNs accepted (`pushed`), what the phone did (`phone`: connected, ringing, answered, declined, turned away), calls the user started (`start`) and why a ring ran out (`detail` on `no_answer` / `unreachable`); registered phones are
kept in `<HERMES_HOME>/hermes-voice/devices.json`. The log also says what a call couldn't put into its chat, never
the text itself: `chat_held` (another Hermes process holds the chat; `holder` is the surface Hermes names,
`announced` whether the user was told on the call), `delivered_late` (it got in after `waited_s`) and
`undelivered` (given up, with the `reason`); `what` is `call_started`, `turn` or `notice`.

**The owner's direct messages.** A DM may ring the phone when it comes from the owner: whoever `owner_ids` names
(a user id, or `"<platform>:<user id>"`), or, with no `owner_ids`, whoever the gateway was told to serve by name: its
platform allowlist (`TELEGRAM_ALLOWED_USERS` …) or `GATEWAY_ALLOWED_USERS`, or a pairing the owner approved. An
allow-all switch, a `*` wildcard, a group-only allowlist or a Discord role grant makes nobody the owner. Group
chats, scheduled jobs and subagents stay off unless their `allow_*` setting is on. The rate limits and quiet hours
count every ring on the host, whichever process it came from.

**Other profiles.** A profile with no dashboard of its own finds the root profile's hub socket. Its processes ring
only when `allowed_profiles` lists the profile, and then their DMs count as the owner's only through `owner_ids`:
this dashboard can't vouch for another profile's allowlist or pairings.

**Runs nobody sits at.** `hermes chat -q` and `hermes -z` (source `oneshot`) and third-party integrations
(`hermes chat --source tool`, source `tool`) run as the CLI, but no one is there to talk to, and what they read
(mail, web pages) could talk the model into ringing. They don't ring unless `allowed_sources` lists them.

## What the conversation is told

The plugin puts two kinds of message into the conversation that owns a call (texts in `inject.py`):

| Message | What it is |
|---|---|
| `[Voice] <said> (…)`, `[Voice, cut off] …`, `[Voice, hung up] …`, `[Voice, muted] …`, `[Voice, line dropped] …` | A turn of the user's: their words, then one of the plugin's two hints in parentheses (`inject.REPLY_HINT`, `inject.HUNG_UP_HINT`). A `[Voice, speech recognition failed…]` turn may have no words. |
| `[Voice call started] …`, `[Voice call not answered] …`, `[Voice call ended by user] …`, `[Voice call ended: …] …`, `[Voice line not delivered: …] …` | An automated notice about one call. Nothing in it was said by the user. |

Every notice is worded as an event of one call, never as an instruction from the user or a standing preference
(a hang-up notice that said "reply in text from now on" was once stored by a memory system as the user's wish). A
notice about a call that is over tells the agent that the user can't hear it and is probably not reading the chat:
finish the task, reply once in text with a short recap, don't ring back unless they asked to be called, and speak
as usual on the next call. A sync `start_call` result says the same in its `note`.

**For memory plugins.** Hermes has no flag a plugin can set that memory providers see on every path a notice
takes. `sync_turn` gets the turn's text as `user_content` whatever started the turn. `display_kind`, Hermes' type
for user rows nobody typed, is set to `internal_notification` by the gateway on `ctx.inject_message` turns (a
provider sees it only in the `messages` list); a dashboard turn started with `prompt.submit` gets none (that
method accepts only `hidden`, which would also hide the notice in the chat), and text steered into a running turn
is typed `steer`, like the user's own steers. `turn_author` is stamped only by Hermes' bot relay. So the marker is
in the text, and it is stable:

- Every notice starts with `[Voice call ` or `[Voice line `, and carries the sentence
  `Automated notice from HermesVoice, not something the user said.` (`inject.NOTICE_MARKER`) right after its closing
  bracket. Skip the whole message: `message.startswith(("[Voice call ", "[Voice line "))`, or
  `inject.NOTICE_MARKER in message`.
- In a `[Voice…] <said> (…)` turn only `<said>` is the user's. Drop the bracket prefix and the trailing hint (one of
  the two strings above) before storing it.

**Long lines.** A `start_call` result flags a line that takes longer than about 15 seconds to say: `Long line:
about 22 s of speech. Keep lines to a sentence or two and offer details instead.` (async and sync, from any
process). The estimate is 15 characters a second (150 words a minute at six characters a word, about the pace of
ElevenLabs' voices) over the characters that are spoken, so audio tags in square brackets don't count
(`guidance.CHARS_PER_SECOND`, `guidance.LONG_LINE_S`). `max_chars` still cuts a line, and the result says so.

**What the user did not hear.** When a call ends by a hang-up or a lost connection while a line is still playing or
queued (no `played` ack from the phone), the ended notice, or the sync result's `note`, quotes those lines (the
first 200 characters of at most three). The hub remembers them for the conversation, in memory only (never on
disk, at most a day, gone with a restart), and reminds the agent once when the conversation's next call starts: in
the `[Voice call started]` notice, or in the first `start_call` result (kept for the call after that if nobody
answers).

## Call style

A namespaced plugin skill can't be patched with `skill_manage`, so what the user wants from calls (tone, form of
address, humour, ElevenLabs audio tags) has its own file: `<HERMES_HOME>/hermes-voice/call-style.md`, free text.
`settings.call_style_path` moves it (`~` is expanded; a relative path is inside the Hermes home). Write it
yourself, or tell Hermes on a call ("call me sir from now on"): the skill and the tool description tell the agent
to edit the file with its normal file tools when you state a lasting preference about how it speaks on calls.

```markdown
Address me as "sir". Dry, understated humour; never bubbly.
Calm and unhurried. No filler ("great question").
Audio tags are fine: [sighs], [chuckles]. No [whispers]: I take calls on the street.
```

The plugin gives the agent the file's current text (blank lines dropped; the first 1500 characters, with a note
when it was cut):

- in the `[Voice call started]` notice of a call you placed;
- as `call_style` in the first `start_call` result of a call: the line that rings, or the first one spoken into a
  call. It is read in the process and profile the conversation runs in, once per call;
- shortened to 400 characters, in the `start_call` tool description, read when the plugin loads, so the first
  line of a call Hermes starts already follows it. A restart refreshes that copy; results always carry the
  current text.

The file's content is never logged and never sent to the phone by the plugin; it does become part of the
conversation (a notice or a tool result), like anything else the agent reads. A missing or empty file adds nothing.

**Audio tags.** `text` goes to ElevenLabs as the agent wrote it, so square-bracket tags (`[laughs]`,
`[whispers]`) reach the model untouched; they are not counted as speech in the long-line estimate. They only do
something with a model that supports them: ElevenLabs documents them for Eleven v3 (`model_id: eleven_v3`), which
is slower to start speaking than the default `eleven_flash_v2_5`. Other models may read a tag out loud or drop it.
The phone gets the same text in `speech_start` (tags included).

## Calls from any session

The phone's socket and the call slot live in the dashboard process (`hermes serve`). Once it serves, the plugin
opens a local socket next to its files, `<HERMES_HOME>/hermes-voice/hub.sock` (0600, folder 0700), with
`hub.token` beside it (0600, new on every start; a client sends it first). Tools in other processes (the CLI, the
Ink TUI, the messaging gateway, cron jobs, compute-host children under `dashboard.turn_isolation`) ring, speak and
end calls through it (`hubsock.py` has the protocol), and take the call's turns over it:

- **Mid-turn**, a turn goes to the agent itself: `redirect()` (a model request is retried with it; during tools it
  becomes a steer), else `steer()` (read after the current tool batch). Whether a turn runs is read off the agent
  (a model request in flight, a tool batch, the turn lease held), since Hermes' `on_session_end` hook doesn't fire
  on every way out of a turn (a provider error, say). A steer the turn ends without reading starts a new turn
  instead.
- **Idle**, it starts a turn with `ctx.inject_message` and the conversation's route key. Hermes allows that in a
  gateway session (messaging, or a local CLI / TUI session the gateway runs) only with

  ```yaml
  plugins:
    entries:
      hermes_voice:
        allow_gateway_injection: true
  ```

  Without it an async `start_call` from such a session is refused (`not_available`, the note says how to fix it);
  a sync one still returns the reply. A classic CLI REPL that runs its own agent needs nothing; Hermes 0.23 has
  none (the CLI, one-shot runs and the Ink TUI are all clients of sessions its gateway runs), so there every CLI
  and TUI conversation needs the setting. Since Hermes 0.22.6 the gateway also drops such a conversation from
  memory once its window is closed (or the one-shot run is over) and then refuses a plugin's turn for it; the
  plugin then has Hermes restore it and tries again (`hermes.restore_retired_session`), so a call still reaches a
  conversation whose terminal you closed. A compute-host child never starts a turn itself: the dashboard, which
  holds the session, submits it (and sends it to the child), so the dashboard shows it running and queues what
  the user types meanwhile.
- A sync wait runs in Hermes' human-wait window of the tool's own process, and ends before Hermes would give up on
  the tool call: its tool deadline (`timeouts.tools.sequential_call`, 420 s by default) plus at most
  `approvals.timeout` + 60 s of human wait, less the time already spent (the same in the dashboard). The result
  says so when it hits; the reply then arrives as a `[Voice]` message.

A call whose process goes away (and doesn't come back within 30 s) is hung up. A messaging gateway that serves the
dashboard app behind its own listener doesn't count as the dashboard: the phone connects to `hermes serve`. While
another dashboard in the same home holds `hub.sock` (a second `hermes serve`, or one still shutting down), this one
keeps trying and takes it over once the other stops (`GET /status` says `hub_socket: "taken"` meanwhile).
Disabling the plugin closes the socket; enabling it again reopens it.

### A chat another Hermes process holds

Hermes keeps one writer per conversation: a process that ran a turn in a chat holds it (a lease in
`<HERMES_HOME>/runtime/active_sessions.json`) for as long as it has the chat open, and answers every other
process's `prompt.submit` for it with 4090 / `SESSION_NOT_OWNED` ("This chat is open in another Hermes
window/terminal"), before anything is written. A call the user starts from the phone belongs to a dashboard
session, so in a chat the Desktop app's backend (or an Ink TUI, or the classic CLI) holds, the dashboard can write
neither the `[Voice call started]` notice nor what the user says. Hermes has no hand-over for such a lease between
processes, so:

1. **The process that holds the chat puts it in.** Every process that hosts sessions of its own and isn't the
   dashboard (a Desktop backend, the Ink TUI) keeps a connection to the hub socket (`attend`). On a refusal the hub
   asks those processes which of them has the chat open and hands the text to that one, which injects it into its
   own live session (redirect, steer or a new turn, as the dashboard does for its own). Its agent answers with
   `start_call` through the hub socket, and from then on that process takes the call's turns itself.
2. **Otherwise the call keeps it and says so.** The delivery stays at the head of the call's queue and is tried
   again every 3 s for 2 minutes from when it was queued; later turns wait behind it, so they arrive in order and
   none twice. Each one that gets in late carries a note ("Delayed by … s: this chat was open in another Hermes
   window …", and how many earlier ones were given up). On the first refusal the hub itself says into the call,
   once per call: "I can't reach this chat right now: it's open in another Hermes window. Close it there, or call
   from another chat." The ring log gets `chat_held`, then `delivered_late` or `undelivered`.

The same holds for the notices of a call Hermes started (`[Voice call not answered]`, a call that ended): kept and
retried, and logged if they never get in. Only a refusal for a held chat is retried: after any other failure the
text may have been taken, so it is logged (`undelivered`) and not sent again. Not covered by step 1: the classic
CLI REPL (it hosts no session the plugin can inject into by id), a process whose plugin is older than this, and a
second plain `hermes serve` in the same home.

## Alert pushes

The phone also hears, as an ordinary notification, about what needs it in a conversation the dashboard hosts while
nothing has that conversation open (no app, Desktop window or dashboard chat attached to it):

- **An approval or a question waiting.** A watcher in the dashboard process looks at every live conversation's open
  server requests (those of turns under `dashboard.turn_isolation` too). A request alerts once, after it waited
  `grace_s` with no client attached; a client that attaches restarts the wait.
- **A turn done**, when no client had the conversation open as the turn ended nor `grace_s` later, it didn't go on
  with another turn, and it isn't on a call with the phone. A turn the user left mid-way (the app went to the
  background, say) alerts; one they watched end doesn't. The watcher sees the turn end itself (Hermes doesn't run
  `on_session_end` on every way out of a turn) and reads how it ended from the turn's `message.complete`
  (relayed from a compute-host child too): its reply, or that it failed. An interrupted or muted turn, and a
  `[SILENT]` reply, say nothing. The dashboard closes a conversation nobody has open once its turn is over (20 s
  after the last client left, then every 20 s) and frees its events with it; when that comes before the
  watcher's next look (every 0.5 s), the turn's end is read in the `on_session_finalize` hook instead. Not
  covered: under `turn_isolation`, a turn that starts and ends between two looks is never seen (no hook of the
  dashboard's fires for a turn that ran in a child).

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
`questions` with questions: empty when they don't fit in 4 KB, previews are off, or Hermes' secret redaction would
change a choice, and the app then opens the conversation to answer. Every title, body and question goes through
Hermes' redaction (`redact_sensitive_text`, forced on) first; where it can't run, the generic line goes instead. The body of an approval is what needs approving (never the command); with
`previews: false` the title is "Hermes" and the body a generic line. The app answers with the gateway's `request.answer {id: request_id, result}` (`{choice}` for an
approval, `{answers: {qid: answer}}` for a question), from any socket. An APNs `410` or bad-token answer forgets
only the alert token: the phone still rings. A push APNs couldn't take for a passing reason (unreachable, `429`,
`5xx`) is tried again after 1, 2, 4 and 8 s while its request is open. During `policy.quiet_hours`, and past a
budget (one sounding turn_done per conversation every 5 minutes, 20 sounding alerts an hour), alerts go silently:
no `sound`, `"interruption-level": "passive"`. The log names the kind, how many phones and APNs' reason, never a
token or the payload.

## Phone protocol

JSON text frames on `/phone` plus binary PCM (16-bit little-endian mono, 24 kHz):

| Direction | Messages |
|---|---|
| phone → plugin | `hello {call_id, session_id?, title?, initiated_by: user\|push, app_version}`, `ringing`, `answered`, `declined`, `played {id}`, `user_turn {call_id, text, ending {kind, detector?, detail?, error?}, provider, language?, started_at, ended_at}`, `ping`, `bye {reason?}` |
| plugin → phone | `ready {call_id, state: ringing\|live}`, `cancel {reason}`, `speech_start {id, text, sample_rate, format}` + PCM + `speech_end {id}` (or with `cancelled: true` / `error`), `pong`, `ended {outcome}` |

Close codes: 4401 auth (a bad or reused ticket, or a Host / Origin the dashboard refuses), 4400 bad hello, 4409
replaced by a newer link, 4429 another conversation holds the call, 1011 the link stopped taking frames. The
plugin accepts the socket before refusing it, so the phone sees the code. Hermes 0.22.7 and later checks Host,
Origin and peer itself in front of every plugin socket and refuses those before the upgrade: the phone then gets
HTTP 403 on the handshake and no close code, which the app treats like 4401. VoIP push payload:
`{call_id, session_id, profile, mode, title}`; the app turns the 32-hex `call_id` into the CallKit UUID.

- A push call is `ready {state: "ringing"}` until the phone says `answered`; nothing is spoken before that.
- `bye {reason}`: `hang_up` and `declined` end the call as `ended_by_user` / `declined`; `no_answer` (the phone's
  own ring timeout ran out) as `no_answer`; `error` (the phone gave up on the call) as `lost`.
- A hello for a call that is over gets `cancel {reason}` (never answered) or `ended {outcome}`, then close 1000; a
  push hello for a call the plugin doesn't know gets `cancel {reason: "unknown_call"}`.
- `GET /status` → `{calls, tts: "elevenlabs" | "fake", h2, apns_configured, scribe_configured, active_call,
  hub_socket: "open" | "waiting" | "taken" | "paused" | "failed" | "off", alerts}`,
  where `active_call` is `{call_id, session_id, title, state, initiated_by: "push" | "user"}` or null (the app's
  call button joins a call Hermes holds for the same chat) and `alerts` is `{enabled, kinds, watching, devices,
  sent}`. HTTP errors are `{detail}`.
- The VoIP push's `session_id` can be a conversation of another process (`local-…` for a CLI one the gateway runs,
  a messaging chat's), which the dashboard may not be able to open: the call works the same.

## Hermes versions

The plugin uses Hermes internals that carry no compatibility promise (most go through `hermes.py`, each
with a fallback), so it is only known to work with a Hermes the integration suite below was run against:

| Hermes | Result |
|---|---|
| v0.23.0 (`2bd378ed1b`, 2026-11-05) | green |
| canary of 2026-10-25 (`d778246c84`, v0.22.5 + 315 commits) | green at the time; not run again since |

`plugin.yaml` sets `requires_hermes: ">=0.22.5"`, so an older Hermes refuses to load the plugin. Run the suite
after every Hermes update. What Hermes changed under the plugin so far:

- **0.22.6: closed local conversations leave the gateway's memory** (`gateway/session_retirement.py`). A keyed
  `ctx.inject_message` for one was refused ("not a live local session"), so what you said on a call was lost when
  the call's CLI or TUI conversation was idle and its window closed (always, for a finished `hermes chat -q` run).
  The plugin now has Hermes restore the conversation and tries again (see "Calls from any session").
- **0.22.6: `ConfigBackendUnavailable` is a `SystemExit`**, which `except Exception` doesn't catch. The plugin
  keeps the settings it last read instead of letting it end the thread that asked.
- **0.22.7: the dashboard checks Host / Origin / peer in front of every plugin socket** and refuses before the
  upgrade (HTTP 403) what the plugin used to close with 4401. Nothing to change: the app treats both alike.
- **0.22.3: a closed dashboard conversation's replay ring is freed at once** (`event_replay.forget_session`). The
  dashboard closes a conversation nobody has open once its turn is over; when that came before the alert
  watcher's next look, the turn's end could no longer be read and, under `turn_isolation`, its `turn_done` alert
  was lost (by the timing, about 3 in 100 such turns with Hermes' 20 s reap grace; 4 of 21 in the tests, whose
  grace is 2 s, which made the suite flaky). The watcher now reads the turn's end in `on_session_finalize` (see
  "Alert pushes").

## Development

```bash
cd hermes-voice-plugin
uv run pytest -q
```

The tests stub every Hermes module the plugin imports, run the plugin's router on a real server (an OS-assigned
port) and drive it with a fake phone over a real WebSocket, plus a mock APNs and a mock ElevenLabs.

`tests/integration/` runs the plugin inside a real `hermes serve --isolated` (opt-in; about five minutes when
green, and a minute or two more for each test that fails, since a failure waits out its timeouts):

```bash
HERMES_VOICE_INTEGRATION=1 uv run pytest -q tests/integration
```

- `test_real_hermes.py`: dashboard conversations driven over `/api/ws` call the phone (sync, async, redirect while
  a turn runs, declined, rung out, `busy`, unreachable, the socket's auth).
- `test_calls_any_session.py`: `hermes chat -Q -q` in the same home (its turn runs in the gateway Hermes starts) calls
  through `hub.sock`: refused under the default policy (a one-shot), then, opted in, a sync call returns the reply
  to that process; an async one's reply becomes a stored user turn of the gateway session, answered into the same
  call; a voice turn the provider refuses (no `on_session_end`) doesn't swallow the next one.
- `test_isolated_calls.py`, under `turn_isolation`: an idle voice turn is started by the dashboard (which then shows
  it running), and a prompt typed meanwhile reaches the model instead of failing as "session busy".
- `test_chat_open_elsewhere.py`: a second `hermes serve` in the same home, started the way the Desktop app starts
  its backend, holds the chat a call is started in from the phone: the notice and the turns reach that backend's
  session, and its agent answers into the call. Then a process without the plugin holds a chat's lease: the phone
  hears that the chat can't be reached, and once that process is gone the notice and the kept turn arrive in order,
  marked as delayed.
- `test_alerts_real_hermes.py`, with turns in the dashboard and under `turn_isolation`: approval and question
  alerts once the client leaves, answered with `request.answer` from the alert's ids; a turn the provider fails
  alerts that it failed; and through the real APNs
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
