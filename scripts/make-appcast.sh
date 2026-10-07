#!/bin/bash
# Writes dist/appcast.xml, the signed Sparkle feed offering
# dist/uHerdr-<version>.zip (made by package-release.sh) as the latest update.
#   VERSION              Release version (default: bundle version).
#   TAG                  Release tag whose assets the feed links to (default: v<VERSION>).
#   RELEASE_NOTES        Optional Markdown file shown in the update dialog.
#   SPARKLE_PRIVATE_KEY  EdDSA private key. Without it the key is read from the
#                        login keychain, where generate_keys stores it.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_URL=https://github.com/MrMySQL/uherdr
TOOLS=.build/artifacts/sparkle/Sparkle/bin
APP="$PWD/dist/uHerdr.app"
[[ -x "$TOOLS/generate_appcast" ]] || { echo "Missing $TOOLS; run swift package resolve first" >&2; exit 1; }
VERSION="${VERSION:-$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")}"
VERSION="${VERSION#v}"
TAG="${TAG:-v$VERSION}"
ZIP="$PWD/dist/uHerdr-$VERSION.zip"
plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" > /dev/null 2>&1 \
    || { echo "$APP has no SUPublicEDKey; set SPARKLE_PUBLIC_KEY in build-app.sh" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "Missing $ZIP; run scripts/package-release.sh first" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# generate_appcast reads the app's version and public key from the archive.
cp "$ZIP" "$WORK/"
if [[ -n "${RELEASE_NOTES:-}" ]]; then
    cp "$RELEASE_NOTES" "$WORK/uHerdr-$VERSION.md"
fi
ARGS=(--download-url-prefix "$REPO_URL/releases/download/$TAG/"
      --full-release-notes-url "$REPO_URL/releases/tag/$TAG"
      --link "$REPO_URL" --embed-release-notes --maximum-deltas 0 -o "$WORK/appcast.xml")
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    "$TOOLS/generate_appcast" --ed-key-file - "${ARGS[@]}" "$WORK" <<<"$SPARKLE_PRIVATE_KEY" 2>&1 | tee "$WORK/log"
else
    "$TOOLS/generate_appcast" "${ARGS[@]}" "$WORK" 2>&1 | tee "$WORK/log"
fi
# A key mismatch is only a warning there, but installed apps would reject the update.
if grep -q 'does not match key' "$WORK/log"; then
    echo "The signing key does not match the app's SUPublicEDKey" >&2
    exit 1
fi
grep -q 'sparkle:edSignature=' "$WORK/appcast.xml" || { echo "appcast.xml has an unsigned update" >&2; exit 1; }
cp "$WORK/appcast.xml" dist/appcast.xml
printf 'Wrote dist/appcast.xml for %s\n' "$TAG"
