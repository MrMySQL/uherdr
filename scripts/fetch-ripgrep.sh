#!/bin/bash
# Fetches the pinned ripgrep release builds the app ships, checks each archive
# against its published SHA-256, and prepares .build/ripgrep/:
#   rg                      macOS universal (arm64 + x86_64), used on this Mac
#   rg-linux-x86_64.gz      static musl builds, copied to an SSH device by
#   rg-linux-aarch64.gz     "Install for uHerdr" (unpacked on this Mac first)
#   COPYING LICENSE-MIT UNLICENSE
# Archives are cached in .build/ripgrep-downloads; a cached archive is used
# only when its hash matches.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=15.2.0
CACHE=.build/ripgrep-downloads
OUT=.build/ripgrep
mkdir -p "$CACHE"
fetch() {
    local target=$1 sum=$2 file="ripgrep-$VERSION-$1.tar.gz"
    if ! { [ -f "$CACHE/$file" ] && echo "$sum  $CACHE/$file" | shasum -a 256 -c --status; }; then
        curl -fsSL -o "$CACHE/$file" "https://github.com/BurntSushi/ripgrep/releases/download/$VERSION/$file"
        echo "$sum  $CACHE/$file" | shasum -a 256 -c --status || { echo "checksum mismatch: $file" >&2; rm -f "$CACHE/$file"; exit 1; }
    fi
    rm -rf "$CACHE/$target"
    mkdir -p "$CACHE/$target"
    tar -xzf "$CACHE/$file" -C "$CACHE/$target" --strip-components 1
}
fetch aarch64-apple-darwin 3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4
fetch x86_64-apple-darwin af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1
fetch x86_64-unknown-linux-musl 33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c
fetch aarch64-unknown-linux-musl 800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915
rm -rf "$OUT"
mkdir -p "$OUT"
lipo -create "$CACHE/aarch64-apple-darwin/rg" "$CACHE/x86_64-apple-darwin/rg" -output "$OUT/rg"
chmod 755 "$OUT/rg"
gzip -9 -n -c "$CACHE/x86_64-unknown-linux-musl/rg" > "$OUT/rg-linux-x86_64.gz"
gzip -9 -n -c "$CACHE/aarch64-unknown-linux-musl/rg" > "$OUT/rg-linux-aarch64.gz"
cp "$CACHE/x86_64-unknown-linux-musl/COPYING" "$CACHE/x86_64-unknown-linux-musl/LICENSE-MIT" "$CACHE/x86_64-unknown-linux-musl/UNLICENSE" "$OUT/"
printf 'ripgrep %s ready in %s\n' "$VERSION" "$OUT"
