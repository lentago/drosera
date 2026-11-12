# Offline render of the dashboards whose JSON carries placeholders, with the
# module terraform/ applies (terraform/runner-cost.tf), so the LogQL fixture
# test runs the query Grafana gets. No providers and no backend: render.sh
# plans this root and reads the outputs from the plan.
terraform {
  required_version = ">= 1.5.0"
}

module "runner_cost" {
  source = "../../../../terraform/modules/runner-cost"

  pricing_json   = file("${path.module}/../../../../claude-cost-export/pricing.json")
  dashboard_json = file("${path.module}/../../../../dashboards/claytonia-runner-fleet.json")
}

output "claytonia-runner-fleet" {
  value = module.runner_cost.dashboard_json
}
