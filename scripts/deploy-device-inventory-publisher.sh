#!/usr/bin/env bash
set -euo pipefail

# Deploy the device-inventory publisher to the Firewalla box (pi user).
# Runs on the OPERATOR WORKSTATION. Idempotent — safe to re-run.
#
# Part of issue #113 (Phase 1). This script is the ONLY way the publisher lands
# on the box — it is NOT gitops-managed (mirrors the worker-transcript-shipper
# exception: editing the file on `main` does not auto-deploy).
#
# What it does, over SSH to pi@firewalla.local:
#   1. Copies scripts/device-inventory-publisher/publish-device-inventory.sh into
#      ~/.firewalla/run/device-inventory/ (a Firewalla-persistent path).
#   2. Writes a sibling device-inventory.env baking in ALLOY_HOST.
#   3. Installs an hourly cron entry for the pi user.
#   4. Installs a ~/.firewalla/config/post_main.d/ hook that re-installs the cron
#      entry — Firewalla's FireMain can regenerate state, and post_main.d/*.sh is
#      the box's supported persistence mechanism for user customizations.
#
# Usage:
#   ./scripts/deploy-device-inventory-publisher.sh <ALLOY_HOST>
#
#   <ALLOY_HOST>  (required) central Alloy Loki-receiver host the box already
#                 ships Zeek logs to — e.g. 192.168.139.20.
#
# Overridable via env:
#   SSH_TARGET    ssh destination (default: pi@firewalla.local)
#   REMOTE_DIR    install dir on the box (default: ~/.firewalla/run/device-inventory)
#   CRON_MINUTE   minute field for the hourly cron (default: 17)

# ---------------------------------------------------------------------------
# Output helpers (match the other scripts/deploy-*.sh)
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
# Inputs
# ---------------------------------------------------------------------------
ALLOY_HOST="${1:-}"
[[ -n "${ALLOY_HOST}" ]] || fail "Usage: $0 <ALLOY_HOST>  (the central Alloy Loki-receiver host, e.g. 192.168.139.20)"
case "${ALLOY_HOST}" in
  http://*|https://*) fail "Pass just the host (e.g. 192.168.139.20), not a URL — the script builds http://<host>:3100/loki/api/v1/push." ;;
esac

SSH_TARGET="${SSH_TARGET:-pi@firewalla.local}"
REMOTE_DIR="${REMOTE_DIR:-/home/pi/.firewalla/run/device-inventory}"
POST_MAIN_D="/home/pi/.firewalla/config/post_main.d"
CRON_MINUTE="${CRON_MINUTE:-17}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISHER_SRC="${SCRIPT_DIR}/device-inventory-publisher/publish-device-inventory.sh"
[[ -f "${PUBLISHER_SRC}" ]] || fail "Publisher not found at ${PUBLISHER_SRC} — run from a repo checkout."

command -v ssh >/dev/null || fail "ssh is required but not found."
command -v scp >/dev/null || fail "scp is required but not found."

info "Deploying to ${SSH_TARGET}"
info "  ALLOY_HOST  = ${ALLOY_HOST}"
info "  REMOTE_DIR  = ${REMOTE_DIR}"
info "  cron        = ${CRON_MINUTE} * * * * (hourly)"

# ---------------------------------------------------------------------------
# 1. Copy the publisher up to a staging path.
# ---------------------------------------------------------------------------
info "Copying publisher to ${SSH_TARGET}:/tmp/publish-device-inventory.sh ..."
scp -q "${PUBLISHER_SRC}" "${SSH_TARGET}:/tmp/publish-device-inventory.sh" \
  || fail "scp of the publisher failed — is ${SSH_TARGET} reachable over SSH?"

# ---------------------------------------------------------------------------
# 2-4. Install on the box. ALLOY_HOST/REMOTE_DIR/etc are passed through the
# environment (not string-substituted into the script), so the remote heredoc
# stays quoted and quoting-safe.
# ---------------------------------------------------------------------------
info "Installing publisher, env file, cron entry, and post_main.d hook on the box ..."
ssh "${SSH_TARGET}" \
  env ALLOY_HOST="${ALLOY_HOST}" REMOTE_DIR="${REMOTE_DIR}" \
      POST_MAIN_D="${POST_MAIN_D}" CRON_MINUTE="${CRON_MINUTE}" \
  bash -s <<'REMOTE' || fail "Remote install failed."
set -eu

CRON_TAG="# device-inventory-publisher"
CRON_LINE="${CRON_MINUTE} * * * * ${REMOTE_DIR}/publish-device-inventory.sh >> ${REMOTE_DIR}/publish.log 2>&1 ${CRON_TAG}"

# --- install the publisher ---
mkdir -p "${REMOTE_DIR}"
mv /tmp/publish-device-inventory.sh "${REMOTE_DIR}/publish-device-inventory.sh"
chmod 0755 "${REMOTE_DIR}/publish-device-inventory.sh"

# --- env file next to it (holds ALLOY_HOST; sourced by the publisher) ---
cat > "${REMOTE_DIR}/device-inventory.env" <<ENV_EOF
# Managed by deploy-device-inventory-publisher.sh — do not edit by hand.
ALLOY_HOST="${ALLOY_HOST}"
ENV_EOF
chmod 0644 "${REMOTE_DIR}/device-inventory.env"

# --- hourly cron entry for pi (idempotent: drop any prior tagged line) ---
( crontab -l 2>/dev/null | grep -vF "${CRON_TAG}" || true; echo "${CRON_LINE}" ) | crontab -

# --- post_main.d hook: re-install the cron entry after FireMain regenerates ---
mkdir -p "${POST_MAIN_D}"
HOOK="${POST_MAIN_D}/reinstall-device-inventory-cron.sh"
# Unquoted heredoc: ${CRON_TAG}/${CRON_LINE} expand now into a self-contained
# hook; the \${…} refs stay literal so the hook uses its own vars at run time.
cat > "${HOOK}" <<HOOK_EOF
#!/usr/bin/env bash
# Managed by deploy-device-inventory-publisher.sh (homelab-observability, #113).
# Firewalla runs post_main.d/*.sh on FireMain startup; this re-installs the
# hourly device-inventory publisher cron for pi in case FireMain reset crontab.
set -eu
CRON_TAG="${CRON_TAG}"
CRON_LINE="${CRON_LINE}"
( crontab -l 2>/dev/null | grep -vF "\${CRON_TAG}" || true; echo "\${CRON_LINE}" ) | crontab -
HOOK_EOF
chmod 0755 "${HOOK}"

echo "Installed:"
echo "  publisher : ${REMOTE_DIR}/publish-device-inventory.sh"
echo "  env file  : ${REMOTE_DIR}/device-inventory.env"
echo "  hook      : ${HOOK}"
echo "  crontab   :"
crontab -l 2>/dev/null | grep -F "${CRON_TAG}" | sed 's/^/    /'
REMOTE

success "Deployed to ${SSH_TARGET}."
info "Test it now:  ssh ${SSH_TARGET} 'DRY_RUN=1 ${REMOTE_DIR}/publish-device-inventory.sh | head'"
info "First real push happens at minute ${CRON_MINUTE} of the next hour; logs in ${REMOTE_DIR}/publish.log."
