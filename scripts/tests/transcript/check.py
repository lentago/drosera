#!/usr/bin/env python3
"""Check what the transcript shipper sent to Loki against expected.json.

    check.py [--wait SECONDS]      LOKI_URL, default http://127.0.0.1:3100

Reads every {job="claude_transcript"} line of the last hour, then checks:
  - the streams and their lines match expected.json (lines compared as sets
    per stream, so equal timestamps can't reorder a pass into a fail);
  - each stream carries exactly its expected labels plus job, worker and
    cluster, so no internal label (evtype, ptype, role, filename) leaks;
  - no LEAK- marker from fixture.py appears in any line or label value.
With --wait it polls until the expected number of lines has arrived or the
time runs out, then checks. Stdlib only.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

LOKI = os.environ.get("LOKI_URL", "http://127.0.0.1:3100")
HERE = os.path.dirname(os.path.abspath(__file__))
FIXED = {"job": "claude_transcript", "worker": "transcript-test", "cluster": "lentago-lab"}
# Loki 3 adds these at ingestion (service-name discovery, level detection);
# Grafana Cloud does the same. Alloy never sends them.
LOKI_ADDED = {"service_name", "detected_level"}


def fetch():
    end = time.time_ns()
    params = {"query": '{job="claude_transcript"}', "start": str(end - 3600 * 10**9),
              "end": str(end), "limit": "5000", "direction": "forward"}
    url = f"{LOKI}/loki/api/v1/query_range?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r)["data"]["result"]


def main():
    expected = json.load(open(os.path.join(HERE, "expected.json")))["streams"]
    want_lines = sum(len(s["lines"]) for s in expected)
    wait = int(sys.argv[2]) if len(sys.argv) == 3 and sys.argv[1] == "--wait" else 0

    deadline = time.time() + wait
    while True:
        got = fetch()
        n = sum(len(s["values"]) for s in got)
        if n >= want_lines or time.time() >= deadline:
            break
        time.sleep(2)
    if wait:
        time.sleep(3)  # let any line that should not be there arrive too
        got = fetch()

    failed = []
    by_labels = {}
    for s in got:
        labels = {k: v for k, v in s["stream"].items() if k not in LOKI_ADDED}
        lines = [v[1] for v in s["values"]]
        for k, v in list(labels.items()) + [("line", l) for l in lines]:
            if "LEAK-" in v:
                failed.append(f"marker reached Loki in {k}: {v[:200]}")
        key = json.dumps({k: v for k, v in labels.items() if k not in FIXED}, sort_keys=True)
        for k, v in FIXED.items():
            if labels.get(k) != v:
                failed.append(f"stream {key}: {k}={labels.get(k)!r}, want {v!r}")
        by_labels.setdefault(key, []).extend(lines)

    for s in expected:
        key = json.dumps(s["labels"], sort_keys=True)
        lines = by_labels.pop(key, None)
        if lines is None:
            failed.append(f"missing stream {key}")
        elif sorted(lines) != sorted(s["lines"]):
            failed.append(f"stream {key}\n  want {sorted(s['lines'])}\n  got  {sorted(lines)}")
        else:
            print(f"ok   {s['labels'].get('runtime', 'claude')}: {len(lines)} lines, labels {key}")
    for key, lines in by_labels.items():
        failed.append(f"unexpected stream {key}: {lines}")

    if failed:
        print("FAIL transcript shipper")
        for f in failed:
            print("  " + f)
        sys.exit(1)
    print("ok   no LEAK- marker reached Loki")


if __name__ == "__main__":
    main()
