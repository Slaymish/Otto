# Otto → Swift Migration Roadmap

The goal is to collapse Otto into a single Swift process — not for raw speed, but to delete the glue: the TCP IPC server, the Python venv bootstrap, the two-process handshake. Every bottleneck that's actually fixable is a macOS API boundary, and Swift owns those natively.

## What gets deleted at the end

| Removed | What replaces it |
|---|---|
| Python subprocess + venv, `requirements.txt` | Single Swift binary, no runtime dep |
| `ipc_server.py` + `PythonBridge` TCP | In-process `@Observable OttoEngine` |
| `agent-desktop` (Node.js) + osascript subprocess | `AXUIElement`, `CGEvent`, `NSAppleScript` |
| `sentence-transformers` | `swift-transformers` (HF) + CoreML |
| `faster-whisper` | WhisperKit (Argmax) or macOS 26 Speech APIs |
| `openwakeword` / ONNX | CoreML model |
| `SetupEngine.swift` (venv bootstrap) | Gone — no venv to create |

---

## Approach: parallel vertical slice (recommended)

Build a Swift `OttoEngine` that publishes the same `@Observable` state `PythonBridge` already publishes (`micLevel`, `transcript`, `spokenText`, `tool_call`, etc.). Gate it behind a `--swift-engine` launch argument. Get PTT working end-to-end in Swift first, then flip the flag. SwiftUI views (`CommandPalette`, `JournalWindow`, etc.) never change.

**Do not** use the strangler-with-inverted-IPC approach — it adds a Python→IPC→Swift round-trip per action during transition, which is slower than today until Phase 2 lands, and the IPC protocol becomes throwaway work.

---

## Phase 00 — Kill the osascript forks ✅ DONE

**Effort:** ~1 day · ships independently  
**Status:** Complete (2026-06-20)

Replaced every `subprocess.run(["osascript", ...])` call in `actions.py` with `NSAppleScript.executeAndReturnError_()` via PyObjC (already a macOS system framework, no subprocess spawn needed).

**What changed:**
- `actions.py`: new `_OsaResult` namedtuple + `_osa()` reimplemented via `NSAppleScript`
- `requirements.txt`: added `pyobjc-framework-Cocoa>=10.0` (darwin only)
- Falls back to subprocess osascript if PyObjC import fails

**Result:** 4.3ms/call vs 26.7ms/call — **6× faster**. Saves ~80–100ms per tool action (a typical action does 3–4 `_osa` calls).

**Implementation notes:**
- `executeAndReturnError_(None)` returns a 2-tuple `(NSAppleEventDescriptor | None, error_dict | None)`
- Each call runs in a daemon thread to preserve the existing timeout behaviour
- All 110 existing tests pass

---

## Phase 01 — The core loop (audio + WebSocket + turn orchestration)

**Effort:** ~2–3 weeks · highest complexity

These three move **together** because they're latency-coupled: audio feeds the WebSocket, the WebSocket drives turns, turns dispatch actions. Splitting them creates a worse seam.

**What to build:**

Create `Otto/OttoEngine.swift` — an `@Observable` class that:
1. Captures mic audio via `AVAudioEngine` (tap on input node → PCM16 frames)
2. Base64-encodes frames and streams them over a persistent `URLSessionWebSocketTask` to `wss://api.openai.com/v1/realtime`
3. Handles the full turn loop: session config, audio commit, tool dispatch, response playback
4. Publishes `micLevel`, `transcript`, `spokenText`, `isReady`, `tool_call` — the same events `PythonBridge` publishes today
5. Dispatches tool calls to `ActionEngine` (Phase 02; stub it out initially)

Wire `OttoApp.swift` to instantiate `OttoEngine` when launched with `--swift-engine`, and bind it where `PythonBridge` is currently bound.

**Key APIs:**
- `AVAudioEngine` + `AVAudioInputNode.installTap(onBus:bufferSize:format:block:)`
- `AVAudioPlayerNode` for TTS playback
- `URLSessionWebSocketTask` for the Realtime WebSocket
- Swift Concurrency (`async`/`await`, `AsyncStream`, actors)

**Replaces:** `voice_agent.py`, `ipc_server.py`, `PythonBridge.swift` TCP layer

**Milestone:** A PTT voice turn completes end-to-end without Python running.

**Watch out for:**
- Audio session category on macOS (no `AVAudioSession`; use `AVAudioEngine` directly)
- OpenAI Realtime API reconnects on 60-min session cap — port the reconnect logic
- The capability context injection (`RETRIEVED CAPABILITIES` block) — stub with a hardcoded string initially, wire to `CapabilityIndex` in Phase 03

---

## Phase 02 — Actions (AX, CGEvent, AppleScript in-process)

**Effort:** ~1–2 weeks

Implement the five model primitives natively in Swift. All of these replace `agent-desktop` (Node.js CLI) and `actions.py`.

| Primitive | Swift implementation |
|---|---|
| `run_applescript(script)` | `NSAppleScript.executeAndReturnError_()` on a background actor |
| `press_key(combo, app)` | `CGEvent(keyboardEventSource:virtualKey:keyDown:)` |
| `read_screen(app)` | `AXUIElementCopyAttributeValue` walking the tree |
| `open_url(url)` | `NSWorkspace.shared.open(url)` |
| `obs_call(type, data)` | `URLSessionWebSocketTask` to OBS |

Create `Otto/ActionEngine.swift`. The model's tool call JSON comes in from `OttoEngine`, gets dispatched here, result goes back as `function_call_output`.

**Important — agent-desktop `@ref` contract:** Existing capability templates reference UI elements using agent-desktop's `@ref` ID scheme. Read the agent-desktop snapshot JSON format before writing the AX replacement. The IDs the model uses for targeted clicks need to map to the same elements, or capability templates that do element-specific clicks break silently.

**Electron AX workaround:** `_force_electron_ax` in `actions.py` calls `AXUIElementSetAttributeValue(element, "AXManualAccessibility", True)`. In Swift:
```swift
AXUIElementSetAttributeValue(axElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
```

**Replaces:** `agent-desktop` (Node.js), `actions.py`, PyObjC entirely

**Milestone:** All tool calls run in-process. Python is not involved in any live session.

---

## Phase 03 — Local ML (embeddings, Whisper, wake word)

**Effort:** ~2–4 weeks · highest risk

Three independently shippable components. If CoreML conversion proves painful, **this entire phase can remain a thin Python sidecar indefinitely** — Phases 0–2 deliver most of the felt improvement.

### Embeddings (retrieval)

Port `retrieval.py`'s semantic search to Swift using [`swift-transformers`](https://github.com/huggingface/swift-transformers) (Hugging Face).

- Model: `all-MiniLM-L6-v2` (22 MB)
- **The tokenizer is the non-trivial part** — `swift-transformers` includes a WordPiece tokenizer that handles this
- Cosine search: use `Accelerate.vDSP` for the dot product (replaces numpy)
- Export the model to CoreML once with `coremltools` for ANE execution

### Whisper / transcription

- **Check macOS 26 Speech APIs first** — if on-device streaming + wake-word coverage is there, use it
- Otherwise: [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Argmax) is the mature Swift/CoreML path for faster-whisper replacement

### Wake word

- Convert the openwakeword ONNX model to CoreML via `coremltools`
- Or call ONNX Runtime via its C ABI from Swift (bindings exist)

**Replaces:** `sentence-transformers`, `faster-whisper`, `openwakeword`

**Milestone:** Startup drops from ~7 s to ~300 ms. No Python ML dependency.

---

## Phase 04 — Retrospective, logging, cleanup

**Effort:** ~1 week

Port the remaining Python-only pieces:

- `retrospective.py` → `Otto/Retrospective.swift` using `URLSession` for OpenAI chat completions, `Codable` for capability JSON management
- `session_log.py` → `Otto/SessionLog.swift` using `FileHandle` for JSONL append
- `config.py` → `Otto/Config.swift` (env var reading, keychain already done in `SettingsStore.swift`)

Then delete: Python, `SetupEngine.swift`, venv bootstrap in `run.sh`, `requirements.txt`, `requirements-local.txt`.

**Milestone:** Otto ships as a single Swift binary. No Python runtime required on the user's machine.

---

## Constraints — read before Phase 01

### Codesigning / TCC grants
The Makefile uses ad-hoc signing with an unstable identity. macOS keys Accessibility and Microphone grants to bundle identity — every rebuild can silently reset them. Before Phase 1 ships, move to a stable Developer ID (or a consistent self-signed identity with a fixed Team ID). This is the easiest thing to miss and the most annoying to debug.

### agent-desktop `@ref` contract
Read agent-desktop's snapshot JSON format before writing the Swift AX replacement. The IDs the model uses for targeted element clicks need to be preserved in `ActionEngine`'s snapshot output, or capability templates break silently.

### Test migration
There are pytest suites for retrieval, retrospective, wake-gate, and session log. Write matching XCTest coverage **alongside** each Swift port — don't plan to backfill after deletion.

### `NSAppleScript` threading (Phase 02)
`NSAppleScript.executeAndReturnError_()` is synchronous. In Swift's actor model, run it inside a detached `Task` or mark the method `nonisolated` explicitly. Same blocking semantics as subprocess.run, but you need to be deliberate about it.

---

## End state — repo shape after Phase 04

**Removed:**
- `src/voice_agent.py`
- `src/wake_listener.py`
- `src/actions.py`
- `src/ipc_server.py`
- `src/retrieval.py`
- `src/retrospective.py`
- `src/session_log.py`
- `src/config.py`
- `requirements.txt`
- `requirements-local.txt`
- `requirements-dev.txt`
- `Otto/SetupEngine.swift`
- `.venv/` (never created)

**Added:**
- `Otto/OttoEngine.swift` — top-level orchestrator
- `Otto/AudioEngine.swift` — AVAudioEngine capture + playback
- `Otto/RealtimeClient.swift` — OpenAI Realtime WebSocket
- `Otto/ActionEngine.swift` — AX + CGEvent + NSAppleScript
- `Otto/CapabilityIndex.swift` — embedding retrieval
- `Otto/Retrospective.swift` — post-session learning loop
- `Otto/SessionLog.swift` — JSONL event log
- `Otto/Config.swift` — env var / keychain config
- `Tests/` — XCTest suite
- `OttoApp.swift` updated: no subprocess spawn, binds to `OttoEngine`
- `PythonBridge.swift` deleted, replaced by `OttoEngine` binding
