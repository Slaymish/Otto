# Architecture

## The main flow

```
startup
    system_scan.py scans /Applications → installed app list
    retrieval.py loads capabilities.json, filters out any whose
    required_apps aren't installed, embeds all examples (~2ms cached)

your voice
    │
    ▼
gpt-realtime-2 transcribes the command
    │
    ▼
retrieval.py embeds the transcript and searches the filtered index
returns top-3 matching capability templates (locally, ~2ms)
    │
    ▼
context injected: "RETRIEVED CAPABILITIES: cut in Premiere → press_key cmd+k"
       + "CURRENT SCREEN (app: Safari, captured 4s ago): ..." (if recent)
    │
    ▼
model calls the right primitive with filled-in parameters
    │
    ├─ run_applescript(script)       AppleScript for any scriptable app
    ├─ press_key(combo, app)         hotkeys for Premiere, etc.
    ├─ read_screen(app)              accessibility-tree text extraction
    ├─ open_url(url)                 browser / Spotify URI schemes
    └─ obs_call(requestType, data)   OBS WebSocket
    │
    ▼
app does the thing → screen snapshot fires in background (screen cache)
    │
    ▼
model speaks a short confirmation
    │
    ▼  (on Ctrl-C / session end)
retrospective.py reflects on what worked → writes new templates to
memory/capabilities.user.json → re-embedded next startup
```

The model has **no hardcoded routing rules**. It receives the retrieved
capability as a recipe and fills in the parameters.

## Entry points

- **`src/voice_agent.py`** — cloud modes (PTT / hotkey / wake word "hey chat") **and** the SwiftUI back-end (`--ipc`). Opens a WebSocket to `wss://api.openai.com/v1/realtime`, streams audio, gates on the wake word regex, injects capability context, and dispatches tool calls to `actions.py`. Reconnects automatically on the 60-min API session cap. With `--ipc` it also starts an `IPCServer` and broadcasts waveform/transcript/spoken/tool_call events to the Swift UI (and accepts `voice_start`/`voice_stop`/`text_input` from it).
- **`src/wake_listener.py`** — local `--local` mode. Two-stage pipeline: OpenWakeWord scores every 80ms frame ($0 CPU), then faster-whisper transcribes only post-wake audio. Once the command text is known, it opens a short-lived Realtime WebSocket to execute it. Imports `INSTRUCTIONS`, `MODEL`, `TOOLS`, `dispatch_tool` from `voice_agent.py`.
- **`src/ipc_server.py`** — asyncio TCP server (localhost, random port) bridging the SwiftUI app and Python. Newline-delimited JSON; the chosen port is printed to stdout as `IPC_PORT=<n>` for the Swift parent to read.
- **`Otto/`** — native SwiftUI command-palette app launched by `./run.sh --app`. `OttoApp.swift` (the `AppDelegate`) spawns `src/voice_agent.py --ipc` as a subprocess, reads `IPC_PORT=` from its stdout, and connects via `PythonBridge.swift`. `HotkeyManager.swift` registers ⌥Space (Carbon `RegisterEventHotKey`) to toggle the palette; `CommandPalette.swift` + `WaveformView.swift` render the UI. Built with `make app` (swiftc + ad-hoc codesign, no full Xcode) or the Xcode project at `Otto/Otto.xcodeproj`.

## Tools / actions (`src/actions.py`)

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

## System scan (`src/system_scan.py`)

Runs once at startup (result cached). Walks `/Applications` and `~/Applications`, builds a lowercase set of installed app names. Also checks for CLIs (`shutil.which`). Two consumers:

- **`retrieval.py`** — filters `CapabilityIndex` entries whose `required_apps` list has no installed match.
- **`voice_agent._build_instructions()`** — injects a short "INSTALLED TOOLS" block into the system prompt so the model knows what's available.

## Capability store and retrieval (`src/retrieval.py`)

- `memory/capabilities.json` — shipped capability templates. Each entry has `id`, `description`, `examples[]`, `primitive`, `template`, and optionally `required_apps[]`.
- `memory/capabilities.user.json` — your learned capabilities (gitignored), written by the retrospective.
- On startup, `CapabilityIndex` embeds all example phrases with `sentence-transformers/all-MiniLM-L6-v2` (~22 MB, runs fully locally). The embedding cache (`memory/embeddings.npy` + `memory/embedding_ids.json`) auto-invalidates when capabilities change.
- Per-turn: the transcript is embedded, cosine similarity ranks capabilities, top-3 are injected as `RETRIEVED CAPABILITIES (grounding: STRONG|WEAK)` into the conversation before `response.create` fires.
- Grounding is STRONG when top score ≥ 0.52, or ≥ 0.40 with clear dominance over the runner-up. The system prompt tells the model to refuse ambiguous weak-grounding commands.

## Screen context

After every successful tool call, `voice_agent._update_screen_cache()` fires as a background task. It calls `actions.read_frontmost_screen()`, which gets the current frontmost app (excluding Otto itself) via osascript and snapshots its accessibility tree. The result is stored in `_screen_cache` with a timestamp.

On the next turn, `_inject_capability_context()` prepends a `CURRENT SCREEN (app: X, captured Ns ago): ...` block to the capability context if the cache is < 60 seconds old.

## Dreaming loop (`src/retrospective.py`)

Post-session (on Ctrl-C): reads JSONL session log, pairs successful tool calls with the spoken phrase that triggered them, calls `gpt-4.1-mini` to either (A) add the user's phrasing to an existing capability or (B) create a new one. Writes result to `capabilities.user.json` and refreshes the in-process retrieval index.

## Session logging (`src/session_log.py`)

Writes typed JSONL events to `memory/sessions/<timestamp>.jsonl` (gitignored). Event types: `heard`, `wake`, `ignored`, `tool_call` (with latency + ok/fail), `spoken`, `error`.

## Configuration (`src/config.py`)

All constants are overridable via env vars or `.env`. Uses `OTTO_` prefix, read through `config.env()`, which falls back to the pre-rebrand `VOICEOS_` prefix.

## App-specific quirks

- **Adobe Premiere Pro** — AX tree is empty (custom UI). `premiere_control` uses CoreGraphics to get the window rect, clicks the Program Monitor's video area to force panel keyboard focus, then sends keys via agent-desktop CGEvent.
- **Claude Desktop (Electron)** — AX tree is empty by default. `_force_electron_ax` calls `AXUIElementSetAttributeValue(..., "AXManualAccessibility", True)` to enable it.
- **Wake word regex** — `_WAKE_RE` in `voice_agent.py` handles NZ-accent mishears of "hey chat" (chut, chit, jet, jat, etc.) from gpt-4o-transcribe.

## Project layout

```
otto/
├── run.sh  ptt.sh  start.sh        entrypoints (run these)
├── Makefile                        builds the SwiftUI app (make app)
├── requirements*.txt  .env.example
├── src/                            application code
│   ├── voice_agent.py              realtime loop — mic ↔ model ↔ tools (cloud + --ipc modes)
│   ├── wake_listener.py            local ($0-idle) wake-word engine: OpenWakeWord + faster-whisper
│   ├── actions.py                  the 5 primitive tools the model calls
│   ├── retrieval.py                local capability embedding index + cosine search
│   ├── system_scan.py              startup app scanner — filters capabilities by what's installed
│   ├── retrospective.py            post-session dreaming loop — learns your phrasings
│   ├── learning_store.py           persistence, journal, undo, usage stats for learned capabilities
│   ├── session_log.py              structured per-session JSONL event logger
│   ├── ipc_server.py               localhost TCP/JSON bridge for the SwiftUI app
│   ├── config.py                   all tuneable constants, read from env (OTTO_ prefix)
│   ├── voice_app.py                safe global-hotkey front-end (Carbon RegisterEventHotKey)
│   ├── ax_keeper.py                keeps Claude Desktop's accessibility tree on
│   └── overlay.py                  waveform HUD
├── Otto/                           native SwiftUI command-palette app (./run.sh --app)
│   ├── Otto.xcodeproj              open in Xcode, or build with `make app`
│   └── Otto/                       Swift sources
│       ├── OttoApp.swift           app delegate — spawns the Python engine, wires the hotkey
│       ├── CommandPalette.swift    the floating palette view (text field + mic + waveform)
│       ├── PythonBridge.swift      TCP/JSON client that drives the UI from Python events
│       ├── HotkeyManager.swift     global ⌥Space summon hotkey (Carbon RegisterEventHotKey)
│       └── WaveformView.swift      live mic-level waveform
├── tests/                          pytest suite
├── docs/                           ADD-AN-APP.md and friends
└── memory/
    ├── capabilities.json           shipped capability templates
    ├── capabilities.user.json      your learned capabilities (gitignored)
    └── sessions/                   session logs (gitignored)
```
