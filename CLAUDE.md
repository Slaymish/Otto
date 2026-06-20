# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run (creates venv, installs deps, launches)
./run.sh                        # push-to-talk: press ENTER to talk
./run.sh --local                # local on-device wake word (OpenWakeWord + faster-whisper, $0 idle)
./run.sh --hotkey               # hold Right Control anywhere to talk
./run.sh --wake                 # cloud wake word "hey chat" (streams continuously — NOT $0 idle)
./run.sh --app                  # native SwiftUI command palette (⌥Space to summon; auto-builds first run)

# Build the SwiftUI app (Xcode Command Line Tools only — no full Xcode)
make app                        # → Otto/build/Otto.app
make clean                      # remove build output

# Mic selection (any mode)
OTTO_MIC=Scarlett ./run.sh

# Run retrospective manually (learn from last N sessions)
cd src && python retrospective.py
cd src && python retrospective.py --sessions 3
cd src && python retrospective.py --journal      # print what you've learned
cd src && python retrospective.py --undo <id>    # undo a learned capability

# Test individual tools without OpenAI
cd src && python actions.py run_applescript 'tell application "Spotify" to play'
cd src && python actions.py open_url "https://example.com"
# (also works with legacy recipe names: open_app, play_music, web_search, etc.)

# Tests
pip install -r requirements-dev.txt
pytest                           # all tests
pytest tests/test_retrieval.py   # capability retrieval grounding tests (needs embedding model)
pytest tests/test_retrospective.py  # dreaming logic, pure — no network needed
pytest tests/test_session_log.py    # JSONL logger write/read cycle, pure
pytest tests/test_voice_agent.py    # wake-word gate (is_wake), pure
pytest tests/test_build.py -v       # builds Otto.app via swiftc — slow, run when touching Swift/Makefile
python tests/test_loop.py "open Spotify"  # live end-to-end (needs OPENAI_API_KEY)
```

All Python is run from within the `.venv` that `run.sh` creates. Scripts in `src/` import each other directly (no package install needed; they find siblings by path).

## Architecture

### The main flow

```
startup: system_scan.py scans /Applications → installed app set
         retrieval.py loads capabilities.json, drops entries whose required_apps
         aren't installed, embeds all examples (cached after first run)

voice → gpt-realtime-2 transcribes → retrieval.py embeds query + searches filtered index
→ RETRIEVED CAPABILITIES + CURRENT SCREEN (if recent) injected as system context
→ model calls a primitive tool → actions.py executes it
→ screen snapshot fires in background (screen cache updated)
→ model speaks confirmation → session_log.py writes JSONL
→ (on Ctrl-C) retrospective.py reads log, calls gpt-4.1-mini, writes capabilities.user.json
```

The model has **no hardcoded routing rules**. It receives retrieved capability templates as recipes and fills in the parameters.

### Entry points

- **`src/voice_agent.py`** — cloud modes (PTT / hotkey / wake word "hey chat") **and** the SwiftUI back-end (`--ipc`). Opens a WebSocket to `wss://api.openai.com/v1/realtime`, streams audio, gates on the wake word regex, injects capability context, and dispatches tool calls to `actions.py`. Reconnects automatically on the 60-min API session cap. With `--ipc` it also starts an `IPCServer` and broadcasts waveform/transcript/spoken/tool_call events to the Swift UI (and accepts `voice_start`/`voice_stop`/`text_input` from it).
- **`src/wake_listener.py`** — local `--local` mode. Two-stage pipeline: OpenWakeWord scores every 80ms frame ($0 CPU), then faster-whisper transcribes only post-wake audio. Once the command text is known, it opens a short-lived Realtime WebSocket to execute it. Imports `INSTRUCTIONS`, `MODEL`, `TOOLS`, `dispatch_tool` from `voice_agent.py`.
- **`src/ipc_server.py`** — asyncio TCP server (localhost, random port) bridging the SwiftUI app and Python. Newline-delimited JSON; the chosen port is printed to stdout as `IPC_PORT=<n>` for the Swift parent to read. See the module docstring for the full message protocol.
- **`Otto/`** — native SwiftUI command-palette app launched by `./run.sh --app`. `OttoApp.swift` (the `AppDelegate`) spawns `src/voice_agent.py --ipc` as a subprocess, reads `IPC_PORT=` from its stdout, and connects via `PythonBridge.swift`. `HotkeyManager.swift` registers ⌥Space (Carbon `RegisterEventHotKey`) to toggle the palette; `CommandPalette.swift` + `WaveformView.swift` render the UI. Built with `make app` (swiftc + ad-hoc codesign, no full Xcode) or the Xcode project at `Otto/Otto.xcodeproj`. The app finds the repo via `OTTO_PROJECT_ROOT` (legacy `VOICEOS_PROJECT_ROOT` still honored) or by walking up from the bundle, and merges `.env` so it works when launched from Finder.

### Tools / actions (`src/actions.py`)

Two layers:

1. **5 primitives** (the only functions exposed to the model via `TOOLS` dict):
   - `run_applescript(script)` — arbitrary osascript
   - `press_key(combo, app, repeat?)` — CGEvent keystrokes via agent-desktop
   - `read_screen(app?)` — accessibility tree text extraction
   - `open_url(url)` — opens in configured browser
   - `obs_call(request_type, request_data)` — OBS WebSocket

2. **Recipe functions** (higher-level, used in the legacy `_LEGACY_TOOLS` dict for standalone CLI testing): `open_app`, `play_music`, `premiere_control`, `obs_scene`, `ask_claude`, `web_search`, `click_link`, `take_note`, `run_terminal`, etc.

3. **Internal helpers** (not exposed to the model, used by the agent loop):
   - `read_frontmost_screen()` — gets the frontmost non-Otto app via osascript, then snapshots its accessibility tree. Called after every tool dispatch to keep the screen cache fresh.

The model uses the 5 primitives to implement whatever the capability template describes. For complex multi-step tasks, the `terminal-run` capability directs the model to open Terminal and hand off to Claude Code via `run_terminal(task)`.

### System scan (`src/system_scan.py`)

Runs once at startup (result cached). Walks `/Applications` and `~/Applications`, builds a lowercase set of installed app names. Also checks for CLIs (`shutil.which`). Two consumers:

- **`retrieval.py`** — filters `CapabilityIndex` entries whose `required_apps` list has no installed match. `CapabilityIndex(filter_by_installed=False)` disables this (used in tests so retrieval quality isn't machine-dependent).
- **`voice_agent._build_instructions()`** — injects a short "INSTALLED TOOLS" block into the system prompt so the model knows what's available and whether Claude Code is present.

### Capability store and retrieval (`src/retrieval.py`)

- `memory/capabilities.json` — shipped capability templates. Each entry has `id`, `description`, `examples[]`, `primitive`, `template`, and optionally `required_apps[]`.
- `memory/capabilities.user.json` — your learned capabilities (gitignored), written by the retrospective.
- `required_apps` — if set, the capability is excluded from the index unless at least one of the listed apps is found in `/Applications` by `system_scan`. App names must match the stem of the `.app` bundle (case-insensitive).
- On startup, `CapabilityIndex` embeds all example phrases with `sentence-transformers/all-MiniLM-L6-v2` (~22 MB, runs fully locally). The embedding cache (`memory/embeddings.npy` + `memory/embedding_ids.json`) auto-invalidates when capabilities change.
- Per-turn: the transcript is embedded, cosine similarity ranks capabilities, top-3 are injected as `RETRIEVED CAPABILITIES (grounding: STRONG|WEAK)` into the conversation before `response.create` fires.
- Grounding is STRONG when top score ≥ 0.52, or ≥ 0.40 with clear dominance over the runner-up. The system prompt tells the model to refuse ambiguous weak-grounding commands.

### Screen context

After every successful tool call, `voice_agent._update_screen_cache()` fires as a background task. It calls `actions.read_frontmost_screen()`, which gets the current frontmost app (excluding Otto itself) via osascript and snapshots its accessibility tree. The result is stored in `_screen_cache` with a timestamp.

On the next turn, `_inject_capability_context()` prepends a `CURRENT SCREEN (app: X, captured Ns ago): ...` block to the capability context if the cache is < 60 seconds old. This gives the model passive awareness of what was on screen after the previous action — without any explicit "read the screen" command.

### Dreaming loop (`src/retrospective.py`)

Post-session (on Ctrl-C): reads JSONL session log, pairs successful tool calls with the spoken phrase that triggered them, calls `gpt-4.1-mini` to either (A) add the user's phrasing to an existing capability or (B) create a new one. Writes result to `capabilities.user.json` and refreshes the in-process retrieval index.

### Session logging (`src/session_log.py`)

Writes typed JSONL events to `memory/sessions/<timestamp>.jsonl` (gitignored). Event types: `heard`, `wake`, `ignored`, `tool_call` (with latency + ok/fail), `spoken`, `error`.

### Configuration (`src/config.py`)

Single source of truth for all constants, all overridable via env vars or `.env`. Env vars use the `OTTO_` prefix, read through `config.env()`, which falls back to the pre-rebrand `VOICEOS_` prefix (with a one-time deprecation note) so old `.env` files keep working. Key vars: `OPENAI_API_KEY`, `OTTO_TRANSCRIBE_MODEL` (default `gpt-4o-transcribe`), `OTTO_WHISPER` (local Whisper size), `OTTO_MIC`, `OTTO_BROWSER`, `OTTO_USER_NAME`, `OTTO_PREMIERE_APP`, `OTTO_SPOTIFY_FAVORITES`, `OTTO_CLAUDE_PROJECT`.

### App-specific quirks

- **Adobe Premiere Pro** — AX tree is empty (custom UI). `premiere_control` uses CoreGraphics to get the window rect, clicks the Program Monitor's video area to force panel keyboard focus, then sends keys via agent-desktop CGEvent. Adding a new Premiere shortcut = one line in `_PREMIERE_KEYS`.
- **Claude Desktop (Electron)** — AX tree is empty by default. `_force_electron_ax` calls `AXUIElementSetAttributeValue(..., "AXManualAccessibility", True)` to enable it. `ask_claude` navigates to a configured project, types a question, and polls the tree for the response.
- **Wake word regex** — `_WAKE_RE` in `voice_agent.py` handles NZ-accent mishears of "hey chat" (chut, chit, jet, jat, etc.) from gpt-4o-transcribe.

## Adding a new capability

Edit `memory/capabilities.json` (or `capabilities.user.json`) and restart — the embedding cache auto-regenerates. See `docs/ADD-AN-APP.md` for the full recipe: snapshot the app with `agent-desktop snapshot --app "AppName" --compact`, write a tool function in `actions.py`, register it in both `TOOLS` dicts, add a `TOOLS` entry in `voice_agent.py`.

If the capability only makes sense when a specific app is installed, add `"required_apps": ["App Name"]` — the entry will be silently skipped on machines where that app isn't present.
