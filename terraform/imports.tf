# Adopt resources that the Cloud migration wizard imported into lentago.
#
# These blocks are idempotent — once a resource is in state, the import is a
# no-op. Leave them here so a fresh-state bootstrap (e.g. state file lost) can
# recover by re-importing without code changes.

import {
  to = grafana_folder.lentago
  id = "afh7m8li40zk0d"
}

import {
  to = grafana_dashboard.onprem["network_overview"]
  id = "firewalla-network-overview"
}

import {
  to = grafana_dashboard.onprem["dns_security"]
  id = "firewalla-dns-security"
}

import {
  to = grafana_dashboard.onprem["traffic_devices"]
  id = "firewalla-traffic-devices"
}

import {
  to = grafana_dashboard.onprem["infra_health"]
  id = "firewalla-infra-health"
}

import {
  to = grafana_dashboard.onprem["office_display"]
  id = "firewalla-office-display"
}

# brasenia-viewer was created by hand in the stack (2026-10-30T00:50:39Z, role
# "None") while #289 was in review, so #289's apply failed with "service
# account already exists". Adopting it keeps the hand-minted `brasenia pub`
# token alive; deleting the account would revoke that token. The apply then
# sets the role to Viewer in place.
import {
  to = grafana_service_account.brasenia_viewer
  id = "21"
}
