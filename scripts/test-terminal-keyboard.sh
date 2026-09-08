#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
KEYBOARD_BUILD_DIR="$(swift build --show-bin-path)"
# Link the actual app implementation without its @main entry point.
KEYBOARD_OBJECTS=()
while IFS= read -r object; do
    case "$object" in
        */HerdrApp.swift.o) ;;
        *) KEYBOARD_OBJECTS+=("$object") ;;
    esac
done < "$KEYBOARD_BUILD_DIR/Herdr.product/Objects.LinkFileList"
swiftc -parse-as-library -I "$KEYBOARD_BUILD_DIR/Modules" \
    -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
    -L "$KEYBOARD_BUILD_DIR" -lghostty -lc++ -framework Carbon \
    Tests/HerdrMacTests/TerminalKeyboardTests.swift Tests/HerdrMacTests/GhosttyLiveTests.swift "${KEYBOARD_OBJECTS[@]}" \
    -o "$KEYBOARD_BUILD_DIR/TerminalKeyboardTests"
"$KEYBOARD_BUILD_DIR/TerminalKeyboardTests" "$@"
PROBE_ROOT="$(mktemp -d /tmp/herdr-ghostty-resources.XXXXXX)"
trap 'rm -rf "$PROBE_ROOT"' EXIT
PROBE_APP="$PROBE_ROOT/ResourceProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_APP/Contents/Resources"
cp "$KEYBOARD_BUILD_DIR/TerminalKeyboardTests" "$PROBE_APP/Contents/MacOS/"
cp Tests/HerdrMacTests/ResourceProbe-Info.plist "$PROBE_APP/Contents/Info.plist"
cp -R "$KEYBOARD_BUILD_DIR/GhosttyKit_GhosttyTerminal.bundle" "$PROBE_APP/Contents/Resources/"
"$PROBE_APP/Contents/MacOS/TerminalKeyboardTests" --bundled-resources
