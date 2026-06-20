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


def test_apply_and_undo_builtin_overlay(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    # a shipped (builtin) capability, with no user overlay yet
    (tmp_path / "capabilities.json").write_text(json.dumps([
        {"id": "app-open", "description": "open an app",
         "examples": ["open Spotify"], "primitive": "run_applescript",
         "template": "tell application ..."}]))
    events = ls.apply_updates([{"id": "app-open", "examples": ["fire up spotify"]}])
    # teaching a new phrasing for an existing builtin is an added_phrasing, not a new capability
    assert len(events) == 1 and events[0].action == "added_phrasing"
    overlay = next(c for c in ls.load_user_caps() if c["id"] == "app-open")
    assert "fire up spotify" in overlay["examples"]
    assert "open Spotify" in overlay["examples"]  # builtin examples preserved
    # undo removes the overlay entirely (reverts to the builtin passthrough)
    assert ls.undo("app-open") is True
    assert all(c["id"] != "app-open" for c in ls.load_user_caps())


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
