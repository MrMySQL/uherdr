#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPOSITORY_ROOT/scripts/app-test-link.sh"
FIXTURE_ROOT="$(mktemp -d /tmp/herdr-link-fixtures.XXXXXX)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

assert_objects() {
    local label="$1"
    shift
    if [ "${#APP_TEST_OBJECTS[@]}" -ne "$#" ]; then
        printf '%s: expected %d objects, got %d:\n' "$label" "$#" "${#APP_TEST_OBJECTS[@]}" >&2
        printf '  <%s>\n' "${APP_TEST_OBJECTS[@]}" >&2
        return 1
    fi
    local index=0
    local expected
    for expected in "$@"; do
        if [ "${APP_TEST_OBJECTS[$index]}" != "$expected" ]; then
            printf '%s: object %d expected <%s>, got <%s>\n' \
                "$label" "$index" "$expected" "${APP_TEST_OBJECTS[$index]}" >&2
            return 1
        fi
        index=$((index + 1))
    done
}

FIXTURE_BIN_PATH="$FIXTURE_ROOT/Modern Products"
swift() { printf '%s\n' "$FIXTURE_BIN_PATH"; }
mkdir -p "$FIXTURE_BIN_PATH/Herdr.product"
cp "$REPOSITORY_ROOT/Tests/Fixtures/app-test-link-swiftpm.txt" \
    "$FIXTURE_BIN_PATH/Herdr.product/Objects.LinkFileList"
source "$HELPER"
assert_objects "SwiftPM newline layout" \
    "/tmp/Modern Build/AppHotkeys.swift.o" \
    "/tmp/Modern Build/WorkspaceView.swift.o"

LEGACY_ROOT="$FIXTURE_ROOT/Legacy Checkout"
FIXTURE_BIN_PATH="$LEGACY_ROOT/products"
LEGACY_LIST="$LEGACY_ROOT/.build/out/Intermediates.noindex/HerdrMac.build/Debug/Herdr-p.build/Objects-normal/arm64/Herdr.LinkFileList"
mkdir -p "$(dirname "$LEGACY_LIST")" "$FIXTURE_BIN_PATH"
cp "$REPOSITORY_ROOT/Tests/Fixtures/app-test-link-xcode.txt" "$LEGACY_LIST"
(
    cd "$LEGACY_ROOT"
    source "$HELPER"
    assert_objects "Xcode quoted layout" \
        "/tmp/Legacy Build/AppHotkeys.o" \
        "/tmp/Legacy Build/WorkspaceView.o"
)

printf 'PASS: app test linker preserves SwiftPM records and parses quoted Xcode object paths\n'
