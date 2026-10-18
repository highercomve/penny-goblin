#!/usr/bin/env python3
"""Build the Oriel arm64 APK from a clean checkout; Gradle must be 8.14.3."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gradle", default=os.environ.get("GRADLE", "gradle"))
args = parser.parse_args()
version = re.search(r'\.version = "([^"]+)"', (ROOT / "build.zig.zon").read_text())[1]
config = ["-Dtarget=aarch64-linux-android", "-Drenderer=oriel", "-Doptimize=ReleaseSafe"]
def run(argv, **kwargs):
    return subprocess.run(argv, cwd=ROOT, check=True, **kwargs)
# The framework owns generation, Kotlin/JNI hooks, manifest and icon defaults.
run(["zig", "build", "android-project", *config])
gradle_file = ROOT / "android/app/build.gradle.kts"
text = gradle_file.read_text()
if 'abiFilters += "arm64-v8a"' not in text:
    text = text.replace('defaultConfig {', 'defaultConfig {\n        ndk { abiFilters += "arm64-v8a" }', 1)
gradle_file.write_text(text)
shutil.copytree(ROOT / "platform/android/res", ROOT / "android/app/src/main/res", dirs_exist_ok=True)
run(["zig", "build", *config, "--summary", "all"])
subprocess.run([args.gradle, "--no-daemon", "assembleDebug"], cwd=ROOT / "android", check=True)
apk = ROOT / "android/app/build/outputs/apk/debug/app-debug.apk"
sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
tools = sdk / "build-tools/35.0.0"
badging = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(apk)], text=True)
assert "name='com.pennygoblin.app'" in badging and f"versionName='{version}'" in badging, badging.splitlines()[0]
subprocess.run([str(tools / "apksigner"), "verify", "--verbose", str(apk)], check=True)
out = ROOT / "dist" / f"penny-goblin-{version}-android-arm64.apk"
out.parent.mkdir(exist_ok=True)
shutil.copy2(apk, out)
out.with_suffix(".apk.sha256").write_text(f"{hashlib.sha256(out.read_bytes()).hexdigest()}  {out.name}\n")
print(out)
