# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build the app (Xcode Command Line Tools only — no full Xcode)
make app                        # → Otto/build/Otto.app
make pkg                        # make app, then wrap as Otto/build/Otto.pkg installer
make clean                      # remove build output

# Run
open Otto/build/Otto.app        # launch the built app
# First run shows onboarding to enter your OpenAI API key.
# Press ⌥Space to summon the command palette; ⌥⇧Space for the journal.

# Standalone Swift unit tests (no Xcode, no Package.swift)
swiftc Otto/Otto/HotkeyConfig.swift tests/swift/HotkeyConfigTests.swift -framework Carbon -o /tmp/hk && /tmp/hk
swiftc Otto/Otto/UpdateChecker.swift tests/swift/UpdateCheckerTests.swift -o /tmp/uc && /tmp/uc
swiftc Otto/Otto/CapabilityKind.swift tests/swift/CapabilityKindTests.swift -o /tmp/ck && /tmp/ck
swiftc tests/swift/SessionLogTests.swift -o /tmp/sl && /tmp/sl
swiftc tests/swift/CapabilityIndexTests.swift -o /tmp/ci && /tmp/ci
```

## Architecture

### The main flow

```
startup: CapabilityIndex loads memory/capabilities.json (bundle) + capabilities.user.json (user data)
         Retrospective processes any unprocessed session logs from the previous run (gpt-4o-mini)

voice (PTT) → OttoEngine opens WebSocket to wss://api.openai.com/v1/realtime
→ user presses ⌥Space mic button → audio frames stream → voice released
→ OpenAI transcribes → CapabilityIndex.contextBlock(for: heard) injects top-3 capabilities
  as session.update instructions before response.create
→ model calls a primitive tool → ActionEngine executes it
→ model speaks confirmation → SessionLog writes JSONL event
→ next app launch: Retrospective reads log, calls gpt-4o-mini, writes capabilities.user.json
```

The model has **no hardcoded routing rules**. It receives retrieved capability templates as recipes and fills in parameters.

### Entry point

**`Otto/`** — native SwiftUI menu-bar app (`LSUIElement`; no Dock icon). `make app` builds it with `swiftc` + CLT only — no full Xcode required.

Key Swift files:

| File | Role |
|---|---|
| `OttoApp.swift` | `AppDelegate` — lifecycle, onboarding gate, hotkeys, update checker |
| `OttoEngine.swift` | `@MainActor @Observable` — WebSocket loop, audio, tool dispatch, session wiring |
| `AudioEngine.swift` | AVAudioEngine mic capture (24kHz PCM16) + TTS playback |
| `ActionEngine.swift` | `actor` — 5 tool primitives: run_applescript, press_key, read_screen, open_url, obs_call |
| `Config.swift` | Centralised config from env vars + SettingsStore (openAIKey, model, micName, …) |
| `CapabilityIndex.swift` | Loads capabilities JSON, keyword search, journal data, CRUD |
| `SessionLog.swift` | JSONL event logger → `~/Library/Application Support/Otto/sessions/` |
| `Retrospective.swift` | Post-session learning via gpt-4o-mini; runs at next startup |
| `CommandPalette.swift` | Floating orb palette (OrbView, CapabilityHalo, WaveformView) |
| `JournalWindow.swift` | Capability browser with edit/delete |
| `SettingsStore.swift` | API key in Keychain; hotkeys, mic, browser in UserDefaults |
| `OttoBridge.swift` | Shared data types: JournalCard, JournalHeader, RecentPhrase, LearnedEvent |

### The 5 tool primitives

All model tool calls resolve to one of:

- `run_applescript(script)` — NSAppleScript in-process
- `press_key(combo, app?, repeat?)` — CGEvent keystrokes
- `read_screen(app?)` — AXUIElement accessibility tree text
- `open_url(url)` — opens in configured browser via NSWorkspace
- `obs_call(request_type, request_data?)` — OBS WebSocket

### Capability store

- `memory/capabilities.json` — shipped templates (tracked in git). Each entry: `id`, `description`, `examples[]`, `primitive`, `template`, `required_apps?[]`.
- `~/Library/Application Support/Otto/capabilities.user.json` — learned capabilities (machine-local, gitignored).
- `required_apps` — capability is excluded from the index if none of the listed app names match a bundle in `/Applications`.
- Retrieval is keyword/Jaccard search (top-3 injected per turn). ML embeddings are a future upgrade.

### Session logging & retrospective

- Events written to `~/Library/Application Support/Otto/sessions/<timestamp>.jsonl`.
- On next launch, `Retrospective.processLastSession()` reads the oldest unprocessed `.jsonl`, calls `gpt-4o-mini` to extract reusable patterns, updates `capabilities.user.json`, and renames the log to `.jsonl.done`.

### Adding a Swift file

Register it in **two** hand-maintained places:
1. `SOURCES` list in `Makefile` (primary build path)
2. `Otto/Otto.xcodeproj/project.pbxproj` — add a `PBXBuildFile`, `PBXFileReference`, group child, and `PBXSourcesBuildPhase` entry.

### Adding a new capability

Edit `memory/capabilities.json` and restart. Entries use this shape:

```json
{
  "id": "spotify-play",
  "description": "Play music in Spotify",
  "examples": ["play Spotify", "start music", "resume playback"],
  "primitive": "run_applescript",
  "template": "tell application \"Spotify\" to play",
  "required_apps": ["Spotify"]
}
```
