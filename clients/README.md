# clients — push events into Grafana Cloud Loki from anywhere

**What you're about to do:** send one structured event from a serverless
function (AWS Lambda or similar) to a Grafana Cloud Loki you own, using
[`loki_push.py`](loki_push.py) — a single stdlib-only Python file you copy
into your function. No pip install, no layer, no agent.

**Why bother:** functions have nowhere to run Alloy, and until now drosera had
no way in for anything that wasn't a host or the Firewalla. With one event per
stage, a dashboard can follow a request from intake to answer. uvularia's Ask
function is the first user; the GitHub Actions side uses the matching
[`loki-event` action](../.github/actions/loki-event/README.md), which sends
the same labels and the same line.

**Time:** about fifteen minutes the first time (mostly the token), then five
per function.

This directory is drosera's source-neutral home for client-side emitters
(#131): nothing here touches the estate's Alloy config or dashboards.

## Token setup

Each client pushes into **its own** Grafana Cloud stack (the free tier is
plenty), so the token is minted there.

1. In the Grafana Cloud portal, open your stack and click **Details** on the
   **Loki** tile. Note the **URL** (`https://logs-prod-NNN.grafana.net`) and
   the **User** — a number, the Loki instance ID.
2. Go to **Administration → Users and access → Cloud access policies** (or
   **Security → Access Policies** in the portal) and **Create access policy**:
   realm = your stack, scope = **`logs:write`** only. Nothing else — this token
   ends up in CI secrets and function environments, so it must not be able to
   read.
3. **Add token** on that policy and copy it (it starts `glc_`; shown once).
4. The credential both helpers take is the pair `<instance-id>:<token>`, e.g.
   `123456:glc_eyJ…`. Store it as a secret — a GitHub Actions secret for
   workflows, Secrets Manager or an encrypted env var for functions.

## Label discipline

Every event lands with exactly these labels:

| Label | Value | Example |
|---|---|---|
| `log_source` | `<source>_<stage>` | `uvularia_answer` |
| `cluster` | the owning org | `lentago` |
| `source` | product slug | `uvularia` |
| `pipeline` | pipeline slug | `ask` |
| `stage` | stage slug | `answer` |
| `repo` | `owner/name` | `lentago/uvularia` |

- **`log_source` is the stream selector**, as it is for every other drosera
  stream (`zeek_dns`, `device_inventory`, …), so `source` and `stage` are
  underscore-only slugs — a hyphen there is rejected.
- **`cluster=<org>`** says whose event it is. Use the org slug, not a host or
  environment.
- **Labels are an index, not data.** Each distinct label combination is a new
  Loki stream, and the free tier caps active streams. Keep `stage` and
  `pipeline` to a small fixed set you could list on a napkin. Run IDs, SHAs,
  request IDs, durations, outcomes, and counts go in the **payload**, never in
  a label — both helpers enforce lowercase slugs so most of these can't slip
  in by accident.
- **The payload is one JSON object** and becomes the log line, compacted to a
  single line; query it with `| json`. Don't put secrets or personal data in
  it — this goes to a log store.

## Use it from a function

Copy `loki_push.py` next to your handler, then:

```python
import os
from loki_push import push_event

def handler(event, context):
    ...
    try:
        push_event(
            os.environ["LOKI_URL"], os.environ["LOKI_TOKEN"],
            cluster="lentago", source="uvularia", pipeline="ask", stage="answer",
            repo="lentago/uvularia",
            payload={"request_id": context.aws_request_id, "ms": elapsed_ms},
        )
    except Exception as exc:  # telemetry must never fail the request
        print(f"loki push failed: {exc}")
```

`push_event` returns the HTTP status (204 from Loki). It raises `ValueError`
for bad input before sending anything, and `urllib.error.HTTPError` /
`URLError` if the push fails — hence the `try` above. Default timeout is 5
seconds; pass `timeout=` to change it. The function needs outbound HTTPS to
`*.grafana.net`.

## How you know it worked

Try it from your laptop first:

```bash
cd clients
python3 -c 'import os, loki_push; print(loki_push.push_event(
    os.environ["LOKI_URL"], os.environ["LOKI_TOKEN"], cluster="lentago",
    source="uvularia", pipeline="ask", stage="answer",
    repo="lentago/uvularia", payload={"smoke": True}))'
```

It prints `204`. Then, in Grafana → **Explore** on the Loki datasource:

```logql
{log_source="uvularia_answer", cluster="lentago"} | json
```

The event appears within a few seconds with all six labels and `smoke=true`.

## Tests

```bash
python3 -m unittest discover -s clients -v
```

[`test_loki_push.py`](test_loki_push.py) runs `push_event` against an
in-process mock Loki — no real token — and checks the exact request plus the
failure paths (HTTP error, bad labels, bad token or payload). CI runs it in
[`.github/workflows/loki-event-test.yml`](../.github/workflows/loki-event-test.yml).
