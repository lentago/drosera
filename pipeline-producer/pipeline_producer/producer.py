"""One producer process: a compute loop plus an HTTP server sharing the last good document."""

import json
import logging
import os
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import state
from .loki import LokiError

log = logging.getLogger("drosera-pipeline")

QUERIES = {
    "runs": '{log_source="github_actions_run", cluster="%s"}',
    "jobs": '{log_source="github_actions_job", cluster="%s"}',
    "lives": '{pipeline="change", stage="live", cluster="%s"}',
}


def parse_entries(entries):
    """Loki ``(labels, ts_ns, line)`` → payload dicts with ``repo`` and ``_ts`` set.

    Lines that aren't JSON objects are skipped; the stream's ``repo`` label
    fills in when the payload lacks one.
    """
    out = []
    for labels, ts_ns, line in entries:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        event.setdefault("repo", labels.get("repo"))
        event["_ts"] = datetime.fromtimestamp(ts_ns / 1e9, tz=timezone.utc)
        out.append(event)
    return out


def compute(cfg, reader, now):
    """Read the window from Loki and build the document. Raises LokiError on a failed read."""
    end_ns = int(now.timestamp()) * 1_000_000_000
    start_ns = end_ns - cfg.window_s * 1_000_000_000
    events = {kind: parse_entries(reader.query_range(query % cfg.cluster, start_ns, end_ns))
              for kind, query in QUERIES.items()}
    return state.build_document(events["runs"], events["jobs"], events["lives"], now, cfg)


class Producer:
    """Holds the last good document. A failed tick keeps serving it unchanged,
    so ``generated_at`` always names the last successful compute."""

    def __init__(self, cfg, reader, pusher=None, out=None, clock=None):
        self.cfg = cfg
        self.reader = reader
        self.pusher = pusher
        self.out = out
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self._lock = threading.Lock()
        self._body = None

    def body(self):
        with self._lock:
            return self._body

    def tick(self):
        """One compute + publish + push. Returns the document, or None if the read failed."""
        now = self.clock()
        try:
            document = compute(self.cfg, self.reader, now)
        except LokiError as exc:
            log.warning("Loki read failed, keeping the last document: %s", exc)
            return None
        except Exception:  # noqa: BLE001 — a bad line must not kill the service
            log.exception("compute failed, keeping the last document")
            return None
        body = (json.dumps(document, indent=2) + "\n").encode()
        with self._lock:
            self._body = body
        if self.out:
            write_out(self.out, body)
        if self.pusher:
            try:
                self.pusher.push(state.state_streams(document, self.cfg.cluster, time.time_ns()))
            except LokiError as exc:
                log.warning("change_pipeline_state push failed: %s", exc)
        stuck = [r["repo"] for r in document["repos"] if r["stuck"]]
        log.info("computed %d repo(s); in flight %d; stuck %s", len(document["repos"]),
                 sum(r["in_flight"] for r in document["repos"]), ", ".join(stuck) or "none")
        return document

    def run(self, stop):
        """Tick every interval until ``stop`` (a threading.Event) is set."""
        while not stop.is_set():
            started = time.monotonic()
            self.tick()
            stop.wait(max(1.0, self.cfg.interval_s - (time.monotonic() - started)))


def write_out(path, body):
    if path == "-":
        sys.stdout.write(body.decode())
        sys.stdout.flush()
        return
    tmp = f"{path}.tmp"
    with open(tmp, "wb") as fh:
        fh.write(body)
    os.replace(tmp, path)


def make_server(producer, host, port):
    class Handler(BaseHTTPRequestHandler):
        server_version = "drosera-pipeline"

        def do_GET(self):  # noqa: N802 — http.server's naming
            if self.path.split("?", 1)[0] == "/healthz":
                return self._send(200, b"ok\n", "text/plain; charset=utf-8")
            body = producer.body()
            if body is None:
                # No successful read yet: a missing document lets the brasenia
                # pane leave the row out, an empty one would claim no repos.
                return self._send(503, b'{"error": "no document yet"}\n', "application/json")
            return self._send(200, body, "application/json", {"Cache-Control": "max-age=10"})

        def _send(self, status, body, content_type, extra=None):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            for name, value in (extra or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):  # the proxy polls; keep the journal quiet
            log.debug("%s %s", self.address_string(), fmt % args)

    return ThreadingHTTPServer((host, port), Handler)
