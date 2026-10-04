#!/usr/bin/env python3
"""Mock Loki push endpoint for the loki-event workflow test.

Records every POST as one JSON line in the capture file (path, auth header,
content type, parsed body) and answers 204 like real Loki. A path under
/status/<code>/ answers <code> instead, so a test can point loki_url at
http://host:port/status/500 to exercise the failure path. Any other path
that isn't .../loki/api/v1/push answers 404, which catches URL-building bugs.

Usage: mock_loki.py <port> <capture-file>
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, CAPTURE = int(sys.argv[1]), sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(CAPTURE, "a") as f:
            f.write(json.dumps({
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "content_type": self.headers.get("Content-Type"),
                "body": json.loads(raw or b"null"),
            }) + "\n")
        forced = re.match(r"^/status/(\d{3})/", self.path)
        if forced:
            code = int(forced.group(1))
        elif self.path.endswith("/loki/api/v1/push"):
            code = 204
        else:
            code = 404
        self.send_response(code)
        self.end_headers()
        if code >= 400:
            self.wfile.write(b"mock loki: forced failure\n")

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
