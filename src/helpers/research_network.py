"""Public HTTPS-only egress for the research WebKit session.

CONNECT resolves and pins a public address before tunnelling TLS. Browser
cookies and certificate verification stay in WebKit; private networks and
plaintext HTTP are never proxy destinations.
"""
import ipaddress
import select
import socket
import socketserver
import threading


def public_addresses(host):
    addresses = list(dict.fromkeys(row[4][0] for row in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)))
    if not addresses or any(not ipaddress.ip_address(ip).is_global for ip in addresses):
        raise ValueError("Private destination")
    return addresses


class Tunnel(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(10)
        first = self.rfile.readline(4097)
        if len(first) > 4096:
            return
        try:
            method, target, version = first.decode("ascii").strip().split()
            host, port = target.rsplit(":", 1)
            host = host.strip("[]")
            if method != "CONNECT" or port != "443" or version not in ("HTTP/1.0", "HTTP/1.1"):
                raise ValueError("HTTPS only")
            for _ in range(100):
                header = self.rfile.readline(4097)
                if len(header) > 4096:
                    raise ValueError("Header too large")
                if header in (b"\r\n", b"\n"):
                    break
            else:
                raise ValueError("Too many headers")
            addresses = public_addresses(host)
            remote = socket.create_connection((addresses[0], 443), timeout=10)
        except (ValueError, UnicodeError, OSError):
            self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        with remote:
            self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            self.wfile.flush()
            streams = (self.connection, remote)
            try:
                # Idle tunnels expire; every resource remains public and TLS.
                while True:
                    readable, _, _ = select.select(streams, [], [], 30)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (remote if source is self.connection else self.connection).sendall(data)
            except OSError:
                return


class Proxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self):
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(("127.0.0.1", 0), Tunnel)
        self.worker = threading.Thread(target=self.serve_forever, daemon=True)
        self.worker.start()

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()

    def close(self):
        self.shutdown()
        self.server_close()
        self.worker.join()
