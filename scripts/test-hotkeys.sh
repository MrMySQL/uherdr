#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -parse-as-library Sources/HerdrMac/ShortcutHintMonitor.swift Tests/HerdrMacTests/ShortcutHintMonitorTests.swift -o .build/ShortcutHintMonitorTests
.build/ShortcutHintMonitorTests
swiftc -parse-as-library Sources/HerdrMac/AppHotkeys.swift Tests/HerdrMacTests/AppHotkeyTests.swift -o .build/AppHotkeyTests
.build/AppHotkeyTests
swiftc -parse-as-library Sources/HerdrMac/ShortcutRecordingMonitor.swift Tests/HerdrMacTests/ShortcutRecordingTests.swift -o .build/ShortcutRecordingTests
.build/ShortcutRecordingTests
