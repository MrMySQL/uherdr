#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
PERFORMANCE_BUILD="$(swift build --show-bin-path)"
swiftc -parse-as-library -I "$PERFORMANCE_BUILD/Modules" \
    Sources/HerdrMac/SessionStore.swift Tests/HerdrMacTests/SessionPublicationTests.swift \
    "$PERFORMANCE_BUILD"/HerdrCore.build/*.swift.o -o "$PERFORMANCE_BUILD/SessionPublicationTests"
"$PERFORMANCE_BUILD/SessionPublicationTests"
PERFORMANCE_OBJECTS=()
while IFS= read -r object; do
    case "$object" in
        */HerdrApp.swift.o) ;;
        *) PERFORMANCE_OBJECTS+=("$object") ;;
    esac
done < "$PERFORMANCE_BUILD/Herdr.product/Objects.LinkFileList"
swiftc -parse-as-library -I "$PERFORMANCE_BUILD/Modules" \
    -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
    -L "$PERFORMANCE_BUILD" -lghostty -lc++ -framework Carbon \
    Tests/HerdrMacTests/TerminalPerformanceTests.swift "${PERFORMANCE_OBJECTS[@]}" \
    -o "$PERFORMANCE_BUILD/TerminalPerformanceTests"
if [ "$#" -eq 3 ] && [ "$1" = "--live" ]; then
    "$PERFORMANCE_BUILD/TerminalPerformanceTests" "$2" "$3"
elif [ "$#" -eq 0 ]; then
    "$PERFORMANCE_BUILD/TerminalPerformanceTests"
else
    printf 'Usage: %s [--live disposable-socket herdr-executable]\n' "$0" >&2
    exit 2
fi
