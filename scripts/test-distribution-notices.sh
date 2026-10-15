#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-dist/uHerdr.app}"
# Verify the shipped bytes, not just the build script's intent.
cmp docs/licenses/swift-cmark-COPYING "$APP/Contents/Resources/swift-cmark-COPYING"
if [ -f .build/checkouts/swift-cmark/COPYING ]; then
    cmp .build/checkouts/swift-cmark/COPYING docs/licenses/swift-cmark-COPYING
fi
printf 'PASS: complete pinned swift-cmark notice is shipped unchanged\n'
for file in NOTICE.md SOURCES.md; do
    cmp "Sources/HerdrMac/Resources/AgentIcons/$file" "$APP/Contents/Resources/HerdrMac_HerdrMac.bundle/Contents/Resources/AgentIcons/$file"
done
printf 'PASS: agent mark attribution and source credits are shipped unchanged\n'
