#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -parse-as-library Sources/HerdrMac/CommandKeyMonitor.swift Tests/HerdrMacTests/CommandKeyMonitorTests.swift -o .build/CommandKeyMonitorTests
.build/CommandKeyMonitorTests
swiftc -parse-as-library Sources/HerdrMac/AppHotkeys.swift Tests/HerdrMacTests/AppHotkeyTests.swift -o .build/AppHotkeyTests
.build/AppHotkeyTests
