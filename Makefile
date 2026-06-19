# Build VoiceOS.app using only Xcode Command Line Tools (no full Xcode needed).
# Install CLT:  xcode-select --install
#
#   make app     — compile + bundle + sign → VoiceOS/build/VoiceOS.app
#   make clean   — remove build output

ARCH   := $(shell uname -m)
SDK    := $(shell xcrun --show-sdk-path 2>/dev/null)
TARGET := $(ARCH)-apple-macos14.0

SOURCES := \
	VoiceOS/VoiceOS/VoiceOSApp.swift    \
	VoiceOS/VoiceOS/CommandPalette.swift \
	VoiceOS/VoiceOS/HotkeyManager.swift  \
	VoiceOS/VoiceOS/PythonBridge.swift   \
	VoiceOS/VoiceOS/WaveformView.swift

APP       := VoiceOS/build/VoiceOS.app
BINARY    := $(APP)/Contents/MacOS/VoiceOS
PLIST_SRC := VoiceOS/VoiceOS/Info.plist
PLIST_DST := $(APP)/Contents/Info.plist
ENTITLE   := VoiceOS/VoiceOS/VoiceOS.entitlements

.PHONY: app clean

app: $(BINARY) $(PLIST_DST)
	codesign --force --sign - --entitlements "$(ENTITLE)" "$(APP)"
	@echo "✓  $(APP)"

$(BINARY): $(SOURCES) | $(APP)/Contents/MacOS
	swiftc $(SOURCES) \
	    -sdk "$(SDK)" \
	    -target "$(TARGET)" \
	    -framework Carbon \
	    -O \
	    -o "$@"

# Substitute Xcode build-setting placeholders with literal values.
$(PLIST_DST): $(PLIST_SRC) | $(APP)/Contents
	sed \
	    -e 's/$$(EXECUTABLE_NAME)/VoiceOS/g' \
	    -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/com.voiceos.app/g' \
	    -e 's/$$(PRODUCT_NAME)/VoiceOS/g' \
	    "$<" > "$@"

$(APP)/Contents/MacOS $(APP)/Contents:
	mkdir -p "$@"

clean:
	rm -rf VoiceOS/build/VoiceOS.app
