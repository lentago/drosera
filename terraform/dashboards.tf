resource "grafana_dashboard" "lab" {
  for_each = local.lab_dashboards

  folder      = grafana_folder.lab.uid
  overwrite   = true
  config_json = local.lab_dashboard_json[each.key]
}

resource "grafana_dashboard" "claytonia" {
  for_each = local.claytonia_dashboards

  folder      = grafana_folder.claytonia.uid
  overwrite   = true
  config_json = local.claytonia_dashboard_json[each.key]
}

resource "grafana_dashboard" "solidago" {
  for_each = local.solidago_dashboards

  folder      = grafana_folder.solidago.uid
  overwrite   = true
  config_json = local.solidago_dashboard_json[each.key]
}

resource "grafana_dashboard" "sites" {
  for_each = local.sites_dashboards

  folder      = grafana_folder.sites.uid
  overwrite   = true
  config_json = local.sites_dashboard_json[each.key]
}
