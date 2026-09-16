#!/bin/bash
# Source after building Herdr. Include every transitive runtime object from SwiftPM,
# including CTOML/TOMLKit, in both the legacy and Swift 6.4 product layouts.
APP_TEST_CONFIGURATION="${APP_TEST_CONFIGURATION:-debug}"
APP_TEST_BUILD="$(swift build -c "$APP_TEST_CONFIGURATION" --show-bin-path)"
APP_TEST_LINK_FILE="$APP_TEST_BUILD/Herdr.product/Objects.LinkFileList"
if [ ! -f "$APP_TEST_LINK_FILE" ]; then
    case "$APP_TEST_CONFIGURATION" in release) APP_TEST_LAYOUT=Release ;; *) APP_TEST_LAYOUT=Debug ;; esac
    APP_TEST_LINK_FILE="$(find .build -path "*/$APP_TEST_LAYOUT/Herdr-p.build/Objects-normal/*/Herdr.LinkFileList" -print -quit)"
fi
if [ ! -f "$APP_TEST_LINK_FILE" ]; then
    printf 'Could not locate the Herdr app object link list.\n' >&2
    exit 1
fi
APP_TEST_MODULE_DIR="$(dirname "$APP_TEST_LINK_FILE")"
APP_TEST_OBJECTS=()
while IFS= read -r object || [ -n "$object" ]; do
    [ -n "$object" ] || continue
    case "$object" in
        */HerdrApp.swift.o|*/HerdrApp.o) ;;
        *) APP_TEST_OBJECTS+=("$object") ;;
    esac
done < <(tr ' ' '\n' < "$APP_TEST_LINK_FILE")
APP_TEST_CTOML_MAP="$APP_TEST_BUILD/CTOML.build/module.modulemap"
if [ ! -f "$APP_TEST_CTOML_MAP" ]; then
    APP_TEST_CTOML_MAP=".build/out/Intermediates.noindex/GeneratedModuleMaps/CTOML.modulemap"
fi
app_test_compile() {
    swiftc -parse-as-library -I "$APP_TEST_BUILD/Modules" -I "$APP_TEST_BUILD" -I "$APP_TEST_MODULE_DIR" \
        -Xcc "-fmodule-map-file=$APP_TEST_CTOML_MAP" \
        -I .build/checkouts/TOMLKit/Sources/CTOML/include \
        -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
        -L "$APP_TEST_BUILD" -lghostty -lc++ -framework Carbon \
        "$@" "${APP_TEST_OBJECTS[@]}"
}
