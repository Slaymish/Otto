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


def test_learn_turn_near_miss_adds_phrasing_without_model(tmp_path, monkeypatch):
    _point(monkeypatch, tmp_path)
    ls.save_user_caps([{"id": "thing", "description": "d", "examples": ["foo"],
                        "primitive": "open_url", "template": "t", "source": "learned"}])

    def boom(turns, existing, **kw):
        raise AssertionError("model must NOT be called on a near miss")

    # query carries a wake word — it must be stripped before storing the phrasing
    turn = {"query": "hey chat, do the thing", "name": "open_url",
            "args": {}, "result": {"status": "ok"}}
    events = il.learn_turn(turn, [], near_miss_id="thing", propose=boom)
    assert len(events) == 1 and events[0].action == "added_phrasing"
    cap = next(c for c in ls.load_user_caps() if c["id"] == "thing")
    assert "do the thing" in cap["examples"]


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
