# Visible Learning — Design

**Date:** 2026-06-20
**Status:** Approved (design); implementation pending
**Slice of:** the "VoiceOS that visibly compounds" reimagining (Phase 2, pulled forward to first)

---

## Product thesis (parent vision)

> **VoiceOS that visibly compounds.** Today it acts and forgets — the learning is
> real but invisible, you can't see what it knows, and it only ever reacts. The
> reimagined product makes *every session observably more yours*: the palette
> teaches you what it can do and what you tend to do next, it reads context to put
> the right command one keystroke away, and after each new thing it learns it shows
> you — for you to keep, tweak, or share.

No personality/mascot. The delight is **competence you can watch accumulate.**

### Phased roadmap (each phase = its own spec)

- **Phase 0 — Foundation:** stateful, bidirectional palette + richer IPC.
- **Phase 1 — Discovery:** idle palette surfaces capabilities, recent commands, fuzzy match.
- **Phase 2 — Visible Learning:** *this spec.* Pulled forward to first.
- **Phase 3 — Ambient context:** frontmost-app + time-of-day surfacing ($0, local).
- **Phase 4 — Make it yours:** shareable capability packs + first-run onboarding.

This document specifies **Phase 2 only**, pulling forward the minimum foundation it needs.

---

## Goal of this slice

Make the existing "dreaming" loop **visible and trustworthy**, in the moment and over time:

1. **Live nudge** — the instant you do something new, a lightweight acknowledgement that it was learned, with one-tap Undo/Edit.
2. **Journal** — a browsable surface to review learned capabilities, edit or delete them, and watch growth accumulate (counts, usage, confidence).

**Decisions locked during brainstorming:**

| Decision | Choice |
|---|---|
| Interaction model | Both: live nudge **and** browsable journal |
| Trust model | **Learn instantly, easy undo** (live immediately; safety via undo + validation) |
| Surface | **Palette-first, terminal fallback** (logic in Python; rich UI in SwiftUI app) |
| Novelty trigger | A tool call that **succeeds on a WEAKLY-grounded turn** |

**Non-goals (explicitly out of scope for this slice):**

- Cloud sync or shareable capability packs (Phase 4).
- In-app editing of template *code/AppleScript* (journal edits limited to name + trigger phrases + delete; power users edit JSON directly).
- Risk-tiering of learned capabilities (the instant-learn decision supersedes it).
- ML-based confidence (use a simple deterministic function).
- Idle discovery / context-awareness (Phases 1 and 3).

---

## Background: how learning works today

`src/retrospective.py` runs **once on Ctrl-C**:

1. Reads the JSONL session log.
2. Pairs successful `tool_call` events with the spoken phrase (`heard`) that triggered them.
3. Calls `gpt-4.1-mini` to either **(A)** add the user's phrasing to an existing
   capability or **(B)** create a new capability.
4. Writes the result to `memory/capabilities.user.json` (gitignored) and refreshes
   the in-process retrieval index.

This works but is invisible: no nudge, no review, no record of growth. The palette
app never receives a Ctrl-C, so today it effectively never learns interactively.

Retrieval already computes a **grounding strength** per turn
(`STRONG` when top score ≥ 0.52, or ≥ 0.40 with clear dominance; otherwise `WEAK`).

---

## Architecture

### The novelty trigger (no new classifier)

A turn is a **learning candidate** when **both**:

- at least one tool call **succeeded** (`tool_call` with `ok: true`), **and**
- the turn's retrieval grounding was **WEAK** (no existing capability strongly matched).

Rationale: strong grounding means an existing capability already covered it; weak +
success means the model improvised something new that worked — exactly what's worth
remembering. We reuse a signal the system already produces.

### Incremental learner

A new lightweight path that runs **during** the session, scoped to a **single
candidate turn**:

- Input: the spoken phrase + the successful tool call(s) for that turn.
- Calls `gpt-4.1-mini` with the **same** add-phrasing-vs-new-capability logic the
  batch retrospective uses.
- Runs **async / best-effort**: it must never block the voice turn or the next command.
- Output: a structured **learning event** (see below), or nothing (rejected/failed).

### Shared learning core (refactor)

Extract the single-pair "(phrase, tool_call) → add-phrasing | new-capability" logic
out of `retrospective.py` into one shared function. Both consumers use it:

- the **incremental learner** (one turn, live), and
- the **end-of-session batch retrospective** (whole log, on Ctrl-C — unchanged behavior).

This is a DRY refactor; the batch path's external behavior must not change, and its
existing tests must stay green.

### Learning store (`src/learning_store.py`, new)

Owns the persistence and metadata layer around `capabilities.user.json`:

- **Per-capability metadata:** `learned_at`, `source_phrase`, `times_used`,
  `last_used`, `confidence`, `origin` (`learned` | `shipped`), `status`.
- **`memory/learning_journal.jsonl`** (append-only, gitignored): one record per
  learning event capturing **before/after** so **undo is exact and reversible**.
- **Undo:** reverts the last write for a capability id to its logged prior state
  (removes an added phrase, or removes a newly created capability). If the capability
  was since manually edited, revert to the logged prior state or no-op gracefully.
- **Usage stats:** aggregated from existing session-log `tool_call` events keyed by
  `capability_id`. Requires adding `capability_id` to `tool_call` log lines (one field).
- **Confidence (deterministic, no ML):** a simple function of `times_used`, success
  rate, and the capability's typical grounding score. Documented inline.

### Learning event (shape)

```json
{
  "id": "edit-setup-launch",
  "action": "new_capability",          // or "added_phrasing"
  "name": "Fire up my edit setup",
  "summary": "Opens Premiere and OBS, switches to the recording scene",
  "phrase": "fire up my edit setup",
  "primitive": "run_applescript",
  "learned_at": "2026-06-20T14:03:11Z"
}
```

### IPC protocol additions

Outbound (Python → Swift):

- `learned` — `{ id, name, summary, phrase, action }` → triggers the live nudge.
- `journal` — full list of learned/shipped capabilities with stats (sent on request).

Inbound (Swift → Python):

- `undo_learning` — `{ id }`
- `edit_capability` — `{ id, name?, phrases? }`
- `delete_capability` — `{ id }`
- `request_journal` — (no args)

`PythonBridge.swift` gains matching publishers/state and send-methods;
`src/ipc_server.py` gains the new handlers.

---

## Data flow (live learn)

```
voice → transcribe → retrieval (grounding = WEAK) → model calls primitive → actions OK
  └─► voice_agent / wake_listener flags turn as learning-candidate (weak + success)
        └─► incremental learner (gpt-4.1-mini, async, single turn)
              → shared learning core decides add-phrasing | new-capability
              → learning_store writes capabilities.user.json + appends learning_journal.jsonl
              → retrieval index refreshed in-process
              → IPC emits `learned`  ──►  palette nudge chip   (terminal: prints a line)
```

---

## Surfaces

### Live nudge (palette)

- After the result row, a transient chip slides in:
  `✦ Learned "fire up my edit setup" · Undo · Edit`
- Lingers like the spoken result (auto-clears after the linger window); dismissable.
- **Undo** sends `undo_learning` and confirms removal.
- **Edit** opens the journal window focused on that entry.
- **Terminal fallback:** prints `✦ learned "name" — undo: python retrospective.py --undo <id>`.

### Journal (new second window in the SwiftUI app)

- Opened via a global shortcut (e.g. ⌥⇧Space) or an affordance on the palette.
- **Header (the "watch it accumulate" moment):**
  `22 capabilities · 6 learned by you · 142 commands run`.
- **Scrollable list of cards**, each showing: name, trigger phrases, what it does
  (primitive + summary), learned date, a **times-used bar**, and confidence.
- **Per-card actions:** edit name / trigger phrases, delete, "try it."
- **Empty state:** friendly nudge ("Nothing learned yet — go do something new").
- **Terminal fallback:** `python retrospective.py --journal` prints a table;
  `python retrospective.py --undo <id>` reverts.

---

## Error handling

- **Learner failure** (model/network): no nudge, logged, session continues unaffected
  (learning is strictly best-effort and async).
- **Malformed learned capability** (bad template/missing fields): validated before
  write; rejected candidates are logged, never surfaced.
- **Undo after manual edit:** revert to the logged prior state, or no-op with a clear
  message if the state has diverged.
- **Empty journal request:** friendly empty state.
- **Concurrency:** the incremental learner runs off the audio/turn path so it can never
  delay a command; writes to the store are serialized.

---

## Testing

Pure unit tests (mock the `gpt-4.1-mini` call — no network):

- Novelty detection: `weak + success` → candidate; `strong + success` → not a candidate;
  `weak + failure` → not a candidate.
- Shared learning core: produces correct `added_phrasing` vs `new_capability` events.
- Learning store: applying an event mutates `capabilities.user.json` correctly;
  **undo reverts exactly** to prior state (both event types).
- Usage-stat aggregation from session-log `tool_call` events keyed by `capability_id`.
- Confidence function: deterministic, monotonic in usage/success.
- Journal serialization round-trips.
- IPC round-trip: `learned` event encode/decode; `undo_learning` command handling.

Regression:

- Existing `tests/test_retrospective.py` (batch path) stays green after the core refactor.
- Existing `tests/test_retrieval.py` stays green (index refresh still works).

Swift:

- `tests/test_build.py` continues to build `VoiceOS.app`.
- Manual visual check via `./run.sh --app`: trigger a novel command, see the nudge,
  Undo, open the journal, edit and delete a card.

---

## Foundation pulled forward (minimum)

From Phase 0, only what this slice needs:

- IPC bridge gains the event/command types listed above.
- The SwiftUI app gains a **second window** (journal) and a **nudge chip** in the palette.

Explicitly **not** building idle-discovery or context-awareness here.

---

## Files touched (anticipated)

- `src/retrospective.py` — extract shared learning core; add `--journal` and `--undo` CLI.
- `src/learning_store.py` — **new**: metadata, journal, undo, usage aggregation, confidence.
- `src/voice_agent.py`, `src/wake_listener.py` — flag candidate turns; invoke incremental learner async.
- `src/ipc_server.py` — new outbound events + inbound handlers.
- `src/session_log.py` — add `capability_id` to `tool_call` events.
- `VoiceOS/VoiceOS/PythonBridge.swift` — new state + send methods.
- `VoiceOS/VoiceOS/CommandPalette.swift` — nudge chip.
- `VoiceOS/VoiceOS/JournalWindow.swift` — **new**: journal window + controller.
- `VoiceOS/VoiceOS/HotkeyManager.swift` — optional second shortcut for the journal.
- `Makefile` — add the new Swift source.
- Tests under `tests/` as listed above.
