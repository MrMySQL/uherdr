#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$PWD/.build/editor-store-tests"
mkdir -p "$TEST_BUILD"
swiftc -emit-library -emit-module -module-name HerdrCore Sources/HerdrCore/*.swift \
    -emit-module-path "$TEST_BUILD/HerdrCore.swiftmodule" -o "$TEST_BUILD/libHerdrCore.dylib"
# Each entry is test-suite:sources-under-test (joined by +).
for suite in EditorStoreTests:EditorStore EditorEditingTests:EditorStore ChangesModelTests:ChangesModel SearchModelTests:SearchModel+QuickOpenModel; do
    name="${suite%%:*}"
    source="${suite#*:}"
    swiftc -parse-as-library -I "$TEST_BUILD" -L "$TEST_BUILD" -lHerdrCore \
        -Xlinker -rpath -Xlinker "$TEST_BUILD" \
        $(for file in ${source//+/ }; do echo "Sources/HerdrMac/$file.swift"; done) "Tests/HerdrMacTests/$name.swift" \
        -o "$TEST_BUILD/$name"
    "$TEST_BUILD/$name"
done
