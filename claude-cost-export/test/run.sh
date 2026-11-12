#!/usr/bin/env bash
# Golden test for cost-export.mjs: sweep the Claude transcript fixture with the
# repo's pricing.json and compare the spooled session_complete events with
# expected.ndjson, byte for byte.
#
# expected.ndjson was recorded with cost-export.mjs and pricing.json as they
# stood before the non-Claude rows were added (#304), so this test proves the
# fleet table's Gemini and Codex rows change nothing for local Claude sessions.
# Re-record (--update) only for a deliberate change to Claude pricing or to the
# event shape, and say why in the PR.
#
#   claude-cost-export/test/run.sh            compare
#   claude-cost-export/test/run.sh --update   re-record expected.ndjson
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
state=$(mktemp -d)
trap 'rm -rf "$state"' EXIT

# Sweep only: nothing is shipped. A wide lookback keeps the fixture's fixed
# timestamps in range, and a fixed worker keeps the hostname out of the output.
COST_STATE_DIR="$state" \
  COST_PROJECTS_DIR="$here/fixture/projects" \
  COST_WORKER=fixture \
  COST_LOOKBACK_DAYS=36500 \
  node "$here/../cost-export.mjs" sweep

sort "$state/spool.ndjson" >"$state/got"

if [ "${1:-}" = "--update" ]; then
  cp "$state/got" "$here/expected.ndjson"
  echo "re-recorded $here/expected.ndjson"
  exit 0
fi

if diff -u "$here/expected.ndjson" "$state/got"; then
  echo "ok   cost-export: $(wc -l <"$state/got") session events identical to expected.ndjson"
else
  echo "FAIL cost-export: output differs from expected.ndjson (diff above)" >&2
  exit 1
fi
