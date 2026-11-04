#!/usr/bin/env python3
"""Run deployed LogQL against fixture lines in a real Loki.

    run.py <expr.logql> <case-dir>   one alert rule, one expected vector
    run.py <case-dir>                several checks over one fixture (checks.json)

    LOKI_URL, default http://127.0.0.1:3100

<case-dir>/fixture.json holds streams of lines, each placed `offset_s` seconds
before "now". They are pushed to Loki once, and each expression is evaluated at
"now".

Two-argument form (alert rules): the expression is evaluated as an instant
query (as Grafana's instant alert query does), and the resulting vector must
equal <case-dir>/expected.json: a list of {"metric": {...}, "value": n}. An
empty list means the rule stays silent.

One-argument form (dashboard panels): <case-dir>/checks.json is a list of
{"name", "expr", "expected"} and, optionally, "kind": "lines".
  - "expr" is a .logql path, or "<dashboard.json>#<panel id>/<refId>" to read
    a panel target's expression out of the dashboard JSON.
  - Grafana variables ($name or ${name}) are replaced from fixture.json "vars",
    for example {"project": ".*", "__range": "1h"}. Others are left as they are.
  - The default kind is a vector, compared as in the two-argument form. "lines"
    runs a log query over the last `range_s` seconds (fixture.json, default
    3600) and compares the sorted rendered lines with "expected".

Either way the expression is the one Terraform deploys (a file it reads with
file(), or the dashboard JSON it uploads), so the test runs the deployed query,
not a copy of it. Each case needs a fresh Loki: lines pushed by an earlier run
stay in the window and count again. Stdlib only.
"""
import json
import os
import re
import sys
import time
import urllib.error
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


def get(path, params):
    url = f"{LOKI}{path}?{urllib.parse.urlencode(params)}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)["data"]
    except urllib.error.HTTPError as e:
        sys.exit(f"query: HTTP {e.code}: {e.read().decode().strip()}\n  {params['query']}")


def query(expr, now_ns):
    data = get("/loki/api/v1/query", {"query": expr, "time": str(now_ns)})
    if data["resultType"] != "vector":
        sys.exit(f"query: expected a vector, got {data['resultType']}")
    return sorted(
        ({"metric": s["metric"], "value": float(s["value"][1])} for s in data["result"]),
        key=lambda s: json.dumps(s["metric"], sort_keys=True),
    )


def query_lines(expr, now_ns, range_s):
    data = get(
        "/loki/api/v1/query_range",
        {"query": expr, "start": str(now_ns - range_s * 10**9), "end": str(now_ns), "limit": "1000"},
    )
    if data["resultType"] != "streams":
        sys.exit(f"query: expected streams, got {data['resultType']}")
    return sorted(v[1] for s in data["result"] for v in s["values"])


def panel_expr(dashboard, panel_id, ref_id):
    def walk(panels):
        for p in panels:
            yield p
            yield from walk(p.get("panels", []))

    for p in walk(json.load(open(dashboard))["panels"]):
        if str(p.get("id")) == panel_id:
            for t in p.get("targets", []):
                if t.get("refId") == ref_id:
                    return t["expr"]
            sys.exit(f"{dashboard}: panel {panel_id} has no target {ref_id}")
    sys.exit(f"{dashboard}: no panel {panel_id}")


def resolve(src, variables):
    if "#" in src:
        path, frag = src.split("#", 1)
        panel_id, ref_id = frag.split("/", 1)
        expr = panel_expr(path, panel_id, ref_id)
    else:
        expr = open(src).read().strip()

    def sub(m):
        name = m.group(1) or m.group(2)
        return variables.get(name, m.group(0))

    return re.sub(r"\$\{(\w+)\}|\$(\w+)", sub, expr)


def vector(entries):
    return sorted(
        ({"metric": e["metric"], "value": float(e["value"])} for e in entries),
        key=lambda s: json.dumps(s["metric"], sort_keys=True),
    )


def check(run, expected):
    got = None
    for _ in range(10):  # the ingester answers within a second or two of the push
        got = run()
        if got == expected:
            break
        time.sleep(1)
    return got


def main():
    if len(sys.argv) == 3:
        expr_file, case = sys.argv[1], sys.argv[2]
        checks = [{"name": None, "expr": expr_file, "expected": json.load(open(os.path.join(case, "expected.json")))}]
    elif len(sys.argv) == 2:
        case = sys.argv[1]
        checks = json.load(open(os.path.join(case, "checks.json")))
    else:
        sys.exit(__doc__)
    fixture = json.load(open(os.path.join(case, "fixture.json")))
    variables = fixture.get("vars", {})
    range_s = int(fixture.get("range_s", 3600))
    name = os.path.basename(os.path.normpath(case))

    now_ns = time.time_ns()
    push(fixture["streams"], now_ns)
    failed = 0
    for c in checks:
        expr = resolve(c["expr"], variables)
        label = f"{name}: {c['name']}" if c["name"] else name
        if c.get("kind") == "lines":
            expected = sorted(c["expected"])
            got = check(lambda: query_lines(expr, now_ns, range_s), expected)
            what = f"{len(expected)} lines"
        else:
            expected = vector(c["expected"])
            got = check(lambda: query(expr, now_ns), expected)
            what = f"{len(expected)} series"
        if got != expected:
            failed += 1
            print(f"FAIL {label}")
            print("  expr:    ", expr)
            print("  expected:", json.dumps(expected, indent=2))
            print("  got:     ", json.dumps(got, indent=2))
        else:
            print(f"ok   {label}: {what}, as expected")
    for c in fixture.get("cases", []):
        print(f"       - {c}")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
