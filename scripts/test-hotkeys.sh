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

TEST_BUILD="$PWD/.build/navigation-tests"
mkdir -p "$TEST_BUILD"
swiftc -emit-library -emit-module -module-name HerdrCore Sources/HerdrCore/*.swift \
    -emit-module-path "$TEST_BUILD/HerdrCore.swiftmodule" -o "$TEST_BUILD/libHerdrCore.dylib"
swiftc -parse-as-library -I "$TEST_BUILD" -L "$TEST_BUILD" -lHerdrCore \
    -Xlinker -rpath -Xlinker "$TEST_BUILD" \
    Sources/HerdrMac/SessionStore.swift Sources/HerdrMac/EditorStore.swift Sources/HerdrMac/VisibleTabNavigation.swift \
    Tests/HerdrMacTests/VisibleTabNavigationTests.swift -o "$TEST_BUILD/VisibleTabNavigationTests"
"$TEST_BUILD/VisibleTabNavigationTests"
