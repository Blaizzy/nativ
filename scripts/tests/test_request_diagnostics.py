"""Local diagnostics regression tests; no MLX imports or server startup."""
import ast
import atexit
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class HTTPError(Exception):
    def __init__(self, status):
        self.status_code = status


class RequestDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        source = Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay/nativ_server.py"
        imports = set("__future__ atexit asyncio json logging os re sqlite3 time uuid contextvars "
                      "dataclasses datetime threading types typing".split())
        names = set("safe_failure_code safe_diagnostic_version AnalyticsStore MetricsTracker "
                    "RequestObservation ModelAggregate bucket_start_unix seconds_to_milliseconds".split())
        nodes = []
        for node in ast.parse(source.read_text()).body:
            if isinstance(node, (ast.Import, ast.ImportFrom)):
                name = node.module if isinstance(node, ast.ImportFrom) else node.names[0].name
                if name in imports:
                    nodes.append(node)
            elif isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names:
                nodes.append(node)
        self.ns = dict(__name__=__name__, HTTPException=HTTPError, BACKEND_NAME="mlx_vlm/0.28.0")
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), self.ns)
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        environment = patch.dict(os.environ, {"NATIV_APP_VERSION": "1.2.3"})
        environment.start()
        self.addCleanup(environment.stop)
        self.store = self.ns["AnalyticsStore"](str(Path(folder.name) / "requests.sqlite3"))
        self.addCleanup(self.store._connection.close)
        self.addCleanup(self.store.close_session)
        self.addCleanup(atexit.unregister, self.store.close_session)
        self.ns["base"] = self.ns["SimpleNamespace"](logger=self.ns["logging"].getLogger(__name__))
        self.ns["ANALYTICS_STORE"] = self.store
        self.db = self.store._connection

    def test_failure_categories(self):
        class UnprintableError(RuntimeError):
            def __str__(self):
                raise AssertionError("Classification must not read exception messages")
        for error, expected in ((MemoryError, "out_of_memory"), (TimeoutError, "timeout"),
                                (NotImplementedError, "unsupported"), (RuntimeError, "runtime_error"),
                                (UnprintableError, "runtime_error")):
            with self.subTest(error=error.__name__):
                self.assertEqual(self.ns["safe_failure_code"](error("PRIVATE")), expected)
        for status, expected in ((400, "invalid_request"), (422, "invalid_request"), (408, "timeout"),
                                 (504, "timeout"), (501, "unsupported"), (500, "runtime_error"), (403, "unknown")):
            with self.subTest(status=status):
                self.assertEqual(self.ns["safe_failure_code"](status=status), expected)
                self.assertEqual(self.ns["safe_failure_code"](HTTPError(status)), expected)

    def test_numeric_versions(self):
        for value, expected in (("1.2", "1.2"), ("9999.9999.9999", "9999.9999.9999"),
                                (None, None), (1, None), ("PRIVATE", None), ("1.2\n", None),
                                ("1.2-beta", None), ("١.٢", None), ("10000.1", None), ("1.2.3.4", None)):
            with self.subTest(value=value):
                self.assertEqual(self.ns["safe_diagnostic_version"](value), expected)

    def test_outcomes_versions_and_duplicate_records(self):
        tracker = self.ns["MetricsTracker"]()
        for cancelled in (False, True):
            observation = self.ns["RequestObservation"](str(cancelled), "chat", "model", False,
                                                       0, 0, False, False, 1, 1)
            tracker.record_started(observation)
            tracker.record_failed(observation, "timeout", cancelled=cancelled)
        self.assertEqual((tracker.in_flight, tracker.requests_failed), (0, 2))
        rows = self.db.execute("SELECT status, error_code, app_version, runtime_version FROM request_events").fetchall()
        self.assertEqual(rows, [("failed", "timeout", "1.2.3", "0.28.0"), ("cancelled", None, "1.2.3", "0.28.0")])
        before = list(self.db.iterdump())
        self.store.record_event(dict(request_id="False", started_at=1, completed_at=2, error_code="PRIVATE"))
        self.assertEqual(list(self.db.iterdump()), before)

    def test_migration_and_private_field_rejection(self):
        self.store.record_event(dict(request_id="old", started_at=1, completed_at=2))
        for column in ("error_code", "app_version", "runtime_version"):
            self.db.execute(f"ALTER TABLE request_events DROP COLUMN {column}")
        self.db.commit()
        self.store._ensure_schema()
        self.store._ensure_schema()
        self.assertEqual(self.db.execute("SELECT error_code, app_version, runtime_version FROM request_events").fetchall(), [(None, None, None)])
        with patch.dict(os.environ, {"NATIV_APP_VERSION": "PRIVATE"}), patch.dict(self.ns, BACKEND_NAME="mlx_vlm/PRIVATE"):
            self.store.record_event(dict(request_id="new", started_at=1, completed_at=2,
                                         status="failed", error_code="PRIVATE"))
        row = self.db.execute("SELECT error_code, app_version, runtime_version FROM request_events WHERE request_id='new'").fetchone()
        self.assertEqual(row, (None, None, None))
        self.assertNotIn("PRIVATE", repr(self.db.execute("SELECT * FROM request_events").fetchall()))


if __name__ == "__main__":
    unittest.main()
