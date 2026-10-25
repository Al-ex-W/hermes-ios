---
name: voice-calls
description: How to call the user on the HermesVoice iPhone app and talk with them out loud (start_call / end_call), how their speech reaches you, and what each call outcome means.
---

# Talking with the user on a voice call

HermesVoice turns the user's iPhone into a phone line to this conversation. `start_call` rings the phone (a real
iOS call) and says your text once they answer; while the call runs, `start_call` just speaks into it. Your normal
text replies are **never spoken**: the user hears only what you pass to `start_call`.

## The call belongs to this conversation

- A call belongs to the conversation that started it (or, for a call the user placed, the conversation they
  called from: it begins with a `[Voice call started]` message). Only that conversation can speak into it.
- There is one call at a time. If the user is on a call with another conversation, `start_call` returns outcome
  `busy`: reply in text.
- The phone never rings twice for the same call: calling `start_call` again while it rings queues your next line.

## How the user's speech reaches you

What the user says arrives as a message in this conversation:

| Message | Meaning |
| --- | --- |
| `[Voice] …` | They finished speaking. |
| `[Voice, cut off] …` | They were still talking when you started speaking; this is what they had said. |
| `[Voice, hung up] …` | They hung up mid-sentence; the call is over. Reply in text. |
| `[Voice, muted] …` / `[Voice, line dropped] …` | They muted, or the connection dropped, mid-sentence. |
| `[Voice, speech recognition failed: …]` | The phone couldn't transcribe them; ask them to repeat. |

Answer `[Voice]` messages with `start_call`. The message can arrive while you are still working: it steers the
current turn (Hermes reads it after the tool calls in flight finish), or starts a new turn when you are idle.

## sync or async

- `mode: "async"` (default): returns `{call_id, status}` at once (`ringing` or `speaking`). Keep working; the reply
  arrives later as a `[Voice]` message. Use it for announcements and when you have more to do.
- `mode: "sync"`: waits until the user has heard your line and replied, and returns
  `{said, ending, outcome, call_id}` — `said` is their words, `ending` how their turn ended (`end_of_speech`,
  `cut_off`, `hang_up`, `muted`, `dropped`, `provider_error`). Use it for a question you need answered before you
  go on. Words the user says while your line is still playing don't count as the reply; they arrive as a
  `[Voice]` message instead.

## Outcomes

| Outcome | What happened | What to do |
| --- | --- | --- |
| `answered` | They picked up (sync: and replied) | Carry on |
| `no_answer` / `declined` | They didn't take the call | Reply in text; don't ring again unless it's urgent or they asked |
| `push_failed` / `unreachable` | The phone couldn't be rung, or never answered the ring | Reply in text |
| `lost` | The connection dropped for over a minute | Reply in text |
| `tts_failed` | Your line couldn't be turned into speech | Reply in text; say why if it keeps happening |
| `ended_by_user` | They hung up | Reply in text from now on |
| `ended_by_agent` | You hung up with `end_call` | — |
| `busy` | They're on a call with another conversation | Reply in text |
| `not_allowed` | Their call settings refuse this call (source, how often, quiet hours) | Follow the note |

With `mode: "async"` the endings come as messages: `[Voice call not answered]`, `[Voice line not delivered: …]`,
`[Voice call ended by user]`, `[Voice call ended: …]`.

## Speaking well

- Short, natural sentences, the way you'd say them on the phone. No Markdown, lists, code, URLs or emoji; numbers
  and names as you'd say them. Put details, links and code in your text reply.
- Long text is cut at about 1000 characters (the result says so).
- Hang up with `end_call` (optionally with a short goodbye) when the conversation is done or they ask.

## When to ring

Ring when the user asked to be called ("call me when it's done") or for news they would want right away. Never for
routine updates. Calls from scheduled jobs, subagents and group chats are refused by default, and the user may
have quiet hours: with `not_allowed` the note says what to do (sometimes: ask in text first, then call again).
