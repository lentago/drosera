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
#   3. Verifies the betula-owned schedule is in user_crontab, then removes the
#      legacy schedule this script used to install: the tagged
#      `# device-inventory-publisher` line in pi's crontab and the
#      post_main.d/reinstall-device-inventory-cron.sh hook.
#   4. Verifies exactly one live crontab line runs the publisher.
#
# The hourly schedule is NOT installed here (#151). It lives in betula's
# cron/user_crontab, deployed by betula's gitops loop (lentago/betula#114):
# Firewalla's update_crontab.sh rebuilds pi's crontab from the system crontab,
# config/crontab/*, and config/user_crontab, so a line added with `crontab -`
# was dropped on every rebuild (feed dead 2026-07-04→13 and 2026-07-17→10-05),
# and the post_main.d hook — run only on FireMain startup — never restored it.
# The step-3 check fails the deploy if betula's line is missing — before any
# legacy removal — rather than leaving a publisher with no schedule.
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
USER_CRONTAB="/home/pi/.firewalla/config/user_crontab"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISHER_SRC="${SCRIPT_DIR}/device-inventory-publisher/publish-device-inventory.sh"
[[ -f "${PUBLISHER_SRC}" ]] || fail "Publisher not found at ${PUBLISHER_SRC} — run from a repo checkout."

command -v ssh >/dev/null || fail "ssh is required but not found."
command -v scp >/dev/null || fail "scp is required but not found."

info "Deploying to ${SSH_TARGET}"
info "  ALLOY_HOST  = ${ALLOY_HOST}"
info "  REMOTE_DIR  = ${REMOTE_DIR}"
info "  schedule    = betula cron/user_crontab (verified, not installed)"

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
info "Installing publisher and env file, retiring the legacy cron entry + hook ..."
ssh "${SSH_TARGET}" \
  env ALLOY_HOST="${ALLOY_HOST}" REMOTE_DIR="${REMOTE_DIR}" \
      POST_MAIN_D="${POST_MAIN_D}" USER_CRONTAB="${USER_CRONTAB}" \
  bash -s <<'REMOTE' || fail "Remote install failed — see the output above."
set -eu

PUBLISHER="${REMOTE_DIR}/publish-device-inventory.sh"
LEGACY_TAG="# device-inventory-publisher"

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

# --- verify the betula-owned schedule exists BEFORE retiring the legacy one ---
# Checked first so a deploy that runs ahead of betula#114 fails with the legacy
# line still in place, instead of leaving the publisher with no schedule.
if ! grep -v '^[[:space:]]*#' "${USER_CRONTAB}" 2>/dev/null | grep -qF "${PUBLISHER}"; then
  echo "ERROR: no schedule for ${PUBLISHER} in ${USER_CRONTAB}." >&2
  echo "       The hourly schedule lives in lentago/betula cron/user_crontab" >&2
  echo "       (betula#114); merge/deploy that first. The legacy schedule was" >&2
  echo "       left untouched." >&2
  exit 1
fi

# --- retire the legacy schedule (#151) ---
# The tagged line is the one this script used to add with `crontab -`. Only
# rewrite the crontab when it is actually there; every other line is kept.
if crontab -l 2>/dev/null | grep -qF "${LEGACY_TAG}"; then
  ( crontab -l 2>/dev/null | grep -vF "${LEGACY_TAG}" ) | crontab -
  echo "Removed legacy tagged cron line."
fi
rm -f "${POST_MAIN_D}/reinstall-device-inventory-cron.sh"

# --- verify exactly one live line ---
LIVE_LINES=$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -cF "${PUBLISHER}" || true)
if [ "${LIVE_LINES}" != "1" ]; then
  echo "ERROR: expected exactly 1 live crontab line for the publisher, found ${LIVE_LINES}." >&2
  echo "       user_crontab has it; run /home/pi/firewalla/scripts/update_crontab.sh" >&2
  echo "       as pi to merge it (never a raw 'crontab user_crontab' — betula#67)." >&2
  exit 1
fi

echo "Installed:"
echo "  publisher : ${PUBLISHER}"
echo "  env file  : ${REMOTE_DIR}/device-inventory.env"
echo "  schedule  : (from ${USER_CRONTAB})"
crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F "${PUBLISHER}" | sed 's/^/    /'
REMOTE

success "Deployed to ${SSH_TARGET}."
info "Test it now:  ssh ${SSH_TARGET} 'DRY_RUN=1 ${REMOTE_DIR}/publish-device-inventory.sh | head'"
info "Next push follows the betula schedule (minute 17 hourly); logs in ${REMOTE_DIR}/publish.log."
