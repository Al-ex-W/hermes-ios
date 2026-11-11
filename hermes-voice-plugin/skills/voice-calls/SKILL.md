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
| `[Voice, cut off] …` | They were still talking, or pausing to think, when you started speaking; this is what they had said. |
| `[Voice, hung up] …` | They hung up mid-sentence; the call is over (see "When a call ends"). |
| `[Voice, muted] …` / `[Voice, line dropped] …` | They muted, or the connection dropped, mid-sentence. |
| `[Voice, speech recognition failed: …]` | The phone couldn't transcribe them; ask them to repeat. |

Answer `[Voice]` messages with `start_call`. The message can arrive while you are still working: it steers the
current turn (Hermes reads it after the tool calls in flight finish), or starts a new turn when you are idle.

The words after the bracket are the user's. The sentence in parentheses at the end (`(Reply out loud with
start_call; …)`, `(HermesVoice note, not the user's words: …)`) is the plugin's hint to you, not something they
said.

The phone waits for a pause before it sends a turn (3.5 s by default, so the user can think mid-sentence), so a
reply reaches you a few seconds after they stop talking.

A turn that ends with `(Delayed by N s: this chat was open in another Hermes window, …)` could not be put into this
conversation when it was said, because another Hermes window or terminal had the chat open. The plugin told the
user so out loud, and the note says whether they are still on the call. Answer it as usual; if it is old, say so
briefly.

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
| `not_allowed` | Their call settings refuse this call (source, how often, quiet hours) | Follow the note (a scheduled job can't ring: see "Calling later") |
| `not_available` | Calls can't be placed from here: no Hermes dashboard with this plugin runs on the host, or (async, from a chat) Hermes doesn't let the plugin start a turn there | Follow the note (a sync call may still work); else reply in text |

With `mode: "async"` the endings come as messages: `[Voice call not answered]`, `[Voice line not delivered: …]`,
`[Voice call ended by user]`, `[Voice call ended: …]`.

## Calling later

"Call me in ten minutes", "wake me at seven", "ring me at half past two with the result": schedule the call with
`start_call` and a time. The plugin keeps the call and rings at that time by itself, also when this conversation is
idle and no chat window is open.

- `in_minutes`: minutes from now. "Call me in ten" is `in_minutes: 10` (fractions work).
- `at`: a clock time such as `"07:00"` (24-hour; the next time the clock shows it, so tomorrow if it has passed
  today), or an ISO date-time such as `"2026-01-31T07:00"`. Times are on the Hermes host's clock (the zone of the
  user's quiet hours, if they set one). At most 7 days ahead. Give `in_minutes` or `at`, not both.
- `text` is the line the user hears when they answer, so write it for that moment ("Good morning, it's seven.").
  `mode` is ignored.

The result comes at once: `{status: "scheduled", scheduled_id, rings_at, note, pending}`. Tell the user the time
(`rings_at`) and carry on or end your turn.

- **Never wait for the time yourself**: no sleep, no waiting command, no sync call held open. Such a wait is cut off
  at Hermes' tool deadline, so the phone rings early or not at all.
- **Never use a cron job** or another scheduler for a call: scheduled jobs are refused by the user's call settings
  (`not_allowed`), and nobody finds out until the call is missing.

At the time the phone rings, and your line is spoken once the user answers. You then get a `[Voice call started]`
notice that names the scheduled call (and says how late it rang, if Hermes was not running at the time). Don't
speak on that notice: wait for their `[Voice]` reply and answer it with `start_call`, as on any call. A call the
user asked for rings during their quiet hours too.

- **Not answered.** The phone rings once more a few minutes later (the result's `note` says when). After that you
  get the usual `[Voice call not answered]` or `[Voice line not delivered: …]` notice; it says that this was the
  scheduled call, when it was tried, and what its line was. Put the line in a short text reply. Don't schedule it
  again unless the user asks.
- **Not placed.** `[Voice call not placed: …]` means the ring never went out: Hermes was down for too long at the
  time, or the user stayed on another call. Tell them in text what the call was for.
- **Already on a call with you.** If the user is on a call with this conversation at the time, the line is said
  into that call without ringing, and a `[Voice line spoken: …]` notice tells you.
- **List and cancel.** Every scheduling result lists this conversation's scheduled calls in `pending`. `end_call`
  with `scheduled_id` cancels one (`"all"` cancels them all, `"list"` only lists them) and hangs nothing up. To
  change a time, cancel the call and schedule a new one. At most 5 calls can wait per conversation.

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

**How much they heard.** After each quoted line the notice says how much of it had played: `"…" (they heard about
2 of 9 s)`, `(they heard none of it)` or `(they heard nearly all of it)`. A little of a long line: it was too
long, so be shorter next time. Nearly all of it: they heard it and left; don't offer it again as missed.

## When a line may not have been heard

The phone reports how each of your lines really played. When that went badly you are told once, with the next
thing the call hands you: in the `note` of a `start_call` result, or at the end of a `[Voice]` message as
`(HermesVoice playback note, not the user's words: …)`. When playback was fine, nothing is added. The note
names the line: `Your last line …`; in the result of your next `start_call`, `Your line before this one …` (the
line you said before, not the one that result is for); or `An earlier line of yours …` when you have said more
since.

| Note | What happened | What to do |
| --- | --- | --- |
| `Your last line may not have been heard well: playback stalled twice (1.8 s of gaps).` | The audio broke up on its way to the phone | If it mattered, say it again: shorter and plainer, without quiet tags |
| `… the phone's audio restarted while it played.` / `… the phone's audio output changed while it played.` | The user switched to the speaker or a headset mid-line; a moment may be missing | The same |
| `… part of its audio was not played.` | The phone lost some of the line | The same |
| `… the phone's volume is very low.` (once per call) | They can barely hear you | Ask them to turn the volume up |
| `Your last line was not played to the end on the phone (they heard about 1 of 4 s).` / `Your last line may not have been heard: the phone did not confirm it played it.` | The line did not get through | Say it again |
| `The user replayed your last line on their phone: …` | They pressed Repeat; the phone played your last line again from its own copy | They have heard it now: don't say it again. Say important things shorter and plainer from here on |

- If these notes keep coming (two or three lines in a row), tell the user in a few words that their audio is
  breaking up, and suggest the speaker or a better connection.
- **The same text again is a replay.** `start_call` with exactly the text of your last line makes no new speech:
  the plugin sends the audio it kept, at once, and the result says `Same text as your last line, so the audio kept
  from it is replayed (no new speech).` Use that only when the user wants the very same words; if they did not
  understand, new words help more.
- The phone evens out loudness, so a line with a quiet tag is not quieter than a normal one. It is still harder
  to understand: when the user asks you to repeat, leave quiet tags out.

## Speaking well

A phone call is not a chat window: the user can't skim, scroll back or copy what they hear.

- **Answers.** Lead with the answer. Two sentences at most by default, then offer more ("Want the details?")
  instead of saying it all.
- **Mid-task updates.** A few words ("Still searching."), never a report. Asked for the status, say where you are
  in one sentence.
- **Never read out** codes (a course code, an order number), long identifiers, hashes, URLs, file paths, issue
  numbers or exact timestamps. Say the human name ("the databases course", "the login bug", "this morning"); the
  exact identifiers go in the text recap.
- **Numbers.** Round them ("about forty", "just under two hours") unless the user asked for precision.
- **Asked to repeat** ("what did you say?"): say it shorter and plainer, without quiet tags, not the same words
  again (the same text would only replay the same audio).
- Plain spoken sentences, the way you'd say them on the phone: no Markdown, lists, code or emoji. Say what the
  user needs to know; only links, code and exact identifiers go in the text recap.
- **Length check.** The `start_call` result flags a line that takes longer than about 15 seconds to say (`Long
  line: about 22 s of speech. Keep lines to a sentence or two and offer details instead.`; estimated at 15
  characters a second). Shorten the lines that follow. Text over about 1000 characters is cut (the result says so).
- Hang up with `end_call` (optionally with a short goodbye) when the conversation is done or they ask.

## Call style: how this user wants to be spoken to

The user's lasting preferences for calls (tone, form of address, humour, ElevenLabs audio tags) live in a file of
theirs: `<HERMES_HOME>/hermes-voice/call-style.md`. The `start_call` description gives its full path (a plugin
setting can move it). This skill can't be edited with `skill_manage`; that file is where such preferences go.

- **Follow it.** The plugin hands you the file's current text when a call starts: in the `[Voice call started]`
  notice, or as `call_style` in the first `start_call` result of a call (the line that rings). The `start_call`
  description also carries a short copy, read when Hermes started, so that your very first line can follow it;
  where the two differ, the result has the current text.
- **Update it** with your file tools when the user states a lasting preference about how you speak on calls
  ("call me sir", "drop the jokes on calls", "sound calmer"). Read the file, change it, keep it short (the first
  1500 characters are used; the plugin says when it cut), and tell the user you noted it. A wish for this one call
  ("speak up, I'm in the car") is not a lasting preference: just do it.
- It is about how you speak. It doesn't decide when to call or what to do, and the automated `[Voice call …]`
  notices never belong in it.

**Audio tags.** Square-bracket tags in `text` (`[laughs]`, `[sighs]`, `[excited]`) go to ElevenLabs as written
and don't count towards a line's length. They only work with ElevenLabs models that support them (ElevenLabs
documents them for Eleven v3, model `eleven_v3`); with other models, the plugin's default `eleven_flash_v2_5`
among them, a tag may be read out loud or dropped. So use tags only when the call style asks for them, and stop
if the user says they hear the tags spoken. Quiet tags (`[whispers]`, low, flat) make a line hard to hear on a
phone: the phone evens out their loudness, but they stay harder to understand. Keep them to a few words, or leave
them out.

## When to ring

Ring when the user asked to be called ("call me when it's done") or for news they would want right away. Never for
routine updates. You can call from any conversation on this host (dashboard, desktop, CLI, TUI, or the user's own
direct messages to Hermes); calls from scheduled jobs, subagents, group chats and other people's chats are refused
by default, and the user may have quiet hours: with `not_allowed` the note says what to do (sometimes: ask in text
first, then call again). For a call at a set time ("in ten minutes", "at seven"), see "Calling later".

## Notifications the app sends (not calls)

The app can notify the user with three pushes: an approval waiting, a question waiting, and a turn that finished.
They are sent only for conversations the dashboard hosts, and only while no client (phone app, Desktop, dashboard
chat) has that conversation open, after a grace period of about 5 s; so an approval you trigger in the chat the user
is looking at never arrives as a push. During quiet hours and past the alert budget they arrive silently. To check
that pushes reach the phone, tell the user to use Settings → Notifications → Send test notification in the app.
