# Runner job cost on the Claytonia — Runner Fleet dashboard (#304).
#
# Gemini and Codex runner jobs report tokens and no cost. This module renders
# the runner rows of claude-cost-export/pricing.json (the fleet's one price
# table) into a LogQL stage and puts it wherever the dashboard JSON carries
# __RUNNER_JOB_COST__, so a price lives only in pricing.json and never in
# dashboard JSON. A change to pricing.json reaches Grafana through the apply
# (the workflow's path filters include it). scripts/tests/logql/render renders
# the same module offline for the LogQL fixture test.
module "runner_cost" {
  source = "./modules/runner-cost"

  pricing_json   = file("${path.module}/../claude-cost-export/pricing.json")
  dashboard_json = file("${local.dashboards_dir}/claytonia-runner-fleet.json")
}

locals {
  # Dashboard files other than the runner fleet's that carry the placeholder.
  # grafana_dashboard.claytonia fails the plan unless this is empty.
  runner_cost_placeholder_elsewhere = [
    for f in fileset(local.dashboards_dir, "*.json") : f
    if f != "claytonia-runner-fleet.json" && strcontains(file("${local.dashboards_dir}/${f}"), "__RUNNER_JOB_COST__")
  ]
}
