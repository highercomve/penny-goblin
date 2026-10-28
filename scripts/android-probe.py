#!/usr/bin/env python3
"""Capture only the isolated adaptive-test app's native view (not the user's desktop).

Requires a --test-profile APK. The probe and synthetic provider are excluded from
production. This is Android injected-input evidence, not physical-device input QA.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time

PACKAGE = "com.pennygoblin.adaptive.test"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("name")
parser.add_argument("--compare", action="store_true")
parser.add_argument("--serial", default="emulator-5554")
parser.add_argument("--output", type=Path, default=Path("docs/evidence/android"))
args = parser.parse_args()
if not re.fullmatch(r"[a-zA-Z0-9_-]{1,60}", args.name):
    parser.error("name must contain only letters, digits, underscores or hyphens")
base = ["adb", "-s", args.serial]
activity = "dev.oriel.CompareActivity" if args.compare else "dev.oriel.OrielMainActivity"
nonce = args.name + "-" + str(time.time_ns())
subprocess.run([*base, "shell", "am", "start", "-n", f"{PACKAGE}/{activity}", "-a", "penny.adaptive.PROBE", "--es", "name", nonce], check=True, capture_output=True)
for attempt in range(40):
    metadata = subprocess.run([*base, "exec-out", "content", "read", "--uri", f"content://{PACKAGE}.fixtures/capture/{nonce}.json"], capture_output=True)
    if metadata.returncode == 0:
        try:
            data = json.loads(metadata.stdout)
        except json.JSONDecodeError:
            time.sleep(0.25)
            continue
        screenshot = subprocess.run([*base, "exec-out", "content", "read", "--uri", f"content://{PACKAGE}.fixtures/capture/{nonce}.png"], capture_output=True, check=True).stdout
        if not screenshot.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("Native screenshot was not a PNG")
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / f"{args.name}.png").write_bytes(screenshot)
        (args.output / f"{args.name}.json").write_text(json.dumps(data, indent=2) + "\n")
        print(json.dumps({"capture": args.name, "width": data["width"], "height": data["height"], "task": data["task"], "fields": data["fields"]}, indent=2))
        break
    time.sleep(0.25)
else:
    raise SystemExit("No test-app capture: check the test APK, Android activity and app logs")
