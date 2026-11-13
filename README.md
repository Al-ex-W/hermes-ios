# Hermes Voice

> **Research beta.** Every AI agent involved is asked to report any issue, inefficiency or discrepancy it notices,
> right away: Hermes through the `start_call` tool description and the `voice-calls` skill, and coding agents
> through [AGENTS.md](AGENTS.md).

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
- If you turn it on, Hermes can ask the phone where it is (`get_location`), say for a scheduled "will I be late?"
  check. It is off by default, and the position goes only to your own Hermes host (see
  [Location and privacy](#location-and-privacy)).

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
| [`hermes-voice-plugin/`](hermes-voice-plugin) | The `hermes_voice` Hermes plugin: `start_call` / `end_call` / `scheduled_calls` / `get_location`, the phone's socket, VoIP, alert and background pushes, TTS |
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
- **Calls that ring later.** "Call me in ten", "wake me at seven": `start_call` with `in_minutes` or `at`
  (`"07:00"`, or an ISO date-time) schedules the call and returns at once with `{status: "scheduled",
  scheduled_id, rings_at}`. The plugin keeps it in `<HERMES_HOME>/hermes-voice/scheduled.json` (which holds the
  line to speak until the call is done) and `hermes serve` rings at that time by itself: after a restart, with no
  chat or desktop open, and during quiet hours, since it is a call you asked for. Who may schedule is checked when
  scheduling. A ring you don't answer is repeated once after five minutes, then the conversation is told; a call
  the host slept through rings up to 15 minutes late and says so, else the conversation is told it was not placed.
  `scheduled_calls` lists and cancels. Details and settings: [plugin README](hermes-voice-plugin/README.md), "Calls
  that ring later".
- Hermes is told to speak as on the phone: the answer first, two sentences at most, no codes, ids, URLs or paths
  read out. A line that takes longer than about 15 seconds to say is flagged in the `start_call` result.
- **When a line is hard to hear.** The phone tells the plugin how each line really played (how much of it, gaps
  where the audio ran dry, audio restarts, the output and its volume), and Hermes is told when a line may not have
  been heard well, and how much of a line you had heard when you hung up in the middle of it. **Repeat** on the
  call screen plays Hermes' last line again at once, from the copy the phone keeps for the length of the call
  (Hermes learns that you did). Lines spoken with a quiet audio tag are raised to normal loudness on the phone, and
  a line that is playing carries on after the Speaker button or AirPods connecting instead of being cut. When
  Hermes says exactly the same line again, the plugin replays its audio instead of making it anew. Details and
  thresholds: [plugin README](hermes-voice-plugin/README.md), "Playback feedback".
- How you want to be spoken to (tone, form of address, humour, ElevenLabs audio tags) lives in
  `<HERMES_HOME>/hermes-voice/call-style.md`. Hermes gets it with every call, and edits it when you state a lasting
  preference (see the [plugin README](hermes-voice-plugin/README.md), "Call style").

**You call Hermes.** Tap the phone button in a chat. Hermes gets a `[Voice call started] …` notice in that chat
and answers with `start_call`. If Hermes is already ringing you from this chat, the button joins that call.

What the conversation sees (the chat itself shows only what you said, or a short notice):

| Message | When |
|---|---|
| `[Voice] <said> (Reply out loud with start_call; …)` | a turn of yours that no waiting `start_call` took |
| `[Voice, cut off] …`, `[Voice, hung up] …`, `[Voice, muted] …` | the same, when the turn didn't end on its own |
| `[Voice call started] …` | you started the call (your turns wait until this is delivered), or answered one Hermes had scheduled |
| `[Voice call not placed: …] …` | a scheduled call never rang (the host was down too long, or you were on another call) |
| `[Voice call not answered] …` | an async call was declined or rang out |
| `[Voice line not delivered: …] …` | the phone couldn't be rung or reached, or a line couldn't be spoken |
| `[Voice call ended by user] …` | you hung up (unless your last turn already said so and you had heard everything) |

The `[Voice call …]` and `[Voice line …]` messages are automated notices: each says so (`Automated notice from
HermesVoice, not something the user said.`), so that neither Hermes nor a memory plugin takes one for your words
or for a preference of yours. After a hang-up Hermes is told that you can't hear it and are probably not reading
the chat: it finishes the task and leaves one short recap in text. If you hung up while it was still speaking, it
is told what you did not hear, and reminded to offer that part when your next call in that chat starts.

There is one call at a time. A call belongs to the conversation that started it (and follows it through context
compression); `start_call` from another conversation returns `busy`. Who may ring you is set in the plugin's policy
(sources, rate limits, quiet hours; see the [plugin README](hermes-voice-plugin/README.md)).

On the iPhone, **Settings → Calls** picks the speech recognizer (Apple, or ElevenLabs Scribe with a token the
plugin mints, so the key stays on the host), the language and how long a pause ends your turn, and shows whether
pushes are registered and what the plugin reports.

**When your turn ends.** A turn ends when you have been quiet for the pause set under **End of speech**: Quick
1.5 s, Normal 3.5 s (the default, so a thinking pause of two or three seconds in the middle of a sentence doesn't
send half of it), Patient 5 s or Very patient 8 s. Both recognizers honour it: Scribe's own silence threshold
stops at 3 s, so the app asks Scribe for 1.5 s and holds what it hears until the whole pause has passed; Apple's
recognizer closes a segment after a shorter pause of its own (and its requests can finish by themselves), so the
app keeps what was heard and puts what you say next behind it. While you
have words on the call screen, **Send now** ends the turn at once, so a long pause doesn't have to be waited out.
The call is half-duplex (the microphone is off while Hermes speaks): a line of Hermes that arrives while you are
mid-turn waits for the turn to end, at most the pause plus two seconds (10 s at the longest), and then cuts in; the
pause isn't counted while Hermes speaks. A change of the setting applies from the next call.

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

   If `hermes gateway install` already made a `hermes-gateway.service` on this machine, copy its `ExecStart`
   binary, `WorkingDirectory` and `Environment=` lines (`PATH`, `HERMES_HOME`) into this unit instead of
   `%h/.local/bin/hermes`, so both services run the same Hermes the same way.

2. **Reach it over Tailscale.** Run `tailscale serve --bg 9119` (as root, or a Tailscale operator; the first time
   it may print a link to turn Serve on for your tailnet, and waits until you do), then give the dashboard its public address in
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

   With `multiplex_profiles` on, the plugin's background work (pushes, Scribe tokens, speech) has no per-turn
   secret scope, so it reads these from the `.env` of the Hermes home the dashboard serves: put them there, not
   only in a shell environment.

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
   messaging gateway, cron, compute-host children, and the backends the Hermes Desktop app spawns over SSH or
   locally) reaches the phone through the dashboard's `~/.hermes/hermes-voice/hub.sock` (owner-only, with a token
   that changes on every dashboard start), so the `hermes serve` dashboard the phone signs in to has to be running. For the conversations the messaging gateway runs (your Telegram or Discord DMs,
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
   `tool`, and another profile's processes only when `policy.allowed_profiles` lists it. For a call at a set time
   don't use a Hermes cron job (it is a scheduled job, and refused): ask in a chat, and the agent schedules the
   call with `start_call` and `at` / `in_minutes`.

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
   notification through the dashboard (`request.answer`). Because an open chat gets no pushes, check them with
   **Settings → Notifications → Send test notification** instead of asking Hermes for an approval: it has the
   plugin push a sample alert to that iPhone alone (`POST /api/plugins/hermes_voice/devices/test`) and shows what
   APNs answered.

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

- **Speaker.** A call starts on the earpiece (or a connected headset, Bluetooth or car), like a phone call. The
  app's speaker button and CallKit's Speaker button both act on the same audio route, and the app reads that route
  after every change. CallKit's own button may not show a move made with the app's button: iOS doesn't tell it.
- **Tool Search.** Current Hermes defers plugin tools behind its `tool_search` / `tool_describe` / `tool_call`
  bridge (`tools.tool_search.enabled: auto`): the model sees `start_call` in the bridge's catalog listing and calls
  it through `tool_call`, describing it first if it hasn't yet. `tools.tool_search.enabled: off` lists every tool
  directly, at the price of a bigger prompt.
- **Steer timing.** During a long tool batch, Hermes reads an injected turn after the batch. A redirect Hermes
  accepts in the very moment its last model reply completes is dropped with that turn (a steer would be carried
  into the next turn), so that one thing you said never reaches the conversation.
- **A chat that is open in another Hermes process.** Hermes lets one process write a conversation: the one that
  ran a turn in it, for as long as it has it open (the Desktop app's backend keeps its chats, also after their tab
  is closed). A call you start from the phone in such a chat belongs to a dashboard session, and Hermes refuses
  the dashboard ("This chat is open in another Hermes window/terminal"). When the process that holds the chat
  hosts its own sessions and runs this plugin (a Desktop backend, the Ink TUI), it puts the call's notice and what
  you say into its own session, and its agent answers into the call. Otherwise (the classic CLI, a Hermes with an
  older plugin or none) the call says once "I can't reach this chat right now: it's open in another Hermes window.
  Close it there, or call from another chat.", keeps each thing you say for up to two minutes, and puts it in, in
  order and marked as delayed, once the chat is free; what never got in is in `rings.jsonl` (`undelivered`).
  Hermes refuses what you type in that chat from the app in the same way.
- Calls from other processes need the dashboard running (it holds the phone's socket and the one call); without
  it `start_call` answers `not_available`. A call whose process goes away for more than 30 s is hung up.
- **Scheduled calls** ring from `hermes serve` only, so it has to be running at the time (a call it missed by up
  to 15 minutes still rings, late). A call scheduled from a messaging chat rings and speaks its line, but what you
  say on it can't be put into that chat yet. A call scheduled from a chat that another process (a CLI, say) still
  holds at the time behaves as in the point above.
- From a messaging chat, a sync `start_call` waits at most Hermes' bound on one human wait inside a tool call
  (`approvals.timeout` + 60 s); after that your reply arrives as a `[Voice]` message.
- The VoIP push's `session_id` can name a conversation of another process (a `local-…` CLI session, a messaging
  chat), which the app may not be able to open; the call itself works the same.
- Alert pushes cover only conversations the dashboard hosts. A suspended app counts as attached until Hermes
  notices its socket is gone, and an alert APNs refuses isn't retried.
- Half duplex: the mic is off while Hermes speaks. If you're mid-sentence when Hermes starts, it waits for
  your pause setting plus 2 s (at most 10 s), then what it heard so far goes in as `cut_off`.
- The Simulator has no VoIP pushes, CallKit audio or microphone: there calls ring inside the app only, Hermes can
  be heard, and you answer by typing. Debug builds take `hermesvoice://ring?call_id=…&session_id=…` as a push, and
  `hermesvoice://location-request?request_id=…` as the background push that asks where the phone is.
- Playback feedback is what the phone can tell: "played" follows the clock against what was queued, not what
  left the loudspeaker, and the volume is the system's, not how loud the room is. Loudness is levelled per line:
  a whisper that starts half way through a normal line comes up only after about a second. After a reconnect in
  the middle of a line, Repeat keeps playing the line before it (the broken one did not arrive whole).

## Settings, profiles and notifications

**Settings** (the gear in the sidebar) follows the desktop app's pages: Model, Chat, Appearance, Workspace, Safety,
Browser, Passwords & Logins, Memory & Context, Advanced, Notifications, Billing, Providers, Profiles, Tools & Keys,
Sessions and About, with a search over every field. The config pages are built from the dashboard's
`/api/config/schema`, and each change is saved on its own (`PUT /api/config` with only that key). The desktop's
Voice page, keyboard shortcuts, window layout, pet, local models and uninstall are left out; its Gateways page is
this app's **Connection** page, and **Calls** and **Location** are this app's own.

- **Profiles** opens from the sidebar's title menu (**Manage profiles…**) or from Settings: create, clone, rename,
  delete, set the default, export or import (paths on the host), and edit SOUL.md.
- **Providers** signs in to provider accounts (device codes) and adds API keys and custom endpoints. A key you type
  is sent only to your own dashboard (`/api/env`); the app neither keeps nor logs it.
- **Notifications** chooses which alerts Hermes may push to this iPhone: an approval waiting, a question waiting,
  a turn finished. The app registers its APNs alert token and these choices with the `hermes_voice` plugin
  (`POST /api/plugins/hermes_voice/devices`). Approvals can be answered from the notification (Run, Allow for
  session, Reject), a single question with a typed reply, and tapping a notification opens its chat. The plugin
  must support alert pushes for these to arrive; with an older plugin only the registration happens.

  Hermes pushes these only for a conversation nobody has open (after about 5 s), so you can't see one by asking
  for an approval in the chat you are looking at. **Send test notification** on the same page checks the whole
  path instead: pick the kind (approval, question, turn finished) and tap it; the plugin sends a real push through
  APNs to this iPhone only, 5 s later, so you can lock the phone or leave the app first (in the app it shows as a
  banner). The line under the button says what happened: that APNs accepted it, or why nothing went out (this
  iPhone isn't registered or has no notification token, APNs isn't set up on the host, the kind is turned off on
  the host or the phone, APNs doesn't know the token or it is for the other environment, the key or bundle id is
  wrong). Answer the test like a real one (Run, Allow for session or Reject; a typed reply for a question): it
  runs nothing and touches no conversation. The app confirms with "Test approval answered: Run", tells the plugin
  which button it was, and the row shows it. With a plugin that has no test route, the app shows a local
  notification and says so.

### Location and privacy

**Settings → Location → Share location with Hermes** is off by default. While it is on, your Hermes agent can ask
this iPhone where it is with the plugin's `get_location` tool: the motivating use is a scheduled job that checks
your calendar, where you are and the trains, and calls you when you are about to be late.

- **What is sent:** latitude, longitude, the fix's accuracy in metres and its time, and speed and heading when the
  phone is moving. Nothing else, and never on the app's own initiative: only as the answer to a request from
  Hermes. The app keeps no position, only the time one was last sent (shown on the page).
- **To whom:** only the Hermes host you signed in to, over the dashboard connection. The plugin keeps the latest
  fix in memory (never on disk, at most 30 minutes, gone with a restart or when you turn sharing off) and logs that
  a request happened, never where you are. The fix does become part of the conversation that asked for it, like
  any tool result, and so reaches that conversation's model provider.
- **Who may ask:** your own conversations, as for calls, and scheduled jobs (`settings.location.allow_cron`).
  Subagents, group chats and other people's chats may not, and the plugin limits how often the phone is asked.
- **When it works:** during a call the request comes over the call's connection. Otherwise the plugin sends a
  background push that wakes the app. With iOS' "While Using the App" permission the app can answer only while it
  is on screen; "Always" (asked for on the page, never by itself) also covers the app in the background and a
  locked phone. Even then iOS may delay or drop a background push (Low Power Mode, no connection, several requests
  in a short time), and it delivers none to an app you force-quit: Hermes is then told that the phone didn't
  answer, and gets at most the last position with its age.
- **Turning it off** stops everything at once: a fix on its way is dropped, the host is told (the tool then
  answers that sharing is off) and forgets the fix it had. The sidebar shows a location arrow while sharing is on,
  and the page says what iOS currently allows (not asked yet, denied, restricted, While Using, Always, and whether
  the position is only approximate because Precise Location is off).

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
paid one with the Push Notifications capability (the app also uses the `voip`, `audio` and `remote-notification`
background modes; the last one is for the background push that asks where the phone is. It has no `location`
background mode: it gets one fix per request and tracks nothing in between).

In the app, enter the **Hermes dashboard** address (`https://<machine>.<tailnet>.ts.net`), username and password.

## Testing

```bash
# The plugin (call hub, streaming, ring protocol, injection, policy, APNs, routes) against stubbed Hermes modules
cd hermes-voice-plugin && uv run pytest -q

# The plugin inside a real `hermes serve` in a temp home (opt-in, about five minutes; needs a Hermes install)
HERMES_VOICE_INTEGRATION=1 uv run pytest -q tests/integration

# The legacy MCP server, and the fake dashboard with its fake plugin
cd hermes-voice-mcp && uv run pytest -q && uv run pytest -q ../devtools/tests

# The app's unit tests (use any simulator that `xcrun simctl list devices available` shows)
cd HermesVoice && xcodebuild test -project HermesVoice.xcodeproj -scheme HermesVoice \
  -destination "platform=iOS Simulator,name=iPhone 18 Pro" -collect-test-diagnostics never
```

The integration tests start Hermes with its own interpreter in a temp `HOME` and `HERMES_HOME` (nothing outside
them is written), sign in with basic auth, drive conversations over `/api/ws` with a stub OpenAI-compatible model
that calls `start_call`, and play the phone on `/phone`: a sync call that returns what was said, an async call
whose turns are injected (a new turn while idle, a redirect while a turn runs), a declined call, one that rings
out, `busy`, an unreachable phone, and the dashboard's auth on the socket. A second Hermes process in the same home
(`hermes chat -Q -q`, whose turn runs in the gateway Hermes starts) calls through the hub socket: its sync call
gets the reply, and its async call's reply becomes a stored turn of that session. A call started from the phone in
a chat another process holds: a backend started the way the Desktop app starts its own takes the call's turns and
answers into the call; with a holder that can't be asked, the phone hears that the chat can't be reached, and the
turns arrive in order once the holder is gone. A call scheduled a few seconds ahead rings on time once its
conversation is idle with no client attached, the reply becomes a stored turn of it, an unanswered ring is repeated
once, and a scheduled call survives a restart of the dashboard. Approvals and questions waiting
on a conversation nobody has open send alert pushes, answered with `request.answer`, with turns in the dashboard
and under `turn_isolation`; through the plugin's real APNs sender and a mock APNs, an approval reaches each phone
that takes approval alerts exactly once. APNs itself is replaced by a recorder or that mock. They look for Hermes
at `~/.hermes/hermes-agent`; set `HERMES_AGENT_DIR` or `HERMES_PYTHON` otherwise, and
`HERMES_VOICE_IT_PORTS=<low>-<high>` to keep their servers in a port range.

The plugin reaches into Hermes internals, so it is only known to work with the Hermes it was run against: this
suite is green against Hermes v0.23.0 (commit `2bd378ed1b`), and was green before that against the canary of
2026-10-25 (`d778246c84`, v0.22.5 plus 315 commits). `plugin.yaml` refuses to load on a Hermes older than 0.22.5
(`requires_hermes`). Run the suite again after every Hermes update: the
[plugin README](hermes-voice-plugin/README.md#hermes-versions) lists what changed in Hermes so far.

With [`devtools/fake_hermes.py`](devtools) running (`--port 9311 --reap-grace 1`), prefix the `xcodebuild test`
command with `TEST_RUNNER_HERMES_FAKE_URL=http://127.0.0.1:9311 TEST_RUNNER_HERMES_FAKE_REAP_GRACE=1` to also run
the app's end-to-end tests against it. Add `-test-timeouts-enabled YES -default-test-execution-time-allowance 60
-collect-test-diagnostics never` so a stuck test fails within a minute: the allowance covers only the tests, and
after a failure xcodebuild otherwise gathers `simctl diagnose`, which can hold the run for ten minutes or more once
the tests are done. The fake serves the plugin's routes too: typing `call me sync: …` in a chat
makes its agent call `start_call`, and `POST /api/plugins/hermes_voice/debug/ring` returns a push payload for
`xcrun simctl openurl booted "hermesvoice://ring?…"` (see `devtools/fake_voice_plugin.py`). It answers the test
alert routes as the plugin does without pushing anything; `GET /api/plugins/hermes_voice/debug/test-alerts` has
each test's payload, which `xcrun simctl push booted <bundle id> payload.json` shows in the Simulator with its
actions (see [`devtools/README.md`](devtools/README.md)). For location, typing `where am I` makes the fake agent
call `get_location`, and `POST /api/plugins/hermes_voice/debug/location-request` asks the phone without the agent:
on the call's link while a call is up, else it returns the background push it would have sent. The Simulator
doesn't hand a `content-available` push from `xcrun simctl push` to the app's handler, so a debug build takes
`xcrun simctl openurl booted "hermesvoice://location-request?request_id=<id>"` as that push; give the Simulator a
position first with `xcrun simctl location booted set 59.0,18.0`.

## How the pieces talk

- **Dashboard**: `POST /auth/password-login` sets a cookie. `POST /api/auth/ws-ticket` returns a single-use ticket
  for `wss://…/api/ws?ticket=…`, which carries JSON-RPC: `session.resume`, `session.create`, `prompt.submit`, and
  streamed `message.*`, `tool.*` and `session.*` events. After a reconnect the app re-attaches each chat in use,
  on screen or in a call (`session.activate`, or `session.resume` when Hermes reaped it meanwhile), and replays
  what it missed (`session.events.since`). Approvals, questions and passwords arrive as server→client requests and
  are answered from the chat.
- **Edits of a stored conversation** (rename, pin, unread, archive, delete): the app first reads
  `GET /api/sessions/{id}/mutation-snapshot` and sends its `runtime_revision` and `runtime_generation` back as
  `expected_revision` / `expected_generation` with a `request_id` (in a `PATCH` body, in a `DELETE` query). Hermes
  0.22.3 and later refuse an edit without them (409 `client_upgrade_required`). An edit whose answer never arrived
  keeps its `request_id`, so trying again can't apply it twice; a conversation that changed meanwhile is read and
  sent once more. A Hermes without the snapshot route gets the plain edit.
- **Calls**: `wss://…/api/plugins/hermes_voice/phone?ticket=…`, with a fresh ticket for every connect. The app
  says `hello {call_id, session_id, title, initiated_by: user|push, app_version}` and gets `ready {call_id,
  state}`; for a push it says `ringing`, then `answered` (once the call's audio runs) or `declined`. Speech comes
  as `speech_start {id, text, sample_rate, format}`, binary 16-bit PCM and `speech_end {id}`; the app answers
  `played {id, playback}` once all of it was heard, with what happened to the line (`playback {audio_s, played_s,
  stalls, stall_s, rebuilds, route_changes, route, volume, level_db, gain_db}`), or `unplayed {id, reason,
  playback}` for a line that was not played to the end (`hang_up` before a `bye`, `cancelled`, `lost` when its
  audio was dropped, `dropped` with the link); `replayed {id}` says the user tapped Repeat.
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
- **Test alerts**: `POST /api/plugins/hermes_voice/devices/test {voip_token, alert_token, kind, delay_s}` pushes
  the same payload with `"test": true` and `"test_id"` under `hermes` to that phone, and answers `{ok, test_id,
  kind, status, code, message, delay_s, action}`; the app reads a delayed test's outcome with `GET
  …/devices/test/{test_id}`. A test alert's actions send no `request.answer`: the app confirms on the phone and
  posts `…/devices/test/{test_id}/answer {action}`.
- **Location**: the registration (`POST …/devices`) carries `location: {enabled, background}`. On a call the plugin
  sends `location_request {id}` on the call's socket and the app answers `location {id, latitude, longitude,
  accuracy_m, fixed_at, speed_mps?, course_deg?}` or `location {id, error}`. Otherwise it sends a background push
  `{"aps": {"content-available": 1}, "hermes": {kind: "location_request", request_id, profile}}` to the alert
  token, and the app posts the same answer with `request_id` and its tokens to `POST …/location`.

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
