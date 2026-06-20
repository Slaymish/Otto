"""
learning_store.py — persistence, journal, undo, usage stats, and confidence for
Otto's learned capabilities.

Owns memory/capabilities.user.json (the learned/overlay capability list) and
memory/learning_journal.jsonl (an append-only before/after record enabling
one-tap undo). Pure file I/O + aggregation — no network, fully unit-testable.
"""
from __future__ import annotations

import copy
import json
import math
import time
import uuid
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


def _append_journal(record: dict) -> None:
    record = {**record, "t": round(time.time(), 3)}
    JOURNAL_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        with open(JOURNAL_PATH, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass


def journal_records() -> list[dict]:
    if not JOURNAL_PATH.exists():
        return []
    recs: list[dict] = []
    try:
        with open(JOURNAL_PATH) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    recs.append(json.loads(line))
                except (ValueError, json.JSONDecodeError):
                    continue
    except OSError:
        return []
    return recs


def apply_updates(updates: list[dict]) -> list[LearningEvent]:
    """Merge learned updates into the user caps file, journaling before/after
    for undo. Returns one LearningEvent per id that actually changed."""
    import retrospective  # local import avoids any import cycle at module load

    user = load_user_caps()
    builtin = _load_json_list(BUILTIN_CAPS_PATH)
    builtin_by_id = {c["id"]: c for c in builtin}
    before_by_id = {c["id"]: copy.deepcopy(c) for c in user}

    merged, _, _ = retrospective._merge_updates(user, builtin_by_id, updates)
    merged_by_id = {c["id"]: c for c in merged}

    events: list[LearningEvent] = []
    seen: set[str] = set()
    for up in updates:
        cid = (up.get("id") or "").strip()
        if not cid or cid in seen or cid not in merged_by_id:
            continue
        seen.add(cid)
        after = merged_by_id[cid]
        before = before_by_id.get(cid)
        is_new = before is None and cid not in builtin_by_id
        action = "new_capability" if is_new else "added_phrasing"
        examples = [e for e in up.get("examples", []) if isinstance(e, str)]
        phrase = examples[0] if examples else ""
        learned_at = _now_iso()
        learned_marker = {"event": "learned", "id": cid, "action": action,
                          "phrase": phrase, "description": after.get("description", ""),
                          "learned_at": learned_at, "entry_id": uuid.uuid4().hex,
                          "before": before, "after": copy.deepcopy(after)}
        _append_journal(learned_marker)
        events.append(LearningEvent(
            id=cid, action=action, phrase=phrase,
            description=after.get("description", ""),
            primitive=after.get("primitive", ""), learned_at=learned_at,
        ))

    save_user_caps(merged)
    return events


def undo(cap_id: str) -> bool:
    """Revert the most recent not-yet-undone learned change for cap_id."""
    recs = journal_records()
    undone_refs = {r.get("ref") for r in recs if r.get("event") == "undone"}
    last = None
    for r in recs:
        if r.get("event") == "learned" and r.get("id") == cap_id and r.get("entry_id") not in undone_refs:
            last = r
    if last is None:
        return False

    caps = load_user_caps()
    by_id = {c["id"]: c for c in caps}
    if last.get("before") is None:
        by_id.pop(cap_id, None)
    else:
        by_id[cap_id] = last["before"]
    save_user_caps(list(by_id.values()))
    _append_journal({"event": "undone", "id": cap_id, "ref": last.get("entry_id")})
    return True


def usage_stats(sessions: int = 200) -> dict[str, dict]:
    stats: dict[str, dict] = {}
    for path in SessionLog.list_sessions(limit=sessions):
        for ev in SessionLog.read_session(path):
            if ev.get("event") != "tool_call":
                continue
            cid = ev.get("capability_id")
            if not cid:
                continue
            s = stats.setdefault(cid, {"times_used": 0, "ok_used": 0, "last_used": None})
            s["times_used"] += 1
            if ev.get("ok"):
                s["ok_used"] += 1
            ts = ev.get("t")
            if ts is not None:
                iso = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                if s["last_used"] is None or iso > s["last_used"]:
                    s["last_used"] = iso
    return stats


def edit_capability(cap_id: str, description: str | None = None,
                    examples: list[str] | None = None) -> bool:
    caps = load_user_caps()
    found = False
    for c in caps:
        if c["id"] == cap_id:
            if description is not None:
                c["description"] = description
            if examples is not None:
                c["examples"] = examples
            found = True
    if found:
        save_user_caps(caps)
    return found


def delete_capability(cap_id: str) -> bool:
    caps = load_user_caps()
    kept = [c for c in caps if c["id"] != cap_id]
    if len(kept) == len(caps):
        return False
    save_user_caps(kept)
    return True


def _learned_at_for(cap_id: str) -> str | None:
    learned_at = None
    for r in journal_records():
        if r.get("event") == "learned" and r.get("id") == cap_id:
            learned_at = r.get("learned_at")
    return learned_at


def build_journal() -> tuple[dict, list[JournalCard]]:
    builtin = {c["id"]: c for c in _load_json_list(BUILTIN_CAPS_PATH)}
    user = {c["id"]: c for c in load_user_caps()}
    active = {**builtin, **user}  # user overrides builtin by id
    stats = usage_stats()

    cards: list[JournalCard] = []
    learned_count = 0
    for cid, cap in active.items():
        origin = "learned" if cid in user else "shipped"
        if origin == "learned":
            learned_count += 1
        s = stats.get(cid, {"times_used": 0, "ok_used": 0, "last_used": None})
        times = s["times_used"]
        success = (s["ok_used"] / times) if times else 1.0
        tmpl = cap.get("template", "")
        cards.append(JournalCard(
            id=cid, description=cap.get("description", ""),
            examples=list(cap.get("examples", [])),
            primitive=cap.get("primitive", ""),
            template=tmpl if isinstance(tmpl, str) else json.dumps(tmpl, ensure_ascii=False),
            origin=origin, learned_at=_learned_at_for(cid),
            times_used=times, last_used=s["last_used"],
            confidence=confidence(times, success),
        ))
    total_commands = sum(s["ok_used"] for s in stats.values())
    cards.sort(key=lambda c: (c.learned_at or "", c.description), reverse=True)
    header = {"capabilities": len(active), "learned": learned_count,
              "commands": total_commands}
    return header, cards


def journal_payload() -> dict:
    header, cards = build_journal()
    return {"type": "journal", "header": header,
            "cards": [c.__dict__ for c in cards]}
