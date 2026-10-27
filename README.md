# Hermes Voice

A small iPhone app for your own [Hermes Agent](https://github.com/NousResearch/hermes-agent), modelled on
[Hermes Conduit](https://github.com/kaishi00/hermes-conduit), with one feature at its center: **CallKit voice calls
with Hermes, where Hermes is heard only when it chooses to speak.**

- **You call Hermes** from any chat, or **Hermes calls you**: an agent uses the `start_call` tool, and your iPhone
  rings through a VoIP push, even when the app isn't running. Either way it is a real CallKit call (Dynamic Island,
  Lock Screen, keeps running while the phone is locked).
- Hermes' normal replies stay **text only**. You hear Hermes only through `start_call`, which turns the text into
  speech with **ElevenLabs** on the Hermes host and streams it to the phone.
- What you say is recognised on the phone (Apple speech recognition, or ElevenLabs Scribe) and goes back to the
  conversation the call belongs to: to a `start_call` that is waiting for your answer, or into the conversation as
  a `[Voice] …` message.
- When a conversation nobody has open waits for your approval or an answer, or finishes a turn, the plugin sends an
  ordinary notification (an alert push) to the phone.

Calls run through the **`hermes_voice` Hermes plugin** ([`hermes-voice-plugin/`](hermes-voice-plugin)), served by
the Hermes dashboard itself. The older `hermes-voice-mcp` server (a `speak` MCP tool on its own port) is kept below
as [legacy](#legacy-the-hermes-voice-mcp-server) until the [cutover](#cutover-from-hermes-voice-mcp).

```
iPhone (HermesVoice)                           Hermes host: hermes serve :9119 (Tailscale Serve, basic auth)
┌─────────────────────────┐  cookie + /api/ws   ┌─────────────────────────────────────────────┐
│ chats                   │ ──────────────────▶ │ dashboard sessions (tui_gateway)            │
│ CallKit + PushKit call  │                     │   └─ agent: start_call / end_call ─┐        │
│ speech → user_turn      │  /api/plugins/      │                                     ▼        │
│ plays PCM speech     ◀──┼─ hermes_voice/phone ┼── hermes_voice plugin: call hub, inject      │
│                         │                     │      ├─ ElevenLabs TTS → PCM                │
│          ▲ VoIP push    │                     │      ├─ Scribe tokens for the phone         │
└──────────┼──────────────┘                     │      └─ APNs (HTTP/2, .p8 key) ──┐          │
           └──────────────────── Apple APNs ◀────┼───────────────────────────────────┘          │
                                                └─────────────────────────────────────────────┘
```

## Layout

| Path | What |
|---|---|
| [`HermesVoice/`](HermesVoice) | SwiftUI iOS app (iOS 17+), generated with XcodeGen from `project.yml` |
| [`hermes-voice-plugin/`](hermes-voice-plugin) | The `hermes_voice` Hermes plugin: `start_call` / `end_call`, the phone's socket, VoIP and alert pushes, TTS |
| [`hermes-voice-mcp/`](hermes-voice-mcp) | Legacy: the `speak` MCP server and its phone socket (until the cutover) |
| [`devtools/`](devtools) | `fake_hermes.py`, a fake dashboard (with a fake `hermes_voice` plugin) for Simulator tests |

## Calls with the hermes_voice plugin

**Hermes calls you.** In any conversation on the host (the dashboard, Hermes Desktop, the CLI or TUI, your own
direct messages to Hermes on a messaging platform), an agent can call `start_call(text, mode)`:

- With no call yet, the plugin rings your iPhone (a VoIP push straight to APNs) and speaks `text` once you
  answer. Calling `start_call` again on the same call just speaks; it never rings twice.
- `mode: "sync"` waits until you answer and returns `{said, ending, outcome, call_id}`: what you said, how your
  turn ended (`end_of_speech`, `cut_off`, `hang_up`…) and how the call went (`answered`, `declined`, `no_answer`…).
- `mode: "async"` (the default) returns `{call_id, status}` at once. What you say then arrives in the conversation
  as a message, forced in like a correction you typed: into the running turn (`session.redirect`, else
  `session.steer`), or as a new turn when Hermes is idle (`prompt.submit`). A conversation that runs in another
  Hermes process (the CLI, the messaging gateway, cron) gets it the same way in that process, over the plugin's
  local hub socket; a new turn there is started with Hermes' `inject_message`, which a gateway conversation allows
  only with `allow_gateway_injection` (see the setup).
- `end_call(text?)` says an optional goodbye and hangs up.

**You call Hermes.** Tap the phone button in a chat. Hermes gets a `[Voice call started] …` notice in that chat
and answers with `start_call`. If Hermes is already ringing you from this chat, the button joins that call.

What the conversation sees (the chat itself shows only what you said, or a short notice):

| Message | When |
|---|---|
| `[Voice] <said> (Reply out loud with start_call; …)` | a turn of yours that no waiting `start_call` took |
| `[Voice, cut off] …`, `[Voice, hung up] …`, `[Voice, muted] …` | the same, when the turn didn't end on its own |
| `[Voice call started] …` | you started the call (your turns wait until this is delivered) |
| `[Voice call not answered] …` | an async call was declined or rang out |
| `[Voice line not delivered: …]` | the phone couldn't be rung or reached, or a line couldn't be spoken |
| `[Voice call ended by user] …` | you hung up (unless your last turn already said so) |

There is one call at a time. A call belongs to the conversation that started it (and follows it through context
compression); `start_call` from another conversation returns `busy`. Who may ring you is set in the plugin's policy
(sources, rate limits, quiet hours; see the [plugin README](hermes-voice-plugin/README.md)).

On the iPhone, **Settings → Calls** picks the speech recognizer (Apple, or ElevenLabs Scribe with a token the
plugin mints, so the key stays on the host), the language and how long a pause ends your turn, and shows whether
pushes are registered and what the plugin reports.

### Setup on the Hermes host

The checklist for the machine (a Linux VM with systemd here) that runs Hermes. Do it once, then the
[cutover](#cutover-from-hermes-voice-mcp).

1. **Run the dashboard under systemd, with basic auth.** Put the sign-in in `~/.hermes/.env`:

   ```bash
   HERMES_DASHBOARD_BASIC_AUTH_USERNAME=me
   HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=a-strong-password
   HERMES_DASHBOARD_BASIC_AUTH_SECRET=<output of: openssl rand -base64 32>
   ```

   Keep the dashboard bound to 127.0.0.1, as a user service in `~/.config/systemd/user/hermes.service`:

   ```ini
   [Unit]
   Description=Hermes backend (hermes serve)
   After=network-online.target

   [Service]
   ExecStart=%h/.local/bin/hermes serve --host 127.0.0.1 --port 9119
   Restart=on-failure
   # 78 is Hermes refusing to start over a config error: don't restart into it forever.
   RestartPreventExitStatus=78

   [Install]
   WantedBy=default.target
   ```

   ```bash
   systemctl --user daemon-reload && systemctl --user enable --now hermes
   loginctl enable-linger "$USER"     # keeps it running while you're logged out
   ```

2. **Reach it over Tailscale.** Run `tailscale serve --bg 9119`, then give the dashboard its public address in
   `~/.hermes/config.yaml`: the exact HTTPS origin `tailscale serve` printed (no path, no port). This also turns
   the dashboard's sign-in gate on, and it is the Host its DNS-rebinding checks accept; without it every request
   from the phone fails with `400 Invalid Host header`.

   ```yaml
   dashboard:
     public_url: https://<machine>.<tailnet>.ts.net
   ```

   Calls work with `dashboard.turn_isolation` on or off: a turn that runs in a compute-host child reaches the
   phone through the plugin's hub socket, like the CLI and the messaging gateway.

3. **Secrets**, in `~/.hermes/.env` or Hermes' secret store (`hermes plugins install` also asks for them):

   | Variable | What |
   |---|---|
   | `ELEVENLABS_API_KEY` | Hermes' voice, and Scribe tokens for the phone |
   | `HERMES_VOICE_APNS_KEY_PATH` | the APNs auth key (`.p8`) from your Apple Developer account, e.g. `~/.hermes/hermes-voice/AuthKey.p8` (`chmod 600` it) |
   | `HERMES_VOICE_APNS_KEY_ID` | that key's 10-character Key ID |
   | `HERMES_VOICE_APNS_TEAM_ID` | your 10-character Team ID |

   Ringing needs a paid Apple Developer team: an APNs key, and an app build signed with the Push Notifications
   capability.

4. **Install and enable the plugin** for each profile that should call you:

   ```bash
   hermes plugins install Al-ex-W/hermes-ios/hermes-voice-plugin   # GitHub: this repo's default branch
   hermes plugins enable hermes_voice        # also installs its one dependency, h2 (APNs is HTTP/2 only)
   ```

   `hermes plugins install` only clones Git sources, and reads a bare path as GitHub `owner/repo` shorthand. For a
   local clone, run `hermes plugins install "file://$PWD#hermes-voice-plugin"` in the repo's root: it installs what
   is committed on the checked-out branch. `--ref <commit-sha>` pins one commit.

   Optional: a voice, a policy and the alert pushes under `plugins.entries.hermes_voice.settings` (see the
   plugin README). If the dashboard log warns that `h2` is missing, run `hermes pm repair`.

   **Calls from conversations outside the dashboard.** Every Hermes process on the host (the CLI and TUI, the
   messaging gateway, cron, compute-host children) reaches the phone through the dashboard's
   `~/.hermes/hermes-voice/hub.sock` (owner-only, with a token that changes on every dashboard start), so the
   dashboard has to be running. For the conversations the messaging gateway runs (your Telegram or Discord DMs,
   and the CLI's own sessions, which current Hermes hands to a local gateway) to take what you say while idle as
   a new turn, let the plugin start turns there:

   ```yaml
   plugins:
     entries:
       hermes_voice:
         allow_gateway_injection: true      # Hermes' own switch, next to settings (not inside it)
   ```

   Without it, an async `start_call` from such a conversation is refused with a note saying so; a sync one still
   returns your reply.

   **Who may ring you from a chat.** Your own direct messages may ring you; group chats, scheduled jobs and
   subagents may not (each has an `allow_*` setting). "Your own" means the users `policy.owner_ids` names (for
   example `["telegram:123456789"]`), or, with no `owner_ids`, the users the gateway serves by name: its platform
   allowlist (`TELEGRAM_ALLOWED_USERS` …), `GATEWAY_ALLOWED_USERS`, or a pairing you approved. An allow-all
   switch, a `*` wildcard or a role-based grant makes nobody the owner, so set `owner_ids` then. The rate limits
   and quiet hours count every ring on the host, whichever process it came from. Runs nobody sits at
   (`hermes chat -q`, `hermes -z`, `--source tool`) don't ring unless `policy.allowed_sources` adds `oneshot` /
   `tool`, and another profile's processes only when `policy.allowed_profiles` lists it.

   ```yaml
   plugins:
     entries:
       hermes_voice:
         settings:
           policy:
             owner_ids: ["telegram:123456789"]
           alerts:
             turn_done: false               # e.g. no "Hermes finished" pushes from this host at all
   ```

5. **Restart the dashboard** (`systemctl --user restart hermes`): plugin routes are mounted at startup. Then,
   signed in to the dashboard, open `https://<machine>.<tailnet>.ts.net/api/plugins/hermes_voice/status`: `h2`,
   `apns_configured` and `scribe_configured` should be `true`, `tts` should be `"elevenlabs"`, and
   `alerts.watching` `true`. Restart the messaging gateway too, if one runs, so it loads the plugin.

6. **On the iPhone:** Tailscale with On-Demand (calls can't reach Hermes without it; the app says so when that's
   the problem), sign in to the dashboard, open the app once so it registers for pushes, and use
   **Settings → Calls → Check**.

7. **Alert pushes.** The app registers an alert token next to its VoIP token, and turning a kind of notification
   off on the phone (approval, question, turn done) sends `POST /api/plugins/hermes_voice/devices` with
   `{"alerts": {"turn_done": false}}`, say; `alerts.devices` in the status counts the phones that take them. They
   come only for conversations the dashboard hosts while no client has them open (after `grace_s`, 5 s), use the
   same APNs key as the calls (`apns-push-type: alert`, topic = the app's bundle id), pass Hermes' secret
   redaction, go silently during `policy.quiet_hours`, and with `alerts.previews: false` carry no conversation
   text (nor does the call push's title). The app answers an approval or a question from the
   notification through the dashboard (`request.answer`).

### Cutover from hermes-voice-mcp

Do this in one go, together with installing the app build that talks to the plugin (it has no voice-server
settings any more):

1. Remove `mcp_servers.hermes_voice` from `~/.hermes/config.yaml` and run `/reload-mcp` in Hermes.
2. Stop the old server: `launchctl bootout gui/$(id -u)/io.github.hermes-ios.voice` for the launchd agent that
   `hermes-voice-mcp/launchd/install.sh` installed (or stop however you ran `uv run hermes-voice-mcp`), and drop
   its tailnet mapping with `tailscale serve --https=8443 off`.
3. `HERMES_VOICE_TOKEN` in `~/.hermes/.env` is no longer used and can go.

**Rollback:** put the `mcp_servers.hermes_voice` entry back, `/reload-mcp`, start the old server and its
`tailscale serve` mapping again, and reinstall the previous app build. The plugin can stay installed.

### Known limits

- **Tool Search.** Current Hermes defers plugin tools behind its `tool_search` / `tool_describe` / `tool_call`
  bridge (`tools.tool_search.enabled: auto`): the model sees `start_call` in the bridge's catalog listing and calls
  it through `tool_call`, describing it first if it hasn't yet. `tools.tool_search.enabled: off` lists every tool
  directly, at the price of a bigger prompt.
- **Steer timing.** During a long tool batch, Hermes reads an injected turn after the batch. A redirect Hermes
  accepts in the very moment its last model reply completes is dropped with that turn (a steer would be carried
  into the next turn), so that one thing you said never reaches the conversation.
- Calls from other processes need the dashboard running (it holds the phone's socket and the one call); without
  it `start_call` answers `not_available`. A call whose process goes away for more than 30 s is hung up.
- From a messaging chat, a sync `start_call` waits at most Hermes' bound on one human wait inside a tool call
  (`approvals.timeout` + 60 s); after that your reply arrives as a `[Voice]` message.
- The VoIP push's `session_id` can name a conversation of another process (a `local-…` CLI session, a messaging
  chat), which the app may not be able to open; the call itself works the same.
- Alert pushes cover only conversations the dashboard hosts. A suspended app counts as attached until Hermes
  notices its socket is gone, and an alert APNs refuses isn't retried.
- Half duplex: the mic is off while Hermes speaks. If you're mid-sentence when Hermes starts, it waits up to 3 s,
  then what it heard so far goes in as `cut_off`.
- The Simulator has no VoIP pushes, CallKit audio or microphone: there calls ring inside the app only, Hermes can
  be heard, and you answer by typing. Debug builds take `hermesvoice://ring?call_id=…&session_id=…` as a push.

## Settings, profiles and notifications

**Settings** (the gear in the sidebar) follows the desktop app's pages: Model, Chat, Appearance, Workspace, Safety,
Browser, Passwords & Logins, Memory & Context, Advanced, Notifications, Billing, Providers, Profiles, Tools & Keys,
Sessions and About, with a search over every field. The config pages are built from the dashboard's
`/api/config/schema`, and each change is saved on its own (`PUT /api/config` with only that key). The desktop's
Voice page, keyboard shortcuts, window layout, pet, local models and uninstall are left out; its Gateways page is
this app's **Connection** page, and **Calls** is this app's own.

- **Profiles** opens from the sidebar's title menu (**Manage profiles…**) or from Settings: create, clone, rename,
  delete, set the default, export or import (paths on the host), and edit SOUL.md.
- **Providers** signs in to provider accounts (device codes) and adds API keys and custom endpoints. A key you type
  is sent only to your own dashboard (`/api/env`); the app neither keeps nor logs it.
- **Notifications** chooses which alerts Hermes may push to this iPhone: an approval waiting, a question waiting,
  a turn finished. The app registers its APNs alert token and these choices with the `hermes_voice` plugin
  (`POST /api/plugins/hermes_voice/devices`). Approvals can be answered from the notification (Run, Allow for
  session, Reject), a single question with a typed reply, and tapping a notification opens its chat. The plugin
  must support alert pushes for these to arrive; with an older plugin only the registration happens.

## Files, review, messaging, agents and kanban

These follow the desktop app's screens and sit where the desktop puts them, adapted to the phone:

- **Files and Review** (the desktop's right sidebar) open from the chat's header button: beside the chat on iPad,
  as a sheet on iPhone. Files browses the session's folder on the host, previews text, markdown and images, adds
  `@file:` references to the composer, copies paths and downloads files. Like the desktop on a remote backend, it
  doesn't rename, delete or upload: Hermes' file-write routes act on the dashboard's own disk, not on the profile's
  workspace (which can be an SSH machine). Review shows the git changes (uncommitted, branch, last turn) with diffs,
  stage, unstage and revert, commits and pushes, and opens pull requests through `gh` on the host. The desktop's
  terminal tab isn't ported.
- **Messaging** is a sidebar row: platform status, setup fields (tokens go only to your own dashboard and are never
  kept or logged by the app), Telegram and WhatsApp setup, pairing requests and approved users, the connection test.
- **Kanban** is a sidebar row while the host serves the kanban plugin: boards, cards with drag and drop, the task
  sheet, and live updates over the plugin's event socket.
- The sidebar's bottom bar holds the desktop statusbar's **Agents** (the subagent tree, with its running count) and
  **Webhooks**, and the **Memory Graph** (also `/journey` in a chat). The chat's subagent status opens Agents too.
- **Import session** (continue a Claude Code or Codex conversation found on the host) is in the Command Center.

## Building the app

```bash
cd HermesVoice
xcodegen generate
open HermesVoice.xcodeproj
```

Signing is personal, so it isn't in the repo. Copy `HermesVoice/Config/Local.xcconfig.example` to
`HermesVoice/Config/Local.xcconfig` (gitignored) and set your `BUNDLE_ID_PREFIX` and Apple `DEVELOPMENT_TEAM`;
the app's bundle id becomes `$(BUNDLE_ID_PREFIX).hermesvoice`. For Hermes to ring the phone, the team must be a
paid one with the Push Notifications capability (the app also uses the `voip` and `audio` background modes).

In the app, enter the **Hermes dashboard** address (`https://<machine>.<tailnet>.ts.net`), username and password.

## Testing

```bash
# The plugin (call hub, streaming, ring protocol, injection, policy, APNs, routes) against stubbed Hermes modules
cd hermes-voice-plugin && uv run pytest -q

# The plugin inside a real `hermes serve` in a temp home (opt-in, about three minutes; needs a Hermes install)
HERMES_VOICE_INTEGRATION=1 uv run pytest -q tests/integration

# The legacy MCP server, and the fake dashboard with its fake plugin
cd hermes-voice-mcp && uv run pytest -q && uv run pytest -q ../devtools/tests

# The app's unit tests
cd HermesVoice && xcodebuild test -project HermesVoice.xcodeproj -scheme HermesVoice \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

The integration tests start Hermes with its own interpreter in a temp `HOME` and `HERMES_HOME` (nothing outside
them is written), sign in with basic auth, drive conversations over `/api/ws` with a stub OpenAI-compatible model
that calls `start_call`, and play the phone on `/phone`: a sync call that returns what was said, an async call
whose turns are injected (a new turn while idle, a redirect while a turn runs), a declined call, one that rings
out, `busy`, an unreachable phone, and the dashboard's auth on the socket. A second Hermes process in the same home
(`hermes chat -Q -q`, whose turn runs in the gateway Hermes starts) calls through the hub socket: its sync call
gets the reply, and its async call's reply becomes a stored turn of that session. Approvals and questions waiting
on a conversation nobody has open send alert pushes, answered with `request.answer`, with turns in the dashboard
and under `turn_isolation`; through the plugin's real APNs sender and a mock APNs, an approval reaches each phone
that takes approval alerts exactly once. APNs itself is replaced by a recorder or that mock. They look for Hermes
at `~/.hermes/hermes-agent`; set `HERMES_AGENT_DIR` or `HERMES_PYTHON` otherwise, and
`HERMES_VOICE_IT_PORTS=<low>-<high>` to keep their servers in a port range.

With [`devtools/fake_hermes.py`](devtools) running (`--port 9311 --reap-grace 1`), prefix the `xcodebuild test`
command with `TEST_RUNNER_HERMES_FAKE_URL=http://127.0.0.1:9311 TEST_RUNNER_HERMES_FAKE_REAP_GRACE=1` to also run
the app's end-to-end tests against it. Add `-test-timeouts-enabled YES -default-test-execution-time-allowance 60
-collect-test-diagnostics never` so a stuck test fails within a minute: the allowance covers only the tests, and
after a failure xcodebuild otherwise gathers `simctl diagnose`, which can hold the run for ten minutes or more once
the tests are done. The fake serves the plugin's routes too: typing `call me sync: …` in a chat
makes its agent call `start_call`, and `POST /api/plugins/hermes_voice/debug/ring` returns a push payload for
`xcrun simctl openurl booted "hermesvoice://ring?…"` (see `devtools/fake_voice_plugin.py`).

## How the pieces talk

- **Dashboard**: `POST /auth/password-login` sets a cookie. `POST /api/auth/ws-ticket` returns a single-use ticket
  for `wss://…/api/ws?ticket=…`, which carries JSON-RPC: `session.resume`, `session.create`, `prompt.submit`, and
  streamed `message.*`, `tool.*` and `session.*` events. After a reconnect the app re-attaches each chat in use,
  on screen or in a call (`session.activate`, or `session.resume` when Hermes reaped it meanwhile), and replays
  what it missed (`session.events.since`). Approvals, questions and passwords arrive as server→client requests and
  are answered from the chat.
- **Calls**: `wss://…/api/plugins/hermes_voice/phone?ticket=…`, with a fresh ticket for every connect. The app
  says `hello {call_id, session_id, title, initiated_by: user|push, app_version}` and gets `ready {call_id,
  state}`; for a push it says `ringing`, then `answered` (once the call's audio runs) or `declined`. Speech comes
  as `speech_start {id, text, sample_rate, format}`, binary 16-bit PCM and `speech_end {id}`; the app answers
  `played {id}` once all of it was heard (a line whose audio was dropped gets no ack).
  What you say goes as `user_turn {call_id, text, ending {kind, …}, provider, language, started_at, ended_at}`.
  The plugin ends a call with `cancel {reason}` while it rings or `ended {outcome}` once live; the app hangs up
  with `bye {reason}`. Close codes: 4401 auth (the app mints one more ticket, then gives up), 4400 bad hello, 4409
  replaced by a newer link, 4429 another conversation holds the call, 1011 a stalled link (the app reconnects).
  The [plugin README](hermes-voice-plugin/README.md) has the details.
- **Ringing**: the plugin sends a VoIP push `{call_id, session_id, profile, mode, title}` to every iPhone that
  registered (`POST /api/plugins/hermes_voice/devices`). The app turns the 32-hex `call_id` into the CallKit UUID
  by inserting dashes, reports the call to CallKit at once, then signs in if it has to and opens the chat and the
  link.
- **Alerts**: `{"aps": {alert {title, body}, category: HERMES_APPROVAL | HERMES_CLARIFY | HERMES_TURN_DONE,
  thread-id: <session id>, sound}, "hermes": {kind, session_id, profile, request_id?, choices?, questions?}}` to
  the alert token the app registered; the notification's actions answer with `request.answer {id: request_id,
  result}` over `/api/ws`.

## Legacy: the hermes-voice-mcp server

Until the cutover, the old setup keeps working for earlier app builds: the app announces a call with
`[Voice call started] call_id: …`, posts what you say as `[Voice] …` messages, and Hermes speaks with the `speak`
MCP tool, passing that `call_id` back (MCP tools aren't told which chat called them).

1. **ElevenLabs**: `ELEVENLABS_API_KEY` in `~/.hermes/.env`. The voice is `HERMES_VOICE_VOICE_ID`, else
   `tts.elevenlabs.voice_id`, else Hermes' default; the model is `HERMES_VOICE_MODEL_ID`, else
   `tts.elevenlabs.streaming_model_id`, else `eleven_flash_v2_5`.
2. **Run the server**: `cd hermes-voice-mcp && uv run hermes-voice-mcp` (on 127.0.0.1:8765). It uses
   `HERMES_VOICE_TOKEN`, else creates a token in `~/.hermes/hermes-voice/token` (`uv run hermes-voice-mcp token`
   prints it). On macOS, `hermes-voice-mcp/launchd/install.sh` installs it as a launchd agent. Expose it with
   `tailscale serve --bg --https=8443 http://127.0.0.1:8765`.
3. **Connect Hermes**: `HERMES_VOICE_TOKEN=<token>` in `~/.hermes/.env`, and in `~/.hermes/config.yaml`:

   ```yaml
   mcp_servers:
     hermes_voice:
       url: http://127.0.0.1:8765/mcp
       headers:
         Authorization: "Bearer ${HERMES_VOICE_TOKEN}"
   ```

   then `/reload-mcp`. Hermes gets the tool `mcp__hermes_voice__speak`.

## Credits

Built after studying Hermes Conduit by kaishi00 and its notifier plugin, both MIT-licensed. The code here is new,
but its dashboard protocol knowledge comes from those projects.
