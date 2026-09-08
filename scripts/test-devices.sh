#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HERDR_TEST_BIN="${HERDR_BIN:-$(command -v herdr || true)}"
if [ -z "$HERDR_TEST_BIN" ]; then
    printf 'Install herdr or set HERDR_BIN.\n' >&2
    exit 1
fi
TEST_ROOT="$(mktemp -d /tmp/uh-devices.XXXXXX)"
SOCKET_A="$TEST_ROOT/a/config/herdr/sessions/native-client-test/herdr.sock"
SOCKET_B="$TEST_ROOT/b/config/herdr/sessions/native-client-test/herdr.sock"
cleanup() {
    for test_socket in "$SOCKET_A" "$SOCKET_B"; do
        env -u HERDR_SESSION HERDR_SOCKET_PATH="$test_socket" "$HERDR_TEST_BIN" server stop >/dev/null 2>&1 || true
    done
    if [ -n "${PID_A:-}" ]; then wait "$PID_A" 2>/dev/null || true; fi
    if [ -n "${PID_B:-}" ]; then wait "$PID_B" 2>/dev/null || true; fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/a/config" "$TEST_ROOT/a/state" "$TEST_ROOT/b/config" "$TEST_ROOT/b/state"
env -u HERDR_SOCKET_PATH -u HERDR_SESSION XDG_CONFIG_HOME="$TEST_ROOT/a/config" XDG_STATE_HOME="$TEST_ROOT/a/state" "$HERDR_TEST_BIN" --session native-client-test server > "$TEST_ROOT/a.log" 2>&1 &
PID_A=$!
env -u HERDR_SOCKET_PATH -u HERDR_SESSION XDG_CONFIG_HOME="$TEST_ROOT/b/config" XDG_STATE_HOME="$TEST_ROOT/b/state" "$HERDR_TEST_BIN" --session native-client-test server > "$TEST_ROOT/b.log" 2>&1 &
PID_B=$!
for _ in {1..80}; do
    if [ -S "$SOCKET_A" ] && [ -S "$SOCKET_B" ]; then break; fi
    sleep 0.1
done
test -S "$SOCKET_A"
test -S "$SOCKET_B"
swift build --target HerdrCore
swiftc -parse-as-library -I .build/debug/Modules Sources/HerdrMac/SessionStore.swift Sources/HerdrMac/DeviceStore.swift Tests/HerdrMacTests/DeviceStoreTests.swift .build/debug/HerdrCore.build/*.o -o .build/DeviceStoreTests
.build/DeviceStoreTests "$SOCKET_A" "$SOCKET_B" "$HERDR_TEST_BIN"
