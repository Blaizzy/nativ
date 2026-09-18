"""Exercise the actual bundled producer's stdlib analytics code without loading MLX."""
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
import tempfile
import threading
import time
import types
import unittest
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any
from unittest.mock import Mock, patch


class FakeHTTPException(Exception):
    def __init__(self, status_code):
        self.status_code = status_code


class RequestDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay/nativ_server.py'
        parsed = ast.parse(source.read_text())
        compile(parsed, str(source), 'exec')
        names = {'safe_failure_code', 'safe_diagnostic_version', 'AnalyticsStore', 'MetricsTracker', 'RequestObservation', 'ModelAggregate', 'bucket_start_unix', 'seconds_to_milliseconds', 'gigabytes_to_bytes', 'install_metrics_overlay'}
        module = ast.Module(body=[ast.ImportFrom(module='__future__', names=[ast.alias(name='annotations')], level=0)] + [n for n in parsed.body if isinstance(n, (ast.ClassDef, ast.FunctionDef)) and n.name in names], type_ignores=[])
        ns = dict(Any=Any, os=os, re=re, sqlite3=sqlite3, time=time, uuid=uuid, datetime=datetime, Lock=threading.Lock,
                  dataclass=dataclasses.dataclass, atexit=atexit, BACKEND_NAME='mlx_vlm/0.28.0', HTTPException=FakeHTTPException,
                  base=types.SimpleNamespace(logger=logging.getLogger('producer-test'), apc_manager=None), current_tool_parser=lambda: None)
        exec(compile(ast.fix_missing_locations(module), str(source), 'exec'), ns)
        cls.ns = ns

    def test_error_types_and_statuses_never_depend_on_messages(self):
        code = self.ns['safe_failure_code']
        for error, expected in [(MemoryError('PRIVATE PROMPT'), 'out_of_memory'), (TimeoutError('PRIVATE AUDIO'), 'timeout'), (NotImplementedError('PRIVATE'), 'unsupported'), (RuntimeError('user said out of memory PRIVATE'), 'runtime_error'), (FakeHTTPException(422), 'invalid_request'), (FakeHTTPException(403), 'unknown'), (FakeHTTPException(503), 'runtime_error')]:
            self.assertEqual(code(error), expected)
        self.assertEqual(code(status=504), 'timeout')
        self.assertEqual(code(status=500), 'runtime_error')
        self.assertEqual(code(status=403), 'unknown')
        self.assertEqual(code(), 'unknown')

    def test_producer_migrates_records_versions_and_separates_cancellation(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {'NATIV_APP_VERSION': '1.2.3'}):
            store = self.ns['AnalyticsStore'](str(Path(folder) / 'analytics.sqlite3'))
            self.ns['ANALYTICS_STORE'] = store
            tracker = self.ns['MetricsTracker']()
            def observation(identifier):
                return self.ns['RequestObservation'](identifier, 'v1/chat/completions', 'Qwen3.5-9B-4bit', True, 0, 0, False, False, time.time() - 1, time.perf_counter() - 1)
            first = observation('failed'); tracker.record_started(first); tracker.record_failed(first, 'out_of_memory')
            second = observation('cancelled'); tracker.record_started(second); tracker.record_failed(second, cancelled=True)
            store._ensure_schema()  # Migration is repeatable against an existing store.
            rows = store._connection.execute('SELECT status, error_code, app_version, runtime_version, finish_reason FROM request_events ORDER BY request_id').fetchall()
            self.assertEqual(rows, [('cancelled', None, '1.2.3', '0.28.0', 'cancelled'), ('failed', 'out_of_memory', '1.2.3', '0.28.0', 'error')])
            self.assertEqual(tracker.in_flight, 0)
            with patch.dict(os.environ, {'NATIV_APP_VERSION': 'PRIVATE PATH'}):
                third = observation('unknown'); tracker.record_started(third); tracker.record_failed(third, 'PRIVATE EXCEPTION')
            row = store._connection.execute("SELECT error_code, app_version FROM request_events WHERE request_id = 'unknown'").fetchone()
            self.assertEqual(row, (None, None))
            completed = observation('completed')
            tracker.record_started(completed)
            tracker.record_completed(completed, {'prompt_tokens': 8, 'completion_tokens': 2, 'request_elapsed_s': 1})
            self.assertEqual(store._connection.execute("SELECT status, error_code, app_version, runtime_version FROM request_events WHERE request_id = 'completed'").fetchone(), ('completed', None, '1.2.3', '0.28.0'))
            # Retrying persistence must not replace an existing outcome/version.
            tracker.record_failed(first, 'timeout')
            self.assertEqual(store._connection.execute("SELECT error_code FROM request_events WHERE request_id = 'failed'").fetchone(), ('out_of_memory',))
            store.close_session(); atexit.unregister(store.close_session); store._connection.close()

    def test_version_values_are_bounded_numeric_identifiers(self):
        validate = self.ns['safe_diagnostic_version']
        for value in ('1.2', '26.904.1193', '0.28.0'):
            self.assertEqual(validate(value), value)
        for value in (None, 1, '', '1', '1.2.3.4', '1.2\n', '1.2-beta', '/private/1.2', '١.٢', '10000.1'):
            self.assertIsNone(validate(value))

    def test_existing_database_rows_survive_schema_upgrade(self):
        with tempfile.TemporaryDirectory() as folder:
            path = str(Path(folder) / 'old.sqlite3')
            store = self.ns['AnalyticsStore'](path)
            self.ns['ANALYTICS_STORE'] = store
            tracker = self.ns['MetricsTracker']()
            observation = self.ns['RequestObservation']('old-request', 'chat', 'model', False, 0, 0, False, False, time.time(), time.perf_counter())
            tracker.record_failed(observation, 'timeout')
            store.close_session(); atexit.unregister(store.close_session); store._connection.close()
            with sqlite3.connect(path) as db:
                for name in ('error_code', 'app_version', 'runtime_version'):
                    db.execute(f'ALTER TABLE request_events DROP COLUMN {name}')
            migrated = self.ns['AnalyticsStore'](path)
            self.assertEqual(migrated._connection.execute('SELECT request_id, status, error_code, app_version, runtime_version FROM request_events').fetchall(), [('old-request', 'failed', None, None, None)])
            migrated.close_session(); atexit.unregister(migrated.close_session); migrated._connection.close()

    def test_middleware_preserves_errors_and_cancellation(self):
        class App:
            def __init__(self):
                self.state = types.SimpleNamespace()
                self.handler = None
            def middleware(self, _kind):
                def register(handler):
                    self.handler = handler
                    return handler
                return register
            def get(self, *args, **kwargs):
                return lambda fn: fn
            post = get

        async def run():
            app = App()
            tracker = Mock()
            observation = object()
            base = types.SimpleNamespace(app=app, logger=logging.getLogger('middleware-test'))
            async def body():
                return b'{}'
            request = types.SimpleNamespace(url=types.SimpleNamespace(path='/v1/chat/completions'), body=body)
            async def materialize(response):
                raise TimeoutError('PRIVATE response')
            accumulator = types.SimpleNamespace(feed=lambda _: None, finalize=lambda: {})
            with patch.dict(self.ns, dict(
                asyncio=asyncio, json=json, Request=object, base=base, TRACKER=tracker,
                TRACKED_PATHS={'/v1/chat/completions'}, install_base_metrics_capture=lambda: None,
                apply_per_model_request_defaults=lambda _: False, parse_request_observation=lambda *_: observation,
                _BASE_METRICS_CAPTURE=contextvars.ContextVar('diagnostic-test', default=None),
                StreamAccumulator=lambda *_: accumulator, merge_base_metrics=lambda data, _: data,
                materialize_response=materialize,
            )):
                self.ns['install_metrics_overlay']()
                for error in (MemoryError('PRIVATE input'), TimeoutError('PRIVATE'), asyncio.CancelledError()):
                    tracker.reset_mock()
                    async def fail(_request):
                        raise error
                    with self.assertRaises(type(error)):
                        await app.handler(request, fail)
                    if isinstance(error, asyncio.CancelledError):
                        tracker.record_failed.assert_called_once_with(observation, cancelled=True)
                    else:
                        tracker.record_failed.assert_called_once_with(observation, self.ns['safe_failure_code'](error))

                tracker.reset_mock()
                response = types.SimpleNamespace(status_code=422)
                async def http_error(_request):
                    return response
                self.assertIs(await app.handler(request, http_error), response)
                tracker.record_failed.assert_called_once_with(observation, 'invalid_request')

                for error in (TimeoutError('PRIVATE audio'), asyncio.CancelledError()):
                    tracker.reset_mock()
                    async def stream():
                        yield b'data: {}\n\n'
                        raise error
                    async def streaming(_request):
                        return types.SimpleNamespace(status_code=200, headers={'content-type': 'text/event-stream'}, body_iterator=stream())
                    response = await app.handler(request, streaming)
                    with self.assertRaises(type(error)):
                        async for _ in response.body_iterator:
                            pass
                    if isinstance(error, asyncio.CancelledError):
                        tracker.record_failed.assert_called_once_with(observation, cancelled=True)
                    else:
                        tracker.record_failed.assert_called_once_with(observation, 'timeout')
                    tracker.record_completed.assert_not_called()

                tracker.reset_mock()
                async def buffered(_request):
                    return types.SimpleNamespace(status_code=200, headers={'content-type': 'application/json'})
                with self.assertRaises(TimeoutError):
                    await app.handler(request, buffered)
                tracker.record_failed.assert_called_once_with(observation, 'timeout')
        asyncio.run(run())


if __name__ == '__main__':
    unittest.main()
