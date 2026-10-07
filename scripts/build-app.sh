#!/bin/bash
# Builds dist/uHerdr.app.
#   VERSION        Marketing version (default: latest v* tag, else 0.0.0). A
#                  pre-release suffix such as -beta.1 is dropped from the bundle.
#   BUILD_NUMBER   CFBundleVersion (default: commit count).
#   UNIVERSAL=1    Build arm64 + x86_64 instead of the host architecture.
#   SIGN_IDENTITY  codesign identity (default: ad-hoc "-"). A Developer ID
#                  identity also gets a secure timestamp for notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || echo 0.0.0)}"
VERSION="${VERSION#v}"
BUNDLE_VERSION="${VERSION%%-*}"
if [[ ! "$BUNDLE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION must look like 1.2.3 (got %s)\n' "$VERSION" >&2
    exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="$PWD/dist/uHerdr.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    # Build each slice separately; multi-arch flags are not honored by every
    # SwiftPM build system, and single-arch builds may share one output path.
    SLICES=()
    for ARCH in arm64 x86_64; do
        swift build -c release --product Herdr --arch "$ARCH"
        BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
        cp "$BIN_DIR/Herdr" ".build/Herdr-$ARCH"
        SLICES+=(".build/Herdr-$ARCH")
    done
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/uHerdr"
else
    swift build -c release --product Herdr
    BIN_DIR="$(swift build -c release --show-bin-path)"
    cp "$BIN_DIR/Herdr" "$APP/Contents/MacOS/uHerdr"
fi
cp -R "$BIN_DIR/GhosttyKit_GhosttyTerminal.bundle" "$APP/Contents/Resources/"
cp -R "$BIN_DIR/HerdrMac_HerdrMac.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>uHerdr</string>
<key>CFBundleIdentifier</key><string>dev.herdr.native</string>
<key>CFBundleName</key><string>uHerdr</string>
<key>CFBundleDisplayName</key><string>uHerdr</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$BUNDLE_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>uHerdr</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 MrMySQL. MIT License.</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>dev.herdr.native.pane</string>
<key>UTTypeDescription</key><string>uHerdr pane</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict><dict>
<key>UTTypeIdentifier</key><string>dev.herdr.native.tab</string>
<key>UTTypeDescription</key><string>uHerdr tab</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST
cp Vendor/GhosttyTerminal/LICENSE "$APP/Contents/Resources/GhosttyTerminal-LICENSE"
cp .build/checkouts/MSDisplayLink/LICENSE "$APP/Contents/Resources/MSDisplayLink-LICENSE"
cp docs/licenses/Ghostty-LICENSE "$APP/Contents/Resources/Ghostty-LICENSE"
cp LICENSE "$APP/Contents/Resources/LICENSE"
swift scripts/make-icon.swift .build/uHerdr.iconset
iconutil -c icns .build/uHerdr.iconset -o "$APP/Contents/Resources/uHerdr.icns"

SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != - ]] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP"
printf 'Built %s %s (%s)\n' "$APP" "$VERSION" "$BUILD_NUMBER"
