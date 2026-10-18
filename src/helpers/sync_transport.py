"""Pinned TLS, one-time pairing and revocable device authentication.

All financial mutations go through the shared Zig worker over private pipes.
This helper never implements expense validation or synchronization semantics.
A paired phone may also hand this desktop a voucher to scan (/v1/scan): the
app's own scanner reads it in a worker process, and only its fields go back.
"""
import argparse
import base64
import collections
import datetime
import hashlib
import hmac
import http.server
import io
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import sqlite3
import ssl
import subprocess
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
import qrcode
from zeroconf import ServiceInfo, Zeroconf

PORT = 57443
MAX_BYTES = 64 * 1024 * 1024
MAX_SCAN_BYTES = 24 * 1024 * 1024
# Errors a phone may see from a scan: it scans on its own after any of them.
SCAN_ERRORS = {"ScannerNotSetUp", "ModelNotDownloaded", "ModelNotImported", "SystemModelNotReady", "DesktopScannerBusy"}
ID = re.compile(r"[0-9a-f]{64}\Z")


def private_write(path, content):
    temporary = path.with_suffix(path.suffix + ".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def worker(executable, database, payload):
    result = subprocess.run([str(executable), "--sync-worker", str(database)],
                            input=json.dumps(payload, separators=(",", ":")).encode(),
                            capture_output=True, timeout=90)
    if result.returncode or len(result.stdout) > MAX_BYTES:
        raise ValueError("SyncWorkerFailed")
    reply = json.loads(result.stdout)
    if not reply.get("ok"):
        raise ValueError(reply.get("err", "SyncWorkerFailed"))
    return reply["value"]


# One scan at a time: each loads a model of a few GB.
scanning = threading.Lock()


def scan(executable, data_url):
    """A paired phone's voucher read by this desktop's own scanner."""
    if not isinstance(data_url, str) or not data_url.startswith("data:image/"):
        raise ValueError("InvalidScanRequest")
    if not scanning.acquire(blocking=False):
        raise ValueError("DesktopScannerBusy")
    try:
        result = subprocess.run([str(executable), "--scan-worker"],
                                input=json.dumps({"data_url": data_url}, separators=(",", ":")).encode(),
                                capture_output=True, timeout=300)
    finally:
        scanning.release()
    if result.returncode or len(result.stdout) > 1024 * 1024:
        raise ValueError("ScanWorkerFailed")
    reply = json.loads(result.stdout)
    if not reply.get("ok"):
        raise ValueError(reply.get("err", "ScanWorkerFailed"))
    return reply["value"]


class ResearchJobs:
    """Paired-device-owned previews; one remote model/scan worker at a time."""
    def __init__(self, executable, database):
        self.executable, self.database = executable, database
        self.lock = threading.RLock()
        self.jobs = {}

    def model(self):
        result = subprocess.run([str(self.executable), "--research-worker", str(self.database)],
            input=b'{"action":"status"}\n', capture_output=True, timeout=30)
        reply = json.loads(result.stdout)
        if result.returncode or reply.get("kind") != "status":
            raise ValueError(reply.get("error", "ResearchWorkerFailed"))
        return reply["value"]

    def handle(self, owner, value):
        action = value.get("action")
        if action == "model":
            result = self.model()
            with self.lock:
                job = self.jobs.get(owner)
                if job and job["state"] in ("running", "ready"):
                    result["label"] += " · Desktop job available; Research resumes it"
            return result
        with self.lock:
            job = self.jobs.get(owner)
            if action == "start":
                ids = value.get("ids")
                if not isinstance(ids, list) or not 1 <= len(ids) <= 10000 or any(not isinstance(i, str) or not ID.fullmatch(i) for i in ids):
                    raise ValueError("InvalidSelection")
                resume = job and (job["state"] == "running" or (job["state"] == "ready" and
                    any(t["id"] in ids for p in job["review"]["proposals"] for t in p["targets"])))
                if not resume:
                    if not scanning.acquire(blocking=False):
                        raise ValueError("DesktopScannerBusy")
                    try:
                        # Bounded retention; keep active jobs and recent reviews.
                        for key, old in list(self.jobs.items()):
                            if old["state"] != "running" and time.monotonic() - old["created"] > 3600:
                                del self.jobs[key]
                        if len(self.jobs) >= 16 and owner not in self.jobs:
                            raise ValueError("ResearchJobsFull")
                        job = {"job": secrets.token_hex(16), "state": "running", "events": [], "review": None,
                               "error": "", "process": None, "created": time.monotonic(), "count": 0}
                        self.jobs[owner] = job
                        # The persistent job thread owns the worker. Linux parent-death
                        # signals follow the spawning thread, not only its process.
                        threading.Thread(target=self.launch, args=(job, ids), daemon=True).start()
                    except Exception:
                        if job and job.get("process") and job["state"] == "running":
                            self.kill(job)
                        scanning.release()
                        raise
            elif not job or value.get("job") != job["job"]:
                raise ValueError("ResearchJobNotFound")
            elif action == "cancel":
                if job["state"] == "running":
                    job["state"] = "cancelled"
                    self.kill(job)
            elif action == "apply":
                payload = value.get("edit")
                fingerprint = json.dumps(payload, sort_keys=True)
                if job["state"] == "applied" and fingerprint == job.get("applied"):
                    return {"count": job["count"]}
                if job["state"] != "ready" or not isinstance(payload, dict):
                    raise ValueError("ResearchNotReady")
                review = job["review"]
                if payload.get("expected_settings") != review["expected_settings"]:
                    raise ValueError("SettingsConflict")
                choices = payload.get("selections")
                if not isinstance(choices, list) or not 1 <= len(choices) <= 10:
                    raise ValueError("InvalidSelection")
                for choice in choices:
                    if not isinstance(choice, dict) or not any(choice.get("targets") == p["targets"] for p in review["proposals"]):
                        raise ValueError("InvalidSelection")
                count = worker(self.executable, self.database, {"action":"research_apply", "edit":payload})
                job.update(state="applied", count=count, applied=fingerprint)
                return {"count": count}
            elif action != "poll":
                raise ValueError("InvalidResearchAction")
            after = value.get("after", 0)
            if type(after) is not int or not 0 <= after <= 256:
                raise ValueError("InvalidResearchAction")
            return {key:job[key] for key in ("job", "state", "review", "error")} | {"events":job["events"][after:], "next":len(job["events"])}

    def launch(self, job, ids):
        try:
            with self.lock:
                if job["state"] != "running":
                    scanning.release()
                    return
                process = subprocess.Popen([str(self.executable), "--research-worker", str(self.database)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
                job["process"] = process
                process.stdin.write(json.dumps({"action":"start", "ids":ids}).encode() + b"\n")
                process.stdin.close()
            threading.Thread(target=self.deadline, args=(job,), daemon=True).start()
        except Exception:
            with self.lock:
                job.update(state="error", error="ResearchWorkerFailed")
                self.kill(job)
            if job["process"]:
                job["process"].wait(timeout=10)
                job["process"].stdout.close()
                if job["process"].stdin: job["process"].stdin.close()
            scanning.release()
            return
        self.consume(job)

    @staticmethod
    def kill(job, hard=False):
        """The worker and, on POSIX, its process group (browser descendants)."""
        if job["process"] is None: return
        try:
            if hasattr(os, "killpg"): os.killpg(job["process"].pid, signal.SIGKILL if hard else signal.SIGTERM)
            else: job["process"].kill()
        except ProcessLookupError: pass

    def deadline(self, job):
        try: job["process"].wait(timeout=23 * 60)
        except subprocess.TimeoutExpired:
            with self.lock:
                if job["state"] == "running":
                    job.update(state="error", error="ResearchTimeLimit")
                    self.kill(job)

    def consume(self, job):
        try:
            while True:
                line = job["process"].stdout.readline(2 * 1024 * 1024 + 1)
                if not line: break
                if len(line) > 2 * 1024 * 1024: raise ValueError("ResearchWorkerFailed")
                message = json.loads(line)
                with self.lock:
                    if job["state"] != "running": continue
                    if message["kind"] == "progress" and len(job["events"]) < 256:
                        job["events"].append(message["value"])
                    elif message["kind"] == "review": job.update(state="ready", review=message["value"])
                    elif message["kind"] == "error": job.update(state="error", error=message["error"])
            job["process"].wait(timeout=15)
        except Exception:
            with self.lock:
                if job["state"] == "running": job.update(state="error", error="ResearchWorkerFailed")
            self.kill(job)
        finally:
            with self.lock:
                if job["state"] == "running": job.update(state="error", error="ResearchWorkerFailed")
            # Also reap any browser descendants before another model can start.
            self.kill(job)
            try: job["process"].wait(timeout=10)
            except subprocess.TimeoutExpired: self.kill(job, hard=True); job["process"].wait()
            job["process"].stdout.close()
            scanning.release()


class Identity:
    def __init__(self, directory, executable, database):
        self.directory = Path(directory)
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.executable, self.database = executable, database
        self.server_id = worker(executable, database, {"action": "identity"})["device_id"]
        self.cert = self.directory / "certificate.pem"
        self.key = self.directory / "private-key.pem"
        if not self.cert.exists() and not self.key.exists():
            self.create_certificate()
        # A missing half of an existing identity fails; it must not silently
        # generate a replacement identity trusted by already-paired phones.
        certificate = x509.load_pem_x509_certificate(self.cert.read_bytes())
        self.pin = certificate.fingerprint(hashes.SHA256()).hex()
        with self.auth() as db:
            db.executescript("""CREATE TABLE IF NOT EXISTS devices(
              id TEXT PRIMARY KEY,label TEXT NOT NULL,token_hash TEXT NOT NULL,
              revoked INTEGER NOT NULL DEFAULT 0,last_seen INTEGER NOT NULL DEFAULT 0);
              CREATE TABLE IF NOT EXISTS pairing(id INTEGER PRIMARY KEY CHECK(id=1),hash TEXT NOT NULL,expires INTEGER NOT NULL);
              CREATE TABLE IF NOT EXISTS pairing_receipts(hash TEXT PRIMARY KEY,device_id TEXT NOT NULL,token_hash TEXT NOT NULL,expires INTEGER NOT NULL);
            """)

    def auth(self):
        path = self.directory / "devices.sqlite3"
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        os.close(fd)
        return sqlite3.connect(path, timeout=10)

    def create_certificate(self):
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Penny Goblin desktop")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(minutes=5))
                .not_valid_after(now + datetime.timedelta(days=1825))
                .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost")]), critical=False)
                .sign(key, hashes.SHA256()))
        private_write(self.key, key.private_bytes(serialization.Encoding.PEM,
                      serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        private_write(self.cert, cert.public_bytes(serialization.Encoding.PEM))

    def routes(self):
        addresses = []
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.connect(("8.8.8.8", 80))
                addresses.append(sock.getsockname()[0])
        except OSError:
            pass
        try:
            result = subprocess.run(["tailscale", "status", "--self", "--json"], capture_output=True, timeout=3)
            if result.returncode == 0:
                value = json.loads(result.stdout)
                if value.get("BackendState") == "Running":
                    addresses.extend(ip for ip in value.get("TailscaleIPs", []) if ":" not in ip)
                    name = value.get("Self", {}).get("DNSName", "").rstrip(".")
                    if name:
                        addresses.append(name)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            pass
        return [f"https://{address}:{PORT}" for address in dict.fromkeys(addresses) if address != "127.0.0.1"]

    def pairing(self):
        secret = secrets.token_urlsafe(32)
        expires = int(time.time()) + 120
        with self.auth() as db:
            db.execute("INSERT OR REPLACE INTO pairing VALUES(1,?,?)", (hashlib.sha256(secret.encode()).hexdigest(), expires))
        data = {"version": 1, "server_id": self.server_id, "pin": self.pin, "endpoints": self.routes(), "secret": secret}
        if not data["endpoints"]:
            raise ValueError("NoNetworkAddress")
        encoded = base64.urlsafe_b64encode(json.dumps(data, separators=(",", ":")).encode()).decode().rstrip("=")
        link = "pennygoblin://pair?data=" + encoded
        png = io.BytesIO()
        qrcode.make(link).save(png, format="PNG")
        return {"link": link, "qr": "data:image/png;base64," + base64.b64encode(png.getvalue()).decode(), "expires": expires}

    def redeem(self, value):
        device_id, secret, label = value.get("device_id", ""), value.get("secret", ""), value.get("label", "Phone")
        if not ID.fullmatch(device_id) or device_id == self.server_id or not isinstance(secret, str) or len(secret) > 128 or not isinstance(label, str) or not 1 <= len(label) <= 80:
            raise ValueError("InvalidPairing")
        token_hash = value.get("token_hash", "")
        if not isinstance(token_hash, str) or not ID.fullmatch(token_hash):
            raise ValueError("InvalidPairing")
        secret_hash = hashlib.sha256(secret.encode()).hexdigest()
        with self.auth() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT r.device_id,r.token_hash,r.expires,d.revoked,d.token_hash FROM pairing_receipts r JOIN devices d ON d.id=r.device_id WHERE r.hash=?", (secret_hash,)).fetchone()
            if previous:
                if previous[0] == device_id and hmac.compare_digest(previous[1], token_hash) and previous[2] >= time.time() and not previous[3] and hmac.compare_digest(previous[4], token_hash):
                    return {"version": 1, "server_id": self.server_id, "credential_ack": True}
                raise ValueError("PairingExpiredOrInvalid")
            row = db.execute("SELECT hash,expires FROM pairing WHERE id=1").fetchone()
            if not row or row[1] < time.time() or not hmac.compare_digest(row[0], secret_hash):
                raise ValueError("PairingExpiredOrInvalid")
            db.execute("DELETE FROM pairing")
            db.execute("DELETE FROM pairing_receipts WHERE expires<?", (int(time.time()),))
            db.execute("INSERT INTO pairing_receipts VALUES(?,?,?,?)", (secret_hash, device_id, token_hash, row[1]))
            db.execute("INSERT OR REPLACE INTO devices(id,label,token_hash) VALUES(?,?,?)", (device_id, label, token_hash))
        return {"version": 1, "server_id": self.server_id, "credential_ack": True}

    def authenticate(self, header):
        if not header.startswith("Bearer "):
            return None
        token = header[7:]
        if not re.fullmatch(r"[0-9a-f]{64}\.[A-Za-z0-9_-]{43}", token):
            return None
        device = token.split(".", 1)[0]
        with self.auth() as db:
            row = db.execute("SELECT token_hash FROM devices WHERE id=? AND revoked=0", (device,)).fetchone()
        return device if row and hmac.compare_digest(row[0], hashlib.sha256(token.encode()).hexdigest()) else None

    def status(self):
        running = False
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE  # Exact certificate pin below.
            with socket.create_connection(("127.0.0.1", PORT), timeout=2) as raw:
                with context.wrap_socket(raw, server_hostname="localhost") as stream:
                    running = hmac.compare_digest(hashlib.sha256(stream.getpeercert(binary_form=True)).hexdigest(), self.pin)
        except OSError:
            pass
        with self.auth() as db:
            devices = [{"id": row[0], "label": row[1], "revoked": bool(row[2]), "last_seen": row[3]} for row in db.execute("SELECT id,label,revoked,last_seen FROM devices ORDER BY label")]
        return {"running": running, "server_id": self.server_id, "endpoints": self.routes(), "devices": devices}


class RateLimit:
    def __init__(self):
        self.lock = threading.Lock()
        self.attempts = collections.deque()

    def allow(self, address):
        with self.lock:
            now = time.monotonic()
            while self.attempts and self.attempts[0][0] < now - 60:
                self.attempts.popleft()
            if len(self.attempts) >= 20 or sum(ip == address for _, ip in self.attempts) >= 5:
                return False
            self.attempts.append((now, address))
            return True


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "PennyGoblin"

    def log_message(self, *args):
        pass  # Never log credentials, pairing material or financial bodies.

    def send_json(self, code, value):
        data = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_json(404, {"error": "NotFound"})

    def do_POST(self):
        identity = self.server.identity
        if self.path not in ("/v1/pair", "/v1/sync", "/v1/scan", "/v1/research"):
            return self.send_json(404, {"error": "NotFound"})
        if sum(len(k) + len(v) for k, v in self.headers.items()) > 8192 or self.headers.get("Transfer-Encoding"):
            return self.send_json(400, {"error": "InvalidHeaders"})
        device = None
        if self.path in ("/v1/sync", "/v1/scan", "/v1/research"):
            device = identity.authenticate(self.headers.get("Authorization", ""))
            if not device:
                return self.send_json(401, {"error": "DeviceNotAuthorized"})
        elif not self.server.rate.allow(self.client_address[0]):
            return self.send_json(429, {"error": "PairingRateLimited"})
        try:
            length = int(self.headers.get("Content-Length", "-1"))
            maximum = 2 * 1024 * 1024 if self.path == "/v1/research" else 4096 if self.path == "/v1/pair" else MAX_SCAN_BYTES if self.path == "/v1/scan" else MAX_BYTES
            if length < 1 or length > maximum or not self.headers.get("Content-Type", "").startswith("application/json"):
                return self.send_json(413, {"error": "InvalidBodySize"})
            data = self.rfile.read(length)
            if len(data) != length:
                return self.send_json(400, {"error": "IncompleteRequest"})
            value = json.loads(data)
            if not isinstance(value, dict):
                raise ValueError("InvalidRequest")
            if self.path == "/v1/pair":
                result = identity.redeem(value)
            elif self.path == "/v1/research":
                if value.get("device_id") != device:
                    return self.send_json(403, {"error": "WrongDeviceIdentity"})
                result = self.server.research.handle(device, value)
            elif self.path == "/v1/scan":
                if value.get("device_id") != device:
                    return self.send_json(403, {"error": "WrongDeviceIdentity"})
                result = {"extraction": scan(identity.executable, value.get("data_url"))}
            else:
                if value.get("device_id") != device:
                    return self.send_json(403, {"error": "WrongDeviceIdentity"})
                result = worker(identity.executable, identity.database, {"action": "exchange", "request": value})
                with identity.auth() as db:
                    db.execute("UPDATE devices SET last_seen=? WHERE id=?", (int(time.time()), device))
            return self.send_json(200, result)
        except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
            code = str(error)
            allowed = {"SyncRecoveryRequired", "PairingExpiredOrInvalid", "InvalidPairing", "ReusedOperationId"} | SCAN_ERRORS | {"ResearchJobNotFound", "ResearchNotReady", "ResearchJobsFull", "InvalidSelection", "InvalidResearchAction", "RevisionConflict", "SettingsConflict", "InvalidCategory", "CategorizationModelRequired", "DesktopResearchUnavailable", "NoCategories"}
            status = 409 if code == "SyncRecoveryRequired" else 429 if code == "DesktopScannerBusy" else 400
            return self.send_json(status, {"error": code if code in allowed else "RequestRejected"})


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, identity):
        self.identity = identity
        self.research = ResearchJobs(identity.executable, identity.database)
        self.rate = RateLimit()
        self.slots = threading.BoundedSemaphore(4)
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls.minimum_version = ssl.TLSVersion.TLSv1_2
        self.tls.load_cert_chain(identity.cert, identity.key)
        super().__init__(("0.0.0.0", PORT), Handler)

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(10)
        try:
            return self.tls.wrap_socket(sock, server_side=True), address
        except Exception:
            sock.close()
            raise

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            return self.shutdown_request(request)
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def handle_error(self, *args):
        pass


def serve(identity):
    server = Server(identity)
    discovery = None
    try:
        addresses = []
        for route in identity.routes():
            host = route.removeprefix("https://").split(":")[0]
            try:
                address = socket.inet_aton(host)
                if not host.startswith("100."):
                    addresses.append(address)
            except OSError:
                pass
        if addresses:
            try:
                discovery = Zeroconf()
                info = ServiceInfo("_pennygoblin._tcp.local.", "PennyGoblin-" + identity.server_id[:8] + "._pennygoblin._tcp.local.",
                                   addresses=addresses, port=PORT, properties={"id": identity.server_id},
                                   server="penny-" + identity.server_id[:8] + ".local.")
                discovery.register_service(info)
            except OSError:
                if discovery:
                    discovery.close()
                discovery = None  # Saved LAN/Tailscale routes still work.
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        if discovery:
            discovery.close()


def main(arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["serve", "pair", "status", "revoke"])
    parser.add_argument("directory")
    parser.add_argument("executable")
    parser.add_argument("database")
    parser.add_argument("--device", default="")
    args = parser.parse_args(arguments)
    identity = Identity(args.directory, args.executable, args.database)
    if args.mode == "serve":
        serve(identity)
        return
    if args.mode == "pair":
        result = identity.pairing()
    elif args.mode == "revoke":
        if not ID.fullmatch(args.device):
            raise ValueError("InvalidDevice")
        with identity.auth() as db:
            db.execute("UPDATE devices SET revoked=1 WHERE id=?", (args.device,))
        result = {"revoked": True}
    else:
        result = identity.status()
    print(json.dumps(result, separators=(",", ":")))
