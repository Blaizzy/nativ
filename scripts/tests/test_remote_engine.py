"""Coverage for forwarding models to an external OpenAI-compatible engine."""
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay/nativ_remote_engine.py"
ENGINE = {"base_url": "http://127.0.0.1:8091/v1", "model": "engine-model", "api_key": "secret"}


class StubResponse:
    def __init__(self, content=b"{}", status_code=200, headers=None, **kwargs):
        self.content = content
        self.status_code = status_code
        self.headers = headers or {}
        self.kwargs = kwargs


class StubHTTPError(Exception):
    pass


class StubClient:
    """Records the request it is asked to send and returns a canned upstream response."""

    sent = []
    raises = None
    upstream = None

    def __init__(self, *args, **kwargs):
        pass

    def build_request(self, method, url, headers=None, json=None):
        return SimpleNamespace(method=method, url=url, headers=headers, json=json)

    async def send(self, request, stream=False):
        StubClient.sent.append(request)
        if StubClient.raises:
            raise StubClient.raises
        return StubClient.upstream

    async def aread(self):
        return b""


def load_module():
    stubs = {
        "httpx": SimpleNamespace(AsyncClient=StubClient, Timeout=lambda *a, **k: None, HTTPError=StubHTTPError),
        "fastapi": ModuleType("fastapi"),
        "fastapi.responses": SimpleNamespace(JSONResponse=StubResponse, Response=StubResponse, StreamingResponse=StubResponse),
        "starlette": ModuleType("starlette"),
        "starlette.background": SimpleNamespace(BackgroundTask=lambda *a, **k: None),
    }
    spec = importlib.util.spec_from_file_location("nativ_remote_engine_under_test", SOURCE)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, stubs):
        spec.loader.exec_module(module)
    return module


class UpstreamResponse:
    def __init__(self, body=b'{"ok": true}', status_code=200, content_type="application/json"):
        self.status_code = status_code
        self.headers = {"content-type": content_type, "date": "now", "server": "engine", "x-extra": "1"}
        self._body = body

    async def aread(self):
        return self._body

    async def aclose(self):
        pass

    def aiter_raw(self):
        raise AssertionError("buffered responses must not be streamed")


class EnginesFileTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def write(self, text):
        path = os.path.join(self.directory.name, "engines.json")
        Path(path).write_text(text)
        return path

    def test_missing_file_means_no_engines(self):
        self.assertEqual(self.module.load_engines(os.path.join(self.directory.name, "none.json")), {})

    def test_unreadable_json_means_no_engines(self):
        self.assertEqual(self.module.load_engines(self.write("{not json")), {})

    def test_entries_without_a_base_url_are_dropped(self):
        path = self.write(json.dumps({"a": {"base_url": "http://x/v1"}, "b": {"model": "m"}, "c": 3}))
        self.assertEqual(list(self.module.load_engines(path)), ["a"])


class RoutingTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.engines = {"qwen": ENGINE}

    def test_a_mapped_model_routes_to_its_engine(self):
        self.assertIs(self.module.engine_for({"model": "qwen"}, self.engines), ENGINE)

    def test_other_models_stay_in_process(self):
        for payload in ({"model": "other"}, {}, {"model": 5}, None, []):
            self.assertIsNone(self.module.engine_for(payload, self.engines))

    def test_paths_map_with_and_without_the_v1_prefix(self):
        self.assertEqual(self.module.upstream_path("/v1/chat/completions"), "/chat/completions")
        self.assertEqual(self.module.upstream_path("/responses"), "/responses")

    def test_compaction_is_not_forwarded(self):
        self.assertIsNone(self.module.upstream_path("/v1/responses/compact"))


class ForwardTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        StubClient.sent, StubClient.raises, StubClient.upstream = [], None, UpstreamResponse()
        self.request = SimpleNamespace(
            url=SimpleNamespace(path="/v1/chat/completions"),
            headers={"authorization": "Bearer nativ", "content-type": "application/json", "host": "x"},
        )

    def run_forward(self, payload=None):
        return asyncio.run(self.module.forward(self.request, payload or {"model": "qwen", "stream": False}, ENGINE))

    def test_the_request_is_sent_to_the_engine_with_its_model_and_key(self):
        self.run_forward()
        sent = StubClient.sent[0]
        self.assertEqual(sent.url, "http://127.0.0.1:8091/v1/chat/completions")
        self.assertEqual(sent.json["model"], "engine-model")
        self.assertEqual(sent.headers["authorization"], "Bearer secret")
        self.assertNotIn("host", sent.headers)

    def test_the_apps_own_key_is_not_leaked_to_an_engine_without_one(self):
        engine = {"base_url": "http://127.0.0.1:8091/v1"}
        asyncio.run(self.module.forward(self.request, {"model": "qwen"}, engine))
        self.assertNotIn("authorization", StubClient.sent[0].headers)

    def test_the_engines_answer_is_returned_without_hop_headers(self):
        response = self.run_forward()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b'{"ok": true}')
        self.assertEqual(response.headers, {"content-type": "application/json", "x-extra": "1"})

    def test_an_unreachable_engine_is_a_503_not_an_exception(self):
        StubClient.raises = StubHTTPError("connection refused")
        self.assertEqual(self.run_forward().status_code, 503)

    def test_compaction_is_a_501_and_never_reaches_the_engine(self):
        self.request.url.path = "/v1/responses/compact"
        self.assertEqual(self.run_forward().status_code, 501)
        self.assertEqual(StubClient.sent, [])


if __name__ == "__main__":
    unittest.main()
