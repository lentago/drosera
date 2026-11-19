#!/usr/bin/env bash
# Offline test for scripts/push-alloy-config.sh (#330): the config it extracts
# from deploy-alloy.sh must be the full file with the trim rules, and it must
# refuse anything that is not one allowlisted host. No ssh, no host touched.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
S=scripts/push-alloy-config.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

# Nothing in this test may reach a real host: put a stub ssh first on PATH for
# the whole run. It records the call and consumes stdin; any call outside the
# one payload check below is a failure (a rejected host must never get here).
stub="$(mktemp -d)"; trap 'rm -rf "$stub"' EXIT
cat > "$stub/ssh" <<'STUB'
#!/bin/bash
cat > "$STUB_OUT"
echo x >> "$STUB_CALLS"
STUB
chmod +x "$stub/ssh"
export STUB_OUT="$stub/payload" STUB_CALLS="$stub/calls" PATH="$stub:$PATH"
: > "$STUB_CALLS"

cfg="$(PUSH_ALLOY_CONFIG_PRINT=1 "$S")"
for want in 'prometheus.scrape "node"' 'prometheus.relabel "node_trim"' 'prometheus.remote_write "cloud"' 'node_cpu_guest_seconds_total' 'loki.write "logs"'; do
  grep -qF "$want" <<<"$cfg" || fail "extracted config lacks: $want"
done
grep -q 'ALLOY_EOF\|GRAFANA_CLOUD_METRICS_TOKEN=' <<<"$cfg" && fail "extract leaked script text"
grep -qF 'sys.env("GRAFANA_CLOUD_METRICS_TOKEN")' <<<"$cfg" || fail "token must stay an env reference"

for bad in "" "pve6" "root@pve" "pve;id" "pve pve2" "../x"; do
  if "$S" "$bad" >/dev/null 2>&1; then fail "accepted bad host '$bad'"; fi
done
[[ ! -s "$STUB_CALLS" ]] || fail "a rejected host reached ssh"
if "$S" pve pve2 >/dev/null 2>&1; then fail "accepted two args"; fi
if "$S" >/dev/null 2>&1; then fail "accepted no args"; fi
# The script that goes to the host must carry the config byte for byte
# (backslashes in the journal regex are easy to mangle), through a stub ssh.
"$S" pve2 >/dev/null
bash -n "$stub/payload" || fail "payload does not parse"
awk "/<<'ALLOY_PUSH_EOF'/{f=1;next} /^ALLOY_PUSH_EOF/{f=0} f" "$stub/payload" | diff - <(PUSH_ALLOY_CONFIG_PRINT=1 "$S") \
  || fail "config in payload differs from the extract"

echo "push-alloy-config-test: ok"
