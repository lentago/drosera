#!/usr/bin/env bash
# Snapshot what's currently in the pitzilabs Grafana Cloud stack so we can write
# accurate Terraform import blocks. Reads GRAFANA_URL and GRAFANA_SA_TOKEN from
# the environment (load via direnv).
#
# Writes terraform/.bootstrap/<resource>.json (gitignored — local-only artifact).

set -euo pipefail

: "${GRAFANA_URL:?GRAFANA_URL must be set (e.g. https://pitzilabs.grafana.net)}"
: "${GRAFANA_SA_TOKEN:?GRAFANA_SA_TOKEN must be set}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/terraform/.bootstrap"
mkdir -p "$OUT"

api() {
  curl -sSf -H "Authorization: Bearer $GRAFANA_SA_TOKEN" "$GRAFANA_URL$1"
}

echo "==> folders"
api /api/folders | tee "$OUT/folders.json" | jq -r '.[] | "\(.uid)\t\(.title)"'

echo "==> datasources"
api /api/datasources | tee "$OUT/datasources.json" | jq -r '.[] | "\(.uid)\t\(.type)\t\(.name)"'

echo "==> dashboards (search)"
api '/api/search?type=dash-db&limit=5000' | tee "$OUT/dashboards.json" | jq -r '.[] | "\(.uid)\t\(.folderTitle // "General")\t\(.title)"'

echo "==> contact points"
api /api/v1/provisioning/contact-points | tee "$OUT/contact_points.json" | jq -r '.[] | "\(.uid // "-")\t\(.type)\t\(.name)"' || true

echo "==> notification policies"
api /api/v1/provisioning/policies > "$OUT/policies.json" || true

echo "==> alert rules"
api /api/v1/provisioning/alert-rules | tee "$OUT/alert_rules.json" | jq -r '.[] | "\(.uid)\t\(.title)"' || true

echo "==> service accounts (for record-keeping; tokens are not listed)"
api '/api/serviceaccounts/search?perpage=1000' | tee "$OUT/service_accounts.json" | jq -r '.serviceAccounts[]? | "\(.id)\t\(.name)\t\(.role)"' || true

echo
echo "Written to $OUT/"
ls -la "$OUT/"
