# Build Otto.app using only Xcode Command Line Tools (no full Xcode needed).
# Install CLT:  xcode-select --install
#
#   make app     — compile + bundle + sign → Otto/build/Otto.app
#   make clean   — remove build output

ARCH   := $(shell uname -m)
SDK    := $(shell xcrun --show-sdk-path 2>/dev/null)
TARGET := $(ARCH)-apple-macos14.0

SOURCES := \
	Otto/Otto/OttoApp.swift        \
	Otto/Otto/CommandPalette.swift \
	Otto/Otto/HotkeyManager.swift  \
	Otto/Otto/PythonBridge.swift   \
	Otto/Otto/WaveformView.swift

APP       := Otto/build/Otto.app
BINARY    := $(APP)/Contents/MacOS/Otto
PLIST_SRC := Otto/Otto/Info.plist
PLIST_DST := $(APP)/Contents/Info.plist
ENTITLE   := Otto/Otto/Otto.entitlements

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
	    -e 's/$$(EXECUTABLE_NAME)/Otto/g' \
	    -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/com.otto.app/g' \
	    -e 's/$$(PRODUCT_NAME)/Otto/g' \
	    "$<" > "$@"

$(APP)/Contents/MacOS $(APP)/Contents:
	mkdir -p "$@"

clean:
	rm -rf Otto/build/Otto.app
