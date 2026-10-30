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

SOURCE = Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay/nativ_server.py'
names = {'stream_with_keepalives', 'stream_keepalive_interval'}
nodes = [n for n in ast.parse(SOURCE.read_text()).body
         if isinstance(n, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
namespace = dict(asyncio=asyncio, anyio=anyio, math=math, os=os, time=time,
                 base=SimpleNamespace(logger=Mock()))
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

    async def test_terminal_event_stops_heartbeats_during_cleanup(self):
        terminal = False
        async def source():
            yield b'data: [DONE]\n\n'
            await asyncio.sleep(.025)
        stream = wrap(source(), .002, is_terminal=lambda: terminal)
        self.assertEqual(await anext(stream), b'data: [DONE]\n\n')
        terminal = True
        self.assertEqual([chunk async for chunk in stream], [])

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

    def test_configuration(self):
        for value, expected in [('0', 0), ('2.5', 2.5), ('-1', 15),
                                ('nan', 15), ('inf', 15), ('oops', 15)]:
            with patch.dict(os.environ, NATIV_STREAM_KEEPALIVE_INTERVAL=value):
                self.assertEqual(namespace['stream_keepalive_interval'](), expected)

if __name__ == '__main__':
    unittest.main()
