#!/usr/bin/env bash
set -euo pipefail

# Deploy the change-pipeline producer (#266) to LXC 105 (grafana-stack, pve5)
# as a long-running systemd service. Idempotent — safe to re-run; re-running is
# also how you ship a code or config change.
#
# Everything installed comes from this checkout — there is no second copy to
# drift:
#   pipeline-producer/pipeline_producer/  → /opt/drosera-pipeline/pipeline_producer/
#   pipeline-producer/config.json         → /etc/drosera-pipeline/config.json
#   pipeline-producer/systemd/*.service   → /etc/systemd/system/
# Credentials go to /etc/default/drosera-pipeline (0600 root:root).
#
# Credentials (environment):
#   DROSERA_LOKI_TOKEN        Grafana Cloud access-policy token, logs:read only. Required.
#   DROSERA_LOKI_URL          Loki base URL for reads; defaults to GRAFANA_CLOUD_LOGS_URL
#   DROSERA_LOKI_USER         Loki user (numeric instance ID); defaults to GRAFANA_CLOUD_LOGS_USER
#   GRAFANA_CLOUD_LOGS_URL    Loki push endpoint  } the collectors' logs:write token; read from
#   GRAFANA_CLOUD_LOGS_USER   Loki username       } /opt/homelab-observability/.env when unset
#   GRAFANA_CLOUD_LOGS_TOKEN  logs:write token    }
# Re-running with none of these set keeps the existing /etc/default/drosera-pipeline.
#
# Usage — from a drosera checkout ON the host, as a sudo-capable user:
#   DROSERA_LOKI_TOKEN=glc_… ./pipeline-producer/deploy.sh

# ── Helpers ──
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${YELLOW}[drosera-pipeline]${NC} $*"; }
success() { echo -e "${GREEN}[drosera-pipeline]${NC} OK: $*"; }
fail()    { echo -e "${RED}[drosera-pipeline]${NC} FAIL: $*" >&2; exit 1; }

SERVICE_USER="drosera-pipeline"
APP_DIR="/opt/drosera-pipeline"
CONF_DIR="/etc/drosera-pipeline"
ENV_FILE="/etc/default/drosera-pipeline"
UNIT_DIR="/etc/systemd/system"
ALLOY_ENV="/opt/homelab-observability/.env"
SECRET_VARS=(DROSERA_LOKI_URL DROSERA_LOKI_USER DROSERA_LOKI_TOKEN
             GRAFANA_CLOUD_LOGS_URL GRAFANA_CLOUD_LOGS_USER GRAFANA_CLOUD_LOGS_TOKEN)

# ── Preconditions ──
if [[ ${EUID} -eq 0 ]]; then SUDO=""; else command -v sudo >/dev/null || fail "Run as root, or install sudo."; SUDO="sudo"; fi
command -v systemctl >/dev/null || fail "systemd is required."

# python3 ≥ 3.10 is the only runtime dependency (stdlib only; LXC 105 has
# 3.10.4). If the guest lacks it, codify the package in kalmia.
[[ -x /usr/bin/python3 ]] || fail "/usr/bin/python3 not found — add python3 to LXC 105's kalmia definition."
/usr/bin/python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
  || fail "python3 is older than 3.10 ($(/usr/bin/python3 --version 2>&1))."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SRC="${SCRIPT_DIR}/pipeline_producer"
CFG_SRC="${SCRIPT_DIR}/config.json"
[[ -f "${PKG_SRC}/__main__.py" && -f "${CFG_SRC}" ]] || fail "Run from a drosera checkout (missing ${PKG_SRC} or ${CFG_SRC})."

# Validate the config before touching the host (no secrets, no network).
PYTHONPATH="${SCRIPT_DIR}" /usr/bin/python3 -B -m pipeline_producer --config "${CFG_SRC}" --check-config \
  || fail "config.json failed validation."
PORT="$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("port", 8611))' "${CFG_SRC}")"

# ── Credentials ──
# Pull one KEY=value out of an env file (no sourcing: it may not be shell-safe).
env_value() {
  ${SUDO} sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$1=//p" "$2" 2>/dev/null | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

any_given=""
for v in "${SECRET_VARS[@]}"; do [[ -n "${!v:-}" ]] && any_given=1; done

if [[ -z "${any_given}" && -f "${ENV_FILE}" ]]; then
  info "No credentials in the environment — keeping the existing ${ENV_FILE}."
  [[ -n "$(env_value DROSERA_LOKI_TOKEN "${ENV_FILE}")" ]] \
    || fail "${ENV_FILE} has no DROSERA_LOKI_TOKEN — re-run with DROSERA_LOKI_TOKEN=glc_… (logs:read)."
  WRITE_ENV=""
else
  [[ -n "${DROSERA_LOKI_TOKEN:-}" ]] \
    || fail "DROSERA_LOKI_TOKEN (a logs:read access-policy token) is not set — the producer can't read Loki without it."
  if [[ -z "${GRAFANA_CLOUD_LOGS_TOKEN:-}" ]] && ${SUDO} test -f "${ALLOY_ENV}"; then
    info "Taking the logs:write credentials from ${ALLOY_ENV}."
    GRAFANA_CLOUD_LOGS_URL="${GRAFANA_CLOUD_LOGS_URL:-$(env_value GRAFANA_CLOUD_LOGS_URL "${ALLOY_ENV}")}"
    GRAFANA_CLOUD_LOGS_USER="${GRAFANA_CLOUD_LOGS_USER:-$(env_value GRAFANA_CLOUD_LOGS_USER "${ALLOY_ENV}")}"
    GRAFANA_CLOUD_LOGS_TOKEN="$(env_value GRAFANA_CLOUD_LOGS_TOKEN "${ALLOY_ENV}")"
  fi
  DROSERA_LOKI_URL="${DROSERA_LOKI_URL:-${GRAFANA_CLOUD_LOGS_URL:-}}"
  DROSERA_LOKI_USER="${DROSERA_LOKI_USER:-${GRAFANA_CLOUD_LOGS_USER:-}}"
  for v in "${SECRET_VARS[@]}"; do
    [[ -n "${!v:-}" ]] || fail "Required value ${v} is not set."
  done
  for v in DROSERA_LOKI_URL GRAFANA_CLOUD_LOGS_URL; do
    case "${!v}" in
      https://*) ;;
      *) fail "${v} is '${!v}', not an https URL — the var didn't expand." ;;
    esac
  done
  case "${DROSERA_LOKI_USER}${DROSERA_LOKI_TOKEN}${GRAFANA_CLOUD_LOGS_USER}${GRAFANA_CLOUD_LOGS_TOKEN}" in
    *'$'*|*'"'*) fail "A credential contains a literal '\$' or '\"' — env vars weren't expanded." ;;
  esac
  WRITE_ENV=1
fi

# ── Service user ──
if id "${SERVICE_USER}" >/dev/null 2>&1; then
  success "System user ${SERVICE_USER} already exists."
else
  info "Creating system user ${SERVICE_USER}..."
  ${SUDO} useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

# ── Code + config ──
info "Installing ${APP_DIR}/pipeline_producer and ${CONF_DIR}/config.json..."
${SUDO} rm -rf "${APP_DIR}/pipeline_producer"   # drop modules removed upstream
${SUDO} install -d -m 0755 "${APP_DIR}/pipeline_producer" "${CONF_DIR}"
${SUDO} install -m 0644 "${PKG_SRC}"/*.py "${APP_DIR}/pipeline_producer/"
${SUDO} install -m 0644 "${CFG_SRC}" "${CONF_DIR}/config.json"

# ── Credentials file (0600 root:root; systemd reads it as root) ──
if [[ -n "${WRITE_ENV}" ]]; then
  info "Writing ${ENV_FILE} (0600, holds the read and write tokens)..."
  ${SUDO} install -m 0600 -o root -g root /dev/null "${ENV_FILE}"
  ${SUDO} tee "${ENV_FILE}" >/dev/null <<ENV_EOF
# Managed by pipeline-producer/deploy.sh — do not edit by hand.
DROSERA_LOKI_URL="${DROSERA_LOKI_URL}"
DROSERA_LOKI_USER="${DROSERA_LOKI_USER}"
DROSERA_LOKI_TOKEN="${DROSERA_LOKI_TOKEN}"
GRAFANA_CLOUD_LOGS_URL="${GRAFANA_CLOUD_LOGS_URL}"
GRAFANA_CLOUD_LOGS_USER="${GRAFANA_CLOUD_LOGS_USER}"
GRAFANA_CLOUD_LOGS_TOKEN="${GRAFANA_CLOUD_LOGS_TOKEN}"
ENV_EOF
fi
# Whichever file is in place, never start without the read token.
[[ -n "$(env_value DROSERA_LOKI_TOKEN "${ENV_FILE}")" ]] \
  || fail "${ENV_FILE} has no DROSERA_LOKI_TOKEN — re-run with DROSERA_LOKI_TOKEN=glc_… (logs:read)."

# ── systemd unit ──
info "Installing drosera-pipeline.service..."
${SUDO} install -m 0644 "${SCRIPT_DIR}/systemd/drosera-pipeline.service" "${UNIT_DIR}/drosera-pipeline.service"
if command -v systemd-analyze >/dev/null; then
  ${SUDO} systemd-analyze verify "${UNIT_DIR}/drosera-pipeline.service" \
    || info "WARN: systemd-analyze reported problems (above) — continuing; the health check below is the real test."
fi
${SUDO} systemctl daemon-reload
${SUDO} systemctl reset-failed drosera-pipeline.service 2>/dev/null || true
${SUDO} systemctl enable drosera-pipeline.service >/dev/null 2>&1 || fail "Could not enable drosera-pipeline.service."
${SUDO} systemctl restart drosera-pipeline.service   # pick up new code, config or credentials

# ── Health: /healthz answers, then the first document (one 24h read) ──
info "Waiting for the first document on :${PORT}..."
for _ in $(seq 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/pipeline.json" || true)"
  [[ "${code}" == "200" ]] && break
  ${SUDO} systemctl is-active --quiet drosera-pipeline.service \
    || fail "drosera-pipeline.service is not running — check 'journalctl -u drosera-pipeline -n 50'."
  sleep 2
done
[[ "${code}" == "200" ]] \
  || fail "No document after 120 s (last HTTP ${code}) — check 'journalctl -u drosera-pipeline -n 50' (a 401 means the read token lacks logs:read)."
summary="$(curl -s "http://127.0.0.1:${PORT}/pipeline.json" \
  | /usr/bin/python3 -c 'import json, sys; d = json.load(sys.stdin); print(len(d["repos"]), "repo(s), generated", d["generated_at"])')"
success "drosera-pipeline is serving: ${summary}"
info "Watch it: journalctl -u drosera-pipeline -f   ·   curl -s http://127.0.0.1:${PORT}/pipeline.json"
