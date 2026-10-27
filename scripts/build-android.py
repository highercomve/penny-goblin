#!/usr/bin/env python3
"""Build reproducible Oriel Android APKs, including an isolated device-test profile."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gradle", default=os.environ.get("GRADLE", "gradle"))
parser.add_argument("--abi", action="append", choices=("arm64-v8a", "x86_64"), help="Repeat for a universal APK (default: arm64-v8a)")
parser.add_argument("--test-profile", action="store_true", help="Separate app ID/data; safe alongside a personal ledger")
parser.add_argument("--no-vision", action="store_true", help="Disable bundled LLM runtime; platform OCR remains available")
args = parser.parse_args()
abis = list(dict.fromkeys(args.abi or ["arm64-v8a"]))
targets = {"arm64-v8a": "aarch64-linux-android", "x86_64": "x86_64-linux-android"}
version = re.search(r'\.version = "([^"]+)"', (ROOT / "build.zig.zon").read_text())[1]
config = ["-Drenderer=oriel", "-Doptimize=ReleaseSafe"] + (["-Dvision=false"] if args.no_vision else [])
def run(argv, **kwargs):
    return subprocess.run(argv, cwd=ROOT, check=True, **kwargs)
# The framework owns generation, Kotlin/JNI hooks, manifest and icon defaults.
run(["zig", "build", "android-project", f"-Dtarget={targets[abis[0]]}", *config])
gradle_file = ROOT / "android/app/build.gradle.kts"
text = gradle_file.read_text()
# android-project preserves customized Gradle files on incremental builds.
# Refresh the release identity without replacing local signing or SDK settings.
major, minor, patch = map(int, version.split("."))
assert 0 <= minor < 100 and 0 <= patch < 100
version_code = major * 10000 + minor * 100 + patch
text, code_count = re.subn(r"(?m)^(\s*versionCode\s*=\s*)\d+", lambda match: match[1] + str(version_code), text)
text, name_count = re.subn(r'(?m)^(\s*versionName\s*=\s*)"[^"]+"', lambda match: match[1] + f'"{version}"', text)
assert code_count == name_count == 1, "Generated Gradle version fields missing or ambiguous"
text = re.sub(r'(?m)^\s*ndk \{ abiFilters.*?\}\n', '\n', text)
filters = ", ".join(f'"{abi}"' for abi in abis)
text = text.replace('defaultConfig {', f'defaultConfig {{\n        ndk {{ abiFilters += listOf({filters}) }}', 1)
gradle_file.write_text(text)
shutil.copytree(ROOT / "platform/android/res", ROOT / "android/app/src/main/res", dirs_exist_ok=True)
for abi in abis:
    run(["zig", "build", f"-Dtarget={targets[abi]}", *config, "--summary", "all"])
run(["python3", "scripts/android-customize.py", *(["--test-profile"] if args.test_profile else [])])
subprocess.run([args.gradle, "--no-daemon", "assembleDebug"], cwd=ROOT / "android", check=True)
apk = ROOT / "android/app/build/outputs/apk/debug/app-debug.apk"
sdk = Path(os.environ.get("ANDROID_HOME") or os.environ["ANDROID_SDK_ROOT"])
tools = Path(os.environ.get("ANDROID_BUILD_TOOLS", sdk / "build-tools/35.0.0"))
tool_env = os.environ.copy()
if "ANDROID_DATA" not in tool_env:
    tool_data = Path(tempfile.gettempdir()) / "penny-android-tool-data"
    tool_data.mkdir(exist_ok=True)
    tool_env["ANDROID_DATA"] = str(tool_data)
badging = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(apk)], text=True, env=tool_env)
app_id = "com.pennygoblin.adaptive.test" if args.test_profile else "com.pennygoblin.app"
assert f"name='{app_id}'" in badging and f"versionName='{version}'" in badging and f"versionCode='{version_code}'" in badging, badging.splitlines()[0]
subprocess.run([str(sdk / "build-tools/35.0.0/apksigner"), "verify", "--verbose", str(apk)], check=True)
for abi in abis:
    assert f"'{abi}'" in badging, f"Missing ABI: {abi}"
profile = "-test" if args.test_profile else ""
architecture = "universal" if len(abis) > 1 else abis[0]
out = ROOT / "dist" / f"penny-goblin-{version}-android-{architecture}{profile}.apk"
out.parent.mkdir(exist_ok=True)
shutil.copy2(apk, out)
out.with_suffix(".apk.sha256").write_text(f"{hashlib.sha256(out.read_bytes()).hexdigest()}  {out.name}\n")
print(out)
