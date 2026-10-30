#!/usr/bin/env python3
"""Run an alert rule's LogQL against fixture lines in a real Loki.

    run.py <expr.logql> <case-dir>   (LOKI_URL, default http://127.0.0.1:3100)

<case-dir>/fixture.json holds streams of lines, each placed `offset_s` seconds
before "now". They are pushed to Loki, the expression is evaluated as an instant
query at "now" (as Grafana's instant alert query does), and the resulting vector
must equal <case-dir>/expected.json: a list of {"metric": {...}, "value": n}.
An empty list means the rule stays silent.

The expression file is the one Terraform reads with file(), so the test runs
the deployed query, not a copy of it. Stdlib only.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

LOKI = os.environ.get("LOKI_URL", "http://127.0.0.1:3100")


def push(streams, now_ns):
    body = {"streams": []}
    for s in streams:
        values = sorted(
            (str(now_ns - int(l["offset_s"]) * 10**9), json.dumps(l["line"], separators=(",", ":")))
            for l in s["lines"]
        )
        body["streams"].append({"stream": s["labels"], "values": [list(v) for v in values]})
    req = urllib.request.Request(
        f"{LOKI}/loki/api/v1/push",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        if r.status != 204:
            sys.exit(f"push: HTTP {r.status}")


def query(expr, now_ns):
    q = urllib.parse.urlencode({"query": expr, "time": str(now_ns)})
    with urllib.request.urlopen(f"{LOKI}/loki/api/v1/query?{q}", timeout=10) as r:
        data = json.load(r)["data"]
    if data["resultType"] != "vector":
        sys.exit(f"query: expected a vector, got {data['resultType']}")
    return sorted(
        ({"metric": s["metric"], "value": float(s["value"][1])} for s in data["result"]),
        key=lambda s: json.dumps(s["metric"], sort_keys=True),
    )


def main():
    expr_file, case = sys.argv[1], sys.argv[2]
    expr = open(expr_file).read().strip()
    fixture = json.load(open(os.path.join(case, "fixture.json")))
    expected = sorted(
        ({"metric": e["metric"], "value": float(e["value"])} for e in json.load(open(os.path.join(case, "expected.json")))),
        key=lambda s: json.dumps(s["metric"], sort_keys=True),
    )
    now_ns = time.time_ns()
    push(fixture["streams"], now_ns)
    got = None
    for _ in range(10):  # the ingester answers within a second or two of the push
        got = query(expr, now_ns)
        if got == expected:
            break
        time.sleep(1)
    name = os.path.basename(os.path.normpath(case))
    if got != expected:
        print(f"FAIL {name}")
        print("expected:", json.dumps(expected, indent=2))
        print("got:     ", json.dumps(got, indent=2))
        sys.exit(1)
    print(f"ok   {name}: {len(expected)} series, as expected")
    for c in fixture.get("cases", []):
        print(f"       - {c}")


if __name__ == "__main__":
    main()
