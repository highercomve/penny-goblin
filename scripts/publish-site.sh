#!/usr/bin/env bash
# Publish generated website files only. Authentication is supplied by CI's agent.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ -f public/index.html ]] || { printf 'Build the Zine site first.\n' >&2; exit 1; }
site_checkout=$(mktemp -d)
trap 'rm -rf -- "$site_checkout"' EXIT
git clone --depth 1 git@github.com:highercomve/penny-goblin-site.git "$site_checkout/site"
python3 - "$site_checkout/site" <<'COPY'
from pathlib import Path
import shutil
import sys
root = Path(sys.argv[1])
for path in root.iterdir():
    if path.name == ".git":
        continue
    if path.is_dir(): shutil.rmtree(path)
    else: path.unlink()
shutil.copytree("public", root, dirs_exist_ok=True)
(root / ".nojekyll").touch()
COPY
git -C "$site_checkout/site" config user.name 'github-actions[bot]'
git -C "$site_checkout/site" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$site_checkout/site" add --all
if git -C "$site_checkout/site" diff --cached --quiet; then
    printf 'Website is already current.\n'
    exit 0
fi
git -C "$site_checkout/site" commit -m "Publish Penny Goblin website"
git -C "$site_checkout/site" push origin HEAD:main
