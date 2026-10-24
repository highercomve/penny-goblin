"""Actual private WebKit downloads against a loopback synthetic bank."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from boa_parser_test import CARD, CHECKING

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src/helpers"))
from bank_download_browser import bank_url
from boa_parser import parse


class Fixture(http.server.BaseHTTPRequestHandler):
    arrived = threading.Event()
    posted = threading.Event()

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.endswith(".csv"):
            body = CARD if "card" in self.path else CHECKING
            if "bad" in self.path:
                body = b"<html>Sign in again</html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/csv")
            self.send_header("Content-Disposition", "attachment; filename=activity.csv")
            Fixture.arrived.set()
        else:
            kind = self.path.strip("/") or "checking"
            body = f'''<!doctype html><input type=password value=DO_NOT_EXPORT>
              <a id=export href=/{kind}.csv download>Download</a>
              <script>setTimeout(()=>document.getElementById('export').click(),150)</script>'''.encode()
            if kind == "post":
                body = b'''<!doctype html><form id=export method=POST action=/card.csv target=_blank>
                  <input name=synthetic value=test></form><script>setTimeout(()=>document.getElementById('export').submit(),150)</script>'''
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Set-Cookie", "session=DO_NOT_EXPORT; HttpOnly")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        Fixture.posted.set()
        self.do_GET()


class BoaBrowserTest(unittest.TestCase):
    def test_bank_domains_are_separate_and_https_only(self):
        self.assertTrue(bank_url("https://secure.bankofamerica.com/login", "bankofamerica.com"))
        for url in ("https://bci.cl", "http://bankofamerica.com", "https://bankofamerica.com.evil.test",
                    "https://bankofamerica.com@evil.test", "https://bankofamerica.com:444"):
            self.assertFalse(bank_url(url, "bankofamerica.com"))

    def test_card_and_checking_and_post_popup_without_login_material(self):
        for kind in ("card", "checking", "post"):
            with self.subTest(kind=kind):
                self.capture(kind)

    def test_html_masquerading_as_csv_is_rejected_and_cancellable(self):
        self.capture("bad")

    def capture(self, kind):
        Fixture.arrived.clear()
        Fixture.posted.clear()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        command = [os.environ["PENNY_BROWSER_HELPER"], "--boa"] if os.environ.get("PENNY_BROWSER_HELPER") else [sys.executable, str(ROOT / "src/helpers/boa_browser.py")]
        process = subprocess.Popen([*command, "--fixture-url", f"http://127.0.0.1:{server.server_port}/{kind}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if kind == "bad":
                self.assertTrue(Fixture.arrived.wait(10))
                time.sleep(.3)
                self.assertIsNone(process.poll(), "Malformed CSV was accepted")
                process.terminate()
            output, error = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, error[-2000:])
            expected = {"error": "Cancelled"} if kind == "bad" else {"rows": parse(CHECKING if kind == "checking" else CARD)}
            self.assertEqual(json.loads(output), expected, error[-2000:])
            self.assertNotIn("DO_NOT_EXPORT", output)
            if kind == "post":
                self.assertTrue(Fixture.posted.is_set())
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
