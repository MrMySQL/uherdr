#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
source scripts/app-test-link.sh
app_test_compile Tests/HerdrMacTests/AgentWorktreeTests.swift -o "$APP_TEST_BUILD/AgentWorktreeTests"
"$APP_TEST_BUILD/AgentWorktreeTests" "$@"
