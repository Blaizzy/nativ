"""Exercise the production SSE wrapper without loading a GPU model."""
import ast
import asyncio
import math
import os
import time
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import anyio
from starlette.applications import Starlette
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import StreamingResponse
from starlette.routing import Route

SOURCE = Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay/nativ_server.py'
names = {'stream_with_keepalives', 'stream_keepalive_interval', 'stream_request_timeout', 'StreamDeadlineExceeded'}
nodes = [n for n in ast.parse(SOURCE.read_text()).body
         if isinstance(n, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
namespace = dict(asyncio=asyncio, anyio=anyio, math=math, os=os, time=time,
                 base=SimpleNamespace(logger=Mock()),
                 base_generation=SimpleNamespace(runtime=SimpleNamespace(config=None)))
exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SOURCE), 'exec'), namespace)
wrap = namespace['stream_with_keepalives']
HEARTBEAT = b': keepalive\n\n'


class KeepaliveTests(unittest.IsolatedAsyncioTestCase):
    async def test_silent_prefill_keeps_one_read_alive_and_preserves_output(self):
        release = asyncio.Event()
        closed = asyncio.Event()
        reads = 0
        async def source():
            nonlocal reads
            try:
                reads += 1
                await release.wait()
                yield b'data: {"text":"hello"}\n\n'
                yield b'data: [DONE]\n\n'
            finally:
                closed.set()
        stream = wrap(source(), .005)
        for _ in range(3):
            self.assertEqual(await anext(stream), HEARTBEAT)
        self.assertEqual(reads, 1)
        release.set()
        self.assertEqual([c async for c in stream],
                         [b'data: {"text":"hello"}\n\n', b'data: [DONE]\n\n'])
        self.assertTrue(closed.is_set())

    async def test_fragmented_events_are_never_interrupted(self):
        for chunks in ([b'data: {', b'"x":1}\n', b'\n'],
                       [b'data: x\r', b'\n\r', b'\n']):
            async def source():
                for chunk in chunks:
                    yield chunk
                    await asyncio.sleep(.01)
            actual = [c async for c in wrap(source(), .002)]
            self.assertEqual(actual[:len(chunks)], chunks)
            self.assertTrue(all(c == HEARTBEAT for c in actual[len(chunks):]))

    async def test_disabled_and_fast_streams_preserve_bytes(self):
        chunks = [b'data: a\n\n', b'data: [DONE]\n\n']
        for interval in (0, 15):
            async def source():
                for chunk in chunks:
                    yield chunk
            self.assertEqual([c async for c in wrap(source(), interval)], chunks)

    async def test_backend_failure_propagates_and_stops_heartbeats(self):
        async def source():
            await asyncio.sleep(.015)
            raise TimeoutError('engine deadline')
            yield
        stream = wrap(source(), .002)
        with self.assertRaisesRegex(TimeoutError, 'engine deadline'):
            async for chunk in stream:
                self.assertEqual(chunk, HEARTBEAT)
        with self.assertRaises(StopAsyncIteration):
            await anext(stream)

    async def test_terminal_event_stops_heartbeats_during_cleanup(self):
        terminal = False
        async def source():
            yield b'data: [DONE]\n\n'
            await asyncio.sleep(.025)
        stream = wrap(source(), .002, is_terminal=lambda: terminal)
        self.assertEqual(await anext(stream), b'data: [DONE]\n\n')
        terminal = True
        self.assertEqual([chunk async for chunk in stream], [])

    async def test_deadline_expires_with_heartbeats_off_or_on_and_during_output(self):
        for interval in (0, .003):
            for active in (False, True):
                closed = asyncio.Event()
                async def source():
                    try:
                        while True:
                            await asyncio.sleep(.002 if active else 10)
                            yield b'data: token\n\n'
                    finally:
                        closed.set()
                start = time.monotonic()
                with self.assertRaises(namespace['StreamDeadlineExceeded']):
                    async for _ in wrap(source(), interval, deadline=start + .03):
                        pass
                self.assertLess(time.monotonic() - start, .5)
                self.assertTrue(closed.is_set())

    async def test_partial_event_timeout_does_not_append_invalid_sse(self):
        async def source():
            yield b'data: {"partial":'
            await asyncio.Event().wait()
        stream = wrap(source(), .002, deadline=time.monotonic() + .02)
        self.assertEqual(await anext(stream), b'data: {"partial":')
        with self.assertRaises(namespace['StreamDeadlineExceeded']) as caught:
            await anext(stream)
        self.assertFalse(caught.exception.safe_to_emit)

    async def test_disabled_does_not_spawn_read_tasks(self):
        async def source():
            yield b'data: a\n\n'
        with patch.object(asyncio, 'create_task', side_effect=AssertionError('unexpected task')):
            self.assertEqual([c async for c in wrap(source(), 0)], [b'data: a\n\n'])

    async def test_completed_response_is_not_reported_as_timeout_during_cleanup(self):
        terminal = False
        closed = asyncio.Event()
        async def source():
            try:
                yield b'data: [DONE]\n\n'
                await asyncio.Event().wait()
            finally:
                closed.set()
        stream = wrap(source(), .002, is_terminal=lambda: terminal, deadline=time.monotonic() + .02)
        await anext(stream)
        terminal = True
        self.assertEqual([chunk async for chunk in stream], [])
        self.assertTrue(closed.is_set())

    async def test_close_during_prefill_closes_pending_source(self):
        closed = asyncio.Event()
        async def source():
            try:
                await asyncio.Event().wait()
                yield b'unreachable'
            finally:
                closed.set()
        stream = wrap(source(), .002)
        self.assertEqual(await anext(stream), HEARTBEAT)
        await stream.aclose()
        self.assertTrue(closed.is_set())

    async def test_anyio_disconnect_cancels_read_and_closes_source(self):
        started, closed = asyncio.Event(), asyncio.Event()
        async def source():
            try:
                started.set()
                await asyncio.Event().wait()
                yield b'unreachable'
            finally:
                closed.set()
        async def consume():
            async for _ in wrap(source(), 15):
                pass
        async with anyio.create_task_group() as group:
            group.start_soon(consume)
            await started.wait()
            group.cancel_scope.cancel()
        self.assertTrue(closed.is_set())

    async def test_http_middleware_disconnect_reaches_backend(self):
        # Exercise the real Starlette streaming/disconnect machinery, including
        # the middleware body iterator used by Nativ, on both API routes.
        for path, fail_send in ((p, fail) for p in ('/v1/chat/completions', '/v1/responses')
                                for fail in (False, True)):
            closed = asyncio.Event()
            incoming = asyncio.Queue()
            await incoming.put({'type': 'http.request', 'body': b'', 'more_body': False})
            sent = []

            async def endpoint(request):
                async def body():
                    try:
                        await asyncio.Event().wait()
                        yield b'unreachable'
                    finally:
                        closed.set()
                return StreamingResponse(body(), media_type='text/event-stream')

            async def middleware(request, call_next):
                response = await call_next(request)
                response.body_iterator = wrap(response.body_iterator, .005)
                return response

            async def send(message):
                sent.append(message)
                if message.get('body') == HEARTBEAT:
                    if fail_send:
                        raise OSError('connection lost')
                    await incoming.put({'type': 'http.disconnect'})

            app = Starlette(routes=[Route(path, endpoint, methods=['POST'])])
            app.add_middleware(BaseHTTPMiddleware, dispatch=middleware)
            scope = dict(type='http', asgi={'version': '3.0', 'spec_version': '2.3'},
                         http_version='1.1', method='POST', scheme='http', path=path,
                         raw_path=path.encode(), query_string=b'', headers=[],
                         client=('127.0.0.1', 1234), server=('127.0.0.1', 8080))
            if fail_send:
                with self.assertRaises(Exception):
                    await asyncio.wait_for(app(scope, incoming.get, send), 1)
            else:
                await asyncio.wait_for(app(scope, incoming.get, send), 1)
            self.assertTrue(closed.is_set())
            self.assertFalse([t for t in asyncio.all_tasks() if t.get_name() == 'nativ-sse-read'])
            self.assertTrue(any(m.get('body') == HEARTBEAT for m in sent))

    def test_configuration(self):
        for value, expected in [('0', 0), ('2.5', 2.5), ('-1', 15),
                                ('nan', 15), ('inf', 15), ('oops', 15)]:
            with patch.dict(os.environ, NATIV_STREAM_KEEPALIVE_INTERVAL=value):
                self.assertEqual(namespace['stream_keepalive_interval'](), expected)

    def test_deadline_uses_live_engine_setting_and_client_can_only_shorten_it(self):
        runtime = namespace['base_generation'].runtime
        with patch.object(runtime, 'config', SimpleNamespace(current=lambda: {'token_queue_timeout': 1200})):
            self.assertEqual(namespace['stream_request_timeout'](), 1200)
            for hint, expected in [('600', 600), ('7200', 1200), ('nan', 1200), ('0', 1200), ('bad', 1200)]:
                request = SimpleNamespace(headers={'x-nativ-request-timeout': hint})
                self.assertEqual(namespace['stream_request_timeout'](request), expected)


if __name__ == '__main__':
    unittest.main()
