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
# lentago/betula's Terraform state, with the TF_VAR_axiom_api_token repo secret as
# a transitional fallback (#313, below). The variable is sensitive with no default,
# the exact pattern alerts.tf uses for TF_VAR_alert_email, and a missing value
# fails the plan loudly rather than shipping an empty credential.
variable "axiom_api_token" {
  type        = string
  sensitive   = true
  description = "Axiom API token for the ALB-logs datasource, used until betula's state carries the cjp-solidago-alb-query value (#313). Set via TF_VAR_axiom_api_token; never committed (public repo)."

  validation {
    condition     = length(trimspace(var.axiom_api_token)) > 0
    error_message = "The TF_VAR_axiom_api_token secret resolved to an empty string. GitHub Actions renders a MISSING repo secret as empty rather than failing, so 'no default' alone does not catch an unset secret — this check does."
  }
}

# betula manages the Axiom tokens (lentago/betula#119, option A) and exposes their
# values as one sensitive output, axiom_tokens: a map from token name to value
# (betula's terraform/README.md, "Reading a token from another repo"). The CI role
# may read that state key, read-only (lentago/solidago#268). The read covers the
# whole state object, every token included, not just this entry: an accepted risk
# recorded in betula's README (terraform/README.md here, CI). No try(): if the
# state can't be read, the plan fails instead of quietly using the fallback.
data "terraform_remote_state" "betula" {
  backend = "s3"
  config = {
    bucket = "solidago-tfstate-365184644049"
    key    = "betula/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  # Transitional (#313, first half). An entry is null until betula first
  # regenerates that token: the tokens were imported, and Axiom returns a value
  # only on create or regenerate. Until then the repo secret is used; from the
  # token's first rotation (betula#119 step 3) betula's value wins. The second
  # half of #313 removes the variable and the secret, and adds a precondition
  # that fails the plan on a null or empty entry.
  axiom_query_token = coalesce(
    data.terraform_remote_state.betula.outputs.axiom_tokens["cjp-solidago-alb-query"],
    var.axiom_api_token,
  )
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
}
