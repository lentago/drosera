#!/usr/bin/env bash
# Claude Code heartbeat hook: while a local session is actively working, push a
# lightweight event="session_running" to the homelab Loki receiver, throttled to
# one push per session per ~30s, so the "Local sessions underway" Grafana panel
# has an in-flight signal. The cost-export sweep still ships the authoritative
# session_complete at the end — this only adds the live band.
#
# Wired via ~/.claude/settings.json hooks.PostToolUse + hooks.UserPromptSubmit.
# Reads the hook payload (JSON) on stdin; needs session_id (+ cwd for a project
# label). Fire-and-forget: never blocks the session, never fails it; off-LAN the
# POST just times out and vanishes. Shares COST_* env with cost-export.mjs.
set -uo pipefail

STATE_DIR="${COST_STATE_DIR:-$HOME/.claude/cost-export}"
HB_DIR="$STATE_DIR/heartbeat"
LOKI_URL="${COST_LOKI_URL:-http://192.168.139.20:3100/loki/api/v1/push}"
WORKER="${COST_WORKER:-$(hostname)}"
THROTTLE="${COST_HEARTBEAT_SEC:-30}"

# Need jq (valid JSON) and curl (push); without either, no-op rather than risk junk.
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null || true)"
sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -z "$sid" ] && exit 0
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"

# Throttle: at most one push per session per $THROTTLE seconds.
mkdir -p "$HB_DIR" 2>/dev/null || exit 0
marker="$HB_DIR/$sid"
now="$(date +%s)"
last="$(stat -c %Y "$marker" 2>/dev/null || echo 0)"
[ "$(( now - last ))" -lt "$THROTTLE" ] && exit 0
: > "$marker" 2>/dev/null || true

project="local"; [ -n "$cwd" ] && project="$(basename "$cwd")"
line="$(jq -cn --arg sid "$sid" --arg w "$WORKER" --arg p "$project" --arg cwd "$cwd" \
  '{event:"session_running",session_id:$sid,source:"local",worker:$w,project:$p,cwd:$cwd}')"
body="$(jq -cn --arg w "$WORKER" --arg p "$project" --arg ts "${now}000000000" --arg line "$line" \
  '{streams:[{stream:{job:"claude_local",service:"claude_runner",source:"local",worker:$w,project:$p,status:"running"},values:[[$ts,$line]]}]}')"

# Detach so the hook returns immediately and never adds latency to the session.
( curl -sf -m 5 -XPOST "$LOKI_URL" -H 'Content-Type: application/json' --data-binary "$body" >/dev/null 2>&1 & ) >/dev/null 2>&1
exit 0
