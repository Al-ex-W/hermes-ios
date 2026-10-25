"""What "the model" does in the integration tests: a tiny agent that calls the user when asked and answers what they
say on the call out loud.

- ``call me sync: <text>`` / ``call me async: <text>`` -> ``start_call {text, mode}``
- an injected ``[Voice] <said> (…hint…)`` turn -> ``start_call {text: "You said <said>."}`` (async); a hung-up turn
  gets a text reply
- after a tool result, or anything else -> a short text reply

Current Hermes defers plugin tools behind its Tool Search bridge (``tool_search`` / ``tool_describe`` /
``tool_call``) unless ``tools.tool_search.enabled`` is off, so a real model reaches ``start_call`` through
``tool_call``; this agent does the same whenever ``start_call`` isn't listed directly.
"""

from __future__ import annotations

import json
import re
import threading
from typing import Any, Optional

from hermes_sandbox import Text, ToolCall, message_text, since_last_reply

# One line: Hermes may append notes of its own to a user's message (e.g. on their very first one).
CALL_ME = re.compile(r"call me (sync|async): ([^\n]+)")
VOICE_TURN = re.compile(r"\[Voice(?:, [^\]]*)?\] (.+?) \((Reply out loud|The user hung up)")


def invoke(body: dict[str, Any], name: str, args: dict[str, Any], delay: float = 0.0) -> ToolCall:
    """Call a tool directly when it is listed, else through Hermes' ``tool_call`` bridge."""
    listed = {str((tool.get("function") or {}).get("name")) for tool in body.get("tools") or []}
    if name in listed:
        return ToolCall(name, args, delay)
    return ToolCall("tool_call", {"calls": [{"name": name, "arguments": args}]}, delay)


def tool_results(bodies: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Every JSON object Hermes returned to the model as a tool result, in order, without repeats."""
    seen: list[dict[str, Any]] = []
    for body in bodies:
        for message in body.get("messages") or []:
            if message.get("role") != "tool":
                continue
            try:
                value = json.loads(message_text(message))
            except ValueError:
                continue
            if isinstance(value, dict) and value not in seen:
                seen.append(value)
    return seen


class Agent:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        # Seconds the model "thinks" before answering a said text (keeps that turn running).
        self.slow: dict[str, float] = {}
        self.answered: set[str] = set()

    def __call__(self, body: dict[str, Any]) -> Any:
        recent = since_last_reply(body)
        texts = [message_text(m) for m in recent]
        with self.lock:
            for said, hint in VOICE_TURN.findall("\n".join(texts)):
                said = " ".join(said.split())
                if said in self.answered:
                    continue
                self.answered.add(said)
                if hint == "The user hung up":
                    return Text("Talk soon.")  # the call is over: reply in text, as the hint says
                return invoke(body, "start_call", {"text": f"You said {said}.", "mode": "async"},
                              self.slow.get(said, 0.0))
        last = recent[-1] if recent else {}
        if last.get("role") == "user":
            match = CALL_ME.search(message_text(last))
            if match:
                return invoke(body, "start_call", {"text": match.group(2).strip(), "mode": match.group(1)})
        if last.get("role") == "tool":
            return Text("Done.")
        return Text("Noted.")


def start_call_result(bodies: list[dict[str, Any]], call_id: Optional[str] = None,
                      key: str = "outcome") -> Optional[dict[str, Any]]:
    """The last start_call result (one with `key`) the model was given, for `call_id` when one is named."""
    found = [r for r in tool_results(bodies) if key in r and (call_id is None or r.get("call_id") == call_id)]
    return found[-1] if found else None
