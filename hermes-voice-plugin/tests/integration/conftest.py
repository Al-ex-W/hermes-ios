"""Opt-in: a real ``hermes serve`` in a temp home (see hermes_sandbox.py). Run with

    HERMES_VOICE_INTEGRATION=1 uv run pytest -q tests/integration

and ``HERMES_PYTHON`` / ``HERMES_AGENT_DIR`` when Hermes isn't at ``~/.hermes/hermes-agent``. ``HERMES_VOICE_IT_TMP``
picks the folder the sandbox goes in (default: the system temp folder); a failing run leaves it there with
``hermes.log`` and ``hermes/logs``. ``HERMES_VOICE_IT_PORTS=<low>-<high>`` keeps the test servers' ports in a range."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Iterator

import pytest

from hermes_sandbox import Sandbox, StubModel, hermes_python
from scenario import Agent

# Set when a test here failed, so the sandbox is kept for a look at its logs.
_FAILED: list[str] = []


@pytest.fixture(scope="module")
def hermes() -> Iterator[tuple[Sandbox, StubModel, Agent]]:
    if os.environ.get("HERMES_VOICE_INTEGRATION") != "1":
        pytest.skip("set HERMES_VOICE_INTEGRATION=1 to run against a real Hermes")
    python, why = hermes_python()
    if python is None:
        pytest.skip(why)
    agent = Agent()
    model = StubModel(agent)
    root = os.environ.get("HERMES_VOICE_IT_TMP")
    sandbox = Sandbox(python, model, root=Path(root) if root else None, ring_timeout_s=6.0)
    started = False
    try:
        sandbox.start()
        started = True
        yield sandbox, model, agent
    finally:
        sandbox.stop()
        model.stop()
        if _FAILED or not started:
            print(f"\nhermes sandbox kept for inspection: {sandbox.root}\n{sandbox.log_tail(3000)}")
        else:
            shutil.rmtree(sandbox.root, ignore_errors=True)


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):  # noqa: ANN001 - pytest hook
    outcome = yield
    report = outcome.get_result()
    if report.when == "call" and report.failed and "hermes" in item.fixturenames:
        _FAILED.append(item.nodeid)
        sandbox = item.funcargs["hermes"][0]
        report.sections.append(("hermes logs", sandbox.agent_logs(4000)))
