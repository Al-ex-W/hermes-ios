# hermes-voice-mcp

The host half of [Hermes Voice](../README.md): an MCP server whose `speak` tool is the only way Hermes is heard during a
HermesVoice call. It runs ElevenLabs text-to-speech on this host and streams 24 kHz 16-bit PCM to the phone.

```bash
uv run hermes-voice-mcp            # serve on 127.0.0.1:8765
uv run hermes-voice-mcp token      # print the token the server uses
uv run pytest -q tests             # end-to-end tests with fake TTS
```

| Route | Who | What |
|---|---|---|
| `/mcp` | Hermes | Streamable-HTTP MCP with one tool, `speak(text, call_id, voice_id?)` (Hermes calls it `mcp__hermes_voice__speak`) |
| `/phone` | iPhone app | WebSocket for the length of a call |
| `/status` | app preflight, you | `{"calls": <connected calls>, "tts": "elevenlabs" or "fake"}` |
| `/health` | anyone | `ok` |

Every route except `/health` requires `Authorization: Bearer <token>`. A token in the query string is never accepted.
To check by hand: `curl -H "Authorization: Bearer $(uv run hermes-voice-mcp token)" http://127.0.0.1:8765/status`.

## speak

`call_id` is required. It is the 32-hex-character id the app puts in the `[Voice call started]` message, so only that
conversation can talk into the call. An unknown or ended `call_id` returns an error telling Hermes to reply in text;
`speak` never falls back to another call. Text longer than `HERMES_VOICE_MAX_CHARS` is cut and the result says so.
`speak` returns once the phone reports the audio was played, or says why not (call ended, playback not confirmed).
If Hermes cancels the call (Stop, interrupt, timeout), the phone is told to drop the utterance's audio.

## Phone protocol

- phone `{"type": "hello", "call_id", "session_id"?, "title"}`, server `{"type": "ready", "call_id"}`
- server `{"type": "speech_start", "id", "text", "sample_rate", "format": "pcm_s16le"}`, binary PCM frames, then
  `{"type": "speech_end", "id"}`, or `{"type": "speech_end", "id", "cancelled": true}` when the speak was cancelled,
  or `{"type": "speech_end", "id", "error"}` when it failed; after a normal end the phone sends `{"type": "played", "id"}`
  once the audio has been heard
- phone `{"type": "ping"}`, server `{"type": "pong"}`; phone `{"type": "bye"}` on hang-up
- close codes: 4401 wrong token, 4400 bad hello, 4409 replaced by a newer connection with the same `call_id`,
  1011 the connection stopped taking frames (including a final `speech_end`), so the phone reconnects

A reconnect with the same `call_id` takes over the call, including a `speak` waiting for `played`. A connection that
drops without `bye` is kept for 60 s with its pending acks, and a `hello` with the same `call_id` resumes the call even
after that; only `bye` ends it. Each `speak` waits up to 6 s for a reconnect before it reports that the phone is not
connected.

## Settings

Read from the environment, then `~/.hermes/.env`, then `~/.hermes/config.yaml` (`tts.elevenlabs.*`), except
`HERMES_VOICE_TOKEN`, where `~/.hermes/.env` wins over the environment as it does in Hermes:

| Variable | Default |
|---|---|
| `ELEVENLABS_API_KEY` | required |
| `HERMES_VOICE_TOKEN` | generated into `~/.hermes/hermes-voice/token` |
| `HERMES_VOICE_VOICE_ID` | `tts.elevenlabs.voice_id`, else `pNInz6obpgDQGcFmaJgB` |
| `HERMES_VOICE_MODEL_ID` | `tts.elevenlabs.streaming_model_id`, else `eleven_flash_v2_5` |
| `ELEVENLABS_BASE_URL` | `tts.elevenlabs.base_url`, else `https://api.elevenlabs.io` |
| `HERMES_VOICE_HOST` / `HERMES_VOICE_PORT` | `127.0.0.1` / `8765` |
| `HERMES_VOICE_MAX_CHARS` | `1000` per utterance |
| `HERMES_VOICE_FAKE_TTS=1` | tones instead of ElevenLabs, for testing |

Setting `HERMES_VOICE_TOKEN` in `~/.hermes/.env` is the simplest setup: Hermes reads the same file when it fills in
`Bearer ${HERMES_VOICE_TOKEN}` for its MCP headers, so both sides agree. Hermes loads that file over its own
environment, so the server does too: a value in `.env` wins over an exported `HERMES_VOICE_TOKEN`, and the server logs
a warning when the two differ. It logs where its token came from at startup. Settings are read once, so restart the server after changing them
(`launchctl kickstart -k gui/$(id -u)/io.github.hermes-ios.voice` with the launchd agent).
