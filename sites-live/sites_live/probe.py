"""Read each site's /version.json and emit the ADR-0010 `live` event.

One event per surface per tick, no-op ticks included: a quiet site still
reports the SHA it serves, so a missing event means a broken probe or site.
A site with no readable version.json (404, timeout, junk) is "no signal": it
is logged and emits nothing. Telemetry never fails the run.

Stdlib only (Python 3.10). Contract: docs/adr/0010-change-pipeline-keyed-by-sha.md.
"""
import argparse
import json
import logging
import os
import re
import socket
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# loki_push.py is vendored next to this package by deploy.sh; in a checkout it
# lives in ../../clients.
_HERE = Path(__file__).resolve().parent
for _cand in (_HERE.parent, _HERE.parent.parent / "clients"):
    if (_cand / "loki_push.py").is_file():
        sys.path.insert(0, str(_cand))
        break
from loki_push import push_event  # noqa: E402

log = logging.getLogger("sites-live")

# Label values, fixed by the ADR: log_source = "<source>_live" = sites_live.
CLUSTER = "lentago"
SOURCE = "sites"
PIPELINE = "change"
STAGE = "live"

MAX_BODY = 64 * 1024
SHA_RE = re.compile(r"[0-9a-f]{40}")
SITE_KEYS = ("host", "repo", "surface")


def version_url(host):
    return f"https://{host}/version.json"


def fetch_version(url, timeout=10):
    """Return the parsed version.json dict, or None when there is no signal."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            raw = resp.read(MAX_BODY + 1)
    except urllib.error.HTTPError as e:
        log.info("no signal from %s: HTTP %s", url, e.code)
        return None
    except (OSError, ValueError) as e:  # URLError, timeout, connection reset
        log.warning("no signal from %s: %s", url, e)
        return None
    if len(raw) > MAX_BODY:
        log.warning("no signal from %s: body over %d bytes", url, MAX_BODY)
        return None
    try:
        data = json.loads(raw)
    except ValueError as e:
        log.warning("no signal from %s: malformed JSON (%s)", url, e)
        return None
    if not isinstance(data, dict) or not isinstance(data.get("sha"), str) \
            or not SHA_RE.fullmatch(data["sha"]):
        log.warning("no signal from %s: no valid 40-hex 'sha'", url)
        return None
    return data


def load_sites(path):
    sites = json.loads(Path(path).read_text())
    for s in sites:
        missing = [k for k in SITE_KEYS if not s.get(k)]
        if missing:
            raise ValueError(f"{path}: site {s!r} lacks {missing}")
    return sites


def load_state(path):
    try:
        state = json.loads(Path(path).read_text())
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".state-")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, sort_keys=True)
    os.replace(tmp, path)


def build_event(site, data, previous_sha, host):
    """The ADR-0010 payload. `sha` is what the site serves, so the very first
    sight of a surface has no earlier SHA: previous_sha repeats sha."""
    sha = data["sha"]
    prev = previous_sha or sha
    built_at = data.get("built_at")
    payload = {
        "sha": sha,
        "previous_sha": prev,
        "repo": site["repo"],
        "surface": site["surface"],
        "result": "noop" if previous_sha == sha else "applied",
        "applied_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": host,
    }
    # The deploy's own build time is extra context; applied_at is the emit time.
    if isinstance(built_at, str):
        payload["built_at"] = built_at
    return payload


def run(sites, state_path, loki_url, loki_token, *, url_for=version_url,
        timeout=10, dry_run=False, hostname=None, push=push_event):
    """One tick. Returns the list of payloads emitted (or that would be)."""
    hostname = hostname or socket.gethostname()
    state = load_state(state_path)
    emitted = []
    for site in sites:
        try:
            data = fetch_version(url_for(site["host"]), timeout)
            if data is None:
                continue
            payload = build_event(site, data, state.get(site["surface"]), hostname)
            if dry_run:
                print(json.dumps({"labels": {"log_source": f"{SOURCE}_{STAGE}",
                                             "cluster": CLUSTER, "source": SOURCE,
                                             "pipeline": PIPELINE, "stage": STAGE,
                                             "repo": site["repo"]},
                                  "line": payload}))
            else:
                push(loki_url, loki_token, CLUSTER, SOURCE, PIPELINE, STAGE,
                     site["repo"], payload)
                # Remember the SHA only once delivered, so a failed push leaves
                # the change as `applied` for the next tick to retry.
                state[site["surface"]] = payload["sha"]
            emitted.append(payload)
        except Exception as e:  # telemetry must never fail the run
            log.warning("%s: event not delivered: %s", site.get("surface"), e)
    if not dry_run and emitted:
        try:
            save_state(state_path, state)
        except OSError as e:
            log.warning("could not save state to %s: %s", state_path, e)
    return emitted


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sites", default=os.environ.get(
        "SITES_LIVE_CONFIG", str(_HERE.parent / "sites.json")))
    ap.add_argument("--state-dir", default=os.environ.get("STATE_DIRECTORY", "."),
                    help="directory for seen-SHA state (systemd StateDirectory)")
    ap.add_argument("--timeout", type=float, default=10)
    ap.add_argument("--dry-run", action="store_true",
                    help="print the events instead of pushing; state is untouched")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    url = os.environ.get("GRAFANA_CLOUD_LOGS_URL", "")
    user = os.environ.get("GRAFANA_CLOUD_LOGS_USER", "")
    token = os.environ.get("GRAFANA_CLOUD_LOGS_TOKEN", "")
    if not args.dry_run and not (url and user and token):
        log.error("GRAFANA_CLOUD_LOGS_URL/USER/TOKEN are not set (see /etc/default/sites-live)")
        return 1
    try:
        sites = load_sites(args.sites)
    except (OSError, ValueError) as e:
        log.error("cannot load %s: %s", args.sites, e)
        return 1
    state_path = Path(args.state_dir) / "seen.json"
    run(sites, state_path, url, f"{user}:{token}", timeout=args.timeout,
        dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
