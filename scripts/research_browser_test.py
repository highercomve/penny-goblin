"""Exercise the real WebKit subprocess on a private X display and test server."""
import http.server
import json
import os
from pathlib import Path
import select
import subprocess
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Fixture(http.server.BaseHTTPRequestHandler):
    stalled = threading.Event()
    release = threading.Event()

    def do_GET(self):
        if self.path == "/stall":
            self.stalled.set()
            self.release.wait(30)
            body = "Late response"
        elif self.path == "/second":
            body = "<title>Merchant evidence</title><main>Example Merchant sells sports equipment.</main>"
        elif self.path == "/delayed":
            body = "<script>setTimeout(() => document.body.innerText = 'Delayed merchant evidence', 400)</script>"
        elif self.path == "/blocked":
            body = '<title>Verify</title><form id="captcha-form">Please verify you are human.</form>'
        else:
            body = """<title>Research fixture</title><main id="content"></main>
              <div style="display:none">INVISIBLE_SECRET</div>
              <script>document.getElementById('content').innerHTML =
              '<h1>JavaScript merchant result</h1><a href="/second">Merchant website</a>' +
              '<a href="/blocked">Challenge page</a><a href="/delayed">Delayed page</a><a href="/stall">Slow page</a>' + '<p>' + 'e'.repeat(17000) + '</p>';</script>"""
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def log_message(self, *_):
        pass


class ResearchBrowserTest(unittest.TestCase):
    def test_bundled_runtime_has_tls(self):
        helper = os.environ.get("PENNY_BROWSER_HELPER")
        if not helper:
            self.skipTest("Requires the packaged browser")
        result = subprocess.run([helper, "--check-runtime"], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"tls": True})

    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        cls.worker = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.worker.start()
        read_fd, write_fd = os.pipe()
        command = [os.environ["PENNY_BROWSER_HELPER"], "--research"] if os.environ.get("PENNY_BROWSER_HELPER") else ["/usr/bin/python3", str(ROOT / "src/helpers/research_browser.py")]
        cls.process = subprocess.Popen([
            "dbus-run-session", "--", "xvfb-run", "-a", "-s", "-screen 0 1920x1080x24", "bash", "-c",
            f'exec "$@" >&{write_fd}', "bash", *command, "--fixture-url",
            f"http://127.0.0.1:{cls.server.server_port}/",
        ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            pass_fds=(write_fd,),
            env={**os.environ, "GSK_RENDERER": "cairo", "GDK_BACKEND": "x11", "GTK_A11Y": "none"})
        os.close(write_fd)
        cls.output = os.fdopen(read_fd, "rb", buffering=0)

    @classmethod
    def tearDownClass(cls):
        Fixture.release.set()
        cls.process.stdin.close()
        try:
            cls.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.process.kill()
            cls.process.wait()
        stderr = cls.process.stderr.read().decode(errors="replace")
        cls.output.close()
        cls.process.stderr.close()
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join()
        if cls.process.returncode:
            raise AssertionError(stderr)

    def request(self, **request):
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        self.process.stdin.flush()
        return self.response(request.get("id"))

    def response(self, request_id):
        if not select.select([self.output], [], [], 35)[0]:
            self.fail("WebKit protocol timed out")
        line = self.output.readline()
        self.assertTrue(line, "WebKit subprocess exited")
        reply = json.loads(line)
        self.assertEqual(reply["id"], request_id)
        return reply

    def test_javascript_snapshot_follow_stale_page_and_challenge(self):
        first = self.request(id=1, tool="fixture")
        self.assertTrue(first["ok"], first)
        page = first["result"]
        self.assertEqual(page["state"], "ready")
        self.assertIn("JavaScript merchant result", page["text"])
        self.assertNotIn("INVISIBLE_SECRET", page["text"])
        self.assertEqual(len(page["text"]), 16000)
        self.assertEqual(len(page["links"]), 4)
        self.assertEqual(self.request(id=2, tool="read_page", page_id=page["page_id"])["result"], page)
        second = self.request(id=3, tool="follow_link", page_id=page["page_id"], link=0)
        self.assertTrue(second["ok"], second)
        self.assertIn("sells sports equipment", second["result"]["text"])
        stale = self.request(id=4, tool="follow_link", page_id=page["page_id"], link=0)
        self.assertEqual(stale["error"], "StalePage")
        first = self.request(id=5, tool="fixture")["result"]
        challenge = self.request(id=6, tool="follow_link", page_id=first["page_id"], link=1)
        self.assertEqual(challenge["result"]["state"], "blocked")
        self.assertEqual(self.request(id=7, tool="eval", script="alert(1)")["error"], "UnknownTool")
        self.assertEqual(self.request(id=8, tool="search", query="x" * 241)["error"], "InvalidQuery")
        first = self.request(id=9, tool="fixture")["result"]
        self.assertEqual(self.request(id=10, tool="follow_link", page_id=first["page_id"], link=-1)["error"], "InvalidLink")
        delayed = self.request(id=11, tool="follow_link", page_id=first["page_id"], link=2)
        self.assertIn("Delayed merchant evidence", delayed["result"]["text"])
        first = self.request(id=12, tool="fixture")["result"]
        self.process.stdin.write(json.dumps({"id": 13, "tool": "follow_link", "page_id": first["page_id"], "link": 3}).encode() + b"\n")
        self.process.stdin.flush()
        self.assertTrue(Fixture.stalled.wait(5), "Expected a pending browser request")
        self.process.stdin.write(b'{"id":14,"tool":"cancel"}\n')
        self.process.stdin.flush()
        self.assertEqual(self.response(13)["error"], "Cancelled")
        self.assertTrue(self.response(14)["result"]["cancelled"])
        Fixture.release.set()
        self.assertTrue(self.request(id=15, tool="fixture")["ok"])
        self.assertFalse(self.request(id=16, tool="cancel")["result"]["cancelled"])


if __name__ == "__main__":
    unittest.main()
