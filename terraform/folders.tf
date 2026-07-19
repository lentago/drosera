# Folder taxonomy follows the Lentago product lines: one folder per product
# (Claytonia, Solidago), Sites for the per-site dashboards, and Lentago Lab
# for the homelab source itself — the lab is drosera's first *client*, not a
# product. The lab folder keeps its wizard-imported uid; renaming a folder uid
# would destroy/recreate it and orphan every dashboard link into it.

resource "grafana_folder" "lab" {
  title = "Lentago Lab"
  uid   = "afh7m8li40zk0d"
}

resource "grafana_folder" "claytonia" {
  title = "Claytonia"
  uid   = "claytonia"
}

resource "grafana_folder" "solidago" {
  title = "Solidago"
  uid   = "solidago"
}

resource "grafana_folder" "sites" {
  title = "Sites"
  uid   = "sites"
}

# 2026-07-18 product-line reorg (renames in state, no destroy/create):
# grafana_folder.firewalla         -> grafana_folder.lab
# grafana_dashboard.firewalla      -> grafana_dashboard.lab
# ...and the runner-fleet dashboard out of the lab map into claytonia.
moved {
  from = grafana_folder.firewalla
  to   = grafana_folder.lab
}

moved {
  from = grafana_dashboard.firewalla
  to   = grafana_dashboard.lab
}

moved {
  from = grafana_dashboard.lab["claude_runner_fleet"]
  to   = grafana_dashboard.claytonia["runner_fleet"]
}
