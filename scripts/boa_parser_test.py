"""Synthetic Bank of America exports; no customer financial data."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/helpers"))
from boa_parser import parse, cents

CHECKING = b'''Description,,Summary Amt.
Beginning balance as of 10/01/2026,,"1,000.00"
Total credits,,"2,000.00"
Total debits,,-15.00

Date,Description,Amount,Running Bal.
10/01/2026,Beginning balance,,1000.00
10/18/2026,"TEST SHOP, INC.",-12.34,987.66
10/18/2026,"TEST SHOP, INC.",-12.34,975.32
10/18/2026,REFUND,12.34,987.66
10/18/2026,BKOFAMERICA CREDIT CARD Bill Payment,-25.00,962.66
10/18/2026,DEPOSIT,2000.00,2962.66
'''
CARD = b'''Posted Date,Reference Number,Payee,Address,Amount
10/18/2026,SYNTHETIC-1,TEST CARD SHOP,ANYTOWN,-12.34
10/18/2026,SYNTHETIC-2,TEST CARD SHOP,ANYTOWN,-12.34
10/18/2026,SYNTHETIC-3,PAYMENT THANK YOU,,24.68
10/18/2026,SYNTHETIC-4,REFUND,,1.00
'''


class BoaParserTest(unittest.TestCase):
    def test_both_products_only_debits_preserve_repeated_purchases(self):
        for source in (CHECKING, CARD):
            with self.subTest(source=source[:20]):
                rows = parse(source)
                self.assertEqual(len(rows), 2)
                self.assertEqual([row["amount"] for row in rows], [1234, 1234])
                self.assertEqual(rows[0]["date"], "2026-10-18")
                self.assertEqual(rows[0]["currency"], "USD")

    def test_csv_quoting_bom_and_exact_cents(self):
        data = '\ufeffPosted Date,Reference Number,Payee,Amount\r\n10/18/2026,1,"TEST ""SHOP"", INC.","-1,234.56"\r\n'
        row = parse(data.encode())[0]
        self.assertEqual(row["amount"], 123456)
        self.assertEqual(row["payee"], 'TEST "SHOP", INC.')
        for value in ("12.345", "12,34.56", "NaN", "1e2", "12", "$12.00", "--12.00"):
            with self.assertRaises(ValueError):
                cents(value)

    def test_malformed_export_rejects_entire_file(self):
        for source in (b"<html>sign in</html>", b"Date,Description,Amount\n10/18/2026,SHOP,-12.34",
                       CARD + b"10/32/2026,5,SHOP,,-1.00\n", CARD + b"10/18/2026,5,SHOP,,NaN\n",
                       CARD + b"10/18/2026,5,SHOP\n", CARD + b"\0",
                       b"x" * (8 * 1024 * 1024 + 1)):
            with self.assertRaises(ValueError):
                parse(source)

    def test_credit_only_export_is_valid_and_empty(self):
        self.assertEqual(parse(b"Posted Date,Reference Number,Payee,Amount\n10/18/2026,1,REFUND,12.34\n"), [])


if __name__ == "__main__":
    unittest.main()
