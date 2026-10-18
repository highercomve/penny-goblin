#!/usr/bin/env bash
# Build the desktop executable and AppImage, using the same entry point as CI.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
renderer=${1:-oriel}
case "$renderer" in oriel|webview) ;; *) printf 'Use oriel or webview\n' >&2; exit 2 ;; esac
zig build -Drenderer="$renderer" -Doptimize=ReleaseSafe -p "zig-out-$renderer" --summary all
zig build package-appimage -Drenderer="$renderer" -Doptimize=ReleaseSafe -p "zig-out-$renderer" --summary all
mkdir -p dist
cp "zig-out-$renderer/bin/penny-goblin" "dist/penny-goblin-linux-x86_64-$renderer"
for image in "zig-out-$renderer/package/"*.AppImage; do
    cp "$image" "dist/$(basename "${image%.AppImage}")-$renderer.AppImage"
done
(cd dist && sha256sum "penny-goblin-linux-x86_64-$renderer" *"-$renderer.AppImage" > "SHA256SUMS-linux-$renderer")
