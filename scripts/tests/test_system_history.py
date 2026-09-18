"""Compile and exercise the production hardware history recorder on macOS."""
import json
import platform
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(platform.system() == "Darwin", "Native hardware diagnostics requires macOS")
class SystemHistoryTests(unittest.TestCase):
    def test_projection_opt_in_retention_and_storage_budget(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            source = ROOT / "Sources/Nativ/Features/SystemMonitor"
            executable = folder / "system-history-test"
            compiled = subprocess.run([
                "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-o", str(executable),
                str(source / "SystemMonitorStore.swift"), str(source / "SystemSensorSampler.swift"),
                str(source / "SystemTelemetry.swift"), str(ROOT / "scripts/tests/SystemTelemetryHarness.swift"),
                "-framework", "AppKit", "-framework", "IOKit", "-framework", "Metal", "-framework", "QuartzCore",
            ], capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            ran = subprocess.run([str(executable), str(folder)], capture_output=True, text=True, timeout=60)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            database = folder / "SystemTelemetry.sqlite3"
            with sqlite3.connect(database) as db:
                rows = db.execute("SELECT payload FROM system_samples").fetchall()
            self.assertEqual(len(rows), 2)
            self.assertEqual(database.stat().st_mode & 0o777, 0o600)
            payload = json.loads(rows[0][0])
            self.assertNotIn("PRIVATE", rows[0][0])
            self.assertEqual(payload["model_identifier"], "Mac17,6")
            self.assertEqual(payload["chip_generation"], 5)
            self.assertEqual(payload["memory_total_bytes"], 64 * 1024 ** 3)
            self.assertEqual(payload["cpu_usage"], .4)
            self.assertEqual(payload["gpu_usage"], .6)
            self.assertIsNone(payload["ane_usage"])
            print(ran.stdout.strip())


if __name__ == "__main__":
    unittest.main()
