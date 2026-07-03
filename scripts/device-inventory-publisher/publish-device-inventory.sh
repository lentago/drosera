#!/usr/bin/env bash
set -euo pipefail

# publish-device-inventory.sh — runs ON the Firewalla box (pi user), hourly via
# cron. Reads the box's own device inventory from local redis and pushes it to
# the central Alloy Loki receiver as the log_source="device_inventory" stream,
# so Grafana Cloud dashboards can resolve raw LAN IPs to device names via
# frame-join transformations and a label_values() template variable.
#
# Part of issue #113 (Phase 1). Deployed by re-running
# scripts/deploy-device-inventory-publisher.sh from the operator workstation —
# NOT gitops-managed (mirrors the worker-transcript-shipper exception).
#
# Why on the Firewalla, not LXC 105: the box already ships Zeek/ACL logs to the
# same Alloy Loki receiver, and can read its own inventory from local redis with
# no new credentials.
#
# Redis model (Firewalla): one hash per device under `host:mac:<MAC>` with
# fields `name` (user label), `bname` (discovered/best name), `mac`, `ipv4Addr`
# (single string), `ipv6Addr` (JSON-encoded array of addresses).
#
# Output: one Loki stream per (device, ip) pair. Labels:
#   { log_source="device_inventory", dev="<name>|<ip>" }
# Line body JSON:
#   {"name":"…","ip":"…","mac":"…","family":"4"|"6","source":"firewalla-redis"}
# The dev label's "<name>|<ip>" shape is load-bearing: Phase 3 populates a
# dashboard variable with label_values({log_source="device_inventory"}, dev)
# and regex /(?<text>[^|]+)\|(?<value>.+)/, so any '|' is stripped from names.
#
# Config: ALLOY_HOST (required). Sourced from an optional sibling
# `device-inventory.env` the deploy script writes, or from the environment.
# Deps: redis-cli, jq, curl (all present on the box). No sudo.
#
# Env knobs:
#   ALLOY_HOST   central Alloy host (default 192.168.139.20 — the Loki receiver)
#   ALLOY_PORT   Loki push port (default 3100)
#   REDIS_CLI    redis-cli invocation (default "redis-cli"; override to add -h/-p)
#   DRY_RUN      if non-empty, print the payload to stdout instead of pushing

# ---------------------------------------------------------------------------
# Config — source a sibling env file if the deploy script dropped one next to us.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/device-inventory.env" ]; then
  # shellcheck source=/dev/null
  . "${SCRIPT_DIR}/device-inventory.env"
fi

ALLOY_HOST="${ALLOY_HOST:-192.168.139.20}"
ALLOY_PORT="${ALLOY_PORT:-3100}"
PUSH_URL="http://${ALLOY_HOST}:${ALLOY_PORT}/loki/api/v1/push"
REDIS_CLI="${REDIS_CLI:-redis-cli}"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "FATAL: '$dep' not found in PATH" >&2; exit 1; }
done
# REDIS_CLI may carry flags (e.g. "redis-cli -p 6379"); check the first word.
command -v "${REDIS_CLI%% *}" >/dev/null 2>&1 || { echo "FATAL: redis-cli not found in PATH" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Collect one JSON stream object per (device, ip) into a temp file.
# ---------------------------------------------------------------------------
STREAMS_FILE="$(mktemp)"
trap 'rm -f "${STREAMS_FILE}"' EXIT

# Single timestamp for the whole batch — one hourly snapshot, one instant.
TS_NS="$(date +%s%N)"

# emit <name> <ip> <mac> <family> — append a Loki stream object.
emit() {
  name="$1"; ip="$2"; mac="$3"; family="$4"
  # Strip '|' from the display name so the dev="<name>|<ip>" split stays clean.
  name="${name//|/}"
  jq -n \
    --arg name "$name" --arg ip "$ip" --arg mac "$mac" \
    --arg family "$family" --arg ts "$TS_NS" '
    {
      stream: { log_source: "device_inventory", dev: ($name + "|" + $ip) },
      values: [ [ $ts, ({ name: $name, ip: $ip, mac: $mac, family: $family, source: "firewalla-redis" } | tojson) ] ]
    }' >> "${STREAMS_FILE}"
}

device_count=0
record_count=0

# --scan is cursor-based and non-blocking (unlike KEYS) — safe on a live box.
while IFS= read -r key; do
  [ -n "$key" ] || continue
  device_count=$((device_count + 1))

  mac="$($REDIS_CLI hget "$key" mac 2>/dev/null || true)"
  [ -n "$mac" ] || mac="${key#host:mac:}"

  name="$($REDIS_CLI hget "$key" name 2>/dev/null || true)"
  [ -n "$name" ] || name="$($REDIS_CLI hget "$key" bname 2>/dev/null || true)"
  [ -n "$name" ] || name="$mac"

  ipv4="$($REDIS_CLI hget "$key" ipv4Addr 2>/dev/null || true)"
  ipv6json="$($REDIS_CLI hget "$key" ipv6Addr 2>/dev/null || true)"

  if [ -n "$ipv4" ] && [ "$ipv4" != "null" ]; then
    emit "$name" "$ipv4" "$mac" "4"
    record_count=$((record_count + 1))
  fi

  # ipv6Addr is a JSON-encoded array; tolerate it being empty/missing/invalid.
  if [ -n "$ipv6json" ] && [ "$ipv6json" != "null" ]; then
    while IFS= read -r ip6; do
      [ -n "$ip6" ] || continue
      emit "$name" "$ip6" "$mac" "6"
      record_count=$((record_count + 1))
    done < <(printf '%s' "$ipv6json" | jq -r 'if type == "array" then .[] else empty end' 2>/dev/null || true)
  fi
done < <($REDIS_CLI --scan --pattern 'host:mac:*' 2>/dev/null || true)

if [ "$record_count" -eq 0 ]; then
  echo "No device records with an IP found across ${device_count} host:mac:* key(s) — nothing to push." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Assemble the batched payload ({streams:[…]}) and push once.
# ---------------------------------------------------------------------------
PAYLOAD_FILE="$(mktemp)"
trap 'rm -f "${STREAMS_FILE}" "${PAYLOAD_FILE}"' EXIT
jq -s '{ streams: . }' "${STREAMS_FILE}" > "${PAYLOAD_FILE}"

if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY_RUN: ${record_count} record(s) from ${device_count} device(s); payload for ${PUSH_URL}:" >&2
  cat "${PAYLOAD_FILE}"
  exit 0
fi

http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "${PUSH_URL}" \
  -H 'Content-Type: application/json' \
  --data-binary "@${PAYLOAD_FILE}")" \
  || { echo "FATAL: push to ${PUSH_URL} failed (curl error)" >&2; exit 1; }

# Loki/Alloy returns 204 No Content on a successful push.
case "$http_code" in
  204|200)
    echo "Pushed ${record_count} record(s) from ${device_count} device(s) to ${PUSH_URL} (HTTP ${http_code})."
    ;;
  *)
    echo "FATAL: push to ${PUSH_URL} returned HTTP ${http_code}" >&2
    exit 1
    ;;
esac
