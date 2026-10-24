"""Use synthetic bank pages only, under Oriel scripts/headless.sh."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "src/helpers/santander_browser.py"
spec = importlib.util.spec_from_file_location("bank_browser", SCRIPT)
browser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(browser)
RESPONSE = {"METADATA": {"STATUS": "0"}, "DATA": {"Informacion": {"Codigo": "00"},
    "MatrizMovimientos": [{"Fecha": "19/10/2026", "Descripcion": "COMPRA NORMAL",
    "Comercio": "TEST SHOP", "Importe": "1.200", "IndicadorDebeHaber": "D"}]}}


class Fixture(http.server.BaseHTTPRequestHandler):
    requests = []
    idle_loaded = threading.Event()
    def log_message(self, *_): pass

    def do_GET(self):
        self.requests.append(self.path)
        self.send_response(200)
        if self.path.startswith(browser.ENDPOINT):
            self.send_header("Content-Type", "application/json")
            body = json.dumps(RESPONSE).encode()
        elif self.path == "/wrong-response":
            self.send_header("Content-Type", "application/json")
            body = b'{"not":"movements","secret":"not captured"}'
        else:
            self.send_header("Content-Type", "text/html")
            self.send_header("Set-Cookie", "test_session=not-exported; HttpOnly; SameSite=Strict")
            body = ("""<!doctype html><title>Synthetic bank</title>
            <input type="password" value="not-exported">
            <script>fetch('/wrong-response').then(() => fetch('""" + browser.ENDPOINT + """'));</script>""").encode()
        if self.path == "/?xhr":
            body = ("""<!doctype html><script>
              const xhr = new XMLHttpRequest();
              xhr.open('POST', '""" + browser.ENDPOINT + """');
              xhr.responseType = 'json'; xhr.send('{}');
            </script>""").encode()
        if self.path == "/idle":
            body = b"<!doctype html><title>Synthetic sign-in</title><p>Waiting for a human</p>"
            self.idle_loaded.set()
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


    do_POST = do_GET


class SantanderBrowserTest(unittest.TestCase):
    def test_bundled_bank_window_exits_with_its_owner(self):
        helper = os.environ.get("PENNY_BROWSER_HELPER")
        if not helper:
            self.skipTest("Requires the direct bundled executable, without a namespace wrapper")
        with open(helper, "rb") as executable:
            if executable.read(4) != b"\x7fELF":
                self.skipTest("Owner test requires an ELF executable, not a launch wrapper")
        Fixture.idle_loaded.clear()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        owner_code = "import subprocess,sys; child=subprocess.Popen(sys.argv[1:],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(child.pid,flush=True); child.wait()"
        owner = subprocess.Popen([sys.executable, "-c", owner_code, helper, "--santander", "--fixture-url", f"http://127.0.0.1:{server.server_port}/idle"], stdout=subprocess.PIPE, text=True)
        child = int(owner.stdout.readline())
        try:
            self.assertTrue(Fixture.idle_loaded.wait(10), "Bank window never loaded")
            owner.terminate()
            owner.wait(timeout=5)
            for _ in range(60):
                state = Path(f"/proc/{child}/stat")
                try:
                    dead = state.read_text().rsplit(")", 1)[1].split()[0] == "Z"
                except FileNotFoundError:
                    dead = True
                if dead:
                    break
                time.sleep(.05)
            else:
                self.fail("Owner exited but its bank browser remained running")
        finally:
            if owner.poll() is None:
                owner.terminate()
                owner.wait(timeout=5)
            owner.stdout.close()
            try:
                os.kill(child, 15)
            except ProcessLookupError:
                pass
            server.shutdown()
            server.server_close()
            thread.join()

    def test_navigation_and_endpoint_are_exact(self):
        self.assertTrue(browser.bank_url(browser.TARGET))
        for url in ["http://mibanco.santander.cl", "https://santander.cl.evil.test",
                    "https://santander.cl@evil.test", "file:///etc/passwd",
                    "https://mibanco.santander.cl:444"]:
            self.assertFalse(browser.bank_url(url))


    def test_real_webkit_fetch_response_without_login_material(self):
        self.capture("/")

    def test_real_webkit_xhr_json_response(self):
        self.capture("/?xhr")

    def capture(self, path):
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            command = [os.environ["PENNY_BROWSER_HELPER"], "--santander"] if os.environ.get("PENNY_BROWSER_HELPER") else ["/usr/bin/python3", str(SCRIPT)]
            result = subprocess.run([*command, "--fixture-url",
                                     f"http://127.0.0.1:{server.server_port}{path}"],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])
            self.assertEqual(json.loads(result.stdout), {"response": RESPONSE})
            self.assertNotIn("not-exported", result.stdout)
            self.assertNotIn("secret", result.stdout)
        except subprocess.TimeoutExpired as error:
            self.fail(f"Capture timed out, requests {Fixture.requests}: {error.stderr!r}")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
