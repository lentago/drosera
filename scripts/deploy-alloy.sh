#!/usr/bin/env bash
set -euo pipefail

# Grafana Alloy host-agent deployment for Lentago lab hosts (Debian 12).
# Idempotent — safe to re-run.
#
# Installs Grafana Alloy from the official apt repo and configures it as a
# host-local "push" agent: it scrapes the node_exporter already running on
# localhost:9100 and remote_writes to Grafana Cloud Mimir every 60s. This is
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

for v in GRAFANA_CLOUD_METRICS_URL GRAFANA_CLOUD_METRICS_USER GRAFANA_CLOUD_METRICS_TOKEN \
  GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_LOGS_USER GRAFANA_CLOUD_LOGS_TOKEN; do
  [[ -n "${!v:-}" ]] || fail "Required env var ${v} is not set — 'source .envrc' first."
done

# Catch un-expanded placeholders (e.g. a single-quoted '$GRAFANA_...' that never
# expanded) before we write bad creds. The URLs are non-secret, safe to echo.
for u in GRAFANA_CLOUD_METRICS_URL GRAFANA_CLOUD_LOGS_URL; do
  case "${!u}" in
    https://*) ;;
    *) fail "${u} is '${!u}', not an https URL — the var didn't expand. Run from the repo with '.envrc' sourced." ;;
  esac
done
case "${GRAFANA_CLOUD_METRICS_URL}${GRAFANA_CLOUD_METRICS_USER}${GRAFANA_CLOUD_METRICS_TOKEN}${GRAFANA_CLOUD_LOGS_URL}${GRAFANA_CLOUD_LOGS_USER}${GRAFANA_CLOUD_LOGS_TOKEN}" in
  *'$'*) fail "A Grafana Cloud credential contains a literal '\$' — the env vars weren't expanded. Source '.envrc' and pass real values, not single-quoted placeholders." ;;
esac

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

  # Use `env` to set DEBIAN_FRONTEND: when running as root SUDO is empty, and a
  # bare `${SUDO} VAR=val cmd` makes bash try to execute `VAR=val` as a command
  # once the empty word drops out. `${SUDO} env VAR=val cmd` is correct for both
  # the root (SUDO="") and sudo (SUDO="sudo") cases.
  info "Installing alloy..."
  if ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout="120" alloy; then
    success "Alloy installed."
  else
    # apt-get install refuses if the system has *any* unrelated broken/unmet
    # deps (e.g. neptune/UGOS ships picom + qemu-block-extra with uninstallable
    # deps). `apt-get download` fetches the .deb without a full-system solve, and
    # `dpkg -i` installs it checking only alloy's own (minimal) deps.
    warn "apt-get install failed — falling back to direct .deb install (bypasses unrelated broken apt state)."
    tmpdeb="$(mktemp -d)"
    ( cd "${tmpdeb}" && ${SUDO} apt-get download -o DPkg::Lock::Timeout="120" alloy ) \
      || { ${SUDO} rm -rf "${tmpdeb}"; fail "apt-get download alloy failed."; }
    ${SUDO} dpkg -i "${tmpdeb}"/alloy_*.deb \
      || { ${SUDO} rm -rf "${tmpdeb}"; fail "dpkg -i alloy failed (alloy has unmet deps of its own)."; }
    ${SUDO} rm -rf "${tmpdeb}"
    success "Alloy installed via direct .deb."
  fi
fi

# ---------------------------------------------------------------------------
# Write the host-agent config (canonical source — edit here, not on the host)
# ---------------------------------------------------------------------------
info "Writing /etc/alloy/config.alloy..."
${SUDO} install -d -m 0755 /etc/alloy
${SUDO} tee /etc/alloy/config.alloy >/dev/null <<'ALLOY_EOF'
// Host-local Alloy agent (push / remote_write model).
//
// Managed by scripts/deploy-alloy.sh in lentago/drosera —
// edit there, re-run the script; do NOT hand-edit on the host.
//
// Metrics: scrapes node_exporter on localhost:9100 → remote_write to Mimir @60s
// (job="node", instance from $ALLOY_INSTANCE).
// Logs: ships this host's systemd journal → Grafana Cloud Loki
// (job="systemd-journal", host from $ALLOY_INSTANCE, cluster="lentago-lab").
// Secrets + instance label come from /etc/default/alloy (0600), never from git.

logging {
  level  = "info"
  format = "logfmt"
}

// ---- metrics ----
prometheus.scrape "node" {
  targets = [
    { __address__ = "127.0.0.1:9100", instance = sys.env("ALLOY_INSTANCE") },
  ]
  forward_to      = [prometheus.relabel.node_trim.receiver]
  // 60s, not 15s (#239): Grafana Cloud bills 1 data point per minute per
  // series and counts anything faster as extra series, so 15s billed ~4x the
  // active node series (~26k billable vs. the 10k included). Dashboards and
  // alerts on node metrics use >= 5m windows, which hold 5+ samples at 60s.
  scrape_interval = "60s"
  job_name        = "node"
}

// Drop node_exporter series no dashboard reads: per-NFS-op client counters,
// per-collector meta-metrics (only useful debugging node_exporter itself),
// and per-disk discard/device-mapper detail. ~1k series fleet-wide freed
// under the 15k Grafana Cloud active-series cap — see issue #138.
prometheus.relabel "node_trim" {
  forward_to = [prometheus.remote_write.cloud.receiver]
  rule {
    source_labels = ["__name__"]
    regex         = "node_nfs_requests_total|node_scrape_collector_success|node_scrape_collector_duration_seconds|node_disk_discard.*|node_disk_device_mapper_info"
    action        = "drop"
  }
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
    cluster = "lentago-lab",
  }
}

// ---- logs: systemd journal → Loki ----
loki.source.journal "host" {
  forward_to    = [loki.write.logs.receiver]
  relabel_rules = loki.relabel.journal.rules
  labels        = { job = "systemd-journal", host = sys.env("ALLOY_INSTANCE") }
  max_age       = "12h"
}

// Keep Loki stream cardinality bounded: only a few low-cardinality labels.
// `unit` is set only for real *.service units (transient run-*/session-*/*.scope
// units are left unlabelled); debug-priority lines are dropped.
loki.relabel "journal" {
  forward_to = []
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
  rule {
    source_labels = ["__journal__systemd_unit"]
    regex         = "(.+\\.service)"
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal_priority"]
    regex         = "7"
    action        = "drop"
  }
}

loki.write "logs" {
  endpoint {
    url = sys.env("GRAFANA_CLOUD_LOGS_URL")
    basic_auth {
      username = sys.env("GRAFANA_CLOUD_LOGS_USER")
      password = sys.env("GRAFANA_CLOUD_LOGS_TOKEN")
    }
  }
  external_labels = {
    cluster = "lentago-lab",
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
GRAFANA_CLOUD_LOGS_URL="${GRAFANA_CLOUD_LOGS_URL}"
GRAFANA_CLOUD_LOGS_USER="${GRAFANA_CLOUD_LOGS_USER}"
GRAFANA_CLOUD_LOGS_TOKEN="${GRAFANA_CLOUD_LOGS_TOKEN}"
ENV_EOF
${SUDO} chown root:root /etc/default/alloy
${SUDO} chmod 0600 /etc/default/alloy

# The alloy service runs as user 'alloy'; it needs the systemd-journal group to
# read the journal for loki.source.journal. Idempotent; takes effect on restart.
if getent group systemd-journal >/dev/null 2>&1; then
  ${SUDO} usermod -aG systemd-journal alloy 2>/dev/null || true
fi

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
  success "Alloy is ready — shipping metrics (Mimir) + journald logs (Loki)."
else
  warn "Alloy ready endpoint did not respond — check 'journalctl -u alloy -n 50'."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Alloy host-agent on '${ALLOY_INSTANCE}': metrics @60s + journald logs.${NC}"
echo -e "${YELLOW} If this host is NEW: remove it from the central prometheus.scrape${NC}"
echo -e "${YELLOW} \"node\" block in alloy/config.alloy (else its metrics double-scrape).${NC}"
echo -e "${GREEN}============================================================${NC}"
