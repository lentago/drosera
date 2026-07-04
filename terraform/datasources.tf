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
    assumeRoleArn = "arn:aws:iam::365184644049:role/foundry-dev-grafana-cloudwatch"
    defaultRegion = "us-east-1"
  })
}
