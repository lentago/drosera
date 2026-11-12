#!/usr/bin/env bash
# Render the dashboards that carry placeholders (today the runner-fleet
# dashboard's __RUNNER_JOB_COST__, #304) into <out-dir>, offline, with the same
# module terraform/ applies. run.py reads a dashboard from LOGQL_RENDERED_DIR
# when the file is there, so a check runs the rendered query, not the
# placeholder.
#
#   scripts/tests/logql/render.sh <out-dir>
#   LOGQL_RENDERED_DIR=<out-dir> python3 scripts/tests/logql/run.py <case-dir>
#
# Each output of render/main.tf is one dashboard, named after its file without
# .json. Needs terraform and jq; no providers, no backend, no network.
set -euo pipefail

out=${1:?usage: render.sh <out-dir>}
root=$(cd "$(dirname "$0")/render" && pwd)
mkdir -p "$out"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Keep terraform's working files out of the checkout.
export TF_DATA_DIR="$tmp/tf"
terraform -chdir="$root" init -input=false -backend=false >"$tmp/init.log" || { cat "$tmp/init.log" >&2; exit 1; }
terraform -chdir="$root" plan -input=false -lock=false -out="$tmp/plan" >"$tmp/plan.log" || { cat "$tmp/plan.log" >&2; exit 1; }
terraform -chdir="$root" show -json "$tmp/plan" >"$tmp/plan.json"

for name in $(jq -r '.planned_values.outputs | keys[]' "$tmp/plan.json"); do
  jq -r --arg n "$name" '.planned_values.outputs[$n].value' "$tmp/plan.json" >"$out/$name.json"
  echo "rendered $out/$name.json"
done
