"""Unit tests for loki_push.push_event against an in-process mock Loki.

Run: python3 -m unittest discover -s clients -v
"""
import base64
import json
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer

from loki_push import push_event


class _MockLoki(BaseHTTPRequestHandler):
    status = 204
    requests = []

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        _MockLoki.requests.append({
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "content_type": self.headers.get("Content-Type"),
            "body": json.loads(raw),
        })
        self.send_response(_MockLoki.status)
        self.end_headers()

    def log_message(self, *args):
        pass


class PushEventTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), _MockLoki)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        _MockLoki.status = 204
        _MockLoki.requests = []
        self.args = dict(
            loki_url=self.url, loki_token="123456:glc_fake", cluster="lentago",
            source="uvularia", pipeline="ask", stage="answer", repo="lentago/uvularia",
            payload={"run": "r-1", "ms": 42},
        )

    def test_pushes_one_line_with_labels(self):
        self.assertEqual(push_event(**self.args), 204)
        self.assertEqual(len(_MockLoki.requests), 1)
        req = _MockLoki.requests[0]
        self.assertEqual(req["path"], "/loki/api/v1/push")
        self.assertEqual(req["content_type"], "application/json")
        self.assertEqual(req["authorization"], "Basic " + base64.b64encode(b"123456:glc_fake").decode())
        (stream,) = req["body"]["streams"]
        self.assertEqual(stream["stream"], {
            "log_source": "uvularia_answer", "cluster": "lentago", "source": "uvularia",
            "pipeline": "ask", "stage": "answer", "repo": "lentago/uvularia",
        })
        ((ts, line),) = stream["values"]
        self.assertRegex(ts, r"^\d{19}$")  # nanoseconds since epoch
        self.assertNotIn("\n", line)
        self.assertEqual(json.loads(line), {"run": "r-1", "ms": 42})

    def test_full_push_url_is_not_doubled(self):
        self.args["loki_url"] = self.url + "/loki/api/v1/push/"
        push_event(**self.args)
        self.assertEqual(_MockLoki.requests[0]["path"], "/loki/api/v1/push")

    def test_http_error_raises(self):
        _MockLoki.status = 401
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            push_event(**self.args)
        self.assertEqual(ctx.exception.code, 401)

    def test_bad_label_rejected_before_sending(self):
        for name, bad in [("stage", "Answer"), ("stage", "an-swer"), ("source", ""),
                          ("pipeline", "run 123"), ("repo", "uvularia"), ("cluster", None)]:
            with self.subTest(name=name, value=bad):
                with self.assertRaises(ValueError):
                    push_event(**{**self.args, name: bad})
        self.assertEqual(_MockLoki.requests, [])

    def test_bad_token_or_payload_rejected(self):
        for override in [{"loki_token": "glc_no_user"}, {"loki_token": ":tok"}, {"payload": [1, 2]}]:
            with self.subTest(**{k: repr(v) for k, v in override.items()}):
                with self.assertRaises(ValueError):
                    push_event(**{**self.args, **override})
        self.assertEqual(_MockLoki.requests, [])


if __name__ == "__main__":
    unittest.main()
