# Otto

<p align="center">
  <img src="Otto/Otto/AppIcon.png" width="128" alt="Otto app icon">
</p>

**A voice and text assistant for the Mac that learns how you work.**

Summon Otto with a keystroke. Say what you want — _"open Spotify," "cut here," "what's on my screen?"_ — and it does it. No chat window, no context-switching. When the session ends, Otto reflects on what worked and quietly rewrites its own memory so the exact way _you_ phrase something lands instantly next time.

The more you use it, the better it fits.

---

## Quickstart

**Requirements:** Mac, Python 3.10+, [Node.js](https://nodejs.org), and an **OpenAI API key with Realtime access**.

```bash
# 1. Install the automation layer
npm install -g agent-desktop
#    Then: System Settings → Privacy & Security → Accessibility → add your terminal

# 2. Set your API key
cp .env.example .env
# edit .env and paste in OPENAI_API_KEY

# 3. Run it
./run.sh
```

Press **Enter**, say something, watch it happen. That's it.

---

## Pick your mode

| Mode | Command | Idle cost | How it works |
|---|---|---|---|
| **Native palette** (recommended) | `./run.sh --app` | **$0** | ⌥Space summons a floating panel. Type or hold the mic button to talk. Auto-builds on first run. |
| **Push-to-talk** | `./run.sh` | **$0** | Press Enter to talk. Nothing leaves your Mac until you do. |
| **Local wake word** | `./run.sh --local` | **$0** | Say _"hey Jarvis"_ — wake detection and transcription run entirely on-device. Cloud only for execution. |
| **Hold-to-talk hotkey** | `./run.sh --hotkey` | **$0** | Hold Right Control anywhere to talk. |
| **Cloud wake word** | `./run.sh --wake` | not $0 | Hands-free "hey chat" — but streams audio continuously, so it bills while idle. |

For hands-free at $0 idle, use `--local`. Tune the whisper model with `OTTO_WHISPER=small.en` for better accuracy.

Pick a mic: `OTTO_MIC=Scarlett ./run.sh`

---

## The palette app

`./run.sh --app` is the best way to run Otto day-to-day. It builds and launches a native macOS command palette — a borderless floating panel that appears over whatever you're doing.

- **⌥Space** — summon / dismiss
- **Type** — send a text command
- **Hold the mic button** — talk instead
- **Journal** — browse and edit everything Otto has learned

Needs only Xcode Command Line Tools (`xcode-select --install`), not full Xcode.

```bash
./run.sh --app     # build (first run) and launch
make app           # build only → Otto/build/Otto.app
```

---

## How it learns

After every session (Ctrl-C), Otto runs a retrospective. It looks at what you actually said and what worked, then either adds your phrasing to an existing capability or creates a new one. The result lands in `memory/capabilities.user.json` — your personal capability library, gitignored, growing quietly in the background.

You never have to train it explicitly. Use it normally and it compounds.

To review or undo what it has learned:

```bash
python src/retrospective.py --journal        # browse learned capabilities
python src/retrospective.py --undo <id>      # revert a specific one
python src/retrospective.py --sessions 3     # reflect on the last 3 sessions manually
```

---

## Escape hatch

For anything too complex for a one-shot command — writing a script, refactoring code, a multi-step research task — just say "hand this off to Claude Code." Otto opens Terminal and starts a live Claude Code session with your task already in the prompt.

---

## Cost and privacy

- **$0 idle** — every mode except `--wake` only sends audio when you actually trigger a command.
- **Per command** — `gpt-realtime-2` runs roughly a few cents per command.
- **Retrieval is local** — capability search uses `sentence-transformers` on-device. No API calls, no cost, works offline.
- **Your data stays put** — session logs and learned capabilities live only on your machine.

---

## Configuration

Copy `.env.example` to `.env` to get started. The only required value is your API key:

```
OPENAI_API_KEY=sk-...
```

Common optional settings:

| Variable | Default | What it does |
|---|---|---|
| `OTTO_MIC` | system default | Mic to use (partial match, e.g. `Scarlett`) |
| `OTTO_WHISPER` | `small.en` | Local Whisper size for `--local` mode |
| `OTTO_BROWSER` | `Safari` | Browser for web searches |
| `OTTO_USER_NAME` | `the user` | Your name in the system prompt |
| `OTTO_USER_HINTS` | — | Free-text hints — accent, preferences, context |
| `OTTO_CLAUDE_PROJECT` | — | Claude Desktop project for `ask_claude` |

Full config reference and all variables are in `.env.example`.

---

## Going further

- **[docs/architecture.md](docs/architecture.md)** — how it works under the hood: the retrieval pipeline, screen context, the dreaming loop, entry points, project layout.
- **[docs/ADD-AN-APP.md](docs/ADD-AN-APP.md)** — step-by-step guide to adding a new app or capability.

---

## Testing

```bash
pip install -r requirements-dev.txt
pytest                          # full suite (pure tests only)
pytest tests/test_retrieval.py  # capability retrieval (needs embedding model)
pytest tests/test_build.py -v   # builds Otto.app — slow, run when touching Swift
python tests/test_loop.py "open Spotify"  # live end-to-end (needs API key)
```

---

License: MIT.  
Otto began as a fork of [voice-os](https://github.com/per-simmons/voice-os) by Pat Simmons.
