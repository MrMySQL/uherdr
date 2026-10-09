#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/Herdr.app}"
# Verify the shipped bytes, not just the build script's intent.
cmp docs/licenses/swift-cmark-COPYING "$APP/Contents/Resources/swift-cmark-COPYING"
if [ -f .build/checkouts/swift-cmark/COPYING ]; then
    cmp .build/checkouts/swift-cmark/COPYING docs/licenses/swift-cmark-COPYING
fi
printf 'PASS: complete pinned swift-cmark notice is shipped unchanged\n'
