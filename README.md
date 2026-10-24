# Hermes Voice

A small iPhone app for your own [Hermes Agent](https://github.com/NousResearch/hermes-agent), modelled on
[Hermes Conduit](https://github.com/kaishi00/hermes-conduit), with one feature at its center: **CallKit voice calls
inside a chat, where Hermes is heard only when it chooses to speak.**

- You start a call from any chat. The call is a real CallKit call (Dynamic Island, Lock Screen, keeps running
  while the phone is locked).
- Starting the call **announces it to Hermes** with a `[Voice call started]` message in that conversation.
- What you say is transcribed on the phone and posted to the same chat as `[Voice] …` messages.
- Hermes' normal replies stay **text only**. You hear Hermes only when it calls the **`speak` MCP tool**, which
  turns the text into speech with **ElevenLabs** on the Hermes host and streams it to the phone.
- Hanging up posts `[Voice call ended]`.

```
iPhone (HermesVoice)                          Hermes host (over Tailscale)
┌──────────────────────┐   cookie + WS RPC    ┌─────────────────────────────┐
│ chat, CallKit call   │ ───────────────────▶ │ hermes dashboard :9119       │
│ STT → "[Voice] …"    │                      │   └─ Hermes agent            │
│                      │                      │        │ MCP (streamable HTTP)│
│ plays PCM speech  ◀──┼── /phone WebSocket ──┼─ hermes-voice-mcp :8765      │
└──────────────────────┘                      │    speak → ElevenLabs API    │
                                              └─────────────────────────────┘
```

## Layout

| Path | What |
|---|---|
| [`HermesVoice/`](HermesVoice) | SwiftUI iOS app (iOS 17+), generated with XcodeGen from `project.yml` |
| [`hermes-voice-mcp/`](hermes-voice-mcp) | Python MCP server: the `speak` tool plus the phone's WebSocket |
| [`reference/`](reference) | Read-only clones of Hermes Conduit and its notifier plugin (MIT), used as protocol reference |

## Setup on the Hermes host

### 1. Let the phone sign in to the dashboard

The app signs in to the Hermes web dashboard with a username and password, like Conduit does. Your dashboard
currently uses only its built-in local session token, so add a sign-in to `~/.hermes/.env`:

```bash
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=me
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=a-strong-password
HERMES_DASHBOARD_BASIC_AUTH_SECRET=<output of: openssl rand -base64 32>
```

Expose the dashboard on your tailnet (keep it bound to 127.0.0.1):

```bash
tailscale serve --bg 9119
```

Tell the dashboard its public address. With a loopback bind, it rejects any other `Host` header unless the host is
listed here, so without this every request from the phone fails with `400 Invalid Host header`. Add to
`~/.hermes/config.yaml` the exact HTTPS origin that `tailscale serve` printed (no path, no port):

```yaml
dashboard:
  public_url: https://<machine>.<tailnet>.ts.net
```

Then restart the dashboard; it reads these settings once at startup. The dashboard address for the app is
`https://<machine>.<tailnet>.ts.net`.

### 2. ElevenLabs

Add your key to `~/.hermes/.env`:

```bash
ELEVENLABS_API_KEY=...
```

Optional: pick a voice. The server uses, in order, `HERMES_VOICE_VOICE_ID`, then `tts.elevenlabs.voice_id` from
`~/.hermes/config.yaml`, then Hermes' default voice. The model defaults to `eleven_flash_v2_5` (low latency,
multilingual); override it with `HERMES_VOICE_MODEL_ID` or `tts.elevenlabs.streaming_model_id`.

### 3. Run the voice server

```bash
cd hermes-voice-mcp
uv run hermes-voice-mcp
```

It listens on `127.0.0.1:8765`. It uses `HERMES_VOICE_TOKEN` if set, from `~/.hermes/.env` first and then the
environment, as Hermes does; otherwise on first start it creates a shared token in
`~/.hermes/hermes-voice/token`. Print it with:

```bash
uv run hermes-voice-mcp token
```

To keep it running across reboots on macOS, install the launchd agent with
`hermes-voice-mcp/launchd/install.sh` (it fills in your paths from `hermes-voice.plist.example`).

Expose it on your tailnet on its own HTTPS port:

```bash
tailscale serve --bg --https=8443 http://127.0.0.1:8765
```

The voice server address for the app is then `https://<machine>.<tailnet>.ts.net:8443`.

### 4. Connect Hermes to the MCP server

Put the token in `~/.hermes/.env` so Hermes and the server share it:

```bash
HERMES_VOICE_TOKEN=<the token from step 3>
```

Add the server to `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  hermes_voice:
    url: http://127.0.0.1:8765/mcp
    headers:
      Authorization: "Bearer ${HERMES_VOICE_TOKEN}"
```

Then run `/reload-mcp` in Hermes (or restart the gateway). Hermes now has the tool `mcp__hermes_voice__speak`.

## Building the app

```bash
cd HermesVoice
xcodegen generate
open HermesVoice.xcodeproj
```

Signing is personal, so it isn't in the repo. Copy `HermesVoice/Config/Local.xcconfig.example` to
`HermesVoice/Config/Local.xcconfig` (gitignored) and set your `BUNDLE_ID_PREFIX` and Apple `DEVELOPMENT_TEAM`;
the app's bundle id becomes `$(BUNDLE_ID_PREFIX).hermesvoice`.

The unit tests drive the gateway connection (reconnects, replay, server→client prompts) over a scripted socket:

```bash
xcodebuild test -project HermesVoice.xcodeproj -scheme HermesVoice -destination "platform=iOS Simulator,name=iPhone 17 Pro"
```

With [`devtools/fake_hermes.py`](devtools) running (`--port 9311 --reap-grace 1`), prefix the command with
`TEST_RUNNER_HERMES_FAKE_URL=http://127.0.0.1:9311 TEST_RUNNER_HERMES_FAKE_REAP_GRACE=1` to also run the end-to-end
tests against it.

Run it on a **real iPhone**: CallKit doesn't provide call audio in the
Simulator. The app falls back to a plain audio session there, so you can still test the screens.

In the app, enter:

- **Hermes dashboard**: the address from step 1, plus the username and password.
- **Hermes Voice server**: the address from step 3 and the token. The app checks both with the server before each
  call, and reports a wrong token or an unreachable server separately.

In **Settings** you can also pick the **speech language**. Automatic follows your iPhone's preferred languages, so
Swedish is recognized as Swedish.

## Using it

1. Open a chat (or start a new one) and tap the phone button.
2. The call connects, and Hermes gets the announcement with a `call_id`. It answers with a short spoken hello.
   The announcement and the end notice are queued, so they never interrupt a task Hermes is running.
3. Talk. After a short pause, what you said is posted as a `[Voice]` message. The mic is paused while Hermes is
   speaking, so it doesn't hear itself.
4. Text replies appear in the chat as usual. Rows marked 🔊 show what Hermes said out loud.
5. Tap **End** (or hang up from the Lock Screen or Dynamic Island).

## How the pieces talk

- **Dashboard**: `POST /auth/password-login` sets a cookie. `POST /api/auth/ws-ticket` returns a single-use ticket
  for `wss://…/api/ws?ticket=…`, which carries JSON-RPC: `session.resume`, `session.create`, `prompt.submit`, and
  streamed `message.*`, `tool.*` and `session.*` events. After a reconnect the app re-attaches each chat in use,
  on screen or in a call (`session.activate`, or `session.resume` when Hermes reaped it meanwhile), and replays
  what it missed (`session.events.since`). Other chats catch up when they are opened again. Approvals, questions
  and passwords arrive as server→client requests and are answered from the chat.
- **Voice server `/phone`**: the app sends `hello {call_id, session_id, title}` and gets `ready`. For each `speak`,
  the server sends `speech_start {id, text, sample_rate}`, then binary 16-bit PCM frames, then `speech_end {id}`.
  The app answers `played {id}` once it has been heard, and that is when the tool returns to Hermes. A stopped or
  failed `speak` ends with `speech_end {id, cancelled}` or `{id, error}` instead, and the app drops the rest at once.
- **Routing**: Hermes doesn't tell MCP servers which chat a tool call came from. So the announcement gives Hermes a
  random 32-character `call_id`, and `speak` must pass it back. An unknown or ended `call_id` is refused, never
  routed to some other call. Other Hermes sessions (cron jobs, other chats) can't talk into your call because
  they never see the id.

## Limits

- Half duplex: you can't talk over Hermes. The mic resumes when its speech finishes.
- Speech recognition uses your preferred languages (or the one picked in Settings), on-device when the iPhone has
  that language's model; otherwise Apple's servers transcribe the call, and the call screen says so.
- Calls are started from the phone only. Hermes ringing you would need PushKit and an APNs key.

## Credits

Built after studying Hermes Conduit by kaishi00 and its notifier plugin, both MIT-licensed (see `reference/*/LICENSE`).
The code here is new, but its dashboard protocol knowledge comes from those projects.
