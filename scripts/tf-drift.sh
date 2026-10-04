#!/usr/bin/env bash
# List grafana_dashboard / grafana_rule_group resources whose LIVE state differs
# from last-applied state (live-only edits that the next apply will overwrite).
# Run from terraform/ after `terraform init`. Prints one line per drifted
# resource on stdout ("<address> (uid <uid>)"); nothing if there is no drift.
# Advisory only: a failed refresh-only plan warns on stderr and prints nothing.
set -euo pipefail

if ! terraform plan -refresh-only -no-color -input=false -lock=false \
  -out=drift.tfplan >drift-plan.log 2>&1; then
  echo "::warning::refresh-only drift check failed (see drift-plan.log); drift status unknown" >&2
  exit 0
fi

terraform show -json drift.tfplan | jq -r '
  .resource_drift[]?
  | select(.type == "grafana_dashboard" or .type == "grafana_rule_group")
  | "\(.address) (uid \(.change.before.uid // .change.after.uid // "n/a"))"'
