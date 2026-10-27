#!/usr/bin/env python3
"""Inject a local Android View input event into the isolated test APK only."""
import argparse
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("command", choices=("tap", "right", "hover", "wheel", "recreate"))
p.add_argument("--capture", type=Path)
p.add_argument("--text")
p.add_argument("--x", type=float, default=100)
p.add_argument("--y", type=float, default=100)
p.add_argument("--amount", type=float, default=-3)
p.add_argument("--meta", type=int, default=0)
p.add_argument("--compare", action="store_true")
a = p.parse_args()
if a.text:
    if not a.capture:
        p.error("--text requires a native --capture JSON")
    capture = json.loads(a.capture.read_text())
    scale = capture.get("scale", capture["density"])
    matches = [n for n in capture["nodes"] if n.get("text") == a.text and n["width"] > 0 and n["height"] > 0]
    matches = [n for n in matches if 0 <= n["x"] * scale < capture["width"] and 0 <= n["y"] * scale < capture["height"]]
    if len(matches) != 1:
        raise SystemExit(f"Expected one visible text target, got {len(matches)}")
    n = matches[0]
    a.x = (n["x"] + n["width"] / 2) * scale
    a.y = (n["y"] + n["height"] / 2) * scale
activity = "dev.oriel.CompareActivity" if a.compare else "dev.oriel.OrielMainActivity"
subprocess.run(["adb", "-s", "emulator-5554", "shell", "am", "start", "-n", f"com.pennygoblin.adaptive.test/{activity}", "-a", "penny.adaptive.PROBE",
    "--es", "command", a.command, "--ef", "x", str(a.x), "--ef", "y", str(a.y), "--ef", "amount", str(a.amount), "--ei", "meta", str(a.meta)], check=True)
