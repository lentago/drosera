locals {
  dashboards_dir = "${path.module}/../dashboards"

  # Dashboard JSON in the repo references the original self-hosted datasource
  # UIDs ("loki" and "prometheus"). On Grafana Cloud the equivalent datasources
  # are auto-provisioned with different UIDs. We rewrite the references at apply
  # time so the JSON files stay portable.
  datasource_uid_rewrites = {
    "loki"       = "grafanacloud-logs"
    "prometheus" = "grafanacloud-prom"
  }

  firewalla_dashboards = {
    network_overview = {
      uid  = "firewalla-network-overview"
      file = "network-overview.json"
    }
    dns_security = {
      uid  = "firewalla-dns-security"
      file = "dns-security.json"
    }
    traffic_devices = {
      uid  = "firewalla-traffic-devices"
      file = "traffic-devices.json"
    }
    infra_health = {
      uid  = "firewalla-infra-health"
      file = "infra-health.json"
    }
    office_display = {
      uid  = "firewalla-office-display"
      file = "office-display.json"
    }
  }

  # Read each dashboard JSON file and rewrite datasource UIDs in one pass.
  # The regex tolerates either `"uid": "loki"` or `"uid":"loki"` (and similar
  # for prometheus) so we don't depend on the formatter's whitespace.
  firewalla_dashboard_json = {
    for k, d in local.firewalla_dashboards :
    k => replace(
      replace(
        file("${local.dashboards_dir}/${d.file}"),
        "/\"uid\":\\s*\"loki\"/",
        "\"uid\": \"${local.datasource_uid_rewrites["loki"]}\""
      ),
      "/\"uid\":\\s*\"prometheus\"/",
      "\"uid\": \"${local.datasource_uid_rewrites["prometheus"]}\""
    )
  }
}
