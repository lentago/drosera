#!/usr/bin/env bash
# Pull the central Alloy config from origin/main and reload the running
# `alloy` docker container when it drifts.
#
# Runs on the grafana-stack LXC (105), where the Alloy docker compose service
# lives at /opt/homelab-observability. Mirrors the spirit of
# homeassistant-config/kiosk-host/gitops-pull.sh: timestamped leveled log with
# in-script rotation, flock against concurrent runs, branch guard, validation
# before reload, and a no-op fast path so Alloy isn't reloaded on every poll.
# A liveness guard also restarts a dead container (only with a valid config).
#
# Driven by a 5-minute timer (alloy-gitops.{service,timer} in this directory).
# Those units are bootstrap-only and deliberately NOT managed by this loop, so a
# broken update can't leave the host unable to fix itself. Bootstrap recipe is
# in this directory's README.

set -euo pipefail

readonly REPO_DIR="/opt/homelab-observability"
readonly LOCK_FILE="/run/alloy-gitops.lock"
readonly LOG_FILE="/var/log/alloy-gitops.log"
readonly LOG_MAX_BYTES=1048576
readonly CONTAINER="alloy"

log() {
  local level="$1"
  shift
  local ts line
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  line="[$ts] [$level] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG_FILE"
}

rotate_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE")
    if ((size >= LOG_MAX_BYTES)); then
      mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
}

# Image of the compose `alloy` service, read from docker-compose.yml so the
# out-of-band validator always matches the version the container runs.
alloy_image() {
  awk '
    /^  [A-Za-z0-9_-]+:/ { in_alloy = ($1 == "alloy:") }
    in_alloy && $1 == "image:" { print $2; exit }
  ' "${REPO_DIR}/docker-compose.yml" | tr -d "\"'"
}

# Validate the checked-out alloy/config.alloy in a throwaway container, so the
# check works whether or not the long-running `alloy` container is healthy.
validate_config() {
  local image
  image=$(alloy_image)
  if [[ -z "${image}" ]]; then
    log ERROR "could not parse the alloy image from docker-compose.yml"
    return 1
  fi
  docker run --rm -v "${REPO_DIR}/alloy:/etc/alloy:ro" "${image}" \
    fmt /etc/alloy/config.alloy >/dev/null 2>&1
}

# True only when the container exists, is running, and is not crash-looping
# (a Restarting container still reports Running=true, so check both).
container_running() {
  local state
  state=$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "${CONTAINER}" 2>/dev/null || true)
  [[ "${state}" == "true false" ]]
}

# Liveness guard. If the container is down, bring it back — but only with a
# config that validates. Never rolls back a commit: a down container is not
# evidence the config is bad. Always returns 0 so callers can carry on.
ensure_alive() {
  if container_running; then
    return 0
  fi
  if validate_config; then
    log WARN "container '${CONTAINER}' is not running — config validates, docker compose up -d"
    docker compose up -d >/dev/null || log ERROR "docker compose up -d failed"
  else
    log ERROR "container '${CONTAINER}' is not running and the checked-out config fails validation — leaving it alone"
  fi
  return 0
}

main() {
  rotate_log

  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    log ERROR "No git repo at ${REPO_DIR}. Bootstrap: see alloy-host/README.md"
    exit 1
  fi
  cd "${REPO_DIR}"

  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ "${branch}" != "main" ]]; then
    log ERROR "Expected branch 'main', got '${branch}'. Aborting to avoid deploying the wrong branch."
    exit 1
  fi

  if ! git fetch --quiet origin main; then
    log ERROR "git fetch failed — check network or DNS"
    exit 1
  fi

  local old new
  old=$(git rev-parse HEAD)
  new=$(git rev-parse origin/main)
  if [[ "${old}" == "${new}" ]]; then
    ensure_alive
    log INFO "no-op, at ${new:0:7}"
    exit 0
  fi

  local changed
  changed=$(git diff --name-only "${old}" "${new}")
  log INFO "Updating ${old:0:7} → ${new:0:7}"
  git reset --hard --quiet origin/main

  # Validate the new config before applying. Validation runs out-of-band in a
  # throwaway container (image parsed from docker-compose.yml), so it does not
  # depend on the running container. If it fails we roll the working tree back
  # and skip the apply; a running collector keeps its last-good in-memory config.
  local touches_alloy=0
  if grep -qE '^(alloy/|docker-compose\.yml$)' <<<"${changed}"; then
    touches_alloy=1
    if ! validate_config; then
      log ERROR "alloy fmt failed on the new config — rolling back to ${old:0:7}, not reloading"
      git reset --hard --quiet "${old}"
      exit 1
    fi
  fi

  # Apply. A docker-compose.yml change recreates the container (which also picks
  # up any alloy/ change); an alloy/ change alone just needs a config reload via
  # SIGHUP (the ./alloy directory mount means the container sees the new files);
  # anything else (docs/scripts/terraform) is a no-op for the running collector.
  # If the container is down, the liveness guard starts it instead (a SIGHUP
  # would have nothing to signal).
  if ! container_running; then
    ensure_alive
  elif grep -qx 'docker-compose.yml' <<<"${changed}"; then
    log INFO "docker-compose.yml changed → docker compose up -d"
    docker compose up -d >/dev/null
  elif ((touches_alloy)); then
    log INFO "alloy/ changed → reloading config (SIGHUP)"
    docker kill --signal=HUP "${CONTAINER}" >/dev/null
  else
    log INFO "update touched no alloy/ or compose files — nothing to reload"
  fi

  log INFO "Deployed ${new:0:7}"
}

main_locked() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    exit 0
  fi
  main
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_locked
fi
