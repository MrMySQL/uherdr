#!/bin/bash
# Source after building Herdr. Include every transitive runtime object from SwiftPM,
# including CTOML/TOMLKit, in both the legacy and Swift 6.4 product layouts.
APP_TEST_CONFIGURATION="${APP_TEST_CONFIGURATION:-debug}"
APP_TEST_BUILD="$(swift build -c "$APP_TEST_CONFIGURATION" --show-bin-path)"
APP_TEST_LINK_FILE="$APP_TEST_BUILD/Herdr.product/Objects.LinkFileList"
APP_TEST_LINK_LAYOUT=swiftpm
if [ ! -f "$APP_TEST_LINK_FILE" ]; then
    case "$APP_TEST_CONFIGURATION" in release) APP_TEST_LAYOUT=Release ;; *) APP_TEST_LAYOUT=Debug ;; esac
    APP_TEST_LINK_FILE="$(find .build -path "*/$APP_TEST_LAYOUT/Herdr-p.build/Objects-normal/*/Herdr.LinkFileList" -print -quit)"
    APP_TEST_LINK_LAYOUT=xcode
fi
if [ ! -f "$APP_TEST_LINK_FILE" ]; then
    printf 'Could not locate the Herdr app object link list.\n' >&2
    exit 1
fi
APP_TEST_MODULE_DIR="$(dirname "$APP_TEST_LINK_FILE")"
APP_TEST_OBJECTS=()
app_test_append_object() {
    local object="$1"
    [ -n "$object" ] || return 0
    case "$object" in
        */HerdrApp.swift.o|*/HerdrApp.o) ;;
        *) APP_TEST_OBJECTS+=("$object") ;;
    esac
}
if [ "$APP_TEST_LINK_LAYOUT" = swiftpm ]; then
    while IFS= read -r object || [ -n "$object" ]; do
        # SwiftPM emits one path per line, but shell-quotes paths with special
        # characters (for example TOMLKit's Date&Time objects). Decode those
        # records without splitting ordinary, unquoted paths containing spaces.
        case "$object" in
            \'*|\"*) object="$(printf '%s\n' "$object" | xargs -n 1 printf '%s\n')" ;;
        esac
        app_test_append_object "$object"
    done < "$APP_TEST_LINK_FILE"
else
    while IFS= read -r object || [ -n "$object" ]; do
        app_test_append_object "$object"
    done < <(xargs -n 1 printf '%s\n' < "$APP_TEST_LINK_FILE")
fi
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
