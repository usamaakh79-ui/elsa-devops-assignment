import json
import threading
import time
import unittest
import urllib.error
import urllib.request

import main


class QuoteApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = main.make_server(0)  # ephemeral port
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        main._ready.set()
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=5) as r:
                return r.status, r.headers.get("Content-Type"), r.read().decode()
        except urllib.error.HTTPError as e:
            with e:
                return e.code, e.headers.get("Content-Type"), e.read().decode()

    def test_healthz(self):
        status, _, body = self.get("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "ok")

    def test_readyz_follows_ready_flag(self):
        self.assertEqual(self.get("/readyz")[0], 200)
        main._ready.clear()
        try:
            self.assertEqual(self.get("/readyz")[0], 503)
        finally:
            main._ready.set()

    def test_quote_returns_json_and_burns_cpu(self):
        start = time.perf_counter()
        status, ctype, body = self.get("/api/quote")
        elapsed = time.perf_counter() - start
        self.assertEqual(status, 200)
        self.assertEqual(ctype, "application/json")
        self.assertIn(json.loads(body)["quote"], main.QUOTES)
        self.assertGreaterEqual(elapsed, main.CPU_WORK_SECONDS * 0.9)

    def test_metrics_exposes_custom_counter(self):
        self.get("/api/quote")
        status, ctype, body = self.get("/metrics")
        self.assertEqual(status, 200)
        self.assertTrue(ctype.startswith("text/plain"))
        self.assertIn('quote_api_requests_total{method="GET",path="/api/quote",status="200"}', body)
        self.assertIn("quote_api_quotes_served_total", body)

    def test_unknown_path_is_404_with_bounded_label(self):
        self.assertEqual(self.get("/nope/123")[0], 404)
        body = self.get("/metrics")[2]
        self.assertIn('path="other"', body)
        self.assertNotIn("/nope/123", body)


if __name__ == "__main__":
    unittest.main()
