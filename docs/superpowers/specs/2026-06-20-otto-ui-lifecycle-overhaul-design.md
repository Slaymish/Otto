# Otto UI & Lifecycle Overhaul — Design

**Date:** 2026-06-20
**Status:** Approved (pending spec review)

## Summary

Five related improvements to the native Otto SwiftUI app, spanning the command
palette, the settings window, and the release/update flow:

1. **Customizable shortcuts** — the summon and journal hotkeys become rebindable
   from Settings.
2. **In-app auto-update** — Otto checks GitHub releases, notifies of new
   versions, and installs them via the bundled `.pkg`.
3. **Mic auto-start** — the mic starts listening on open by default, toggleable
   in Settings; when off, the palette opens with a push-to-activate mic glyph.
4. **Circular orb UI** — the palette opens as a circular orb with a waveform that
   morphs into the text/results bar as soon as the user types.
5. **Floating capabilities** — the most context-relevant capabilities float
   radially around the orb and can be invoked with a click.

These are cohesive (they all touch the palette + settings) and ship as one spec,
implemented in phases.

## Goals

- Make the summon (default ⌥Space) and journal (default ⌥⇧Space) shortcuts
  user-configurable, with persistence and live re-registration.
- Let an installed Otto detect, announce, and install new releases without the
  user leaving the app.
- Default to mic-on-open, with a setting to switch to push-to-talk.
- Replace the static Spotlight-style bar with a circular orb that morphs into the
  existing bar on typing.
- Surface a small set of relevant capabilities around the orb as quick actions.

## Non-Goals (deferred)

- **Screen-aware / learned-behavior relevance** for the floating capabilities.
  v1 reuses the existing suggestion heuristic; smarter ranking (screen content,
  time of day, learned patterns) is a later pass.
- Code signing / notarization of the `.pkg`. The updater works with the existing
  unsigned `.pkg`-on-GitHub distribution.
- Sparkle / appcast infrastructure. We use a lightweight custom checker.
- Delta updates. The updater downloads the full `.pkg`.

## Background / Current State

- `Otto/` is an `LSUIElement` SwiftUI menu-bar app. `OttoApp.swift`'s
  `AppDelegate` spawns `src/voice_agent.py --ipc`, reads `IPC_PORT=` from stdout,
  and connects via `PythonBridge.swift` (an `@Observable` over a `NWConnection`).
- `CommandPalette.swift` is a fixed **640pt-wide** bar: a leading glyph, an
  `Ask anything…` `TextField`, a **hold-to-talk** mic button (`DragGesture`
  start/stop → `sendVoiceStart`/`sendVoiceStop`), an inline `WaveformView`, and a
  suggestion list driven by `bridge.recentPhrases` + `bridge.journalCards`.
- `HotkeyManager.swift` already takes `keyCode` / `modifiers` / `id` and uses
  Carbon `RegisterEventHotKey`. **Only one** instance is created today (summon
  ⌥Space). The ⌥⇧Space journal hotkey referenced in `CLAUDE.md` is **not actually
  registered** — journal is only opened via the menu bar / the learned-chip Edit
  button.
- `SettingsStore.swift` persists the API key in the Keychain and name/mic/browser
  in `UserDefaults`, exposing them as env vars for the Python subprocess. Saving
  restarts Python via `AppDelegate.restartPython()`.
- `SettingsWindow.swift` renders the API key + preferences form.
- `MenuBarController.swift` owns the status-item menu (Open Search / Journal /
  Settings / Quit).
- **Version mismatch:** `Info.plist` hardcodes `CFBundleShortVersionString = 1.0`
  and `CFBundleVersion = 1`, but published releases are `v0.0.x`. The pkg is built
  by `make pkg` (`pkgbuild`) and, in CI, renamed to `Otto-<tag>.pkg`.
- Capability `template`s use `{token}` placeholders (e.g.
  `tell application "{app}" to activate`). Some templates are dicts
  (Premiere/OBS); `PythonBridge` decodes `template` as `String`, so dict
  templates arrive as `""`.
- **Build registration:** new Swift files must be added to **both** the `SOURCES`
  list in `Makefile` and `Otto/Otto.xcodeproj/project.pbxproj` (no
  filesystem-synchronized groups). `make app` (swiftc) is the canonical build;
  `test_build.py` compiles the bundle.

## Phase 0 — Version Stamping (foundation)

The updater must compare the running app's version against the latest release
tag, so the bundle's version must be real.

- Introduce a single source of truth: a `VERSION` variable in the `Makefile`,
  defaulting to `git describe --tags --abbrev=0` (fallback to a literal when no
  tag is reachable).
- During `make app` (and therefore `make pkg`), substitute the version into the
  generated `Info.plist`'s `CFBundleShortVersionString` and `CFBundleVersion`
  (strip a leading `v` for the numeric fields as needed). Confirm how the current
  build materializes `Info.plist` (it contains `$(EXECUTABLE_NAME)`-style
  placeholders that only resolve under Xcode) and ensure `make app` writes a
  fully-resolved plist.
- Result: a release built as `v0.0.5` reports `0.0.5` at runtime via
  `Bundle.main.infoDictionary["CFBundleShortVersionString"]`.

**Acceptance:** `defaults read <Otto.app>/Contents/Info CFBundleShortVersionString`
matches the build's `VERSION` tag.

## Phase 1 — Customizable Shortcuts

### Data
- **New `HotkeyConfig.swift`** — `struct HotkeyConfig: Codable, Equatable` holding
  `keyCode: UInt32` and a portable modifier representation. Provides:
  - mapping between `NSEvent.ModifierFlags` and Carbon modifier masks
    (`optionKey`, `shiftKey`, `cmdKey`, `controlKey`),
  - a `displayString` rendering glyphs (e.g. `⌥Space`, `⌥⇧Space`),
  - static defaults: `summonDefault` (keyCode 49 / option), `journalDefault`
    (keyCode 49 / option+shift).
- **`SettingsStore`** gains `summonHotkey` and `journalHotkey` (persisted in
  `UserDefaults` as encoded `HotkeyConfig`, falling back to defaults). These are
  app-behavior settings, **not** Python env vars.

### UI
- **New `HotkeyRecorderView.swift`** — a SwiftUI control showing the current combo
  and a "record" affordance. While recording, install a local
  `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` monitor that captures the
  next `keyCode` + `modifierFlags`, validates (must include at least one
  modifier), and writes back a `HotkeyConfig`. Esc cancels.
- **`SettingsWindow`** gains a "Shortcuts" section with two recorders (Summon
  Otto, Open Journal) and an inline warning if the two configs are equal.

### Wiring
- **`OttoApp`** creates two `HotkeyManager`s: summon (id 1 → `paletteController.toggle()`)
  and journal (id 2 → `journalController.show()`), initialized from
  `SettingsStore`. The journal hotkey is newly registered here.
- On settings save, `restartHotkeys()` unregisters and re-registers both from the
  updated configs (alongside the existing `restartPython()` only when env-backed
  values changed — hotkey changes do **not** need a Python restart).

### Tests
- `HotkeyConfig` modifier mapping round-trips (NSEvent flags → Carbon → display)
  via Swift Testing.

**Acceptance:** Rebinding summon to a new combo in Settings and saving makes the
new combo summon the palette (old combo no longer fires); journal hotkey works;
equal-combo warning shows.

## Phase 2 — Auto-Update (custom GitHub checker)

### Checker
- **New `UpdateChecker.swift`** (`@Observable final class`):
  - `currentVersion` from `Bundle.main.infoDictionary["CFBundleShortVersionString"]`.
  - `checkForUpdates()` GETs
    `https://api.github.com/repos/Slaymish/Otto/releases/latest`, parses
    `tag_name` and the `assets[]` entry whose `name` ends in `.pkg`
    (`browser_download_url`). Sets `availableUpdate: UpdateInfo?`
    (`{ version, pkgURL, releaseURL, notes }`) when newer.
  - Pure helper `isNewer(_ candidate: String, than current: String) -> Bool` does
    a dotted-numeric semver compare after stripping a leading `v`. Unit-tested.
  - Triggered: ~5s after launch, then on a daily timer, and on demand from
    Settings ("Check now"). No-ops gracefully offline (sets a `lastError`-style
    status, never crashes).
- Only runs from the installed bundle (skip in dev mode, where
  `resourcesHaveBackend` is false), to avoid nagging during development.

### Notify
- **`MenuBarController`** shows a badge (small dot overlaid on the status glyph)
  and inserts a dynamic "Update to vX…" menu item when `availableUpdate != nil`;
  selecting it triggers the install flow.
- **`SettingsWindow`** shows an "Updates" section: current version, a banner with
  an **Update** button when one is available, and a "Check now" button. Reflects
  download/progress/error state.

### Install
- `downloadAndInstall()` uses `URLSession` to download the `.pkg` to a temp
  directory, then `NSWorkspace.shared.open(pkgURL)` to launch macOS Installer.
  After launching, Otto quits (`NSApp.terminate`) so Installer can replace
  `/Applications/Otto.app`. Surface download errors in the Settings UI.

### Tests
- `UpdateChecker.isNewer` covers: newer, older, equal, `v`-prefixed,
  different-length versions (`0.0.5` vs `0.0.4`, `0.1.0` vs `0.0.9`, `1.0` vs
  `0.0.4`).

**Acceptance:** With the current version below the latest release, the menu shows
a badge + "Update to vX" item and Settings shows the banner; clicking Update
downloads the pkg and launches Installer. With current == latest, no badge.

## Phase 3 + 4 — Mic Auto-Start, Circular Orb, Floating Capabilities

These ship together because the orb's listening/off visual is the mic-auto-start
state.

### Mic auto-start
- **`SettingsStore`** gains `micAutoStart: Bool` (default **true**, `UserDefaults`).
- **`SettingsWindow`** adds a toggle: "Start listening when Otto opens".
- The mic interaction changes from **hold-to-talk** (`DragGesture`) to
  **tap-to-toggle**:
  - On palette show: if `micAutoStart`, call `bridge.sendVoiceStart()` and show
    the live waveform; else show the mic glyph at rest.
  - Tapping the orb toggles listening (`sendVoiceStart`/`sendVoiceStop`).
  - On palette hide or successful submit, `sendVoiceStop()`.

### Circular orb ↔ bar morph
`CommandPalette` becomes a two-state surface driven by whether the input text is
empty:

- **Orb mode** (text empty): a ~140pt circle.
  - Listening → circular waveform (driven by `bridge.micLevel` /
    `bridge.waveformActive`).
  - Not listening (auto-start off, or toggled off) → `mic.fill` glyph; click to
    start.
  - An always-present, visually-collapsed (height/opacity 0) **focused**
    `TextField` captures the first keystroke so typing immediately triggers the
    morph. (Keeps focus handling identical to today; only the visual frame
    changes.)
- **Bar mode** (text non-empty): springs into the existing 640pt field +
  suggestion / result / learned / error rows (unchanged logic). Emptying the text
  morphs back to orb mode.
- Morph is a SwiftUI spring animating the container frame + corner radius.
  Panel sizing continues via `NSHostingController.sizingOptions =
  .preferredContentSize`; the panel is anchored top-center so growth is
  predictable (verify re-centering behavior as the preferred size changes).

### New components (kept small)
- **`OrbView.swift`** — the circular visual: idle mic glyph, listening waveform
  ring, and a subtle pulse. Reuses `WaveformView`'s level input.
- **`CapabilityHalo.swift`** — lays out 4–5 capability chips radially around the
  orb (`angle = 2π·i/n`, fixed radius), each a capsule with a primitive icon +
  short label. Only shown in orb mode.

### Floating capabilities behavior
- **Source (v1):** the existing suggestion heuristic already in `CommandPalette` —
  `bridge.recentPhrases` (recent) + most-used / highest-confidence
  `bridge.journalCards`. Take the top 4–5. No new IPC needed.
- **Tap behavior:** detect a `{token}` placeholder in the card's `template`
  (regex `\{[a-zA-Z_]+\}`):
  - placeholder present → pre-fill the input with the capability phrase for
    editing (morphs to bar mode, no submit),
  - no placeholder (including dict-template cards that arrive as `""`) → run
    immediately via `bridge.sendText(...)` (matching today's suggestion tap).

### Tests
- Build test (`test_build.py`) keeps the bundle compiling with the new files.
- Pure logic worth a Swift Testing case: the placeholder-detection helper
  (parameterized vs simple).

**Acceptance:** Opening Otto shows the orb; with auto-start on it's already
listening (waveform); with auto-start off it shows the mic glyph and a click
starts listening. Typing morphs the orb into the bar and back on clear. 4–5
capability chips float around the orb; clicking a parameterized one fills the
input, a simple one runs.

## Files

**New**
- `Otto/Otto/HotkeyConfig.swift`
- `Otto/Otto/HotkeyRecorderView.swift`
- `Otto/Otto/UpdateChecker.swift`
- `Otto/Otto/OrbView.swift`
- `Otto/Otto/CapabilityHalo.swift`

**Modified**
- `Otto/Otto/SettingsStore.swift` — hotkeys, `micAutoStart`.
- `Otto/Otto/SettingsWindow.swift` — Shortcuts, Updates, mic toggle sections.
- `Otto/Otto/OttoApp.swift` — two hotkeys + `restartHotkeys()`, `UpdateChecker`
  wiring, menu badge plumbing.
- `Otto/Otto/MenuBarController.swift` — update badge + dynamic update menu item.
- `Otto/Otto/CommandPalette.swift` — orb/bar morph, tap-to-toggle mic, halo.
- `Otto/Otto/HotkeyManager.swift` — (only if a re-register convenience is needed).
- `Otto/Otto/Info.plist` — version fields fed by the build.
- `Makefile` — `VERSION` stamping; register new `SOURCES`.
- `Otto/Otto.xcodeproj/project.pbxproj` — register new Swift files.

## Risks / Open Questions

- **Panel re-centering during morph:** growing the hosting controller's preferred
  size while keeping a stable top-center anchor needs verification; may require
  setting the frame origin explicitly on size change rather than relying on
  `.preferredContentSize` alone.
- **First-keystroke capture in orb mode:** relies on an always-focused hidden
  `TextField`. Confirm `onKeyPress`/focus still behaves inside the borderless
  `CommandPanel` when the field is zero-size.
- **Unsigned pkg + Gatekeeper:** launching the downloaded `.pkg` may prompt
  Gatekeeper. Acceptable for the current unsigned distribution; documented for the
  user.
- **Version stamping under `make app`:** must confirm the non-Xcode build fully
  resolves `Info.plist` placeholders so the runtime version is correct.

## Build Order

0. Version stamping (foundation for the updater).
1. Customizable shortcuts.
2. Auto-update.
3. Mic auto-start + circular orb + floating capabilities (combined UI phase).
