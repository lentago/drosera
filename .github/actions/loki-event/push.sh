#!/bin/sh
# Push one structured event to a Grafana Cloud Loki push endpoint.
#
# Called by action.yml with every input mapped to an LE_* env var, but it runs
# standalone too (export the same vars) — handy for a local smoke test.
# POSIX sh + curl + jq only; no bashisms, so it runs on any runner image.
#
# Label shape (see README.md § Label discipline, and clients/loki_push.py,
# which must stay in lockstep):
#   log_source=<source>_<stage>  cluster=<cluster>
#   source=<source>  pipeline=<pipeline>  stage=<stage>  repo=<owner/name>
# The log line is the payload JSON, compacted to a single line.
set -eu

die() {
  echo "::error::loki-event: $*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "curl not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

: "${LE_LOKI_URL:?loki_url is required}"
: "${LE_LOKI_TOKEN:?loki_token is required}"
: "${LE_CLUSTER:?cluster is required}"
: "${LE_SOURCE:?source is required}"
: "${LE_PIPELINE:?pipeline is required}"
: "${LE_STAGE:?stage is required}"
: "${LE_REPO:?repo is required}"
[ -n "${LE_PAYLOAD_JSON:-}" ] || LE_PAYLOAD_JSON='{}'

# Labels are an index, not a data field: every distinct value is a new Loki
# stream, and free-tier stream budgets are small. Hold them to lowercase slugs
# so a run ID or a commit SHA can't sneak in as a label value — per-run detail
# belongs in the payload.
#
# source and stage also build log_source, whose existing values (zeek_dns,
# device_inventory) are underscore-only — so no hyphens there.
check() {
  # $1 = input name, $2 = extended regex, $3 = value
  printf '%s' "$3" | grep -Eq "$2" || die "$1 has an invalid value '$3' (want $2)"
}
check source '^[a-z][a-z0-9_]{0,31}$' "$LE_SOURCE"
check stage '^[a-z][a-z0-9_]{0,31}$' "$LE_STAGE"
check pipeline '^[a-z0-9][a-z0-9_-]{0,62}$' "$LE_PIPELINE"
check cluster '^[a-z0-9][a-z0-9_-]{0,62}$' "$LE_CLUSTER"
check repo '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' "$LE_REPO"

# Grafana Cloud basic auth is <loki-instance-id>:<access-policy-token>.
case "$LE_LOKI_TOKEN" in
  ?*:?*) ;;
  *) die "loki_token must be '<instance-id>:<token>' (Grafana Cloud basic auth)" ;;
esac

# Accept either the bare host or the full push URL.
url="${LE_LOKI_URL%/}"
case "$url" in
  */loki/api/v1/push) ;;
  *) url="$url/loki/api/v1/push" ;;
esac

# Nanosecond epoch. %N is GNU, not POSIX: where it's unsupported date echoes
# it literally (or errors), so fall back to whole seconds.
ts="$(date +%s%N 2>/dev/null || true)"
case "$ts" in
  '' | *[!0-9]*) ts="$(date +%s)000000000" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf '%s' "$LE_PAYLOAD_JSON" |
  jq -c --arg ts "$ts" \
    --arg cluster "$LE_CLUSTER" --arg source "$LE_SOURCE" \
    --arg pipeline "$LE_PIPELINE" --arg stage "$LE_STAGE" --arg repo "$LE_REPO" '
    if type != "object" then error("payload-json must be a JSON object") else . end
    | {streams: [{
        stream: {
          log_source: ($source + "_" + $stage),
          cluster: $cluster,
          source: $source,
          pipeline: $pipeline,
          stage: $stage,
          repo: $repo
        },
        values: [[$ts, tojson]]
      }]}' >"$tmp/body.json" 2>"$tmp/jq.err" ||
  die "payload-json is not a valid JSON object: $(cat "$tmp/jq.err")"

# Credentials go to curl via a config file on stdin, never argv, so they
# don't show up in the process table. Escape \ and " for curl's config syntax.
user="$(printf '%s' "$LE_LOKI_TOKEN" | sed 's/[\\"]/\\&/g')"
code="$(
  printf 'user = "%s"\n' "$user" |
    curl -sS -K - \
      --max-time 10 \
      -H 'Content-Type: application/json' \
      --data-binary "@$tmp/body.json" \
      -o "$tmp/resp" -w '%{http_code}' \
      "$url"
)" || die "request to $url failed (curl exit $?)"

case "$code" in
  2??) echo "loki-event: pushed log_source=${LE_SOURCE}_${LE_STAGE} cluster=$LE_CLUSTER (HTTP $code)" ;;
  *) die "Loki answered HTTP $code: $(head -c 500 "$tmp/resp")" ;;
esac
