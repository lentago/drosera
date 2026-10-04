# loki-event — push one event from a GitHub workflow to Grafana Cloud Loki

**What you're about to do:** add one step to a GitHub Actions workflow that
sends a single structured event — "stage X of pipeline Y just ran, here are
the details" — to a Grafana Cloud Loki you own. A composite action, POSIX `sh`
plus `curl` and `jq` (both already on GitHub-hosted runners), no third-party
actions.

**Why bother:** until now nothing could get an event from GitHub Actions into
Loki — the only paths were a host Alloy, the LAN-only Alloy receiver, and the
Firewalla's Fluent Bit. With one event per stage, a dashboard can show a
pipeline left to right: what ran, when, and where it stopped. First consumer
is uvularia (vault publish, intake, and Ask), each pushing into the **client's
own** Grafana Cloud free tier.

**Time:** about fifteen minutes the first time — most of it minting the token.
After that, each extra event is one step.

The serverless twin, for functions that can't run a workflow step, is
[`clients/loki_push.py`](../../../clients/loki_push.py) — same labels, same
line.

## 1. Mint a write-only Loki token

Follow [clients/README.md § Token setup](../../../clients/README.md#token-setup):
you end up with a Loki URL and a `<instance-id>:<token>` pair scoped to
`logs:write` only. Save them in the **calling** repo as secrets, e.g.
`LOKI_URL` and `LOKI_TOKEN` (Settings → Secrets and variables → Actions).

## 2. Add the step

```yaml
      - name: Emit publish event
        if: always()   # report failures too — that's the interesting case
        continue-on-error: true   # telemetry must never fail the pipeline
        uses: lentago/drosera/.github/actions/loki-event@main
        with:
          loki_url: ${{ secrets.LOKI_URL }}
          loki_token: ${{ secrets.LOKI_TOKEN }}
          cluster: lentago            # the owning org — see label discipline
          source: uvularia
          pipeline: vault-publish
          stage: publish
          payload-json: >-
            {"run_id": "${{ github.run_id }}", "sha": "${{ github.sha }}",
             "outcome": "${{ job.status }}"}
```

| Input | Required | Notes |
|---|---|---|
| `loki_url` | yes | Loki base URL (`https://logs-prod-NNN.grafana.net`); `/loki/api/v1/push` is appended if missing. |
| `loki_token` | yes | `<instance-id>:<token>`, `logs:write` scope. Always from a secret. |
| `cluster` | yes | Owning org slug → `cluster` label. |
| `source` | yes | Product slug (`[a-z][a-z0-9_]*`) → `source` label and the first half of `log_source`. |
| `pipeline` | yes | Pipeline slug (`[a-z0-9][a-z0-9_-]*`) → `pipeline` label. |
| `stage` | yes | Stage slug (`[a-z][a-z0-9_]*`) → `stage` label and the second half of `log_source`. |
| `repo` | no | `owner/name`; defaults to the calling repo. |
| `payload-json` | no | A JSON **object**; becomes the log line, compacted. Defaults to `{}`. |

The step fails on bad input (before anything is sent) and on any non-2xx
answer from Loki. Whether that fails your job is your call —
`continue-on-error: true` above is the usual choice for telemetry.

> **Heads up.** `@main` tracks this repo's default branch. If you'd rather
> not take changes unreviewed, pin to a commit SHA instead.

Label rules — what goes in a label and what goes in the payload — are in
[clients/README.md § Label discipline](../../../clients/README.md#label-discipline).
Read them before choosing your `stage` names.

## How you know it worked

The step log ends with
`loki-event: pushed log_source=uvularia_publish cluster=lentago (HTTP 204)`.
Then, in Grafana → **Explore**, pick the Loki datasource and run:

```logql
{log_source="uvularia_publish", cluster="lentago"} | json
```

The event appears within a few seconds, carrying the `source`, `pipeline`,
`stage`, and `repo` labels, with your payload fields parsed alongside.

## Tests

[`.github/workflows/loki-event-test.yml`](../../workflows/loki-event-test.yml)
runs this action against a mock Loki ([`test/mock_loki.py`](test/mock_loki.py))
on every PR — no real token. It checks the exact request (path, auth header,
labels, one-line payload), then checks that an HTTP 500, a hyphenated stage,
non-JSON payload, and a token missing its instance ID each **fail** the step,
and that only the 500 case reached the wire.
