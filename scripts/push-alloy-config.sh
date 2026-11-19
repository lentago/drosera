#!/usr/bin/env bash
set -euo pipefail

# Push the host Alloy config from scripts/deploy-alloy.sh to ONE host (#330).
#
# deploy-alloy.sh re-writes /etc/default/alloy, which holds the push tokens, so
# re-running it just to roll out a relabel change means handling credentials.
# This script does the narrow job instead: it takes the canonical config out of
# deploy-alloy.sh (the single source of truth), and on the host it
#   1. checks it with `alloy fmt`,
#   2. backs up /etc/alloy/config.alloy to config.alloy.pre<UTC timestamp>,
#   3. installs the new file and restarts alloy,
#   4. verifies alloy is active with no error-level journal lines,
# and on any failure restores the backup, restarts alloy and exits non-zero.
# It never reads or writes /etc/default/alloy or any credential.
#
# Usage (from the drosera clone, on the commit you mean to roll out):
#   scripts/push-alloy-config.sh <host>
# <host> is exactly one of: pve pve2 pve3 pve4 pve5 neptune.
#   PVE nodes are reached as `ssh root@pve.local [ssh <node>]`;
#   neptune as `ssh cpitzi@neptune.local` + sudo (no root login there).
#
#   PUSH_ALLOY_CONFIG_PRINT=1  print the extracted config and exit (tests).

HOSTS="pve pve2 pve3 pve4 pve5 neptune"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/deploy-alloy.sh"

extract_config() {
  awk "/<<'ALLOY_EOF'/{f=1;next} /^ALLOY_EOF/{f=0} f" "${SRC}"
}

if [[ "${PUSH_ALLOY_CONFIG_PRINT:-}" == 1 ]]; then
  extract_config
  exit 0
fi

[[ $# -eq 1 ]] || { echo "usage: $0 <${HOSTS// /|}>" >&2; exit 2; }
HOST="$1"
ok=0
for h in ${HOSTS}; do [[ "${HOST}" == "${h}" ]] && ok=1; done
[[ ${ok} -eq 1 ]] || { echo "refusing host '${HOST}': allowed are ${HOSTS}" >&2; exit 2; }

CONFIG="$(extract_config)"
[[ "${CONFIG}" == *'prometheus.relabel "node_trim"'* ]] \
  || { echo "extracted config looks wrong (no node_trim); not pushing" >&2; exit 1; }

# Transport: run a command on the target, stdin passed through.
case "${HOST}" in
  pve)     run() { ssh -o BatchMode=yes root@pve.local "$@"; }; SUDO="none" ;;
  neptune) run() { ssh -o BatchMode=yes cpitzi@neptune.local "$@"; }; SUDO="sudo" ;;
  *)       run() { ssh -o BatchMode=yes root@pve.local ssh -o BatchMode=yes "${HOST}" "$@"; }; SUDO="none" ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REMOTE="$(cat <<'R'
set -u
STAMP="$1"; [ "$2" = sudo ] && S="sudo -n" || S=""
CFG=/etc/alloy/config.alloy
NEW=$(mktemp /tmp/alloy-push.XXXXXX)
trap 'rm -f "$NEW"' EXIT
cat > "$NEW" <<'ALLOY_PUSH_EOF'
@@CONFIG@@
ALLOY_PUSH_EOF
alloy fmt "$NEW" >/dev/null || { echo "alloy fmt rejected the config" >&2; exit 1; }
BAK="$CFG.pre$STAMP"
$S cp -p "$CFG" "$BAK" || { echo "backup failed" >&2; exit 1; }
restore() {
  echo "FAILED: restoring $BAK" >&2
  if $S cp -p "$BAK" "$CFG" && $S systemctl restart alloy && sleep 5 && [ "$($S systemctl is-active alloy)" = active ]; then
    echo "restored: alloy active on the previous config" >&2
  else
    echo "RESTORE FAILED: $CFG may be wrong and alloy may be down; fix by hand (backup: $BAK)" >&2
  fi
  exit 1
}
$S install -m 644 -o root -g root "$NEW" "$CFG" || restore
$S systemctl restart alloy || restore
T0=$(date +%s)
sleep 10
[ "$($S systemctl is-active alloy)" = active ] || restore
if $S journalctl -u alloy --since "@$T0" -p err --no-pager -q | grep -q .; then restore; fi
echo "ok: alloy active, no error lines; backup $BAK"
R
)"

# The config rides inside the script on stdin (`bash -s`), so the remote
# command line is just two plain words and survives the pve -> node hop.
case "${CONFIG}" in *ALLOY_PUSH_EOF*) echo "config contains the heredoc delimiter" >&2; exit 1 ;; esac
PAYLOAD="${REMOTE%%@@CONFIG@@*}${CONFIG}${REMOTE#*@@CONFIG@@}"

echo "[push-alloy-config] ${HOST}: installing config from ${SRC}"
printf '%s\n' "${PAYLOAD}" | run bash -s -- "${STAMP}" "${SUDO}"
