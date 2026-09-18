"""Regression coverage for HTTP 200 streams that carry failure events."""

import ast
import asyncio
import contextvars
import json
import time
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock


class StreamingRequestDiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay/nativ_server.py'
        parsed = ast.parse(source.read_text())
        names = {'StreamAccumulator', 'install_metrics_overlay'}
        definitions = [node for node in parsed.body if isinstance(node, (ast.ClassDef, ast.FunctionDef)) and node.name in names]
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
        app.middleware = middleware
        app.get = app.post = lambda *args, **kwargs: lambda handler: handler
        observation = types.SimpleNamespace(model='test-model', start_time=time.perf_counter(), first_token_at=None)
        tracker = Mock()
        namespace = dict(
            asyncio=asyncio, json=json, time=time, Request=object,
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


if __name__ == '__main__':
    unittest.main()
