# devtools

## `fake_hermes.py`: a fake Hermes dashboard for end-to-end tests

A small stand-in for the Hermes web dashboard (port 9119) that speaks exactly the parts the HermesVoice app
uses. The shapes come from the Hermes source: cookie sign-in, the session list, stored messages, WebSocket
tickets, and the `/api/ws` JSON-RPC gateway with its events. Its "agent" is scripted and really calls the
voice server's `speak` tool over MCP. That lets you test a whole call in the iOS Simulator without a real
Hermes, a model or ElevenLabs. It also does what the app has to handle when the connection drops:
event replay, detached sessions that get reaped, and server→client requests such as approvals.
Everything is kept in memory, and nothing touches `~/.hermes`.

| Prompt | Fake agent |
|---|---|
| `[Voice call started] call_id: <32 hex> …` | `tool.start` for `mcp__hermes_voice__speak` with `{text, call_id}`. Calls `speak("Hi, I am fake Hermes. I can hear you.")` on the voice server and waits for the result, then `tool.complete`. Then it streams the text reply `Call connected (text only).` |
| `[Voice] <words>` | `speak("You said: <words>")`, then the same line as text |
| `[Voice call ended] …` | text `Call ended.`, with no speak |
| text containing `approve` | `tool.start` for `terminal`, then an `approval` request `{command, description, choices, request_id, …}`. The reply says which choice came back, or that nobody could answer |
| text containing `clarify` | a `clarify` request with three questions (single choice, multi-select, open-ended), then the answers |
| text containing `secret` | a `secret` request `{env_var, prompt}` (300 s deadline). The value is never echoed or logged, only its length |
| text containing `sudo` | a `sudo` request `{command}` (120 s deadline) inside a `terminal` tool call |
| text containing `window` | a window-owned `window.read` request (30 s deadline), the one to test 4404 declines with |
| anything else | text `Echo: <prompt>` |

Each turn streams in about 0.3 s: `message.start` → `message.delta`… → `message.complete` →
`session.info {running: false}`. A new chat also gets `session.title` after its first turn. Prompts sent
while a turn runs are handled like Hermes handles them:

- With `queued: true`, the prompt is queued. Queued text prompts merge into one slot and run after the turn.
- Without it, the running turn is interrupted and the prompt is queued.
- `session.interrupt` stops the turn and drops the queue.

The stored transcript keeps assistant rows with `tool_calls`, so reopening a chat shows its 🔊 rows.

### Run it for a Simulator test

The fake uses the `hermes-voice-mcp` venv, so you don't need to install anything. Calls go through its fake
`hermes_voice` plugin (below), so the fake alone is enough for the current app:

```bash
cd hermes-voice-mcp
uv run python ../devtools/fake_hermes.py --port 9311
```

In the app (the Simulator shares the Mac's loopback), sign in to **Hermes dashboard** `http://127.0.0.1:9311` with
username `test` and password `test`.

Legacy: the `[Voice call started] call_id: …` / `speak` demo of earlier app builds also needs the MCP voice server,
started first with fake TTS (tones), a throwaway HERMES_HOME and a known token:

```bash
cd hermes-voice-mcp
HERMES_VOICE_FAKE_TTS=1 HERMES_VOICE_TOKEN=devtoken HERMES_HOME=$(mktemp -d) \
  uv run hermes-voice-mcp --port 8765
uv run python ../devtools/fake_hermes.py --port 9311 --voice-url http://127.0.0.1:8765 --voice-token devtoken
```

The fake prints every RPC, every event and every `speak` result with the prefix `FAKE`, for example
`FAKE 20:02:30 speak result (0.4s, ok): Spoken to the user (2.1s of audio).` Stop both with Ctrl-C.

Options: `--host` (default `127.0.0.1`; use `0.0.0.0` or the Tailscale IP to test from a real iPhone),
`--username` and `--password` (default `test`/`test`), `--speak-timeout` (default 300 s), `--reap-grace`
(default 20 s, `0` keeps detached sessions forever), `--replay-max` (default 512 events per session) and
`--contract` (default `HermesVoice/Contract/gateway-contract.openrpc.json`, `''` turns the param check off).
The token can also come from `HERMES_VOICE_TOKEN`.

Use a short grace to test what happens when the app was backgrounded for too long, for example
`--reap-grace 3`: background the app, wait, come back, and the app has to fall back from `session.activate`
(4001) to `session.resume`.

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
- `WS /api/ws?ticket=…` sends `gateway.ready {skin, change_events, heartbeat: true, replay_epoch}` first. A bad
  ticket closes the socket with 4401 before accepting it. Supported methods:
  - `gateway.ping`, `ping`
  - `client.capabilities {server_requests: true}` returns `{server_requests: [13 methods], declines_not_shown:
    true}`. Without it the connection counts as an app that can't answer server requests: they aren't sent,
    and an approval is withdrawn at once instead of stalling the turn.
  - `session.create`, with `idempotency_key` (a repeated key returns the same session but doesn't bind the
    new socket, as in Hermes)
  - `session.resume`, with `omit_messages`. Takes the stored id and returns the runtime `session_id`, the stored
    key as `session_key`, plus `running`, `status`, `inflight`, `queued`, `pending_approval` and
    `open_requests` when they are set. A live session is re-attached; otherwise a new runtime id is minted. A
    minted key that has no row yet (a draft reaped before its first prompt) gets an empty row, as in Hermes, and
    any other unknown id gets 4007.
  - `session.activate {session_id: <runtime id>}` re-attaches a live session to this socket and returns the
    same payload. A runtime id that is gone (reaped, or never existed) gets `4001 session not found`, as from
    Hermes; Hermes answers 4007 only when a reap races the call.
  - `session.events.since {session_id, last_seen}` returns `{events, latest_seq, truncated, count, epoch,
    open_requests}`. `truncated` is true when events after `last_seen` fell out of the ring.
  - `prompt.submit`, which returns `{status: "streaming" | "queued"}`. With `truncate_before_row_id` and
    `confirm_truncate` it is a rewind: that prompt row and everything after it are dropped before the text runs
    (4009 while a turn runs, 4029 without `confirm_truncate`).
  - `session.interrupt`, which also withdraws the session's open requests
  - `session.close`, which ends the runtime with its turn and open requests. `DELETE /api/sessions/:id` removes
    only the stored rows (409 while a turn runs), as in Hermes.
  - `approval.respond {session_id, choice, all?, request_id?}` returns `{resolved}`. It also finds the approval by
    `request_id` or a stored session id when the runtime id is stale.
  - `request.answer {id, result}` and `clarify.lock {request_id, question_id, answer}` return `{status: "ok" |
    "expired"}`.

  Unknown methods get `-32601`, and params with a key the contract doesn't know get `4000`. Events are framed as
  `{"method": "event", "params": {type, session_id: <runtime id>, seq, payload}}`. `seq` counts per session
  from 1, and the last 512 events per session are kept for `session.events.since`, including the events sent
  while no client was attached. `epoch` is the `replay_epoch` of this process: a restarted fake starts over
  with a new one. Session-less broadcasts (`session.reclaimed`) have `session_id: ""` and no `seq`.

### The fake `hermes_voice` plugin

`fake_voice_plugin.py` is always mounted: the plugin's routes under `/api/plugins/hermes_voice/` (`WS /phone`,
`POST /devices`, `POST /scribe-token` with a dummy token, `GET /status` with `tts: "fake"`) and its call model (one
call slot, ring / answer / decline, sync and async `start_call`, injected `[Voice] …` turns and notices, with the
texts of `hermes-voice-plugin/inject.py`). Speech is a tone per word. Typing `call me sync: <text>` or
`call me async: <text>` in a chat makes the fake agent call `start_call`; `hang up` calls `end_call`.

Nothing is pushed: `POST /api/plugins/hermes_voice/debug/ring {session_id, mode, text}` rings any session and
returns the VoIP push payload, `GET …/debug/pushes` lists them. A debug build of the app takes the payload as a
push with `xcrun simctl openurl booted "hermesvoice://ring?call_id=<hex>&session_id=<id>&mode=sync"` (it rings
inside the app; answer from the call panel). The module docstring has a curl recipe; `--call-ring-timeout` and
`--call-drop-retention` shorten the timers.

Devices may also register an APNs `alert_token` with `alerts: {approval, clarify, turn_done}` (bad shapes get
`422`); `GET /status` lists them, and `GET …/debug/alerts?session_id=…&kind=approval|clarify|turn_done` returns the
`{aps, hermes}` notification the plugin would push, the alert tokens it would go to, and the history.

### Settings screens (M3)

The Settings, Profiles and Providers screens have their routes here too, each honouring `?profile=`: the config
schema, `GET`/`PUT /api/config`, the `/api/model/*` routes, the memory provider config, `/api/env` (masked values
only; `POST /api/providers/validate` rejects keys starting with `bad`), provider sign-in by device code (approved
after `--oauth-approve-after` seconds; a user code starting with `DENY` is denied), profile
create/rename/delete/default/export/import and SOUL.md, `/api/status`, and the `vault.*` and `billing.*` RPCs (any
master password unlocks except `wrong`). The module docstring lists every route. API keys, vault secrets and
passwords are never logged. Unlike Hermes, `PUT /api/config` refuses a value whose type doesn't match its schema
field, with `400`. Custom endpoints (`/api/providers/custom-endpoints`) aren't served yet.

### Capabilities, cron, command center and artifacts (M4)

The M4 screens have their routes here too, each honouring `?profile=` with its own state per profile. The shapes
come from `hermes_cli/web_routers/{skills,tools,mcp,cron,ops,status,analytics,actions,files}.py` and
`plugins.manage` in `tui_gateway/methods_tools.py`; each handler names its source.

- **Skills**: `GET /api/skills`, `PUT /api/skills/toggle`, `GET`/`PUT /api/skills/content`, `POST /api/skills`
  (the same name, category and frontmatter checks as Hermes), plus the official hub catalog
  (`/api/skills/hub/official`, `preview`, `install`, `uninstall`, `update`).
- **Toolsets**: `GET /api/tools/toolsets` (the voice toolsets `tts` and `stt` are listed; the app strips them),
  `PUT /{name}`, `/config` (providers with `ready` / `needs_keys` / `needs_auth` / `needs_setup`), `/models`,
  `/model`, `/provider` (web picks a backend per capability), `/env` (declared keys only, into `.env`),
  `/post-setup`, and `GET`/`PUT /api/tools/terminal/backend(s)` (writes `terminal.backend`).
- **MCP**: `GET`/`POST`/`PUT /api/mcp/servers`, `DELETE /{name}`, `PUT /{name}/enabled`, `POST /{name}/test`
  (an `auth: oauth` server needs a token first; a URL or command with `offline` in it fails to connect),
  `POST /{name}/auth` + `GET`/`DELETE /api/mcp/oauth/flows/{id}`, and `GET`/`POST /api/mcp/catalog(/install)`.
  The servers live in the profile's config (`mcp_servers` in `GET /api/config`), like in Hermes. An OAuth flow
  approves itself after `--mcp-oauth-approve-after` seconds (default 2, `0` = never). It also completes through
  its `authorization_url`, which is the fake's own consent page (Approve / Deny), or through the debug trigger
  `POST /api/mcp/oauth/flows/{id}/debug {outcome: "approve" | "deny"}`.
- **Plugins**: the gateway RPC `plugins.manage` with `list`, `toggle`, `install` (a `catalog_name` or a git
  repo), `update` (one update asks for consent first), `remove` and `settings`. An enabled plugin can add a
  toolset or an MCP server (`source: "plugin"`, read-only).
- **Cron**: jobs CRUD, `runs`, `pause`, `resume`, `trigger`, `delivery-targets`, `blueprints` and
  `blueprints/instantiate`, with the schedule parser of `cron/jobs.py` (`30m`, `every 2h`, `in 45m`,
  `weekdays at 9am`, five-field cron, ISO time). A triggered agent job leaves a `source: cron` chat that the run
  row points at. `POST /api/cron/fire` takes `Authorization: Bearer <--cron-fire-token>`.
- **Command center**: `GET /api/health` (public), `/api/system/stats`, `/api/logs` (file, level, component and
  search filters), `/api/analytics/usage` and `/models`, `/api/curator` (+ `paused`, `run`), and the maintenance
  actions `POST /api/ops/doctor`, `security-audit`, `backup` (+ `GET /api/ops/backup/download?archive=` once it's
  done), `debug-share`, `GET /api/ops/checkpoints` + `POST …/prune`, `POST /api/gateway/restart`, and
  `GET /api/hermes/update/check` + `POST /api/hermes/update`. Curator runs and checkpoint prunes need an explicit
  `?profile=` (400 otherwise), as on a multi-profile Hermes.
- **Actions**: every background action is tailed with `GET /api/actions/{name}/status`. Each poll shows more of
  its log, and the `--action-polls`-th poll (default 3) finishes it with its exit code. An action nobody polls
  finishes after `--action-seconds` (default 6, `0` = only by polls). What it changes (a new skill or server, the
  archive, pruned checkpoints, the update) happens when it finishes.
- **Artifacts**: the screen reads chats, so `--seed full` adds chats whose messages carry an image (`MEDIA:`),
  files (a PDF and a CSV, also in a `write_file` result) and links. `GET /api/fs/read-data-url` and
  `/api/fs/download` serve those files, and `GET /api/media/proxy` serves the one remote image (from memory; the
  fake never goes online).

`--seed` picks the data: `full` (the default) is `demo` plus the artifact chats and one chat per past cron run.
`demo` seeds both profiles with skills, MCP servers, plugins, cron jobs (one paused, one failing), checkpoints
and 90 days of usage, without new chats. `minimal` has none of it, to see the empty states. `/api/audio/*` is
never served. Keys and tokens typed into these routes go to the profile's `.env` or config only and are never
logged.

### Detached sessions

When the last socket of a session closes, the session keeps running with nobody attached, and its turn
continues. After `--reap-grace` seconds without a client, an idle session is reaped and every connected client
gets `session.reclaimed {session_id, stored_session_id, reason: "ws_orphan_reap"}`. A running session (also one
waiting on an approval) is checked again after each grace. `session.activate`, `session.resume` and
`prompt.submit` re-attach the session and cancel the reap.

### Server→client requests

The fake sends requests like Hermes does: `{"jsonrpc": "2.0", "id": "srq-<12 hex>", "method", "params":
{session_id, …}}` goes to every socket attached to the session. The app answers with a response frame carrying
the same id:

- `{result}` settles the request. Clarify answers merge with the ones already locked with `clarify.lock`.
- `{error: {code: 4404}}` is a "not shown here" decline. It settles the request only once every attached
  client that sent `client.capabilities` has declined. The result is then Hermes' "No Hermes Desktop window"
  refusal.
- Any other error (such as `-32601`) settles it as unanswered. For an approval that means it is withdrawn,
  not denied.
- A response for an id that is no longer open is dropped without a reply.

A request that nobody answered stays open across reconnects. It comes back in `open_requests` from
`session.resume`, `session.activate` and `session.events.since`. A request is withdrawn with a `request.cancel
{id, method, reason}` event when the turn is interrupted (`interrupted`), when its deadline passes (`timeout`),
or when `approval.respond` resolved the approval (`resolved`).

### Tests

```bash
cd hermes-voice-mcp
uv run pytest -q ../devtools/tests
```

The tests start the fake in-process. `test_fake_hermes_m4.py` covers the M4 routes and `plugins.manage`; the
others cover sign-in and streaming, reconnect plus replay (also truncated),
reaping and `session.activate` after a reap, resuming a reaped draft, approvals across a reconnect,
`approval.respond`, 4404 declines, clients that can't answer, clarify locks, secrets, interrupt and timeout
cancels, and the speak demo against an in-process voice server. One test checks every result, event and request
against the pinned gateway contract. It is skipped when there's no contract; `HERMES_GATEWAY_CONTRACT=<path>`
checks against another copy.

`record_fixtures.py` records the frames the app's `GatewayFixtureTests` decode
(`HermesVoice/HermesVoiceTests/Fixtures/*.json`): `uv run python ../devtools/record_fixtures.py` from
`hermes-voice-mcp` runs a scenario against an in-process fake. With `--url` it records a throwaway
`hermes serve --isolated` instead; the script's docstring says how to start one.
