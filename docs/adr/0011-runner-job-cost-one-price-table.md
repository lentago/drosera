# ADR-0011: Runner job cost from one price table, rendered into the dashboard at apply time

**Status:** Accepted (2026-11-12)

## Context

Peer worker runtimes (lentago/claytonia#166) put Gemini CLI and Codex CLI jobs on
the bullpen beside Claude Code. Claude jobs report their own `total_cost_usd`.
Gemini and Codex report tokens only, so their `job_complete` lines carry
`cost_usd: null`, and since #303 the *Claytonia — Runner Fleet* spend panels count
every such job as unpriced. #304 asks for those jobs to be priced, with three
constraints: `claude-cost-export/pricing.json` stays the fleet's only price table
(claytonia carries none, claytonia#166 review decision 5); its Claude fallback
`_default` never prices a non-Claude model; and local Claude session costs from
`cost-export.mjs` do not change.

The Phase 1 gate runs (2026-11-04) showed what the line has to carry. A Gemini
job on the CLI default reports `model=default` and uses three models: a router,
a main model that can change mid-job, and a loop detector. Codex's output names
no model. OpenAI bills cache writes at their own rate, and in those runs cache
writes were nearly all of a Codex job's uncached input. Job totals plus one
model name cannot be priced correctly.

## Decision

1. **Token contract** (recorded on lentago/claytonia#173). `job_complete` carries
   `tokens` and `tokens_by_model` (`{"<model id>": {...}}`), each with five
   disjoint fields: `in`, `cached`, `cache_write`, `out` and `thinking`. Codex
   files its tokens under the model named in the session transcript, or under
   `unknown`.
2. **Runner rows in the one table.** A row with a `runtime` (`gemini`, `codex`)
   carries explicit per-MTok rates in a `prices` list: `input`, `cached_input`,
   `output` (which also prices thinking) and, where the vendor charges it,
   `cache_write`. Each entry after the first starts at a `from` date. The Claude
   multipliers and `_default` never apply to these rows, and `cost-export.mjs`
   drops them when it loads the table.
3. **Rendered at apply time.** `terraform/modules/runner-cost` turns the runner
   rows into one LogQL `label_format cost=…` stage using Loki's template math,
   and replaces `__RUNNER_JOB_COST__` with it wherever a spend panel puts that
   placeholder. `cost` is the job's own `cost_usd` when it has one. Otherwise it
   is the job's per-model tokens priced at the period matching its `finished`
   date, and otherwise empty. The workflow's path filters include
   `pricing.json`, so a price change applies like a dashboard change.
4. **Unknown, never guessed.** A job is priced only when the tokens its rows
   priced add up to its totals, and at least one token was priced. That leaves a
   job unknown, never priced at $0, never partly priced and never priced as
   another model, when any of these hold:
   - it used a model with no row (a model called at zero tokens prices
     nothing either way, so it does not count);
   - it has write tokens on a row without a write rate;
   - its totals are null or all zero;
   - its price depends on a date it does not carry.
5. **Base prompt-length tier.** Rows price the vendor's base tier. Job totals
   cannot show which requests crossed a long-context threshold.

## Alternatives considered

- **An Infinity inline table joined on `model`.** It would keep LogQL simple.
  But the join works per series, not per job and model, and the price would
  still have to come from somewhere other than the panel JSON.
- **Generated per-model LogQL terms combined with vector arithmetic.** That is
  one `sum_over_time … unwrap` per model and field, multiplied by a scalar. It
  takes dozens of terms per panel, each needing an `or vector(0)` guard, and it
  cannot express "unknown if any model lacks a row" without a second set of
  terms.
- **Committing the generated LogQL into the dashboard JSON** behind a sync check.
  The deployed query would be visible in the repo. But the price would sit in
  two files, seven times over in the dashboard, and a price change would need a
  regeneration step.
- **One resolved model per job** (`model_used`), with every token priced at that
  model. It is simpler for claytonia, but about 1% off for Gemini, and it makes
  the router and loop-detector rows dead weight.

## Consequences

- **The dashboard JSON in the repo no longer runs as written** for the spend
  panels. `scripts/tests/logql/render.sh` renders it offline with the same
  module, and `run.py` refuses an expression that still holds a placeholder.
- **Prices apply at query time**, so a vendor price change is a new dated entry
  in the row's `prices` list. Editing the existing entry reprices past jobs.
- **The stage uses the template variables `$priced_usd` and `$priced_tok`.**
  Grafana leaves an undefined `$name` alone, so the dashboard must never define
  a variable with either name.
- **The stage grows with every runner row.** Today it is five rows and six
  periods, about 4 KB per panel query.
- **A request whose prompt passes the long-context threshold is
  under-reported:** 200K tokens on Vertex AI, 272K on OpenAI.
- **The live check waits on claytonia#173.** Until it emits `tokens_by_model`,
  Gemini and Codex jobs stay unknown, as they were under #303.
