#!/usr/bin/env bash
# =============================================================================
# lib/common.sh - Shared helpers for host-side dc scripts.
#
# Sourced (never executed directly) by every script under scripts/. Enforces the
# Bash 4+ requirement, guards against double-sourcing, and exposes the dc_*
# helper API used across the codebase: global config loading, scope/hidden-path
# normalization, deterministic image-tag derivation, and hidden-volume handling.
#
# Key concepts this file encodes:
#   - Overlay scopes  -> see dc_effective_scopes_csv / dc_image_ref_from_scopes
#   - Hidden volumes  -> see dc_hidden_volume_name and friends
#   - Per-project cfg -> ~/.config/dev-containers/<name>/config (key=value)
# =============================================================================

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERROR: dev-containers requires Bash 4+ (scripts must run under bash)." >&2
  exit 1
fi

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: dev-containers requires Bash 4+ (current: $BASH_VERSION)" >&2
  echo "  macOS: brew install bash" >&2
  exit 1
fi

# Include guard: scripts chain-source lib files; this makes re-sourcing a no-op
# so helpers and globals are defined exactly once per shell.
if [[ -n "${_DC_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_SH_LOADED=1

# Print an error message to stderr and exit non-zero. Standard failure path.
dc_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Print a non-fatal warning to stderr.
dc_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

# Join positional arguments with the given separator (first arg). Echoes the
# result without a trailing newline; empty args are preserved as empty fields.
dc_join_by() {
  local separator="$1"
  shift

  local out=""
  local item=""
  for item in "$@"; do
    if [[ -n "$out" ]]; then
      out+="$separator"
    fi
    out+="$item"
  done

  printf '%s' "$out"
}

# Canonicalize a path to an absolute, symlink-resolved form. Works for both
# existing directories and not-yet-existing file paths (resolving the parent).
dc_resolve_path() {
  local input="$1"

  if [[ -d "$input" ]]; then
    (cd -P "$input" && pwd)
    return $?
  fi

  local parent=""
  parent="$(cd -P "$(dirname "$input")" && pwd)" || return 1
  printf '%s/%s\n' "$parent" "$(basename "$input")"
}

# Path to the global dev-containers config file (DC_OVERLAYS_DIR lives here).
dc_global_config_path() {
  printf '%s/.config/dev-containers/config\n' "$HOME"
}

# Default overlays root used by setup.sh when bootstrapping global config.
dc_overlay_default_root() {
  printf '%s/.config/dev-containers/overlays\n' "$HOME"
}

# Source and validate the global config, exporting DC_OVERLAYS_DIR.
#
# DC_OVERLAYS_DIR is deliberately unset before sourcing so a stale or malicious
# value can't leak in from the environment; it is then normalized (~ and
# relative paths are resolved against the config dir) and required to exist.
dc_load_global_config() {
  local cfg=""
  cfg="$(dc_global_config_path)"

  if [[ ! -f "$cfg" ]]; then
    dc_die "Global config not found: ~/.config/dev-containers/config
Run: scripts/setup.sh"
  fi

  unset DC_OVERLAYS_DIR

  # shellcheck disable=SC1090
  source "$cfg"

  if [[ -z "${DC_OVERLAYS_DIR:-}" ]]; then
    dc_die "DC_OVERLAYS_DIR is not set in ~/.config/dev-containers/config
Set DC_OVERLAYS_DIR and rerun scripts/setup.sh"
  fi

  if [[ "$DC_OVERLAYS_DIR" == "~" || "$DC_OVERLAYS_DIR" == "~/"* ]]; then
    DC_OVERLAYS_DIR="$HOME${DC_OVERLAYS_DIR#\~}"
  elif [[ "$DC_OVERLAYS_DIR" != /* ]]; then
    DC_OVERLAYS_DIR="$HOME/.config/dev-containers/$DC_OVERLAYS_DIR"
  fi

  if [[ ! -d "$DC_OVERLAYS_DIR" ]]; then
    dc_die "Overlay root does not exist: $DC_OVERLAYS_DIR
Run: scripts/setup.sh"
  fi
}

# Echo the SHA-256 hex digest of a string.
#
# Tries sha256sum (Linux), shasum (macOS default), then openssl, so the same
# code works across all supported host platforms without extra dependencies.
dc_sha256_hex() {
  local input="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    set -- $(printf '%s' "$input" | sha256sum)
    printf '%s\n' "$1"
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    set -- $(printf '%s' "$input" | shasum -a 256)
    printf '%s\n' "$1"
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    set -- $(printf '%s' "$input" | openssl dgst -sha256 -r)
    printf '%s\n' "$1"
    return 0
  fi

  dc_die "No SHA-256 tool available (sha256sum, shasum, or openssl required)."
}

# Validate a single overlay scope name against the allowed identifier pattern.
dc_validate_scope_name() {
  local scope="$1"
  [[ "$scope" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# Normalize a comma-separated scope list: trim/lowercase each token, drop
# empties, reject invalid names, and de-duplicate while preserving order.
dc_normalize_scopes_csv() {
  local input="$1"

  local -a normalized=()
  local -a raw_scopes=()
  declare -A seen=()
  local raw_scope=""
  local scope=""

  IFS=',' read -r -a raw_scopes <<< "$input"
  for raw_scope in "${raw_scopes[@]}"; do
    scope="${raw_scope//[[:space:]]/}"
    scope="${scope,,}"
    [[ -z "$scope" ]] && continue

    if ! dc_validate_scope_name "$scope"; then
      printf 'ERROR: Invalid scope name: %s\n' "$scope" >&2
      printf '  Allowed pattern: ^[a-z0-9][a-z0-9._-]*$\n' >&2
      return 1
    fi

    if [[ -n "${seen[$scope]-}" ]]; then
      continue
    fi

    seen["$scope"]=1
    normalized+=("$scope")
  done

  dc_join_by ',' "${normalized[@]}"
}

# Validate one hidden path. Hidden paths are mounted as named volumes under
# /workspace and embedded in backend mount flags, so they must be relative,
# traversal-free, contain no whitespace or ':' (which would break flag parsing),
# and use only filename-safe characters.
dc_validate_hidden_path() {
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
dc_normalize_hidden_paths_csv() {
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

    if ! dc_validate_hidden_path "$path"; then
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

  dc_join_by ',' "${normalized[@]}"
}

# Normalize hidden paths across multiple --hide values (which may repeat).
# Merges and de-duplicates all values into one canonical CSV, echoing empty
# when no values are supplied.
dc_normalize_hidden_paths_values() {
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
    if ! normalized_csv="$(dc_normalize_hidden_paths_csv "$raw_value")"; then
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

  dc_join_by ',' "${normalized_all[@]}"
}

# Build the deterministic managed-volume name for a project hidden path.
#
# Format: dc-hide-<project-slug>-<12hex>. The name is derived purely from the
# project and path (not random) so the same hidden path reliably maps to the
# same volume across creates, starts, and rebuilds, letting us find/remove it.
dc_hidden_volume_name() {
  local project="$1"
  local hidden_path="$2"

  local project_slug=""
  project_slug="$(dc_project_slug "$project")"

  local key="hide-v1|$project|$hidden_path"
  local hash=""
  hash="$(dc_sha256_hex "$key")"
  hash="${hash:0:12}"

  printf 'dc-hide-%s-%s\n' "$project_slug" "$hash"
}

# Check whether a named volume exists in the backend's volume store.
# Returns 0 (exists), 1 (absent), or 2 (the backend list call itself failed).
dc_hidden_volume_exists() {
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
dc_rebuild_handle_hidden_volumes() {
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
      hidden_volume="$(dc_hidden_volume_name "$project" "$hidden_path")"
      echo "     ~ Kept: $hidden_volume ($hidden_path)"
    done
    return 0
  fi

  echo "  -> Removing hidden volumes for clean rebuild..."
  for hidden_path in "${hidden_paths[@]}"; do
    [[ -z "$hidden_path" ]] && continue
    hidden_volume="$(dc_hidden_volume_name "$project" "$hidden_path")"

    if backend_remove_volume "$hidden_volume" 2>/dev/null; then
      echo "     ✓ Removed: $hidden_volume ($hidden_path)"
      continue
    fi

    if dc_hidden_volume_exists "$hidden_volume"; then
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
dc_hidden_mounts_verified() {
  local project="$1"
  shift

  local hidden_path=""
  local target=""
  local rc=0

  for hidden_path in "$@"; do
    [[ -z "$hidden_path" ]] && continue
    target="/workspace/$hidden_path"

    backend_exec "$project" sh -c \
      '[ -d "'"${target}"'" ] && [ "$(stat -c %d /workspace)" != "$(stat -c %d "'"${target}"'")" ]' \
      2>/dev/null || rc=1
  done

  return $rc
}

# Ensure hidden-volume mounts are live, restarting the container if needed.
#
# Some backends (e.g. OrbStack) occasionally apply named-volume mounts only
# after a restart, so we verify, then stop/start once and re-verify before
# giving up. Called after both create and start.
dc_ensure_hidden_mounts() {
  local project="$1"
  shift

  if [[ $# -eq 0 ]]; then
    return 0
  fi

  local attempt=0
  local max_attempts=2

  while true; do
    if dc_hidden_mounts_verified "$project" "$@"; then
      return 0
    fi

    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
      echo "ERROR: Hidden volume mounts not active after restart." >&2
      echo "       Named volumes are configured but not applied to the container." >&2
      echo "       This is a known issue with some container backends (e.g. OrbStack)." >&2
      echo "       Try: dc stop $project && dc start $project" >&2
      return 1
    fi

    echo "  -> Hidden volume mounts not active; restarting container to reapply..."
    backend_stop "$project"
    sleep 1
    backend_start "$project"
    sleep 2
  done
}

# Derive a filesystem-safe slug from a project name (lowercased, non-alnum
# collapsed to '-', trimmed, capped at 24 chars). Used to build volume names.
dc_project_slug() {
  local project="$1"
  local project_slug="${project,,}"

  project_slug="${project_slug//[^a-z0-9]/-}"
  while [[ "$project_slug" == *--* ]]; do
    project_slug="${project_slug//--/-}"
  done
  project_slug="${project_slug#-}"
  project_slug="${project_slug%-}"
  [[ -n "$project_slug" ]] || project_slug="project"
  project_slug="${project_slug:0:24}"

  printf '%s\n' "$project_slug"
}

# Return whether an overlay scope exists in either team/ or user/ overlays.
dc_scope_exists() {
  local overlays_dir="$1"
  local scope="$2"

  [[ -f "$overlays_dir/team/Containerfile.$scope" || -f "$overlays_dir/user/Containerfile.$scope" ]]
}

# Resolve the final, effective scope list for a create/rebuild.
#
# Implements the layering contract: requested named scopes must exist in team/
# or user/ (missing ones fail fast), "all" is never taken from the request but
# auto-prepended when a Containerfile.all exists. The resulting order drives
# overlay composition and image-tag derivation.
dc_effective_scopes_csv() {
  local overlays_dir="$1"
  local requested_scopes_csv="$2"

  local normalized_csv=""
  if ! normalized_csv="$(dc_normalize_scopes_csv "$requested_scopes_csv")"; then
    return 1
  fi

  local -a requested=()
  local -a selected=()
  local -a missing=()
  local -a effective=()
  local scope=""

  IFS=',' read -r -a requested <<< "$normalized_csv"
  for scope in "${requested[@]}"; do
    [[ -z "$scope" ]] && continue
    [[ "$scope" == "all" ]] && continue

    if dc_scope_exists "$overlays_dir" "$scope"; then
      selected+=("$scope")
    else
      missing+=("$scope")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'ERROR: Missing overlay scope(s): %s\n' "$(dc_join_by ', ' "${missing[@]}")" >&2
    printf '  Add Containerfile.<scope> under %s/team or %s/user\n' "$overlays_dir" "$overlays_dir" >&2
    return 1
  fi

  if dc_scope_exists "$overlays_dir" "all"; then
    effective+=("all")
  fi

  effective+=("${selected[@]}")

  dc_join_by ',' "${effective[@]}"
}

# Derive the deterministic image tag for a scope set.
#
# No overlays -> dev-base:latest (the shared base). Otherwise the effective
# scopes are hashed into dev-img-<16hex>:latest so identical scope sets always
# resolve to one reusable, shareable derived image across projects/machines.
dc_image_ref_from_scopes() {
  local overlays_dir="$1"
  local requested_scopes_csv="$2"

  local effective_scopes_csv=""
  if ! effective_scopes_csv="$(dc_effective_scopes_csv "$overlays_dir" "$requested_scopes_csv")"; then
    return 1
  fi

  if [[ -z "$effective_scopes_csv" ]]; then
    printf 'dev-base:latest\n'
    return 0
  fi

  local -a scopes=()
  local scope=""
  local scope_key="v1"

  IFS=',' read -r -a scopes <<< "$effective_scopes_csv"
  for scope in "${scopes[@]}"; do
    [[ -z "$scope" ]] && continue
    scope_key+="|${#scope}:$scope"
  done

  local hash=""
  hash="$(dc_sha256_hex "$scope_key")"
  hash="${hash:0:16}"

  printf 'dev-img-%s:latest\n' "$hash"
}

# Extract the 16-hex hash from a dev-img-* reference, or fail for other refs.
dc_image_hash_from_ref() {
  local image_ref="$1"
  local repo="${image_ref%%:*}"

  if [[ "$repo" =~ ^dev-img-([0-9a-f]{16})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

# Set or replace a single KEY="value" line in a project config file safely.
# Rewrites via a temp file and atomic mv, escaping backslashes/quotes so the
# value round-trips through a later `source`. Appends the key if absent.
dc_set_config_key() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  local escaped="$value"
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"

  local tmp_file="${config_file}.tmp.$$"
  local updated=0
  local line=""

  : > "$tmp_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s="%s"\n' "$key" "$escaped" >> "$tmp_file"
      updated=1
    else
      printf '%s\n' "$line" >> "$tmp_file"
    fi
  done < "$config_file"

  if [[ "$updated" -eq 0 ]]; then
    printf '%s="%s"\n' "$key" "$escaped" >> "$tmp_file"
  fi

  mv "$tmp_file" "$config_file"
}
