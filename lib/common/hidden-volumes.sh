#!/usr/bin/env bash
# =============================================================================
# lib/common/hidden-volumes.sh - Hidden-path normalization + volume lifecycle.
#
# Sourced (never executed directly) via lib/common.sh. Owns the grammar for
# /workspace-relative hidden paths (relative, traversal-free, no whitespace or
# shell-breaking chars) and the deterministic named-volume mapping derived from
# (project, path). The volume-lifecycle helpers (rebuild cleanup, mount
# verification, restart-to-apply) depend on the backend_* abstraction supplied
# by lib/container-backend.sh. Depends on core.sh (dce_project_slug,
# dce_sha256_hex, dce_join_by).
# =============================================================================

if [[ -n "${_DC_COMMON_HIDDEN_VOLUMES_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_HIDDEN_VOLUMES_SH_LOADED=1

# Validate one hidden path. Hidden paths are mounted as named volumes under
# /workspace and embedded in backend mount flags, so they must be relative,
# traversal-free, contain no whitespace or ':' (which would break flag parsing),
# and use only filename-safe characters.
dce_validate_hidden_path() {
  local path="$1"

  [[ -n "$path" ]] || return 1

  if [[ "$path" =~ [[:space:]] ]]; then
    return 1
  fi

  [[ "$path" != /* ]] || return 1
  [[ "$path" != "." && "$path" != ".." ]] || return 1
  [[ "$path" != *:* ]] || return 1

  if [[ "$path" =~ (^|/)\.\.?($|/) ]]; then
    return 1
  fi

  [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]]
}

# Normalize a single comma-separated hidden-path value: trim whitespace, strip
# leading "./", collapse duplicate slashes, strip trailing "/", de-dupe, and
# validate each path. Returns the canonical CSV or fails with a message.
dce_normalize_hidden_paths_csv() {
  local input="$1"

  if [[ -z "$input" ]]; then
    printf 'ERROR: Hidden path value is empty.\n' >&2
    return 1
  fi

  local -a normalized=()
  local -a raw_paths=()
  declare -A seen=()
  local raw_path=""
  local path=""
  local saw_token=0

  IFS=',' read -r -a raw_paths <<< "$input"
  for raw_path in "${raw_paths[@]}"; do
    saw_token=1
    path="$raw_path"
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    [[ -z "$path" ]] && continue

    while [[ "$path" == ./* ]]; do
      path="${path#./}"
    done

    while [[ "$path" == */ ]]; do
      path="${path%/}"
    done

    while [[ "$path" == *"//"* ]]; do
      path="${path//\/\//\/}"
    done

    if ! dce_validate_hidden_path "$path"; then
      printf 'ERROR: Invalid hidden path: %s\n' "$path" >&2
      printf '  Rules: relative path under /workspace; no whitespace, no :, no traversal (., ..)\n' >&2
      return 1
    fi

    if [[ -n "${seen[$path]-}" ]]; then
      continue
    fi

    seen["$path"]=1
    normalized+=("$path")
  done

  if [[ "$saw_token" -eq 1 && ${#normalized[@]} -eq 0 ]]; then
    printf 'ERROR: Hidden path value is empty or invalid: %s\n' "$input" >&2
    return 1
  fi

  dce_join_by ',' "${normalized[@]}"
}

# Normalize hidden paths across multiple --hide values (which may repeat).
# Merges and de-duplicates all values into one canonical CSV, echoing empty
# when no values are supplied.
dce_normalize_hidden_paths_values() {
  if [[ $# -eq 0 ]]; then
    printf ''
    return 0
  fi

  local -a normalized_all=()
  local -a normalized_parts=()
  declare -A seen=()
  local raw_value=""
  local normalized_csv=""
  local part=""

  for raw_value in "$@"; do
    [[ -z "$raw_value" ]] && continue
    if ! normalized_csv="$(dce_normalize_hidden_paths_csv "$raw_value")"; then
      return 1
    fi

    IFS=',' read -r -a normalized_parts <<< "$normalized_csv"
    for part in "${normalized_parts[@]}"; do
      [[ -z "$part" ]] && continue
      if [[ -n "${seen[$part]-}" ]]; then
        continue
      fi
      seen["$part"]=1
      normalized_all+=("$part")
    done
  done

  dce_join_by ',' "${normalized_all[@]}"
}

# Build the deterministic managed-volume name for a project hidden path.
#
# Format: dce-hide-<project-slug>-<12hex>. The name is derived purely from the
# project and path (not random) so the same hidden path reliably maps to the
# same volume across creates, starts, and rebuilds, letting us find/remove it.
dce_hidden_volume_name() {
  local project="$1"
  local hidden_path="$2"

  local project_slug=""
  project_slug="$(dce_project_slug "$project")"

  local key="hide-v1|$project|$hidden_path"
  local hash=""
  hash="$(dce_sha256_hex "$key")"
  hash="${hash:0:12}"

  printf 'dce-hide-%s-%s\n' "$project_slug" "$hash"
}

# Check whether a named volume exists in the backend's volume store.
# Returns 0 (exists), 1 (absent), or 2 (the backend list call itself failed).
dce_hidden_volume_exists() {
  local volume_name="$1"
  local volume_list=""
  local listed_volume=""

  if ! volume_list="$(backend_list_volumes 2>/dev/null)"; then
    return 2
  fi

  while IFS= read -r listed_volume; do
    [[ -z "$listed_volume" ]] && continue
    if [[ "$listed_volume" == "$volume_name" ]]; then
      return 0
    fi
  done <<< "$volume_list"

  return 1
}

# Remove (or preserve) hidden volumes during a container rebuild.
#
# Default rebuild drops hidden volumes for a clean slate (fresh dependency
# install, no stale/compromised caches). If removal fails but the volume is
# still present, the rebuild aborts rather than risk reusing suspect state.
dce_rebuild_handle_hidden_volumes() {
  local project="$1"
  local keep_hidden_volumes="$2"
  shift 2

  local -a hidden_paths=("$@")
  local hidden_path=""
  local hidden_volume=""
  local exists_rc=0

  if [[ ${#hidden_paths[@]} -eq 0 ]]; then
    return 0
  fi

  echo ""
  if [[ "$keep_hidden_volumes" == "true" ]]; then
    echo "  -> Preserving hidden volumes (--keep-hidden-volumes):"
    for hidden_path in "${hidden_paths[@]}"; do
      [[ -z "$hidden_path" ]] && continue
      hidden_volume="$(dce_hidden_volume_name "$project" "$hidden_path")"
      echo "     ~ Kept: $hidden_volume ($hidden_path)"
    done
    return 0
  fi

  echo "  -> Removing hidden volumes for clean rebuild..."
  for hidden_path in "${hidden_paths[@]}"; do
    [[ -z "$hidden_path" ]] && continue
    hidden_volume="$(dce_hidden_volume_name "$project" "$hidden_path")"

    if backend_remove_volume "$hidden_volume" 2>/dev/null; then
      echo "     ✓ Removed: $hidden_volume ($hidden_path)"
      continue
    fi

    if dce_hidden_volume_exists "$hidden_volume"; then
      echo "ERROR: Failed to remove hidden volume still present: $hidden_volume ($hidden_path)"
      echo "       Aborting rebuild to avoid reusing possibly compromised hidden state."
      return 1
    else
      exists_rc=$?
    fi

    if [[ "$exists_rc" -eq 2 ]]; then
      echo "ERROR: Failed to verify hidden volume removal: $hidden_volume ($hidden_path)"
      echo "       Aborting rebuild to avoid reusing possibly compromised hidden state."
      return 1
    fi

    echo "     (already gone: $hidden_volume)"
  done
}

# Verify each hidden path is actually backed by a separate volume (different
# device than /workspace). Catches the case where a named volume was requested
# but the backend silently bind-mounted the host path instead.
dce_hidden_mounts_verified() {
  local project="$1"
  shift

  local hidden_path=""
  local target=""
  local rc=0

  for hidden_path in "$@"; do
    [[ -z "$hidden_path" ]] && continue
    target="/workspace/$hidden_path"

    # Detect the mount point from the mount table (findmnt -M), NOT by comparing
    # st_dev of the path vs /workspace: on a single-filesystem Linux host (most
    # servers, CI runners, WSL2) the repo bind mount and the named-volume mount
    # share one underlying device, so `stat -c %d` reads equal for both and the
    # mount is falsely reported absent -- breaking `dce new --hide` there. macOS
    # Docker Desktop only appeared to work because its host bind and VM volume
    # sit on different devices. findmnt reads /proc/self/mountinfo, which is
    # correct regardless of the underlying device layout.
    # shellcheck disable=SC2016  # runs in the container's sh -c; only ${target} is host-side.
    backend_exec "$project" sh -c \
      'findmnt -M "'"${target}"'" >/dev/null 2>&1' \
      2>/dev/null || rc=1
  done

  return $rc
}

# Ensure hidden-volume mounts are live, restarting the container if needed.
#
# Some backends (e.g. OrbStack) occasionally apply named-volume mounts only
# after a restart, so we verify, then stop/start once and re-verify before
# giving up. Called after both create and start.
dce_ensure_hidden_mounts() {
  local project="$1"
  shift

  if [[ $# -eq 0 ]]; then
    return 0
  fi

  local attempt=0
  local max_attempts=2

  while true; do
    if dce_hidden_mounts_verified "$project" "$@"; then
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: Hidden volume mounts not active after restart." >&2
      echo "       Named volumes are configured but not applied to the container." >&2
      echo "       This is a known issue with some container backends (e.g. OrbStack)." >&2
      echo "       Try: dce stop $project && dce start $project" >&2
      return 1
    fi

    echo "  -> Hidden volume mounts not active; restarting container to reapply..."
    backend_stop "$project"
    sleep 1
    backend_start "$project"
    sleep 2
  done
}
