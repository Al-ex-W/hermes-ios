# devtools

## `fake_hermes.py`: a fake Hermes dashboard for end-to-end tests

A small stand-in for the Hermes web dashboard (port 9119) that speaks exactly the parts the HermesVoice app
uses. The shapes come from the Hermes source: cookie sign-in, the session list, stored messages, WebSocket
tickets, and the `/api/ws` JSON-RPC gateway with its events. Its "agent" is scripted and really calls the
voice server's `speak` tool over MCP. That lets you test a whole call in the iOS Simulator without a real
Hermes, a model or ElevenLabs. Everything is kept in memory, and nothing touches `~/.hermes`.

| Prompt | Fake agent |
|---|---|
| `[Voice call started] call_id: <32 hex> …` | `tool.start` for `mcp__hermes_voice__speak` with `{text, call_id}`. Calls `speak("Hi, I am fake Hermes. I can hear you.")` on the voice server and waits for the result, then `tool.complete`. Then it streams the text reply `Call connected (text only).` |
| `[Voice] <words>` | `speak("You said: <words>")`, then the same line as text |
| `[Voice call ended] …` | text `Call ended.`, with no speak |
| anything else | text `Echo: <prompt>` |

Each turn streams in about 0.3 s: `message.start` → `message.delta`… → `message.complete` →
`session.info {running: false}`. A new chat also gets `session.title` after its first turn. Prompts sent
while a turn runs are handled like Hermes handles them:

- With `queued: true`, the prompt is queued. Queued text prompts merge into one slot and run after the turn.
- Without it, the running turn is interrupted and the prompt is queued.
- `session.interrupt` stops the turn and drops the queue.

The stored transcript keeps assistant rows with `tool_calls`, so reopening a chat shows its 🔊 rows.

### Run it for a Simulator test

Use two terminals. Both commands use the `hermes-voice-mcp` venv, so you don't need to install anything.

```bash
# 1. Voice server with fake TTS (tones), a throwaway HERMES_HOME and a known token
cd hermes-voice-mcp
HERMES_VOICE_FAKE_TTS=1 HERMES_VOICE_TOKEN=devtoken HERMES_HOME=$(mktemp -d) \
  uv run hermes-voice-mcp --port 8765

# 2. Fake Hermes dashboard
cd hermes-voice-mcp
uv run python ../devtools/fake_hermes.py --port 9311 --voice-url http://127.0.0.1:8765 --voice-token devtoken
```

In the app (the Simulator shares the Mac's loopback):

- **Hermes dashboard**: `http://127.0.0.1:9311`, username `test`, password `test`
- **Hermes Voice server**: `http://127.0.0.1:8765`, token `devtoken`

The fake prints every RPC, every event and every `speak` result with the prefix `FAKE`, for example
`FAKE 20:02:30 speak result (0.4s, ok): Spoken to the user (2.1s of audio).` Stop both with Ctrl-C.

Options: `--host` (default `127.0.0.1`; use `0.0.0.0` or the Tailscale IP to test from a real iPhone),
`--username` and `--password` (default `test`/`test`), and `--speak-timeout` (default 300 s). The token can
also come from `HERMES_VOICE_TOKEN`.

### What it implements

- `POST /auth/password-login` `{provider: "basic", username, password}` returns `{ok, next}` and sets the
  HttpOnly cookie `hermes_session_at`. Wrong credentials get 401, and an unknown provider gets 404.
- `POST /auth/logout` clears the cookies and redirects (302) to `/login`.
- `POST /api/auth/ws-ticket` returns `{ticket, ttl_seconds: 30}`. A ticket works for one connection only.
- `GET /api/profiles/sessions` returns `{sessions: [{id, title, preview, last_active, message_count, profile,
  hidden: false, …}], total, …}`. A draft only appears once it has a prompt.
- `GET /api/sessions/{id}/messages` returns `{session_id, profile, messages: [{id, role, content,
  display_kind, tool_calls, …}], pagination}`. A draft with no prompt yet gets 404.
- Any unauthenticated `/api/*` call gets Hermes' 401 envelope `{error: "unauthenticated", …}`. A `POST`
  whose `Origin` doesn't match its `Host` gets 403.
- `WS /api/ws?ticket=…` sends `gateway.ready` first. A bad ticket closes the socket with 4401 before
  accepting it. Supported methods:
  - `gateway.ping`, `ping`, `client.capabilities`
  - `session.create`, with `idempotency_key` (a repeated key returns the same session)
  - `session.resume`, with `omit_messages`. It returns the runtime `session_id`, the stored key as `session_key`
    and `stored_session_id`, plus `running`, `inflight` and `queued`.
  - `prompt.submit`, which returns `{status: "streaming" | "queued"}`
  - `session.interrupt`

  Unknown methods get `-32601`. Events are framed as
  `{"method": "event", "params": {type, session_id: <runtime id>, payload}}`.
