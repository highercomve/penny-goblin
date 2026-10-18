#!/usr/bin/env bash
# Rebuild Zine output without retaining deleted pages from an older build.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ $(zine version 2>&1) == 0.14.0 ]] || { printf 'Zine 0.14.0 is required.\n' >&2; exit 1; }
site_stage=$(mktemp -d)
trap 'rm -rf -- "$site_stage"' EXIT
zine release --output "$site_stage/site"
rm -rf -- public
mv -- "$site_stage/site" public
