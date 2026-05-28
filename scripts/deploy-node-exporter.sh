#!/usr/bin/env bash
set -euo pipefail

# node_exporter deployment script for Proxmox VE hosts (Debian 12)
# Idempotent — safe to re-run.
#
# Check https://github.com/prometheus/node_exporter/releases for the latest version.
NODE_EXPORTER_VERSION="1.9.0"

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'  # No Color

info()    { echo -e "${YELLOW}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Privilege escalation — use sudo only if we're not already root.
# Proxmox host root shells routinely don't have sudo installed at all.
# ---------------------------------------------------------------------------
if [[ ${EUID} -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
  command -v sudo >/dev/null || fail "sudo is required when running as a non-root user, but was not found in PATH."
fi

# ---------------------------------------------------------------------------
# Step 1 — Detect architecture
# ---------------------------------------------------------------------------
info "Detecting system architecture..."
MACHINE=$(uname -m)
case "${MACHINE}" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  armv7l)  ARCH="armv7" ;;
  *) fail "Unsupported architecture: ${MACHINE}. Only x86_64, aarch64, and armv7l are supported." ;;
esac
success "Architecture: ${MACHINE} → ${ARCH}"

# ---------------------------------------------------------------------------
# Step 2 — Check if already installed at the correct version
# ---------------------------------------------------------------------------
info "Checking for existing node_exporter installation..."
if [[ -x /usr/local/bin/node_exporter ]]; then
  INSTALLED_VERSION=$(/usr/local/bin/node_exporter --version 2>&1 | head -1 | awk '{print $3}')
  if [[ "${INSTALLED_VERSION}" == "${NODE_EXPORTER_VERSION}" ]]; then
    success "node_exporter ${NODE_EXPORTER_VERSION} is already installed — skipping download."
    SKIP_INSTALL=true
  else
    info "Found node_exporter ${INSTALLED_VERSION}, upgrading to ${NODE_EXPORTER_VERSION}."
    SKIP_INSTALL=false
  fi
else
  info "node_exporter not found — installing."
  SKIP_INSTALL=false
fi

# ---------------------------------------------------------------------------
# Step 3 — Download and install binary
# ---------------------------------------------------------------------------
if [[ "${SKIP_INSTALL}" == "false" ]]; then
  TARBALL="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
  DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${TARBALL}"

  info "Downloading ${TARBALL}..."
  curl -fsSL --output "/tmp/${TARBALL}" "${DOWNLOAD_URL}" \
    || fail "Failed to download node_exporter from ${DOWNLOAD_URL}"

  info "Extracting archive..."
  tar -xzf "/tmp/${TARBALL}" -C /tmp \
    || fail "Failed to extract ${TARBALL}"

  EXTRACTED_DIR="/tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}"

  info "Installing binary to /usr/local/bin/node_exporter..."
  ${SUDO:+sudo }install -m 0755 "${EXTRACTED_DIR}/node_exporter" /usr/local/bin/node_exporter \
    || fail "Failed to install node_exporter binary"

  info "Cleaning up temporary files..."
  rm -f "/tmp/${TARBALL}"
  rm -rf "${EXTRACTED_DIR}"

  success "node_exporter ${NODE_EXPORTER_VERSION} installed."
fi

# ---------------------------------------------------------------------------
# Step 4 — Create dedicated system user
# ---------------------------------------------------------------------------
info "Checking for node_exporter system user..."
if id -u node_exporter &>/dev/null; then
  success "System user 'node_exporter' already exists — skipping."
else
  info "Creating system user 'node_exporter'..."
  ${SUDO:+sudo }useradd --no-create-home --shell /bin/false --system node_exporter \
    || fail "Failed to create node_exporter system user"
  success "System user 'node_exporter' created."
fi

# ---------------------------------------------------------------------------
# Step 5 — Write systemd unit file
# ---------------------------------------------------------------------------
info "Writing /etc/systemd/system/node_exporter.service..."
${SUDO:+sudo }tee /etc/systemd/system/node_exporter.service > /dev/null <<'UNIT_EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|run)($|/)" \
  --collector.netclass.ignored-devices="^(veth|docker|br-).*" \
  --web.listen-address=":9100"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
success "Systemd unit file written."

# ---------------------------------------------------------------------------
# Step 6 — Enable and start service
# ---------------------------------------------------------------------------
info "Reloading systemd daemon..."
${SUDO:+sudo }systemctl daemon-reload \
  || fail "systemctl daemon-reload failed"

info "Enabling and starting node_exporter..."
${SUDO:+sudo }systemctl enable --now node_exporter \
  || fail "Failed to enable/start node_exporter service"

success "node_exporter service enabled and started."

# ---------------------------------------------------------------------------
# Step 7 — Verify
# ---------------------------------------------------------------------------
info "Waiting for node_exporter to start..."
if ! ${SUDO:+sudo }systemctl is-active --quiet node_exporter; then
  sleep 1
  ${SUDO:+sudo }systemctl is-active --quiet node_exporter \
    || fail "node_exporter service is not active. Run 'journalctl -u node_exporter -n 50' to diagnose."
fi
success "Service is active."

info "Checking metrics endpoint..."
# node_exporter needs a few seconds after start before its collectors emit
# node_* series. Poll for up to 15s.
METRICS=""
for _ in $(seq 1 15); do
  METRICS=$(curl -fsSL http://localhost:9100/metrics 2>/dev/null || true)
  echo "${METRICS}" | grep -q "node_cpu_seconds_total" && break
  sleep 1
done

if echo "${METRICS}" | grep -q "node_cpu_seconds_total"; then
  success "Metrics endpoint is healthy — node_cpu_seconds_total confirmed."
else
  fail "Metrics endpoint reachable but node_cpu_seconds_total never appeared after 15s — check service logs."
fi

if echo "${METRICS}" | grep -q "node_zfs_"; then
  success "ZFS metrics are available — node_zfs_* series detected."
else
  info "ZFS collector found no pools (node_zfs_* absent). This is expected on hosts without ZFS."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} node_exporter v${NODE_EXPORTER_VERSION} is running on port 9100.${NC}"
echo -e "${GREEN} Add this host's IP to your Prometheus scrape targets.${NC}"
echo -e "${GREEN}   Metrics: http://$(hostname -I | awk '{print $1}'):9100/metrics${NC}"
echo -e "${GREEN}============================================================${NC}"
