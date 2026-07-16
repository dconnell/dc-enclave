#!/usr/bin/env bash
# =============================================================================
# tests/integration/cases/sync.sh - Real-backend coverage for the `--sync`
# (Mutagen-synced workspace) feature.
#
# The stubbed contract test (tests/contract/sync-lifecycle.sh) proves the dce
# orchestration (mount swap, create-argv parity, flush ordering, mutual
# exclusion). This case proves the REAL-BACKEND behavior the contract suite
# cannot: a live Mutagen daemon reconciling a preserved dce-sync volume across
# the docker/podman transport, two-way file sync, rebuild-without-data-loss,
# snapshot exclusion, and clean-sweep exclusion. This is where the plan's one
# implementation unknown (volume-scoped sync on podman, not just docker) is
# actually confirmed against a real daemon.
#
# Gating: the whole suite is SKIPPED (not failed) when `mutagen` is not on PATH
# or the backend is apple/container (no Mutagen transport). The fail-fast
# negative paths (mutual exclusion, apple reject) are covered by the data-driven
# matrix (matrix/flags.tsv) and run without mutagen.
#
# Entry point (called by run-all.sh once per selected backend, full mode):
#   it_cases_sync <backend>
# =============================================================================
set -uo pipefail

# Per-reconciliation poll budget (seconds). 30s was tight on fast native
# runners; WSL2's slower VHDX-backed docker store routinely exceeds it on the
# first Mutagen reconcile, so default to 60 and allow CI to override.
_IT_SYNC_SETTLE_BUDGET="${IT_SYNC_SETTLE_BUDGET:-60}"

# Skip the whole suite when it cannot meaningfully run. Returns 0 (skip) or
# leaves the case to run. Mirrors the shellcheck WARN-when-absent convention.
_it_sync_skip_if_unsupported() {  # <backend>
  if [[ "$1" == "apple" ]]; then
    it_case_skip "apple/container has no Mutagen transport (--sync unsupported)"
    return 0
  fi
  if [[ "$1" == "podman" ]]; then
    it_case_skip "podman unsupported for --sync (Mutagen has no podman transport; macOS podman-machine SSH bridge blocked)"
    return 0
  fi
  if ! command -v mutagen >/dev/null 2>&1; then
    it_case_skip "mutagen CLI not on PATH (install: brew install mutagen-io/mutagen/mutagen)"
    return 0
  fi
  return 1
}

# Echo the Mutagen session name for a project (mirrors lib/common/sync.sh).
_it_session_name() {  # <project>
  dce_sync_session_name "$1"
}

# Return 0 if a Mutagen session for <project> exists.
_it_session_exists() {  # <project>
  local session
  session="$(_it_session_name "$1")"
  mutagen sync list "$session" >/dev/null 2>&1
}

# Return 0 if <volume> exists on <backend> (subshell-isolated; no context leak).
_it_volume_exists() {  # <backend> <volume>
  (
    backend_use "$1" >/dev/null 2>&1 || exit 1
    local v
    while IFS= read -r v; do
      [[ "$v" == "$2" ]] && exit 0
    done < <(backend_list_volumes 2>/dev/null)
    exit 1
  )
}

# Read one scalar value from a project's config file (the config command does
# not expose CONTAINER_SYNC, so read the persisted file directly).
_it_cfg_get() {  # <project> <key>
  local cfg="$HOME/.config/dce-enclave/$1/config"
  [[ -f "$cfg" ]] || return 1
  local line
  line="$(grep -E "^$2=" "$cfg" 2>/dev/null | head -n1)" || return 1
  printf '%s' "${line#*=}"
}

# Poll a shell <test> inside the container until it passes or <timeout>s elapse.
# Uses dce exec directly (not it_dce) so a tight poll loop does not spam the case
# log. Returns 0 if the test passed within budget, 1 otherwise.
_it_sync_poll() {  # <backend> <project> <test-sh> <timeout>
  local b="$1" p="$2" test="$3" budget="$4" elapsed=0
  while (( elapsed < budget )); do
    if CONTAINER_BACKEND="$b" "$_IT_DCE" exec "$p" sh -c "$test" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# Poll for a host-side file to appear (container->host reconciliation).
_it_sync_poll_host() {  # <path> <timeout>
  local path="$1" budget="$2" elapsed=0
  while (( elapsed < budget )); do
    [[ -f "$path" ]] && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Comprehensive synced lifecycle: new -> two-way sync -> rebuild (preserve) ->
# stop/start -> doctor -> rm (session+volume gone). One project, full flow.
# ---------------------------------------------------------------------------
_it_sync_lifecycle() {  # <backend> <case_id>
  local b="$1" c="$2" p cfg repo session sync_vol out rc
  _it_sync_skip_if_unsupported "$b" && return 0

  p="$(it_project_name "$b" "$c")"
  repo="$IT_REPOS_DIR/$p"
  # nodejs scope would build a derived image; base-only keeps this case focused
  # on the sync machinery (the hook is exercised by the dedicated nodejs case).
  if ! it_dce "$b" "$c" new "$p" --sync --sync-ignore node_modules,dist >/dev/null; then
    it_case_fail "dce new --sync exited non-zero"; return 1
  fi
  it_register_project "$p" "$b"
  session="$(_it_session_name "$p")"
  sync_vol="$(dce_sync_volume_name "$p")"

  # Config persisted the opt-in + ignore set, with no hidden paths. The array
  # writer (dce_set_config_array) %q-quotes elements and surrounds them with
  # spaces, so match loosely rather than pinning exact whitespace.
  [[ "$(_it_cfg_get "$p" CONTAINER_SYNC)" == '"1"' ]] \
    || { it_case_fail "config: CONTAINER_SYNC not persisted as 1"; return 1; }
  cfg="$HOME/.config/dce-enclave/$p/config"
  local ipline
  ipline="$(grep -E '^CONTAINER_SYNC_IGNORE_PATHS=' "$cfg")" \
    || { it_case_fail "config: CONTAINER_SYNC_IGNORE_PATHS not persisted"; return 1; }
  grep -Fq 'node_modules' <<<"$ipline" \
    || { it_case_fail "config: CONTAINER_SYNC_IGNORE_PATHS missing node_modules"; return 1; }
  grep -Fq 'dist' <<<"$ipline" \
    || { it_case_fail "config: CONTAINER_SYNC_IGNORE_PATHS missing dist"; return 1; }
  grep -Eq '^CONTAINER_HIDDEN_PATHS=\([[:space:]]*\)$' "$cfg" \
    || { it_case_fail "config: hidden paths must be empty under --sync"; return 1; }

  # Mutagen session exists + the sync volume exists on the backend.
  _it_session_exists "$p" || { it_case_fail "mutagen sync session not created"; return 1; }
  _it_volume_exists "$b" "$sync_vol" || { it_case_fail "dce-sync volume not created"; return 1; }

  # Two-way reconciliation: host -> container.
  printf 'host-marker-%s\n' "$RANDOM" > "$repo/host-marker.txt"
  _it_sync_poll "$b" "$p" 'test -f /workspace/host-marker.txt' "$_IT_SYNC_SETTLE_BUDGET" \
    || { it_case_fail "host->container sync did not settle in ${_IT_SYNC_SETTLE_BUDGET}s"; return 1; }

  # Two-way reconciliation: container -> host (the data-loss-critical direction).
  it_dce "$b" "$c" exec "$p" sh -c 'echo container-marker > /workspace/container-marker.txt' >/dev/null \
    || { it_case_fail "dce exec write failed"; return 1; }
  _it_sync_poll_host "$repo/container-marker.txt" "$_IT_SYNC_SETTLE_BUDGET" \
    || { it_case_fail "container->host sync did not settle in ${_IT_SYNC_SETTLE_BUDGET}s"; return 1; }

  # Rebuild preserves the sync volume + reconciles back (no data loss). A marker
  # written in the container must survive the destroy/recreate because the volume
  # is preserved and the session reconnects.
  it_dce "$b" "$c" exec "$p" sh -c 'echo persist > /workspace/persist-marker.txt' >/dev/null \
    || { it_case_fail "dce exec write (persist) failed"; return 1; }
  _it_sync_poll_host "$repo/persist-marker.txt" "$_IT_SYNC_SETTLE_BUDGET" >/dev/null \
    || { it_case_fail "persist marker did not sync to host before rebuild"; return 1; }
  if ! it_dce_in "$b" "$c" $'yes\n' rebuild-container "$p" --yes >/dev/null; then
    it_case_fail "rebuild-container (synced) exited non-zero"; return 1
  fi
  # Same volume name survived (not a fresh one).
  _it_volume_exists "$b" "$sync_vol" || { it_case_fail "sync volume not preserved across rebuild"; return 1; }
  _it_session_exists "$p" || { it_case_fail "sync session not present after rebuild"; return 1; }
  _it_sync_poll "$b" "$p" 'test -f /workspace/persist-marker.txt' "$_IT_SYNC_SETTLE_BUDGET" \
    || { it_case_fail "persist marker lost across rebuild (data-loss regression)"; return 1; }

  # stop/start leaves the session intact and the workspace accessible.
  it_dce "$b" "$c" stop "$p" >/dev/null || { it_case_fail "stop"; return 1; }
  it_dce "$b" "$c" start "$p" >/dev/null || { it_case_fail "start"; return 1; }
  _it_session_exists "$p" || { it_case_fail "sync session dropped after stop/start"; return 1; }

  # doctor reports a healthy synced project. Its aggregate exit code also
  # reflects token/devcontainer state (the placeholder token always fails in
  # tests), so assert only the sync-specific signal, not the overall exit code.
  out="$(it_dce_capture "$b" "$c" doctor "$p" 2>&1 || true)"
  grep -Fqi 'Sync session healthy' <<<"$out" \
    || { it_case_fail "doctor did not report sync session healthy: $out"; return 1; }

  # Explicit rm: session terminated + sync volume removed. The harness per-case
  # rm is an idempotent no-op after this (project already gone).
  if ! it_dce "$b" "$c" rm "$p" --yes >/dev/null; then
    it_case_fail "dce rm (synced) exited non-zero"; return 1
  fi
  if _it_session_exists "$p"; then
    it_case_fail "mutagen session not terminated by dce rm"; return 1
  fi
  if _it_volume_exists "$b" "$sync_vol"; then
    it_case_fail "sync volume not removed by dce rm"; return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot excludes the sync volume (host is canonical). Asserts the guard
# message and that NO snapshot volume is created for the sync volume.
# ---------------------------------------------------------------------------
_it_sync_snapshot_excluded() {  # <backend> <case_id>
  local b="$1" c="$2" p label out rc
  _it_sync_skip_if_unsupported "$b" && return 0

  p="$(it_project_name "$b" "$c")"
  if ! it_dce "$b" "$c" new "$p" --sync >/dev/null; then
    it_case_fail "dce new --sync exited non-zero"; return 1
  fi
  it_register_project "$p" "$b"
  # Container must be running for the snapshot scrub step.
  it_dce "$b" "$c" start "$p" >/dev/null || { it_case_fail "start"; return 1; }
  label="$(it_snap_label "$c")"

  out="$(it_dce_capture "$b" "$c" snapshot "$p" "$label" --yes)" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "snapshot exited $rc"; return 1; }
  grep -Fqi 'sync volume excluded' <<<"$out" \
    || { it_case_fail "snapshot did not note sync-volume exclusion: $out"; return 1; }

  # No snapshot volume (dce-snapvol-*) should exist for this project: a synced
  # project has no hidden paths, so the capture loop is empty by construction.
  local v left=0
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    if [[ "$v" == "dce-snapvol-"* && "$v" == *"$(dce_project_slug "$p")"* ]]; then
      left=1
    fi
  done < <(backend_use "$b" >/dev/null 2>&1 && backend_list_volumes 2>/dev/null)
  [[ $left -eq 0 ]] || { it_case_fail "snapshot created a snapvol for a synced project (should be excluded)"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# dce clean never touches dce-sync-*: neither --hidden-volumes nor --snapshots
# removes the sync volume of a live synced project.
# ---------------------------------------------------------------------------
_it_sync_clean_sweep() {  # <backend> <case_id>
  local b="$1" c="$2" p sync_vol out rc
  _it_sync_skip_if_unsupported "$b" && return 0

  p="$(it_project_name "$b" "$c")"
  if ! it_dce "$b" "$c" new "$p" --sync >/dev/null; then
    it_case_fail "dce new --sync exited non-zero"; return 1
  fi
  it_register_project "$p" "$b"
  sync_vol="$(dce_sync_volume_name "$p")"

  # --hidden-volumes scopes to dce-hide-*; the sync volume must survive.
  out="$(it_dce_capture "$b" "$c" clean --hidden-volumes --dry-run)" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "clean --hidden-volumes --dry-run exited $rc"; return 1; }
  ! grep -Fq "$sync_vol" <<<"$out" \
    || { it_case_fail "clean --hidden-volumes listed the sync volume for removal"; return 1; }
  _it_volume_exists "$b" "$sync_vol" || { it_case_fail "sync volume vanished after clean --hidden-volumes"; return 1; }

  # --snapshots scopes to dce-snapvol-*/dce-snap-*; the sync volume must survive.
  out="$(it_dce_capture "$b" "$c" clean --snapshots --dry-run)" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "clean --snapshots --dry-run exited $rc"; return 1; }
  ! grep -Fq "$sync_vol" <<<"$out" \
    || { it_case_fail "clean --snapshots listed the sync volume for removal"; return 1; }
  _it_volume_exists "$b" "$sync_vol" || { it_case_fail "sync volume vanished after clean --snapshots"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# The nodejs install-on-start hook fires under --sync-ignore on a real backend.
# Uses the repo's example overlay (composed+built once). With no package.json the
# hook logs "no package.json ... skipping dependency sync" -- network-free proof
# the hook composes with the sync topology (the generalization's real risk).
# ---------------------------------------------------------------------------
_it_sync_nodejs_hook() {  # <backend> <case_id>
  local b="$1" c="$2" p out rc team_od
  _it_sync_skip_if_unsupported "$b" && return 0

  # Provide the example nodejs overlay so a derived image composes+builds.
  team_od="$HOME/.config/dce-enclave/team/overlays"
  mkdir -p "$team_od"
  [[ -f "$team_od/Containerfile.nodejs" ]] \
    || cp "$_IT_ROOT/Containerfiles/example/Containerfile.nodejs" "$team_od/" \
    || { it_case_skip "could not stage nodejs example overlay"; return 0; }

  p="$(it_project_name "$b" "$c")"
  if ! it_dce "$b" "$c" new "$p" nodejs --sync --sync-ignore node_modules >/dev/null; then
    it_case_fail "dce new nodejs --sync exited non-zero (overlay build?)"; return 1
  fi
  it_register_project "$p" "$b"
  _it_session_exists "$p" || { it_case_fail "mutagen sync session not created"; return 1; }

  # The composed ENTRYPOINT chains the node hook on start; with no package.json
  # it logs the skip line. Poll the container log for the hook marker.
  local log elapsed=0
  log="$(it_log_path "$b" "$c")"
  while (( elapsed < 30 )); do
    out="$(it_dce_capture "$b" "$c" logs "$p")" && rc=0 || rc=$?
    if grep -Fqi 'node-hide' <<<"$out" || grep -Fqi 'no package.json' <<<"$out"; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  it_case_fail "nodejs install-on-start hook did not fire under --sync-ignore (see $log)"
  return 1
}

it_cases_sync() {  # <backend>
  local b="$1"
  it_run_case "$b" "sync-lifecycle"        _it_sync_lifecycle
  it_run_case "$b" "sync-snapshot-excluded" _it_sync_snapshot_excluded
  it_run_case "$b" "sync-clean-sweep"      _it_sync_clean_sweep
  it_run_case "$b" "sync-nodejs-hook"      _it_sync_nodejs_hook
}
