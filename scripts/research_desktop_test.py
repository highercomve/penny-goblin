"""Real desktop app + real ledger/commands on a private display, synthetic data.
Usage: scripts/headless.sh python3 research_desktop_test.py APP MODEL_GGUF
"""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
model = Path(sys.argv[2]).resolve()
with tempfile.TemporaryDirectory(prefix="penny-research-desktop-") as directory:
    root = Path(directory)
    data = root / "data/com.pennygoblin.app"
    data.mkdir(parents=True)
    model_dir = data / "categorization-model"
    model_dir.mkdir()
    (model_dir / "choice.json").write_text(json.dumps(str(model)))
    path = data / "ledger.sqlite3"
    db = sqlite3.connect(path)
    for script in ("schema.sql", "migration2.sql", "migration3.sql", "migration4.sql"):
        db.executescript((ROOT / "src/core" / script).read_text())
    settings = json.dumps({"salary":100000,"categories":{"Groceries":["MARKET"]}})
    db.execute("insert into settings values('budget',?)", (settings,))
    for index in range(10):
        identity = hashlib.sha256(f"desktop research {index}".encode()).hexdigest()
        db.execute("insert into expenses(id,revision,date,amount,currency,payee,account,category,notes,reference,location) values(?,1,'2026-10-18',100,'CLP',?,'Debit','Other','','','')", (identity, f"MARKET {index}"))
        db.execute("insert into changes(expense_id,revision) values(?,1)", (identity,))
    db.commit()
    before = db.execute("select id,date,amount,account,notes,reference,location from expenses order by id").fetchall()
    report = root / "report.json"
    env = {**os.environ,"XDG_DATA_HOME":str(root/"data"),"XDG_CONFIG_HOME":str(root/"config"),"GSK_RENDERER":"cairo",
           "PENNY_QA_OUT":str(report),"PENNY_QA":"view:payments;click:research-open;wait:1000;click:research-start;wait:1000;dump;wait:5000;click:research-apply;wait:1000;dump"}
    with (root / "app.log").open("wb") as log:
        process = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while not report.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError((root/"app.log").read_text()[-5000:])
                time.sleep(.1)
            assert db.execute("select count(*) from expenses where category='Other' and revision=1").fetchone()[0] == 10, "Research wrote before Apply"
            deadline = time.monotonic() + 15
            while db.execute("select count(*) from expenses where category='Groceries' and revision=2").fetchone()[0] != 10:
                if process.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError("Apply did not update all selected payments: " + (root/"app.log").read_text()[-3000:])
                time.sleep(.1)
            assert before == db.execute("select id,date,amount,account,notes,reference,location from expenses order by id").fetchall(), "Research changed other financial fields"
            assert db.execute("select count(*) from changes where revision=2").fetchone()[0] == 10, "Missing sync bookkeeping"
            assert db.execute("pragma integrity_check").fetchone()[0] == "ok"
            print("Real WebKit app: ten synthetic payments reviewed with zero writes before Apply; categories/revisions/sync bookkeeping committed; financial fields preserved.")
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill();process.wait()
            db.close()
