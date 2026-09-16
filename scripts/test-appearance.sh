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
swiftc -parse-as-library -I "$APPEARANCE_BUILD_DIR/Modules" -I "$APPEARANCE_BUILD_DIR" -I "$APPEARANCE_APP_MODULE_DIR" \
    -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
    -L "$APPEARANCE_BUILD_DIR" -lghostty -lc++ -framework Carbon \
    Tests/HerdrMacTests/TerminalAppearanceTests.swift "${APPEARANCE_OBJECTS[@]}" \
    -o "$APPEARANCE_BUILD_DIR/TerminalAppearanceTests"
APPEARANCE_HERDR="${HERDR_BIN:-$(command -v herdr || true)}"
if [ -z "$APPEARANCE_HERDR" ]; then
    printf 'Install herdr or set HERDR_BIN for mounted appearance tests.\n' >&2
    exit 1
fi
APPEARANCE_ROOT="$(mktemp -d /tmp/ha.XXXXXX)"
APPEARANCE_SOCKET="$APPEARANCE_ROOT/config/herdr/sessions/native-client-test/herdr.sock"
cleanup() {
    env -u HERDR_SESSION HERDR_SOCKET_PATH="$APPEARANCE_SOCKET" "$APPEARANCE_HERDR" server stop >/dev/null 2>&1 || true
    if [ -n "${APPEARANCE_SERVER_PID:-}" ]; then wait "$APPEARANCE_SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$APPEARANCE_ROOT"
}
trap cleanup EXIT
mkdir -p "$APPEARANCE_ROOT/config" "$APPEARANCE_ROOT/state"
env -u HERDR_SOCKET_PATH -u HERDR_SESSION XDG_CONFIG_HOME="$APPEARANCE_ROOT/config" XDG_STATE_HOME="$APPEARANCE_ROOT/state" "$APPEARANCE_HERDR" --session native-client-test server > "$APPEARANCE_ROOT/server.log" 2>&1 &
APPEARANCE_SERVER_PID=$!
for _ in {1..50}; do
    [ -S "$APPEARANCE_SOCKET" ] && break
    sleep 0.1
done
if [ ! -S "$APPEARANCE_SOCKET" ]; then cat "$APPEARANCE_ROOT/server.log" >&2; exit 1; fi
"$APPEARANCE_BUILD_DIR/TerminalAppearanceTests" "$APPEARANCE_SOCKET" "$APPEARANCE_HERDR"
