#!/usr/bin/env bash
# Build the packaged desktop executable and AppImage, using the same entry point as CI.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# build-linux.sh <oriel|webview> [zig build options, e.g. -Dggml_cuda_prebuilt=/abs/libggml-cuda.so]
renderer=${1:-oriel}
shift || true
case "$renderer" in oriel|webview) ;; *) printf 'Use oriel or webview\n' >&2; exit 2 ;; esac
zig build package-executable -Drenderer="$renderer" -Doptimize=ReleaseSafe -p "zig-out-$renderer" --summary all "$@"
zig build package-appimage -Drenderer="$renderer" -Doptimize=ReleaseSafe -p "zig-out-$renderer" --summary all "$@"
mkdir -p dist
# Published files come only from package/: the executable there is checked
# (no dev agent) and stripped, never the raw zig-out bin copy.
version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
cp "zig-out-$renderer/package/penny-goblin-$version-x86_64-linux" "dist/penny-goblin-linux-x86_64-$renderer"
for image in "zig-out-$renderer/package/"*.AppImage; do
    cp "$image" "dist/$(basename "${image%.AppImage}")-$renderer.AppImage"
done
(cd dist && sha256sum "penny-goblin-linux-x86_64-$renderer" *"-$renderer.AppImage" > "SHA256SUMS-linux-$renderer")
