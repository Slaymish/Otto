#!/usr/bin/env python3
"""
test_build.py — verify that `make app` produces a valid, runnable Otto.app
bundle using only Xcode Command Line Tools (no full Xcode required).

Invokes the Swift compiler, so this test is slow (~30–90s on a cold build,
a few seconds on a warm incremental build).  Run explicitly when touching the
Makefile or any Otto Swift source file:

    pytest tests/test_build.py -v
"""
from __future__ import annotations

import os
import plistlib
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

PROJECT_ROOT = Path(__file__).parent.parent
APP_PATH = PROJECT_ROOT / "Otto" / "build" / "Otto.app"
BINARY_PATH = APP_PATH / "Contents" / "MacOS" / "Otto"
PLIST_PATH = APP_PATH / "Contents" / "Info.plist"
ENTITLE_PATH = PROJECT_ROOT / "Otto" / "Otto" / "Otto.entitlements"


def _swiftc_available() -> bool:
    result = subprocess.run(
        ["xcrun", "-f", "swiftc"], capture_output=True
    )
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def built_app() -> Path:
    """Run `make app` once per test-module; return the .app path."""
    if not _swiftc_available():
        pytest.skip("swiftc not found — install Command Line Tools: xcode-select --install")

    result = subprocess.run(
        ["make", "app"],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            f"`make app` failed (exit {result.returncode}):\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return APP_PATH


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_make_app_succeeds(built_app: Path) -> None:
    assert built_app.is_dir(), f"Expected .app bundle at {built_app}"


def test_bundle_structure(built_app: Path) -> None:
    assert (built_app / "Contents").is_dir()
    assert (built_app / "Contents" / "MacOS").is_dir()
    assert BINARY_PATH.exists(), "Missing binary Otto/build/Otto.app/Contents/MacOS/Otto"
    assert PLIST_PATH.exists(), "Missing Info.plist"


def test_binary_is_executable(built_app: Path) -> None:
    mode = BINARY_PATH.stat().st_mode
    assert mode & stat.S_IXUSR, "Binary is not user-executable"


def test_info_plist_substitutions(built_app: Path) -> None:
    """Xcode build-setting placeholders must be replaced with real values."""
    with open(PLIST_PATH, "rb") as f:
        plist = plistlib.load(f)

    raw_text = PLIST_PATH.read_text()
    assert "$(" not in raw_text, (
        "Info.plist still contains unsubstituted Xcode variables:\n"
        + "\n".join(l for l in raw_text.splitlines() if "$(" in l)
    )

    assert plist["CFBundleExecutable"] == "Otto"
    assert plist["CFBundleIdentifier"] == "com.otto.app"
    assert plist["CFBundleName"] == "Otto"
    assert plist.get("LSUIElement") is True, "LSUIElement must be True (accessory app)"


def test_codesign_valid(built_app: Path) -> None:
    result = subprocess.run(
        ["codesign", "--verify", "--strict", str(built_app)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"codesign --verify failed:\n{result.stderr}"
    )


def test_no_unlinked_symbols(built_app: Path) -> None:
    """nm should not show any undefined symbols the binary actually needs."""
    result = subprocess.run(
        ["nm", "-u", str(BINARY_PATH)],
        capture_output=True,
        text=True,
    )
    # Filter to symbols that are truly unresolved (nm marks them with ' U ')
    undefined = [
        line for line in result.stdout.splitlines()
        if line.strip().startswith("U ")
        # Stub symbols starting with '_$s' are Swift runtime stubs — expected.
        and "NewEventHandlerUPP" in line
    ]
    assert not undefined, (
        "Binary references removed Carbon symbol NewEventHandlerUPP — "
        "check HotkeyManager.swift:\n" + "\n".join(undefined)
    )
