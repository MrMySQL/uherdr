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
    Tests/HerdrMacTests/TerminalKeyboardTests.swift "${KEYBOARD_OBJECTS[@]}" \
    -o "$KEYBOARD_BUILD_DIR/TerminalKeyboardTests"
"$KEYBOARD_BUILD_DIR/TerminalKeyboardTests"
