---
name: voice-calls
description: How to call the user on the HermesVoice iPhone app and talk with them out loud (start_call / end_call), how their speech reaches you, and what each call outcome means.
---

# Talking with the user on a voice call

HermesVoice turns the user's iPhone into a phone line to this conversation. `start_call` rings the phone (a real
iOS call) and says your text once they answer; while the call runs, `start_call` just speaks into it. Your normal
text replies are **never spoken**: the user hears only what you pass to `start_call`.

## The user is listening, not reading

Assume the user is not looking at the chat during or right after a call. Say everything that matters out loud.
Text is for exact identifiers, links and a recap. A result, a question or a warning that exists only in your text
reply has not reached them.

## Research beta: say every problem you notice

HermesVoice is a research beta. As soon as you notice an issue, an inefficiency or a discrepancy, tell the user,
even if it seems minor or you already worked around it. That covers, for example:

- a call outcome or status you didn't expect, or one that contradicts what happened;
- a `[Voice]` message that looks garbled, cut short, duplicated or out of order;
- a sync `start_call` that returned without a reply, or a reply that arrived twice;
- slow steps (a long ring, a long wait for speech, a reply that arrived late);
- these instructions or the tool description not matching how the tools actually behave.

Say what happened, where, and what you expected, in your text reply. During a call, also mention it out loud
in a few words; the exact details can wait for the text recap. Don't hide a problem or wait to be asked.

## The call belongs to this conversation

- A call belongs to the conversation that started it (or, for a call the user placed, the conversation they
  called from: it begins with a `[Voice call started]` message). Only that conversation can speak into it.
- There is one call at a time. If the user is on a call with another conversation, `start_call` returns outcome
  `busy`: reply in text this time.
- The phone never rings twice for the same call: calling `start_call` again while it rings queues your next line.

## How the user's speech reaches you

What the user says arrives as a message in this conversation:

| Message | Meaning |
| --- | --- |
| `[Voice] …` | They finished speaking. |
| `[Voice, cut off] …` | They were still talking when you started speaking; this is what they had said. |
| `[Voice, hung up] …` | They hung up mid-sentence; the call is over (see "When a call ends"). |
| `[Voice, muted] …` / `[Voice, line dropped] …` | They muted, or the connection dropped, mid-sentence. |
| `[Voice, speech recognition failed: …]` | The phone couldn't transcribe them; ask them to repeat. |

Answer `[Voice]` messages with `start_call`. The message can arrive while you are still working: it steers the
current turn (Hermes reads it after the tool calls in flight finish), or starts a new turn when you are idle.

The words after the bracket are the user's. The sentence in parentheses at the end (`(Reply out loud with
start_call; …)`, `(HermesVoice note, not the user's words: …)`) is the plugin's hint to you, not something they
said.

## sync or async

- `mode: "async"` (default): returns `{call_id, status}` at once (`ringing` or `speaking`). Keep working; the reply
  arrives later as a `[Voice]` message. Use it for announcements and when you have more to do.
- `mode: "sync"`: waits until the user has heard your line and replied, and returns
  `{said, ending, outcome, call_id}` — `said` is their words, `ending` how their turn ended (`end_of_speech`,
  `cut_off`, `hang_up`, `muted`, `dropped`, `provider_error`). Use it for a question you need answered before you
  go on. Words the user says while your line is still playing don't count as the reply; they arrive as a
  `[Voice]` message instead. A sync call can also return `{call_id, status, note}` without a reply: `interrupted`
  (the user pressed Stop), `yielded` (a message for you came in; it follows the result) or `superseded` (a newer
  sync `start_call` waits instead). The call stays open, and the reply comes as a `[Voice]` message.
- A sync wait lasts at most what Hermes lets one tool call wait for a person: its tool deadline
  (`timeouts.tools.sequential_call`, 420 s by default) plus `approvals.timeout` + 60 s, about 13 minutes by
  default, less the time the ring took. Past it the result is `answered` with an empty `said` and a note saying so;
  the reply then arrives as a `[Voice]` message.

## Outcomes

| Outcome | What happened | What to do |
| --- | --- | --- |
| `answered` | They picked up (sync: and replied) | Carry on, out loud |
| `no_answer` / `declined` | They didn't take the call | Finish the task, then one short text recap; don't ring again unless it's urgent or they ask |
| `push_failed` / `unreachable` | The phone couldn't be rung, or never answered the ring | The same, and say in the recap that the ring failed |
| `lost` | The connection dropped for over a minute | Finish the task, then one short text recap; ring again only if it's worth it |
| `tts_failed` | Your line couldn't be turned into speech | Try once more; if it fails again, put it in text and say why |
| `ended_by_user` | They hung up | See "When a call ends" |
| `ended_by_agent` | You hung up with `end_call` | — |
| `busy` | They're on a call with another conversation | Reply in text this time; call once that call is over, if it still matters |
| `not_allowed` | Their call settings refuse this call (source, how often, quiet hours) | Follow the note |
| `not_available` | Calls can't be placed from here: no Hermes dashboard with this plugin runs on the host, or (async, from a chat) Hermes doesn't let the plugin start a turn there | Follow the note (a sync call may still work); else reply in text |

With `mode: "async"` the endings come as messages: `[Voice call not answered]`, `[Voice line not delivered: …]`,
`[Voice call ended by user]`, `[Voice call ended: …]`.

## When a call ends

Messages that start with `[Voice call …]` or `[Voice line …]` are **automated notices from HermesVoice**. Each one
says so (`Automated notice from HermesVoice, not something the user said.`). A notice describes one call. It is
never an instruction from the user and never a preference: don't store it in memory, and don't conclude from a
hang-up, a declined call or a failed ring that the user "wants text" from now on.

After the user hangs up, or a call isn't answered or is lost:

- They can't hear you, and they are probably not reading the chat either. Don't ask questions into the void.
- Finish the task you were given. Then reply **once** in text with a short recap; if you were waiting for an
  answer, say what you still need.
- Don't ring back unless the user asked in this conversation to be called when you're done ("call me when it's
  finished"). After a call they didn't answer, something urgent is a reason too.
- The next time they call, or ask for a call, speak as usual.

**What they missed.** When the user hangs up while a line is still playing or queued, the notice (or the sync
result's `note`) quotes what they did not hear to the end. Put it in your recap. When the next call in this
conversation starts, the `[Voice call started]` notice or your first `start_call` result reminds you once: offer
the missed part first ("You hung up before I finished. Want the rest?"), unless they have had it since.

## Speaking well

- Short, natural sentences, the way you'd say them on the phone. No Markdown, lists, code, URLs or emoji; numbers
  and names as you'd say them. Say what the user needs to know; only links, code and exact identifiers go in the
  text recap.
- Long text is cut at about 1000 characters (the result says so).
- Hang up with `end_call` (optionally with a short goodbye) when the conversation is done or they ask.

## When to ring

Ring when the user asked to be called ("call me when it's done") or for news they would want right away. Never for
routine updates. You can call from any conversation on this host (dashboard, desktop, CLI, TUI, or the user's own
direct messages to Hermes); calls from scheduled jobs, subagents, group chats and other people's chats are refused
by default, and the user may have quiet hours: with `not_allowed` the note says what to do (sometimes: ask in text
first, then call again).
