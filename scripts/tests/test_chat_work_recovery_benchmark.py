import json
from pathlib import Path
import tempfile
import unittest

from scripts.benchmarks.chat_work_recovery.benchmark import grade


class ChatBrowserBenchmarkGradingTests(unittest.TestCase):
    def test_catalog_index_does_not_replace_a_missing_source_page(self):
        records = [
            {"name": "Scanner-01", "code": "A", "latency_ms": 100, "license": "Apache-2.0", "cpu": True},
            {"name": "Scanner-02", "code": "B", "latency_ms": 200, "license": "Restricted", "cpu": False},
        ]
        answer = json.dumps({"records": records, "total_latency_ms": 300, "recommended": "Scanner-01"})
        incomplete = grade("catalog", answer, ["http://localhost/catalog", "http://localhost/Scanner-01"], records)
        self.assertFalse(incomplete["completed"])
        self.assertEqual(incomplete["required_pages_read"], 1)
        complete = grade("catalog", answer, ["http://localhost/Scanner-01", "http://localhost/Scanner-02"], records)
        self.assertTrue(complete["completed"])

    def test_chain_requires_order_and_preserves_unknown_facts(self):
        records = [{"code": "A"}, {"code": "B"}]
        reads = ["http://localhost/checkpoint/1", "http://localhost/checkpoint/2"]
        for answer in [{"tokens": ["B", "A"], "passport": None}, {"tokens": ["A", "B"], "passport": "A"},
                       {"tokens": ["A", "B", "invented"], "passport": None}]:
            self.assertFalse(grade("chain", json.dumps(answer), reads, records)["completed"])
        self.assertTrue(grade("chain", json.dumps({"tokens": ["A", "B"], "passport": None}), reads, records)["completed"])

    def test_tool_call_markup_is_not_a_final_research_answer(self):
        result = grade("live", '<|tool_call>call:chat_work{}<tool_call|>',
                       [f"https://example.com/{i}" for i in range(5)], [])
        self.assertFalse(result["completed"])
        self.assertFalse(result["final_answer_present"])

    def test_repeated_reads_do_not_meet_the_five_page_gate(self):
        result = grade("live", "A comparison", ["https://example.com/source"] * 5, [])
        self.assertFalse(result["completed"])

    def test_live_summary_requires_a_source_review(self):
        from scripts.benchmarks.chat_work_recovery.summarize import metrics
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "result.json"
            path.write_text(json.dumps({"config": {"case": "live", "context": 8192, "mode": "recovery"},
                "grade": {}, "steps": [], "task_seconds": 1, "final": "A comparison",
                "read_urls": [f"https://example.com/{i}" for i in range(5)]}))
            self.assertTrue(metrics(path)["grade"]["automatic_gate_passed"])
            self.assertFalse(metrics(path)["completed"])
            path.with_name("review.json").write_text(json.dumps({"completed": False, "reason": "Error pages"}))
            self.assertFalse(metrics(path)["completed"])
            path.with_name("review.json").write_text(json.dumps({"completed": True, "reason": "Five relevant pages verified"}))
            self.assertTrue(metrics(path)["completed"])


class ResponsesReplayTests(unittest.TestCase):
    def test_failed_stream_preserves_request_and_server_error(self):
        from unittest.mock import patch
        from scripts.benchmarks.chat_work_recovery.benchmark import generate_responses, ResponseStreamFailure
        event = {"type": "response.failed", "response": {"error": {"message": "Tool arguments mismatch"}}}
        class Stream:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def __iter__(self): return iter([b"data: " + json.dumps(event).encode()])
        with patch("urllib.request.urlopen", return_value=Stream()), self.assertRaises(ResponseStreamFailure) as caught:
            generate_responses("http://localhost", {"model": "fixture", "max_tokens": 100},
                               [{"role": "user", "content": "Research"}], [], "Current evidence", 8192, None, 0)
        self.assertEqual(caught.exception.capture["events"], [event])
        self.assertEqual(caught.exception.capture["request"]["transient_context"], "Current evidence")
        self.assertIn("Tool arguments mismatch", str(caught.exception))

    def test_compaction_replay_keeps_fresh_context_outside_saved_prefix(self):
        from unittest.mock import patch
        from scripts.benchmarks.chat_work_recovery.benchmark import generate_responses
        capsule = {"type": "compaction", "encrypted_content": "opaque"}
        seen = []
        class Stream:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def __iter__(self):
                response = {"status": "completed", "usage": {"input_tokens": 123, "output_tokens": 3},
                            "output": [capsule, {"type": "message", "content": [{"type": "output_text", "text": "answer"}]}]}
                return iter([b"data: " + json.dumps({"type": "response.completed", "response": response}).encode()])
        def open_request(request, **kwargs):
            seen.append(json.loads(request.data)); return Stream()
        messages = [{"role": "system", "content": "System"}, {"role": "user", "content": "Research"}]
        sampling = {"model": "fixture", "max_tokens": 4096}
        with patch("urllib.request.urlopen", open_request):
            first, saved, count = generate_responses("http://localhost", sampling, messages, [], "First evidence", 8192, None, 0)
            self.assertEqual(count, 1)
            self.assertEqual(first["message"]["content"], "answer")
            messages.append({"role": "assistant", "content": "Next turn"})
            generate_responses("http://localhost", sampling, messages, [], "New evidence", 8192, saved, count, final_instruction="Finish honestly")
        self.assertEqual(seen[1]["input"], [capsule, {"type": "message", "role": "assistant", "content": "Next turn"}])
        self.assertEqual(seen[1]["transient_context"], "New evidence\n\nFinish honestly")
        self.assertEqual(seen[1]["instructions"], "System\n\nFinish honestly")
        self.assertEqual(seen[1]["max_output_tokens"], 4096)
        self.assertEqual(seen[1]["context_management"][0]["compact_threshold"], 6144)


if __name__ == "__main__":
    unittest.main()
