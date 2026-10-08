#!/usr/bin/env bash
# Install (or update) the sites live probe on this host. Idempotent: re-run it
# after any change under sites-live/ or clients/loki_push.py.
#
#   sudo GRAFANA_CLOUD_LOGS_URL=https://logs-prod-NNN.grafana.net \
#        GRAFANA_CLOUD_LOGS_USER=123456 GRAFANA_CLOUD_LOGS_TOKEN=glc_... \
#        sites-live/deploy.sh
#
# The credentials are written to a 0600 /etc/default/sites-live. If that file
# already exists and the variables are unset, it is left alone, so a plain
# re-run only refreshes the code and units.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC
readonly DEST="/opt/sites-live"
readonly ENV_FILE="/etc/default/sites-live"
readonly UNIT_DIR="/etc/systemd/system"

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' ||
  { echo "python3 >= 3.10 required" >&2; exit 1; }

install -d -m 0755 "${DEST}" "${DEST}/sites_live"
install -m 0644 "${SRC}"/sites_live/*.py "${DEST}/sites_live/"
install -m 0644 "${SRC}/sites.json" "${DEST}/sites.json"
# Vendored, so the probe and the clients/ emitter cannot drift apart.
install -m 0644 "${SRC}/../clients/loki_push.py" "${DEST}/loki_push.py"

if [[ -n "${GRAFANA_CLOUD_LOGS_URL:-}" && -n "${GRAFANA_CLOUD_LOGS_USER:-}" && -n "${GRAFANA_CLOUD_LOGS_TOKEN:-}" ]]; then
  umask 077
  tmp=$(mktemp "${ENV_FILE}.XXXXXX")
  printf 'GRAFANA_CLOUD_LOGS_URL=%s\nGRAFANA_CLOUD_LOGS_USER=%s\nGRAFANA_CLOUD_LOGS_TOKEN=%s\n' \
    "${GRAFANA_CLOUD_LOGS_URL}" "${GRAFANA_CLOUD_LOGS_USER}" "${GRAFANA_CLOUD_LOGS_TOKEN}" >"${tmp}"
  chmod 0600 "${tmp}"
  mv "${tmp}" "${ENV_FILE}"
elif [[ ! -f "${ENV_FILE}" ]]; then
  echo "no ${ENV_FILE} and GRAFANA_CLOUD_LOGS_URL/USER/TOKEN not set" >&2
  exit 1
fi

install -m 0644 "${SRC}"/systemd/sites-live.service "${SRC}"/systemd/sites-live.timer "${UNIT_DIR}/"
systemctl daemon-reload
systemctl enable --now sites-live.timer
systemctl restart sites-live.timer
echo "installed; first tick: systemctl start sites-live.service && journalctl -u sites-live -n 20"
