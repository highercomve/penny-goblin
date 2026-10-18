"""Read a bank statement PDF into expense rows.

BCI's card movements and checking cartolas go to bci_parser. Everything else
runs the preserved Santander parser in a disposable private filesystem: only
the supplied PDF and settings are read, and the legacy parser's writes point
at the temporary sandbox, never the original web application's data directory.
"""
import contextlib
import io
import json
import shutil
import sys
import tempfile
import datetime
import re
from pathlib import Path

import bci_parser


def categorizer(settings):
    """A row's category from the settings, as the Santander parser picks it:
    a fixed expense's keyword first, then the categories' keywords, else Other."""
    fixed = []
    for entry in settings.get("fixed_expenses_items") or []:
        keywords = entry.get("keywords") or []
        if isinstance(keywords, str):
            keywords = [k.strip() for k in keywords.split(",") if k.strip()]
        if entry.get("name") and keywords:
            fixed.append((str(entry["name"]).strip(), [str(k).strip() for k in keywords if str(k).strip()]))
    categories = settings.get("categories") or {}
    plain = lambda text: re.sub(r"[^a-zA-Z0-9\s]", " ", text).upper()

    def categorize(desc):
        for name, keywords in fixed:
            if any(plain(k).strip() and plain(k).strip() in plain(desc) for k in keywords):
                return f"Fixed: {name}"
        for category, keywords in categories.items():
            if any(k.upper() in desc.upper() for k in keywords):
                return category
        return "Other"
    return categorize


def parse_bci(pdf_path, settings):
    """BCI's documents, or None when the PDF isn't one."""
    import pdfplumber
    with pdfplumber.open(pdf_path) as pdf:
        if len(pdf.pages) > 100:
            raise ValueError("Too many pages")
        kind = bci_parser.detect(pdf.pages[0].extract_text() or "")
        if kind is None:
            return None
        categorize = categorizer(settings)
        if kind == "card":
            rows = bci_parser.parse_card(pdf, categorize)
        else:
            rows = bci_parser.parse_cartola(pdf, categorize, settings.get("account_owners") or [])
    if not rows or len(rows) > 10000:
        raise ValueError("No supported transactions or too many rows")
    return {"parser": f"bci-{kind}-v1", "rows": rows}


def parse(pdf_path, settings_path):
    if sys.platform != "win32":
        import resource
        resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
        resource.setrlimit(resource.RLIMIT_AS, (1024**3, 1024**3))
    settings = json.loads(Path(settings_path).read_text())
    with contextlib.redirect_stderr(io.StringIO()):  # pdfminer's font warnings
        bci = parse_bci(pdf_path, settings)
    if bci is not None:
        return bci
    source = Path(__file__).with_name("santander_parser.py").read_text()
    with tempfile.TemporaryDirectory(prefix="penny-statement-") as directory:
        root = Path(directory)
        parser_dir = root / "finance_tracker"
        parser_dir.mkdir()
        inputs = root / "input"
        inputs.mkdir()
        shutil.copyfile(pdf_path, inputs / "statement.pdf")
        (parser_dir / "categories.json").write_text(json.dumps({"categories": settings.get("categories") or {}}))
        (root / "config.json").write_text(json.dumps({
            "account_owners": settings.get("account_owners") or [],
            "budget": {"fixed_expenses": settings.get("fixed_expenses_items") or []},
        }))
        namespace = {"__file__": str(parser_dir / "extract_data.py"), "__name__": "penny_parser"}
        log = io.StringIO()
        with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
            exec(compile(source, namespace["__file__"], "exec"), namespace)
            with namespace["pdfplumber"].open(inputs / "statement.pdf") as pdf:
                if len(pdf.pages) > 100:
                    raise ValueError("Too many pages")
                first = (pdf.pages[0].extract_text() or "").upper()
                if not any(marker in first for marker in ("MOVIMIENTOS TARJETA", "CUENTA CORRIENTE", "SANTANDER")):
                    raise ValueError("Unsupported statement")
            namespace["extract_transactions"](str(inputs))
        if "Failed to process" in log.getvalue():
            raise ValueError("Partial parse rejected")
        rows = json.loads((parser_dir / "data/transactions.json").read_text())
        if not rows or len(rows) > 10000:
            raise ValueError("No supported transactions or too many rows")
        # The parser order is stable within a content-addressed source PDF.
        return {"parser": "santander-web-v1", "rows": [
            {"date": datetime.datetime.strptime(row["date"], "%d/%m/%y").date().isoformat(),
             "amount": row["amount"], "payee": row["desc"], "account": row["card"], "category": row["category"]}
            for row in rows
        ]}


if __name__ == "__main__":
    try:
        if sys.argv[1] == "--sync":
            from sync_transport import main
            main(sys.argv[2:])
        else:
            json.dump(parse(sys.argv[1], sys.argv[2]), sys.stdout, ensure_ascii=False)
    except Exception:
        sys.stderr.write("Synchronization helper failed.\n" if len(sys.argv) > 1 and sys.argv[1] == "--sync" else "Statement parsing failed. Check the PDF format.\n")
        sys.exit(1)
