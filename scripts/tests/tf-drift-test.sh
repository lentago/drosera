#!/usr/bin/env bash
# Fixture test for scripts/tf-drift.sh's comparison (#290). No Terraform, no
# Grafana: each fixture is the JSON of a refresh-only plan, fed through
# `tf-drift.sh --from-json`.
#
#   normalisation-only.json  rule group whose only difference is null vs [] in
#                            notification_settings; must print nothing.
#   mixed.json               real live edits (a rule's `for`, a mute timing
#                            added, a dashboard panel) beside the same noise and
#                            a non-Grafana-dashboard type; must print exactly
#                            mixed.expected.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
drift="$here/../tf-drift.sh"
fx="$here/tf-drift"
fail=0

out=$("$drift" --from-json "$fx/normalisation-only.json")
if [ -n "$out" ]; then
  echo "FAIL normalisation-only: expected no drift, got:"
  echo "$out"
  fail=1
else
  echo "ok   normalisation-only: null vs [] is not reported"
fi

if diff -u "$fx/mixed.expected" <("$drift" --from-json "$fx/mixed.json"); then
  echo "ok   mixed: every real edit reported, the noise and the datasource are not"
else
  echo "FAIL mixed: output differs from mixed.expected (diff above)"
  fail=1
fi

exit "$fail"
