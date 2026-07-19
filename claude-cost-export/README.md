# claude-cost-export

> Rehomed from [workstation-bootstrap](https://github.com/lentago/workstation-bootstrap)
> (archived 2026-07-01). This is live observability tooling — the exporter and
> heartbeat feed the **Claytonia — Runner Fleet** dashboard managed in this
> repo — so it lives here with the rest of the pipeline.

Ship the cost of **local, interactive** Claude Code sessions to the Lentago lab
Grafana **"Claytonia — Runner Fleet"** dashboard, so a workstation shows up next to
the [bullpen](https://github.com/lentago/claytonia) agents under a **Local
sessions** row (`source="local"`, `worker=<hostname>`).

It also emits a lightweight **`session_running`** heartbeat while a session is
actively working (throttled to ~30s, keyed on **active tool use**), so the
dashboard's **"Local sessions underway"** pane shows in real time which
workstations are busy — the live counterpart to the per-session cost shipped at
the end.

The bullpen gets `total_cost_usd` for free from headless `claude -p --output-format
json`. Interactive sessions have no such result blob, so this tool reconstructs
per-session cost from the transcript and ships one event per finished session.

## How it works

```
~/.claude/projects/**/*.jsonl   (transcripts — the source of truth, written by CC)
        │  sweep: dedupe by uuid + requestId(max output), sum tokens per model
        ▼
  compute cost  ×  pricing.json
        │  one `session_complete` event per FINISHED session
        ▼
  spool.ndjson  ──ship──▶  Alloy Loki receiver :3100 (LXC 105) ──▶ Grafana Cloud
        ▲                    (off-LAN POST fails → stays queued → drains later)
        │
  SessionEnd hook drops done/<id>  +  systemd --user timer (every 5 min)
```

**Capture and shipping are decoupled on purpose.** The transcript on disk is the
source of truth, so a hard kill that skips the `SessionEnd` hook is still caught
by the timer's idle-detection backstop. The local `spool.ndjson` is what makes
**off-LAN buffering** work: when the Loki receiver is unreachable the POST fails,
the event stays queued, and the next on-LAN tick drains the backlog.

A session is considered **finished** when its `SessionEnd` marker exists *or* its
last transcript activity is older than `COST_IDLE_MIN` (default 30 min). Each
session is emitted **exactly once** (guarded by `emitted.json`), and runs are
serialized with `flock` so a timer tick can't race a manual run.

## Files

| File | Role |
|---|---|
| `cost-export.mjs` | sweep transcripts → spool, and drain spool → Loki. Phases: `sweep`, `ship`, `seed`, `all` (default). |
| `pricing.json` | per-MTok USD price table + cache multipliers. **Drifts — keep current** (source: platform.claude.com/docs/en/about-claude/pricing). |
| `cost-hook.sh` | `SessionEnd` hook: drops a `done/<session_id>` marker so finished sessions ship promptly. |
| `session-heartbeat.sh` | `PostToolUse` + `UserPromptSubmit` hook: throttled (~30s) `session_running` beat on active tool use → the "Local sessions underway" pane. Fire-and-forget; off-LAN no-ops. |
| `claude-cost-export.{service,timer}` | systemd `--user` units; the timer runs `sweep + ship` every 5 min (backstop + off-LAN drainer). |
| `install.sh` | idempotent install: copy assets → render units → merge hooks → **seed** → start timer. |

## Install

```bash
./install.sh        # standalone; also called by workstation-bootstrap setup-*.sh
```

Install **seeds** the guard (claims existing sessions without shipping) so only
sessions completed *after* install ship — no backfill spike. To deliberately
backfill history afterward:

```bash
COST_LOOKBACK_DAYS=90 flock -n ~/.claude/cost-export/.lock \
  node ~/.claude/cost-export/cost-export.mjs sweep
```

## Live "underway" signal

The `session_running` heartbeat is **separate from cost shipping**.
`session-heartbeat.sh` fires on every `PostToolUse` (and `UserPromptSubmit`),
throttles to one push per session per `COST_HEARTBEAT_SEC` (default 30s), and
fire-and-forgets a tiny `session_running` event straight to the Loki receiver. It
is **never spooled** (a stale "running" shipped later would be misleading) and
off-LAN it just times out and vanishes — so it adds no latency and needs no state.

**The metric is active tool use, not session liveness.** A session that's open
but idle (you're reading, or away) emits no beats, so its band drops out — the
pane answers "which workstations are *working* right now", not "which sessions
are merely open". A continuously-busy session draws a solid band; long pauses show
as gaps. The dashboard query (`count_over_time(... session_running [2m]) > bool 0`,
stacked by `worker`) bridges beats within a 2-minute window.

## Cost basis

Cost is **computed** (CC doesn't write dollars to the transcript) as
`tokens × pricing.json`, with cache reads at 0.1×, 5-min cache writes at 1.25×,
1-hour cache writes at 2× base input, and Opus fast-mode at 2× rates. This is the
same API-list-price basis the fleet reports — an estimate, not a billed amount
(local sessions run on a subscription). Raw token counts are shipped alongside
`cost_usd`, so totals are recomputable if prices change.

## Config (env)

`COST_STATE_DIR` · `COST_PROJECTS_DIR` · `COST_PRICING` · `COST_LOKI_URL`
(default `http://192.168.139.20:3100/loki/api/v1/push`) · `COST_IDLE_MIN` (30) ·
`COST_LOOKBACK_DAYS` (14) · `COST_WORKER` (hostname) · `COST_REJECT_OLD_H` (160) ·
`COST_HEARTBEAT_SEC` (30, heartbeat throttle).

## Known limits

- **Resume undercount.** A session emitted after idle, then resumed (`claude
  --resume`), is not re-emitted; later cost is missed. Rare; favored over the
  double-counting risk of re-emitting.
- **Off-LAN >~1 week.** Loki rejects log lines older than its
  `reject_old_samples_max_age`; events older than `COST_REJECT_OLD_H` are shipped
  with the *current* timestamp (true time preserved in the payload's `finished`).
- **Pricing drift.** `pricing.json` is a static snapshot; update it when
  Anthropic changes prices.
