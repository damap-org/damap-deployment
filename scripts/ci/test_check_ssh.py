"""Local fixtures for SSH diagnostics; no external network access required."""
import contextlib
import importlib.util
import io
from pathlib import Path
import socket
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("check_ssh", Path(__file__).with_name("check-ssh.py"))
check_ssh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_ssh)


class ConnectivityTests(unittest.TestCase):
    def run_fixture(self, response):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(3)
            address = listener.getsockname()

            def serve():
                with listener.accept()[0] as connection:
                    connection.settimeout(3)
                    if response is None:
                        connection.recv(1)  # Wait until the probe times out and closes.
                    else:
                        connection.sendall(response)

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            output = io.StringIO()
            try:
                with contextlib.redirect_stdout(output):
                    result = check_ssh.probe(socket.AF_INET, address, 0.2)
            finally:
                worker.join(timeout=4)
            self.assertFalse(worker.is_alive())
            return result, output.getvalue()

    def test_banner(self):
        result, output = self.run_fixture(b"SSH-2.0-test\r\n")
        self.assertTrue(result)
        self.assertIn("TCP CONNECTED", output)
        self.assertIn("SSH BANNER RECEIVED", output)

    def test_pre_banner(self):
        result, output = self.run_fixture(b"Welcome\r\nSSH-2.0-test\r\n")
        self.assertTrue(result)
        self.assertIn("SSH PRE-BANNER", output)

    def test_connected_but_silent(self):
        result, output = self.run_fixture(None)
        self.assertFalse(result)
        self.assertIn("SSH BANNER TIMEOUT", output)
        self.assertNotIn("TCP TIMEOUT", output)

    def test_peer_closes(self):
        result, output = self.run_fixture(b"")
        self.assertFalse(result)
        self.assertIn("SSH CLOSED", output)

    def test_tcp_failures(self):
        for error, expected in [(TimeoutError(), "TCP TIMEOUT"),
                                (ConnectionRefusedError(111, "Connection refused"), "TCP FAILED")]:
            with self.subTest(error=error), patch.object(check_ssh.socket, "socket") as factory:
                factory.return_value.__enter__.return_value.connect.side_effect = error
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    result = check_ssh.probe(socket.AF_INET, ("192.0.2.1", 22), 0.2)
                self.assertFalse(result)
                self.assertIn(expected, output.getvalue())
                self.assertNotIn("SSH BANNER WAIT", output.getvalue())

    def test_dns_failure(self):
        with patch.object(check_ssh.socket, "getaddrinfo", side_effect=socket.gaierror("No address")):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(check_ssh.check("invalid.example", 22, 1), 1)
            self.assertIn("DNS FAILED", output.getvalue())

    def test_one_reachable_address_is_enough(self):
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 22))
                     for ip in ("192.0.2.1", "192.0.2.2")]
        with patch.object(check_ssh.socket, "getaddrinfo", return_value=addresses), \
                patch.object(check_ssh, "probe", side_effect=[False, True]), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(check_ssh.check("example.test", 22, 1), 0)


if __name__ == "__main__":
    unittest.main()
