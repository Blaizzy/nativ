import json
import unittest

from scripts.benchmarks.chat_work_browser.benchmark import grade


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
        for answer in [{"tokens": ["B", "A"], "passport": None}, {"tokens": ["A", "B"], "passport": "A"}]:
            self.assertFalse(grade("chain", json.dumps(answer), reads, records)["completed"])
        self.assertTrue(grade("chain", json.dumps({"tokens": ["A", "B"], "passport": None}), reads, records)["completed"])

    def test_repeated_reads_do_not_meet_the_five_page_gate(self):
        result = grade("live", "A comparison", ["https://example.com/source"] * 5, [])
        self.assertFalse(result["completed"])


if __name__ == "__main__":
    unittest.main()
