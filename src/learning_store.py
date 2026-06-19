"""
learning_store.py — persistence, journal, undo, usage stats, and confidence for
voice-os learned capabilities.

Owns memory/capabilities.user.json (the learned/overlay capability list) and
memory/learning_journal.jsonl (an append-only before/after record enabling
one-tap undo). Pure file I/O + aggregation — no network, fully unit-testable.
"""
from __future__ import annotations

import copy
import json
import math
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from session_log import SessionLog

_ROOT = Path(__file__).resolve().parent.parent
USER_CAPS_PATH = _ROOT / "memory" / "capabilities.user.json"
BUILTIN_CAPS_PATH = _ROOT / "memory" / "capabilities.json"
JOURNAL_PATH = _ROOT / "memory" / "learning_journal.jsonl"


@dataclass(frozen=True)
class LearningEvent:
    id: str
    action: str          # "new_capability" | "added_phrasing"
    phrase: str
    description: str
    primitive: str
    learned_at: str

    def to_ipc(self) -> dict:
        return {"type": "learned", "id": self.id, "action": self.action,
                "phrase": self.phrase, "description": self.description,
                "primitive": self.primitive}


@dataclass(frozen=True)
class JournalCard:
    id: str
    description: str
    examples: list[str]
    primitive: str
    template: str
    origin: str          # "learned" | "shipped"
    learned_at: str | None
    times_used: int
    last_used: str | None
    confidence: float


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_json_list(path: Path) -> list[dict]:
    if not path.exists():
        return []
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:  # noqa: BLE001
        return []


def load_user_caps() -> list[dict]:
    return _load_json_list(USER_CAPS_PATH)


def save_user_caps(caps: list[dict]) -> None:
    USER_CAPS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(USER_CAPS_PATH, "w") as f:
        json.dump(caps, f, indent=2, ensure_ascii=False)


def confidence(times_used: int, success_rate: float) -> float:
    """Deterministic trust score in [0,1]. Half from proven success rate,
    half from accumulated use with diminishing returns (~0.63 at 3 uses)."""
    usage = 1.0 - math.exp(-max(0, times_used) / 3.0)
    score = 0.5 * usage + 0.5 * max(0.0, min(1.0, success_rate))
    return round(min(1.0, score), 3)
