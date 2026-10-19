#!/usr/bin/env bash
# Build libggml-cuda.so on this machine (Arch Linux with the `cuda` package;
# nvcc on a hosted runner takes over an hour) and attach it to this
# repository's release named by CI's CUDA backend key, which the Linux
# WebView job downloads instead of compiling it.
#
#   scripts/publish-cuda-backend.sh            build and upload
#   scripts/publish-cuda-backend.sh <lib.so>   upload a library built with
#                                              the same Oriel snapshot, GPU
#                                              list and CUDA version
#
# The key must match CI's: the same vendor/oriel files, CUDA_ARCHS and CUDA
# major version (the library links libcublas.so.<major>).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

archs=$(sed -n 's/^  CUDA_ARCHS: //p' .github/workflows/build.yml)
[[ -n $archs ]] || { printf 'error: no CUDA_ARCHS in .github/workflows/build.yml\n' >&2; exit 1; }
installed=$(pacman -Q cuda | cut -d' ' -f2)
major=${installed%%.*}
ggml=$(sha256sum vendor/oriel/build.zig.zon vendor/oriel/build/ggml.zig | sha256sum | cut -c1-16)
key="ggml-cuda-$ggml-${archs//,/_}-cuda$major"

lib=${1:-}
if [[ -z $lib ]]; then
    zig build -Drenderer=webview -Doptimize=ReleaseSafe -Dggml_cuda -Dcuda_arch="$archs" -p zig-out-cuda --summary all
    lib=zig-out-cuda/bin/libggml-cuda.so
fi
[[ -f $lib ]] || { printf 'error: %s not found\n' "$lib" >&2; exit 1; }

if gh release view "$key" >/dev/null 2>&1; then
    gh release upload "$key" "$lib" --clobber
else
    gh release create "$key" "$lib" --prerelease --title "CUDA backend $key" \
        --notes "libggml-cuda.so for CI's Linux WebView build (CUDA archs $archs, CUDA $installed). Not an app release."
fi
printf 'Published %s\n' "$key"
