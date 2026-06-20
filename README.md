# Otto

**A personal, native-feeling voice & text assistant for the Mac — one that learns
your workflows and gets better the more you use it.**

Otto sits quietly in the background. Summon it with a keystroke, say (or type) what
you want — _"open Spotify," "cut here," "what's on my screen?"_ — and it does the
thing. No chat, no ceremony. Every session it watches what worked and quietly
writes that back into its own memory, so the exact way _you_ ask for something
lands instantly next time. It compounds.

It's not a demo and it's not a gimmick. It's built to be a daily driver.

- **Brain** — OpenAI `gpt-realtime-2` (speech-to-speech + tool calling)
- **Hands** — 5 primitive tools: AppleScript, key presses, screen reading, URL opening, OBS WebSocket
- **Memory** — local semantic retrieval: your capabilities are embedded with `sentence-transformers` and searched on every turn, fully on-device, $0
- **Learning** — a post-session "dreaming" loop reflects on what worked and writes new capability templates for next time
- **Aware** — scans your installed apps at startup so it only suggests capabilities it can actually run; passively captures what's on screen after each action so the next command has context
- **Escape hatch** — hand off anything too complex to Claude Code: say "let Claude handle this" and it opens Terminal with a live session
- **Surface** — a native SwiftUI command palette (⌥Space), or any of four terminal modes

---

## Quickstart

**Requirements:** a Mac, [Node](https://nodejs.org) (for agent-desktop),
Python 3.10+, and an **OpenAI API key with Realtime access**.

```bash
# 1. install the "hands"
npm install -g agent-desktop
#    grant Accessibility: System Settings → Privacy & Security → Accessibility

# 2. add your key
cp .env.example .env          # paste OPENAI_API_KEY into .env

# 3. run it (creates a venv, installs deps, launches)
./run.sh                      # push-to-talk: press ENTER, talk, it acts
```

Then talk: _"open Spotify," "play some jazz," "cut here," "what's on my screen?"_

---

## Ways to talk to it

| Mode                           | Command                          | Idle cost | Notes                                                                                       |
| ------------------------------ | -------------------------------- | --------- | ------------------------------------------------------------------------------------------- |
| **Native palette app**         | `./run.sh --app`                 | **$0**    | A native macOS command palette. Press **⌥Space** to summon, then type a command or hold the mic button to talk. Auto-builds the app on first run (needs Xcode Command Line Tools). |
| **Push-to-talk** (default)     | `./run.sh`                       | **$0**    | Press ENTER, talk. Nothing is sent until you press ENTER.                                   |
| **Local wake word**            | `./run.sh --local`               | **$0**    | On-device [OpenWakeWord](https://github.com/dscripka/openWakeWord) (`hey jarvis`) + local Whisper. The cloud is only called once the wake word fires. |
| **Hold-to-talk hotkey**        | `./ptt.sh` / `./run.sh --hotkey` | **$0**    | Hold **Right Control** (or your hotkey) anywhere to talk.                                    |
| **Cloud wake word "hey chat"** | `./run.sh --wake`                | not $0    | Hands-free, but streams + transcribes audio **continuously**, so it bills while idle.       |

Pick a specific mic with `OTTO_MIC=Scarlett ./run.sh`.

> **Want hands-free without the idle cost?** Use `--local`. The wake word and
> transcription run entirely on your Mac (free); only an actual command reaches
> the cloud. Note the local wake word is `hey jarvis` (an OpenWakeWord built-in) —
> `hey chat` is only available in the cloud `--wake` mode unless you train a
> custom OpenWakeWord model. Pick a bigger local Whisper for accuracy with
> `OTTO_WHISPER=small.en` (or `distil-large-v3`).

---

## The palette app

`./run.sh --app` launches a native macOS command palette — a borderless floating
panel, summoned with **⌥Space**. Type a command and press return, or hold the mic
button to talk; the waveform, transcript, and spoken result render live in the UI.

Under the hood it's the same Python engine: the Swift app spawns
`src/voice_agent.py --ipc` and talks to it over a localhost TCP socket
(newline-delimited JSON — see `src/ipc_server.py` for the protocol). The Swift
side stays a thin front-end; all the brains live in Python.

```bash
./run.sh --app     # auto-builds Otto.app on first run, then launches it
make app           # build only → Otto/build/Otto.app
make clean         # remove the build output
```

The palette also shows **suggestions** — your recent commands and learned capabilities — so everything is reachable from one keystroke. Type to filter, or pick "Open Journal" at the bottom to browse and edit what Otto knows.

Building needs **Xcode Command Line Tools** only (`xcode-select --install`) —
no full Xcode required. The `Makefile` compiles the Swift sources with `swiftc`,
bundles them into `Otto.app`, and ad-hoc code-signs the result.

---

## How it works

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
capability as a recipe and fills in the parameters. New capabilities are
added by editing `memory/capabilities.json` — or by just using your Mac and
letting the retrospective learn them for you.

For anything too complex to handle with a one-shot command — refactoring code,
building a script, researching something across multiple steps — just say "hand
this off to Claude Code" (or "let Claude handle this"). Otto opens Terminal and
starts a live Claude Code session with your task as the prompt.

---

## The capability store

`memory/capabilities.json` — shipped generic capabilities (app launching,
Spotify, Premiere editing, OBS, web search, notes, terminal/Claude Code, etc.).

`memory/capabilities.user.json` — your personal capabilities, written by the
dreaming loop after each session. Gitignored. Format:

```json
[
  {
    "id": "premiere-cut",
    "description": "Cut/razor at the playhead in Premiere Pro",
    "examples": ["cut here", "razor at playhead", "add edit", "split here"],
    "primitive": "press_key",
    "template": { "combo": "cmd+k", "app": "Adobe Premiere Pro" }
  }
]
```

The optional `"required_apps"` field lists app names (as they appear in
`/Applications`) that must be installed for a capability to be loaded. At startup
`system_scan.py` walks `/Applications`, and any capability whose required apps
aren't present is silently dropped from the index — so Otto won't suggest Spotify
commands on a machine where Spotify isn't installed.

```json
{
  "id": "spotify-play-search",
  "required_apps": ["Spotify"],
  "primitive": "run_applescript",
  ...
}
```

**Adding a new capability:** add an entry to either JSON file and restart. The
embedding cache auto-regenerates. No Python needed.

---

## The dreaming loop

At the end of every session (Ctrl-C), Otto runs a retrospective:

```bash
python src/retrospective.py              # reflect on the last session
python src/retrospective.py --sessions 3 # reflect on the last 3 sessions
```

It reads the structured session log, pairing **what you actually said** with the
tool that ran, and does one of two things per command:

1. **Adds your phrasing to an existing capability** (the common case) — so the
   exact way _you_ ask for something matches instantly next time, while the
   original template and examples are preserved.
2. **Creates a new capability** only when the action is genuinely new.

The result is written to `memory/capabilities.user.json` and re-embedded next
startup. Otto tunes itself to your specific vocabulary without you writing any
code. This is the compounding loop — the more you use it, the better it fits.

---

## Session history

Every session is logged as structured JSONL in `memory/sessions/` (gitignored):

```
memory/sessions/2026-06-18T00-30-00.jsonl
```

Each line is a typed event — `heard`, `wake`, `tool_call` (with latency and
ok/fail), `spoken`, `error`. Useful for debugging, cost auditing, or feeding
into the retrospective manually.

---

## Configuration

All tuneable values live in `.env` (copy `.env.example` to get started). Env vars
use the `OTTO_` prefix:

| Variable                    | Default              | Description                                               |
| --------------------------- | -------------------- | --------------------------------------------------------- |
| `OPENAI_API_KEY`            | —                    | Required. Realtime-capable key.                           |
| `OTTO_TRANSCRIBE_MODEL`     | `gpt-4o-transcribe`  | Cloud STT for push-to-talk/hotkey/`--wake`. Bigger = more accurate (`gpt-4o-mini-transcribe`, `whisper-1`). |
| `OTTO_WHISPER`              | `small.en`           | **Local** STT size for `--local` mode (`tiny.en`…`distil-large-v3`). Runs on-device, $0 idle. |
| `OTTO_OWW_MODEL`            | `hey_jarvis`         | Local wake word for `--local` (`hey_jarvis`/`hey_mycroft`/`alexa`, or a custom model path). |
| `OTTO_OWW_THRESHOLD`        | `0.5`                | Local wake sensitivity: lower = more sensitive.           |
| `OTTO_BROWSER`              | `Safari`             | Browser for web searches.                                 |
| `OTTO_USER_NAME`            | `the user`           | Your name in the system prompt.                           |
| `OTTO_USER_HINTS`           | —                    | Free-text hints e.g. accent, preferences.                 |
| `OTTO_PREMIERE_APP`         | `Adobe Premiere Pro` | Exact app name (update yearly).                           |
| `OTTO_SPOTIFY_FAVORITES`    | —                    | Path to JSON file of phrase → spotify URI mappings.       |
| `OTTO_CLAUDE_PROJECT`       | —                    | Claude Desktop project name for `ask_claude`.             |
| `OTTO_CLAUDE_PROJECT_HINT`  | —                    | Phrase from the project's system prompt (skip-nav check). |
| `OTTO_EMBED_MODEL`          | `all-MiniLM-L6-v2`   | Local sentence-transformers model for retrieval.          |

> Pre-rebrand `VOICEOS_*` variables are still honored as a fallback (with a
> one-time deprecation note), so an old `.env` keeps working — rename them to
> `OTTO_*` when convenient.

---

## Cost & privacy

- **Cost:** `gpt-realtime-2` is ~$32/$64 per 1M audio tokens — roughly **a few
  cents per command**. The palette app, push-to-talk, hotkey, and `--local` are
  **$0 idle** (audio only leaves your Mac for an actual command). The cloud wake
  word (`--wake`) transcribes continuously, so it bills while idle — use `--local`
  for hands-free without that cost.
- **Local wake + STT:** `--local` runs OpenWakeWord and faster-whisper on-device.
  Wake detection is ~free CPU; Whisper only runs per-command. No idle API cost.
- **Retrieval:** runs fully locally via `sentence-transformers`. No API calls, no
  cost, works offline.
- **Privacy:** mic audio is sent to OpenAI only during an active command. Session
  logs and learned capabilities stay on your machine.

---

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
├── tests/                          pytest suite (see "Testing" below)
├── docs/                           ADD-AN-APP.md and friends
└── memory/
    ├── capabilities.json           shipped capability templates
    ├── capabilities.user.json      your learned capabilities (gitignored)
    └── sessions/                   session logs (gitignored)
```

## Testing

```bash
pip install -r requirements-dev.txt   # pytest
pytest                                # runs tests/
```

- `tests/test_retrieval.py` — asserts spoken **paraphrases** resolve to the right
  capability template (and that off-topic chatter stays low-confidence). Needs
  the local embedding model.
- `tests/test_retrospective.py` — the dreaming loop's learning logic (pairing
  phrasings with tools, the merge that grows existing templates). Pure, no network.
- `tests/test_session_log.py` — the structured JSONL logger: every event method,
  the read/write cycle, and graceful handling of malformed files. Pure, no network.
- `tests/test_voice_agent.py` — the wake-word gate (`is_wake`): standard phrases,
  NZ-accent mishears of "chat", and false positives that must not fire.
- `tests/test_build.py` — verifies `make app` produces a valid, runnable
  `Otto.app` with Command Line Tools only. Slow (invokes `swiftc`); run it
  explicitly when touching the Makefile or any Swift source: `pytest tests/test_build.py -v`.
- `tests/test_loop.py` — optional live end-to-end check against the Realtime API
  (needs `OPENAI_API_KEY`): `python tests/test_loop.py "open Spotify"`.

---

License: MIT.

Otto began as a fork of [voice-os](https://github.com/per-simmons/voice-os) by
Pat Simmons, and has since grown into its own thing.
