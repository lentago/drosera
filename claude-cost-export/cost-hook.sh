#!/usr/bin/env bash
# Claude Code SessionEnd hook: mark a session "finished" so the next sweep ships
# it promptly instead of waiting for the idle-timeout backstop. Best-effort and
# intentionally trivial — a hard kill that skips this hook is still caught by the
# sweep's idle detection, because the transcript on disk is the source of truth.
#
# Wired via ~/.claude/settings.json hooks.SessionEnd. Reads the hook payload
# (JSON) on stdin; we only need session_id. Never blocks, never fails the session.
set -uo pipefail
STATE_DIR="${COST_STATE_DIR:-$HOME/.claude/cost-export}"
DONE_DIR="$STATE_DIR/done"

payload="$(cat 2>/dev/null || true)"
sid=""
if command -v jq >/dev/null 2>&1; then
  sid="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi
# jq-less fallback
[ -z "$sid" ] && sid="$(printf '%s' "$payload" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"

[ -z "$sid" ] && exit 0

# Done marker first, best effort: a heartbeat beat detached a moment ago checks
# for it and will not recreate the beacon. If the marker cannot be written the
# beacon is still removed below.
{ mkdir -p "$DONE_DIR" 2>/dev/null && : > "$DONE_DIR/$sid" 2>/dev/null; } || true

# Drop this session's viewport focus beacon (see session-heartbeat.sh); best
# effort.
beacon_dir="${VIEWPORT_DIR:-/mnt/lentago/web/viewport}/focus"
if [ -d "$beacon_dir" ]; then
  sess="$(printf '%s' "${sid:0:8}" | tr -c 'A-Za-z0-9_-' '_')"
  rm -f "$beacon_dir/$(hostname)-$sess.json" "$beacon_dir/$(hostname)-$sess.json.partial" 2>/dev/null || true
fi
exit 0
