#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Test runners import app internals and replace its entry point. Release builds
# therefore need testable modules and separate objects, like benchmark-panes.sh.
swift build -c "${APP_TEST_CONFIGURATION:-debug}" --product Herdr \
    -Xswiftc -enable-testing -Xswiftc -no-whole-module-optimization
source scripts/app-test-link.sh
app_test_compile Tests/HerdrMacTests/PaneDragTests.swift -o "$APP_TEST_BUILD/PaneDragTests"
"$APP_TEST_BUILD/PaneDragTests" "$@"
