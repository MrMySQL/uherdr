#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swiftc -parse-as-library Sources/HerdrMac/PaneSearchMatches.swift Tests/HerdrMacTests/PaneSearchTests.swift -o .build/PaneSearchTests
.build/PaneSearchTests
