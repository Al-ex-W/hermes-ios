"""Make devtools/fake_hermes.py importable from the tests (run them from the hermes-voice-mcp venv)."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
