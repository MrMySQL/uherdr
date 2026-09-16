#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
source scripts/app-test-link.sh
APPEARANCE_BUILD_DIR="$APP_TEST_BUILD"
app_test_compile Tests/HerdrMacTests/AppearanceStoreTests.swift -o "$APP_TEST_BUILD/AppearanceStoreTests"
"$APP_TEST_BUILD/AppearanceStoreTests"
app_test_compile Tests/HerdrMacTests/TerminalAppearanceTests.swift -o "$APP_TEST_BUILD/TerminalAppearanceTests"
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
