# sites-live — which commit is each public site serving?

Part of the change pipeline ([ADR-0010](../docs/adr/0010-change-pipeline-keyed-by-sha.md),
epic #251). A red deploy leaves the old image serving and nobody knows (#204).
The Alloy blackbox probe can match a body but not extract a value, so this small
timer reads what each site serves and emits the ADR's `live` event.

Every 5 minutes, for each row of [`sites.json`](sites.json), it fetches
`https://<host>/version.json` (10 s timeout). The file is written into the site
build by the shared deploy workflow:

```json
{"sha": "<40 hex>", "repo": "lentago/<site repo>", "built_at": "<RFC 3339>"}
```

## Sites

| Host | Repo | Surface |
|---|---|---|
| `lentago.dev` | `lentago/site-lentago-dev` | `site-lentago-dev` |
| `icecreamtofightwith.com` | `lentago/site-icecreamtofightwith-com` | `site-icecreamtofightwith-com` |
| `pondviewlane.com` | `lentago/site-pondviewlane-com` | `site-pondviewlane-com` |
| `essexcrossingatmontserrat.com` | `lentago/site-pondviewlane-com` | `site-essexcrossingatmontserrat-com` |

Pondview and Essex are one repo with two skins, so one commit, two surfaces.
Add a site by adding a row to `sites.json` and re-running `deploy.sh`.

## The event

Pushed straight to Grafana Cloud Loki through
[`clients/loki_push.py`](../clients/loki_push.py) (vendored by `deploy.sh`).

Labels: `log_source="sites_live"`, `cluster="lentago"`, `source="sites"`,
`pipeline="change"`, `stage="live"`, `repo="lentago/<site repo>"`. The ADR makes
`log_source` `<source>_live` and `source` an underscore-only slug, hence
`source="sites"` (the client rejects hyphens).

Line, one JSON object per surface per tick:

| Field | Value |
|---|---|
| `sha` | `sha` from the site's `version.json` |
| `previous_sha` | the SHA seen on the previous tick; equal to `sha` on a `noop`, and on the first sight of a surface (there is no earlier SHA) |
| `repo`, `surface` | from `sites.json` |
| `result` | `applied` when `sha` differs from the last one seen for that surface, else `noop` (`rolled_back` is not applicable to a site) |
| `applied_at` | RFC 3339 UTC time of the emit, as the ADR defines it |
| `host` | the host the probe ran on |
| `built_at` | the file's own `built_at`, when present (the deploy's build time) |

Rules it follows:

- **404, timeout, connection error, malformed JSON or a bad `sha` is "no
  signal"**: logged once per tick, nothing emitted, exit 0. Until the deploy
  workflow writes `version.json` every site is a 404.
- **Telemetry never fails the run.** A failed push is logged; the SHA is only
  recorded as seen after a successful push, so the next tick retries it as
  `applied`.
- The last SHA seen per surface is kept in `/var/lib/sites-live/seen.json`
  (`StateDirectory`).

## Deploy (LXC 105)

```bash
sudo GRAFANA_CLOUD_LOGS_URL=https://logs-prod-NNN.grafana.net \
     GRAFANA_CLOUD_LOGS_USER=123456 \
     GRAFANA_CLOUD_LOGS_TOKEN=glc_... \
     sites-live/deploy.sh
```

Installs to `/opt/sites-live`, writes the credentials to a `0600`
`/etc/default/sites-live` (same variable names as betula's collectors; a
`logs:write` token), and enables `sites-live.timer`. Re-running is safe; without
the variables set it keeps the existing credentials. This is **not**
gitops-managed: re-run it after changing anything here.

## Check it

```bash
cd sites-live && python3 -m sites_live --dry-run   # prints what would be pushed
python3 -m unittest discover -s sites-live -t sites-live -v   # from the repo root
```

```logql
{log_source="sites_live", cluster="lentago"} | json
```

The `Live now` table on `Change — Pipeline` keys on `pipeline="change",
stage="live"`, so site rows appear without a dashboard edit.
