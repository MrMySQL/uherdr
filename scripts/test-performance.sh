#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
source scripts/app-test-link.sh
PERFORMANCE_BUILD="$APP_TEST_BUILD"
app_test_compile Tests/HerdrMacTests/SessionPublicationTests.swift -o "$APP_TEST_BUILD/SessionPublicationTests"
"$APP_TEST_BUILD/SessionPublicationTests"
app_test_compile Tests/HerdrMacTests/TerminalPerformanceTests.swift Tests/HerdrMacTests/TerminalRepaintTests.swift -o "$APP_TEST_BUILD/TerminalPerformanceTests"
if [ "$#" -eq 3 ] && [ "$1" = "--live" ]; then
    "$PERFORMANCE_BUILD/TerminalPerformanceTests" "$2" "$3"
elif [ "$#" -eq 0 ]; then
    "$PERFORMANCE_BUILD/TerminalPerformanceTests"
else
    printf 'Usage: %s [--live disposable-socket herdr-executable]\n' "$0" >&2
    exit 2
fi
