#!/usr/bin/env python3
"""
test_voice_agent.py — unit tests for pure functions in voice_agent.py.

Tests the wake-word gate (is_wake) thoroughly: standard phrases, NZ-accent
mishears of "chat", joined forms, false positives that must not fire.

    pytest test_voice_agent.py
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest  # noqa: E402

pytest.importorskip("sounddevice")   # skip gracefully in envs without audio
pytest.importorskip("websockets")

from voice_agent import is_wake  # noqa: E402


# ---------------------------------------------------------------------------
# Phrases that MUST trigger the wake gate
# ---------------------------------------------------------------------------

SHOULD_WAKE = [
    # canonical forms
    "hey chat, open Spotify",
    "Hey Chat play music",
    "hey chat open the browser",
    # normalised openers
    "hay chat do something",
    "hi chat open terminal",
    "he chat pause",
    "ok chat, stop recording",
    "okay chat save the project",
    "aye chat resume",
    "eh chat open notes",
    # NZ-accent mishears of "chat" that gpt-4o-transcribe produces
    "hey chut, open spotify",
    "hey chit pause",
    "hey jet, search for something",
    "hey jat open safari",
    "hey ject start recording",
    "hey chot cut here",
    "hey chad launch chrome",
    "hey chap save",
    "hey shot pause",
    "hey char open finder",
    "hey chant take a note",
    # joined forms (no space between opener and word)
    "heychat open spotify",
    "haychat pause",
    "heychad resume",
    "happychat open terminal",
    "achat search",
    "eychat do something",
    # punctuation is stripped before matching
    "hey chat! open spotify",
    "hey chat: do that",
    "hey chat. save the project",
    # leading/trailing whitespace
    "  hey chat, open spotify  ",
    # extra words after the wake word
    "hey chat open spotify and play some jazz",
    "hey chat what is on my screen",
]


@pytest.mark.parametrize("phrase", SHOULD_WAKE)
def test_is_wake_returns_true(phrase):
    assert is_wake(phrase), f"Expected wake=True for {phrase!r}"


# ---------------------------------------------------------------------------
# Phrases that MUST NOT trigger the wake gate
# ---------------------------------------------------------------------------

SHOULD_NOT_WAKE = [
    # no wake word at all
    "open Spotify",
    "pause the music",
    "save my project",
    "what is on my screen",
    # wrong word after opener
    "hey there, open Spotify",
    "hey you",
    "ok go ahead",
    # partial / near-miss forms
    "hey chatting about things",   # "chatting" ≠ "chat\b"
    "hey chatter",                  # "chatter" ≠ "chat\b"
    "heychatter",                   # "heychat" must have \b after it
    # empty / whitespace only
    "",
    "   ",
    # just the opener, no second word
    "hey",
    "ok",
]


@pytest.mark.parametrize("phrase", SHOULD_NOT_WAKE)
def test_is_wake_returns_false(phrase):
    assert not is_wake(phrase), f"Expected wake=False for {phrase!r}"


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

def test_is_wake_none_input():
    # voice_agent passes `(transcript or "").lower()`, so None is safe
    assert not is_wake(None)  # type: ignore[arg-type]


def test_is_wake_case_insensitive():
    assert is_wake("HEY CHAT open spotify")
    assert is_wake("HEY CHAT OPEN SPOTIFY")


def test_is_wake_normalises_multiple_spaces():
    # double space between words still matches
    assert is_wake("hey  chat  pause")


def test_is_wake_normalises_punctuation_to_space():
    # commas, periods, exclamation marks are stripped
    assert is_wake("hey,chat,open spotify")
    assert is_wake("hey-chat open spotify")


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


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
