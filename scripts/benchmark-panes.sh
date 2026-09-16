#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
PERF_HERDR="${HERDR_BIN:-$(command -v herdr)}"
PERF_ROOT="$(mktemp -d /tmp/hp.XXXXXX)"
PERF_SOCKET="$PERF_ROOT/config/herdr/sessions/native-client-test/herdr.sock"
cleanup() {
    env -u HERDR_SESSION HERDR_SOCKET_PATH="$PERF_SOCKET" "$PERF_HERDR" server stop >/dev/null 2>&1 || true
    if [ -n "${PERF_SERVER_PID:-}" ]; then wait "$PERF_SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$PERF_ROOT"
}
trap cleanup EXIT
# Separate objects let the harness replace the app's @main entry point.
swift build -c release --product Herdr -Xswiftc -enable-testing -Xswiftc -no-whole-module-optimization
APP_TEST_CONFIGURATION=release
source scripts/app-test-link.sh
PERF_BUILD="$APP_TEST_BUILD"
app_test_compile -O Tests/HerdrMacTests/PanePerformanceTests.swift -o "$PERF_BUILD/PanePerformanceTests"
mkdir -p "$PERF_ROOT/config" "$PERF_ROOT/state"
env -u HERDR_SOCKET_PATH -u HERDR_SESSION XDG_CONFIG_HOME="$PERF_ROOT/config" XDG_STATE_HOME="$PERF_ROOT/state" \
    "$PERF_HERDR" --session native-client-test server > "$PERF_ROOT/server.log" 2>&1 &
PERF_SERVER_PID=$!
for _ in {1..50}; do
    [ -S "$PERF_SOCKET" ] && break
    sleep 0.1
done
if [ ! -S "$PERF_SOCKET" ]; then cat "$PERF_ROOT/server.log" >&2; exit 1; fi
"$PERF_BUILD/PanePerformanceTests" "$PERF_SOCKET" "$PERF_HERDR"
