"""Unit tests for sites_live.probe against in-process fake HTTP servers.

Run: python3 -m unittest discover -s sites-live -t sites-live -v
"""
import json
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from sites_live import probe

SHA_A = "a" * 40
SHA_B = "b" * 40


class FakeSite(BaseHTTPRequestHandler):
    """Serves whatever `behaviour` says: ('json', obj) | ('raw', bytes) | ('status', n) | ('sleep', s)."""
    behaviour = {}

    def do_GET(self):
        kind, arg = FakeSite.behaviour.get(self.headers["Host"], ("status", 404))
        if kind == "sleep":
            time.sleep(arg)
            return
        body = b""
        code = 200
        if kind == "json":
            body = json.dumps(arg).encode()
        elif kind == "raw":
            body = arg
        else:
            code = arg
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ProbeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeSite)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}/version.json"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        FakeSite.behaviour = {}
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / "seen.json"
        self.pushes = []

    def fake_push(self, *args):
        self.pushes.append(args)

    def tick(self, sites, **kw):
        # Every site resolves to the one fake server.
        return probe.run(sites, self.state, "http://loki", "1:tok",
                         url_for=lambda h: self.base, timeout=kw.pop("timeout", 2),
                         hostname="lxc105", push=self.fake_push, **kw)

    def serve(self, obj):
        FakeSite.behaviour = {f"127.0.0.1:{self.server.server_port}": obj}

    def site(self, surface="site-x", repo="lentago/site-x"):
        return {"host": "x.example", "repo": repo, "surface": surface}

    def test_applied_then_noop_then_changed(self):
        self.serve(("json", {"sha": SHA_A, "repo": "lentago/site-x", "built_at": "2026-10-07T12:00:00Z"}))
        first = self.tick([self.site()])
        self.assertEqual(first[0]["result"], "applied")
        self.assertEqual(self.tick([self.site()])[0]["result"], "noop")
        self.serve(("json", {"sha": SHA_B}))
        third = self.tick([self.site()])[0]
        self.assertEqual((third["result"], third["sha"], third["previous_sha"]), ("applied", SHA_B, SHA_A))
        self.assertEqual(len(self.pushes), 3)

    def test_event_contract(self):
        self.serve(("json", {"sha": SHA_A, "built_at": "2026-10-07T12:00:00Z"}))
        self.tick([self.site()])
        _, _, cluster, source, pipeline, stage, repo, payload = self.pushes[0]
        self.assertEqual((cluster, source, pipeline, stage, repo),
                         ("lentago", "sites", "change", "live", "lentago/site-x"))
        self.assertEqual(f"{source}_{stage}", "sites_live")
        for key in ("sha", "previous_sha", "repo", "surface", "result", "applied_at", "host"):
            self.assertIn(key, payload)
        self.assertRegex(payload["applied_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(payload["built_at"], "2026-10-07T12:00:00Z")
        self.assertEqual(payload["host"], "lxc105")

    def test_no_signal_emits_nothing(self):
        cases = {
            "404": ("status", 404),
            "500": ("status", 500),
            "malformed": ("raw", b"{not json"),
            "not-object": ("raw", b"[1]"),
            "bad-sha": ("json", {"sha": "xyz"}),
            "timeout": ("sleep", 1.0),
        }
        for name, behaviour in cases.items():
            with self.subTest(name):
                self.serve(behaviour)
                self.assertEqual(self.tick([self.site()], timeout=0.2), [])
        self.assertEqual(self.pushes, [])

    def test_connection_refused_does_not_raise(self):
        out = probe.run([self.site()], self.state, "u", "1:t",
                        url_for=lambda h: "http://127.0.0.1:1/version.json",
                        timeout=1, push=self.fake_push)
        self.assertEqual(out, [])

    def test_two_surfaces_one_repo(self):
        self.serve(("json", {"sha": SHA_A}))
        sites = [self.site("site-pondviewlane-com", "lentago/site-pondviewlane-com"),
                 self.site("site-essexcrossingatmontserrat-com", "lentago/site-pondviewlane-com")]
        out = self.tick(sites)
        self.assertEqual([e["surface"] for e in out], [s["surface"] for s in sites])
        self.assertEqual({p[6] for p in self.pushes}, {"lentago/site-pondviewlane-com"})

    def test_failed_push_is_swallowed_and_retried_as_applied(self):
        self.serve(("json", {"sha": SHA_A}))

        def boom(*a):
            raise OSError("loki down")
        self.assertEqual(probe.run([self.site()], self.state, "u", "1:t", url_for=lambda h: self.base,
                                   push=boom), [])
        self.assertEqual(self.tick([self.site()])[0]["result"], "applied")

    def test_dry_run_prints_and_keeps_state(self):
        self.serve(("json", {"sha": SHA_A}))
        self.tick([self.site()], dry_run=True)
        self.assertEqual(self.pushes, [])
        self.assertFalse(self.state.exists())

    def test_shipped_config_is_valid(self):
        sites = probe.load_sites(Path(probe.__file__).resolve().parent.parent / "sites.json")
        self.assertEqual(len(sites), 4)
        self.assertEqual(len({s["surface"] for s in sites}), 4)


if __name__ == "__main__":
    unittest.main()
