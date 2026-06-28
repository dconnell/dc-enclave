#!/usr/bin/env bash
# =============================================================================
# tests/integration/lib/naming.sh - Collision-proof resource naming for an
# integration run.
#
# Every resource created by the suite is named <prefix>-<backend>-<runid>-<case>
# so it can never collide with a developer's real projects NOR with a parallel
# integration run on the same host. The run id is stamped once per process and
# reused for every resource in the run, which also makes leak detection a
# simple prefix scan (see harness.sh / cleanup.sh).
#
# These are pure helpers (no lib deps, no I/O) so they can be sourced anywhere.
# =============================================================================
if [[ -n "${_IT_NAMING_SH_LOADED:-}" ]]; then return 0; fi
declare -gr _IT_NAMING_SH_LOADED=1

# Generate (once) and echo the run id. Format matches the plan so leak sweeps
# and log paths share one token:
#   <UTC YYYYmmddHHMMSS>-<pid>-<RANDOM>
# $$ is the runner PID; $RANDOM is bash-specific but the runner requires Bash 4+.
it_run_id() {
  if [[ -z "${IT_RUN_ID:-}" ]]; then
    IT_RUN_ID="$(date -u +%Y%m%d%H%M%S)-$$-$RANDOM"
    export IT_RUN_ID
  fi
  printf '%s\n' "$IT_RUN_ID"
}

# Project container name: test-<backend>-<runid>-<case>
it_project_name() {  # <backend> <case>
  printf 'test-%s-%s-%s\n' "$1" "$(it_run_id)" "$2"
}

# Private network name: testnet-<backend>-<runid>-<case>. Capped at 63 chars
# (the DNS-label limit apple/container enforces for network names -- container
# names are unaffected); long case ids are tail-truncated plus a short cksum
# hash so names stay unique while the run-id prefix (leak scan) is preserved.
it_network_name() {  # <backend> <case>
  local name
  name="testnet-$1-$(it_run_id)-$2"
  if (( ${#name} > 63 )); then
    local hash
    hash="$(printf '%s' "$2" | cksum | awk '{print $1}')"
    name="${name:0:56}-${hash:0:6}"
  fi
  printf '%s\n' "$name"
}

# Snapshot label: it-<runid>-<case>. Lowercase 'it' keeps it clearly distinct
# from container names; labels allow [A-Za-z0-9_.-] so '-' and the run id are
# legal. A single run reuses one run id so snapshot leaks sweep by it-*<runid>.
it_snap_label() {  # <case>
  printf 'it-%s-%s\n' "$(it_run_id)" "$1"
}

# Shared workspace root for this run: /tmp/dce-integration/<runid>
it_workspace_root() {  # [runid]
  printf '/tmp/dce-integration/%s\n' "${1:-$(it_run_id)}"
}
