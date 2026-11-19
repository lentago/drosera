#!/usr/bin/env bash
# Offline test for scripts/push-alloy-config.sh (#330): the config it extracts
# from deploy-alloy.sh must be the full file with the trim rules, and it must
# refuse anything that is not one allowlisted host. No ssh, no host touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
S=scripts/push-alloy-config.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

cfg="$(PUSH_ALLOY_CONFIG_PRINT=1 "$S")"
for want in 'prometheus.scrape "node"' 'prometheus.relabel "node_trim"' 'prometheus.remote_write "cloud"' 'node_cpu_guest_seconds_total' 'loki.write "logs"'; do
  grep -qF "$want" <<<"$cfg" || fail "extracted config lacks: $want"
done
grep -q 'ALLOY_EOF\|GRAFANA_CLOUD_METRICS_TOKEN=' <<<"$cfg" && fail "extract leaked script text"
grep -qF 'sys.env("GRAFANA_CLOUD_METRICS_TOKEN")' <<<"$cfg" || fail "token must stay an env reference"

for bad in "" "pve6" "root@pve" "pve;id" "pve pve2" "../x"; do
  if "$S" "$bad" >/dev/null 2>&1; then fail "accepted bad host '$bad'"; fi
done
if "$S" pve pve2 >/dev/null 2>&1; then fail "accepted two args"; fi
if "$S" >/dev/null 2>&1; then fail "accepted no args"; fi
# The script that goes to the host must carry the config byte for byte
# (backslashes in the journal regex are easy to mangle), through a stub ssh.
stub="$(mktemp -d)"; trap 'rm -rf "$stub"' EXIT
# shellcheck disable=SC2016
printf '#!/bin/bash\ncat > "$STUB_OUT"\n' > "$stub/ssh"; chmod +x "$stub/ssh"
STUB_OUT="$stub/payload" PATH="$stub:$PATH" "$S" pve2 >/dev/null
bash -n "$stub/payload" || fail "payload does not parse"
awk "/<<'ALLOY_PUSH_EOF'/{f=1;next} /^ALLOY_PUSH_EOF/{f=0} f" "$stub/payload" | diff - <(PUSH_ALLOY_CONFIG_PRINT=1 "$S") \
  || fail "config in payload differs from the extract"

echo "push-alloy-config-test: ok"
