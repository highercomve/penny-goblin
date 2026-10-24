"""Freeze the Linux browsers and PyGObject; only platform GTK/WebKit stay external."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("inputs", nargs="*")
args = parser.parse_args()
# Reuse the pinned parser build environment; PyGObject comes from the build host.
# It is bundled into the executable, never imported from the user's system.
python = ROOT / ".browser-venv/bin/python"
if not python.exists():
    subprocess.run([sys.executable, "-m", "venv", str(python.parent.parent)], check=True)
subprocess.run([str(python), "-m", "pip", "install", "pyinstaller==6.16.0",
                "pyinstaller-hooks-contrib==2026.8"], check=True, stdout=sys.stderr)
import gi
system_packages = str(Path(gi.__file__).resolve().parent.parent)
with tempfile.TemporaryDirectory(prefix="penny-browser-build-") as directory:
    source = ROOT / "src/helpers"
    spec = Path(directory) / "browser.spec"
    spec.write_text(f"""
from pathlib import Path
a = Analysis([{str(source / 'browser_helper.py')!r}],
    pathex=[{str(source)!r}, {system_packages!r}],
    hiddenimports=['santander_browser', 'bci_browser', 'boa_browser', 'research_browser', 'research_network',
        'gi.repository.GLibUnix', 'gi.repository.GioUnix',
        'gi.overrides.GLibUnix', 'gi.overrides.GioUnix'],
    hooksconfig={{'gi': {{'module-versions': {{'Gtk': '4.0', 'Gdk': '4.0', 'WebKit': '6.0'}},
        'icons': [], 'themes': [], 'languages': []}}}})
# Match the application's native GTK/WebKit and the system WebKit subprocesses.
# Bundle Python extensions and libpython, not a duplicate graphics/network stack.
a.binaries = [entry for entry in a.binaries
    if '/python' in entry[1] or Path(entry[1]).name.startswith('libpython')]
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, a.binaries, a.datas, [], name='browser-helper',
    console=True, strip=False, upx=False)
""")
    result = subprocess.run([str(python), "-m", "PyInstaller", "--noconfirm",
        "--distpath", f"{directory}/dist", "--workpath", f"{directory}/work", str(spec)],
        capture_output=True)
    if result.returncode:
        sys.stderr.buffer.write(result.stderr[-16000:])
        raise SystemExit(result.returncode)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(directory) / "dist/browser-helper", output)
    output.chmod(0o700)
