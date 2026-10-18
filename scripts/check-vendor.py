#!/usr/bin/env python3
"""Verify that the checked-in Oriel snapshot matches its recorded contents."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[1] / "vendor/oriel"
manifest = json.loads((root / "SNAPSHOT.json").read_text())
for name, expected in manifest["files"].items():
    path = root / name
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f"Oriel snapshot mismatch: {name}")
print(f"Oriel snapshot verified: {len(manifest['files'])} files")
