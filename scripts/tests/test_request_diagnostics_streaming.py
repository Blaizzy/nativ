"""Regression coverage for HTTP 200 streams that carry failure events."""

import ast
import asyncio
import contextvars
import json
import math
import os
import time
import types
import unittest
import anyio
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch


class StreamingRequestDiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay/nativ_server.py'
        parsed = ast.parse(source.read_text())
        names = {'StreamAccumulator', 'install_metrics_overlay', 'stream_with_keepalives', 'stream_keepalive_interval', 'stream_request_timeout', 'StreamDeadlineExceeded', 'RequestCancellationMiddleware'}
        definitions = [node for node in parsed.body if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names]
        cls.code = compile(ast.fix_missing_locations(ast.Module(
            body=ast.parse('from __future__ import annotations').body + definitions,
            type_ignores=[],
        )), str(source), 'exec')

    async def run_stream(self, path, chunks):
        app = types.SimpleNamespace(state=types.SimpleNamespace())
        def middleware(_):
            def register(handler):
                app.handler = handler
            return register
        app.add_middleware = lambda _: None
        app.middleware = middleware
        app.get = app.post = lambda *args, **kwargs: lambda handler: handler
        observation = types.SimpleNamespace(model='test-model', start_time=time.perf_counter(), first_token_at=None)
        tracker = Mock()
        namespace = dict(
            asyncio=asyncio, anyio=anyio, math=math, os=os, json=json, time=time, Request=object,
            base=types.SimpleNamespace(app=app, logger=Mock()),
            TRACKER=tracker, TRACKED_PATHS={path},
            install_base_metrics_capture=lambda: None,
            apply_per_model_request_defaults=lambda _: False,
            parse_request_observation=lambda *_: observation,
            merge_base_metrics=lambda completion, _: completion,
            safe_failure_code=lambda _: 'runtime_error',
            _BASE_METRICS_CAPTURE=contextvars.ContextVar('stream-test', default=None),
        )
        exec(self.code, namespace)
        namespace['install_metrics_overlay']()
        async def body():
            for chunk in chunks:
                yield chunk
        response = types.SimpleNamespace(status_code=200, headers={'content-type': 'text/event-stream'}, body_iterator=body())
        request = types.SimpleNamespace(url=types.SimpleNamespace(path=path), body=AsyncMock(return_value=b'{}'))
        returned = await app.handler(request, AsyncMock(return_value=response))
        self.assertEqual([chunk async for chunk in returned.body_iterator], chunks)
        tracker.record_started.assert_called_once_with(observation)
        return tracker, observation

    async def test_error_events_fail_once_without_persisting_their_content(self):
        cases = [
            ('/v1/chat/completions', None, {'error': 'PRIVATE request and exception text'}),
            ('/v1/chat/completions', None, {'error': {'message': 'PRIVATE', 'code': 'PRIVATE'}}),
            ('/v1/chat/completions', 'error', {'message': 'PRIVATE'}),
            ('/v1/chat/completions', None, {'choices': [{'finish_reason': 'error'}]}),
            ('/v1/responses', 'response.failed', {'response': {'status': 'failed', 'error': {'message': 'PRIVATE'}}}),
            ('/v1/responses', None, {'type': 'response.failed', 'response': {'error': {'message': 'PRIVATE'}}}),
            ('/v1/responses', 'response.completed', {'response': {'status': 'failed'}}),
        ]
        for path, event, payload in cases:
            for terminated in (False, True):
                with self.subTest(path=path, event=event, terminated=terminated, payload=payload):
                    block = ((f'event: {event}\n' if event else '') + 'data: ' + json.dumps(payload)).encode()
                    if terminated:
                        block += b'\n\ndata: [DONE]\n\n'
                    chunks = [block[:13], block[13:]]
                    tracker, observation = await self.run_stream(path, chunks)
                    tracker.record_failed.assert_called_once_with(observation, 'runtime_error')
                    tracker.record_completed.assert_not_called()
                    self.assertNotIn('PRIVATE', repr(tracker.mock_calls))

    async def test_successful_streams_still_complete(self):
        for path, block in [
            ('/v1/chat/completions', b'data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1}}\n\ndata: [DONE]\n\n'),
            ('/v1/responses', b'event: response.completed\ndata: {"response":{"status":"completed","error":null,"usage":{"input_tokens":4,"output_tokens":1}}}\n\n'),
        ]:
            with self.subTest(path=path):
                tracker, observation = await self.run_stream(path, [block])
                tracker.record_failed.assert_not_called()
                tracker.record_completed.assert_called_once()
                actual_observation, completion = tracker.record_completed.call_args.args
                self.assertIs(actual_observation, observation)
                self.assertEqual(completion['prompt_tokens'], 4)
                self.assertEqual(completion['completion_tokens'], 1)

    async def test_heartbeat_does_not_count_as_output_or_first_token(self):
        tracker, observation = await self.run_stream('/v1/chat/completions', [
            b': keepalive\n\n', b'data: [DONE]\n\n',
        ])
        self.assertIsNone(observation.first_token_at)
        completion = tracker.record_completed.call_args.args[1]
        self.assertEqual(completion['completion_tokens'], 0)

    async def test_terminal_events_are_recognized(self):
        # Use the same production accumulator that controls heartbeat eligibility.
        namespace = dict(json=json)
        exec(self.code, namespace)
        for block in (
            'data: [DONE]',
            'event: response.completed\ndata: {"response": {}}',
            'data: {"type": "response.incomplete"}',
            'event: response.failed\ndata: {"response": {"status": "failed"}}',
            'data: {"error": "failed"}',
        ):
            accumulator = namespace['StreamAccumulator'](types.SimpleNamespace(model='test'), 'responses')
            accumulator.feed(block)
            self.assertTrue(accumulator.terminal, block)

    async def test_deadline_before_headers_cancels_endpoint(self):
        import httpx
        from fastapi import FastAPI, Request
        from fastapi.responses import JSONResponse
        app = FastAPI()
        closed = asyncio.Event()
        tracker = Mock()
        namespace = dict(
            asyncio=asyncio, anyio=anyio, math=math, os=os, json=json, time=time,
            Request=Request, JSONResponse=JSONResponse,
            base=types.SimpleNamespace(app=app, logger=Mock()),
            base_generation=types.SimpleNamespace(runtime=types.SimpleNamespace(config=None)), TRACKER=tracker,
            TRACKED_PATHS={'/v1/chat/completions'}, install_base_metrics_capture=lambda: None,
            apply_per_model_request_defaults=lambda _: False,
            parse_request_observation=lambda *_: types.SimpleNamespace(model='test'),
            _BASE_METRICS_CAPTURE=contextvars.ContextVar('deadline-test', default=None),
        )
        exec(self.code, namespace)
        namespace['install_metrics_overlay']()
        @app.post('/v1/chat/completions')
        async def stalled_endpoint():
            try:
                await asyncio.Event().wait()
            finally:
                closed.set()
        with patch.dict(os.environ, NATIV_STREAM_REQUEST_TIMEOUT='0.02'):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
                response = await asyncio.wait_for(client.post('/v1/chat/completions', json={'stream': True}), 1)
        self.assertEqual(response.status_code, 504)
        self.assertEqual(response.json()['error']['code'], 'request_timeout')
        self.assertTrue(closed.is_set())


if __name__ == '__main__':
    unittest.main()
