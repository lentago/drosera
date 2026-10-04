"""Push one structured event to a Grafana Cloud Loki push endpoint.

Stdlib only, so a serverless function (AWS Lambda, etc.) can vendor this one
file. Same label shape as .github/actions/loki-event/push.sh — keep the two in
lockstep. See clients/README.md.
"""
import base64
import json
import re
import time
import urllib.request

_CHECKS = {
    "source": r"[a-z][a-z0-9_]{0,31}",
    "stage": r"[a-z][a-z0-9_]{0,31}",
    "pipeline": r"[a-z0-9][a-z0-9_-]{0,62}",
    "cluster": r"[a-z0-9][a-z0-9_-]{0,62}",
    "repo": r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
}


def push_event(loki_url, loki_token, cluster, source, pipeline, stage, repo, payload, timeout=5):
    """POST one event; return the HTTP status. Raises ValueError on bad input,
    urllib.error.URLError/HTTPError on a failed push — wrap the call if your
    function must not fail because telemetry did."""
    labels = {"cluster": cluster, "source": source, "pipeline": pipeline, "stage": stage, "repo": repo}
    for name, value in labels.items():
        if not re.fullmatch(_CHECKS[name], value or ""):
            raise ValueError(f"{name} has an invalid value {value!r} (want {_CHECKS[name]})")
    if not re.fullmatch(r".+:.+", loki_token or "") or not isinstance(payload, dict):
        raise ValueError("loki_token must be '<instance-id>:<token>' and payload a dict")
    url = loki_url.rstrip("/")
    if not url.endswith("/loki/api/v1/push"):
        url += "/loki/api/v1/push"
    stream = {"log_source": f"{source}_{stage}", **labels}
    line = json.dumps(payload, separators=(",", ":"))
    body = {"streams": [{"stream": stream, "values": [[str(time.time_ns()), line]]}]}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": "Basic " + base64.b64encode(loki_token.encode()).decode(),
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status
