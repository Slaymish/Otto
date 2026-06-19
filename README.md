# Voice OS — run your Mac with your voice

Talk to your Mac and it actually does things — open apps, play music, control
Premiere, start a recording, read the screen back. A small, hackable starting
point you can clone and extend. **It learns your workflows over time.**

- **Brain:** OpenAI `gpt-realtime-2` (speech-to-speech + tool calling)
- **Hands:** 5 primitive tools — AppleScript, key presses, screen reading, URL opening, OBS WebSocket
- **Memory:** local semantic retrieval — capabilities embedded with `sentence-transformers`, searched per-turn, no API cost
- **Learning:** post-session "dreaming" — the model reflects on what worked and writes new capability templates for next time

> Built for the "run your entire computer with your voice" video. Clone it, hand
> it to your coding agent, and say _"build this out for me."_
> See **[docs/ADD-AN-APP.md](docs/ADD-AN-APP.md)**.

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
| **Push-to-talk** (default)     | `./run.sh`                       | **$0**    | Press ENTER, talk. Nothing is sent until you press ENTER.                                   |
| **Local wake word**            | `./run.sh --local`               | **$0**    | On-device [OpenWakeWord](https://github.com/dscripka/openWakeWord) (`hey jarvis`) + local Whisper. The cloud is only called once the wake word fires. |
| **Hold-to-talk hotkey**        | `./ptt.sh` / `./run.sh --hotkey` | **$0**    | Hold **Right Control** (or your hotkey) anywhere to talk.                                    |
| **Cloud wake word "hey chat"** | `./run.sh --wake`                | not $0    | Hands-free, but streams + transcribes audio **continuously**, so it bills while idle.       |
| **SwiftUI palette app**        | `./run.sh --app`                 | **$0**    | A native macOS command palette. Press **⌥Space** to summon, then type a command or hold the mic button to talk. Auto-builds the app on first run (needs Xcode Command Line Tools). |

Pick a specific mic with `VOICEOS_MIC=Scarlett ./ptt.sh`.

> **Want hands-free without the idle cost?** Use `--local`. The wake word and
> transcription run entirely on your Mac (free); only an actual command reaches
> the cloud. Note the local wake word is `hey jarvis` (an OpenWakeWord built-in) —
> `hey chat` is only available in the cloud `--wake` mode unless you train a
> custom OpenWakeWord model. Pick a bigger local Whisper for accuracy with
> `VOICEOS_WHISPER=small.en` (or `distil-large-v3`).

---

## The SwiftUI palette app

`./run.sh --app` launches a native macOS command palette (a borderless floating
panel, summoned with **⌥Space**) instead of the terminal. Type a command and
press return, or hold the mic button to talk — the waveform, transcript, and
spoken result render in the UI.

Under the hood it's the same Python engine: the Swift app spawns
`src/voice_agent.py --ipc` and talks to it over a localhost TCP socket
(newline-delimited JSON — see `src/ipc_server.py` for the protocol). The Swift
side stays a thin front-end; all the brains live in Python.

```bash
./run.sh --app     # auto-builds VoiceOS.app on first run, then launches it
make app           # build only → VoiceOS/build/VoiceOS.app
make clean         # remove the build output
```

Building needs **Xcode Command Line Tools** only (`xcode-select --install`) —
no full Xcode required. The `Makefile` compiles the Swift sources with `swiftc`,
bundles them into `VoiceOS.app`, and ad-hoc code-signs the result.

---

## How it works

```
your voice
    │
    ▼
gpt-realtime-2 transcribes the command
    │
    ▼
retrieval.py embeds the transcript and searches capabilities.json
returns top-3 matching capability templates (locally, ~2ms)
    │
    ▼
context injected: "RETRIEVED CAPABILITIES: cut in Premiere → press_key cmd+k"
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
app does the thing → model speaks a short confirmation
    │
    ▼  (on Ctrl-C / session end)
retrospective.py reflects on what worked → writes new templates to
memory/capabilities.user.json → re-embedded next startup
```

The model has **no hardcoded routing rules**. It receives the retrieved
capability as a recipe and fills in the parameters. New capabilities are
added by editing `memory/capabilities.json` — or by just using the OS and
letting the retrospective learn them for you.

---

## The capability store

`memory/capabilities.json` — shipped generic capabilities (app launching,
Spotify, Premiere editing, OBS, web search, notes, etc.).

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

**Adding a new capability:** add an entry to either JSON file and restart. The
embedding cache auto-regenerates. No Python needed.

---

## The dreaming loop

At the end of every session (Ctrl-C), the system runs a retrospective:

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
startup. The OS tunes itself to your specific vocabulary without you writing any
code.

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

All tuneable values live in `.env` (copy `.env.example` to get started):

| Variable                      | Default              | Description                                               |
| ----------------------------- | -------------------- | --------------------------------------------------------- |
| `OPENAI_API_KEY`              | —                    | Required. Realtime-capable key.                           |
| `VOICEOS_TRANSCRIBE_MODEL`    | `gpt-4o-transcribe`  | Cloud STT for push-to-talk/hotkey/`--wake`. Bigger = more accurate (`gpt-4o-mini-transcribe`, `whisper-1`). |
| `VOICEOS_WHISPER`             | `small.en`           | **Local** STT size for `--local` mode (`tiny.en`…`distil-large-v3`). Runs on-device, $0 idle. |
| `VOICEOS_OWW_MODEL`           | `hey_jarvis`         | Local wake word for `--local` (`hey_jarvis`/`hey_mycroft`/`alexa`, or a custom model path). |
| `VOICEOS_OWW_THRESHOLD`       | `0.5`                | Local wake sensitivity: lower = more sensitive.           |
| `VOICEOS_BROWSER`             | `Safari`             | Browser for web searches.                                 |
| `VOICEOS_USER_NAME`           | `the user`           | Your name in the system prompt.                           |
| `VOICEOS_USER_HINTS`          | —                    | Free-text hints e.g. accent, preferences.                 |
| `VOICEOS_PREMIERE_APP`        | `Adobe Premiere Pro` | Exact app name (update yearly).                           |
| `VOICEOS_SPOTIFY_FAVORITES`   | —                    | Path to JSON file of phrase → spotify URI mappings.       |
| `VOICEOS_CLAUDE_PROJECT`      | —                    | Claude Desktop project name for `ask_claude`.             |
| `VOICEOS_CLAUDE_PROJECT_HINT` | —                    | Phrase from the project's system prompt (skip-nav check). |
| `VOICEOS_EMBED_MODEL`         | `all-MiniLM-L6-v2`   | Local sentence-transformers model for retrieval.          |

---

## Cost & privacy

- **Cost:** `gpt-realtime-2` is ~$32/$64 per 1M audio tokens — roughly **a few
  cents per command**. Push-to-talk, hotkey, and `--local` are **$0 idle**
  (audio only leaves your Mac for an actual command). The cloud wake word
  (`--wake`) transcribes continuously, so it bills while idle — use `--local`
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
voice-os/
├── run.sh  ptt.sh  start.sh        entrypoints (run these)
├── Makefile                        builds the SwiftUI app (make app)
├── requirements*.txt  .env.example
├── src/                            application code
│   ├── voice_agent.py              realtime loop — mic ↔ model ↔ tools (cloud + --ipc modes)
│   ├── wake_listener.py            local ($0-idle) wake-word engine: OpenWakeWord + faster-whisper
│   ├── actions.py                  the 5 primitive tools the model calls
│   ├── retrieval.py                local capability embedding index + cosine search
│   ├── retrospective.py            post-session dreaming loop — learns your phrasings
│   ├── session_log.py              structured per-session JSONL event logger
│   ├── ipc_server.py               localhost TCP/JSON bridge for the SwiftUI app
│   ├── config.py                   all tuneable constants, read from env
│   ├── voice_app.py                safe global-hotkey front-end (Carbon RegisterEventHotKey)
│   ├── ax_keeper.py                keeps Claude Desktop's accessibility tree on
│   └── overlay.py                  waveform HUD
├── VoiceOS/                        native SwiftUI command-palette app (./run.sh --app)
│   ├── VoiceOS.xcodeproj           open in Xcode, or build with `make app`
│   └── VoiceOS/                    Swift sources
│       ├── VoiceOSApp.swift        app delegate — spawns the Python engine, wires the hotkey
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
  `VoiceOS.app` with Command Line Tools only. Slow (invokes `swiftc`); run it
  explicitly when touching the Makefile or any Swift source: `pytest tests/test_build.py -v`.
- `tests/test_loop.py` — optional live end-to-end check against the Realtime API
  (needs `OPENAI_API_KEY`): `python tests/test_loop.py "open Spotify"`.

License: MIT. Have fun — go tell your agent to build it out.
