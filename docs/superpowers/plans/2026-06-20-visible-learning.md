# Visible Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing "dreaming" loop visible — a live "I just learned this" nudge in the palette plus a browsable capability journal — so VoiceOS observably compounds with use.

**Architecture:** A successful tool call on a *weakly-grounded* turn is treated as "something new." An async incremental learner (gpt-4.1-mini, the same logic the batch retrospective uses) turns that turn into a learned capability immediately, records a before/after journal entry for one-tap undo, and emits a `learned` IPC event. A new `learning_store` module owns persistence, the journal, undo, usage stats, and confidence. The SwiftUI app shows a nudge chip and a second journal window; terminal modes get a printed line and CLI subcommands.

**Tech Stack:** Python 3.10+ (stdlib + `urllib`, `numpy`, `sentence-transformers` already present), pytest; Swift/SwiftUI/AppKit built via `make app` (Xcode Command Line Tools, no full Xcode).

## Global Constraints

- Python target: 3.10+ (`from __future__ import annotations` is used across `src/`; match it).
- Scripts in `src/` import siblings directly by name (no package). New modules live in `src/` and are imported as `import learning_store`, etc. Tests add `src/` to `sys.path` via `sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))`.
- `memory/capabilities.user.json`, `memory/learning_journal.jsonl`, and `memory/sessions/` are gitignored and may not exist — all reads must tolerate absence.
- Learning is **best-effort and async**: a model/network failure must never block a voice turn or crash a session.
- Trust model: learned capabilities are **live immediately**; safety comes from validation-before-write and one-tap undo.
- The model used for learning is `gpt-4.1-mini` via `https://api.openai.com/v1/chat/completions` with `{"response_format": {"type": "json_object"}}` (matches existing retrospective).
- Existing tests must stay green: `pytest tests/test_retrospective.py tests/test_retrieval.py tests/test_session_log.py tests/test_voice_agent.py`.
- Swift sources must be added to `Makefile`'s `SOURCES` or `make app` will not compile them.
- **Out of scope (follow-ups, do not build here):** `--local` (`wake_listener.py`) live-learning; cloud sync / shareable packs; in-app editing of template *code* (journal edits = description + example phrases + delete only); risk-tiering.

---

## File Structure

**New (Python):**
- `src/learning_store.py` — persistence + metadata for `capabilities.user.json`; `learning_journal.jsonl` (append-only, before/after); `apply_updates`, `undo`, `edit_capability`, `delete_capability`; usage-stat aggregation from session logs; deterministic `confidence`; `build_journal`/`journal_payload`. Dataclasses `LearningEvent`, `JournalCard`.
- `src/incremental_learner.py` — `learn_turn(turn, *, propose, existing_view)` orchestration: one turn → updates → `apply_updates` → `list[LearningEvent]`. Network injected for testability.

**New (Swift):**
- `VoiceOS/VoiceOS/JournalWindow.swift` — `JournalView` (SwiftUI) + `JournalController` (titled NSWindow).

**Modified (Python):**
- `src/session_log.py` — `tool_call(..., capability_id=None)` writes a `capability_id` field.
- `src/retrospective.py` — extract `call_model` + `propose_updates`; route persistence through `learning_store`; keep all test-referenced helpers in place; add `--journal` / `--undo` CLI.
- `src/voice_agent.py` — capture per-turn grounding + top match (`_last_turn`); pure `_should_learn` / `_capability_id_for` helpers; fire incremental learner on weak+success; broadcast `learned`; wire inbound journal/undo/edit/delete IPC.
- `src/ipc_server.py` — new inbound callbacks + dispatch routes.

**Modified (Swift):**
- `VoiceOS/VoiceOS/PythonBridge.swift` — decode `learned`/`journal`; add `learnedEvent`, `journal` state; add `requestJournal`/`undoLearning`/`editCapability`/`deleteCapability`.
- `VoiceOS/VoiceOS/CommandPalette.swift` — nudge chip.
- `VoiceOS/VoiceOS/VoiceOSApp.swift` — `JournalController` + a second `HotkeyManager` (⌥⇧Space).
- `Makefile` — add `JournalWindow.swift` to `SOURCES`.

**New (tests):**
- `tests/test_learning_store.py`, `tests/test_incremental_learner.py`, `tests/test_ipc.py`; additions to `tests/test_voice_agent.py`.

---

## Data Shapes (authoritative — used across tasks)

```python
# learning_store.py
@dataclass(frozen=True)
class LearningEvent:
    id: str
    action: str          # "new_capability" | "added_phrasing"
    phrase: str          # the user phrasing just learned ("" if unknown)
    description: str      # capability description (human label)
    primitive: str
    learned_at: str       # ISO-8601 UTC, e.g. "2026-06-20T14:03:11Z"

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
    template: str         # stringified
    origin: str           # "learned" | "shipped"
    learned_at: str | None
    times_used: int
    last_used: str | None
    confidence: float     # 0.0..1.0
```

**`learning_journal.jsonl` entry (one JSON object per line):**
```json
{"event": "learned", "t": 1750000000.0, "id": "x", "action": "new_capability",
 "phrase": "fire up my edit setup", "description": "...", "learned_at": "2026-06-20T14:03:11Z",
 "before": null, "after": { ... full capability dict ... }}
{"event": "undone", "t": 1750000123.0, "id": "x", "ref": 1750000000.0}
```

**IPC additions:**
- Python→Swift: `{"type":"learned", "id","action","phrase","description","primitive"}`
- Python→Swift: `{"type":"journal","header":{"capabilities":N,"learned":M,"commands":K},"cards":[ {id,description,examples,primitive,template,origin,learned_at,times_used,last_used,confidence}, ...]}`
- Swift→Python: `{"type":"request_journal"}`, `{"type":"undo_learning","id":...}`, `{"type":"edit_capability","id":...,"description":...,"examples":[...]}`, `{"type":"delete_capability","id":...}`

---

## Task 1: session_log records `capability_id` on tool calls

**Files:**
- Modify: `src/session_log.py:49-57`
- Test: `tests/test_session_log.py`

**Interfaces:**
- Produces: `SessionLog.tool_call(name: str, args: dict, result: dict, latency: float, capability_id: str | None = None)` — writes a `capability_id` field (may be `null`).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_session_log.py`:

```python
def test_tool_call_records_capability_id(tmp_path, monkeypatch):
    import session_log
    monkeypatch.setattr(session_log, "_SESSIONS_DIR", tmp_path)
    log = session_log.SessionLog(user="t")
    log.tool_call("run_applescript", {"script": "x"}, {"status": "ok"}, 0.1,
                  capability_id="spotify-play-search")
    events = session_log.SessionLog.read_session(log.path)
    call = next(e for e in events if e["event"] == "tool_call")
    assert call["capability_id"] == "spotify-play-search"
    assert call["ok"] is True


def test_tool_call_capability_id_defaults_to_none(tmp_path, monkeypatch):
    import session_log
    monkeypatch.setattr(session_log, "_SESSIONS_DIR", tmp_path)
    log = session_log.SessionLog(user="t")
    log.tool_call("open_url", {"url": "http://x"}, {"status": "ok"}, 0.1)
    events = session_log.SessionLog.read_session(log.path)
    call = next(e for e in events if e["event"] == "tool_call")
    assert call["capability_id"] is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_session_log.py -k capability -v`
Expected: FAIL (`tool_call() got an unexpected keyword argument 'capability_id'`)

- [ ] **Step 3: Implement**

In `src/session_log.py`, replace the `tool_call` method (lines 49-57):

```python
    def tool_call(self, name: str, args: dict, result: dict, latency: float,
                  capability_id: str | None = None) -> None:
        self._write({
            "event": "tool_call",
            "name": name,
            "args": args,
            "result": result,
            "latency_s": round(latency, 3),
            "ok": result.get("status") == "ok",
            "capability_id": capability_id,
        })
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_session_log.py -v`
Expected: PASS (all, including existing)

- [ ] **Step 5: Commit**

```bash
git add src/session_log.py tests/test_session_log.py
git commit -m "feat: record capability_id on tool_call session events"
```

---

## Task 2: learning_store — load/save + deterministic confidence

**Files:**
- Create: `src/learning_store.py`
- Test: `tests/test_learning_store.py`

**Interfaces:**
- Produces:
  - `USER_CAPS_PATH: Path`, `JOURNAL_PATH: Path`, `BUILTIN_CAPS_PATH: Path` (module constants; tests monkeypatch these).
  - `load_user_caps() -> list[dict]`
  - `save_user_caps(caps: list[dict]) -> None`
  - `confidence(times_used: int, success_rate: float) -> float` — deterministic, in `[0,1]`, monotonic non-decreasing in `times_used` and in `success_rate`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_learning_store.py`:

```python
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import learning_store as ls  # noqa: E402


def _point(monkeypatch, tmp_path):
    monkeypatch.setattr(ls, "USER_CAPS_PATH", tmp_path / "capabilities.user.json")
    monkeypatch.setattr(ls, "JOURNAL_PATH", tmp_path / "learning_journal.jsonl")
    monkeypatch.setattr(ls, "BUILTIN_CAPS_PATH", tmp_path / "capabilities.json")


def test_load_user_caps_missing_returns_empty(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    assert ls.load_user_caps() == []


def test_save_then_load_roundtrips(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    caps = [{"id": "a", "description": "d", "examples": ["x"],
             "primitive": "open_url", "template": "http://x", "source": "learned"}]
    ls.save_user_caps(caps)
    assert ls.load_user_caps() == caps


def test_confidence_rises_with_use_and_success():
    base = ls.confidence(0, 1.0)
    more = ls.confidence(9, 1.0)
    assert 0.0 <= base <= more <= 1.0
    # success_rate dominates the floor: 0 uses, perfect success -> 0.5
    assert abs(base - 0.5) < 1e-9
    # failures lower it
    assert ls.confidence(9, 0.0) < ls.confidence(9, 1.0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_learning_store.py -v`
Expected: FAIL (`ModuleNotFoundError: No module named 'learning_store'`)

- [ ] **Step 3: Implement**

Create `src/learning_store.py`:

```python
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
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_learning_store.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/learning_store.py tests/test_learning_store.py
git commit -m "feat: learning_store skeleton — load/save caps + confidence"
```

---

## Task 3: learning_store — apply_updates + journal entries + undo

**Files:**
- Modify: `src/learning_store.py`
- Test: `tests/test_learning_store.py`

**Interfaces:**
- Consumes: `retrospective._merge_updates(user_caps, builtin_by_id, updates) -> (merged, n_caps, n_examples)` (existing).
- Produces:
  - `apply_updates(updates: list[dict]) -> list[LearningEvent]` — merges into the user caps file, appends before/after journal entries, returns one `LearningEvent` per id that actually changed.
  - `undo(cap_id: str) -> bool` — reverts the last not-yet-undone `learned` entry for `cap_id`; returns whether anything was reverted.
  - `journal_records() -> list[dict]` — all `learning_journal.jsonl` entries.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_learning_store.py`:

```python
def test_apply_updates_new_capability_writes_event_and_journal(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    events = ls.apply_updates([{
        "id": "edit-setup", "examples": ["fire up my edit setup"],
        "primitive": "run_applescript", "template": "tell application ...",
        "description": "Open editing apps",
    }])
    assert len(events) == 1
    ev = events[0]
    assert ev.id == "edit-setup" and ev.action == "new_capability"
    assert ev.phrase == "fire up my edit setup"
    # capability is now live
    caps = ls.load_user_caps()
    assert any(c["id"] == "edit-setup" for c in caps)
    # journal recorded with before=None
    recs = ls.journal_records()
    learned = [r for r in recs if r["event"] == "learned" and r["id"] == "edit-setup"]
    assert learned and learned[-1]["before"] is None


def test_apply_updates_added_phrasing_to_existing_user_cap(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    ls.save_user_caps([{"id": "thing", "description": "d", "examples": ["foo"],
                        "primitive": "open_url", "template": "http://x", "source": "learned"}])
    events = ls.apply_updates([{"id": "thing", "examples": ["bar"]}])
    assert len(events) == 1 and events[0].action == "added_phrasing"
    assert "bar" in next(c for c in ls.load_user_caps() if c["id"] == "thing")["examples"]


def test_undo_new_capability_removes_it(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    ls.apply_updates([{"id": "edit-setup", "examples": ["x"],
                       "primitive": "open_url", "template": "http://x",
                       "description": "d"}])
    assert ls.undo("edit-setup") is True
    assert all(c["id"] != "edit-setup" for c in ls.load_user_caps())
    # second undo is a no-op
    assert ls.undo("edit-setup") is False


def test_undo_added_phrasing_restores_prior_examples(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    ls.save_user_caps([{"id": "thing", "description": "d", "examples": ["foo"],
                        "primitive": "open_url", "template": "http://x", "source": "learned"}])
    ls.apply_updates([{"id": "thing", "examples": ["bar"]}])
    assert ls.undo("thing") is True
    assert next(c for c in ls.load_user_caps() if c["id"] == "thing")["examples"] == ["foo"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_learning_store.py -k "apply or undo" -v`
Expected: FAIL (`AttributeError: module 'learning_store' has no attribute 'apply_updates'`)

- [ ] **Step 3: Implement**

Add to `src/learning_store.py`:

```python
def _append_journal(record: dict) -> None:
    record["t"] = round(time.time(), 3)
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
        save_marker = {"event": "learned", "id": cid, "action": action,
                       "phrase": phrase, "description": after.get("description", ""),
                       "learned_at": learned_at,
                       "before": before, "after": copy.deepcopy(after)}
        _append_journal(save_marker)
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
        if r.get("event") == "learned" and r.get("id") == cap_id and r.get("t") not in undone_refs:
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
    _append_journal({"event": "undone", "id": cap_id, "ref": last.get("t")})
    return True
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_learning_store.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/learning_store.py tests/test_learning_store.py
git commit -m "feat: learning_store apply_updates + journal + undo"
```

---

## Task 4: learning_store — usage stats, edit/delete, journal payload

**Files:**
- Modify: `src/learning_store.py`
- Test: `tests/test_learning_store.py`

**Interfaces:**
- Consumes: `SessionLog.list_sessions`, `SessionLog.read_session` (existing).
- Produces:
  - `usage_stats(sessions: int = 200) -> dict[str, dict]` — `{cap_id: {"times_used": int, "ok_used": int, "last_used": str | None}}` from session-log `tool_call` events keyed by `capability_id`.
  - `edit_capability(cap_id: str, description: str | None = None, examples: list[str] | None = None) -> bool`
  - `delete_capability(cap_id: str) -> bool`
  - `build_journal() -> tuple[dict, list[JournalCard]]` — `(header, cards)`; `header = {"capabilities": int, "learned": int, "commands": int}`.
  - `journal_payload() -> dict` — `{"type":"journal","header":...,"cards":[<card dict>...]}`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_learning_store.py`:

```python
def test_usage_stats_counts_by_capability_id(tmp_path, monkeypatch):
    import session_log
    sessions_dir = tmp_path / "sessions"
    sessions_dir.mkdir()
    monkeypatch.setattr(session_log, "_SESSIONS_DIR", sessions_dir)
    log = session_log.SessionLog(user="t")
    log.tool_call("open_url", {}, {"status": "ok"}, 0.1, capability_id="web-search")
    log.tool_call("open_url", {}, {"status": "ok"}, 0.1, capability_id="web-search")
    log.tool_call("open_url", {}, {"status": "error"}, 0.1, capability_id="web-search")
    stats = ls.usage_stats()
    assert stats["web-search"]["times_used"] == 3
    assert stats["web-search"]["ok_used"] == 2
    assert stats["web-search"]["last_used"] is not None


def test_build_journal_merges_caps_stats_and_confidence(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    import session_log
    sessions_dir = tmp_path / "sessions"
    sessions_dir.mkdir()
    monkeypatch.setattr(session_log, "_SESSIONS_DIR", sessions_dir)
    # one builtin, one learned
    (tmp_path / "capabilities.json").write_text(json.dumps([
        {"id": "web-search", "description": "search the web", "examples": ["search x"],
         "primitive": "open_url", "template": "http://x"}]))
    ls.save_user_caps([{"id": "edit-setup", "description": "edit", "examples": ["fire up"],
                        "primitive": "run_applescript", "template": "t", "source": "learned"}])
    log = session_log.SessionLog(user="t")
    log.tool_call("open_url", {}, {"status": "ok"}, 0.1, capability_id="web-search")
    header, cards = ls.build_journal()
    assert header["capabilities"] == 2
    assert header["learned"] == 1
    assert header["commands"] == 1
    by_id = {c.id: c for c in cards}
    assert by_id["web-search"].origin == "shipped"
    assert by_id["edit-setup"].origin == "learned"
    assert by_id["web-search"].times_used == 1
    assert 0.0 <= by_id["edit-setup"].confidence <= 1.0


def test_edit_and_delete_capability(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    ls.save_user_caps([{"id": "thing", "description": "old", "examples": ["a"],
                        "primitive": "open_url", "template": "t", "source": "learned"}])
    assert ls.edit_capability("thing", description="new", examples=["a", "b"]) is True
    c = next(c for c in ls.load_user_caps() if c["id"] == "thing")
    assert c["description"] == "new" and c["examples"] == ["a", "b"]
    assert ls.delete_capability("thing") is True
    assert ls.load_user_caps() == []
    assert ls.delete_capability("thing") is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_learning_store.py -k "usage or build_journal or edit_and_delete" -v`
Expected: FAIL (`AttributeError: ... 'usage_stats'`)

- [ ] **Step 3: Implement**

Add to `src/learning_store.py`:

```python
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
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_learning_store.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/learning_store.py tests/test_learning_store.py
git commit -m "feat: learning_store usage stats, edit/delete, journal payload"
```

---

## Task 5: retrospective — extract `call_model` + `propose_updates`, route persistence through learning_store

**Files:**
- Modify: `src/retrospective.py`
- Test: `tests/test_retrospective.py` (existing must stay green; add 2 new tests)

**Interfaces:**
- Produces:
  - `call_model(prompt: str, *, model: str = "gpt-4.1-mini", timeout: int = 30) -> str` — POSTs to OpenAI chat completions, returns the message content string. Raises on failure.
  - `propose_updates(turns: list[dict], existing_view: list[dict], *, call=call_model) -> list[dict]` — builds the prompt, calls the model, parses to a flat updates list. `call` is injectable for tests.
- Unchanged (still importable as `retrospective._*`): `_strip_wake`, `_collect_turns`, `_format_turns_for_prompt`, `_format_existing_for_prompt`, `_merge_updates`, `_parse_updates`, `_RETROSPECTIVE_PROMPT`, `run_retrospective`.

> NOTE: keep all existing helpers exactly where they are — `tests/test_retrospective.py` imports them as `r._merge_updates`, etc. Only *extract* the inline HTTP block from `run_retrospective` into `call_model`, and add `propose_updates`. `_load_user_caps`/`_save_user_caps` stay but delegate to `learning_store` to avoid two persistence paths.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_retrospective.py`:

```python
def test_propose_updates_uses_injected_caller():
    captured = {}

    def fake_call(prompt, **kw):
        captured["prompt"] = prompt
        return json.dumps({"updates": [{"id": "x", "examples": ["hi"]}]})

    turns = [{"query": "say hi", "name": "run_applescript", "args": {}, "result": {}}]
    existing = [{"id": "x", "description": "d", "examples": ["hello"]}]
    updates = r.propose_updates(turns, existing, call=fake_call)
    assert updates == [{"id": "x", "examples": ["hi"]}]
    assert "say hi" in captured["prompt"]
    assert "[x]" in captured["prompt"]


def test_propose_updates_empty_on_no_updates():
    updates = r.propose_updates([], [], call=lambda p, **k: json.dumps({"updates": []}))
    assert updates == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_retrospective.py -k propose_updates -v`
Expected: FAIL (`AttributeError: module 'retrospective' has no attribute 'propose_updates'`)

- [ ] **Step 3: Implement**

In `src/retrospective.py`, add near the top (after imports):

```python
def call_model(prompt: str, *, model: str = "gpt-4.1-mini", timeout: int = 30) -> str:
    """POST the prompt to OpenAI chat completions; return the message content."""
    import urllib.request

    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        raise RuntimeError("OPENAI_API_KEY not set")
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "response_format": {"type": "json_object"},
        "temperature": 0.4,
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = json.loads(resp.read())
    return raw["choices"][0]["message"]["content"]


def propose_updates(turns: list[dict], existing_view: list[dict], *, call=call_model) -> list[dict]:
    """Build the retrospective prompt for these turns, call the model, parse updates."""
    prompt = (
        _RETROSPECTIVE_PROMPT
        .replace("{existing}", _format_existing_for_prompt(existing_view))
        .replace("{log}", _format_turns_for_prompt(turns))
    )
    content = call(prompt)
    return _parse_updates(json.loads(content))
```

Then update `_load_user_caps`/`_save_user_caps` to delegate (replace lines 142-149):

```python
def _load_user_caps() -> list[dict]:
    import learning_store
    return learning_store.load_user_caps()


def _save_user_caps(caps: list[dict]) -> None:
    import learning_store
    learning_store.save_user_caps(caps)
```

Then refactor the body of `run_retrospective` (lines ~267-303) so the prompt-build + HTTP block is replaced by a single call. Replace from the `# NB: plain .replace` comment through the `except Exception as e:` block with:

```python
    try:
        t0 = time.monotonic()
        updates = propose_updates(turns, existing_view)
        if verbose:
            print(f"[retrospective] LLM responded in {time.monotonic()-t0:.1f}s", flush=True)
    except Exception as e:  # noqa: BLE001
        print(f"[retrospective] LLM call failed: {e}", flush=True)
        return 0
```

(Leave the surrounding `builtin_caps`/`existing_view` setup and the `_merge_updates`/`_save_user_caps` lines that follow unchanged.)

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_retrospective.py -v`
Expected: PASS (all existing + 2 new)

- [ ] **Step 5: Commit**

```bash
git add src/retrospective.py tests/test_retrospective.py
git commit -m "refactor: extract call_model/propose_updates; route caps through learning_store"
```

---

## Task 6: incremental_learner — learn one turn

**Files:**
- Create: `src/incremental_learner.py`
- Test: `tests/test_incremental_learner.py`

**Interfaces:**
- Consumes: `retrospective.propose_updates`, `learning_store.apply_updates`, `learning_store.LearningEvent`.
- Produces:
  - `learn_turn(turn: dict, existing_view: list[dict], *, propose=retrospective.propose_updates) -> list[learning_store.LearningEvent]` — wraps the single turn in a list, proposes updates, applies them, returns events. Never raises (returns `[]` on any failure).
  - `turn` shape: `{"query": str|None, "name": str, "args": dict, "result": dict}`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_incremental_learner.py`:

```python
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import incremental_learner as il  # noqa: E402
import learning_store as ls  # noqa: E402


def _point(monkeypatch, tmp_path):
    monkeypatch.setattr(ls, "USER_CAPS_PATH", tmp_path / "capabilities.user.json")
    monkeypatch.setattr(ls, "JOURNAL_PATH", tmp_path / "learning_journal.jsonl")
    monkeypatch.setattr(ls, "BUILTIN_CAPS_PATH", tmp_path / "capabilities.json")


def test_learn_turn_creates_capability_from_weak_turn(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    turn = {"query": "fire up my edit setup", "name": "run_applescript",
            "args": {"script": "tell ..."}, "result": {"status": "ok"}}

    def fake_propose(turns, existing, **kw):
        assert turns[0]["query"] == "fire up my edit setup"
        return [{"id": "edit-setup", "examples": ["fire up my edit setup"],
                 "primitive": "run_applescript", "template": "tell ...",
                 "description": "Open editing apps"}]

    events = il.learn_turn(turn, [], propose=fake_propose)
    assert len(events) == 1 and events[0].id == "edit-setup"
    assert any(c["id"] == "edit-setup" for c in ls.load_user_caps())


def test_learn_turn_returns_empty_when_model_raises(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)

    def boom(turns, existing, **kw):
        raise RuntimeError("network down")

    events = il.learn_turn({"query": "x", "name": "open_url", "args": {}, "result": {}},
                           [], propose=boom)
    assert events == []


def test_learn_turn_returns_empty_when_nothing_learned(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    events = il.learn_turn({"query": "x", "name": "open_url", "args": {}, "result": {}},
                           [], propose=lambda turns, existing, **kw: [])
    assert events == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_incremental_learner.py -v`
Expected: FAIL (`ModuleNotFoundError: No module named 'incremental_learner'`)

- [ ] **Step 3: Implement**

Create `src/incremental_learner.py`:

```python
"""
incremental_learner.py — learn from a single command the moment it succeeds.

When a tool call succeeds on a WEAKLY-grounded turn (the model improvised
something not already covered), this turns that one turn into a learned
capability immediately, using the same proposal logic as the batch
retrospective. Best-effort: any failure returns [] and is swallowed by the
caller, which runs this off the audio/turn path.
"""
from __future__ import annotations

import retrospective
import learning_store


def learn_turn(turn: dict, existing_view: list[dict], *,
               propose=retrospective.propose_updates) -> list[learning_store.LearningEvent]:
    """Learn from one (query, tool_call) turn. Returns LearningEvents (possibly empty)."""
    try:
        updates = propose([turn], existing_view)
    except Exception:  # noqa: BLE001 — learning is best-effort
        return []
    if not updates:
        return []
    try:
        return learning_store.apply_updates(updates)
    except Exception:  # noqa: BLE001
        return []
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_incremental_learner.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/incremental_learner.py tests/test_incremental_learner.py
git commit -m "feat: incremental_learner — learn from a single successful turn"
```

---

## Task 7: retrospective CLI — `--journal` and `--undo`

**Files:**
- Modify: `src/retrospective.py` (the `if __name__ == "__main__":` block, lines ~335-357)
- Test: manual (CLI), no unit test (thin argparse wiring over already-tested store functions)

**Interfaces:**
- Consumes: `learning_store.build_journal`, `learning_store.undo`.
- Produces: `python retrospective.py --journal` prints a table; `python retrospective.py --undo <id>` reverts and prints the result.

- [ ] **Step 1: Implement**

In `src/retrospective.py`, replace the argparse section in `__main__` (after `.add_argument("--session-file", ...)`) — add two arguments and branch before the default run:

```python
    parser.add_argument("--journal", action="store_true",
                        help="print the capability journal (what you've learned) and exit")
    parser.add_argument("--undo", type=str, default=None, metavar="ID",
                        help="undo the most recent learned change for capability ID and exit")
    args = parser.parse_args()

    import learning_store

    if args.undo:
        ok = learning_store.undo(args.undo)
        print(f"[journal] {'undone' if ok else 'nothing to undo for'} {args.undo}")
        raise SystemExit(0)

    if args.journal:
        header, cards = learning_store.build_journal()
        print(f"\n  {header['capabilities']} capabilities · "
              f"{header['learned']} learned by you · {header['commands']} commands run\n")
        for c in cards:
            tag = "✦" if c.origin == "learned" else " "
            used = f"{c.times_used}×" if c.times_used else "—"
            print(f"  {tag} [{c.id}] {c.description}  ({used}, conf {c.confidence})")
            if c.examples:
                print(f"      e.g. {'; '.join(c.examples[:3])}")
        print()
        raise SystemExit(0)
```

(Delete the now-duplicated `args = parser.parse_args()` line that previously followed the `--session-file` argument; keep the existing default-run code below for the no-flag case.)

- [ ] **Step 2: Verify manually**

Run: `cd src && python retrospective.py --journal`
Expected: prints the header line and a list of shipped capabilities (no crash even with no learned caps / no sessions).

Run: `cd src && python retrospective.py --undo nonexistent-id`
Expected: prints `[journal] nothing to undo for nonexistent-id`

- [ ] **Step 3: Confirm existing tests still pass**

Run: `pytest tests/test_retrospective.py -v`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/retrospective.py
git commit -m "feat: retrospective CLI --journal and --undo"
```

---

## Task 8: voice_agent — pure novelty helpers + capture per-turn grounding

**Files:**
- Modify: `src/voice_agent.py` (add `_last_turn` global + helpers; set it in `_inject_capability_context`; pass `capability_id` in `_handle_tool_call`)
- Test: `tests/test_voice_agent.py` (add pure-helper tests)

**Interfaces:**
- Produces (module-level, pure, importable):
  - `_should_learn(grounding: str | None, status: str) -> bool` — `True` iff `grounding == "WEAK"` and `status == "ok"`.
  - `_capability_id_for(last_turn: dict | None) -> str | None` — returns `last_turn["top_id"]` when `last_turn["grounding"] == "STRONG"`, else `None`.
  - `_last_turn: dict | None` — `{"query": str, "grounding": "STRONG"|"WEAK", "top_id": str|None}`, set per turn.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_voice_agent.py`:

```python
def test_should_learn_only_on_weak_success():
    import voice_agent as va
    assert va._should_learn("WEAK", "ok") is True
    assert va._should_learn("STRONG", "ok") is False
    assert va._should_learn("WEAK", "error") is False
    assert va._should_learn(None, "ok") is False


def test_capability_id_for_only_when_strong():
    import voice_agent as va
    assert va._capability_id_for({"grounding": "STRONG", "top_id": "web-search"}) == "web-search"
    assert va._capability_id_for({"grounding": "WEAK", "top_id": "web-search"}) is None
    assert va._capability_id_for(None) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_voice_agent.py -k "should_learn or capability_id_for" -v`
Expected: FAIL (`AttributeError: module 'voice_agent' has no attribute '_should_learn'`)

- [ ] **Step 3: Implement**

In `src/voice_agent.py`, near the other module globals (around line 56-58 where `_session`/`_ipc` are declared), add:

```python
_last_turn: "dict | None" = None
```

Add these pure helpers (place them just above `_inject_capability_context`, ~line 505):

```python
def _should_learn(grounding: "str | None", status: str) -> bool:
    """A successful tool call on a weakly-grounded turn is 'something new'."""
    return grounding == "WEAK" and status == "ok"


def _capability_id_for(last_turn: "dict | None") -> "str | None":
    """The capability a turn used, only when retrieval was confident (STRONG)."""
    if last_turn and last_turn.get("grounding") == "STRONG":
        return last_turn.get("top_id")
    return None
```

In `_inject_capability_context`, after computing `results`/`grounding` (right after line 513 `grounding = _cap_index.grounding(results)`), record the turn:

```python
        global _last_turn
        _last_turn = {
            "query": transcript,
            "grounding": grounding,
            "top_id": results[0].capability.id if results else None,
        }
```

In `_handle_tool_call`, change the session logging line (line 573) to attach the capability id:

```python
    if _session:
        _session.tool_call(name, args, result, exec_time,
                           capability_id=_capability_id_for(_last_turn))
```

- [ ] **Step 4: Run tests**

Run: `pytest tests/test_voice_agent.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/voice_agent.py tests/test_voice_agent.py
git commit -m "feat: voice_agent captures per-turn grounding + tags tool calls with capability_id"
```

---

## Task 9: voice_agent — fire incremental learner on weak+success, broadcast `learned`

**Files:**
- Modify: `src/voice_agent.py` (`_handle_tool_call` + a new async runner)
- Test: manual (live) — the trigger logic was unit-tested in Task 8; this wires it.

**Interfaces:**
- Consumes: `incremental_learner.learn_turn`, `_should_learn`, `_last_turn`, `_cap_index`, `_ipc`, `learning_store.LearningEvent.to_ipc`.
- Produces: `async def _run_incremental_learner(turn: dict) -> None` — runs `learn_turn` in the default executor (it makes a blocking HTTP call), then broadcasts each `learned` IPC event, prints a terminal nudge, and refreshes the retrieval index.

- [ ] **Step 1: Implement the async runner**

In `src/voice_agent.py`, add near `_handle_tool_call` (it needs `asyncio`, already imported):

```python
async def _run_incremental_learner(turn: dict) -> None:
    """Learn from one successful, weakly-grounded turn — off the turn path."""
    if not _MEMORY_ENABLED or _cap_index is None:
        return
    import incremental_learner
    existing = [
        {"id": c.id, "description": c.description, "examples": c.examples}
        for c in _cap_index._caps
    ]
    loop = asyncio.get_event_loop()
    try:
        events = await loop.run_in_executor(
            None, lambda: incremental_learner.learn_turn(turn, existing))
    except Exception as e:  # noqa: BLE001
        _log(f"learn failed: {e}")
        return
    if not events:
        return
    for ev in events:
        verb = "Learned" if ev.action == "new_capability" else "Now also"
        print(f"\n✦  {verb}: {ev.phrase!r}", flush=True)
        _log(f"LEARNED {ev.action} {ev.id} {ev.phrase!r}")
        if _ipc:
            _ipc.broadcast(ev.to_ipc())
    try:
        _cap_index.refresh()
    except Exception:  # noqa: BLE001
        pass
```

- [ ] **Step 2: Wire the trigger into `_handle_tool_call`**

In `_handle_tool_call`, after the IPC `tool_call` broadcast (after line 575) and before sending the function_call_output, add:

```python
    if _should_learn(_last_turn.get("grounding") if _last_turn else None, status):
        turn = {"query": (_last_turn or {}).get("query"),
                "name": name, "args": args, "result": result}
        asyncio.create_task(_run_incremental_learner(turn))
```

- [ ] **Step 3: Verify it imports and the suite is green**

Run: `cd src && python -c "import voice_agent"`
Expected: no error (imports cleanly).

Run: `pytest tests/test_voice_agent.py -v`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/voice_agent.py
git commit -m "feat: voice_agent fires incremental learner on weak+success and broadcasts learned"
```

---

## Task 10: ipc_server + voice_agent — inbound journal/undo/edit/delete

**Files:**
- Modify: `src/ipc_server.py` (callbacks + dispatch)
- Modify: `src/voice_agent.py` (register handlers in the `--ipc` setup block, ~lines 716-720)
- Test: `tests/test_ipc.py`

**Interfaces:**
- Produces on `IPCServer`: callback attributes `on_request_journal: Callable | None`, `on_undo_learning: Callable[[str], None] | None`, `on_edit_capability: Callable[[str, str | None, list | None], None] | None`, `on_delete_capability: Callable[[str], None] | None`; `_dispatch` routes the matching message types.
- Consumes in voice_agent: `learning_store.journal_payload`, `learning_store.undo`, `learning_store.edit_capability`, `learning_store.delete_capability`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_ipc.py`:

```python
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from ipc_server import IPCServer  # noqa: E402


def test_dispatch_request_journal_calls_callback():
    srv = IPCServer()
    called = {"n": 0}
    srv.on_request_journal = lambda: called.__setitem__("n", called["n"] + 1)
    srv._dispatch({"type": "request_journal"})
    assert called["n"] == 1


def test_dispatch_undo_passes_id():
    srv = IPCServer()
    got = {}
    srv.on_undo_learning = lambda cid: got.__setitem__("id", cid)
    srv._dispatch({"type": "undo_learning", "id": "edit-setup"})
    assert got["id"] == "edit-setup"


def test_dispatch_edit_passes_fields():
    srv = IPCServer()
    got = {}
    srv.on_edit_capability = lambda cid, desc, ex: got.update(id=cid, desc=desc, ex=ex)
    srv._dispatch({"type": "edit_capability", "id": "x", "description": "d", "examples": ["a"]})
    assert got == {"id": "x", "desc": "d", "ex": ["a"]}


def test_dispatch_delete_passes_id():
    srv = IPCServer()
    got = {}
    srv.on_delete_capability = lambda cid: got.__setitem__("id", cid)
    srv._dispatch({"type": "delete_capability", "id": "x"})
    assert got["id"] == "x"


def test_dispatch_ignores_undo_without_id():
    srv = IPCServer()
    got = {"n": 0}
    srv.on_undo_learning = lambda cid: got.__setitem__("n", got["n"] + 1)
    srv._dispatch({"type": "undo_learning"})  # no id
    assert got["n"] == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_ipc.py -v`
Expected: FAIL (callbacks not routed; e.g. `request_journal` is a no-op)

- [ ] **Step 3: Implement in `src/ipc_server.py`**

In `__init__`, add after `self.on_text_input = None`:

```python
        self.on_request_journal: Callable | None = None
        self.on_undo_learning: Callable[[str], None] | None = None
        self.on_edit_capability: Callable[[str, "str | None", "list | None"], None] | None = None
        self.on_delete_capability: Callable[[str], None] | None = None
```

In `_dispatch`, add before the `# "ping"` comment:

```python
        elif t == "request_journal" and self.on_request_journal:
            self.on_request_journal()
        elif t == "undo_learning" and self.on_undo_learning:
            cid = (msg.get("id") or "").strip()
            if cid:
                self.on_undo_learning(cid)
        elif t == "edit_capability" and self.on_edit_capability:
            cid = (msg.get("id") or "").strip()
            if cid:
                self.on_edit_capability(cid, msg.get("description"), msg.get("examples"))
        elif t == "delete_capability" and self.on_delete_capability:
            cid = (msg.get("id") or "").strip()
            if cid:
                self.on_delete_capability(cid)
```

Also update the module docstring's "Swift → Python messages" list to include the four new types (documentation only).

- [ ] **Step 4: Wire handlers in `src/voice_agent.py`**

In the `if IPC_MODE and _ipc:` block (after line 719, where `on_text_input` is set), add:

```python
                        import learning_store

                        def _broadcast_journal():
                            if _ipc:
                                _ipc.broadcast(learning_store.journal_payload())

                        def _refresh_index():
                            if _cap_index is not None:
                                try:
                                    _cap_index.refresh()
                                except Exception:  # noqa: BLE001
                                    pass

                        def _after_change(_ok=True):
                            _refresh_index()
                            _broadcast_journal()

                        _ipc.on_request_journal = _broadcast_journal
                        _ipc.on_undo_learning = lambda cid: _after_change(learning_store.undo(cid))
                        _ipc.on_edit_capability = lambda cid, desc, ex: _after_change(
                            learning_store.edit_capability(cid, desc, ex))
                        _ipc.on_delete_capability = lambda cid: _after_change(
                            learning_store.delete_capability(cid))
```

- [ ] **Step 5: Run tests**

Run: `pytest tests/test_ipc.py -v && cd src && python -c "import voice_agent" && cd ..`
Expected: PASS and clean import.

- [ ] **Step 6: Commit**

```bash
git add src/ipc_server.py src/voice_agent.py tests/test_ipc.py
git commit -m "feat: IPC inbound journal/undo/edit/delete wired to learning_store"
```

---

## Task 11: PythonBridge — decode `learned`/`journal`, add send methods

**Files:**
- Modify: `VoiceOS/VoiceOS/PythonBridge.swift`
- Test: `make app` (compile) — Swift logic verified by build + manual run

**Interfaces:**
- Produces on `PythonBridge`:
  - `struct LearnedEvent: Equatable { let id, action, phrase, description, primitive: String }`
  - `struct JournalCard: Identifiable, Equatable { let id; description; examples:[String]; primitive; template; origin; learnedAt:String?; timesUsed:Int; lastUsed:String?; confidence:Double }`
  - `struct JournalHeader: Equatable { let capabilities, learned, commands: Int }`
  - State: `var learnedEvent: LearnedEvent?`, `var journalHeader: JournalHeader?`, `var journalCards: [JournalCard] = []`
  - Methods: `requestJournal()`, `undoLearning(_ id: String)`, `editCapability(_ id: String, description: String?, examples: [String]?)`, `deleteCapability(_ id: String)`

- [ ] **Step 1: Implement**

In `PythonBridge.swift`, add the model types above `@Observable final class PythonBridge`:

```swift
struct LearnedEvent: Equatable {
    let id: String
    let action: String      // "new_capability" | "added_phrasing"
    let phrase: String
    let description: String
    let primitive: String
}

struct JournalHeader: Equatable {
    let capabilities: Int
    let learned: Int
    let commands: Int
}

struct JournalCard: Identifiable, Equatable {
    let id: String
    let description: String
    let examples: [String]
    let primitive: String
    let template: String
    let origin: String       // "learned" | "shipped"
    let learnedAt: String?
    let timesUsed: Int
    let lastUsed: String?
    let confidence: Double
}
```

Add published state (after `var lastError: String?`):

```swift
    var learnedEvent: LearnedEvent?
    var journalHeader: JournalHeader?
    var journalCards: [JournalCard] = []
```

Add send methods (after `sendText`):

```swift
    func requestJournal() { send(["type": "request_journal"]) }
    func undoLearning(_ id: String) { send(["type": "undo_learning", "id": id]) }
    func deleteCapability(_ id: String) { send(["type": "delete_capability", "id": id]) }
    func editCapability(_ id: String, description: String?, examples: [String]?) {
        var msg: [String: Any] = ["type": "edit_capability", "id": id]
        if let description { msg["description"] = description }
        if let examples { msg["examples"] = examples }
        send(msg)
    }
```

In `handleMessage`'s `switch type`, add cases (before `default:`):

```swift
            case "learned":
                self.learnedEvent = LearnedEvent(
                    id: (obj["id"] as? String) ?? "",
                    action: (obj["action"] as? String) ?? "",
                    phrase: (obj["phrase"] as? String) ?? "",
                    description: (obj["description"] as? String) ?? "",
                    primitive: (obj["primitive"] as? String) ?? "")
            case "journal":
                if let header = obj["header"] as? [String: Any] {
                    self.journalHeader = JournalHeader(
                        capabilities: (header["capabilities"] as? NSNumber)?.intValue ?? 0,
                        learned: (header["learned"] as? NSNumber)?.intValue ?? 0,
                        commands: (header["commands"] as? NSNumber)?.intValue ?? 0)
                }
                let cards = (obj["cards"] as? [[String: Any]]) ?? []
                self.journalCards = cards.map { c in
                    JournalCard(
                        id: (c["id"] as? String) ?? "",
                        description: (c["description"] as? String) ?? "",
                        examples: (c["examples"] as? [String]) ?? [],
                        primitive: (c["primitive"] as? String) ?? "",
                        template: (c["template"] as? String) ?? "",
                        origin: (c["origin"] as? String) ?? "shipped",
                        learnedAt: c["learned_at"] as? String,
                        timesUsed: (c["times_used"] as? NSNumber)?.intValue ?? 0,
                        lastUsed: c["last_used"] as? String,
                        confidence: (c["confidence"] as? NSNumber)?.doubleValue ?? 0)
                }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `make app 2>&1 | grep -E "error|✓"`
Expected: `✓  VoiceOS/build/VoiceOS.app` (no errors)

- [ ] **Step 3: Commit**

```bash
git add VoiceOS/VoiceOS/PythonBridge.swift
git commit -m "feat: PythonBridge decodes learned/journal and adds journal commands"
```

---

## Task 12: CommandPalette — live "learned" nudge chip

**Files:**
- Modify: `VoiceOS/VoiceOS/CommandPalette.swift`
- Test: `make app` + manual

**Interfaces:**
- Consumes: `bridge.learnedEvent`, `bridge.undoLearning(_:)`, the existing `onDismiss`/`resultLingerSeconds` patterns.
- Produces: a `var onOpenJournal: () -> Void = {}` parameter on `CommandPalette` (wired in Task 13) used by the chip's "Edit" affordance.

- [ ] **Step 1: Implement**

In `CommandPalette.swift`, add the new closure property near `onDismiss`:

```swift
    var onOpenJournal: () -> Void = {}
```

In `body`, add a learned-nudge section after the `resultRow`/`errorRow` block (inside the `VStack`, after the `else if !bridge.spokenText.isEmpty` branch closes):

```swift
            if let learned = bridge.learnedEvent {
                learnedChip(learned)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
```

Add the animation driver alongside the existing `.animation(...)` modifiers:

```swift
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.learnedEvent)
```

Add an auto-clear task alongside the existing spokenText `.task(id:)`:

```swift
        .task(id: bridge.learnedEvent) {
            guard bridge.learnedEvent != nil else { return }
            try? await Task.sleep(nanoseconds: resultLingerSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            bridge.learnedEvent = nil
        }
```

Add the chip view (near `resultRow`):

```swift
    private func learnedChip(_ event: LearnedEvent) -> some View {
        let verb = event.action == "new_capability" ? "Learned" : "Now also"
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("\(verb) \u{201C}\(event.phrase)\u{201D}")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") {
                bridge.undoLearning(event.id)
                bridge.learnedEvent = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            Button("Edit") {
                bridge.learnedEvent = nil
                onOpenJournal()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.secondary)
        }
        .font(.system(size: 12, weight: .medium))
    }
```

- [ ] **Step 2: Build**

Run: `make app 2>&1 | grep -E "error|✓"`
Expected: `✓  VoiceOS/build/VoiceOS.app`

- [ ] **Step 3: Commit**

```bash
git add VoiceOS/VoiceOS/CommandPalette.swift
git commit -m "feat: palette shows a live 'learned' nudge chip with Undo/Edit"
```

---

## Task 13: JournalWindow + second hotkey + Makefile + AppDelegate wiring

**Files:**
- Create: `VoiceOS/VoiceOS/JournalWindow.swift`
- Modify: `VoiceOS/VoiceOS/VoiceOSApp.swift`
- Modify: `Makefile` (add the new source)
- Test: `make app` + manual checklist

**Interfaces:**
- Consumes: `PythonBridge` (`journalHeader`, `journalCards`, `requestJournal`, `undoLearning`, `deleteCapability`, `editCapability`); `HotkeyManager(keyCode:modifiers:onToggle:)` (existing).
- Produces: `final class JournalController { init(bridge:); func toggle(); func show(); func hide() }`.

- [ ] **Step 1: Add the source to the Makefile**

In `Makefile`, add to `SOURCES` (after `WaveformView.swift`):

```make
	VoiceOS/VoiceOS/JournalWindow.swift
```

(Keep the trailing `\` line-continuations correct — the last source line has no trailing backslash.)

- [ ] **Step 2: Create `VoiceOS/VoiceOS/JournalWindow.swift`**

```swift
import SwiftUI
import AppKit

/// The capability journal — a browsable record of what VoiceOS knows and has
/// learned, with usage and confidence. Opened with ⌥⇧Space.
struct JournalView: View {
    var bridge: PythonBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if bridge.journalCards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(bridge.journalCards) { card in
                            JournalCardRow(card: card, bridge: bridge)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear { bridge.requestJournal() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(bridge.journalHeader?.capabilities ?? bridge.journalCards.count)")
                .font(.system(size: 22, weight: .bold))
            Text("capabilities").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.secondary)
            Text("\(bridge.journalHeader?.learned ?? 0)").font(.system(size: 22, weight: .bold))
            Text("learned by you").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.secondary)
            Text("\(bridge.journalHeader?.commands ?? 0)").font(.system(size: 22, weight: .bold))
            Text("commands run").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 13))
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Nothing learned yet").font(.headline)
            Text("Go do something new — it'll show up here.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct JournalCardRow: View {
    let card: JournalCard
    var bridge: PythonBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if card.origin == "learned" {
                    Image(systemName: "sparkle").foregroundStyle(Color.accentColor).font(.system(size: 11))
                }
                Text(card.description.isEmpty ? card.id : card.description)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(card.timesUsed > 0 ? "\(card.timesUsed)× used" : "unused")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !card.examples.isEmpty {
                Text(card.examples.prefix(3).map { "\u{201C}\($0)\u{201D}" }.joined(separator: "  "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 10) {
                ConfidenceBar(value: card.confidence)
                Text(card.primitive).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if card.origin == "learned" {
                    Button("Undo") { bridge.undoLearning(card.id) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor).font(.system(size: 12))
                    Button("Delete") { bridge.deleteCapability(card.id) }
                        .buttonStyle(.plain).foregroundStyle(.red.opacity(0.8)).font(.system(size: 12))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }
}

private struct ConfidenceBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.opacity(0.8))
                    .frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(width: 80, height: 5)
    }
}

/// Hosts JournalView in a standard titled, resizable window.
final class JournalController {
    private var window: NSWindow?
    private let bridge: PythonBridge

    init(bridge: PythonBridge) { self.bridge = bridge }

    func toggle() {
        if let window, window.isVisible { hide() } else { show() }
    }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        bridge.requestJournal()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    func hide() { window?.orderOut(nil) }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "VoiceOS — Journal"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: JournalView(bridge: bridge))
        window = w
    }
}
```

- [ ] **Step 3: Wire into `VoiceOSApp.swift` (AppDelegate)**

Add properties near the existing controllers:

```swift
    private var journalController: JournalController?
    private var journalHotkey: HotkeyManager?
```

In `applicationDidFinishLaunching`, after `paletteController = PaletteController(bridge: bridge)`:

```swift
        journalController = JournalController(bridge: bridge)
```

After the existing `hotkeyManager?.register()`, add a second hotkey (⌥⇧Space — keyCode 49, optionKey | shiftKey):

```swift
        journalHotkey = HotkeyManager(
            keyCode: 49,
            modifiers: UInt32(optionKey) | UInt32(shiftKey),
            onToggle: { [weak self] in self?.journalController?.toggle() })
        journalHotkey?.register()
```

`optionKey`/`shiftKey` come from Carbon; add `import Carbon` at the top of `VoiceOSApp.swift` if not present.

Wire the palette chip's "Edit" to open the journal: in `PaletteController.buildPanel()` (CommandPalette.swift), update the `CommandPalette(...)` initializer call to pass `onOpenJournal`. Since `PaletteController` doesn't hold the `JournalController`, route via a closure set by the AppDelegate. Add to `PaletteController`:

```swift
    var onOpenJournal: () -> Void = {}
```

and in `buildPanel()` change the root view construction to:

```swift
        let rootView = CommandPalette(bridge: bridge,
                                      onDismiss: { [weak self] in self?.hide() },
                                      onOpenJournal: { [weak self] in self?.onOpenJournal() })
```

Then in `AppDelegate.applicationDidFinishLaunching`, after both controllers exist:

```swift
        paletteController?.onOpenJournal = { [weak self] in self?.journalController?.show() }
```

- [ ] **Step 4: Build**

Run: `make app 2>&1 | grep -E "error|warning|✓"`
Expected: `✓  VoiceOS/build/VoiceOS.app` with no errors.

- [ ] **Step 5: Manual verification**

Run: `./run.sh --app` (requires `OPENAI_API_KEY` in `.env`). Then:
1. Press ⌥Space — palette appears and is clickable.
2. Speak/type a novel command that succeeds (e.g. an AppleScript not covered by a shipped capability). Within a few seconds a `✦ Learned "…"` chip appears.
3. Click **Undo** — chip dismisses; capability removed.
4. Trigger another novel command, then press ⌥⇧Space — the Journal window opens showing the header counts and cards; the just-learned card has a sparkle, usage, confidence bar, Undo/Delete.
5. Click **Delete** on a learned card — it disappears and the header count drops.

- [ ] **Step 6: Commit**

```bash
git add VoiceOS/VoiceOS/JournalWindow.swift VoiceOS/VoiceOS/VoiceOSApp.swift VoiceOS/VoiceOS/CommandPalette.swift Makefile
git commit -m "feat: capability Journal window (⌥⇧Space) + palette Edit affordance"
```

---

## Task 14: Full regression + docs

**Files:**
- Modify: `CLAUDE.md` (commands), `README.md` (mention the journal), `.gitignore` (journal file)
- Test: full suite

- [ ] **Step 1: Ignore the journal file**

Confirm `memory/learning_journal.jsonl` is gitignored. Run:
`grep -q "learning_journal" .gitignore || printf "memory/learning_journal.jsonl\n" >> .gitignore`
Expected: the pattern is present afterward.

- [ ] **Step 2: Run the full Python suite**

Run: `pytest tests/test_session_log.py tests/test_learning_store.py tests/test_incremental_learner.py tests/test_retrospective.py tests/test_retrieval.py tests/test_voice_agent.py tests/test_ipc.py -v`
Expected: all PASS.

- [ ] **Step 3: Build the app**

Run: `make app 2>&1 | grep -E "error|✓"`
Expected: `✓  VoiceOS/build/VoiceOS.app`

- [ ] **Step 4: Update docs**

In `CLAUDE.md`, under the retrospective commands, add:

```bash
cd src && python retrospective.py --journal      # print what you've learned
cd src && python retrospective.py --undo <id>    # undo a learned capability
```

In `README.md`, add one line under the app section: "Press ⌥⇧Space to open the **Journal** — what VoiceOS has learned, how often you use it, and one-tap undo."

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md .gitignore
git commit -m "docs: document the capability journal + ignore learning_journal.jsonl"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- Live nudge → Tasks 9 (broadcast), 12 (chip). ✓
- Journal (browsable, counts, usage, confidence, edit/delete) → Tasks 4, 11, 13. ✓
- Trust model "learn instantly, easy undo" → Task 3 (undo), 12/13 (UI undo). ✓
- Novelty trigger "weak + success" → Tasks 8 (pure helper), 9 (wiring). ✓
- Shared learning core (DRY) → Task 5 (`propose_updates`/`call_model`), reused by Task 6. ✓
- `capability_id` on tool_call → Task 1; consumed by usage stats Task 4. ✓
- IPC additions → Tasks 10 (Python), 11 (Swift). ✓
- Terminal fallback → Task 7 (CLI `--journal`/`--undo`), Task 9 (printed nudge). ✓
- Validation-before-write → reuses `_merge_updates` (drops new caps lacking primitive+template). ✓
- Best-effort/async → Task 6 (`learn_turn` swallows errors), Task 9 (executor + create_task). ✓
- Existing tests stay green → Tasks 5, 8 explicitly re-run them. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `LearningEvent`/`JournalCard` defined once (Task 2), populated in Task 3/4, serialized in Task 4 (`journal_payload`), decoded in Swift Task 11 with matching keys (`learned_at`, `times_used`, `last_used`). `_should_learn`/`_capability_id_for` names consistent across Tasks 8–9. IPC message `type` strings match between `ipc_server` (Task 10), `journal_payload` (Task 4), `LearningEvent.to_ipc` (Task 2), and Swift decode (Task 11). ✓

**Deviation from spec (noted):** the spec's `LearningEvent` listed `name` + `summary`; this plan uses `description` (the capability's existing field) + `phrase` to avoid redundant data. Internally consistent across all tasks.
