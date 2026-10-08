import json
import os
import threading
import unittest
import urllib.error
import urllib.request
from datetime import timedelta

from pipeline_producer.config import Config
from pipeline_producer.loki import LokiPusher, LokiReader
from pipeline_producer.producer import Producer, make_server, parse_entries
from tests.fakes import BASE, SHA_B, SHA_PR, FakeLoki, at, job, live, run

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DROSERA = "lentago/drosera"


def seeded_loki():
    loki = FakeLoki()
    main = run(DROSERA, "push", "main", SHA_B, 4, workflow="terraform")
    loki.add_run(run(DROSERA, "pull_request", "agent/x", SHA_PR, 0, workflow="ShellCheck"))
    loki.add_run(main)
    loki.add_job(job(DROSERA, main, 5))
    loki.add_live(live(DROSERA, "alloy-lxc105", SHA_B, 7, result="applied"))
    # Another org's events and the producer's own state stream must not be read.
    loki.add_run(run("other/repo", "push", "main", SHA_B, 4), cluster="other")
    loki.add({"log_source": "change_pipeline_state", "cluster": "lentago", "repo": "lentago/ghost"},
             int((BASE + timedelta(minutes=6)).timestamp()) * 10**9, {"stage": "live", "state": 3})
    return loki


class Ticks(unittest.TestCase):
    def setUp(self):
        self.loki = seeded_loki()
        self.now = BASE + timedelta(minutes=8)
        cfg = Config.load(os.path.join(HERE, "config.json"))
        self.producer = Producer(cfg, LokiReader("https://l", "1", "r", transport=self.loki),
                                 LokiPusher("https://l", "1", "w", transport=self.loki),
                                 clock=lambda: self.now)

    def test_tick_reads_the_three_streams_over_the_window(self):
        doc = self.producer.tick()
        queries = {p["query"] for p, _ in self.loki.reads}
        self.assertEqual(queries, {'{log_source="github_actions_run", cluster="lentago"}',
                                   '{log_source="github_actions_job", cluster="lentago"}',
                                   '{pipeline="change", stage="live", cluster="lentago"}'})
        params = self.loki.reads[0][0]
        self.assertEqual(int(params["end"]) - int(params["start"]), 86400 * 10**9)
        self.assertEqual([r["repo"] for r in doc["repos"]], [DROSERA])
        self.assertEqual([s["state"] for s in doc["repos"][0]["stages"]], [3, 0, 3, 3, 3, 3])

    def test_tick_pushes_state_without_pipeline_labels(self):
        self.producer.tick()
        (_, body), = self.loki.pushes
        stream = body["streams"][0]
        self.assertEqual(stream["stream"], {"log_source": "change_pipeline_state", "cluster": "lentago", "repo": DROSERA})
        self.assertEqual(len(stream["values"]), 6)

    def test_failed_read_keeps_the_last_document(self):
        self.producer.tick()
        good = self.producer.body()
        self.loki.fail_reads = 503
        self.now += timedelta(minutes=5)
        self.assertIsNone(self.producer.tick())
        self.assertEqual(self.producer.body(), good)
        self.assertEqual(json.loads(good)["generated_at"], at(8))
        self.assertEqual(len(self.loki.pushes), 1)  # nothing pushed for the failed tick

    def test_failed_push_still_publishes(self):
        self.producer.pusher = LokiPusher("https://l", "1", "w", transport=lambda *a, **k: (401, "no"))
        self.assertIsNotNone(self.producer.tick())
        self.assertIsNotNone(self.producer.body())


class Server(unittest.TestCase):
    def setUp(self):
        cfg = Config.load(os.path.join(HERE, "config.json"))
        self.loki = seeded_loki()
        self.producer = Producer(cfg, LokiReader("https://l", "1", "r", transport=self.loki),
                                 clock=lambda: BASE + timedelta(minutes=8))
        self.server = make_server(self.producer, "127.0.0.1", 0)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=5) as resp:
                return resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.headers, exc.read()

    def test_healthz(self):
        self.assertEqual(self.get("/healthz")[::2], (200, b"ok\n"))

    def test_no_document_before_first_success(self):
        self.assertEqual(self.get("/viewport/pipeline.json")[0], 503)

    def test_any_path_serves_the_document(self):
        self.producer.tick()
        for path in ("/", "/pipeline.json", "/viewport/pipeline.json"):
            status, headers, body = self.get(path)
            self.assertEqual(status, 200)
            self.assertEqual(headers["Content-Type"], "application/json")
            self.assertEqual(headers["Cache-Control"], "max-age=10")
            self.assertEqual(json.loads(body)["schema"], 1)


class Parsing(unittest.TestCase):
    def test_parse_entries(self):
        got = parse_entries([({"repo": "lentago/a"}, 10**18, '{"x": 1}'),
                             ({"repo": "lentago/a"}, 1, "not json"),
                             ({"repo": "lentago/a"}, 1, "[1, 2]"),
                             ({"repo": "lentago/a"}, 1, '{"repo": "lentago/b"}')])
        self.assertEqual([g["repo"] for g in got], ["lentago/a", "lentago/b"])
        self.assertEqual(got[0]["_ts"].year, 2001)


if __name__ == "__main__":
    unittest.main()
