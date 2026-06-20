# Otto UI & Lifecycle Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Otto's summon/journal shortcuts user-configurable, add in-app GitHub auto-update, default the mic to listen-on-open, and replace the Spotlight-style bar with a circular orb that morphs into the bar and floats relevant capabilities around itself.

**Architecture:** Native SwiftUI menu-bar app (`Otto/`). New pure-logic helpers (`HotkeyConfig`, `UpdateChecker.isNewer`, `CapabilityKind`) are unit-tested with standalone `swiftc`-compiled assertion binaries; UI and integration work is verified by the canonical `make app` build plus manual acceptance. Settings persist via `SettingsStore` (Keychain + `UserDefaults`).

**Tech Stack:** Swift 5.x / SwiftUI / AppKit, Carbon (`RegisterEventHotKey`), `NWConnection` IPC, `swiftc`-based `make app` build (no Xcode), `pkgbuild`, GitHub Releases API.

## Global Constraints

- Every new Swift file MUST be registered in **both** `Makefile` `SOURCES` **and** `Otto/Otto.xcodeproj/project.pbxproj` (four entries: PBXBuildFile, PBXFileReference, group child, PBXSourcesBuildPhase). `make app` is the canonical build gate.
- Canonical build command: `make app` → `Otto/build/Otto.app`. It must succeed after every task that touches Swift or the Makefile.
- Swift unit tests run standalone: `swiftc <source.swift> <test.swift> -o /tmp/bin && /tmp/bin` (exit non-zero on failure). No xcodebuild/Package.swift exists.
- Target floor: `arch-apple-macos14.0` (from `Makefile` `TARGET`); guard macOS 26+ APIs behind `#if HAS_MACOS26_SDK` / `if #available(macOS 26.0, *)` exactly as `CommandPalette.swift` already does.
- GitHub repo for updates: `Slaymish/Otto`. Release pkg asset name pattern: `Otto-<tag>.pkg` (e.g. `Otto-v0.0.5.pkg`).
- Mic auto-start default: **true**. Summon default: ⌥Space (keyCode 49 / `optionKey`). Journal default: ⌥⇧Space (keyCode 49 / `optionKey|shiftKey`).
- Do not disturb the user's existing uncommitted working changes outside the files named in each task.
- Commit message types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`.

---

## Task 1: Version stamping through the build

**Files:**
- Modify: `Makefile:8-13` (add `VERSION` vars), `Makefile:51-57` (plist sed), `Makefile:77-82` (pkg)
- Modify: `Otto/Otto/Info.plist:17-20` (version fields → placeholders)

**Interfaces:**
- Produces: a built `Otto.app` whose `CFBundleShortVersionString` equals the git tag (leading `v` stripped). Task 7's `UpdateChecker.currentVersion` reads this at runtime.

- [ ] **Step 1: Change Info.plist to use placeholders**

In `Otto/Otto/Info.plist`, replace the hardcoded version block:

```xml
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
```

- [ ] **Step 2: Add VERSION vars to the Makefile**

After `Makefile:13` (the `SDK_FLAGS` line), add:

```makefile
# Version: latest reachable git tag (e.g. v0.0.5) → 0.0.5 for plist fields.
# Override with `make app VERSION=v0.0.6`.
VERSION        := $(shell git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
VERSION_NUMBER := $(patsubst v%,%,$(VERSION))
```

- [ ] **Step 3: Substitute version fields in the plist rule**

Replace the `$(PLIST_DST)` recipe body (`Makefile:53-57`) with:

```makefile
	sed \
	    -e 's/$$(EXECUTABLE_NAME)/Otto/g' \
	    -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/com.otto.app/g' \
	    -e 's/$$(PRODUCT_NAME)/Otto/g' \
	    -e 's/$$(MARKETING_VERSION)/$(VERSION_NUMBER)/g' \
	    -e 's/$$(CURRENT_PROJECT_VERSION)/$(VERSION_NUMBER)/g' \
	    "$<" > "$@"
```

- [ ] **Step 4: Stamp the pkg version**

Replace the `pkg:` recipe (`Makefile:77-82`) with:

```makefile
pkg: app
	pkgbuild \
	    --component "$(APP)" \
	    --install-location /Applications \
	    --version "$(VERSION_NUMBER)" \
	    "Otto/build/Otto.pkg"
	@echo "✓  Otto/build/Otto.pkg ($(VERSION_NUMBER))"
```

- [ ] **Step 5: Build and verify the stamped version**

Run:
```bash
make clean && make app && \
  defaults read "$(pwd)/Otto/build/Otto.app/Contents/Info" CFBundleShortVersionString
```
Expected: prints the numeric version (e.g. `0.0.4`) matching `git describe --tags --abbrev=0` with the `v` stripped — NOT `1.0`.

- [ ] **Step 6: Commit**

```bash
git add Makefile Otto/Otto/Info.plist
git commit -m "build: stamp app version from git tag into Info.plist and pkg"
```

---

## Task 2: HotkeyConfig (pure model + test)

**Files:**
- Create: `Otto/Otto/HotkeyConfig.swift`
- Create: `tests/swift/HotkeyConfigTests.swift`
- Modify: `Makefile:15-26` (SOURCES), `Otto/Otto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces:
  - `struct HotkeyConfig: Codable, Equatable { var keyCode: UInt32; var carbonModifiers: UInt32 }`
  - `HotkeyConfig.summonDefault` / `.journalDefault`
  - `static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32`
  - `init?(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags)` (returns nil if no modifier)
  - `var displayString: String` (e.g. `"⌥Space"`)
  - Consumed by Tasks 3 (SettingsStore), 4 (recorder), 5 (hotkey wiring).

- [ ] **Step 1: Write the failing test**

Create `tests/swift/HotkeyConfigTests.swift`:

```swift
import AppKit

func expect(_ cond: Bool, _ msg: String) {
    if !cond { FileHandle.standardError.write(Data(("FAIL: " + msg + "\n").utf8)); exit(1) }
}

// Carbon constants: optionKey 0x0800, shiftKey 0x0200, cmdKey 0x0100, controlKey 0x1000
let opt = HotkeyConfig.carbonModifiers(from: [.option])
expect(opt == 0x0800, "option maps to 0x0800, got \(opt)")

let optShift = HotkeyConfig.carbonModifiers(from: [.option, .shift])
expect(optShift == 0x0800 | 0x0200, "option+shift maps to 0x0A00, got \(optShift)")

// Defaults
expect(HotkeyConfig.summonDefault.keyCode == 49, "summon keyCode 49")
expect(HotkeyConfig.summonDefault.carbonModifiers == 0x0800, "summon = option")
expect(HotkeyConfig.journalDefault.carbonModifiers == 0x0800 | 0x0200, "journal = option+shift")

// Reject combos with no modifier
expect(HotkeyConfig(keyCode: 49, modifierFlags: []) == nil, "no-modifier combo rejected")

// Display string
expect(HotkeyConfig.summonDefault.displayString == "⌥Space", "summon display, got \(HotkeyConfig.summonDefault.displayString)")
expect(HotkeyConfig.journalDefault.displayString == "⌥⇧Space", "journal display, got \(HotkeyConfig.journalDefault.displayString)")

// Codable round-trip (used for UserDefaults storage)
let data = try! JSONEncoder().encode(HotkeyConfig.journalDefault)
let decoded = try! JSONDecoder().decode(HotkeyConfig.self, from: data)
expect(decoded == HotkeyConfig.journalDefault, "codable round-trip")

print("ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swiftc Otto/Otto/HotkeyConfig.swift tests/swift/HotkeyConfigTests.swift -framework Carbon -o /tmp/hk && /tmp/hk`
Expected: FAIL — `error: cannot find 'HotkeyConfig' in scope` (file not created yet).

- [ ] **Step 3: Write HotkeyConfig.swift**

Create `Otto/Otto/HotkeyConfig.swift`:

```swift
import AppKit
import Carbon.HIToolbox

/// A persistable global-hotkey description: a virtual key code plus Carbon modifier mask.
/// Carbon masks (from <Carbon/HIToolbox/Events.h>): cmdKey 0x0100, shiftKey 0x0200,
/// optionKey 0x0800, controlKey 0x1000.
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let summonDefault  = HotkeyConfig(keyCode: 49, carbonModifiers: UInt32(optionKey))
    static let journalDefault = HotkeyConfig(keyCode: 49, carbonModifiers: UInt32(optionKey | shiftKey))

    /// Map AppKit modifier flags to a Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// Build from a captured key event; requires at least one modifier.
    init?(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        let mods = Self.carbonModifiers(from: modifierFlags)
        guard mods != 0 else { return nil }
        self.keyCode = keyCode
        self.carbonModifiers = mods
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Human-readable glyph string, e.g. "⌥⇧Space".
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Minimal key-code → label map covering common summon keys.
    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "Return"
        case kVK_Tab:          return "Tab"
        case kVK_Escape:       return "Esc"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        default:               return "Key\(code)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swiftc Otto/Otto/HotkeyConfig.swift tests/swift/HotkeyConfigTests.swift -framework Carbon -o /tmp/hk && /tmp/hk`
Expected: prints `ok`, exit 0.

- [ ] **Step 5: Register in Makefile SOURCES**

In `Makefile`, append to the `SOURCES` list (after the `OnboardingView.swift` line, adding a `\` continuation to the prior last line):

```makefile
	Otto/Otto/OnboardingView.swift \
	Otto/Otto/HotkeyConfig.swift
```

- [ ] **Step 6: Register in project.pbxproj**

In `Otto/Otto.xcodeproj/project.pbxproj`, add these four lines mirroring the `MenuBarController.swift` entries (IDs chosen to not collide):

Near the other `PBXBuildFile` entries (around line 19):
```
		AA00000200000000000000B1 /* HotkeyConfig.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA00000100000000000000B1 /* HotkeyConfig.swift */; };
```
Near the `PBXFileReference` entries (around line 36):
```
		AA00000100000000000000B1 /* HotkeyConfig.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HotkeyConfig.swift; sourceTree = "<group>"; };
```
In the group children list (around line 81):
```
				AA00000100000000000000B1 /* HotkeyConfig.swift */,
```
In the `PBXSourcesBuildPhase` files list (around line 179):
```
				AA00000200000000000000B1 /* HotkeyConfig.swift in Sources */,
```

- [ ] **Step 7: Verify the app still builds**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`, no errors.

- [ ] **Step 8: Commit**

```bash
git add Otto/Otto/HotkeyConfig.swift tests/swift/HotkeyConfigTests.swift Makefile Otto/Otto.xcodeproj/project.pbxproj
git commit -m "feat: add HotkeyConfig model for customizable shortcuts"
```

---

## Task 3: Persist hotkeys + mic auto-start in SettingsStore

**Files:**
- Modify: `Otto/Otto/SettingsStore.swift`

**Interfaces:**
- Consumes: `HotkeyConfig` (Task 2).
- Produces on `SettingsStore.shared`:
  - `@Published var summonHotkey: HotkeyConfig`
  - `@Published var journalHotkey: HotkeyConfig`
  - `@Published var micAutoStart: Bool`
  Consumed by Tasks 5 (hotkey wiring), 10 (mic), and the Settings UI.

- [ ] **Step 1: Add published properties**

In `Otto/Otto/SettingsStore.swift`, after the existing `@Published var browserName` line (`:12`), add:

```swift
    @Published var summonHotkey: HotkeyConfig = .summonDefault
    @Published var journalHotkey: HotkeyConfig = .journalDefault
    @Published var micAutoStart: Bool = true
```

- [ ] **Step 2: Load them in reload()**

In `reload()` (after the `browserName` assignment, `:24`), add:

```swift
        summonHotkey  = Self.decodeHotkey("otto.summonHotkey")  ?? .summonDefault
        journalHotkey = Self.decodeHotkey("otto.journalHotkey") ?? .journalDefault
        micAutoStart  = UserDefaults.standard.object(forKey: "otto.micAutoStart") as? Bool ?? true
```

- [ ] **Step 3: Persist them in save()**

In `save()` (after the `browserName` set, `:31`), add:

```swift
        Self.encodeHotkey(summonHotkey,  forKey: "otto.summonHotkey")
        Self.encodeHotkey(journalHotkey, forKey: "otto.journalHotkey")
        UserDefaults.standard.set(micAutoStart, forKey: "otto.micAutoStart")
```

- [ ] **Step 4: Add the JSON helpers**

Before the closing brace of `SettingsStore`, add:

```swift
    // MARK: - Hotkey persistence (JSON in UserDefaults)

    private static func encodeHotkey(_ cfg: HotkeyConfig, forKey key: String) {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func decodeHotkey(_ key: String) -> HotkeyConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyConfig.self, from: data)
    }
```

- [ ] **Step 5: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`.

- [ ] **Step 6: Commit**

```bash
git add Otto/Otto/SettingsStore.swift
git commit -m "feat: persist hotkeys and mic-auto-start in SettingsStore"
```

---

## Task 4: HotkeyRecorderView

**Files:**
- Create: `Otto/Otto/HotkeyRecorderView.swift`
- Modify: `Makefile` SOURCES, `Otto/Otto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `HotkeyConfig` (Task 2).
- Produces: `struct HotkeyRecorderView: View { init(label: String, config: Binding<HotkeyConfig>) }`. Consumed by Task 5 (Settings UI).

- [ ] **Step 1: Create HotkeyRecorderView.swift**

Create `Otto/Otto/HotkeyRecorderView.swift`:

```swift
import SwiftUI
import AppKit

/// A "click to record" control that captures the next key combo into a HotkeyConfig.
/// While recording, a local key-down monitor intercepts events; Esc cancels.
struct HotkeyRecorderView: View {
    let label: String
    @Binding var config: HotkeyConfig

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: toggle) {
                Text(recording ? "Press keys…" : config.displayString)
                    .font(.system(.body, design: .rounded).monospaced())
                    .frame(minWidth: 96)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(recording ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels without changing the binding.
            if event.keyCode == 53 { // kVK_Escape
                stop()
                return nil
            }
            if let cfg = HotkeyConfig(keyCode: UInt32(event.keyCode), modifierFlags: event.modifierFlags) {
                config = cfg
                stop()
            }
            return nil // swallow the event while recording
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }
}
```

- [ ] **Step 2: Register in Makefile SOURCES**

Append to `SOURCES` (continuing the list):
```makefile
	Otto/Otto/HotkeyRecorderView.swift
```

- [ ] **Step 3: Register in project.pbxproj**

Add the four entries using IDs `...B2`, mirroring Task 2 Step 6:
```
		AA00000200000000000000B2 /* HotkeyRecorderView.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA00000100000000000000B2 /* HotkeyRecorderView.swift */; };
```
```
		AA00000100000000000000B2 /* HotkeyRecorderView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = HotkeyRecorderView.swift; sourceTree = "<group>"; };
```
```
				AA00000100000000000000B2 /* HotkeyRecorderView.swift */,
```
```
				AA00000200000000000000B2 /* HotkeyRecorderView.swift in Sources */,
```

- [ ] **Step 4: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`.

- [ ] **Step 5: Commit**

```bash
git add Otto/Otto/HotkeyRecorderView.swift Makefile Otto/Otto.xcodeproj/project.pbxproj
git commit -m "feat: add HotkeyRecorderView for capturing shortcut combos"
```

---

## Task 5: Wire two hotkeys + Settings shortcuts section

**Files:**
- Modify: `Otto/Otto/HotkeyManager.swift` (re-register convenience), `Otto/Otto/OttoApp.swift`, `Otto/Otto/SettingsWindow.swift`

**Interfaces:**
- Consumes: `HotkeyConfig`, `HotkeyRecorderView`, `SettingsStore.summonHotkey/.journalHotkey`.
- Produces: `AppDelegate.restartHotkeys()`; two registered hotkeys (summon id 1, journal id 2).

- [ ] **Step 1: Build summon + journal hotkeys from settings in OttoApp**

In `Otto/Otto/OttoApp.swift`, replace the single hotkey block in `startMainApp()` (`:87-90`):

```swift
        hotkeyManager = HotkeyManager(onToggle: { [weak self] in
            self?.paletteController?.toggle()
        })
        hotkeyManager?.register()
```

with two managers driven by settings:

```swift
        registerHotkeys()
```

Add a `journalHotkeyManager` property next to `hotkeyManager` (`:23`):

```swift
    private var hotkeyManager: HotkeyManager?
    private var journalHotkeyManager: HotkeyManager?
```

Add these methods after `restartPython()` (`:109`):

```swift
    // MARK: - Hotkeys

    private func registerHotkeys() {
        let summon = SettingsStore.shared.summonHotkey
        let journal = SettingsStore.shared.journalHotkey

        let s = HotkeyManager(keyCode: summon.keyCode, modifiers: summon.carbonModifiers, id: 1,
                              onToggle: { [weak self] in self?.paletteController?.toggle() })
        s.register()
        hotkeyManager = s

        let j = HotkeyManager(keyCode: journal.keyCode, modifiers: journal.carbonModifiers, id: 2,
                              onToggle: { [weak self] in self?.journalController?.show() })
        j.register()
        journalHotkeyManager = j
    }

    /// Re-register both global hotkeys after a settings change (no Python restart needed).
    func restartHotkeys() {
        hotkeyManager?.unregister()
        journalHotkeyManager?.unregister()
        registerHotkeys()
    }
```

- [ ] **Step 2: Split settings save into env-changes vs hotkey-changes**

In `startMainApp()` where `settingsController` is created (`:75`), change the `onSaved` closure so hotkeys and env are both refreshed:

```swift
        settingsController = SettingsController(onSaved: { [weak self] in
            self?.restartHotkeys()
            self?.restartPython()
        })
```

- [ ] **Step 3: Add the Shortcuts section to SettingsView**

In `Otto/Otto/SettingsWindow.swift`, add a computed section after `preferencesSection` (used in `body`):

```swift
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts")
                .font(.headline)
            HotkeyRecorderView(label: "Summon Otto", config: $store.summonHotkey)
            HotkeyRecorderView(label: "Open Journal", config: $store.journalHotkey)
            if store.summonHotkey == store.journalHotkey {
                Text("Both shortcuts are the same — only one will fire.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
```

Add it to the scroll content `VStack` (`:60-63`), after `preferencesSection`:

```swift
                    apiKeySection
                    preferencesSection
                    shortcutsSection
```

- [ ] **Step 4: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`.

- [ ] **Step 5: Manual acceptance**

Run `./run.sh --app`. In Settings, set Summon to a new combo (e.g. ⌥⌘O), Save. Verify the new combo opens the palette and the old ⌥Space no longer does. Verify the journal combo opens the journal.

- [ ] **Step 6: Commit**

```bash
git add Otto/Otto/OttoApp.swift Otto/Otto/SettingsWindow.swift
git commit -m "feat: register customizable summon and journal hotkeys"
```

---

## Task 6: UpdateChecker.isNewer (pure semver + test)

**Files:**
- Create: `Otto/Otto/UpdateChecker.swift` (initial: pure helper only)
- Create: `tests/swift/UpdateCheckerTests.swift`
- Modify: `Makefile` SOURCES, `Otto/Otto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `enum SemVer { static func isNewer(_ candidate: String, than current: String) -> Bool }`. Consumed by Task 7.

- [ ] **Step 1: Write the failing test**

Create `tests/swift/UpdateCheckerTests.swift`:

```swift
import Foundation

func expect(_ cond: Bool, _ msg: String) {
    if !cond { FileHandle.standardError.write(Data(("FAIL: " + msg + "\n").utf8)); exit(1) }
}

expect(SemVer.isNewer("0.0.5", than: "0.0.4"), "0.0.5 > 0.0.4")
expect(SemVer.isNewer("v0.0.5", than: "0.0.4"), "v-prefix stripped")
expect(SemVer.isNewer("0.1.0", than: "0.0.9"), "0.1.0 > 0.0.9")
expect(SemVer.isNewer("1.0", than: "0.0.4"), "1.0 > 0.0.4 (uneven length)")
expect(!SemVer.isNewer("0.0.4", than: "0.0.4"), "equal is not newer")
expect(!SemVer.isNewer("0.0.3", than: "0.0.4"), "older is not newer")
expect(!SemVer.isNewer("0.0.4", than: "0.0.4.0"), "0.0.4 == 0.0.4.0")

print("ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swiftc Otto/Otto/UpdateChecker.swift tests/swift/UpdateCheckerTests.swift -o /tmp/uc && /tmp/uc`
Expected: FAIL — `error: cannot find 'SemVer' in scope`.

- [ ] **Step 3: Create UpdateChecker.swift with the SemVer helper**

Create `Otto/Otto/UpdateChecker.swift`:

```swift
import Foundation

/// Dotted-numeric version comparison, tolerant of a leading "v" and uneven lengths.
enum SemVer {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate)
        let b = parts(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swiftc Otto/Otto/UpdateChecker.swift tests/swift/UpdateCheckerTests.swift -o /tmp/uc && /tmp/uc`
Expected: prints `ok`, exit 0.

- [ ] **Step 5: Register in Makefile SOURCES and pbxproj (IDs `...B3`)**

Append `Otto/Otto/UpdateChecker.swift` to `SOURCES`. Add to `project.pbxproj`:
```
		AA00000200000000000000B3 /* UpdateChecker.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA00000100000000000000B3 /* UpdateChecker.swift */; };
```
```
		AA00000100000000000000B3 /* UpdateChecker.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = UpdateChecker.swift; sourceTree = "<group>"; };
```
```
				AA00000100000000000000B3 /* UpdateChecker.swift */,
```
```
				AA00000200000000000000B3 /* UpdateChecker.swift in Sources */,
```

- [ ] **Step 6: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`.

- [ ] **Step 7: Commit**

```bash
git add Otto/Otto/UpdateChecker.swift tests/swift/UpdateCheckerTests.swift Makefile Otto/Otto.xcodeproj/project.pbxproj
git commit -m "feat: add SemVer comparison for update checking"
```

---

## Task 7: UpdateChecker fetch / parse / install

**Files:**
- Modify: `Otto/Otto/UpdateChecker.swift`

**Interfaces:**
- Consumes: `SemVer.isNewer` (Task 6).
- Produces:
  - `struct UpdateInfo: Equatable { let version: String; let pkgURL: URL; let releaseURL: URL; let notes: String }`
  - `@MainActor @Observable final class UpdateChecker` with:
    - `var currentVersion: String`
    - `var availableUpdate: UpdateInfo?`
    - `var status: UpdateChecker.Status` (`.idle/.checking/.downloading(Double)/.failed(String)`)
    - `func checkForUpdates() async`
    - `func downloadAndInstall() async`
  Consumed by Tasks 8 (menu badge) and 9 (settings UI + app wiring).

- [ ] **Step 1: Append the checker class to UpdateChecker.swift**

Add below the `SemVer` enum in `Otto/Otto/UpdateChecker.swift`:

```swift
import Observation
import AppKit

struct UpdateInfo: Equatable {
    let version: String      // numeric, e.g. "0.0.5"
    let pkgURL: URL
    let releaseURL: URL
    let notes: String
}

@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case downloading(Double)
        case failed(String)
    }

    private static let latestURL = URL(string: "https://api.github.com/repos/Slaymish/Otto/releases/latest")!

    let currentVersion: String
    var availableUpdate: UpdateInfo?
    var status: Status = .idle
    /// Called when availableUpdate transitions to non-nil (wired by AppDelegate for the menu badge).
    var onUpdateFound: (() -> Void)?

    init() {
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    func checkForUpdates() async {
        status = .checking
        do {
            var req = URLRequest(url: Self.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                status = .failed("Malformed release data")
                return
            }
            let numeric = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/Slaymish/Otto/releases/latest")!
            let notes = (json["body"] as? String) ?? ""

            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let pkgURLString = assets.first { ($0["name"] as? String)?.hasSuffix(".pkg") == true }?["browser_download_url"] as? String

            status = .idle
            guard SemVer.isNewer(tag, than: currentVersion), let pkgStr = pkgURLString, let pkgURL = URL(string: pkgStr) else {
                availableUpdate = nil
                return
            }
            availableUpdate = UpdateInfo(version: numeric, pkgURL: pkgURL, releaseURL: releaseURL, notes: notes)
            onUpdateFound?()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func downloadAndInstall() async {
        guard let update = availableUpdate else { return }
        status = .downloading(0)
        do {
            let (tmpURL, _) = try await URLSession.shared.download(from: update.pkgURL)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("Otto-v\(update.version).pkg")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            status = .idle
            NSWorkspace.shared.open(dest)   // launches macOS Installer
            // Give Installer a beat to take over, then quit so it can replace the bundle.
            try? await Task.sleep(nanoseconds: 800_000_000)
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`.

- [ ] **Step 3: Re-run the SemVer test (ensure the added code didn't break standalone compile)**

Run: `swiftc Otto/Otto/UpdateChecker.swift tests/swift/UpdateCheckerTests.swift -o /tmp/uc && /tmp/uc`
Expected: prints `ok`. (UpdateChecker.swift now imports AppKit/Observation — still compiles standalone on macOS.)

- [ ] **Step 4: Commit**

```bash
git add Otto/Otto/UpdateChecker.swift
git commit -m "feat: fetch, compare, and install GitHub releases in UpdateChecker"
```

---

## Task 8: Menu-bar update badge + dynamic menu item

**Files:**
- Modify: `Otto/Otto/MenuBarController.swift`

**Interfaces:**
- Produces on `MenuBarController`:
  - `var onInstallUpdate: () -> Void`
  - `func setUpdateAvailable(_ version: String?)` — toggles a badge + "Update to vX…" item.
  Consumed by Task 9 (AppDelegate wiring).

- [ ] **Step 1: Add update state + API to MenuBarController**

In `Otto/Otto/MenuBarController.swift`, add properties after `onQuit` (`:12`):

```swift
    var onInstallUpdate: () -> Void = {}
    private var pendingUpdateVersion: String?
```

- [ ] **Step 2: Add setUpdateAvailable + badge rendering**

Add after `install()` (`:24`):

```swift
    /// Show/hide the update affordance. Pass nil to clear.
    func setUpdateAvailable(_ version: String?) {
        pendingUpdateVersion = version
        applyBadge()
        statusItem?.menu = buildMenu()
    }

    private func applyBadge() {
        guard let button = statusItem?.button else { return }
        let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Otto")
        base?.isTemplate = true
        if pendingUpdateVersion != nil {
            // Overlay a small dot to signal an available update.
            let badged = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
                base?.draw(in: rect)
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
                return true
            }
            badged.isTemplate = false
            button.image = badged
        } else {
            button.image = base
        }
    }
```

- [ ] **Step 3: Insert the dynamic update item into the menu**

In `buildMenu()`, after the `Settings…` item (`:46`) and before the separator (`:48`), add:

```swift
        if let v = pendingUpdateVersion {
            menu.addItem(.separator())
            let updateItem = NSMenuItem(title: "Update to v\(v)\u{2026}", action: #selector(installUpdate), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }
```

- [ ] **Step 4: Add the action**

Add after `@objc private func quit()` (`:77`):

```swift
    @objc private func installUpdate() { onInstallUpdate() }
```

- [ ] **Step 5: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`.

- [ ] **Step 6: Commit**

```bash
git add Otto/Otto/MenuBarController.swift
git commit -m "feat: menu-bar update badge and dynamic update menu item"
```

---

## Task 9: Wire UpdateChecker into the app + Settings Updates section

**Files:**
- Modify: `Otto/Otto/OttoApp.swift`, `Otto/Otto/SettingsWindow.swift`

**Interfaces:**
- Consumes: `UpdateChecker`, `MenuBarController.setUpdateAvailable/.onInstallUpdate`.
- Produces: shared `UpdateChecker` instance reachable by the Settings window.

- [ ] **Step 1: Hold an UpdateChecker in AppDelegate**

In `Otto/Otto/OttoApp.swift`, add a property near `bridge` (`:18`):

```swift
    let updateChecker = UpdateChecker()
```

- [ ] **Step 2: Wire menu badge + install, and kick off a check (installed bundle only)**

In `startMainApp()`, after `menuBar.install()` / `menuBarController = menuBar` (`:85`), add:

```swift
        // Updates: badge the menu when one is found; install on click.
        updateChecker.onUpdateFound = { [weak self] in
            self?.menuBarController?.setUpdateAvailable(self?.updateChecker.availableUpdate?.version)
        }
        menuBar.onInstallUpdate = { [weak self] in
            Task { await self?.updateChecker.downloadAndInstall() }
        }
        if resourcesHaveBackend {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.updateChecker.checkForUpdates()
                self?.scheduleDailyUpdateCheck()
            }
        }
```

- [ ] **Step 3: Add the daily timer**

Add a property near the other vars (`:26`):

```swift
    private var updateTimer: Timer?
```

Add this method after `restartHotkeys()`:

```swift
    private func scheduleDailyUpdateCheck() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { await self?.updateChecker.checkForUpdates() }
        }
    }
```

- [ ] **Step 4: Pass the checker to the Settings window**

Change the `SettingsController` init to accept the checker. In `Otto/Otto/SettingsWindow.swift`, update `SettingsController`:

```swift
    private let updateChecker: UpdateChecker
    private let onSaved: () -> Void

    init(updateChecker: UpdateChecker, onSaved: @escaping () -> Void) {
        self.updateChecker = updateChecker
        self.onSaved = onSaved
        super.init()
    }
```

And in `buildWindow()` pass it to the view:

```swift
        let view = SettingsView(
            updateChecker: updateChecker,
            onSave: { [weak self] in
                self?.onSaved()
                self?.window?.orderOut(nil)
            },
            onClose: { [weak self] in self?.window?.orderOut(nil) }
        )
```

In `OttoApp.swift` `startMainApp()`, update construction (`:75`):

```swift
        settingsController = SettingsController(updateChecker: updateChecker, onSaved: { [weak self] in
            self?.restartHotkeys()
            self?.restartPython()
        })
```

- [ ] **Step 5: Add the Updates section to SettingsView**

In `SettingsView`, add a stored property and a section. After `@State private var showKey` (`:55`):

```swift
    var updateChecker: UpdateChecker
```

Update the `SettingsView` memberwise usage — the `body`'s scroll `VStack` (`:60-63`) becomes:

```swift
                    apiKeySection
                    preferencesSection
                    shortcutsSection
                    updatesSection
```

Add the section:

```swift
    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates")
                .font(.headline)
            HStack {
                Text("Current version \(updateChecker.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check now") {
                    Task { await updateChecker.checkForUpdates() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let update = updateChecker.availableUpdate {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Version \(update.version) is available")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Update") {
                        Task { await updateChecker.downloadAndInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.10)))
            }
            if case .downloading = updateChecker.status {
                ProgressView().controlSize(.small)
            } else if case .failed(let msg) = updateChecker.status {
                Text(msg).font(.caption).foregroundStyle(.orange)
            }
        }
    }
```

- [ ] **Step 6: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`. (Note: `SettingsView` reads `@Observable` `UpdateChecker`, so SwiftUI tracks `availableUpdate`/`status` automatically.)

- [ ] **Step 7: Manual acceptance**

Build a bundle whose version is below the latest release (`make app VERSION=v0.0.0`), run it from `Otto/build/Otto.app`. Within ~5s the menu shows a badge + "Update to vX…"; Settings → Updates shows the banner. Click "Check now" to force a re-check.

- [ ] **Step 8: Commit**

```bash
git add Otto/Otto/OttoApp.swift Otto/Otto/SettingsWindow.swift
git commit -m "feat: wire update checker into app menu and settings"
```

---

## Task 10: CapabilityKind helper (parameterized detection + test)

**Files:**
- Create: `Otto/Otto/CapabilityKind.swift`
- Create: `tests/swift/CapabilityKindTests.swift`
- Modify: `Makefile` SOURCES, `Otto/Otto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `enum CapabilityKind { static func isParameterized(template: String) -> Bool }`. Consumed by Task 13 (halo) / Task 14 (palette tap).

- [ ] **Step 1: Write the failing test**

Create `tests/swift/CapabilityKindTests.swift`:

```swift
import Foundation

func expect(_ cond: Bool, _ msg: String) {
    if !cond { FileHandle.standardError.write(Data(("FAIL: " + msg + "\n").utf8)); exit(1) }
}

expect(CapabilityKind.isParameterized(template: "tell application \"{app}\" to activate"), "{app} is a param")
expect(CapabilityKind.isParameterized(template: "https://www.google.com/search?q={query}"), "{query} is a param")
expect(!CapabilityKind.isParameterized(template: "tell application \"Spotify\" to playpause"), "no braces = simple")
expect(!CapabilityKind.isParameterized(template: ""), "empty (dict template) = simple")
expect(!CapabilityKind.isParameterized(template: "func(){ return 1 }"), "JS braces with non-token content = simple")

print("ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swiftc Otto/Otto/CapabilityKind.swift tests/swift/CapabilityKindTests.swift -o /tmp/ck && /tmp/ck`
Expected: FAIL — `error: cannot find 'CapabilityKind' in scope`.

- [ ] **Step 3: Create CapabilityKind.swift**

Create `Otto/Otto/CapabilityKind.swift`:

```swift
import Foundation

/// Classifies a capability template by whether it has a `{token}` placeholder.
/// Templates that arrive empty (dict templates serialized to "" over IPC) are simple.
enum CapabilityKind {
    /// A placeholder is `{` + one-or-more identifier chars + `}` (e.g. {app}, {query}, {scene}).
    /// This excludes JS object/function braces like `(){ return 1 }` which contain spaces/punctuation.
    static func isParameterized(template: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\{[A-Za-z_][A-Za-z0-9_]*\\}") else { return false }
        let range = NSRange(template.startIndex..., in: template)
        return regex.firstMatch(in: template, range: range) != nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swiftc Otto/Otto/CapabilityKind.swift tests/swift/CapabilityKindTests.swift -o /tmp/ck && /tmp/ck`
Expected: prints `ok`, exit 0.

- [ ] **Step 5: Register in Makefile SOURCES and pbxproj (IDs `...B6`)**

Append `Otto/Otto/CapabilityKind.swift` to `SOURCES`. Add to `project.pbxproj`:
```
		AA00000200000000000000B6 /* CapabilityKind.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA00000100000000000000B6 /* CapabilityKind.swift */; };
```
```
		AA00000100000000000000B6 /* CapabilityKind.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CapabilityKind.swift; sourceTree = "<group>"; };
```
```
				AA00000100000000000000B6 /* CapabilityKind.swift */,
```
```
				AA00000200000000000000B6 /* CapabilityKind.swift in Sources */,
```

- [ ] **Step 6: Build + commit**

Run: `make app` → expect `✓`.
```bash
git add Otto/Otto/CapabilityKind.swift tests/swift/CapabilityKindTests.swift Makefile Otto/Otto.xcodeproj/project.pbxproj
git commit -m "feat: classify capability templates as parameterized vs simple"
```

---

## Task 11: Mic auto-start toggle in Settings

**Files:**
- Modify: `Otto/Otto/SettingsWindow.swift`

**Interfaces:**
- Consumes: `SettingsStore.micAutoStart` (Task 3).
- Produces: a Preferences toggle bound to `store.micAutoStart`.

- [ ] **Step 1: Add the toggle to preferencesSection**

In `Otto/Otto/SettingsWindow.swift`, inside `preferencesSection`'s inner `VStack` (after the three `labeledField`s, `:114`), add:

```swift
                Toggle("Start listening when Otto opens", isOn: $store.micAutoStart)
                    .toggleStyle(.switch)
                    .padding(.top, 6)
```

- [ ] **Step 2: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`.

- [ ] **Step 3: Commit**

```bash
git add Otto/Otto/SettingsWindow.swift
git commit -m "feat: add mic auto-start toggle to settings"
```

---

## Task 12: OrbView (circular waveform / mic / idle visual)

**Files:**
- Create: `Otto/Otto/OrbView.swift`
- Modify: `Makefile` SOURCES, `Otto/Otto.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `struct OrbView: View { init(listening: Bool, level: Float, micEnabled: Bool, onTap: @escaping () -> Void) }`. Consumed by Task 14.

- [ ] **Step 1: Create OrbView.swift**

Create `Otto/Otto/OrbView.swift`:

```swift
import SwiftUI

/// The circular palette orb: shows a radial waveform while listening, a mic glyph
/// when idle/disabled, and a subtle breathing pulse. Tapping toggles listening.
struct OrbView: View {
    let listening: Bool
    let level: Float
    let micEnabled: Bool
    var onTap: () -> Void

    private let diameter: CGFloat = 140

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)

            if listening {
                RadialWaveform(level: level)
                    .padding(26)
            } else {
                Image(systemName: micEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(listening ? 1.0 : 0.98)
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: listening)
        .contentShape(Circle())
        .onTapGesture { onTap() }
        .help(listening ? "Listening — tap to stop" : "Tap to talk")
    }
}

/// A ring of bars whose heights track the live mic level — the circular analog of WaveformView.
private struct RadialWaveform: View {
    let level: Float
    private let bars = 36
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let baseR = min(size.width, size.height) / 2 - 8
                for i in 0..<bars {
                    let angle = (Double(i) / Double(bars)) * 2 * .pi
                    // Animated, level-scaled bar length with a little per-bar variation.
                    let wobble = 0.5 + 0.5 * sin(phase * 2 + Double(i) * 0.5)
                    let len = 4 + CGFloat(level) * 22 * CGFloat(wobble)
                    let inner = CGPoint(x: c.x + cos(angle) * baseR, y: c.y + sin(angle) * baseR)
                    let outer = CGPoint(x: c.x + cos(angle) * (baseR + len), y: c.y + sin(angle) * (baseR + len))
                    var path = Path()
                    path.move(to: inner)
                    path.addLine(to: outer)
                    ctx.stroke(path, with: .color(.white.opacity(level > 0.05 ? 0.85 : 0.25)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
            }
            .onChange(of: timeline.date) { _, _ in phase += 0.08 }
        }
    }
}
```

- [ ] **Step 2: Register in Makefile SOURCES and pbxproj (IDs `...B4`)**

Append `Otto/Otto/OrbView.swift` to `SOURCES`. Add to `project.pbxproj`:
```
		AA00000200000000000000B4 /* OrbView.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA00000100000000000000B4 /* OrbView.swift */; };
```
```
		AA00000100000000000000B4 /* OrbView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OrbView.swift; sourceTree = "<group>"; };
```
```
				AA00000100000000000000B4 /* OrbView.swift */,
```
```
				AA00000200000000000000B4 /* OrbView.swift in Sources */,
```

- [ ] **Step 3: Build + commit**

Run: `make app` → expect `✓`.
```bash
git add Otto/Otto/OrbView.swift Makefile Otto/Otto.xcodeproj/project.pbxproj
git commit -m "feat: add circular OrbView with radial waveform"
```

---

## Task 13: CapabilityHalo (radial floating capabilities)

**Files:**
- Create: `Otto/Otto/CapabilityHalo.swift`
- Modify: `Makefile` SOURCES, `Otto/Otto.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `CapabilityKind` (Task 10).
- Produces:
  - `struct HaloItem: Identifiable, Equatable { let id: String; let label: String; let icon: String; let phrase: String; let isParameterized: Bool }`
  - `struct CapabilityHalo: View { init(items: [HaloItem], orbDiameter: CGFloat, onSelect: @escaping (HaloItem) -> Void) }`
  Consumed by Task 14.

- [ ] **Step 1: Create CapabilityHalo.swift**

Create `Otto/Otto/CapabilityHalo.swift`:

```swift
import SwiftUI

/// One floating capability chip around the orb.
struct HaloItem: Identifiable, Equatable {
    let id: String
    let label: String
    let icon: String
    let phrase: String          // text sent or pre-filled when tapped
    let isParameterized: Bool   // true → pre-fill input; false → run immediately
}

/// Lays out capability chips radially around the orb. Purely presentational —
/// the parent owns selection behavior.
struct CapabilityHalo: View {
    let items: [HaloItem]
    let orbDiameter: CGFloat
    var onSelect: (HaloItem) -> Void

    /// Distance from center to each chip's center.
    private var radius: CGFloat { orbDiameter / 2 + 64 }

    var body: some View {
        ZStack {
            ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { index, item in
                chip(item)
                    .offset(offset(for: index, of: min(items.count, 5)))
            }
        }
        // Canvas large enough to hold the orb + chips on all sides.
        .frame(width: radius * 2 + 140, height: radius * 2 + 80)
    }

    private func chip(_ item: HaloItem) -> some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 160)
    }

    /// Distribute chips evenly around the circle, starting at the top.
    private func offset(for index: Int, of count: Int) -> CGSize {
        guard count > 0 else { return .zero }
        let angle = -Double.pi / 2 + (Double(index) / Double(count)) * 2 * .pi
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}
```

- [ ] **Step 2: Register in Makefile SOURCES and pbxproj (IDs `...B5`)**

Append `Otto/Otto/CapabilityHalo.swift` to `SOURCES`. Add to `project.pbxproj`:
```
		AA00000200000000000000B5 /* CapabilityHalo.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA00000100000000000000B5 /* CapabilityHalo.swift */; };
```
```
		AA00000100000000000000B5 /* CapabilityHalo.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CapabilityHalo.swift; sourceTree = "<group>"; };
```
```
				AA00000100000000000000B5 /* CapabilityHalo.swift */,
```
```
				AA00000200000000000000B5 /* CapabilityHalo.swift in Sources */,
```

- [ ] **Step 3: Build + commit**

Run: `make app` → expect `✓`.
```bash
git add Otto/Otto/CapabilityHalo.swift Makefile Otto/Otto.xcodeproj/project.pbxproj
git commit -m "feat: add CapabilityHalo radial capability chips"
```

---

## Task 14: CommandPalette orb↔bar morph, tap-to-toggle mic, halo

**Files:**
- Modify: `Otto/Otto/CommandPalette.swift`

**Interfaces:**
- Consumes: `OrbView`, `CapabilityHalo`/`HaloItem`, `CapabilityKind`, `SettingsStore.micAutoStart`, existing `PythonBridge` API (`sendVoiceStart/Stop`, `sendText`, `micLevel`, `waveformActive`, `recentPhrases`, `journalCards`).
- Produces: the redesigned palette. Behavior gated by `inputText.isEmpty` (orb mode) vs non-empty (bar mode).

- [ ] **Step 1: Add orb-mode state + listening control**

In `Otto/Otto/CommandPalette.swift`, add state next to the existing `@State` declarations (`:35-38`):

```swift
    @State private var isListening = false
```

Add a computed flag after the state block:

```swift
    /// Orb mode when nothing has been typed; bar mode as soon as text exists.
    private var isOrbMode: Bool { inputText.isEmpty }
```

- [ ] **Step 2: Restructure body into orb vs bar**

Replace the top of `body` (`:40-76`, the outer `VStack { inputRow … suggestionSection }`) so orb mode renders the orb + halo and bar mode renders the existing stack. Replace the `VStack(spacing: 0) { … }` content with:

```swift
        Group {
            if isOrbMode {
                orbModeView
            } else {
                barModeView
            }
        }
```

Then add the two container views before `// MARK: - Input row`:

```swift
    // MARK: - Orb mode

    private var orbModeView: some View {
        ZStack {
            CapabilityHalo(items: haloItems, orbDiameter: 140, onSelect: handleHalo)
            OrbView(listening: isListening,
                    level: bridge.micLevel,
                    micEnabled: true,
                    onTap: toggleListening)
            // Invisible, focused field that captures the first keystroke to enter bar mode.
            TextField("", text: $inputText)
                .textFieldStyle(.plain)
                .focused($textFieldFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onSubmit { submitText() }
        }
        .padding(20)
    }

    // MARK: - Bar mode

    private var barModeView: some View {
        VStack(spacing: 0) {
            inputRow
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            if bridge.waveformActive || isListening {
                WaveformView(level: bridge.micLevel, active: bridge.waveformActive)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let error = bridge.lastError {
                errorRow(error)
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if !bridge.spokenText.isEmpty {
                resultRow
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let learned = bridge.learnedEvent {
                learnedChip(learned)
                    .padding(.horizontal, 20).padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if showSuggestions {
                suggestionSection
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: 640)
    }
```

- [ ] **Step 3: Move frame/background/animations to the outer Group**

The modifiers currently chained after the old `VStack` (`:77-109`) attach to the `Group`. Keep them, but remove the fixed `.frame(width: 640)` from the outer chain (bar mode sets its own width; orb mode is square) and add an animation on `isOrbMode`. The chain after `Group { … }` becomes:

```swift
        .animation(.spring(duration: 0.32, bounce: 0.12), value: isOrbMode)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.waveformActive)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.spokenText)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.lastError)
        .animation(.spring(duration: 0.28, bounce: 0.08), value: bridge.learnedEvent)
        .animation(.spring(duration: 0.22, bounce: 0.05), value: showSuggestions)
        .background { paletteBackground }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
        .padding(1)
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onAppear { textFieldFocused = true; startListeningIfEnabled() }
        .onReceive(NotificationCenter.default.publisher(for: .paletteDidShow)) { _ in
            inputText = ""
            selectedIndex = nil
            textFieldFocused = true
            bridge.requestJournal()
            bridge.requestSuggestions()
            startListeningIfEnabled()
        }
        .onChange(of: inputText) { selectedIndex = nil }
```

(Keep the two existing `.task(id:)` auto-clear blocks unchanged.)

- [ ] **Step 4: Replace hold-to-talk with tap-to-toggle in micButton**

Replace the `micButton`'s `.gesture(DragGesture…)` (`:181-194`) with a tap that toggles listening, and reflect `isListening`:

```swift
            .onTapGesture { toggleListening() }
            .help(isListening ? "Tap to stop" : "Tap to talk")
```

Also change the `micButton` visual to key off `isListening` instead of `isHoldingMic` (replace `isHoldingMic` references in `micButton`, `:170-179`, with `isListening`). Remove the now-unused `@State private var isHoldingMic` (`:36`).

- [ ] **Step 5: Add the listening + halo helpers**

Add to the `// MARK: - Actions` area:

```swift
    private func startListeningIfEnabled() {
        if SettingsStore.shared.micAutoStart && !isListening {
            isListening = true
            bridge.lastError = nil
            bridge.sendVoiceStart()
        }
    }

    private func toggleListening() {
        isListening.toggle()
        bridge.lastError = nil
        if isListening { bridge.sendVoiceStart() } else { bridge.sendVoiceStop() }
    }

    private func stopListening() {
        if isListening { isListening = false; bridge.sendVoiceStop() }
    }

    private func handleHalo(_ item: HaloItem) {
        if item.isParameterized {
            inputText = item.phrase            // enter bar mode for editing
            textFieldFocused = true
        } else {
            bridge.spokenText = ""
            bridge.lastError = nil
            bridge.sendText(item.phrase)
        }
    }

    /// Top relevant capabilities for the halo (v1: recent + most-used, reusing suggestion data).
    private var haloItems: [HaloItem] {
        let recent = bridge.recentPhrases.prefix(2).map { rp in
            HaloItem(id: "recent::\(rp.phrase)", label: rp.phrase,
                     icon: "clock.arrow.circlepath", phrase: rp.phrase, isParameterized: false)
        }
        let recentSet = Set(bridge.recentPhrases.map { $0.phrase.lowercased() })
        let caps = bridge.journalCards
            .filter { !recentSet.contains($0.description.lowercased()) }
            .sorted { $0.timesUsed != $1.timesUsed ? $0.timesUsed > $1.timesUsed : $0.confidence > $1.confidence }
            .prefix(5 - recent.count)
            .map { card in
                HaloItem(id: "cap::\(card.id)", label: card.description,
                         icon: Self.primitiveIcon(card.primitive), phrase: card.description,
                         isParameterized: CapabilityKind.isParameterized(template: card.template))
            }
        return Array(recent) + Array(caps)
    }
```

- [ ] **Step 6: Stop listening on submit and dismiss**

In `submitText()` (`:293-300`), after `bridge.sendText(text)`, add `stopListening()`. In `PaletteController.hide()` is AppKit, not the view — instead stop on the existing dismiss path: in the `.onKeyPress(.escape)` handler add `stopListening()` before `onDismiss()`. Update:

```swift
        .onKeyPress(.escape) { stopListening(); onDismiss(); return .handled }
```

And at the end of `submitText()`:

```swift
        bridge.sendText(text)
        inputText = ""
        stopListening()
```

- [ ] **Step 7: Build to verify**

Run: `make app`
Expected: `✓  Otto/build/Otto.app`. Resolve any unused-symbol warnings from the removed `isHoldingMic`.

- [ ] **Step 8: Manual acceptance**

Run `./run.sh --app`. Summon Otto:
- With mic auto-start ON (default): orb shows the radial waveform and is already listening; speaking runs a command.
- Toggle auto-start OFF in Settings, summon again: orb shows the mic glyph; tap to start listening.
- Start typing: the orb morphs into the 640pt bar with suggestions; clearing the field morphs back to the orb.
- 4–5 chips float around the orb. Click a simple one (e.g. "pause music") → runs; click a parameterized one (e.g. "open {app}") → pre-fills the input.

- [ ] **Step 9: Commit**

```bash
git add Otto/Otto/CommandPalette.swift
git commit -m "feat: circular orb palette with morph, tap-to-talk, and capability halo"
```

---

## Task 15: Full build + bundle regression check

**Files:** none (verification only)

- [ ] **Step 1: Run the Swift build test**

Run: `pip install -r requirements-dev.txt >/dev/null 2>&1; pytest tests/test_build.py -v`
Expected: PASS (the bundle compiles via swiftc with all new sources).

- [ ] **Step 2: Run all standalone Swift unit tests**

Run:
```bash
swiftc Otto/Otto/HotkeyConfig.swift tests/swift/HotkeyConfigTests.swift -framework Carbon -o /tmp/hk && /tmp/hk
swiftc Otto/Otto/UpdateChecker.swift tests/swift/UpdateCheckerTests.swift -o /tmp/uc && /tmp/uc
swiftc Otto/Otto/CapabilityKind.swift tests/swift/CapabilityKindTests.swift -o /tmp/ck && /tmp/ck
```
Expected: each prints `ok`.

- [ ] **Step 3: Run the existing Python suite (no regressions)**

Run: `pytest tests/test_retrospective.py tests/test_session_log.py tests/test_voice_agent.py -v`
Expected: PASS (Swift work shouldn't touch these; this confirms it).

- [ ] **Step 4: Final pkg build sanity**

Run: `make pkg && ls -la Otto/build/Otto.pkg`
Expected: pkg builds; `make` echoes the stamped version.

- [ ] **Step 5: Update docs**

In `CLAUDE.md`, under the SwiftUI app section, note the new files (`HotkeyConfig`, `HotkeyRecorderView`, `UpdateChecker`, `OrbView`, `CapabilityHalo`, `CapabilityKind`), the customizable hotkeys, the GitHub auto-updater, mic-auto-start setting, and the orb palette. Add the standalone `swiftc` Swift-test command and `tests/swift/` to the Tests block.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document orb palette, updater, and customizable shortcuts"
```

---

## Self-Review Notes

- **Spec coverage:** Phase 0 → Task 1; shortcuts (Phase 1) → Tasks 2–5; auto-update (Phase 2) → Tasks 6–9; mic auto-start (Phase 3) → Tasks 3/11/14; orb + halo (Phase 4) → Tasks 10/12/13/14. All five features plus version-stamping are covered.
- **Build registration:** every new-file task includes both Makefile `SOURCES` and `project.pbxproj` steps (Global Constraints).
- **Type consistency:** `HotkeyConfig`, `UpdateInfo`/`SemVer`/`UpdateChecker.Status`, `HaloItem`, `CapabilityKind.isParameterized`, `MenuBarController.setUpdateAvailable/onInstallUpdate`, and `AppDelegate.restartHotkeys/registerHotkeys` names are used consistently across producing and consuming tasks.
- **Deferred:** screen-aware halo relevance, signing/notarization, and Sparkle are out of scope per the spec.
