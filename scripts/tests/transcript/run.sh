#!/usr/bin/env bash
# Run alloy/runner-transcript.alloy, as deployed, in Alloy against a throwaway
# Loki and check what it ships (#305). The config is the file the workers run;
# only the Loki endpoint comes from the environment, as on a worker.
#
#   scripts/tests/transcript/run.sh        LOKI_URL (default http://127.0.0.1:3100)
#
# fixture.py builds a worker home tree, which is mounted at /home/claude. Late
# lines are appended to the native Gemini and Codex files after Alloy has
# found their links, so the test also proves tailing through a symlink. Needs
# docker and a Loki that has seen no claude_transcript lines in the last hour.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
LOKI_URL=${LOKI_URL:-http://127.0.0.1:3100}
ALLOY_IMAGE=${ALLOY_IMAGE:-grafana/alloy:v1.21.3} # the workers' version
# The container reaches the host's Loki port through the host gateway.
push_url="http://host.docker.internal:${LOKI_URL##*:}/loki/api/v1/push"

root=$(mktemp -d)
name="transcript-test-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; rm -rf "$root"; }
trap cleanup EXIT

python3 "$here/fixture.py" write "$root"
chmod -R a+rX "$root"

docker run -d --name "$name" --hostname transcript-test \
  --add-host=host.docker.internal:host-gateway \
  -v "$root:/home/claude:ro" \
  -v "$repo/alloy/runner-transcript.alloy:/etc/alloy-transcript/config.alloy:ro" \
  -e GRAFANA_CLOUD_LOGS_URL="$push_url" \
  -e GRAFANA_CLOUD_LOGS_USER=test -e GRAFANA_CLOUD_LOGS_TOKEN=test \
  "$ALLOY_IMAGE" run /etc/alloy-transcript/config.alloy --storage.path=/tmp/alloy >/dev/null

# local.file_match re-scans every 10 s; give it two passes before appending.
sleep 25
python3 "$here/fixture.py" append "$root"

if ! LOKI_URL=$LOKI_URL python3 "$here/check.py" --wait 60; then
  echo "--- alloy log (last 40 lines)"
  docker logs "$name" 2>&1 | tail -40
  exit 1
fi
