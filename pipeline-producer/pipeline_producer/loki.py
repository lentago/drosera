"""Small stdlib Loki client: paginated ``query_range`` reads and batched pushes.

clients/loki_push.py sends one event and insists on the six-label client
shape (``pipeline``, ``stage``, …). The state stream must carry neither of
those labels, so the producer carries its own pusher.
"""

import base64
import json
import logging
import urllib.error
import urllib.parse
import urllib.request

API_PREFIX = "/loki/api/v1"
QUERY_RANGE_PATH = API_PREFIX + "/query_range"
PUSH_PATH = API_PREFIX + "/push"

log = logging.getLogger("drosera-pipeline")


class LokiError(RuntimeError):
    def __init__(self, status, body):
        super().__init__(f"Loki request failed: HTTP {status}: {str(body)[:300]}")
        self.status = status
        self.body = body


def base_url(url):
    """``https://logs-prod-NNN.grafana.net[/loki/api/v1/…]`` → the bare base URL."""
    url = url.rstrip("/")
    cut = url.find(API_PREFIX)
    return url[:cut] if cut != -1 else url


def _basic(user, token):
    return "Basic " + base64.b64encode(f"{user}:{token}".encode()).decode()


def _transport(method, url, headers, body=None, timeout=30):
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")


class LokiReader:
    """Reads raw log lines; the producer does all parsing and joining in Python."""

    # Grafana Cloud's max_entries_limit_per_query; a larger limit answers 400.
    MAX_LIMIT = 5000

    def __init__(self, url, user, token, page_limit=MAX_LIMIT, max_limit=MAX_LIMIT, transport=_transport):
        if not (url and user and token):
            raise ValueError("Loki url, user and token are all required")
        self.url = base_url(url) + QUERY_RANGE_PATH
        self._auth = _basic(user, token)
        self.page_limit = page_limit
        self.max_limit = max(max_limit, page_limit)
        self._transport = transport

    def _page(self, query, start_ns, end_ns, limit):
        params = urllib.parse.urlencode({
            "query": query, "start": str(start_ns), "end": str(end_ns),
            "limit": str(limit), "direction": "forward",
        })
        try:
            status, text = self._transport("GET", f"{self.url}?{params}", {"Authorization": self._auth})
        except (urllib.error.URLError, OSError) as exc:
            raise LokiError(None, exc) from exc
        if not 200 <= status < 300:
            raise LokiError(status, text)
        try:
            data = json.loads(text)["data"]
        except (ValueError, KeyError, TypeError) as exc:
            raise LokiError(status, f"unparseable response: {text}") from exc
        if data.get("resultType") != "streams":
            raise LokiError(status, f"expected streams, got {data.get('resultType')!r}")
        entries = []
        for stream in data.get("result") or []:
            labels = stream.get("stream") or {}
            for ts, line in stream.get("values") or []:
                entries.append((labels, int(ts), line))
        return entries

    def query_range(self, query, start_ns, end_ns):
        """Every entry in ``[start_ns, end_ns)`` as ``(labels, ts_ns, line)``, oldest first.

        Pages forward with ``limit``: the next page starts at the newest
        timestamp seen (inclusive, since a full page can stop part-way through
        a nanosecond), and entries already seen are dropped.
        """
        seen, out, start, limit = set(), [], start_ns, self.page_limit
        while start < end_ns:
            page = self._page(query, start, end_ns, limit)
            for labels, ts, line in page:
                key = (tuple(sorted(labels.items())), ts, line)
                if key not in seen:
                    seen.add(key)
                    out.append((labels, ts, line))
            if len(page) < limit:
                break
            newest = max(ts for _, ts, _ in page)
            if newest > start:
                start, limit = newest, self.page_limit
            elif limit < self.max_limit:
                # A full page inside one nanosecond: widen it rather than lose lines.
                limit = min(limit * 2, self.max_limit)
            else:
                # Still full at Loki's cap: step past this nanosecond, or loop forever.
                log.warning("over %d lines at %d ns for %s; skipping the rest of them", limit, start, query)
                start += 1
        out.sort(key=lambda e: e[1])
        return out


class LokiPusher:
    def __init__(self, url, user, token, transport=_transport):
        if not (url and user and token):
            raise ValueError("Loki url, user and token are all required")
        self.url = base_url(url) + PUSH_PATH
        self._auth = _basic(user, token)
        self._transport = transport

    def push(self, streams):
        """POST ``[{"stream": {...}, "values": [[ts, line], ...]}, ...]`` in one request."""
        body = json.dumps({"streams": streams}, separators=(",", ":")).encode()
        headers = {"Content-Type": "application/json", "Authorization": self._auth}
        try:
            status, text = self._transport("POST", self.url, headers, body)
        except (urllib.error.URLError, OSError) as exc:
            raise LokiError(None, exc) from exc
        if not 200 <= status < 300:
            raise LokiError(status, text)
