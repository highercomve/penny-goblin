"""Real isolated WebKit downloads against synthetic BCI card/cartola PDFs."""
import base64
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from bci_fixtures import pdf

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src/helpers"))
SCRIPT = ROOT / "src/helpers/bci_browser.py"
spec = importlib.util.spec_from_file_location("bci_browser", SCRIPT)
browser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(browser)


class Fixture(http.server.BaseHTTPRequestHandler):
    post_received = threading.Event()
    bad_received = threading.Event()
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        if self.path.endswith(".pdf"):
            body = b"NOT A PDF" if self.path == "/bad.pdf" else pdf(card="card" in self.path)
            if self.path == "/bad.pdf":
                self.bad_received.set()
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Disposition", "attachment; filename=movements.pdf")
        else:
            kind = "card" if self.path == "/card" else "checking"
            body = f"""<!doctype html><title>Synthetic BCI</title>
                <input type=password value=DO_NOT_EXPORT>
                <a id=download href=/{kind}.pdf download>Download movements</a>
                <script>setTimeout(()=>document.getElementById('download').click(),150)</script>""".encode()
            self.send_header("Content-Type", "text/html")
            self.send_header("Set-Cookie", "session=DO_NOT_EXPORT; HttpOnly")
            if self.path == "/post":
                body = b"<!doctype html><form id=export method=POST action=/card.pdf target=_blank><input name=synthetic value=test></form><script>setTimeout(()=>document.getElementById('export').submit(),150)</script>"
            if self.path == "/bad":
                body = b"<!doctype html><a id=download href=/bad.pdf download>Download</a><script>setTimeout(()=>document.getElementById('download').click(),150)</script>"
            if self.path in ("/blob", "/data", "/data-attachment", "/data-octet", "/data-popup"):
                encoded = base64.b64encode(pdf(card=True)).decode("ascii")
                mime = "attachment/file" if self.path == "/data-attachment" else "application/octet-stream" if self.path == "/data-octet" else "application/pdf"
                href = f"'data:{mime};base64,{encoded}'" if self.path != "/blob" else f"URL.createObjectURL(new Blob([Uint8Array.from(atob('{encoded}'),c=>c.charCodeAt(0))],{{type:'application/pdf'}}))"
                body = f"<!doctype html><script>setTimeout(()=>{{let a=document.createElement('a');a.href={href};a.download='movements.pdf';document.body.append(a);a.click();}},150)</script>".encode()
                if self.path == "/data-popup":
                    body = f"<!doctype html><script>setTimeout(()=>window.open({href},'_blank'),150)</script>".encode()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.post_received.set()
        self.do_GET()


class BciBrowserTest(unittest.TestCase):
    def test_bci_navigation_is_restricted_to_https_bank_domains(self):
        self.assertTrue(browser.bank_url(browser.LOGIN))
        self.assertTrue(browser.bank_url("https://banco.bci.cl/movements"))
        for url in ("http://bci.cl", "https://bci.cl.evil.test", "https://bci.cl@evil.test", "file:///etc/passwd", "https://bci.cl:444"):
            self.assertFalse(browser.bank_url(url))

    def test_download_card_pdf_without_login_material(self):
        self.capture("card")

    def test_download_checking_pdf_without_login_material(self):
        self.capture("checking")

    def test_browser_generated_blob_pdf(self):
        self.capture("blob")

    def test_browser_generated_data_pdf(self):
        for kind in ("data", "data-attachment", "data-octet", "data-popup"):
            with self.subTest(kind=kind):
                self.capture(kind)

    def test_post_popup_preserves_its_method_and_private_session(self):
        Fixture.post_received.clear()
        self.capture("post")
        self.assertTrue(Fixture.post_received.is_set(), "Bank export POST was converted to a GET")

    def test_invalid_pdf_stays_in_review_and_can_be_cancelled(self):
        Fixture.bad_received.clear()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        command = [os.environ["PENNY_BROWSER_HELPER"], "--bci"] if os.environ.get("PENNY_BROWSER_HELPER") else ["/usr/bin/python3", str(SCRIPT)]
        process = subprocess.Popen([*command, "--fixture-url", f"http://127.0.0.1:{server.server_port}/bad"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(Fixture.bad_received.wait(10), "Synthetic download did not start")
            time.sleep(.3)
            self.assertIsNone(process.poll(), "Invalid PDF was accepted or closed the browser")
            process.terminate()
            output, error = process.communicate(timeout=5)
            self.assertEqual(json.loads(output), {"error": "Cancelled"}, error[-1000:])
        finally:
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=5)
            server.shutdown()
            server.server_close()
            thread.join()

    def capture(self, kind):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            command = [os.environ["PENNY_BROWSER_HELPER"], "--bci"] if os.environ.get("PENNY_BROWSER_HELPER") else ["/usr/bin/python3", str(SCRIPT)]
            result = subprocess.run([*command, "--fixture-url", f"http://127.0.0.1:{server.server_port}/{kind}"], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])
            reply = json.loads(result.stdout)
            self.assertIn("pdf_base64", reply, (reply, result.stderr[-2000:]))
            self.assertEqual(base64.b64decode(reply["pdf_base64"]), pdf(kind in ("card", "post", "blob") or kind.startswith("data")))
            self.assertNotIn("DO_NOT_EXPORT", result.stdout)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
