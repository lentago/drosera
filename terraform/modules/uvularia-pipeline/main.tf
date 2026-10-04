# uvularia pipeline pane — one dashboard + one rule group, parameterised by org.
#
# The same module serves both deployment shapes from issue #218:
#   - drosera's estate stack for the demonstration client (terraform/alerts.tf,
#     cluster = "lentago"), applied by the terraform-on-merge pipeline;
#   - a client's own free-tier stack, applied from the client's own repo with
#     `source = "git::https://github.com/lentago/drosera.git//terraform/modules/uvularia-pipeline?ref=<sha>"`
#     (docs/clients/uvularia.md). Nothing of the client's is hosted here
#     (lentago/.github ADR-0007).
#
# Events: log_source=uvularia_<stage>, cluster=<org>, payload as a one-line JSON
# log (.github/actions/loki-event, clients/loki_push.py). The payload fields
# these queries read are listed in docs/clients/uvularia.md § Event contract.
#
# Every query uses parameterised `| json name="path"` so only the field being
# read becomes a label; a bare `| json` would turn every payload field (question
# text, latency, …) into a label and split each line into its own series.

locals {
  # A git:: module source checks out the whole repo, so this path resolves the
  # same way for the estate (local source) and for a client (remote source).
  dashboard_raw = jsondecode(replace(
    file("${path.module}/../../../dashboards/uvularia-pipeline.json"),
    "/\"uid\":\\s*\"loki\"/",
    "\"uid\": \"${var.loki_datasource_uid}\""
  ))

  # The repo JSON defaults the cluster variable to the demonstration client;
  # point it at this org instead. The variable still lists every cluster with
  # uvularia events, so one JSON serves any org.
  dashboard_json = jsonencode(merge(local.dashboard_raw, {
    uid = var.dashboard_uid
    templating = {
      list = [for v in local.dashboard_raw.templating.list : merge(v, {
        current = v.name == "cluster" ? { text = var.cluster, value = var.cluster } : v.current
      })]
    }
  }))

  rule_group_name = coalesce(var.rule_group_name, "Uvularia pipeline — ${var.cluster}")

  published = "{log_source=\"uvularia_published\", cluster=\"${var.cluster}\"}"
  asked     = "{log_source=\"uvularia_asked\", cluster=\"${var.cluster}\"}"
  # Turn events carry the digest that answered, so a busy box confirms its
  # digest without waiting for the next refresh event.
  served_or_asked = "{log_source=~\"uvularia_(served|asked)\", cluster=\"${var.cluster}\"}"

  # Grafana Cloud free-tier log retention is 14 days; a publish older than that
  # has aged out of Loki and cannot be compared.
  lookback         = "14d"
  lookback_seconds = 14 * 24 * 60 * 60

  # Each expression returns one series when the rule should fire and nothing
  # when it should not, so NoData is the healthy case (no_data_state = "OK")
  # and the threshold is simply "a series exists" (count > 0).
  rules = [
    {
      key      = "stale-digest"
      panel_id = 4 # dashboard panel this alert links to (__panelId__)
      name     = "Uvularia — served digest behind published"
      # The latest published digest, unless that digest has been reported by
      # the Ask function (served refresh or answered turn) in the window.
      # Pending until it has stayed that way for stale_digest_minutes.
      expr        = "count(topk(1, max by (digest) (max_over_time(${local.published} | json digest=\"digest\", v=\"at\" | unwrap v | __error__=\"\" [${local.lookback}]))) unless on (digest) sum by (digest) (count_over_time(${local.served_or_asked} | json digest=\"digest\" | digest!=\"\" [${var.stale_digest_minutes}m])))"
      from        = local.lookback_seconds
      for         = "${var.stale_digest_minutes}m"
      severity    = "warning"
      summary     = "The Ask function for ${var.cluster} has not reported serving the latest published digest for over ${var.stale_digest_minutes} minutes. It is answering from an older corpus (or has stopped reporting): check the function's refresh and its last served event."
      description = "Latest uvularia_published digest not seen on uvularia_served or uvularia_asked in the last ${var.stale_digest_minutes}m, sustained ${var.stale_digest_minutes}m."
    },
    {
      key      = "obligation-gained"
      panel_id = 7 # dashboard panel this alert links to (__panelId__)
      name     = "Uvularia — obligation went amber or red"
      # Latest standing vs. the latest standing as of 30m ago: fires for 30
      # minutes after a publish whose amber or red count went up (an amber that
      # turned red raises red, so it fires too).
      expr        = "count(((max(last_over_time(${local.published} | json v=\"standing.amber\" | unwrap v | __error__=\"\" [${local.lookback}])) - max(last_over_time(${local.published} | json v=\"standing.amber\" | unwrap v | __error__=\"\" [${local.lookback}] offset 30m))) > 0) or ((max(last_over_time(${local.published} | json v=\"standing.red\" | unwrap v | __error__=\"\" [${local.lookback}])) - max(last_over_time(${local.published} | json v=\"standing.red\" | unwrap v | __error__=\"\" [${local.lookback}] offset 30m))) > 0))"
      from        = local.lookback_seconds + 1800
      for         = "0s"
      severity    = "warning"
      summary     = "The latest publish for ${var.cluster} has more amber or red obligations than the one before it. Open the public board to see which obligation slipped and what record would satisfy it."
      description = "standing.amber or standing.red on uvularia_published rose against the standing as of 30m earlier."
    },
    {
      key      = "cap-low"
      panel_id = 5 # dashboard panel this alert links to (__panelId__)
      name     = "Uvularia — Ask daily cap nearly spent"
      # cap_remaining / (cap_used + cap_remaining) from the most recent turn in
      # the last hour, or any turn refused for the cap. The hour bounds it to
      # today's cap, which resets at 00:00 UTC.
      expr        = "count(((max(last_over_time(${local.asked} | json v=\"cap_remaining\" | unwrap v | __error__=\"\" [1h])) / (max(last_over_time(${local.asked} | json v=\"cap_remaining\" | unwrap v | __error__=\"\" [1h])) + max(last_over_time(${local.asked} | json v=\"cap_used\" | unwrap v | __error__=\"\" [1h])))) < ${var.cap_alert_fraction}) or (sum(count_over_time(${local.asked} | json kind=\"kind\" | kind=\"capped\" [1h])) > 0))"
      from        = 3600
      for         = "0s"
      severity    = "warning"
      summary     = "The Ask box for ${var.cluster} has less than ${floor(var.cap_alert_fraction * 100)}% of today's question cap left (or has started refusing for the cap). It resets at 00:00 UTC; raise daily_cap in the rules repo's policy.yaml if this is real demand."
      description = "cap_remaining below ${var.cap_alert_fraction} of cap_used + cap_remaining on the latest uvularia_asked turn in 1h, or a kind=\"capped\" turn in 1h."
    },
  ]
}

resource "grafana_dashboard" "pipeline" {
  folder      = var.folder_uid
  overwrite   = true
  config_json = local.dashboard_json
}

resource "grafana_rule_group" "pipeline" {
  name             = local.rule_group_name
  folder_uid       = var.folder_uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = { for r in local.rules : r.key => r }

    content {
      name = rule.value.name
      for  = rule.value.for

      # Presence-shaped queries: empty means healthy. A stopped emitter is not
      # caught here — that is an ingest-absence question, not these three.
      condition      = "C"
      no_data_state  = "OK"
      exec_err_state = "Error"

      data {
        ref_id         = "A"
        datasource_uid = var.loki_datasource_uid
        query_type     = "instant"
        # query_type must mirror the model's queryType: the alerting API lifts
        # it onto the query, and an unset value plans `"instant" -> null` on
        # every apply (#221).

        relative_time_range {
          from = rule.value.from
          to   = 0
        }

        model = jsonencode({
          refId         = "A"
          expr          = rule.value.expr
          queryType     = "instant"
          editorMode    = "code"
          intervalMs    = 1000
          maxDataPoints = 43200
          datasource = {
            type = "loki"
            uid  = var.loki_datasource_uid
          }
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"

        relative_time_range {
          from = 0
          to   = 0
        }

        model = jsonencode({
          refId = "C"
          type  = "classic_conditions"
          datasource = {
            type = "__expr__"
            uid  = "__expr__"
          }
          conditions = [{
            type = "query"
            evaluator = {
              type   = "gt"
              params = [0]
            }
            operator = { type = "and" }
            query    = { params = ["A"] }
            reducer  = { type = "last", params = [] }
          }]
        })
      }

      notification_settings {
        contact_point   = var.contact_point
        group_by        = var.group_by
        repeat_interval = var.repeat_interval
      }

      labels = {
        service  = "uvularia"
        cluster  = var.cluster
        severity = rule.value.severity
      }

      annotations = {
        summary     = rule.value.summary
        description = rule.value.description
        # Grafana requires both or neither: a rule that names the dashboard must
        # also name the panel it belongs to (the first apply failed with exactly
        # that 400). Each rule declares the panel it is about.
        __dashboardUid__ = var.dashboard_uid
        __panelId__      = tostring(rule.value.panel_id)
      }
    }
  }
}
