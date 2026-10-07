import base64
import unittest

from pipeline_producer.loki import LokiError, LokiPusher, LokiReader, base_url
from tests.fakes import FakeLoki

SEL = '{log_source="x", cluster="lentago"}'


class Reader(unittest.TestCase):
    def setUp(self):
        self.loki = FakeLoki()
        for ts in (10, 20, 20, 20, 30, 40, 50):
            self.loki.add({"log_source": "x", "cluster": "lentago", "repo": "lentago/a"}, ts, {"ts": ts, "n": len(self.loki.entries)})
        self.loki.add({"log_source": "y", "cluster": "lentago"}, 25, {"other": True})

    def test_paginates_without_loss_or_duplicates(self):
        reader = LokiReader("https://logs.example/", "1", "t", page_limit=2, transport=self.loki)
        got = reader.query_range(SEL, 0, 100)
        self.assertEqual([ts for _, ts, _ in got], [10, 20, 20, 20, 30, 40, 50])
        self.assertGreater(len(self.loki.reads), 3)
        params, headers = self.loki.reads[0]
        self.assertEqual((params["limit"], params["direction"], params["query"]), ("2", "forward", SEL))
        self.assertEqual(headers["Authorization"], "Basic " + base64.b64encode(b"1:t").decode())

    def test_full_page_of_one_timestamp_terminates(self):
        reader = LokiReader("https://l", "1", "t", page_limit=1, max_limit=1, transport=self.loki)
        with self.assertLogs("drosera-pipeline", "WARNING"):
            got = reader.query_range(SEL, 0, 100)
        self.assertIn(30, [ts for _, ts, _ in got])  # stepped past ts 20 instead of looping

    def test_window_bounds(self):
        reader = LokiReader("https://l", "1", "t", transport=self.loki)
        self.assertEqual([ts for _, ts, _ in reader.query_range(SEL, 20, 40)], [20, 20, 20, 30])

    def test_read_error(self):
        self.loki.fail_reads = 401
        reader = LokiReader("https://l", "1", "t", transport=self.loki)
        with self.assertRaises(LokiError) as ctx:
            reader.query_range(SEL, 0, 100)
        self.assertEqual(ctx.exception.status, 401)

    def test_network_error(self):
        def boom(*_a, **_k):
            raise OSError("unreachable")
        with self.assertRaises(LokiError):
            LokiReader("https://l", "1", "t", transport=boom).query_range(SEL, 0, 100)

    def test_requires_credentials(self):
        with self.assertRaises(ValueError):
            LokiReader("https://l", "1", "")


class Pusher(unittest.TestCase):
    def test_push(self):
        loki = FakeLoki()
        streams = [{"stream": {"log_source": "change_pipeline_state"}, "values": [["1", "{}"]]}]
        LokiPusher("https://l/loki/api/v1/push", "1", "t", transport=loki).push(streams)
        headers, body = loki.pushes[0]
        self.assertEqual(body, {"streams": streams})
        self.assertEqual(headers["Content-Type"], "application/json")

    def test_push_error(self):
        with self.assertRaises(LokiError):
            LokiPusher("https://l", "1", "t", transport=lambda *a, **k: (500, "boom")).push([])


class Urls(unittest.TestCase):
    def test_base_url(self):
        for url in ("https://l", "https://l/", "https://l/loki/api/v1/push", "https://l/loki/api/v1/query_range"):
            self.assertEqual(base_url(url), "https://l")


if __name__ == "__main__":
    unittest.main()
