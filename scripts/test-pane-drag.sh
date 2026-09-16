#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
source scripts/app-test-link.sh
app_test_compile Tests/HerdrMacTests/PaneDragTests.swift -o "$APP_TEST_BUILD/PaneDragTests"
"$APP_TEST_BUILD/PaneDragTests" "$@"
