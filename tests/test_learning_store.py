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
