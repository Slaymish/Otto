"""
incremental_learner.py — learn from a single command the moment it succeeds.

When a tool call succeeds on a WEAKLY-grounded turn (the model improvised
something not already covered), this turns that one turn into a learned
capability immediately.

Following the Alphero spike lesson — keep the model out of the latency path —
there are two routes:
  • Deterministic (no model): if the turn's top retrieval match was a NEAR MISS
    (same intent, just new phrasing), attach the phrasing to it directly.
  • Model (only when truly novel): mint a brand-new capability, off the turn
    path, with a short timeout so it fails fast and never blocks the experience.

Best-effort throughout: any failure returns [] and is swallowed by the caller.
"""
from __future__ import annotations

import retrospective
import learning_store

_MODEL_TIMEOUT_S = 8  # interactive: fail fast, never block the experience


def learn_turn(turn: dict, existing_view: list[dict], *,
               near_miss_id: "str | None" = None,
               propose=None) -> list[learning_store.LearningEvent]:
    """Learn from one (query, tool_call) turn. Returns LearningEvents (possibly empty)."""
    phrase = retrospective._strip_wake((turn.get("query") or "")).strip()

    # Deterministic fast path: a near-miss existing capability → just add the phrasing.
    if near_miss_id and phrase:
        try:
            return learning_store.apply_updates([{"id": near_miss_id, "examples": [phrase]}])
        except Exception:  # noqa: BLE001
            return []

    # Otherwise ask the model to mint a new capability — off-path, fail-fast.
    proposer = propose or (lambda turns, existing: retrospective.propose_updates(
        turns, existing,
        call=lambda p, **k: retrospective.call_model(p, timeout=_MODEL_TIMEOUT_S)))
    try:
        updates = proposer([turn], existing_view)
    except Exception:  # noqa: BLE001 — learning is best-effort
        return []
    if not updates:
        return []
    try:
        return learning_store.apply_updates(updates)
    except Exception:  # noqa: BLE001
        return []
