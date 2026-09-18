"""Exercise real diagnostics code and SQLite without importing MLX or starting a server.

Only named production definitions are loaded: model setup and module-level database
creation must not run in tests. HTTP/MLX boundaries are faked; storage, outcome handling
and buffered response materialization execute their production implementations.
"""

import ast
import asyncio
import atexit
import contextvars
import dataclasses
import json
import logging
import os
import re
import sqlite3
import sys
import tempfile
import threading
import types
import unittest
import uuid
from contextlib import ExitStack, closing, contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock, Mock, patch

SOURCE = Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay/nativ_server.py"
DEFINITIONS = {
    "safe_failure_code",
    "safe_diagnostic_version",
    "AnalyticsStore",
    "MetricsTracker",
    "RequestObservation",
    "ModelAggregate",
    "bucket_start_unix",
    "seconds_to_milliseconds",
    "gigabytes_to_bytes",
    "materialize_response",
    "install_metrics_overlay",
}


def diagnostics_code():
    parsed = ast.parse(SOURCE.read_text(), filename=str(SOURCE))
    compile(parsed, str(SOURCE), "exec")
    definitions = [
        node
        for node in parsed.body
        if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name in DEFINITIONS
    ]
    if {node.name for node in definitions} != DEFINITIONS:
        raise AssertionError("Update the test harness: a production definition is missing")
    future = ast.parse("from __future__ import annotations").body
    return compile(
        ast.fix_missing_locations(ast.Module(body=future + definitions, type_ignores=[])),
        str(SOURCE),
        "exec",
    )


class FakeHTTPException(Exception):
    def __init__(self, status_code):
        super().__init__("PRIVATE exception detail")
        self.status_code = status_code


class FakeApp:
    def __init__(self):
        self.state = types.SimpleNamespace()

    def middleware(self, kind):
        def register(handler):
            self.handler = handler
            return handler

        return register

    def get(self, *args, **kwargs):
        return lambda handler: handler

    post = get


class FakeResponse:
    def __init__(self, content=b"", status_code=200, headers=None, **kwargs):
        self.body = content
        self.status_code = status_code
        self.headers = headers or {}


class RequestDiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.code = diagnostics_code()

    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.folder = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.stack.enter_context(patch.dict(os.environ, {"NATIV_APP_VERSION": "1.2.3"}))
        # Each test gets new classes, globals, app state and SQLite connections.
        self.server = types.ModuleType("nativ_diagnostics_under_test")
        self.stack.enter_context(patch.dict(sys.modules, {self.server.__name__: self.server}))
        self.server.__dict__.update(
            Any=Any,
            asyncio=asyncio,
            atexit=atexit,
            os=os,
            re=re,
            json=json,
            sqlite3=sqlite3,
            uuid=uuid,
            datetime=datetime,
            Lock=threading.Lock,
            dataclass=dataclasses.dataclass,
            HTTPException=FakeHTTPException,
            time=types.SimpleNamespace(time=lambda: 1_700_000_000, perf_counter=lambda: 10),
            BACKEND_NAME="mlx_vlm/0.28.0",
            current_tool_parser=lambda: None,
            base=types.SimpleNamespace(
                app=FakeApp(), logger=Mock(spec=logging.Logger), apc_manager=None
            ),
        )
        exec(self.code, self.server.__dict__)
        self.path = self.folder / "analytics.sqlite3"
        self.store = self.stack.enter_context(self.open_store(self.path))
        self.server.ANALYTICS_STORE = self.store

    @contextmanager
    def open_store(self, path):
        store = self.server.AnalyticsStore(str(path))
        try:
            yield store
        finally:
            atexit.unregister(store.close_session)
            try:
                store.close_session()
            finally:
                store._connection.close()

    def rows(self, sql, parameters=(), path=None):
        # A separate reader verifies committed data, rather than pending writer state.
        with closing(sqlite3.connect(path or self.path)) as connection:
            connection.row_factory = sqlite3.Row
            return [dict(row) for row in connection.execute(sql, parameters)]

    def observation(self, request_id="request", stream=False):
        return self.server.RequestObservation(
            request_id=request_id,
            endpoint="/v1/chat/completions",
            model="Qwen3-8B",
            stream=stream,
            image_count=0,
            audio_count=0,
            structured_output=False,
            thinking_enabled=False,
            started_at_unix=1_699_999_998,
            start_time=8,
            first_token_at=8.25,
        )

    def event(self, **overrides):
        return {
            "request_id": "request",
            "started_at": 1_699_999_998,
            "completed_at": 1_700_000_000,
            "model_id": "Qwen3-8B",
            **overrides,
        }

    def test_failure_categories_use_types_and_status_not_private_messages(self):
        class UnprintableError(RuntimeError):
            def __str__(self):
                raise AssertionError("Classification must not read the exception message")

        for error, expected in (
            (MemoryError("PRIVATE"), "out_of_memory"),
            (TimeoutError("PRIVATE"), "timeout"),
            (NotImplementedError("PRIVATE"), "unsupported"),
            (RuntimeError("PRIVATE out of memory"), "runtime_error"),
            (UnprintableError(), "runtime_error"),
        ):
            with self.subTest(error_type=type(error).__name__):
                self.assertEqual(self.server.safe_failure_code(error), expected)
        for status, expected in (
            (400, "invalid_request"),
            (422, "invalid_request"),
            (408, "timeout"),
            (504, "timeout"),
            (501, "unsupported"),
            (500, "runtime_error"),
            (503, "runtime_error"),
            (401, "unknown"),
            (403, "unknown"),
            (429, "unknown"),
        ):
            for wrapped in (False, True):
                with self.subTest(status=status, wrapped=wrapped):
                    result = (
                        self.server.safe_failure_code(FakeHTTPException(status))
                        if wrapped
                        else self.server.safe_failure_code(status=status)
                    )
                    self.assertEqual(result, expected)
        self.assertEqual(self.server.safe_failure_code(), "unknown")

    def test_versions_accept_only_bounded_ascii_components(self):
        for value in ("1.2", "0.28.0", "9999.9999.9999"):
            with self.subTest(valid=value):
                self.assertEqual(self.server.safe_diagnostic_version(value), value)
        for value in (
            None,
            1,
            "",
            "1",
            "1.2.3.4",
            "1.2\n",
            "1.2-beta",
            " 1.2",
            "/private/1.2",
            "١.٢",
            "10000.1",
            "1.10000",
            "1.2.10000",
        ):
            with self.subTest(invalid=value):
                self.assertIsNone(self.server.safe_diagnostic_version(value))

    def test_tracker_persists_distinct_outcomes_and_compatible_counters(self):
        tracker = self.server.MetricsTracker()
        for status in ("failed", "cancelled", "completed"):
            observation = self.observation(status, stream=status != "completed")
            tracker.record_started(observation)
            if status == "completed":
                tracker.record_completed(
                    observation,
                    {"prompt_tokens": 8, "completion_tokens": 2, "request_elapsed_s": 2},
                )
            else:
                tracker.record_failed(observation, "out_of_memory", cancelled=status == "cancelled")
        rows = self.rows(
            "SELECT status, error_code, finish_reason, app_version, runtime_version "
            "FROM request_events ORDER BY status"
        )
        expected = [
            dict(
                status=status,
                error_code=code,
                finish_reason=reason,
                app_version="1.2.3",
                runtime_version="0.28.0",
            )
            for status, code, reason in (
                ("cancelled", None, "cancelled"),
                ("completed", None, None),
                ("failed", "out_of_memory", "error"),
            )
        ]
        self.assertEqual(rows, expected)
        self.assertEqual(
            (tracker.in_flight, tracker.requests_completed, tracker.requests_failed), (0, 1, 2)
        )
        self.assertEqual(tracker.models["Qwen3-8B"].requests_failed, 2)
        self.assertEqual(tracker.streaming_requests, 2)
        self.assertEqual(tracker.models["Qwen3-8B"].streaming_requests, 2)
        counters = self.rows(
            "SELECT requests_started, requests_completed, requests_failed FROM analytics_buckets"
        )
        self.assertEqual(
            counters, [dict(requests_started=3, requests_completed=1, requests_failed=2)] * 2
        )

    def test_persistence_rejects_private_or_missing_versions_and_error_text(self):
        for app, backend, expected in (
            ("PRIVATE app path", "mlx_vlm/PRIVATE runtime", (None, None)),
            (None, "mlx_vlm", (None, None)),
            ("1.2.3", "mlx_vlm/0.28.0rc1", ("1.2.3", None)),
            ("PRIVATE", "mlx_vlm/0.28.0", (None, "0.28.0")),
        ):
            with self.subTest(app=app, backend=backend):
                with patch.dict(os.environ), patch.object(self.server, "BACKEND_NAME", backend):
                    if app is None:
                        os.environ.pop("NATIV_APP_VERSION", None)
                    else:
                        os.environ["NATIV_APP_VERSION"] = app
                    event = self.event(
                        request_id=str(uuid.uuid4()),
                        status="failed",
                        error_code="PRIVATE exception",
                    )
                    self.store.record_event(event)
                row = self.rows(
                    "SELECT error_code, app_version, runtime_version FROM request_events WHERE request_id = ?",
                    (event["request_id"],),
                )[0]
                self.assertEqual(
                    row, dict(error_code=None, app_version=expected[0], runtime_version=expected[1])
                )
        self.assertNotIn("PRIVATE", "\n".join(self.store._connection.iterdump()))

    def test_non_failed_records_never_keep_an_error_category(self):
        for status in ("completed", "cancelled"):
            with self.subTest(status=status):
                event = self.event(request_id=status, status=status, error_code="timeout")
                self.store.record_event(event)
        self.assertEqual(
            self.rows("SELECT error_code FROM request_events"), [{"error_code": None}] * 2
        )

    def test_duplicate_ids_preserve_the_entire_row_and_aggregates(self):
        event = self.event(status="failed", error_code="out_of_memory")
        self.store.record_event(event)
        before = self.rows("SELECT * FROM request_events")
        buckets = self.rows("SELECT * FROM analytics_buckets")
        with patch.dict(os.environ, {"NATIV_APP_VERSION": "9.9"}):
            self.store.record_event(
                dict(event, status="cancelled", error_code="timeout", prompt_tokens=999)
            )
        self.assertEqual(self.rows("SELECT * FROM request_events"), before)
        self.assertEqual(self.rows("SELECT * FROM analytics_buckets"), buckets)

    def test_migration_preserves_legacy_rows_and_can_resume_partial_upgrades(self):
        for retained in (None, "error_code", "app_version", "runtime_version"):
            with self.subTest(retained=retained):
                path = self.folder / f"legacy-{retained}.sqlite3"
                with self.open_store(path) as store:
                    store.record_event(self.event(status="failed", error_code="timeout"))
                with closing(sqlite3.connect(path)) as connection:
                    for column in ("error_code", "app_version", "runtime_version"):
                        if column != retained:
                            connection.execute(f"ALTER TABLE request_events DROP COLUMN {column}")
                    connection.commit()
                before = self.rows("SELECT * FROM request_events", path=path)[0]
                with self.open_store(path) as migrated:
                    migrated._ensure_schema()  # Repeating an upgrade must also be harmless.
                after = self.rows("SELECT * FROM request_events", path=path)[0]
                self.assertEqual({key: after[key] for key in before}, before)
                for column in {"error_code", "app_version", "runtime_version"} - before.keys():
                    self.assertIsNone(after[column])

    def middleware(self, path="/v1/chat/completions"):
        server = self.server
        observation = self.observation()
        completion = {"prompt_tokens": 8, "completion_tokens": 2}
        server.TRACKER = Mock(spec_set=server.MetricsTracker)
        server.Request = object
        server.Response = FakeResponse
        server.TRACKED_PATHS = {"/v1/chat/completions", "/v1/responses"}
        server.install_base_metrics_capture = Mock()
        server.apply_per_model_request_defaults = Mock(return_value=False)
        server.parse_request_observation = Mock(return_value=observation)
        server.parse_chat_response = Mock(return_value=completion)
        server.parse_responses_body = Mock(return_value=completion)
        server.StreamAccumulator = Mock()
        server.StreamAccumulator.return_value.finalize.return_value = completion
        server.StreamAccumulator.return_value.failed = False
        server.merge_base_metrics = Mock(return_value=completion)
        server._BASE_METRICS_CAPTURE = contextvars.ContextVar("test-capture", default=None)
        server.install_metrics_overlay()
        request = types.SimpleNamespace(
            url=types.SimpleNamespace(path=path), body=AsyncMock(return_value=b"{}")
        )
        return server.base.app.handler, request, observation, completion

    async def test_failures_and_cancellation_propagate_at_each_response_stage(self):
        for stage in ("dispatch", "streaming", "buffered"):
            for error_type, expected in (
                (MemoryError, "out_of_memory"),
                (TimeoutError, "timeout"),
                (asyncio.CancelledError, None),
            ):
                with self.subTest(stage=stage, error_type=error_type.__name__):
                    self.server.base.app = FakeApp()
                    handler, request, observation, _ = self.middleware()
                    error = error_type("PRIVATE response")
                    outer_context = {"outer": True}
                    token = self.server._BASE_METRICS_CAPTURE.set(outer_context)
                    try:

                        async def chunks():
                            yield b"data: {}\n\n"
                            raise error

                        response = FakeResponse(
                            headers={
                                "content-type": "text/event-stream"
                                if stage == "streaming"
                                else "application/json"
                            }
                        )
                        response.body_iterator = chunks()
                        call_next = (
                            AsyncMock(side_effect=error)
                            if stage == "dispatch"
                            else AsyncMock(return_value=response)
                        )
                        with self.assertRaises(error_type) as caught:
                            returned = await handler(request, call_next)
                            if stage == "streaming":
                                async for _ in returned.body_iterator:
                                    pass
                        self.assertIs(caught.exception, error)
                        self.assertIs(self.server._BASE_METRICS_CAPTURE.get(), outer_context)
                        self.server.TRACKER.record_started.assert_called_once_with(observation)
                        self.server.TRACKER.record_completed.assert_not_called()
                        if expected is None:
                            self.server.TRACKER.record_failed.assert_called_once_with(
                                observation, cancelled=True
                            )
                        else:
                            self.server.TRACKER.record_failed.assert_called_once_with(
                                observation, expected
                            )
                    finally:
                        await response.body_iterator.aclose()
                        self.server._BASE_METRICS_CAPTURE.reset(token)

    async def test_http_error_response_is_returned_unchanged(self):
        handler, request, observation, _ = self.middleware()
        response = FakeResponse(b"PRIVATE error body", status_code=422)
        self.assertIs(await handler(request, AsyncMock(return_value=response)), response)
        self.server.TRACKER.record_failed.assert_called_once_with(observation, "invalid_request")
        self.server.TRACKER.record_completed.assert_not_called()

    async def test_successful_streams_and_buffered_responses_are_not_failures(self):
        for path in ("/v1/chat/completions", "/v1/responses"):
            for stream in (False, True):
                with self.subTest(path=path, stream=stream):
                    self.server.base.app = FakeApp()
                    handler, request, observation, completion = self.middleware(path)
                    chunks = [b"data: {}\n", b"\ndata: {}"]

                    async def body():
                        for chunk in chunks:
                            yield chunk

                    response = FakeResponse(
                        headers={
                            "content-type": "text/event-stream" if stream else "application/json"
                        }
                    )
                    response.body_iterator = body()
                    returned = await handler(request, AsyncMock(return_value=response))
                    if stream:
                        self.assertEqual([chunk async for chunk in returned.body_iterator], chunks)
                    else:
                        self.assertEqual(returned.body, b"".join(chunks))
                        parser = (
                            self.server.parse_chat_response
                            if path.endswith("chat/completions")
                            else self.server.parse_responses_body
                        )
                        parser.assert_called_once_with(returned.body, observation)
                    self.server.TRACKER.record_completed.assert_called_once_with(
                        observation, completion
                    )
                    self.server.TRACKER.record_failed.assert_not_called()
                    self.assertIsNone(self.server._BASE_METRICS_CAPTURE.get())

    async def test_untracked_requests_bypass_diagnostics(self):
        handler, request, _, _ = self.middleware("/health")
        response = FakeResponse(b"healthy")
        self.assertIs(await handler(request, AsyncMock(return_value=response)), response)
        request.body.assert_not_awaited()
        self.assertEqual(self.server.TRACKER.mock_calls, [])


if __name__ == "__main__":
    unittest.main()
