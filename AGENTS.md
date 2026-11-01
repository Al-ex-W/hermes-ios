# Instructions for AI agents working on this repository

Hermes Voice is a **research beta**. Every agent working here (coding assistants, review agents, subagents) follows
the rules below.

## Say every problem you notice

As soon as you notice an issue, an inefficiency or a discrepancy, say it, in your reply or report, even if it is
minor, outside your task, or you already worked around it. That includes:

- bugs, flaky or slow tests, failing or skipped checks, warnings;
- docs, comments, tool descriptions or plans that don't match the code or the Hermes source;
- the app, the plugin, the fake server (`devtools/fake_hermes.py`) and real Hermes disagreeing about a route,
  shape or behaviour;
- slow, wasteful or redundant work, in the code or in how you were asked to do something;
- your own instructions contradicting each other or the code.

Say what you saw, where (file and line, command, output), and what you expected. Never hide a problem to make a
result look clean, and don't wait to be asked.

## Repository rules

- This repository is **public**. Never commit personal data (names, email addresses, Apple team ids, absolute home
  paths), secrets, `.env` files or `.p8` keys. Signing settings live only in the gitignored
  `HermesVoice/Config/Local.xcconfig`. Scan staged changes for personal data and secret patterns before every push.
- Never send prompts to, or change, a live Hermes dashboard or `~/.hermes`. Test against `devtools/fake_hermes.py`
  or a throwaway `hermes serve --isolated` with a temporary `HERMES_HOME`.
- The only voice feature is this project's call mode: never call Hermes' `/api/audio/*`, `voice.*` or `wake.*`.
- Run `xcodebuild` tests with `-collect-test-diagnostics never` (post-failure diagnostics can stall for minutes).
- How to build and test: see "Building the app" and "Testing" in [README.md](README.md).
