#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
PERFORMANCE_BUILD="$(swift build --show-bin-path)"
PERFORMANCE_LINK_FILE="${PERFORMANCE_BUILD}/Herdr.product/Objects.LinkFileList"
if [ ! -f "${PERFORMANCE_LINK_FILE}" ]; then
    PERFORMANCE_LINK_FILE="$(find .build -path '*/Herdr-p.build/Objects-normal/*/Herdr.LinkFileList' -print -quit)"
fi
PERFORMANCE_APP_MODULE_DIR="$(dirname "${PERFORMANCE_LINK_FILE}")"
if [ ! -f "${PERFORMANCE_LINK_FILE}" ]; then
    printf 'Could not locate the Herdr app object link list.\n' >&2
    exit 1
fi
PERFORMANCE_OBJECTS=()
while IFS= read -r object || [ -n "$object" ]; do
    [ -n "$object" ] || continue
    case "$object" in
        */HerdrApp.swift.o|*/HerdrApp.o) ;;
        *) PERFORMANCE_OBJECTS+=("$object") ;;
    esac
done < <(tr ' ' '\n' < "${PERFORMANCE_LINK_FILE}")
PERFORMANCE_CORE_OBJECTS=()
for object in "${PERFORMANCE_OBJECTS[@]}"; do
    case "$object" in */HerdrCore.build/*|*/HerdrCore.o) PERFORMANCE_CORE_OBJECTS+=("$object") ;; esac
done
swiftc -parse-as-library -I "$PERFORMANCE_BUILD/Modules" -I "$PERFORMANCE_BUILD" \
    Sources/HerdrMac/Appearance/AppearanceStore.swift Sources/HerdrMac/SessionStore.swift Tests/HerdrMacTests/SessionPublicationTests.swift \
    "${PERFORMANCE_CORE_OBJECTS[@]}" -o "$PERFORMANCE_BUILD/SessionPublicationTests"
"$PERFORMANCE_BUILD/SessionPublicationTests"
swiftc -parse-as-library -I "$PERFORMANCE_BUILD/Modules" -I "$PERFORMANCE_BUILD" -I "${PERFORMANCE_APP_MODULE_DIR}" \
    -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
    -L "$PERFORMANCE_BUILD" -lghostty -lc++ -framework Carbon \
    Tests/HerdrMacTests/TerminalPerformanceTests.swift Tests/HerdrMacTests/TerminalRepaintTests.swift "${PERFORMANCE_OBJECTS[@]}" \
    -o "$PERFORMANCE_BUILD/TerminalPerformanceTests"
if [ "$#" -eq 3 ] && [ "$1" = "--live" ]; then
    "$PERFORMANCE_BUILD/TerminalPerformanceTests" "$2" "$3"
elif [ "$#" -eq 0 ]; then
    "$PERFORMANCE_BUILD/TerminalPerformanceTests"
else
    printf 'Usage: %s [--live disposable-socket herdr-executable]\n' "$0" >&2
    exit 2
fi
