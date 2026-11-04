# terraform/datasources.tf
#
# Datasources we manage ourselves. The stack's built-in datasources
# (grafanacloud-prom / grafanacloud-logs / grafanacloud-infinity) are
# auto-provisioned by Grafana Cloud and deliberately NOT managed here.
#
# Solidago CloudWatch: query-on-demand against the AWS account, via the
# cross-account role provisioned in lentago/solidago (modules/grafana-cloud).
# Auth is "Grafana Assume Role" — Grafana Cloud's own AWS account assumes our
# role, presenting this stack's External ID; no credentials are stored on
# either side. Because IAM role ARNs are deterministic, solidago's nightly
# teardown/standup DR drill recreates the role at the same ARN and this
# datasource never needs re-pointing.

resource "grafana_data_source" "solidago_cloudwatch" {
  type = "cloudwatch"
  name = "Solidago CloudWatch"
  uid  = "solidago-cloudwatch"

  json_data_encoded = jsonencode({
    authType      = "grafana_assume_role"
    assumeRoleArn = "arn:aws:iam::365184644049:role/solidago-dev-grafana-cloudwatch"
    defaultRegion = "us-east-1"
  })
}

# Solidago Axiom: query-on-demand against the ALB access logs that lentago/betula
# ships into the `cjp-solidago-alb` Axiom dataset (betula#87). This is the render
# side of the capture-once boundary — drosera queries Axiom directly; nothing is
# teed into Loki/Mimir. The signed `axiomhq-axiom-datasource` plugin this needs is
# installed by grafana_cloud_plugin_installation.axiom in plugins.tf (pinned to
# 0.7.2), so the stack requirement is codified rather than a manual prerequisite.
#
# The API token is NEVER committed (drosera is a public repo). It comes from
# lentago/betula's Terraform state (#313, below); there is no repo secret for it.
#
# betula manages the Axiom tokens (lentago/betula#119, option A) and exposes their
# values as one sensitive output, axiom_tokens: a map from token name to value
# (betula's terraform/README.md, "Reading a token from another repo"). The CI role
# may read that state key, read-only (lentago/solidago#268). The read covers the
# whole state object, every token included, not just this entry: an accepted risk
# recorded in betula's README (terraform/README.md here, CI). No try() around the
# read: if the state can't be read, the plan fails.
data "terraform_remote_state" "betula" {
  backend = "s3"
  config = {
    bucket = "solidago-tfstate-365184644049"
    key    = "betula/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  # betula's value for this datasource's token. An entry is null until betula
  # first creates or regenerates that token; this one was regenerated in
  # betula#119 step 3 (2026-11-04). A rotation in betula changes the value, and
  # drosera must apply within its 48-hour grace period to pick it up (betula's
  # README, "Rotation timing"). The precondition below fails the plan if the
  # entry is ever null or empty, rather than shipping an empty credential.
  axiom_query_token = data.terraform_remote_state.betula.outputs.axiom_tokens["cjp-solidago-alb-query"]
}

resource "grafana_data_source" "solidago_axiom" {
  type = "axiomhq-axiom-datasource"
  name = "Solidago Axiom"
  uid  = "solidago-axiom"

  # accessToken is the plugin's secureJsonData key; it is stored server-side by
  # Grafana and never read back into state as plaintext.
  secure_json_data_encoded = jsonencode({
    accessToken = local.axiom_query_token
  })

  # Explicit: a datasource of this type cannot be created until the plugin that
  # provides it exists on the stack. Nothing in the arguments above references
  # the installation, so Terraform has no implicit edge to infer — without this
  # the two can be ordered arbitrarily and a first apply fails intermittently.
  depends_on = [grafana_cloud_plugin_installation.axiom]

  lifecycle {
    precondition {
      condition     = try(length(trimspace(local.axiom_query_token)) > 0, false)
      error_message = "betula's axiom_tokens output has no value for cjp-solidago-alb-query (null or empty). The entry is null until betula creates or regenerates that token; see betula's terraform/README.md, \"Reading a token from another repo\"."
    }
  }
}
