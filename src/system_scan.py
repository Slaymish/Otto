"""
system_scan.py — detect installed apps and CLI tools at Otto startup.

Results are cached after the first call so retrieval.py and voice_agent.py
both read from a single scan without repeating the filesystem walk.
"""
from __future__ import annotations

import shutil
from pathlib import Path

_app_names: set[str] | None = None  # lowercase names without .app
_cli_tools: dict[str, bool] | None = None


def installed_apps() -> set[str]:
    """Return a set of lowercase app names (no .app suffix) from /Applications
    and ~/Applications. Result is cached after the first call."""
    global _app_names
    if _app_names is not None:
        return _app_names

    names: set[str] = set()
    for base in (Path("/Applications"), Path.home() / "Applications"):
        if base.is_dir():
            for p in base.iterdir():
                if p.suffix == ".app":
                    names.add(p.stem.lower())
                elif p.is_dir() and p.suffix == "":
                    # subdirectory bundles (e.g. /Applications/Adobe/...)
                    for sub in p.iterdir():
                        if sub.suffix == ".app":
                            names.add(sub.stem.lower())

    _app_names = names
    return _app_names


_CLI_CHECKS = {
    "claude": "claude (Claude Code CLI)",
    "ffmpeg": "ffmpeg",
    "yt-dlp": "yt-dlp",
    "obs": "obs (CLI)",
}


def installed_clis() -> dict[str, bool]:
    """Return {tool_name: is_installed} for common CLIs Otto might use."""
    global _cli_tools
    if _cli_tools is not None:
        return _cli_tools
    _cli_tools = {name: bool(shutil.which(name)) for name in _CLI_CHECKS}
    return _cli_tools


def scan_system() -> str:
    """Format installed context as a short string for the system prompt."""
    apps = installed_apps()
    clis = installed_clis()

    lines: list[str] = []
    lines.append("INSTALLED TOOLS:")
    lines.append(f"  Apps ({len(apps)} total, showing notable): "
                 + ", ".join(sorted(a for a in apps if a in {
                     "spotify", "obs", "obs studio", "adobe premiere pro",
                     "final cut pro", "logic pro", "xcode", "arc", "google chrome",
                     "firefox", "notion", "slack", "zoom", "figma", "discord",
                     "1password", "raycast", "obsidian",
                 })))

    active_clis = [label for name, label in _CLI_CHECKS.items() if clis.get(name)]
    if active_clis:
        lines.append("  CLIs: " + ", ".join(active_clis))

    if clis.get("claude"):
        lines.append("  Claude Code is available — use terminal-run to delegate complex tasks.")
    else:
        lines.append("  Claude Code CLI not installed — terminal-run will fail.")

    return "\n".join(lines)
