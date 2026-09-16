#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
source scripts/app-test-link.sh
KEYBOARD_BUILD_DIR="$APP_TEST_BUILD"
app_test_compile Tests/HerdrMacTests/TerminalKeyboardTests.swift Tests/HerdrMacTests/GhosttyLiveTests.swift Tests/HerdrMacTests/AgentFileDropTests.swift -o "$KEYBOARD_BUILD_DIR/TerminalKeyboardTests"
"$KEYBOARD_BUILD_DIR/TerminalKeyboardTests" "$@"
PROBE_ROOT="$(mktemp -d /tmp/herdr-ghostty-resources.XXXXXX)"
trap 'rm -rf "$PROBE_ROOT"' EXIT
PROBE_APP="$PROBE_ROOT/ResourceProbe.app"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_APP/Contents/Resources"
cp "$KEYBOARD_BUILD_DIR/TerminalKeyboardTests" "$PROBE_APP/Contents/MacOS/"
cp Tests/HerdrMacTests/ResourceProbe-Info.plist "$PROBE_APP/Contents/Info.plist"
cp -R "$KEYBOARD_BUILD_DIR/GhosttyKit_GhosttyTerminal.bundle" "$PROBE_APP/Contents/Resources/"
"$PROBE_APP/Contents/MacOS/TerminalKeyboardTests" --bundled-resources
