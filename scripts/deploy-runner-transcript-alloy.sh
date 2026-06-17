#!/usr/bin/env bash
set -euo pipefail

# Deploy the worker-local "fleet transcript" Alloy agent to a claude-runner
# worker (claude-runner / claude-runner-2 on pve4). Idempotent — safe to re-run.
#
# This tails Claude Code's live session transcripts and ships a scrubbed,
# human-readable reasoning stream to Grafana Cloud Loki (job="claude_transcript"),
# rendered live on the Claude Runner Fleet dashboard. See issue #71 and the
# canonical config alloy/runner-transcript.alloy (read verbatim by this script —
# there is no second embedded copy to drift).
#
# It installs Alloy as a DEDICATED `alloy-transcript.service` running as the
# `claude` user (the session files are 0600 claude:claude — the stock root/alloy
# service cannot read them) on its own HTTP port, so it never collides with a
# future stock `alloy.service` (e.g. node_exporter push via deploy-alloy.sh).
#
# Required environment (the logs half of the central .envrc):
#   GRAFANA_CLOUD_LOGS_URL    Loki push endpoint
#   GRAFANA_CLOUD_LOGS_USER   Loki username (numeric)
#   GRAFANA_CLOUD_LOGS_TOKEN  Grafana Cloud push token (logs:write scope)
#
# Worker label (arg 1, or $ALLOY_INSTANCE; defaults to `hostname -s`):
#   the value used for the worker="" label — use the worker's name as the fleet
#   knows it (claude-runner, claude-runner-2).
#
# Usage — run from a checkout ON the worker, as a sudo-capable user:
#   source .envrc      # exports GRAFANA_CLOUD_LOGS_*
#   ./scripts/deploy-runner-transcript-alloy.sh <worker-label>
#
# One-liner from a control host (private repo → the worker already has git auth):
#   ssh claude-runner 'git clone --depth 1 \
#     https://github.com/PitziLabs/homelab-observability /tmp/ho && cd /tmp/ho && \
#     sudo env GRAFANA_CLOUD_LOGS_URL=… GRAFANA_CLOUD_LOGS_USER=… \
#     GRAFANA_CLOUD_LOGS_TOKEN=… ALLOY_INSTANCE=claude-runner \
#     ./scripts/deploy-runner-transcript-alloy.sh; rm -rf /tmp/ho'

# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# Privilege — use sudo only if not already root.
if [[ ${EUID} -eq 0 ]]; then SUDO=""; else command -v sudo >/dev/null || fail "Run as root, or install sudo."; SUDO="sudo"; fi

# The user the transcript service runs as (owner of the session files).
RUN_USER="${RUNNER_USER:-claude}"
id "${RUN_USER}" >/dev/null 2>&1 || fail "User '${RUN_USER}' does not exist on this host — is this a claude-runner worker?"

# Worker label.
ALLOY_INSTANCE="${ALLOY_INSTANCE:-${1:-$(hostname -s)}}"
[[ -n "${ALLOY_INSTANCE}" ]] || fail "ALLOY_INSTANCE is empty — pass the worker label as arg 1."
info "Worker label: ${ALLOY_INSTANCE}"

# Locate the canonical config next to this script (single source of truth).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_SRC="${SCRIPT_DIR}/../alloy/runner-transcript.alloy"
[[ -f "${CFG_SRC}" ]] || fail "Canonical config not found at ${CFG_SRC} — run from a repo checkout."

# Validate creds are present and actually expanded (non-secret URL is safe to echo).
for v in GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_LOGS_USER GRAFANA_CLOUD_LOGS_TOKEN; do
  [[ -n "${!v:-}" ]] || fail "Required env var ${v} is not set — 'source .envrc' first."
done
case "${GRAFANA_CLOUD_LOGS_URL}" in
  https://*) ;;
  *) fail "GRAFANA_CLOUD_LOGS_URL is '${GRAFANA_CLOUD_LOGS_URL}', not an https URL — the var didn't expand." ;;
esac
case "${GRAFANA_CLOUD_LOGS_USER}${GRAFANA_CLOUD_LOGS_TOKEN}" in
  *'$'*) fail "A Grafana Cloud credential contains a literal '\$' — env vars weren't expanded." ;;
esac

# ---------------------------------------------------------------------------
# Install Alloy from the Grafana apt repo (idempotent; shared binary).
# ---------------------------------------------------------------------------
if command -v alloy >/dev/null 2>&1; then
  success "Alloy already installed ($(alloy --version 2>/dev/null | head -1 || echo present)) — skipping install."
else
  command -v curl >/dev/null || fail "curl is required but not installed."
  command -v gpg  >/dev/null || ${SUDO} apt-get install -y gnupg || fail "Could not install gnupg."
  info "Adding the Grafana apt repository..."
  ${SUDO} install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | ${SUDO} gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg \
    || fail "Failed to fetch/install the Grafana GPG key."
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | ${SUDO} tee /etc/apt/sources.list.d/grafana.list >/dev/null
  info "Refreshing the Grafana apt repo index..."
  ${SUDO} apt-get update \
    -o Dir::Etc::sourcelist="sources.list.d/grafana.list" \
    -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" -o DPkg::Lock::Timeout="120" \
    || fail "Failed to refresh the Grafana apt repo index."
  info "Installing alloy..."
  if ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout="120" alloy; then
    success "Alloy installed."
  else
    warn "apt-get install failed — falling back to direct .deb install."
    tmpdeb="$(mktemp -d)"
    ( cd "${tmpdeb}" && ${SUDO} apt-get download -o DPkg::Lock::Timeout="120" alloy ) \
      || { ${SUDO} rm -rf "${tmpdeb}"; fail "apt-get download alloy failed."; }
    ${SUDO} dpkg -i "${tmpdeb}"/alloy_*.deb || { ${SUDO} rm -rf "${tmpdeb}"; fail "dpkg -i alloy failed."; }
    ${SUDO} rm -rf "${tmpdeb}"
    success "Alloy installed via direct .deb."
  fi
fi
# The stock package enables an `alloy.service` we do NOT use here — leave it
# stopped/disabled so only our dedicated unit runs.
${SUDO} systemctl disable --now alloy.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Install the canonical config (edit alloy/runner-transcript.alloy, not the host).
# ---------------------------------------------------------------------------
info "Installing /etc/alloy-transcript/config.alloy from ${CFG_SRC}..."
${SUDO} install -d -m 0755 /etc/alloy-transcript
${SUDO} install -m 0644 "${CFG_SRC}" /etc/alloy-transcript/config.alloy

# State dir (positions DB) must be writable by the run user.
${SUDO} install -d -o "${RUN_USER}" -g "${RUN_USER}" -m 0750 /var/lib/alloy-transcript

# ---------------------------------------------------------------------------
# Secrets + worker label (0600, root:RUN_USER so the service user can read it).
# ---------------------------------------------------------------------------
info "Writing /etc/default/alloy-transcript (0640, holds the push token)..."
${SUDO} tee /etc/default/alloy-transcript >/dev/null <<ENV_EOF
# Managed by scripts/deploy-runner-transcript-alloy.sh — do not edit by hand.
ALLOY_INSTANCE="${ALLOY_INSTANCE}"
GRAFANA_CLOUD_LOGS_URL="${GRAFANA_CLOUD_LOGS_URL}"
GRAFANA_CLOUD_LOGS_USER="${GRAFANA_CLOUD_LOGS_USER}"
GRAFANA_CLOUD_LOGS_TOKEN="${GRAFANA_CLOUD_LOGS_TOKEN}"
ENV_EOF
${SUDO} chown "root:${RUN_USER}" /etc/default/alloy-transcript
${SUDO} chmod 0640 /etc/default/alloy-transcript

# ---------------------------------------------------------------------------
# Dedicated systemd unit, running as the session-file owner on its own port.
# ---------------------------------------------------------------------------
info "Writing /etc/systemd/system/alloy-transcript.service..."
${SUDO} tee /etc/systemd/system/alloy-transcript.service >/dev/null <<UNIT_EOF
[Unit]
Description=Grafana Alloy — bullpen fleet transcript shipper (worker-local, runs as ${RUN_USER})
Documentation=https://github.com/PitziLabs/homelab-observability/issues/71
After=network-online.target
Wants=network-online.target

[Service]
User=${RUN_USER}
Group=${RUN_USER}
EnvironmentFile=/etc/default/alloy-transcript
ExecStart=/usr/bin/alloy run /etc/alloy-transcript/config.alloy \\
  --storage.path=/var/lib/alloy-transcript \\
  --server.http.listen-addr=127.0.0.1:12346
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF

info "Validating the installed config with 'alloy fmt'..."
${SUDO} alloy fmt /etc/alloy-transcript/config.alloy >/dev/null || fail "alloy fmt rejected the installed config."

${SUDO} systemctl daemon-reload
${SUDO} systemctl enable alloy-transcript.service >/dev/null 2>&1 || true
${SUDO} systemctl restart alloy-transcript.service \
  || fail "alloy-transcript failed to start — check 'journalctl -u alloy-transcript -n 50'."
sleep 2
${SUDO} systemctl is-active --quiet alloy-transcript.service \
  || fail "alloy-transcript is not active after restart — check 'journalctl -u alloy-transcript -n 50'."
success "alloy-transcript.service is running as ${RUN_USER}, shipping job=\"claude_transcript\" worker=\"${ALLOY_INSTANCE}\"."
info  "Watch it live: journalctl -u alloy-transcript -f   (or the fleet dashboard's 'Fleet stream of consciousness' panel)"
