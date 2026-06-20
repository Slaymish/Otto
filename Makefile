# Build Otto.app using only Xcode Command Line Tools (no full Xcode needed).
# Install CLT:  xcode-select --install
#
#   make app     — compile + bundle + sign → Otto/build/Otto.app
#   make clean   — remove build output

ARCH        := $(shell uname -m)
SDK         := $(shell xcrun --show-sdk-path 2>/dev/null)
SDK_MAJOR   := $(shell xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)
TARGET      := $(ARCH)-apple-macos14.0
# Pass -D HAS_MACOS26_SDK when the active SDK is macOS 26+ so glassEffect compiles.
SDK_FLAGS   := $(shell [ "$(SDK_MAJOR)" -ge 26 ] 2>/dev/null && echo "-D HAS_MACOS26_SDK")

SOURCES := \
	Otto/Otto/OttoApp.swift        \
	Otto/Otto/CommandPalette.swift \
	Otto/Otto/HotkeyManager.swift  \
	Otto/Otto/PythonBridge.swift   \
	Otto/Otto/WaveformView.swift   \
	Otto/Otto/JournalWindow.swift  \
	Otto/Otto/SettingsStore.swift  \
	Otto/Otto/SetupEngine.swift    \
	Otto/Otto/OnboardingView.swift

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
	    $(SDK_FLAGS) \
	    -O \
	    -o "$@"

# Substitute Xcode build-setting placeholders with literal values.
$(PLIST_DST): $(PLIST_SRC) | $(APP)/Contents
	sed \
	    -e 's/$$(EXECUTABLE_NAME)/Otto/g' \
	    -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/com.otto.app/g' \
	    -e 's/$$(PRODUCT_NAME)/Otto/g' \
	    "$<" > "$@"

$(ICON_DST): $(ICON_SRC) | $(APP)/Contents/Resources
	cp "$<" "$@"

$(APP)/Contents/MacOS $(APP)/Contents $(APP)/Contents/Resources:
	mkdir -p "$@"

clean:
	rm -rf Otto/build/Otto.app
