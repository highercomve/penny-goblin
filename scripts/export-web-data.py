#!/usr/bin/env python3
"""Export existing web-app data without starting it or writing its files.

Usage: python3 native/scripts/export-web-data.py > /tmp/tarjeta-import.json
The exported file contains private financial data; keep it out of version control.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "finance_tracker"))
from web_app import load_data, normalize_fixed_expenses, total_fixed_expenses


def export():
    transactions, category_config, config = load_data()
    fixed = normalize_fixed_expenses(config.get("budget", {}).get("fixed_expenses", []))
    owners = config.get("account_owner") or config.get("account_owners", [])
    if isinstance(owners, str):
        owners = [owners]
    json.dump({
        "account_owners": owners,
        "transactions": transactions,
        "categories": category_config.get("categories", {}),
        "special_cases": category_config.get("special_cases", {}),
        "cards_config": config.get("cards", {}),
        "salary": config.get("budget", {}).get("salary", 0),
        "fixed_expenses": total_fixed_expenses(fixed),
        "fixed_expenses_items": fixed,
        "vendors_config": config.get("vendors", {}),
    }, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    export()
