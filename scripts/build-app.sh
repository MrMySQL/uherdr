#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/Herdr.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN_DIR="$(swift build -c release --show-bin-path)"
cp "$BIN_DIR/Herdr" "$APP/Contents/MacOS/Herdr"
for resource in "$BIN_DIR"/*.bundle; do
    [ -d "$resource" ] && cp -R "$resource" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Herdr</string>
<key>CFBundleIdentifier</key><string>dev.herdr.native</string>
<key>CFBundleName</key><string>Herdr</string>
<key>CFBundleDisplayName</key><string>Herdr</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>Herdr</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
if [ -f .build/checkouts/SwiftTerm/LICENSE ]; then
    cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE"
fi
swift scripts/make-icon.swift .build/Herdr.iconset
iconutil -c icns .build/Herdr.iconset -o "$APP/Contents/Resources/Herdr.icns"
codesign --force --deep --sign - "$APP"
printf 'Built %s\n' "$APP"
