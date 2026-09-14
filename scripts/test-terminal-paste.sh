#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
HERDR_TEST_BIN="${HERDR_BIN:-$(command -v herdr)}"
if [ "${HERDR_TEST_PASTE_AGENTS:-0}" = "1" ]; then
    command -v claude >/dev/null
    command -v codex >/dev/null
fi
TEST_ROOT="$(mktemp -d /tmp/hp.XXXXXX)"
TEST_SOCKET="$TEST_ROOT/config/herdr/sessions/native-client-test/herdr.sock"
cleanup() {
    env -u HERDR_SESSION HERDR_SOCKET_PATH="$TEST_SOCKET" "$HERDR_TEST_BIN" server stop >/dev/null 2>&1 || true
    if [ -n "${TEST_SERVER_PID:-}" ]; then wait "$TEST_SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/config" "$TEST_ROOT/state"
env -u HERDR_SOCKET_PATH -u HERDR_SESSION -u HERDR_CLIENT_SOCKET_PATH XDG_CONFIG_HOME="$TEST_ROOT/config" XDG_STATE_HOME="$TEST_ROOT/state" "$HERDR_TEST_BIN" --session native-client-test server > "$TEST_ROOT/server.log" 2>&1 &
TEST_SERVER_PID=$!
for _ in {1..100}; do
    [ -S "$TEST_SOCKET" ] && break
    sleep 0.1
done
if [ ! -S "$TEST_SOCKET" ]; then cat "$TEST_ROOT/server.log" >&2; exit 1; fi
HERDR_TEST_PASTE=1 bash scripts/test-terminal-keyboard.sh --live "$TEST_SOCKET" "$HERDR_TEST_BIN"
