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
    """Stands in for the fastapi response classes: keeps what it was built with."""

    def __init__(self, content=b"{}", status_code=200, headers=None, **kwargs):
        self.content = content
        self.status_code = status_code
        self.headers = headers or {}


class StubTransportError(Exception):
    pass


class StubInvalidURL(Exception):
    pass


class StubHTTPError(Exception):
    pass


class StubClient:
    """Plays back a script of upstream responses or errors, recording what was sent."""

    sent = []
    script = []
    posted = []
    post_script = []

    def __init__(self, *args, **kwargs):
        pass

    def build_request(self, method, url, headers=None, json=None):
        return SimpleNamespace(method=method, url=url, headers=headers, json=json)

    async def post(self, url, json=None, headers=None):
        StubClient.posted.append(SimpleNamespace(url=url, json=json, headers=headers))
        step = StubClient.post_script.pop(0)
        if isinstance(step, Exception):
            raise step
        return step

    async def send(self, request, stream=False):
        StubClient.sent.append(request)
        step = StubClient.script.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


class UpstreamResponse:
    def __init__(self, body=b'{"ok": true}', status_code=200, content_type="application/json", chunks=(), read_error=None):
        self.status_code = status_code
        self.headers = {"content-type": content_type, "content-encoding": "gzip", "date": "now",
                        "server": "engine", "x-extra": "1"}
        self._body, self._chunks, self._read_error = body, chunks, read_error
        self.closed = 0

    async def aread(self):
        if self._read_error:
            raise self._read_error
        return self._body

    async def aclose(self):
        self.closed += 1

    async def aiter_raw(self):
        for chunk in self._chunks:
            if isinstance(chunk, Exception):
                raise chunk
            yield chunk


def load_module():
    stubs = {
        "httpx": SimpleNamespace(
            AsyncClient=StubClient, Timeout=lambda *a, **k: None, HTTPError=StubHTTPError,
            TransportError=StubTransportError, InvalidURL=StubInvalidURL, Response=UpstreamResponse,
        ),
        "fastapi": ModuleType("fastapi"),
        "fastapi.responses": SimpleNamespace(JSONResponse=StubResponse, Response=StubResponse, StreamingResponse=StubResponse),
    }
    spec = importlib.util.spec_from_file_location("nativ_remote_engine_under_test", SOURCE)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, stubs):
        spec.loader.exec_module(module)
    return module


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


class JSONReply:
    """The part of an httpx response that count_input_tokens reads."""

    def __init__(self, data, error=None):
        self._data, self._error = data, error

    def raise_for_status(self):
        if self._error:
            raise self._error

    def json(self):
        return self._data


class CountTokensTests(unittest.TestCase):
    payload = {
        "model": "qwen", "instructions": "Be brief.",
        "input": [
            {"type": "message", "role": "user", "content": "hi", "reasoning_content": "dropped"},
            {"type": "message", "role": "tool", "tool_call_id": "c1", "content": "42"},
        ],
        "tools": [{"type": "function", "function": {"name": "f"}}],
    }

    def setUp(self):
        self.module = load_module()
        StubClient.posted, StubClient.post_script = [], []

    def count(self, payload=None):
        return asyncio.run(self.module.count_input_tokens(payload or self.payload, ENGINE))

    def test_tokens_are_counted_by_the_engines_template_then_tokenizer(self):
        StubClient.post_script = [JSONReply({"prompt": "<rendered>"}), JSONReply({"tokens": [1, 2, 3, 4]})]
        response = self.count()
        self.assertEqual(response.content, {"input_tokens": 4})
        template, tokenize = StubClient.posted
        self.assertEqual(template.url, "http://127.0.0.1:8091/apply-template")
        self.assertEqual(tokenize.url, "http://127.0.0.1:8091/tokenize")
        self.assertEqual(tokenize.json, {"content": "<rendered>", "add_special": False})
        self.assertEqual(template.headers, {"authorization": "Bearer secret"})

    def test_instructions_lead_and_only_conversation_fields_are_sent(self):
        StubClient.post_script = [JSONReply({"prompt": "p"}), JSONReply({"tokens": []})]
        self.count()
        sent = StubClient.posted[0].json
        self.assertEqual(sent["messages"], [
            {"role": "system", "content": "Be brief."},
            {"role": "user", "content": "hi"},
            {"role": "tool", "tool_call_id": "c1", "content": "42"},
        ])
        self.assertEqual(sent["tools"], self.payload["tools"])

    def test_tools_are_left_out_when_the_request_has_none(self):
        StubClient.post_script = [JSONReply({"prompt": "p"}), JSONReply({"tokens": []})]
        self.count({"model": "qwen", "input": []})
        self.assertNotIn("tools", StubClient.posted[0].json)

    def test_an_engine_failure_is_a_503(self):
        StubClient.post_script = [JSONReply({}, error=StubHTTPError("boom"))]
        self.assertEqual(self.count().status_code, 503)

    def test_an_unexpected_engine_reply_is_a_503(self):
        StubClient.post_script = [JSONReply({"unexpected": 1})]
        self.assertEqual(self.count().status_code, 503)


class PreloadTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.engines = {"qwen": ENGINE}

    def strip(self, *arguments):
        return self.module.without_remote_preload(list(arguments), self.engines)

    def test_a_mapped_model_is_not_preloaded(self):
        self.assertEqual(self.strip("--port", "8080", "--model", "qwen", "--host", "x"), ["--port", "8080", "--host", "x"])
        self.assertEqual(self.strip("--model=qwen", "--port", "8080"), ["--port", "8080"])

    def test_other_models_and_arguments_are_untouched(self):
        arguments = ["--model", "other", "--stt-model", "qwen", "--port", "8080"]
        self.assertEqual(self.strip(*arguments), arguments)

    def test_a_trailing_model_flag_is_kept(self):
        self.assertEqual(self.strip("--port", "8080", "--model"), ["--port", "8080", "--model"])


class ResponsesTranslationTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def convert(self, **body):
        return self.module.responses_body_for_engine(body)

    def test_a_tool_message_becomes_a_function_call_output(self):
        result = self.convert(input=[{"type": "message", "role": "tool", "tool_call_id": "c1", "content": "42"}])
        self.assertEqual(result["input"], [{"type": "function_call_output", "call_id": "c1", "output": "42"}])

    def test_an_assistant_message_with_tool_calls_becomes_function_call_items(self):
        call = {"index": 0, "id": "c1", "type": "function", "function": {"name": "read_file", "arguments": '{"p": 1}'}}
        result = self.convert(input=[{"type": "message", "role": "assistant", "content": None, "tool_calls": [call]}])
        self.assertEqual(result["input"], [{"type": "function_call", "call_id": "c1", "name": "read_file", "arguments": '{"p": 1}'}])

    def test_assistant_text_alongside_tool_calls_is_kept(self):
        call = {"id": "c1", "function": {"name": "f"}}
        result = self.convert(input=[{"type": "message", "role": "assistant", "content": "Checking", "tool_calls": [call]}])
        self.assertEqual([item["type"] for item in result["input"]], ["message", "function_call"])
        self.assertEqual(result["input"][1]["arguments"], "{}")

    def test_plain_messages_lose_chat_extensions_but_keep_their_text(self):
        item = {"type": "message", "role": "assistant", "content": "hi", "reasoning_content": "thought", "name": "x"}
        self.assertEqual(self.convert(input=[item])["input"], [{"type": "message", "role": "assistant", "content": "hi"}])

    def test_text_parts_collapse_to_a_string_and_image_parts_become_input_images(self):
        parts = [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]
        self.assertEqual(self.module._message_content(parts), "ab")
        image = [{"type": "text", "text": "look"}, {"type": "image_url", "image_url": {"url": "data:x"}}]
        self.assertEqual(self.module._message_content(image)[1], {"type": "input_image", "image_url": "data:x"})

    def test_nested_tool_definitions_are_flattened(self):
        nested = {"type": "function", "function": {"name": "read_file", "description": "d", "parameters": {"type": "object"}}}
        flat = {"type": "function", "name": "read_file", "parameters": {"type": "object"}}
        result = self.convert(tools=[nested, flat])
        self.assertEqual(result["tools"], [{"type": "function", "name": "read_file", "description": "d",
                                            "parameters": {"type": "object"}}, flat])

    def test_other_fields_and_non_message_items_pass_through(self):
        body = {"model": "m", "stream": True, "input": [{"type": "function_call_output", "call_id": "c", "output": "x"}]}
        self.assertEqual(self.convert(**body), body)


class ForwardTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        StubClient.sent, StubClient.script = [], []
        self.request = SimpleNamespace(
            url=SimpleNamespace(path="/v1/chat/completions"),
            headers={"authorization": "Bearer nativ", "content-type": "application/json", "host": "x",
                     "cookie": "session=1", "x-api-key": "k", "accept-encoding": "gzip"},
        )

    def forward(self, engine=ENGINE, payload=None):
        return asyncio.run(self.module.forward(self.request, payload or {"model": "qwen"}, engine))

    def collect(self, response):
        async def gather():
            return [chunk async for chunk in response.content]
        return asyncio.run(gather())

    def test_the_request_goes_to_the_engine_with_its_model_and_key(self):
        StubClient.script = [UpstreamResponse()]
        self.forward()
        sent = StubClient.sent[0]
        self.assertEqual(sent.url, "http://127.0.0.1:8091/v1/chat/completions")
        self.assertEqual(sent.json["model"], "engine-model")
        self.assertEqual(sent.headers["authorization"], "Bearer secret")

    def test_only_allowed_client_headers_reach_the_engine(self):
        StubClient.script = [UpstreamResponse()]
        self.forward(engine={"base_url": "http://127.0.0.1:8091/v1"})
        self.assertEqual(StubClient.sent[0].headers, {"content-type": "application/json"})

    def test_a_buffered_answer_drops_hop_headers_and_the_stale_content_encoding(self):
        upstream = UpstreamResponse()
        StubClient.script = [upstream]
        response = self.forward()
        self.assertEqual(response.content, b'{"ok": true}')
        self.assertEqual(response.headers, {"content-type": "application/json", "x-extra": "1"})
        self.assertEqual(upstream.closed, 1)

    def test_an_error_status_from_the_engine_is_passed_through(self):
        StubClient.script = [UpstreamResponse(body=b"bad", status_code=400, content_type="text/plain")]
        response = self.forward()
        self.assertEqual((response.status_code, response.content), (400, b"bad"))

    def test_a_failed_body_read_is_a_503_and_the_connection_is_closed(self):
        upstream = UpstreamResponse(read_error=StubHTTPError("reset"))
        StubClient.script = [upstream]
        self.assertEqual(self.forward().status_code, 503)
        self.assertEqual(upstream.closed, 1)

    def test_a_stream_is_relayed_chunk_by_chunk_then_closed(self):
        upstream = UpstreamResponse(content_type="text/event-stream", chunks=[b"data: 1\n\n", b"data: 2\n\n"])
        StubClient.script = [upstream]
        response = self.forward()
        self.assertEqual(self.collect(response), [b"data: 1\n\n", b"data: 2\n\n"])
        self.assertEqual(upstream.closed, 1)
        self.assertNotIn("content-length", response.headers)

    def test_a_stream_that_breaks_midway_still_closes_the_connection(self):
        upstream = UpstreamResponse(content_type="text/event-stream", chunks=[b"data: 1\n\n", StubTransportError("reset")])
        StubClient.script = [upstream]
        response = self.forward()
        with self.assertRaises(StubTransportError):
            self.collect(response)
        self.assertEqual(upstream.closed, 1)

    def test_a_stale_pooled_connection_is_retried_once(self):
        StubClient.script = [StubTransportError("closed by peer"), UpstreamResponse()]
        self.assertEqual(self.forward().status_code, 200)
        self.assertEqual(len(StubClient.sent), 2)

    def test_an_engine_that_stays_down_is_a_503(self):
        StubClient.script = [StubTransportError("refused"), StubTransportError("refused")]
        self.assertEqual(self.forward().status_code, 503)

    def test_a_malformed_base_url_is_a_503_not_an_exception(self):
        StubClient.script = [StubInvalidURL("bad url")]
        self.assertEqual(self.forward().status_code, 503)
        self.assertEqual(len(StubClient.sent), 1)

    def test_only_responses_bodies_are_translated(self):
        StubClient.script = [UpstreamResponse(), UpstreamResponse()]
        messages = [{"role": "tool", "tool_call_id": "c1", "content": "x"}]
        self.forward(payload={"model": "qwen", "messages": messages})
        self.assertEqual(StubClient.sent[0].json["messages"], messages)
        self.request.url.path = "/v1/responses"
        self.forward(payload={"model": "qwen", "input": [{"type": "message", "role": "tool", "tool_call_id": "c1", "content": "x"}]})
        self.assertEqual(StubClient.sent[1].json["input"][0]["type"], "function_call_output")

    def test_compaction_is_a_501_and_never_reaches_the_engine(self):
        self.request.url.path = "/v1/responses/compact"
        self.assertEqual(self.forward().status_code, 501)
        self.assertEqual(StubClient.sent, [])


if __name__ == "__main__":
    unittest.main()
