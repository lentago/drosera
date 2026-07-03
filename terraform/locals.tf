locals {
  dashboards_dir = "${path.module}/../dashboards"

  # Dashboard JSON in the repo references the original self-hosted datasource
  # UIDs ("loki" and "prometheus"). On Grafana Cloud the lentago stack
  # auto-provisions datasources whose *UID* is "grafanacloud-<service>"
  # (logs / prom / infinity). The stack-name prefix ("grafanacloud-lentago-*")
  # appears in the datasource *name*, NOT its UID — panels reference datasources
  # by UID, so we must rewrite to the UID, not the name. We rewrite at apply time
  # so the JSON files stay portable.
  #
  # To verify the UIDs on a live stack (note: read .uid, not .name):
  #   curl -s -H "Authorization: Bearer $GRAFANA_AUTH" $GRAFANA_URL/api/datasources \
  #     | jq '.[] | {uid, name}'
  #
  # History: loki/prometheus were previously rewritten to the *name*
  # ("grafanacloud-lentago-{logs,prom}"), which are non-existent UIDs. Prom
  # panels still rendered because the Prometheus datasource is the stack default,
  # so a dangling UID silently fell back to it; all-Loki dashboards (e.g.
  # claude-runner-fleet) showed "No data" because the fallback default is
  # Prometheus, which can't run LogQL. infinity was already correct.
  datasource_uid_rewrites = {
    "loki"       = "grafanacloud-logs"
    "prometheus" = "grafanacloud-prom"
    "infinity"   = "grafanacloud-infinity"
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
    neptune_nas = {
      uid  = "firewalla-neptune-nas"
      file = "neptune-nas.json"
    }
    claude_runner_fleet = {
      uid  = "claude-runner-fleet"
      file = "claude-runner-fleet.json"
    }
  }

  # Read each dashboard JSON file and rewrite datasource UIDs in one pass.
  # The regex tolerates either `"uid": "loki"` or `"uid":"loki"` (and similar
  # for prometheus) so we don't depend on the formatter's whitespace.
  firewalla_dashboard_json = {
    for k, d in local.firewalla_dashboards :
    k => replace(
      replace(
        replace(
          file("${local.dashboards_dir}/${d.file}"),
          "/\"uid\":\\s*\"loki\"/",
          "\"uid\": \"${local.datasource_uid_rewrites["loki"]}\""
        ),
        "/\"uid\":\\s*\"prometheus\"/",
        "\"uid\": \"${local.datasource_uid_rewrites["prometheus"]}\""
      ),
      "/\"uid\":\\s*\"infinity\"/",
      "\"uid\": \"${local.datasource_uid_rewrites["infinity"]}\""
    )
  }
}
