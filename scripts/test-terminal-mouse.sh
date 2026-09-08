#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HERDR_TEST_BIN="${HERDR_BIN:-$(command -v herdr || true)}"
if [ -z "$HERDR_TEST_BIN" ]; then
    printf 'Install herdr or set HERDR_BIN to its executable.\n' >&2
    exit 1
fi
TEST_ROOT="$(mktemp -d /tmp/hn.XXXXXX)"
TEST_SOCKET="$TEST_ROOT/config/herdr/sessions/native-client-test/herdr.sock"
cleanup() {
    env -u HERDR_SESSION HERDR_SOCKET_PATH="$TEST_SOCKET" "$HERDR_TEST_BIN" server stop >/dev/null 2>&1 || true
    if [ -n "${TEST_SERVER_PID:-}" ]; then wait "$TEST_SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/state"
env -u HERDR_SOCKET_PATH -u HERDR_SESSION XDG_CONFIG_HOME="$TEST_ROOT/config" XDG_STATE_HOME="$TEST_ROOT/state" "$HERDR_TEST_BIN" --session native-client-test server > "$TEST_ROOT/server.log" 2>&1 &
TEST_SERVER_PID=$!
for _ in {1..50}; do
    [ -S "$TEST_SOCKET" ] && break
    sleep 0.1
done
if [ ! -S "$TEST_SOCKET" ]; then cat "$TEST_ROOT/server.log" >&2; exit 1; fi
python3 scripts/test-terminal-stream.py "$TEST_SOCKET" "$HERDR_TEST_BIN" --check-mouse-modes
HERDR_TEST_MOUSE=1 bash scripts/test-terminal-keyboard.sh --live "$TEST_SOCKET" "$HERDR_TEST_BIN"
