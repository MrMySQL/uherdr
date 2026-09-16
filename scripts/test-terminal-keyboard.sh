#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
KEYBOARD_BUILD_DIR="$(swift build --show-bin-path)"
# Link the actual app implementation without its @main entry point.
KEYBOARD_LINK_FILE="${KEYBOARD_BUILD_DIR}/Herdr.product/Objects.LinkFileList"
if [ ! -f "${KEYBOARD_LINK_FILE}" ]; then
    KEYBOARD_LINK_FILE="$(find .build -path '*/Herdr-p.build/Objects-normal/*/Herdr.LinkFileList' -print -quit)"
fi
KEYBOARD_APP_MODULE_DIR="$(dirname "${KEYBOARD_LINK_FILE}")"
if [ ! -f "${KEYBOARD_LINK_FILE}" ]; then
    printf 'Could not locate the Herdr app object link list.\n' >&2
    exit 1
fi
KEYBOARD_OBJECTS=()
while IFS= read -r object || [ -n "$object" ]; do
    [ -n "$object" ] || continue
    case "$object" in
        */HerdrApp.swift.o|*/HerdrApp.o) ;;
        *) KEYBOARD_OBJECTS+=("$object") ;;
    esac
done < <(tr ' ' '\n' < "${KEYBOARD_LINK_FILE}")
swiftc -parse-as-library -I "$KEYBOARD_BUILD_DIR/Modules" -I "$KEYBOARD_BUILD_DIR" -I "${KEYBOARD_APP_MODULE_DIR}" \
    -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
    -L "$KEYBOARD_BUILD_DIR" -lghostty -lc++ -framework Carbon \
    Tests/HerdrMacTests/TerminalKeyboardTests.swift Tests/HerdrMacTests/GhosttyLiveTests.swift Tests/HerdrMacTests/AgentFileDropTests.swift "${KEYBOARD_OBJECTS[@]}" \
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
