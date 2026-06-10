#!/usr/bin/env bash
set -euo pipefail

# Grafana Alloy host-agent deployment for homelab hosts (Debian 12).
# Idempotent — safe to re-run.
#
# Installs Grafana Alloy from the official apt repo and configures it as a
# host-local "push" agent: it scrapes the node_exporter already running on
# localhost:9100 and remote_writes to Grafana Cloud Mimir every 15s. This is
# the standardized collection model — every important host owns and ships its
# own metrics (buffered locally across network blips) instead of being pulled
# by the central Alloy on LXC 105.
#
# Labels match the central "node" job exactly (job="node",
# instance=$ALLOY_INSTANCE), so every existing dashboard and query is
# unchanged.
#
# Required environment (same vars as the central .envrc):
#   GRAFANA_CLOUD_METRICS_URL    Mimir remote_write endpoint
#   GRAFANA_CLOUD_METRICS_USER   Mimir username (numeric)
#   GRAFANA_CLOUD_METRICS_TOKEN  Grafana Cloud push token (metrics:write scope)
#
# Instance label (arg 1, or $ALLOY_INSTANCE; defaults to `hostname -s`):
#   the value used for the instance="" label — must match the name this host
#   already uses in the central scrape (e.g. neptune, pve, pve2, pve3, pve5).
#
# Usage (run as root, or as a sudo-capable user):
#   source .envrc   # exports GRAFANA_CLOUD_METRICS_*
#   ./deploy-alloy.sh <instance-label>
#
# AFTER it succeeds, remove this host from the central prometheus.scrape "node"
# block in alloy/config.alloy on LXC 105 so its series are not double-scraped.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Privilege — use sudo only if not already root.
# ---------------------------------------------------------------------------
if [[ ${EUID} -eq 0 ]]; then
  SUDO=""
else
  command -v sudo >/dev/null || fail "Run as root, or install sudo."
  SUDO="sudo"
fi

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
ALLOY_INSTANCE="${ALLOY_INSTANCE:-${1:-$(hostname -s)}}"
[[ -n "${ALLOY_INSTANCE}" ]] || fail "ALLOY_INSTANCE is empty — pass the instance label as arg 1."
info "Instance label: ${ALLOY_INSTANCE}"

for v in GRAFANA_CLOUD_METRICS_URL GRAFANA_CLOUD_METRICS_USER GRAFANA_CLOUD_METRICS_TOKEN; do
  [[ -n "${!v:-}" ]] || fail "Required env var ${v} is not set — 'source .envrc' first."
done

# ---------------------------------------------------------------------------
# Prerequisite — node_exporter must already be serving on :9100
# ---------------------------------------------------------------------------
info "Checking node_exporter on localhost:9100..."
command -v curl >/dev/null || fail "curl is required but not installed."
curl -fsS --max-time 5 http://localhost:9100/metrics >/dev/null 2>&1 \
  || fail "node_exporter not reachable on localhost:9100 — run deploy-node-exporter.sh first."
success "node_exporter reachable."

# ---------------------------------------------------------------------------
# Install Alloy from the Grafana apt repo (idempotent)
# ---------------------------------------------------------------------------
if command -v alloy >/dev/null 2>&1; then
  success "Alloy already installed ($(alloy --version 2>/dev/null | head -1 || echo present)) — skipping install."
else
  if ! command -v gpg >/dev/null 2>&1; then
    info "Installing gnupg (needed for the repo key)..."
    ${SUDO} apt-get install -y gnupg || fail "Could not install gnupg."
  fi

  info "Adding the Grafana apt repository..."
  ${SUDO} install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | ${SUDO} gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg \
    || fail "Failed to fetch/install the Grafana GPG key."
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | ${SUDO} tee /etc/apt/sources.list.d/grafana.list >/dev/null

  # Update ONLY the Grafana repo list, so an unrelated failing repo (e.g. the
  # Proxmox enterprise repo returning 401) can't leave alloy unindexed. A real
  # failure to reach the Grafana repo is fatal.
  # DPkg::Lock::Timeout makes apt wait for the dpkg lock instead of failing
  # immediately — Proxmox nodes run background apt/pve tasks that briefly hold it.
  info "Refreshing the Grafana apt repo index..."
  ${SUDO} apt-get update \
    -o Dir::Etc::sourcelist="sources.list.d/grafana.list" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0" \
    -o DPkg::Lock::Timeout="120" \
    || fail "Failed to refresh the Grafana apt repo index."

  info "Installing alloy..."
  ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout="120" alloy \
    || fail "apt-get install alloy failed."
  success "Alloy installed."
fi

# ---------------------------------------------------------------------------
# Write the host-agent config (canonical source — edit here, not on the host)
# ---------------------------------------------------------------------------
info "Writing /etc/alloy/config.alloy..."
${SUDO} install -d -m 0755 /etc/alloy
${SUDO} tee /etc/alloy/config.alloy >/dev/null <<'ALLOY_EOF'
// Host-local Alloy agent (push / remote_write model).
//
// Managed by scripts/deploy-alloy.sh in PitziLabs/homelab-observability —
// edit there, re-run the script; do NOT hand-edit on the host.
//
// Scrapes the node_exporter on localhost:9100 and remote_writes to Grafana
// Cloud Mimir at 15s. Labels (job="node", instance from $ALLOY_INSTANCE) match
// the central scrape, so dashboards and queries are unchanged. Secrets and the
// instance label come from /etc/default/alloy (0600), never from git.

logging {
  level  = "info"
  format = "logfmt"
}

prometheus.scrape "node" {
  targets = [
    { __address__ = "127.0.0.1:9100", instance = sys.env("ALLOY_INSTANCE") },
  ]
  forward_to      = [prometheus.remote_write.cloud.receiver]
  scrape_interval = "15s"
  job_name        = "node"
}

prometheus.remote_write "cloud" {
  endpoint {
    url = sys.env("GRAFANA_CLOUD_METRICS_URL")
    basic_auth {
      username = sys.env("GRAFANA_CLOUD_METRICS_USER")
      password = sys.env("GRAFANA_CLOUD_METRICS_TOKEN")
    }
  }
  external_labels = {
    cluster = "homelab",
  }
}
ALLOY_EOF

# ---------------------------------------------------------------------------
# Write the env file (secrets + instance) — root-only, read by systemd
# ---------------------------------------------------------------------------
info "Writing /etc/default/alloy (0600, holds the push token)..."
${SUDO} tee /etc/default/alloy >/dev/null <<ENV_EOF
## Managed by deploy-alloy.sh — host-agent settings + Grafana Cloud push creds.
## systemd reads this as EnvironmentFile (as root, before dropping to user alloy).
CONFIG_FILE="/etc/alloy/config.alloy"
CUSTOM_ARGS=""
RESTART_ON_UPGRADE=true

ALLOY_INSTANCE="${ALLOY_INSTANCE}"
GRAFANA_CLOUD_METRICS_URL="${GRAFANA_CLOUD_METRICS_URL}"
GRAFANA_CLOUD_METRICS_USER="${GRAFANA_CLOUD_METRICS_USER}"
GRAFANA_CLOUD_METRICS_TOKEN="${GRAFANA_CLOUD_METRICS_TOKEN}"
ENV_EOF
${SUDO} chown root:root /etc/default/alloy
${SUDO} chmod 0600 /etc/default/alloy

# ---------------------------------------------------------------------------
# Enable + (re)start
# ---------------------------------------------------------------------------
info "Enabling and restarting alloy..."
${SUDO} systemctl daemon-reload
${SUDO} systemctl enable alloy >/dev/null 2>&1 || true
${SUDO} systemctl restart alloy || fail "alloy failed to start — check 'journalctl -u alloy -n 50'."

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
sleep 3
${SUDO} systemctl is-active --quiet alloy || fail "alloy is not active after restart."
success "alloy service is active."

info "Waiting for the Alloy ready endpoint (localhost:12345)..."
READY=false
for _ in $(seq 1 10); do
  if curl -fsS --max-time 3 http://localhost:12345/-/ready >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 1
done
if [[ "${READY}" == true ]]; then
  success "Alloy is ready and shipping metrics."
else
  warn "Alloy ready endpoint did not respond — check 'journalctl -u alloy -n 50'."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Alloy host-agent running on '${ALLOY_INSTANCE}' (push @ 15s).${NC}"
echo -e "${YELLOW} NEXT: remove '${ALLOY_INSTANCE}' from the central${NC}"
echo -e "${YELLOW}       prometheus.scrape \"node\" block in alloy/config.alloy${NC}"
echo -e "${YELLOW}       on LXC 105, or its series will be scraped twice.${NC}"
echo -e "${GREEN}============================================================${NC}"
