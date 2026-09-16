#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
APPEARANCE_BUILD_DIR="$(swift build --show-bin-path)"
APPEARANCE_LINK_FILE="$APPEARANCE_BUILD_DIR/Herdr.product/Objects.LinkFileList"
if [ ! -f "$APPEARANCE_LINK_FILE" ]; then
    APPEARANCE_LINK_FILE="$(find .build -path '*/Herdr-p.build/Objects-normal/*/Herdr.LinkFileList' -print -quit)"
fi
APPEARANCE_APP_MODULE_DIR="$(dirname "$APPEARANCE_LINK_FILE")"
if [ ! -f "$APPEARANCE_LINK_FILE" ]; then
    printf 'Could not locate the Herdr app object link list.\n' >&2
    exit 1
fi
APPEARANCE_OBJECTS=()
while IFS= read -r object || [ -n "$object" ]; do
    [ -n "$object" ] || continue
    case "$object" in
        */HerdrApp.swift.o|*/HerdrApp.o) ;;
        *) APPEARANCE_OBJECTS+=("$object") ;;
    esac
done < <(tr ' ' '\n' < "$APPEARANCE_LINK_FILE")
swiftc -parse-as-library -I "$APPEARANCE_BUILD_DIR/Modules" -I "$APPEARANCE_BUILD_DIR" -I "$APPEARANCE_APP_MODULE_DIR" \
    -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
    -L "$APPEARANCE_BUILD_DIR" -lghostty -lc++ -framework Carbon \
    Tests/HerdrMacTests/AppearanceStoreTests.swift "${APPEARANCE_OBJECTS[@]}" \
    -o "$APPEARANCE_BUILD_DIR/AppearanceStoreTests"
"$APPEARANCE_BUILD_DIR/AppearanceStoreTests"
