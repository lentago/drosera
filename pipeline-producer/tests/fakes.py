"""An in-process fake Grafana Cloud Loki plus event builders — no tokens, no network."""

import json
import re
import threading
import urllib.parse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = datetime(2026, 10, 7, 21, 0, 0, tzinfo=timezone.utc)
SHA_A = "a" * 40   # the older main commit
SHA_B = "b" * 40   # the newer main commit (head in most fixtures)
SHA_PR = "c" * 40  # a PR branch head


def at(minutes):
    """``BASE + minutes`` as GitHub-style RFC 3339."""
    return (BASE + timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")


def ns(iso_ts):
    dt = datetime.fromisoformat(iso_ts.replace("Z", "+00:00"))
    return int(dt.timestamp()) * 1_000_000_000


_run_ids = iter(range(1000, 10**6))


def run(repo, event, branch, sha, minute, workflow="CI", conclusion="success", run_id=None, attempt=1):
    """A github_actions_run line (betula clients/github mapping), created a minute before it finished."""
    run_id = run_id or next(_run_ids)
    return {"repo": repo, "workflow": workflow, "run_id": run_id, "run_attempt": attempt,
            "event": event, "branch": branch, "head_sha": sha, "conclusion": conclusion,
            "created_at": at(minute - 1), "updated_at": at(minute),
            "html_url": f"https://github.com/{repo}/actions/runs/{run_id}"}


def job(repo, run_line, minute, name="apply", conclusion="success"):
    return {"repo": repo, "workflow": run_line["workflow"], "run_id": run_line["run_id"],
            "run_attempt": run_line["run_attempt"], "job_id": run_line["run_id"] * 10,
            "job_name": name, "conclusion": conclusion, "completed_at": at(minute),
            "html_url": f"{run_line['html_url']}/job/{run_line['run_id'] * 10}"}


def live(repo, surface, sha, minute, result="noop"):
    return {"sha": sha, "previous_sha": sha, "repo": repo, "surface": surface,
            "result": result, "applied_at": at(minute)}


def parsed(events):
    """Builder dicts → what producer.parse_entries yields (``_ts`` from the line's own time)."""
    out = []
    for e in events:
        stamp = e.get("updated_at") or e.get("completed_at") or e.get("applied_at")
        out.append({**e, "_ts": datetime.fromisoformat(stamp.replace("Z", "+00:00"))})
    return out


_MATCHER = re.compile(r'\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*"((?:[^"\\]|\\.)*)"\s*')


def parse_selector(query):
    """``{a="x", b="y"}`` → dict. Equality matchers only, which is all the producer sends."""
    inner = query.strip()
    assert inner.startswith("{") and inner.endswith("}"), query
    out = {}
    for part in inner[1:-1].split(","):
        m = _MATCHER.fullmatch(part)
        assert m, f"unsupported matcher {part!r}"
        out[m.group(1)] = m.group(2)
    return out


class FakeLoki:
    """Serves ``query_range`` over stored entries and records pushes.

    ``fail_reads`` makes every read answer that HTTP status instead.
    """

    def __init__(self):
        self.entries = []  # (labels, ts_ns, line)
        self.pushes = []
        self.reads = []
        self.fail_reads = None
        self.server = None

    # ── feeding ──
    def add(self, labels, ts_ns, payload):
        self.entries.append((dict(labels), ts_ns, json.dumps(payload, separators=(",", ":"))))

    def add_run(self, payload, cluster="lentago"):
        self.add(_feed_labels("run", cluster, payload["repo"]), ns(payload["updated_at"]), payload)

    def add_job(self, payload, cluster="lentago"):
        self.add(_feed_labels("job", cluster, payload["repo"]), ns(payload["completed_at"]), payload)

    def add_live(self, payload, cluster="lentago"):
        source = payload["repo"].split("/", 1)[1].lstrip(".").replace("-", "_")
        labels = {"log_source": f"{source}_live", "cluster": cluster, "source": source,
                  "pipeline": "change", "stage": "live", "repo": payload["repo"]}
        self.add(labels, ns(payload["applied_at"]), payload)

    # ── the API ──
    def query_range(self, params):
        selector = parse_selector(params["query"])
        start, end = int(params["start"]), int(params["end"])
        limit = int(params.get("limit", 100))
        assert params.get("direction") == "forward"
        hits = sorted((e for e in self.entries
                       if start <= e[1] < end and all(e[0].get(k) == v for k, v in selector.items())),
                      key=lambda e: e[1])[:limit]
        streams = {}
        for labels, ts, line in hits:
            streams.setdefault(tuple(sorted(labels.items())), []).append([str(ts), line])
        result = [{"stream": dict(k), "values": v} for k, v in streams.items()]
        return {"status": "success", "data": {"resultType": "streams", "result": result}}

    def handle(self, method, url, headers, body=None):
        """Transport-shaped entry point: ``(status, text)``."""
        parts = urllib.parse.urlsplit(url)
        if method == "GET" and parts.path == "/loki/api/v1/query_range":
            params = dict(urllib.parse.parse_qsl(parts.query))
            self.reads.append((params, headers))
            if self.fail_reads:
                return self.fail_reads, "invalid scope requested"
            return 200, json.dumps(self.query_range(params))
        if method == "POST" and parts.path == "/loki/api/v1/push":
            self.pushes.append((headers, json.loads(body)))
            return 204, ""
        return 404, "not found"

    def __call__(self, method, url, headers, body=None, timeout=30):
        return self.handle(method, url, headers, body)

    # ── as a real HTTP server, for the CLI test ──
    def start(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def _reply(self, method, body=None):
                headers = {k: v for k, v in self.headers.items()}
                status, text = fake.handle(method, f"http://fake{self.path}", headers, body)
                payload = text.encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):  # noqa: N802
                self._reply("GET")

            def do_POST(self):  # noqa: N802
                self._reply("POST", self.rfile.read(int(self.headers.get("Content-Length", 0))))

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def stop(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()


def _feed_labels(stage, cluster, repo):
    return {"log_source": f"github_actions_{stage}", "cluster": cluster, "source": "github_actions",
            "pipeline": "ci", "stage": stage, "repo": repo}
