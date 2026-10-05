# uvularia — put the pipeline pane in your own Grafana

**What you're about to do:** add the uvularia operator pane — one dashboard
and three alert rules — to **your own** Grafana Cloud stack, from a small
Terraform file in **your own** repo. Terraform is a tool that reads a file
describing what should exist ("this dashboard, these alerts") and makes your
Grafana match it.

**Why bother:** your records pipeline already tells you, stage by stage, what
it just did. This pane lines those reports up left to right — Intake ·
Reviewed · Published · Served · Asked — so you can see at a glance where things
are waiting, and it emails you when the Ask box is serving an old corpus, when
an obligation slips to amber or red, or when the day's question cap is nearly
spent.

**Time:** about twenty minutes the first time, most of it making the token.
After that, picking up a new version is one line and one `terraform apply`.

Everything here runs in your stack and your repo. Lentago Labs hosts nothing
of yours, holds no copy of your data, and can't see your dashboard (that's
the rule in [lentago/.github ADR-0007](https://github.com/lentago/.github/blob/main/docs/adr/0007-client-owned-delivery-no-multi-tenant-saas.md)).
Our own copy of this pane, for the demonstration client, is wired up the same
way in [`terraform/alerts.tf`](../../terraform/alerts.tf) — we practice what we
publish.

## Before you start

- **Your pipeline sends events.** Each uvularia stage pushes one event to your
  Loki (Grafana's log store) with the
  [`loki-event` action](../../.github/actions/loki-event/README.md) or
  [`loki_push.py`](../../clients/README.md). Without events the pane is
  empty — every panel reads "no data", never a fake green. Set those up first.
- **Terraform 1.5 or newer** on your laptop
  ([install guide](https://developer.hashicorp.com/terraform/install)).
- **Your org slug** — the `cluster` value your events carry, e.g.
  `stillwater`. It's the same word you put in `cluster:` on the action.

## 1. Make a Grafana token

This token lets Terraform create the dashboard, a folder, an email contact
point, and the alert rules. It is **not** the `logs:write` token your
pipeline uses.

1. Open your stack (`https://<your-stack>.grafana.net`) and go to
   **Administration → Users and access → Service accounts → Add service
   account**. Name it `terraform`, role **Editor**.
2. **Add service account token**, copy it (it starts `glsa_`; shown once).

> **Heads up.** Keep this token out of git. Anyone holding it can change your
> dashboards and alerts.

## 2. Add the Terraform file

In a repo you own (your records repo is fine; a folder called `grafana/`
keeps it tidy), create `grafana/main.tf`:

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.18"
    }
  }
}

variable "grafana_url" {
  type        = string
  description = "Your stack URL, e.g. https://stillwater.grafana.net"
}

variable "grafana_token" {
  type      = string
  sensitive = true
}

variable "alert_email" {
  type      = string
  sensitive = true
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_token
}

resource "grafana_folder" "uvularia" {
  title = "Uvularia"
}

resource "grafana_contact_point" "email" {
  name = "Uvularia email"
  email {
    addresses = [var.alert_email]
  }
}

module "uvularia_pipeline" {
  # Pin to a commit you've looked at; see "Picking up a new version" below.
  source = "git::https://github.com/lentago/drosera.git//terraform/modules/uvularia-pipeline?ref=<commit-sha>"

  cluster       = "stillwater" # your org slug
  folder_uid    = grafana_folder.uvularia.uid
  contact_point = grafana_contact_point.email.name

  # Optional — these are the defaults:
  # repeat_interval      = "4h"   # how often a still-firing alert re-emails
  # group_by             = null   # Grafana's default notification grouping
  # stale_digest_minutes = 30
  # served_window_hours  = 12
  # cap_alert_fraction   = 0.2
}
```

Replace `<commit-sha>` with the latest commit on
[drosera's `main`](https://github.com/lentago/drosera/commits/main) and
`stillwater` with your slug. The module reads the same dashboard file we use,
[`dashboards/uvularia-pipeline.json`](../../dashboards/uvularia-pipeline.json),
and the rules in
[`terraform/modules/uvularia-pipeline/main.tf`](../../terraform/modules/uvularia-pipeline/main.tf).

Then add a `.gitignore` next to it:

```
.terraform/
*.tfstate
*.tfstate.*
```

> **Heads up.** `terraform.tfstate` is Terraform's notebook of what it
> created. It holds your alert email, so it stays out of git (especially in a
> public repo). Keep it on your laptop and back it up with your other files.
> If you lose it, Terraform forgets it made these things: delete the
> `Uvularia` folder in Grafana and apply again.

## 3. Apply it

```bash
cd grafana
export TF_VAR_grafana_url=https://stillwater.grafana.net
export TF_VAR_grafana_token=glsa_...
export TF_VAR_alert_email=you@example.org
terraform init
terraform apply
```

Terraform lists what it will create — a folder, a contact point, a dashboard,
and a rule group — and asks you to type `yes`.

## How you know it worked

- `terraform apply` ends with `Apply complete! Resources: 4 added`.
- In Grafana, **Dashboards → Uvularia → Uvularia — Records pipeline** opens
  with your slug in the **Org (cluster)** box at the top. Panels with events
  behind them show numbers; the rest say "no data".
- **Alerting → Alert rules** shows a group called
  `Uvularia pipeline — <your slug>` with four rules, all **Normal**.
- To check the email path, open **Alerting → Contact points → Uvularia email
  → Test**. The test mail arrives within a minute.

## What the pane reads

The top row, left to right:

| Panel | Shows |
|---|---|
| **Intake** | open intake Issues and PRs, and how long the oldest has waited |
| **Reviewed** | PRs with green checks waiting on a person, and the oldest's wait |
| **Published** | the latest digest and how long ago it went out, with obligations green / amber / red / no data |
| **Served** | the digest the Ask box last said it's serving and when, its rules tag, and refresh checks in 24h |
| **Asked** | last 24h by outcome (answered, incident, escalated, declined), median latency, cap left, last question |

Below that: **announcement merge-to-live latency** (one dot per publish that
took an announcement live), the **obligation timeline** (how the standing
looked at each publish), and the **demand loop** — the subjects people asked
about most this week that the box escalated or declined. Each of those bars is
a record nobody has written yet.

## The four alerts

| Alert | Fires when | What to do |
|---|---|---|
| **served digest behind published** | the Ask box has reported in (a `served` refresh or an answered question) since the newest publish, and is still on an older digest, for 30 minutes | check the Ask function's refresh; it's answering from an older corpus |
| **Ask function silent** | no `served` refresh and no answered question at all in 12 hours | check the rules repo's `heartbeat` workflow and its `ASK_HEALTH_URL` variable, then the function's own logs |
| **obligation went amber or red** | a publish has more amber or red obligations than the one before; stays lit 30 minutes, so you get one email | open your public board and see which obligation slipped |
| **Ask daily cap nearly spent** | the most recent question in the last hour left under 20 % of the day's cap, or a question was turned away for the cap | it resets at 00:00 UTC; raise `daily_cap` in the rules repo's `policy.yaml` if it's real demand |

The first three treat "no events" as calm. They watch for something going
wrong in events that arrive; they don't notice an emitter that has gone quiet.
**Ask function silent** is the one exception, because the stale-digest check
can't judge a box that never reports. For the other stages the panels show
it: a stage with no events reads "no data".

## Event contract

Every event carries the labels from
[clients/README.md § Label discipline](../../clients/README.md#label-discipline):
`log_source=uvularia_<stage>`, `cluster=<your slug>`, plus `source`,
`pipeline`, `stage`, `repo`. The pane selects on `log_source` and `cluster`
only, so your `pipeline` names are up to you. The payload (the JSON object you
pass as `payload-json`) needs these fields:

| Stage (`log_source`) | Sent by | Payload fields the pane reads |
|---|---|---|
| `uvularia_intake` | records intake workflow, on each run and daily | `at`, `open` (open intake Issues + PRs), `oldest_opened_at` (`0` when none) |
| `uvularia_reviewed` | records validate workflow, on each run and daily | `at`, `awaiting` (green PRs waiting on a person), `oldest_green_at` (`0` when none) |
| `uvularia_published` | records publish workflow | `at` (the receipt's `published_at`), `digest`, `standing` (`{green, amber, red, no_data}`, as in the receipt), `announcement_latency_s` (longest merge-to-live in this publish; leave it out when no announcement went live) |
| `uvularia_evals` | rules evals workflow | none yet; sent for the record |
| `uvularia_rules_released` | rules release workflow | `tag` (drawn as a marker on the timeline) |
| `uvularia_served` | Ask function, on every refresh check, at least every 15 minutes | `at`, `digest`, `rules_tag` |
| `uvularia_asked` | Ask function, once per question | `at`, `kind`, `latency_ms`, `cap_used`, `cap_remaining`, `digest`, `subject` (the first subject the question matched, `unmatched` if none) |

All times are Unix seconds (`date +%s`). Nothing in a payload identifies the
person asking: the question text is truncated and carries no name, address,
or IP ([lentago/uvularia#52](https://github.com/lentago/uvularia/issues/52)).

> **Heads up.** The silence alert counts on hearing from the Ask box at least
> every 12 hours. If your function only refreshes when someone asks a
> question, a quiet day looks like a dead box. Send `served` on a schedule
> (the rules repo's `heartbeat` workflow does this). GitHub runs those
> schedules late, often hours apart, which is why the window is 12 hours and
> not 30 minutes.

> **Heads up.** The Grafana Cloud free tier keeps logs for 14 days. A stage
> that hasn't reported in that long reads "no data", and a publish older than
> that can no longer be compared against.

## Picking up a new version

Change `ref=<commit-sha>` to a newer commit, run `terraform init -upgrade`,
then `terraform apply`. Read the plan before you type `yes`: it shows exactly
what changes on the dashboard and the rules.

## Leaving

Everything lives in your stack and your repo. To leave us, fork
[lentago/drosera](https://github.com/lentago/drosera) (or copy just
`dashboards/uvularia-pipeline.json` and `terraform/modules/uvularia-pipeline/`
into your repo) and point `source` at your copy. To remove the pane, run
`terraform destroy`. Your events stay in Loki until they age out. To leave
Grafana Cloud, the dashboard is plain JSON any Grafana can import, and the
events are ordinary Loki logs.
