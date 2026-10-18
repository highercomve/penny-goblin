import importlib.util
from pathlib import Path
import socket
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "src/helpers/research_network.py"
spec = importlib.util.spec_from_file_location("research_network", path)
network = importlib.util.module_from_spec(spec)
spec.loader.exec_module(network)


class NetworkBoundaryTest(unittest.TestCase):
    def test_resolved_private_or_mixed_addresses_are_rejected(self):
        for addresses in (("127.0.0.1",), ("::1",), ("10.0.0.5",), ("169.254.169.254",), ("8.8.8.8", "192.168.1.1")):
            with self.subTest(addresses=addresses), patch.object(socket, "getaddrinfo", return_value=[(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443)) for address in addresses]):
                with self.assertRaises(ValueError): network.public_addresses("merchant.invalid")
        with patch.object(socket, "getaddrinfo", return_value=[(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("8.8.8.8", 443))]):
            self.assertEqual(network.public_addresses("merchant.invalid"), ["8.8.8.8"])

    def test_real_proxy_rejects_local_network_and_plaintext(self):
        proxy = network.Proxy()
        try:
            for request in (b"CONNECT 127.0.0.1:443 HTTP/1.1", b"CONNECT [::1]:443 HTTP/1.1", b"CONNECT 8.8.8.8:80 HTTP/1.1", b"GET http://127.0.0.1/ HTTP/1.1"):
                with self.subTest(request=request), socket.create_connection(proxy.server_address, timeout=3) as client:
                    client.sendall(request + b"\r\nHost: ignored\r\n\r\n")
                    self.assertTrue(client.recv(4096).startswith(b"HTTP/1.1 403"))
        finally: proxy.close()


if __name__ == "__main__": unittest.main()
