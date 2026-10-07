#!/bin/bash
# Notarizes dist/uHerdr.app (built by build-app.sh) and packages it as
# dist/uHerdr-<version>.dmg and .zip with SHA256SUMS.
#   VERSION         Release version for file names (default: bundle version).
#   SIGN_IDENTITY   Developer ID identity used to sign the DMG.
#   Notary credentials, either:
#     NOTARY_PROFILE                                  keychain profile from
#                                                     `xcrun notarytool store-credentials`
#     NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID  App Store Connect API key
#   Without credentials the artifacts are packaged but not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/uHerdr.app"
[[ -d "$APP" ]] || { echo "Missing $APP; run scripts/build-app.sh first" >&2; exit 1; }
VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")}"
VERSION="${VERSION#v}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NAME="uHerdr-$VERSION"
DMG="$PWD/dist/$NAME.dmg"
ZIP="$PWD/dist/$NAME.zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi

notarize() {
    [[ ${#NOTARY_ARGS[@]} -gt 0 ]] || return 0
    local result status id
    printf 'Notarizing %s\n' "$(basename "$1")"
    result="$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --output-format json)"
    status="$(plutil -extract status raw - <<<"$result")"
    if [[ "$status" != Accepted ]]; then
        id="$(plutil -extract id raw - <<<"$result")"
        printf 'Notarization %s for %s\n' "$status" "$1" >&2
        xcrun notarytool log "$id" "${NOTARY_ARGS[@]}" >&2 || true
        exit 1
    fi
    xcrun stapler staple "$2"
}

codesign --verify --strict "$APP"
if [[ ${#NOTARY_ARGS[@]} -eq 0 ]]; then
    echo "warning: no notary credentials; packaging without notarization" >&2
fi

# Notarize and staple the app itself so the zip works offline too.
ditto -c -k --keepParent "$APP" "$WORK/submit.zip"
notarize "$WORK/submit.zip" "$APP"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

mkdir "$WORK/dmg"
ditto "$APP" "$WORK/dmg/uHerdr.app"
ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -quiet -volname uHerdr -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO "$DMG"
if [[ "$SIGN_IDENTITY" != - ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
notarize "$DMG" "$DMG"

if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
    spctl --assess --type execute --verbose "$APP"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi
(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
printf 'Packaged %s\n' dist/"$NAME".{dmg,zip} dist/SHA256SUMS
