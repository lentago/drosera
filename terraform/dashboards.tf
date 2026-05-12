resource "grafana_dashboard" "firewalla" {
  for_each = local.firewalla_dashboards

  folder      = grafana_folder.firewalla.uid
  overwrite   = true
  config_json = local.firewalla_dashboard_json[each.key]
}
