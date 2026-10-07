# ADR-0010: The change pipeline, keyed by commit SHA

**Status:** Accepted (2026-10-07)

## Context

Every enforced surface on this fleet applies on merge to `main`: the `.github`,
kalmia, claytonia, drosera and betula terraform workflows; the alloy and
Firewalla gitops timers; the site deploys. All of them apply silently. GitHub
tells the commit author when a workflow fails, and on this fleet that is often a
bot: #204 records site-icecreamtofightwith-com's deploy sitting red for about 29
hours before anyone knew.

The deeper gap is that no runtime reports which commit it is running.
`alloy-host/gitops-pull.sh` logged only to a local file, betula's
`gitops-sync.sh` ships nothing (betula#107), and the sites expose no commit at
all. "Applied" is observable from GitHub; "live" was observable from nowhere.

Epic #251 sets out the model. This record fixes the parts other work builds on:
the stages, the join key, how each stage is derived, the `live` event contract,
and the propagation budgets. The dashboard, the stuck alert and the other
emitters are separate items under #251.

## Decision

### Six stages, one join key

```
pushed → pr_open → checks_green → merged → applied → live
```

Every stage is a Loki event that carries `repo` and a commit `sha`. A change's
**position** is the furthest stage whose latest event carries its SHA. A
change is **in flight** while the newest `main` commit of its repo has no
`live` event, and **stuck** once it has been in flight for longer than its
surface's propagation budget (below).

**The SHA changes at the merge.** The fleet squash-merges, so a PR's head SHA
(what `pull_request` runs carry) is not the merge commit SHA on `main` (what
`push` runs and `live` events carry). For example, drosera #249 had head
`48d9a01` and merge commit `00d22a6`. The six stages therefore form two
SHA-joined halves:

- `pushed → pr_open → checks_green`, keyed by the PR **head** SHA;
- `merged → applied → live`, keyed by the **merge commit** SHA.

The in-flight and stuck definitions only use the second half, so the stuck alert
and the "newest `main` commit" view are fully SHA-joined. Joining the halves
needs the PR as a bridge (head SHA → PR number → merge commit), and the v1
Actions feed carries neither a PR number nor a commit message. Until it does,
the dashboard shows the pre-merge half per branch and the post-merge half per
commit. Adding that bridge is a feed change in betula (lentago/betula#133), and
not a prerequisite for anything in #251.

### Stages 1–5 come from the GitHub Actions feed

betula#113's collector (live on LXC 105 since 2026-10-07) pushes one event per
completed workflow run and one per job, with labels
`log_source=github_actions_run|github_actions_job`, `cluster=lentago`,
`source=github_actions`, `pipeline=ci`, `stage=run|job`, and `repo=owner/name`.
It only emits **completed** runs: run events are stamped at `updated_at` and job
events at `completed_at`, and it polls every 5 min.

| Stage | Derivation |
|---|---|
| `pushed` | **Not derived.** A bare push with no PR is visible only through the repo Events API (`PushEvent`), which the collector does not read. On this fleet every change goes through a PR, so `pushed` collapses into `pr_open`. |
| `pr_open` | A `github_actions_run` with `event=pull_request` on a `branch` other than `main` ⇒ `pr_open` for its `head_sha`. Because only completed runs are emitted, the timestamp is the first PR run's completion, not the moment the PR opened. It lags by one workflow duration plus up to one poll interval. |
| `checks_green` | Every `pull_request` run for that `head_sha` (latest `run_attempt` per workflow) has `conclusion=success`. A run is only emitted once it has completed, so by construction every job in it has finished. A workflow that has not completed yet is not in the feed, so `checks_green` can show before the last workflow reports. The branch ruleset's required checks are the real gate; `merged` supersedes `checks_green` either way. |
| `merged` | A `github_actions_run` with `event=push` and `branch=main` ⇒ `merged` for its `head_sha` (the merge commit). A merge that triggers no push workflow produces no event. In drosera, `terraform.yml` and `status-page.yml` both path-filter their `push` triggers, so a docs-only merge is invisible here. The next stage that carries the SHA (for drosera, the alloy `live` event, which reports every `main` commit) still places the change. |
| `applied` | A `github_actions_job` whose `job_name` is `apply` (or ends in ` / apply`, the name GitHub gives a job inside a called reusable workflow), with `conclusion=success` ⇒ `applied`. The job payload has no `head_sha`, so join it to its run on `(repo, run_id, run_attempt)` and take the run's `head_sha`. `conclusion=skipped` is a path-gated apply that did not run, not an apply. |
| `live` | Emitted by the runtime itself (contract below); for terraform surfaces, derived in v1 (see budgets). |

### The `live` event contract

The six-label shape from [`clients/README.md`](../../clients/README.md), so
`live` events sit beside the `loki-event` emitters and the Actions feed:

| Label | Value |
|---|---|
| `log_source` | `<source>_live`, e.g. `drosera_live` |
| `cluster` | `lentago` |
| `source` | the repo slug as an underscore-only slug (hyphens become `_`, a leading `.` is dropped: `.github` → `github`) |
| `pipeline` | `change` |
| `stage` | `live` |
| `repo` | `lentago/<repo>` |

The log line is one JSON object:

| Field | Meaning |
|---|---|
| `sha` | the full commit SHA the surface is running after this tick |
| `previous_sha` | the SHA it ran before this tick (equal to `sha` on a no-op) |
| `repo` | `lentago/<repo>` (repeated from the label so `\| json` output stands alone) |
| `surface` | short runtime name: `alloy-lxc105`, `firewalla`, `site-icecreamtofightwith-com`, … |
| `result` | `applied` (new SHA now running), `noop` (already current), `rolled_back` (the new SHA was rejected; `sha` is the commit kept, `previous_sha` the rejected one) |
| `applied_at` | RFC 3339 UTC time of the emit |

Rules:

- **Emit on every reconcile tick, no-op ticks included.** A quiet surface still
  reports the SHA it runs, so a missing `live` event always means a broken
  surface, never a quiet one. The emitter is also its own heartbeat, which is
  why `drosera_live` is in `scripts/check-loki-labels.sh` `EXPECTED`.
- **`surface` is payload, not a label.** One repo can feed several surfaces
  (each site, each host), and the stream count stays at one per emitting repo.
- **Telemetry never changes the reconcile.** A failed push is logged and
  ignored; the emitter's exit code and behaviour are what they were without it.
- **Timestamps.** Emitters on the LAN push through the central Alloy's
  `loki.source.api` on `:3100`, which restamps entries at receive time (no
  `use_incoming_timestamp`). The receive time is effectively the emit time.
  `applied_at` carries the emitter's own clock regardless. A pushed
  `cluster="lentago"` label overrides that Alloy's
  `external_labels { cluster = "lentago-lab" }`.

The first emitter is `alloy-host/gitops-pull.sh` (surface `alloy-lxc105`,
`log_source=drosera_live`), every 5 min:

```logql
{log_source="drosera_live", cluster="lentago"} | json
```

### Propagation budgets

The budget runs from `merged` to `live` for the newest `main` commit.

| Surface | Budget | Why |
|---|---|---|
| terraform (`.github`, kalmia, claytonia, drosera, betula, solidago) | 10 min | apply job queue + run, plus one collector poll |
| alloy (`alloy-lxc105`) | 10 min | two 5-min gitops ticks, so one missed tick does not page |
| Firewalla | 10 min | same shape as alloy: a 5-min gitops timer |
| sites | 20 min | the deploy workflow's typical duration plus a probe interval |

*Amended 2026-10-07: solidago applies on merge too and was missing from this list; its apply job is named `Terraform Apply`, so consumers match the job name case-insensitively as `(terraform )?apply`, with or without a reusable-workflow prefix.*

**v1: apply-success counts as `live` for the terraform surfaces.** Terraform's
runtime is the provider's remote state, and nothing on the fleet reports it
independently today. An `applied` event for a terraform repo's merge commit is
treated as its `live` event. The later item is a scheduled
`terraform plan -detailed-exitcode` drift probe that emits `live` only on exit 0.
Until then a live-only edit that drifts after apply stays invisible to this
pipeline. The anti-drift rule in `CLAUDE.md` and `scripts/tf-drift.sh` still
cover that.

## Consequences

- Adding a surface is one emitter plus one budget entry. The dashboard and the
  stuck alert key on `pipeline="change", stage="live"` and the payload, not on a
  per-surface label.
- Each emitting repo adds one Loki stream. That is negligible against the
  stream budget, and nothing is added in Mimir.
- The stuck alert needs to know the newest `main` commit per repo. In repos
  whose push workflows are path-filtered, the Actions feed does not see every
  merge. The alert work (#251) has to pick a source that every merge reaches:
  for example, the collector reading each repo's `main` head, or an unfiltered
  push workflow that emits `merged` via `loki-event`. This record does not
  choose between them.
- `pushed` stays underived until something reads the Events API. On this fleet
  that costs nothing in practice.

## Alternatives considered

- **Per-stage webhooks** (`push`, `pull_request`, `workflow_run`,
  `workflow_job`) for real-time state. These need a publicly reachable receiver,
  which the lab does not expose (see ADR-0006 on egress, and the betula#113
  out-of-scope note). Deferred. If the feed's poll latency proves too slow, an
  ADR on the receiver comes first.
- **Traces** (one span per stage under a per-change trace). These model a
  single change's lifecycle well, but the questions here are aggregate: what is
  in flight now, what is stuck, and merge-to-live latency per surface over
  time. Traces would also add a tracing backend for what is a handful of coarse,
  minutes-apart events.
- **Prometheus metrics** (for example, a gauge of the deployed SHA per surface).
  The reasoning of claytonia ADR-0007 applies. A SHA as a label value is
  unbounded cardinality: every merge mints a series that never goes away, which
  is the Loki analogue of the Pushgateway stale-series trap. A stage transition
  is an event, not a sampled value. Mimir is also the constrained budget here
  (ADR-0005); one Loki stream per repo costs nothing there.
