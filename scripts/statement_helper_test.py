import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def fixture_pdf():
    text = b"BT /F1 12 Tf 40 800 Td (SANTANDER - MOVIMIENTOS TARJETA XXXX-1234) Tj 0 -40 Td (14/10/26 TEST MARKET $40.000) Tj ET"
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
               b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 842] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
               b"<< /Length " + str(len(text)).encode() + b" >>\nstream\n" + text + b"\nendstream"]
    data = b"%PDF-1.4\n"
    offsets = []
    for index, value in enumerate(objects, 1):
        offsets.append(len(data))
        data += f"{index} 0 obj\n".encode() + value + b"\nendobj\n"
    xref = len(data)
    data += b"xref\n0 6\n0000000000 65535 f \n"
    data += b"".join(f"{offset:010} 00000 n \n".encode() for offset in offsets)
    data += f"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return data


class StatementHelperTest(unittest.TestCase):
    def test_real_bci_card_and_checking_pdfs_exclude_credits_and_card_repayments(self):
        from bci_fixtures import pdf as bci_pdf
        for card in (True, False):
            with self.subTest(card=card), tempfile.TemporaryDirectory(prefix="penny-bci-proof-") as directory:
                root = Path(directory)
                source, settings = root / "fixture.pdf", root / "settings.json"
                source.write_bytes(bci_pdf(card))
                settings.write_text(json.dumps({"categories": {"Food": ["TEST BCI SHOP"]}}))
                result = subprocess.run([sys.executable, str(ROOT / "src/helpers/statement_helper.py"), str(source), str(settings)], capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                parsed = json.loads(result.stdout)
                self.assertEqual(parsed["parser"], "bci-card-v1" if card else "bci-cartola-v1")
                self.assertEqual(len(parsed["rows"]), 1)
                self.assertEqual(parsed["rows"][0]["amount"], 1200)
                self.assertEqual(parsed["rows"][0]["payee"], "TEST BCI SHOP")

    def test_real_pdf_in_isolated_parser(self):
        with tempfile.TemporaryDirectory(prefix="penny-pdf-proof-") as directory:
            root = Path(directory)
            pdf, settings = root/"fixture.pdf", root/"settings.json"
            pdf.write_bytes(fixture_pdf())
            settings.write_text(json.dumps({"categories": {"Food": ["MARKET"]}}))
            helper = Path(sys.argv[1]) if len(sys.argv) > 1 else None
            command = [str(helper)] if helper else [sys.executable, str(ROOT/"src/helpers/statement_helper.py")]
            result = subprocess.run(command + [str(pdf), str(settings)], capture_output=True, check=True)
            self.assertEqual(json.loads(result.stdout), {"parser": "santander-web-v1", "rows": [
                {"date": "2026-10-14", "amount": 40000, "payee": "TEST MARKET", "account": "1234", "category": "Food"}
            ]})
            pdf.write_bytes(b"%PDF-damaged")
            result = subprocess.run(command + [str(pdf), str(settings)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")


sys.path.insert(0, str(ROOT / "src/helpers"))
import bci_parser  # noqa: E402


class BciParserTest(unittest.TestCase):
    """BCI's rules, on the text and values its downloads hold (no customer PDFs)."""

    def test_documents_are_told_apart(self):
        self.assertEqual(bci_parser.detect("DETALLE MOVIMIENTOS TARJETA DE CRÉDITO\nTarjeta: Bci / Mastercard **** 2642"), "card")
        self.assertEqual(bci_parser.detect("CARTOLA DE CUENTA CORRIENTE\nFECHA SUCURSAL DESCRIPCION SALDO DIARIO"), "cartola")
        # Santander's cartola names its bank: it stays with the Santander parser.
        self.assertIsNone(bci_parser.detect("BANCO SANTANDER CHILE\nCARTOLA DE CUENTA CORRIENTE SALDO DIARIO"))
        self.assertIsNone(bci_parser.detect("ESTADO DE CUENTA EN MONEDA NACIONAL DE TARJETA DE CRÉDITO"))

    def test_amounts_dates_and_arrow_colours(self):
        self.assertEqual(bci_parser.amount_of("1.149.431"), 1149431)
        self.assertEqual(bci_parser.amount_of("$ 5.324"), 5324)
        self.assertIsNone(bci_parser.amount_of("1291663692"[:5] + ".12"))
        self.assertEqual(bci_parser.iso_date("5/10/2026"), "2026-10-05")
        self.assertIsNone(bci_parser.iso_date("31/13/2026"))
        # Average colours of BCI's arrows: orange charge, green credit.
        self.assertFalse(bci_parser.is_green((84, 46, 12)))
        self.assertTrue(bci_parser.is_green((30, 59, 31)))

    def test_internal_movements_and_owner_transfers(self):
        for desc in ("TRASPASO DESDE LINEA SOBREGIRO A CTA CTE", "AMORTIZACION LINEA DE SOBREGIRO", "PAGO AUTO SOBREGIRO 20541282",
                     "PAGO TARJETA DE CREDITO MASTERCARD", "PAC TARJETA DE CREDITO MASTERCARD", "PAGO DEUDA TARJETA DE CREDITO"):
            self.assertTrue(bci_parser.INTERNAL.search(desc), desc)
        for desc in ("PAG.DIV.088. CRED.HIPOTEC", "CARGO POR PAGO DE SERVICIOS", "IMPUESTO LINEA DE SOBREGIRO"):
            self.assertFalse(bci_parser.INTERNAL.search(desc), desc)
        owners = ["Sergio Marin"]
        self.assertTrue(bci_parser.is_owner_transfer("TRANSFER A S.MARIN ZAMBRA", owners))
        self.assertTrue(bci_parser.is_owner_transfer("TRANSFER A SERGIO MARIN", owners))
        self.assertFalse(bci_parser.is_owner_transfer("TRANSFER A ELENNI ZAMBRAN", owners))
        self.assertFalse(bci_parser.is_owner_transfer("TRANSFER A M.HERNANDEZ MA", owners))
        self.assertFalse(bci_parser.is_owner_transfer("CARGO POR PAGO DE SERVICIOS", owners))

    def test_cartola_summary_total(self):
        summary = "Saldo Anterior\n05-05-2026 al 18-08-\n262.890 - 45.413.736 + 45.150.846 = 0"
        self.assertEqual(bci_parser.cartola_total_charges(summary), 45413736)
        self.assertIsNone(bci_parser.cartola_total_charges("no summary"))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
