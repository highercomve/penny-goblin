#!/usr/bin/env python3
"""Fingerprint resolved Oriel inputs using stable labels shared with prior CI caches."""
import hashlib
from pathlib import Path
import sys

labels = ("vendor/oriel/build.zig.zon", "vendor/oriel/build/ggml.zig")
if len(sys.argv) != 3:
    raise SystemExit("expected Oriel manifest and ggml build file")
record = "".join(f"{hashlib.sha256(Path(path).read_bytes()).hexdigest()}  {label}\n"
                 for path, label in zip(sys.argv[1:], labels))
print(hashlib.sha256(record.encode()).hexdigest()[:16])
