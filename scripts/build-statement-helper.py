"""Build a self-contained parser; no Python installation needed at runtime."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("inputs", nargs="*")  # Build-system file dependencies.
args = parser.parse_args()
venv = ROOT / ".helper-venv"
python = venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
if not python.exists():
    subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
requirements = ROOT / "scripts/helper-requirements.txt"
digest = hashlib.sha256(requirements.read_bytes()).hexdigest()
stamp = venv / "requirements.sha256"
if not stamp.exists() or stamp.read_text() != digest:
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(ROOT / "scripts/helper-requirements.txt")], check=True)
    stamp.write_text(digest)
with tempfile.TemporaryDirectory(prefix="penny-helper-build-") as directory:
    source = ROOT / "src/helpers"
    command = [str(python), "-m", "PyInstaller", "--noconfirm", "--onefile", "--name", "statement-helper",
               "--hidden-import", "pdfplumber", "--add-data", f"{source / 'santander_parser.py'}:.",
               "--distpath", f"{directory}/dist", "--workpath", f"{directory}/work", "--specpath", directory,
               str(source / "statement_helper.py")]
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        sys.stderr.buffer.write(result.stderr[-12000:])
        raise SystemExit(result.returncode)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(directory)/"dist"/("statement-helper.exe" if os.name == "nt" else "statement-helper"), output)
