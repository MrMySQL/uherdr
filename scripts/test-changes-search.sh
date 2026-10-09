#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$PWD/.build/changes-search-tests"
mkdir -p "$TEST_BUILD"
swiftc -emit-library -emit-module -module-name HerdrCore Sources/HerdrCore/*.swift \
    -emit-module-path "$TEST_BUILD/HerdrCore.swiftmodule" -o "$TEST_BUILD/libHerdrCore.dylib"
swiftc -parse-as-library Sources/HerdrMac/MediaDecoder.swift Tests/HerdrMacTests/MediaDecoderTests.swift -o "$TEST_BUILD/media"
"$TEST_BUILD/media"
swiftc -parse-as-library -I "$TEST_BUILD" -L "$TEST_BUILD" -lHerdrCore \
    -Xlinker -rpath -Xlinker "$TEST_BUILD" Sources/HerdrMac/EditorStore.swift \
    Sources/HerdrMac/FileTreeModel.swift Tests/HerdrMacTests/FileTreeModelTests.swift -o "$TEST_BUILD/tree"
"$TEST_BUILD/tree"
# Compile the view's exact path helpers without bringing in the whole app.
python3 - "$TEST_BUILD/SelectionHelpers.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/HerdrMac/RightSidebarView.swift').read_text()
start = source.index('    static func changeTabID')
end = source.index('    private func openChange', start)
Path(sys.argv[1]).write_text('import Foundation\nimport HerdrCore\n@MainActor struct RightSidebarView {\n' + source[start:end] + '}\n')
PY
swiftc -parse-as-library -I "$TEST_BUILD" -L "$TEST_BUILD" -lHerdrCore \
    -Xlinker -rpath -Xlinker "$TEST_BUILD" Sources/HerdrMac/EditorStore.swift \
    "$TEST_BUILD/SelectionHelpers.swift" Tests/HerdrMacTests/ChangeSelectionTests.swift -o "$TEST_BUILD/selection"
"$TEST_BUILD/selection"
