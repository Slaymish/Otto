# Build Otto.app using only Xcode Command Line Tools (no full Xcode needed).
# Install CLT:  xcode-select --install
#
#   make app     — compile + bundle resources + sign → Otto/build/Otto.app
#   make pkg     — make app, then wrap as Otto/build/Otto.pkg installer
#   make clean   — remove build output

ARCH        := $(shell uname -m)
SDK         := $(shell xcrun --show-sdk-path 2>/dev/null)
SDK_MAJOR   := $(shell xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)
TARGET      := $(ARCH)-apple-macos14.0
# Pass -D HAS_MACOS26_SDK when the active SDK is macOS 26+ so glassEffect compiles.
SDK_FLAGS   := $(shell [ "$(SDK_MAJOR)" -ge 26 ] 2>/dev/null && echo "-D HAS_MACOS26_SDK")

# Version: latest reachable git tag (e.g. v0.0.5) → 0.0.5 for plist fields.
# Override with `make app VERSION=v0.0.6`.
VERSION        := $(shell git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)
VERSION_NUMBER := $(patsubst v%,%,$(VERSION))

SOURCES := \
	Otto/Otto/OttoApp.swift        \
	Otto/Otto/CommandPalette.swift \
	Otto/Otto/HotkeyManager.swift  \
	Otto/Otto/MenuBarController.swift \
	Otto/Otto/OttoBridge.swift     \
	Otto/Otto/AudioEngine.swift    \
	Otto/Otto/ActionEngine.swift   \
	Otto/Otto/OttoEngine.swift     \
	Otto/Otto/WaveformView.swift   \
	Otto/Otto/JournalWindow.swift  \
	Otto/Otto/SettingsStore.swift  \
	Otto/Otto/SettingsWindow.swift \
	Otto/Otto/OnboardingView.swift \
	Otto/Otto/HotkeyConfig.swift   \
	Otto/Otto/HotkeyRecorderView.swift \
	Otto/Otto/UpdateChecker.swift  \
	Otto/Otto/CapabilityKind.swift \
	Otto/Otto/OrbView.swift        \
	Otto/Otto/CapabilityHalo.swift

APP       := Otto/build/Otto.app
BINARY    := $(APP)/Contents/MacOS/Otto
PLIST_SRC := Otto/Otto/Info.plist
PLIST_DST := $(APP)/Contents/Info.plist
ENTITLE   := Otto/Otto/Otto.entitlements
ICON_SRC  := Otto/Otto/AppIcon.icns
ICON_DST  := $(APP)/Contents/Resources/AppIcon.icns

.PHONY: app bundle-resources pkg clean

app: $(BINARY) $(PLIST_DST) $(ICON_DST) bundle-resources
	codesign --force --sign - --entitlements "$(ENTITLE)" "$(APP)"
	@echo "✓  $(APP)"

$(BINARY): $(SOURCES) | $(APP)/Contents/MacOS
	swiftc $(SOURCES) \
	    -sdk "$(SDK)" \
	    -target "$(TARGET)" \
	    -framework Carbon \
	    -framework ServiceManagement \
	    -framework AVFoundation \
	    $(SDK_FLAGS) \
	    -O \
	    -o "$@"

# Substitute Xcode build-setting placeholders with literal values.
$(PLIST_DST): $(PLIST_SRC) | $(APP)/Contents
	sed \
	    -e 's/$$(EXECUTABLE_NAME)/Otto/g' \
	    -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/com.otto.app/g' \
	    -e 's/$$(PRODUCT_NAME)/Otto/g' \
	    -e 's/$$(MARKETING_VERSION)/$(VERSION_NUMBER)/g' \
	    -e 's/$$(CURRENT_PROJECT_VERSION)/$(VERSION_NUMBER)/g' \
	    "$<" > "$@"

$(ICON_DST): $(ICON_SRC) | $(APP)/Contents/Resources
	cp "$<" "$@"

$(APP)/Contents/MacOS $(APP)/Contents $(APP)/Contents/Resources:
	mkdir -p "$@"

# Copy read-only capabilities into the bundle.
# Write-path data (user caps, sessions) goes to ~/Library/Application Support/Otto at runtime.
bundle-resources: | $(APP)/Contents/Resources
	rm -rf "$(APP)/Contents/Resources/memory"
	mkdir -p "$(APP)/Contents/Resources/memory"
	cp memory/capabilities.json "$(APP)/Contents/Resources/memory/capabilities.json"

# Create an installer PKG that drops Otto.app into /Applications.
# In CI, rename the output to Otto-<tag>.pkg before uploading.
pkg: app
	pkgbuild \
	    --component "$(APP)" \
	    --install-location /Applications \
	    --version "$(VERSION_NUMBER)" \
	    "Otto/build/Otto.pkg"
	@echo "✓  Otto/build/Otto.pkg ($(VERSION_NUMBER))"

clean:
	rm -rf Otto/build/
