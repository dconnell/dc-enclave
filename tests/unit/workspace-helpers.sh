#!/usr/bin/env bash
# =============================================================================
# tests/unit/workspace-helpers.sh - Shared repo-layout / mount-planning helpers.
#
# Covers lib/common/workspace.sh, the single source of truth for the schema-v2
# runtime shape shared by `dce new` and `dce rebuild-container`:
#   - dce_managed_devcontainer_file : managed devcontainer.json location
#   - dce_managed_cache_path/target : the reserved /workspace/.cache volume
#   - dce_cache_volume_name         : deterministic managed cache volume name
#   - dce_repo_entries_lines        : <name><TAB><path> lines from the globals
#   - dce_repo_mount_args           : one bind per repo at /workspace/<name>
#   - dce_workspace_mount_args      : full create-argv mount set (live + snap)
#   - dce_managed_volume_paths      : user hidden paths + the managed .cache
#   - dce_hidden_paths_for_project  : single-repo shorthand -> repo-prefixed
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
HOME="$WORK/home"
mkdir -p "$HOME"

# --- managed devcontainer path (project config dir, never a repo root) --------
dc_file="$(dce_managed_devcontainer_file "myproj")"
[[ "$dc_file" == "$HOME/.config/dce-enclave/myproj/devcontainer.json" ]] \
  || fail "managed devcontainer path wrong (got $dc_file)"

# --- managed cache constants ---------------------------------------------------
[[ "$(dce_managed_cache_path)" == ".cache" ]] || fail "cache path must be .cache"
[[ "$(dce_managed_cache_target)" == "/workspace/.cache" ]] || fail "cache target wrong"

cache_vol="$(dce_cache_volume_name "myproj")"
cache_vol_again="$(dce_cache_volume_name "myproj")"
[[ "$cache_vol" == "$cache_vol_again" ]] || fail "cache volume name must be stable"
[[ "$cache_vol" == dce-hide-* ]] || fail "cache volume should reuse the dce-hide- volume family"
[[ "$cache_vol" != "$(dce_hidden_volume_name "myproj" "node_modules")" ]] \
  || fail "cache volume must differ from a user hidden volume"

# --- repo entries + mounts from the schema-v2 globals --------------------------
# shellcheck disable=SC2034  # consumed by the helper via globals
REPO_NAMES=(web api)
# shellcheck disable=SC2034
REPO_PATHS=("$WORK/repos/web" "$WORK/src/api")

entries="$(dce_repo_entries_lines)"
printf '%s\n' "$entries" | grep -Fxq $'web\t'"$WORK/repos/web" \
  || fail "repo entries: missing web line (got: $entries)"
printf '%s\n' "$entries" | grep -Fxq $'api\t'"$WORK/src/api" \
  || fail "repo entries: missing api line (got: $entries)"

mapfile -t repo_args < <(dce_repo_mount_args)
[[ ${#repo_args[@]} -eq 4 ]] || fail "repo mounts: expected 4 argv words (got ${#repo_args[@]})"
[[ "${repo_args[0]}" == "--volume" ]] || fail "repo mounts: first word must be --volume"
[[ "${repo_args[1]}" == "$WORK/repos/web:/workspace/web" ]] || fail "repo mounts: web bind wrong (${repo_args[1]})"
[[ "${repo_args[3]}" == "$WORK/src/api:/workspace/api" ]] || fail "repo mounts: api bind wrong (${repo_args[3]})"

# --- full create/rebuild mount plan (live mode) --------------------------------
hidden_vol="$(dce_hidden_volume_name "myproj" "web/node_modules")"
mapfile -t mounts < <(dce_workspace_mount_args "myproj" "$WORK/sec/.npmrc" "live" "web/node_modules")

mounts_csv="$(printf '%s\n' "${mounts[@]}")"
grep -Fxq "$WORK/repos/web:/workspace/web" <<<"$mounts_csv" || fail "mount plan: repo web missing"
grep -Fxq "$WORK/src/api:/workspace/api" || true
grep -Fxq "$WORK/src/api:/workspace/api" <<<"$mounts_csv" || fail "mount plan: repo api missing"
grep -Fxq "$cache_vol:/workspace/.cache" <<<"$mounts_csv" || fail "mount plan: managed .cache volume missing"
grep -Fxq "$WORK/sec/.npmrc:/home/dev/.npmrc:ro" <<<"$mounts_csv" || fail "mount plan: npmrc bind missing"
grep -Fxq "$hidden_vol:/workspace/web/node_modules" <<<"$mounts_csv" || fail "mount plan: hidden volume missing"

# NO root /workspace bind may exist anymore: /workspace is the project root,
# assembled from per-repo binds + the managed cache volume.
if grep -Eq '^[^:]*:/workspace$' <<<"$mounts_csv"; then
  fail "mount plan: root /workspace bind must not exist"
fi

# An empty npmrc path must skip the secret bind (defensive; both callers pass one).
mapfile -t mounts_nonpmrc < <(dce_workspace_mount_args "myproj" "" "live" "")
if grep -q '/home/dev/.npmrc' <<<"$(printf '%s\n' "${mounts_nonpmrc[@]}")"; then
  fail "mount plan: empty npmrc path must not emit a secret bind"
fi

# --- snapshot-restore mode: hidden + managed volumes come from snap volumes ----
snap_vol_hidden="$(dce_snapshot_volume_name "myproj" "lbl" "web/node_modules")"
snap_vol_cache="$(dce_snapshot_volume_name "myproj" "lbl" ".cache")"
mapfile -t snap_mounts < <(dce_workspace_mount_args "myproj" "$WORK/sec/.npmrc" "snap:lbl" "web/node_modules")
snap_csv="$(printf '%s\n' "${snap_mounts[@]}")"
grep -Fxq "$snap_vol_hidden:/workspace/web/node_modules" <<<"$snap_csv" \
  || fail "snap mode: hidden volume must mount from the snapshot volume"
grep -Fxq "$snap_vol_cache:/workspace/.cache" <<<"$snap_csv" \
  || fail "snap mode: managed .cache must mount from the snapshot volume (isolated restore)"
# Repo binds are host state and never snapshot-sourced.
grep -Fxq "$WORK/repos/web:/workspace/web" <<<"$snap_csv" || fail "snap mode: repo bind missing"

# --- managed volume paths: user hidden + the cache path, deduped ---------------
mapfile -t managed < <(dce_managed_volume_paths "web/node_modules" "api/dist")
[[ "${managed[*]}" == "web/node_modules api/dist .cache" ]] \
  || fail "managed volume paths wrong (got: ${managed[*]})"
mapfile -t managed_dedup < <(dce_managed_volume_paths ".cache" "web/x")
[[ "${managed_dedup[*]}" == "web/x .cache" ]] \
  || fail "managed volume paths must dedupe .cache (got: ${managed_dedup[*]})"

# --- single-repo --hide shorthand normalizes to the repo-prefixed form ---------
# shellcheck disable=SC2034
REPO_NAMES=(only)
# shellcheck disable=SC2034
REPO_PATHS=("$WORK/repos/only")
shorthand="$(dce_hidden_paths_for_project "node_modules")"
[[ "$shorthand" == "only/node_modules" ]] \
  || fail "single-repo shorthand should persist as only/node_modules (got: $shorthand)"

nested_shorthand="$(dce_hidden_paths_for_project "apps/web/node_modules")"
[[ "$nested_shorthand" == "only/apps/web/node_modules" ]] \
  || fail "single-repo nested shorthand should persist as only/apps/web/node_modules (got: $nested_shorthand)"

# Already-prefixed paths pass through untouched.
[[ "$(dce_hidden_paths_for_project "only/node_modules")" == "only/node_modules" ]] \
  || fail "prefixed hidden path must pass through"
[[ "$(dce_hidden_paths_for_project "only/apps/web/node_modules")" == "only/apps/web/node_modules" ]] \
  || fail "prefixed nested hidden path must pass through"
[[ "$(dce_hidden_paths_for_project "only/a" "only/b")" == "only/a,only/b" ]] \
  || fail "multiple prefixed hidden paths must pass through"

# Multi-repo projects reject ambiguous unprefixed shorthand.
# shellcheck disable=SC2034
REPO_NAMES=(web api)
# shellcheck disable=SC2034
REPO_PATHS=("$WORK/repos/web" "$WORK/repos/api")
if dce_hidden_paths_for_project "node_modules" >/dev/null 2>&1; then
  fail "ambiguous unprefixed hidden path must be rejected for multi-repo projects"
fi
[[ "$(dce_hidden_paths_for_project "web/node_modules" "api/dist")" == "web/node_modules,api/dist" ]] \
  || fail "explicit multi-repo hidden paths must pass through"
if dce_hidden_paths_for_project "bogus/node_modules" >/dev/null 2>&1; then
  fail "unknown repo prefix must be rejected for multi-repo projects"
fi

# Reserved managed path stays rejected here too (defense in depth).
# shellcheck disable=SC2034
REPO_NAMES=(only)
# shellcheck disable=SC2034
REPO_PATHS=("$WORK/repos/only")
if dce_hidden_paths_for_project ".cache" >/dev/null 2>&1; then
  fail "the managed .cache path must never be claimable as a hidden path"
fi

pass "workspace/mount-planning helpers"
