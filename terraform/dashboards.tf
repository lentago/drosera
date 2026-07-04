resource "grafana_dashboard" "firewalla" {
  for_each = local.firewalla_dashboards

  folder      = grafana_folder.firewalla.uid
  overwrite   = true
  config_json = local.firewalla_dashboard_json[each.key]
}

resource "grafana_dashboard" "solidago" {
  for_each = local.solidago_dashboards

  folder      = grafana_folder.solidago.uid
  overwrite   = true
  config_json = local.solidago_dashboard_json[each.key]
}
