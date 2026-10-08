# pipeline-producer: the change pipeline as data (`pipeline.json` + `change_pipeline_state`)

**What you're about to do:** install a small stdlib-only Python service on
LXC 105 (`grafana-stack`, pve5). Every 30 seconds it reads the last 24 hours
of the GitHub Actions feed and the `live` events from Grafana Cloud Loki. It
computes the six stages of [ADR-0010](../docs/adr/0010-change-pipeline-keyed-by-sha.md)
for every repo once, serves the result as a schema-1 JSON document on
`:8611`, and writes the same state back to Loki as the `change_pipeline_state`
stream.

**Why bother:** two consumers need the pipeline as data rather than as a
dashboard. The first is the brasenia wall pane (lentago/brasenia#26), which
reads `http://pub.lan/viewport/pipeline.json`. The second is the "By repo"
strip on `Change — Pipeline`, whose v1 feed is a 10 KB LogQL expression that
re-derives every stage on each render. With one producer, both consumers get
the same answer, and the stuck alert becomes a one-line query (#266).

**Time:** about ten minutes the first time (mostly minting the read token),
then one command per redeploy.

## How it works

One process with two threads, run as `drosera-pipeline.service`
(`Type=simple`, `Restart=always`):

1. **Read.** Every `interval` (default `30s`) it runs three `query_range`
   reads over `window` (default `24h`), paging forward with `limit` and
   `start`:
   - `{log_source="github_actions_run", cluster="lentago"}`
   - `{log_source="github_actions_job", cluster="lentago"}`
   - `{pipeline="change", stage="live", cluster="lentago"}`

   It parses the JSON lines in Python, so no LogQL does any joining.
2. **Compute.** For each repo it works out the six stages, `head`,
   `in_flight`, `stuck` and the budget. The rules are listed below.
3. **Serve.** `GET /healthz` returns `200 ok`. Any other `GET` returns the
   current document with `Content-Type: application/json` and
   `Cache-Control: max-age=10`. Until the first successful read, those other
   paths return `503`, so the pane leaves its row out instead of showing an
   empty pipeline. When a read fails, the service keeps serving the last good
   document, and its `generated_at` still names that last success.
4. **Write back.** After each compute it pushes one line per repo and stage to
   Loki (see [The `change_pipeline_state` stream](#the-change_pipeline_state-stream)).
   A failed push is logged and doesn't affect what is served. `--no-push`
   turns the push off.

### Getting it onto the LAN

LXC 105 has no mount of the web share, so the producer doesn't write to the
pub.lan drop. Instead, pub's Caddy proxies `/viewport/pipeline.json` to
`http://<grafana-stack>:8611/` (kalmia owns that route). The viewport stays
credential-free (brasenia ADR-0005), and nothing on pub needs a Loki token.

## State rules

State codes are the dashboard's: **3** current/success, **2** failed, **1**
waiting or lagging, **0** no signal. These rules match the "By repo" panel
query in [`dashboards/change-pipeline.json`](../dashboards/change-pipeline.json),
which stays the reference until the panel reads this stream. "Run" means a
`github_actions_run` line. "PR run" means `event=pull_request` on a branch
other than `main`. "Main push" means `event=push` on `main`.

| Stage | Rule |
|---|---|
| `pushed` | The newest PR run (by `updated_at`): **3**, `detail` = the branch. |
| `pr_open` | That same run. **1** "awaiting merge" while it is newer than the newest main push's `created_at`, otherwise **0** "no PR newer than main". The feed carries no PR number yet (betula#133), so this stage never claims a merge or a close. |
| `checks_green` | On the newest PR run's SHA, take the latest attempt of each non-skipped workflow and keep the worst. Worst means the lowest code, as the panel's `bottomk` ranks it, so a cancelled run (1) outranks a failure (2). |
| `merged` | The newest main push (by `created_at`): **3**, `detail` = `main`. |
| `applied` | For terraform repos (`terraform_repos` in [`config.json`](config.json)), take the newest job matching `(?i)(.* / )?(terraform )?apply` that wasn't skipped, joined to its run's SHA on `(run_id, run_attempt)`. For other repos, take the newest main push workflow's conclusion. Either way it counts only if it ran on `head`. Otherwise it is **0**, which is what a docs-only merge in a path-filtered repo shows. |
| `live` | For each surface, take the newest `live` event. It is **3** when its SHA equals `head` and **1** otherwise, and the worst surface wins. A repo with no surface is **0**. |

- **`head`** is the SHA of the newest main push. Once betula emits a
  branch-head event (filed alongside #266), prefer it: it also sees merges
  that start no push workflow.
- The fleet squash-merges, so `checks_green` (the PR head SHA) and `merged`
  (the merge commit) legitimately carry different SHAs (ADR-0010).
- **`in_flight`** is true while no surface has reported `head` in the window.
  A repo with no surface is never in flight. Any report counts, not just the
  newest, because a surface may already have moved past a `head` that the
  push workflows saw to a merge they didn't see. A surface that rejected
  `head` (`rolled_back`) never reported it, so the repo stays in flight.
- **`in_flight_since`** is `head.merged_at` while the repo is in flight.
  **`stuck`** is true once the repo has been in flight for longer than
  `budget_minutes`.
- **`budget_minutes`** is `budget_minutes.site` (20) for a `site-*` repo or a
  repo with a `site-*` surface, and `budget_minutes.default` (10) otherwise.
  These are the ADR-0010 budgets.

## The document (schema 1)

The schema is pinned in #266, and the brasenia pane is built against it. Field
names don't change without a schema bump.

```json
{
  "schema": 1,
  "generated_at": "2026-10-07T22:10:00Z",
  "producer": "drosera pipeline producer on grafana-stack (LXC 105)",
  "window": "24h",
  "repos": [
    {
      "repo": "lentago/drosera",
      "head": {"sha": "36398c0", "full_sha": "36398c06…", "merged_at": "2026-10-07T21:14:31Z", "url": "https://github.com/lentago/drosera/commit/36398c06…"},
      "in_flight": false,
      "in_flight_since": null,
      "stuck": false,
      "budget_minutes": 10,
      "stages": [
        {"stage": "pushed", "state": 3, "sha": "cdecf7e", "detail": "agent/change-pipeline-graphviz-strip", "when": "…", "url": "…"},
        "… pr_open, checks_green, merged, applied, live …"
      ],
      "surfaces": [
        {"surface": "alloy-lxc105", "sha": "36398c0", "state": 3, "result": "applied", "when": "2026-10-07T21:17:33Z"}
      ]
    }
  ]
}
```

- `stages` always holds the six entries in pipeline order. A stage with no
  signal has `state: 0` and `sha`, `detail`, `when` and `url` all `null`.
- `repos` is sorted by name and holds every repo with an event in the window.
  `head` is `null` for a repo with no main push in the window.

## The `change_pipeline_state` stream

Each compute writes one line per repo and stage, with the six lines one
nanosecond apart in pipeline order:

| Label | Value |
|---|---|
| `log_source` | `change_pipeline_state` |
| `cluster` | `lentago` |
| `repo` | `owner/name`: one stream per repo, and the stage goes in the line |

```json
{"stage":"live","state":3,"sha":"36398c0","detail":"alloy-lxc105 · applied","when":"2026-10-07T21:17:33Z","url":"…","head":"36398c0","in_flight":false,"stuck":false}
```

There are deliberately **no `pipeline` or `stage` labels**. The dashboard
selects the real `live` events with `{pipeline="change", stage="live"}` and
must not see these lines. The current state of a repo:

```logql
{log_source="change_pipeline_state", cluster="lentago", repo="lentago/drosera"} | json
```

The stuck alert becomes a one-line query:

```logql
sum by (repo) (count_over_time({log_source="change_pipeline_state", cluster="lentago"} | json | stage="live" | stuck="true" [2m]))
```

**Volume:** about 25 repos × 6 lines every 30 s is roughly 430k short lines
(~100 MB) a day. A longer `interval` cuts that proportionally.

## Config

[`config.json`](config.json) lives in git and is installed verbatim to
`/etc/drosera-pipeline/config.json`:

| Key | Default | Meaning |
|---|---|---|
| `interval` | `30s` | Time between computes (`--interval` overrides it). |
| `window` | `24h` | How far back each read goes (`--window` overrides it). |
| `listen`, `port` | `0.0.0.0`, `8611` | Where the HTTP server listens. |
| `cluster` | `lentago` | Which `cluster` the reads select and the write stamps. |
| `producer` | — | The document's `producer` string. |
| `terraform_repos` | `.github`, kalmia, claytonia, drosera, betula, solidago | Repos whose `applied` stage comes from the apply job. |
| `budget_minutes` | `{"default": 10, "site": 20}` | The ADR-0010 propagation budgets. |

## Token setup

All credentials go only in `/etc/default/drosera-pipeline` (0600 root:root,
written by `deploy.sh`), never in git.

### Read: a `logs:read` access-policy token (new)

LXC 105's `/opt/homelab-observability/.env` holds only the collectors'
`logs:write` token. A read with it gets `401 invalid scope requested`, so the
producer needs its own token:

1. In the Grafana Cloud portal, go to **Security → Access Policies** and click
   **Create access policy**. Set the realm to the `lentago` stack and the
   scope to **`logs:read`** only.
2. Click **Add token** and copy the `glc_…` value. It becomes
   `DROSERA_LOKI_TOKEN`.
3. `DROSERA_LOKI_URL` and `DROSERA_LOKI_USER` are the same Loki URL and
   numeric user as the write side. `deploy.sh` defaults them to those values.

### Write: the existing `logs:write` token

`GRAFANA_CLOUD_LOGS_URL`, `GRAFANA_CLOUD_LOGS_USER` and
`GRAFANA_CLOUD_LOGS_TOKEN` are the names the central Alloy already uses. When
they aren't in the environment, `deploy.sh` reads them from
`/opt/homelab-observability/.env`.

## Deploy

[`deploy.sh`](deploy.sh) is idempotent. Run it from a drosera checkout on
LXC 105 as a sudo-capable user:

```bash
git clone --depth 1 https://github.com/lentago/drosera /tmp/drosera && cd /tmp/drosera
DROSERA_LOKI_TOKEN=glc_… ./pipeline-producer/deploy.sh
```

The script does the following, in order:

1. Checks for `python3` ≥ 3.10 and validates `config.json`.
2. Refuses to go on without the read token.
3. Creates the `drosera-pipeline` system user.
4. Installs the package to `/opt/drosera-pipeline/`, the config to
   `/etc/drosera-pipeline/`, the credentials to `/etc/default/drosera-pipeline`
   and the [`systemd/`](systemd/) unit.
5. Enables and restarts the unit.
6. Waits until `:8611` serves a document.

To ship a code or config change, re-run the script with no credentials in the
environment. It keeps the existing credentials file, but still refuses to
continue if that file has no read token.

## How you know it worked

On the host:

```bash
systemctl status drosera-pipeline --no-pager
journalctl -u drosera-pipeline -n 20 --no-pager      # "computed N repo(s); in flight M; stuck none"
curl -s http://127.0.0.1:8611/pipeline.json | python3 -m json.tool | head -40
```

To compute one document without pushing, using the installed credentials:

```bash
sudo bash -c 'set -a; . /etc/default/drosera-pipeline; set +a; \
  PYTHONPATH=/opt/drosera-pipeline exec python3 -B -m pipeline_producer \
    --config /etc/drosera-pipeline/config.json --once --no-push --out -'
# (sourced inside a root shell so the tokens never appear on a command line that `ps` can show)
```

In Grafana, **Explore** on the Loki datasource:

```logql
{log_source="change_pipeline_state", cluster="lentago"} | json
```

## Tests

```bash
cd pipeline-producer && python3 -m unittest discover -s tests -t . -v
```

The tests run against an in-process fake Loki ([`tests/fakes.py`](tests/fakes.py)),
with no tokens and no network. They cover:

- the state rules, with one fixture per case listed in #266;
- `query_range` paging, including a full page inside one nanosecond;
- keeping the last good document when a read fails;
- the HTTP endpoints;
- the labels on the write-back stream;
- the acceptance command, `python3 -m pipeline_producer --once --no-push --out -`,
  run as a subprocess against the fake served over HTTP.

CI runs them in
[`pipeline-producer-tests.yml`](../.github/workflows/pipeline-producer-tests.yml)
on Python 3.10, the version LXC 105 runs.
