#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product Herdr
MENU_BUILD_DIR="$(swift build --show-bin-path)"
MENU_TEST_ROOT="$(mktemp -d /tmp/herdr-text-size.XXXXXX)"
trap 'rm -rf "$MENU_TEST_ROOT"' EXIT
MENU_APP="$MENU_TEST_ROOT/TextSizeMenuTests.app"
mkdir -p "$MENU_APP/Contents/MacOS" "$MENU_APP/Contents/Resources"
# Use the actual app scene and commands with the test harness as the entry point.
{ printf '@testable import HerdrMac\n'; sed '/^@main$/d' Sources/HerdrMac/HerdrApp.swift; } > "$MENU_TEST_ROOT/HerdrApp.swift"
MENU_OBJECTS=()
while IFS= read -r object; do
    case "$object" in
        */HerdrApp.swift.o) ;;
        *) MENU_OBJECTS+=("$object") ;;
    esac
done < "$MENU_BUILD_DIR/Herdr.product/Objects.LinkFileList"
swiftc -parse-as-library -I "$MENU_BUILD_DIR/Modules" \
    -I .build/artifacts/ghosttyterminal/libghostty/GhosttyKit.xcframework/macos-arm64_x86_64/Headers \
    -L "$MENU_BUILD_DIR" -lghostty -lc++ -framework Carbon \
    "$MENU_TEST_ROOT/HerdrApp.swift" Tests/HerdrMacTests/TextSizeMenuTests.swift "${MENU_OBJECTS[@]}" \
    -o "$MENU_APP/Contents/MacOS/TextSizeMenuTests"
cat > "$MENU_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TextSizeMenuTests</string>
<key>CFBundleIdentifier</key><string>dev.herdr.text-size-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
cp -R "$MENU_BUILD_DIR/GhosttyKit_GhosttyTerminal.bundle" "$MENU_APP/Contents/Resources/"
"$MENU_APP/Contents/MacOS/TextSizeMenuTests"
