"""Exercise the installer with real curl and a local, failure-injecting server."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import os
from pathlib import Path
import re
import socket
import subprocess
import tarfile
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).parents[1] / "install_github_mcp_server.sh"


class GitHubMCPInstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="nativ-mcp-installer-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "app resources"
        self.archive = io.BytesIO()
        with tarfile.open(fileobj=self.archive, mode="w:gz") as archive:
            for name, content, mode in [
                ("github-mcp-server", b"#!/bin/sh\nprintf fixture\\n\n", 0o755),
                ("LICENSE", b"Fixture license\n", 0o644),
            ]:
                entry = tarfile.TarInfo(name)
                entry.size, entry.mode = len(content), mode
                archive.addfile(entry, io.BytesIO(content))
        self.payload = self.archive.getvalue()
        checksum = hashlib.sha256(self.payload).hexdigest()
        # The fixture is pinned just like the release archive; no test endpoint or
        # checksum override is added to the production installer.
        self.script = self.root / "installer.sh"
        self.script.write_text(re.sub(r'expected_checksum="[0-9a-f]{64}"',
                                      f'expected_checksum="{checksum}"', SCRIPT.read_text()))
        self.responses = []
        self.requests = 0
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.requests += 1
                response = fixture.responses.pop(0) if fixture.responses else 200
                if response == "disconnect":
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    self.close_connection = True
                    return
                payload = fixture.payload if response == 200 else b"Gateway Timeout"
                self.send_response(response)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(worker.join)
        self.addCleanup(server.shutdown)
        hooks = self.root / "hooks.sh"
        hooks.write_text('curl() { command curl --retry-delay 1 "${@:1:$#-1}" "$FIXTURE_URL"; }\n')
        self.environment = dict(os.environ, BASH_ENV=str(hooks),
                                DERIVED_FILE_DIR=str(self.root / "derived"),
                                FIXTURE_URL=f"http://127.0.0.1:{server.server_port}/archive",
                                NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")

    def install(self):
        return subprocess.run(["/bin/bash", str(self.script), str(self.output)],
                              env=self.environment, capture_output=True, text=True, timeout=30)

    def test_interrupted_download_and_gateway_timeout_are_retried_then_cached(self):
        self.responses = ["disconnect", 504, 200]
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, 3)
        self.assertTrue(os.access(self.output / "github-mcp-server", os.X_OK))
        self.assertEqual((self.output / "github-mcp-server-LICENSE.txt").read_text(), "Fixture license\n")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.requests, 3, "A verified cached archive must not be downloaded again")

    def test_retries_are_bounded_and_failed_download_is_not_installed(self):
        self.responses = ["disconnect"] * 10
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.requests, 4)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.rglob("*.download")))
        self.assertFalse(list(self.root.rglob("*.tar.gz")))

    def test_checksum_mismatch_never_reaches_app_resources(self):
        self.payload = b"not the pinned archive"
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.rglob("*.download")))
        self.assertFalse(list(self.root.rglob("*.tar.gz")))


if __name__ == "__main__":
    unittest.main()
