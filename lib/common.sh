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

# Single source of truth for the dev-containers version. Sourced by every host
# script (via the dc dispatcher and each subcommand), so both `dc --version` and
# any subcommand can read $DC_VERSION. Bump this in the same commit that tags a
# release (e.g. `git tag v0.1.0`) so the embedded string tracks the git tag.
declare -gr DC_VERSION="0.1.0"

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

# Validate an IANA timezone name: only the characters that legitimately appear in
# zone names (letters, digits, '_', '/', '+', '-'). Rejects whitespace, colons,
# and every shell metacharacter unconditionally -- the value is embedded in a
# backend `--env TZ=` flag, so it can never be allowed to escape the assignment.
dc_timezone_name_is_valid() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9_+./-]+$ ]]
}

# Extract the zone name from a /etc/localtime symlink target. Cross-platform by
# design: both conventions embed the zone after a "zoneinfo/" segment --
#   Linux: /usr/share/zoneinfo/<Area>/<Location>
#   macOS: /var/db/timezone/zoneinfo/<Area>/<Location>
# Returns 0 with the zone on stdout when a clean segment is found; returns 1 for
# regular-file copies, missing paths, non-zoneinfo links, or invalid names.
dc_timezone_from_localtime_file() {
  local path="$1"
  local target=""
  local zone=""

  [[ -L "$path" ]] || return 1
  target="$(readlink "$path" 2>/dev/null)" || return 1
  [[ -n "$target" ]] || return 1

  if [[ "$target" == *zoneinfo/* ]]; then
    zone="${target##*zoneinfo/}"
    zone="${zone%%/}"
    if dc_timezone_name_is_valid "$zone"; then
      printf '%s\n' "$zone"
      return 0
    fi
  fi

  return 1
}

# Resolve the host's IANA timezone name so a container can mirror it.
#
# Selection order: an explicit $TZ (when it passes the strict zone-name check)
# is honored first; otherwise the zone is parsed from /etc/localtime. When
# neither yields a clean value, nothing is echoed and the call returns non-zero
# so the caller simply omits `--env TZ` and leaves the container on the image
# default. An explicitly-set but invalid $TZ is warned about and rejected rather
# than silently substituted from /etc/localtime (an explicit value is intentional).
dc_host_timezone() {
  local tz="${TZ:-}"

  if [[ -n "$tz" ]]; then
    if dc_timezone_name_is_valid "$tz"; then
      printf '%s\n' "$tz"
      return 0
    fi
    dc_warn "Ignoring invalid TZ value: $tz"
    return 1
  fi

  dc_timezone_from_localtime_file "/etc/localtime"
}

# Path to the global dev-containers config file (DC_TEAM_DIR/DC_USER_DIR live here).
dc_global_config_path() {
  printf '%s/.config/dev-containers/config\n' "$HOME"
}

# Default team/user roots used by setup.sh when bootstrapping global config. Each
# is an independent root that may be its own git repo, containing both overlays/
# (image layers) and container-recipes/ (per-container-name recipe files).
dc_team_default_root() {
  printf '%s/.config/dev-containers/team\n' "$HOME"
}

dc_user_default_root() {
  printf '%s/.config/dev-containers/user\n' "$HOME"
}

# Single source of truth for the four leaf directories under the two roots. The
# root variables must be set (dc_load_global_config guarantees this for runtime;
# callers that bypass the loader must set them first).
dc_team_overlays_dir() {
  printf '%s/overlays\n' "$DC_TEAM_DIR"
}

dc_user_overlays_dir() {
  printf '%s/overlays\n' "$DC_USER_DIR"
}

dc_team_recipes_dir() {
  printf '%s/container-recipes\n' "$DC_TEAM_DIR"
}

dc_user_recipes_dir() {
  printf '%s/container-recipes\n' "$DC_USER_DIR"
}

# Normalize a global-config root path in place by variable name: expand a leading
# ~ and resolve a relative path against the config dir. Shared by the two-root
# loader so the exact rule lives in one place (previously it was triplicated).
_dc_normalize_config_root() {
  local varname="$1"
  local val="${!varname}"
  if [[ "$val" == "~" || "$val" == "~/"* ]]; then
    val="$HOME${val#\~}"
  elif [[ "$val" != /* ]]; then
    val="$HOME/.config/dev-containers/$val"
  fi
  printf -v "$varname" '%s' "$val"
}

# Load and validate the global config, exporting DC_TEAM_DIR and DC_USER_DIR.
#
# The global config is parsed with dc_config_extract_scalar (no `source`), so a
# malicious or corrupted file cannot execute code. Both roots are deliberately
# unset first so a stale/environment value can't leak in; each is then normalized
# (~ and relative paths resolved against the config dir) and required to exist.
# Each root may be its own git repo holding both overlays/ and container-recipes/.
dc_load_global_config() {
  local cfg=""
  cfg="$(dc_global_config_path)"

  if [[ ! -f "$cfg" ]]; then
    dc_die "Global config not found: ~/.config/dev-containers/config
Run: scripts/setup.sh"
  fi

  if [[ -L "$cfg" ]]; then
    dc_die "Refusing to load global config via symlink: $cfg"
  fi

  unset DC_TEAM_DIR DC_USER_DIR

  if ! DC_TEAM_DIR="$(dc_config_extract_scalar "$cfg" DC_TEAM_DIR)"; then
    dc_die "DC_TEAM_DIR is not set (or is not a clean quoted value) in ~/.config/dev-containers/config
Set DC_TEAM_DIR and rerun scripts/setup.sh"
  fi
  if ! DC_USER_DIR="$(dc_config_extract_scalar "$cfg" DC_USER_DIR)"; then
    dc_die "DC_USER_DIR is not set (or is not a clean quoted value) in ~/.config/dev-containers/config
Set DC_USER_DIR and rerun scripts/setup.sh"
  fi

  if [[ -z "${DC_TEAM_DIR:-}" ]]; then
    dc_die "DC_TEAM_DIR is not set in ~/.config/dev-containers/config
Set DC_TEAM_DIR and rerun scripts/setup.sh"
  fi
  if [[ -z "${DC_USER_DIR:-}" ]]; then
    dc_die "DC_USER_DIR is not set in ~/.config/dev-containers/config
Set DC_USER_DIR and rerun scripts/setup.sh"
  fi

  _dc_normalize_config_root DC_TEAM_DIR
  _dc_normalize_config_root DC_USER_DIR

  if [[ ! -d "$DC_TEAM_DIR" ]]; then
    dc_die "Team root does not exist: $DC_TEAM_DIR
Run: scripts/setup.sh"
  fi
  if [[ ! -d "$DC_USER_DIR" ]]; then
    dc_die "User root does not exist: $DC_USER_DIR
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

# Echo the SHA-256 hex digest of a file's raw bytes.
#
# Companion to dc_sha256_hex for the cases (provenance fingerprints) where the
# input is a file and every byte -- including trailing newlines -- must count.
# Same tool fallback chain as dc_sha256_hex so it works on every supported host.
dc_sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    set -- $(sha256sum "$file")
    printf '%s\n' "$1"
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    set -- $(shasum -a 256 "$file")
    printf '%s\n' "$1"
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    set -- $(openssl dgst -sha256 -r "$file")
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

# Return whether an overlay scope exists in either team or user overlays dir.
# Each dir is the resolved leaf overlays/ directory of a root (see
# dc_team_overlays_dir / dc_user_overlays_dir).
dc_scope_exists() {
  local team_od="$1"
  local user_od="$2"
  local scope="$3"

  [[ -f "$team_od/Containerfile.$scope" || -f "$user_od/Containerfile.$scope" ]]
}

# Resolve the final, effective scope list for a create/rebuild.
#
# Implements the layering contract: requested named scopes must exist in the
# team or user overlays dir (missing ones fail fast), "all" is never taken from
# the request but auto-prepended when a Containerfile.all exists. The resulting
# order drives overlay composition and image-tag derivation.
dc_effective_scopes_csv() {
  local team_od="$1"
  local user_od="$2"
  local requested_scopes_csv="$3"

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

    if dc_scope_exists "$team_od" "$user_od" "$scope"; then
      selected+=("$scope")
    else
      missing+=("$scope")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'ERROR: Missing overlay scope(s): %s\n' "$(dc_join_by ', ' "${missing[@]}")" >&2
    printf '  Add Containerfile.<scope> under %s or %s\n' "$team_od" "$user_od" >&2
    return 1
  fi

  if dc_scope_exists "$team_od" "$user_od" "all"; then
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
  local team_od="$1"
  local user_od="$2"
  local requested_scopes_csv="$3"

  local effective_scopes_csv=""
  if ! effective_scopes_csv="$(dc_effective_scopes_csv "$team_od" "$user_od" "$requested_scopes_csv")"; then
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

# =============================================================================
# Image provenance (plans/versioning.md). Best-effort provenance capture so a
# built dev-img-* image can be traced back to the overlay state (team/user git
# commits + file content fingerprints) that produced it. Detection is per-root
# and independent for team and user: each side always yields a content_hash,
# and additionally yields git commit/dirty/source when its root (DC_TEAM_DIR /
# DC_USER_DIR) is a git checkout. The dirty check is scoped to the overlays/
# subtree so container-recipes/ edits never contaminate overlay provenance.
# These are host-side helpers; none needs a container backend.
# =============================================================================

# Escape a string for safe embedding in a JSON string value. Backslash and
# double-quote are escaped; the named control chars use their JSON short forms;
# any other control char (< 0x20) becomes \u00XX. Values fed in here (commit
# SHAs, hex hashes, scope names, ISO timestamps, git remote URLs) are normally
# already clean, so this is defensive -- it keeps provenance.jsonl valid even
# if a future field carries an unusual byte.
dc_json_escape() {
  local s="$1"
  local out=""
  local i ch ord code

  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      \\) out+='\\' ;;
      '"')  out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      *)
        ord=$(printf '%d' "'$ch" 2>/dev/null || printf '64')
        if (( ord < 32 )); then
          printf -v code '%04x' "$ord"
          out+="\\u$code"
        else
          out+="$ch"
        fi
        ;;
    esac
  done

  printf '%s' "$out"
}

# Reduce a value to the safe subset for a Dockerfile LABEL double-quoted value.
# Dockerfile label values would otherwise interpret `"` (ends the string), `\`
# (escape), and `$` (ARG/ENV expansion); backtick is stripped defensively too.
# Control chars are removed. Our values are inherently safe, so this is a guard
# against surprises (e.g. an exotic git remote URL). Stripping (not escaping)
# keeps the label inert without depending on Dockerfile escape quirks.
dc_label_scrub() {
  local s="$1"
  local out=""
  local i ch ord

  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    if [[ "$ch" == '"' || "$ch" == '\' || "$ch" == '$' || "$ch" == '`' ]]; then
      continue
    fi
    ord=$(printf '%d' "'$ch" 2>/dev/null || printf '64')
    (( ord < 32 )) && continue
    out+="$ch"
  done

  printf '%s' "$out"
}

# Per-side content fingerprint for a set of EFFECTIVE scopes. Iterates the
# canonical order (all first, then listed scopes -- exactly what composes) and,
# for each existing fragment under $overlays_dir (the resolved leaf overlays/
# directory of one root), folds "v1|<scope>|<sha256(file bytes)>" into the hash
# input. Returns empty when the side contributes no fragment for these scopes
# (e.g. that side has no Containerfile.<scope>). The 12-hex truncation matches
# the label contract; the per-fragment "v1" prefix leaves room to evolve the
# scheme.
dc_provenance_content_hash() {
  local overlays_dir="$1"
  local effective_scopes_csv="$2"

  local acc=""
  local scope="" file=""
  local -a scopes=()
  [[ -n "$effective_scopes_csv" ]] && IFS=',' read -r -a scopes <<< "$effective_scopes_csv"

  for scope in "${scopes[@]}"; do
    [[ -n "$scope" ]] || continue
    file="$overlays_dir/Containerfile.$scope"
    [[ -f "$file" ]] || continue
    acc+="v1|$scope|$(dc_sha256_file "$file")|"
  done

  [[ -n "$acc" ]] || return 0
  local hash=""
  hash="$(dc_sha256_hex "$acc")"
  printf '%s\n' "${hash:0:12}"
}

# Fold both namespaces' per-side fingerprints into one full (64-hex) hash. Used
# as the stable, always-present combined identifier (label content.hash and the
# JSONL dedup key). Order is fixed (team then user) so the result is stable.
dc_provenance_combined_hash() {
  local team_hash="$1"
  local user_hash="$2"

  dc_sha256_hex "v1|${team_hash}|${user_hash}"
}

# Git HEAD full SHA of $dir, or empty when $dir is not a git checkout. Always
# exits 0 (best-effort: provenance never fails a build). The FULL sha (not the
# abbreviated form) is stored so the log/labels hold the canonical identifier --
# short shas are a display concern, handled at read time.
dc_provenance_git_commit() {
  local dir="$1"

  [[ -d "$dir" ]] || { printf ''; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return 0; }
  git -C "$dir" rev-parse HEAD 2>/dev/null || printf ''
}

# "true" / "false" when $dir is a git checkout (any tracked change, staged
# change, or untracked file vs HEAD counts as dirty), or empty when not under
# git. Uses `git status --porcelain` so an untracked new Containerfile.<scope>
# is also flagged (its bytes already changed the content_hash; this mirrors
# that as a human-readable warning).
#
# An optional second argument is a pathspec limiting the dirty check to that
# subtree. Each root now holds both overlays/ and container-recipes/, so image
# provenance passes "overlays" so a recipe-only edit does not mark overlay
# provenance dirty. Empty/omitted pathspec checks the whole work tree.
dc_provenance_git_dirty() {
  local dir="$1"
  local pathspec="${2:-}"

  [[ -d "$dir" ]] || { printf ''; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return 0; }
  local status_out
  if [[ -n "$pathspec" ]]; then
    status_out="$(git -C "$dir" status --porcelain -- "$pathspec" 2>/dev/null)"
  else
    status_out="$(git -C "$dir" status --porcelain 2>/dev/null)"
  fi
  if [[ -n "$status_out" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# configured remote.origin.url for $dir, or empty when not under git / no remote.
dc_provenance_git_source() {
  local dir="$1"

  [[ -d "$dir" ]] || { printf ''; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return 0; }
  git -C "$dir" config --get remote.origin.url 2>/dev/null || printf ''
}

# Render a scopes CSV as a JSON array string, e.g. ["nodejs","golang"] / [].
# Each element is JSON-escaped (scope names are charset-restricted, but escape
# anyway so the output is always valid JSON).
dc_provenance_scopes_json() {
  local csv="$1"
  local out="[" first=1 scope=""
  local -a scopes=()
  [[ -n "$csv" ]] && IFS=',' read -r -a scopes <<< "$csv"

  for scope in "${scopes[@]}"; do
    [[ -n "$scope" ]] || continue
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="\"$(dc_json_escape "$scope")\""
  done

  out+="]"
  printf '%s' "$out"
}

# Path to a project's provenance log.
dc_provenance_log_path() {
  printf '%s/.config/dev-containers/%s/provenance.jsonl\n' "$HOME" "$1"
}

# Append one provenance entry to the project's JSONL log, deduping on change.
#
# Recomputes the overlay-derived values from the team/user roots ($team_root,
# $user_root -- DC_TEAM_DIR/DC_USER_DIR) + $scopes_csv (the same source of truth
# compose-containerfile.sh uses for the image labels) and merges in $base_id
# (the caller-supplied local dev-base image Id) plus the build timestamp. Dedup
# key is (combined content_hash, base id): every overlay byte and scope is
# already encoded in content_hash, and base id covers a base rebuild, so the two
# together uniquely identify an image state. If the last logged line matches,
# the append is skipped (no churn from no-op rebuilds or rebuild-container). The
# file is created owner-only (chmod 600), matching the security posture of the
# project config.
#
# Provenance signals stay overlay-scoped even though each root now also holds
# container-recipes/: the content hash is computed from overlays/ fragments
# only, git_commit is the repo HEAD, and git_dirty uses an "overlays" pathspec
# so a recipe-only edit does not contaminate overlay provenance.
dc_log_provenance() {
  local project="$1"
  local image_ref="$2"
  local action="$3"
  local team_root="$4"
  local user_root="$5"
  local scopes_csv="$6"
  local base_id="$7"

  local team_od="" user_od=""
  team_od="$team_root/overlays"
  user_od="$user_root/overlays"

  local eff=""
  eff="$(dc_effective_scopes_csv "$team_od" "$user_od" "$scopes_csv" 2>/dev/null || true)"

  local team_ch="" user_ch="" combined=""
  team_ch="$(dc_provenance_content_hash "$team_od" "$eff")"
  user_ch="$(dc_provenance_content_hash "$user_od" "$eff")"
  combined="$(dc_provenance_combined_hash "$team_ch" "$user_ch")"

  local team_commit="" team_dirty="" team_source=""
  local user_commit="" user_dirty="" user_source=""
  team_commit="$(dc_provenance_git_commit "$team_root")"
  team_dirty="$(dc_provenance_git_dirty "$team_root" overlays)"
  team_source="$(dc_provenance_git_source "$team_root")"
  user_commit="$(dc_provenance_git_commit "$user_root")"
  user_dirty="$(dc_provenance_git_dirty "$user_root" overlays)"
  user_source="$(dc_provenance_git_source "$user_root")"

  # dirty is a bare JSON boolean when under git, else an empty JSON string.
  local tdj="" udj=""
  if [[ "$team_dirty" == "true" || "$team_dirty" == "false" ]]; then tdj="$team_dirty"; else tdj='""'; fi
  if [[ "$user_dirty" == "true" || "$user_dirty" == "false" ]]; then udj="$user_dirty"; else udj='""'; fi

  local now=""
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local team_obj="" user_obj="" base_obj="" scopes_json=""
  team_obj="{\"content_hash\":\"$(dc_json_escape "$team_ch")\",\"git_commit\":\"$(dc_json_escape "$team_commit")\",\"git_dirty\":$tdj,\"source\":\"$(dc_json_escape "$team_source")\"}"
  user_obj="{\"content_hash\":\"$(dc_json_escape "$user_ch")\",\"git_commit\":\"$(dc_json_escape "$user_commit")\",\"git_dirty\":$udj,\"source\":\"$(dc_json_escape "$user_source")\"}"
  base_obj="{\"image\":\"dev-base:latest\",\"id\":\"$(dc_json_escape "$base_id")\"}"
  scopes_json="$(dc_provenance_scopes_json "$eff")"

  # Compact JSONL; content_hash is emitted last so dedup can find it via tail.
  local line=""
  line="{\"ts\":\"$(dc_json_escape "$now")\",\"action\":\"$(dc_json_escape "$action")\",\"image_ref\":\"$(dc_json_escape "$image_ref")\",\"scopes\":$scopes_json,\"dc_version\":\"$(dc_json_escape "$DC_VERSION")\",\"base\":$base_obj,\"team\":$team_obj,\"user\":$user_obj,\"content_hash\":\"$(dc_json_escape "$combined")\"}"

  local log_path=""
  log_path="$(dc_provenance_log_path "$project")"

  # Dedup against the last logged line on (content_hash, base id).
  local last=""
  [[ -f "$log_path" ]] && last="$(tail -n1 "$log_path" 2>/dev/null || true)"
  if [[ -n "$last" ]]; then
    local last_ch="" last_base="" cur_ch="" cur_base=""
    last_ch="$(printf '%s' "$last" | grep -oE '"content_hash":"[^"]*"' | tail -n1 || true)"
    last_base="$(printf '%s' "$last" | grep -oE '"id":"[^"]*"' | head -n1 || true)"
    cur_ch="\"content_hash\":\"$(dc_json_escape "$combined")\""
    cur_base="\"id\":\"$(dc_json_escape "$base_id")\""
    if [[ -n "$last_ch" && "$last_ch" == "$cur_ch" && "$last_base" == "$cur_base" ]]; then
      return 0
    fi
  fi

  mkdir -p "$(dirname "$log_path")"
  printf '%s\n' "$line" >> "$log_path"
  chmod 600 "$log_path"
}

# Known scalar and array keys permitted in a project config file. The loader
# rejects any key outside these sets so an attacker cannot introduce arbitrary
# assignments. Keep in sync with scripts/new-container.sh config emission.
declare -gra _DC_CONFIG_SCALAR_KEYS=(
  CONTAINER_PROJECT CONTAINER_OVERLAY_SCOPES CONTAINER_IMAGE CONTAINER_BACKEND
  CONTAINER_CPUS CONTAINER_MEMORY REPOS_DIR SECRET_DIR
  SSH_KEY_PATH TOKEN_FILE NPMRC_PATH
)
declare -ga _DC_CONFIG_ARRAY_KEYS=(PORTS CONTAINER_HIDDEN_PATHS CONTAINER_NETWORKS)

# Supported container backend names (mirrors lib/container-backend.sh selection).
declare -ga _DC_KNOWN_BACKENDS=(apple docker orbstack colima podman)

# Validate a CONTAINER_CPUS value: empty (default) or a positive decimal such as
# 1, 2, 1.5, 0.25. Rejects zero/negative, exponent notation, whitespace, and any
# shell metacharacter. Prints a diagnostic and returns 1 on rejection.
dc_validate_cpus_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf 'ERROR: Invalid CPU value: %q\n' "$value" >&2
    printf '  Expected a positive decimal (e.g. 1, 2, 1.5, 0.25); no exponents or units.\n' >&2
    return 1
  fi

  if [[ "$value" =~ ^0+(\.0+)?$ ]]; then
    printf 'ERROR: CPU value must be greater than zero: %s\n' "$value" >&2
    return 1
  fi

  return 0
}

# Validate a CONTAINER_MEMORY value: empty (default) or a positive integer with an
# optional single unit suffix (k, m, g; case-insensitive), e.g. 512m, 4g, 1024.
# Rejects zero/negative, unsupported suffixes, whitespace, and shell metacharacters.
dc_validate_memory_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]+[kKmMgG]?$ ]]; then
    printf 'ERROR: Invalid memory value: %q\n' "$value" >&2
    printf '  Expected a positive integer with optional unit (k, m, g), e.g. 512m, 4g, 1024.\n' >&2
    return 1
  fi

  if [[ "$value" =~ ^0+[kKmMgG]?$ ]]; then
    printf 'ERROR: memory value must be greater than zero: %s\n' "$value" >&2
    return 1
  fi

  return 0
}

# Validate a network name. Networks are user-defined objects shared across
# containers and embedded in backend `network create/connect` flags, so they use
# the same conservative identifier pattern as overlay scopes (no shell
# metacharacters, no whitespace, no leading dash). Returns 0 (valid) / 1 silent.
dc_validate_network_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# Validate an IPv4 address value: empty (means "auto-allocate") or a dotted-quad
# with each octet in 0-255. Rejects zero-octet padding beyond leading-zero rules,
# whitespace, exponents, and any shell metacharacter. Prints a diagnostic and
# returns 1 on rejection. (Mirrors dc_validate_cpus_value / dc_validate_memory_value.)
dc_validate_ip_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    printf 'ERROR: Invalid IPv4 address: %q\n' "$value" >&2
    printf '  Expected dotted-quad (e.g. 10.20.30.40).\n' >&2
    return 1
  fi

  local octet=""
  local IFS=.
  local -a octets=()
  # shellcheck disable=SC2206
  octets=($value)
  for octet in "${octets[@]}"; do
    # Reject leading zeros like 010 (ambiguous octal) while allowing single 0.
    if [[ "$octet" =~ ^0[0-9]+$ ]]; then
      printf 'ERROR: Invalid IPv4 octet (leading zero): %s in %s\n' "$octet" "$value" >&2
      return 1
    fi
    if [[ "$octet" -gt 255 ]]; then
      printf 'ERROR: Invalid IPv4 octet (>255): %s in %s\n' "$octet" "$value" >&2
      return 1
    fi
  done

  return 0
}

# Validate an IPv4 CIDR subnet value: empty (means "auto-allocate by backend") or
# dotted-quad / prefix with octets 0-255 and prefix 0-32. Prints a diagnostic and
# returns 1 on rejection.
dc_validate_subnet_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    printf 'ERROR: Invalid IPv4 subnet (expected A.B.C.D/N): %q\n' "$value" >&2
    return 1
  fi

  local prefix="${value##*/}"
  local addr="${value%/*}"

  if [[ "$prefix" -gt 32 ]]; then
    printf 'ERROR: Invalid subnet prefix (>32): %s in %s\n' "$prefix" "$value" >&2
    return 1
  fi

  if ! dc_validate_ip_value "$addr" 2>/dev/null; then
    printf 'ERROR: Invalid subnet address in %s\n' "$value" >&2
    return 1
  fi

  return 0
}

# Serialize a value for safe embedding inside a double-quoted shell assignment.
# Escapes backslash, quote, $, and backtick (in that order) so a later `source`
# reproduces the exact bytes without executing command substitution. Rejects
# control characters (newline, tab, NUL, ...) outright; they never belong in a
# config value. Echoes the escaped string on success; returns 1 on rejection.
dc_escape_config_value() {
  local value="$1"

  if [[ "$value" =~ [[:cntrl:]] ]]; then
    printf 'ERROR: config value rejected: contains control characters.\n' >&2
    return 1
  fi

  local out="$value"
  out="${out//\\/\\\\}"
  out="${out//\"/\\\"}"
  out="${out//\$/\\\$}"
  out="${out//\`/\\\`}"

  printf '%s' "$out"
}

# Return 0 if KEY is an allowed scalar project-config key.
dc_config_is_scalar_key() {
  local key="$1"
  local k=""
  for k in "${_DC_CONFIG_SCALAR_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# Return 0 if KEY is an allowed array project-config key.
dc_config_is_array_key() {
  local key="$1"
  local k=""
  for k in "${_DC_CONFIG_ARRAY_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# Return 0 if NAME is a supported container backend identifier.
dc_config_is_known_backend() {
  local name="$1"
  local b=""
  for b in "${_DC_KNOWN_BACKENDS[@]}"; do
    [[ "$b" == "$name" ]] && return 0
  done
  return 1
}

# Return 0 (true) if PATH is group- or other-writable. Uses single-bit -perm
# checks (portable across GNU and BSD find) combined with -o so either bit trips.
dc_path_is_group_or_other_writable() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  [[ -n "$(find "$path" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>/dev/null)" ]]
}

# Scan the content of a double-quoted value and return 0 if an UNESCAPED command
# substitution token ($ or backtick) is present. Escaped forms (\$, \`) are
# treated as literal data and ignored, since the serializer emits those for any
# real $/backtick in a value. This is the guard that lets us source safely.
dc_quoted_has_unescaped_subst() {
  local content="$1"
  local i=0
  local len=${#content}
  local ch=""
  local escaped=0

  for ((i = 0; i < len; i++)); do
    ch="${content:i:1}"
    if [[ "$escaped" -eq 1 ]]; then
      escaped=0
      continue
    fi
    if [[ "$ch" == '\' ]]; then
      escaped=1
      continue
    fi
    if [[ "$ch" == '$' || "$ch" == '`' ]]; then
      return 0
    fi
  done

  return 1
}

# Validate one line of a project config against the strict assignment grammar.
# Returns 0 if the line is blank, a (non-continuing) comment, or a known
# KEY="value" / KEY=(array) assignment with no unescaped command substitution.
# Returns 1 (reject) for unknown keys, bare shell syntax, or dangerous tokens.
dc_config_line_is_safe() {
  local line="$1"

  # Blank / whitespace-only line.
  [[ -z "${line//[[:space:]]/}" ]] && return 0

  # Comment line. Reject a trailing backslash, which would continue the comment
  # onto the next line and could hide a payload after the comment.
  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    [[ "$line" != *'\' ]]
    return $?
  fi

  # Must be a KEY=... assignment with an uppercase identifier key.
  if [[ ! "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
    return 1
  fi

  local key="${BASH_REMATCH[1]}"
  local rest="${BASH_REMATCH[2]}"

  if dc_config_is_array_key "$key"; then
    # Array assignment must be wrapped in (...).
    [[ "${rest:0:1}" == "(" ]] || return 1
    [[ "${rest: -1}" == ")" ]] || return 1
    # Array elements are emitted with printf '%q'; reject any shell metacharacter
    # that %q output never produces, as it would indicate hand-crafted content.
    case "$rest" in
      *'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*) return 1 ;;
    esac
    return 0
  fi

  if dc_config_is_scalar_key "$key"; then
    # Scalar must be a single, well-formed double-quoted string (handles escaped
    # quotes/backslashes). This also rejects trailing content after the closing
    # quote, e.g. KEY="x"; rm -rf /.
    if [[ ! "$rest" =~ ^\"([^\"\\]|\\.)*\"$ ]]; then
      return 1
    fi
    local content="${rest#\"}"
    content="${content%\"}"
    if dc_quoted_has_unescaped_subst "$content"; then
      return 1
    fi
    return 0
  fi

  # Unknown key.
  return 1
}

# Validate the values loaded from a project config (called after sourcing, while
# the variables are in scope). Prints a diagnostic and returns 1 (does NOT exit)
# on any out-of-contract value: security-critical file/line checks are handled
# earlier by dc_load_project_config via dc_die, but value problems are left to
# the caller so maintenance commands (e.g. `dc clean`) can skip a bad project
# without aborting the whole run.
dc_validate_config_values() {
  local config_file="$1"

  if ! dc_validate_cpus_value "${CONTAINER_CPUS:-}" >&2; then
    printf '  in %s\n' "$config_file" >&2
    return 1
  fi

  if ! dc_validate_memory_value "${CONTAINER_MEMORY:-}" >&2; then
    printf '  in %s\n' "$config_file" >&2
    return 1
  fi

  if [[ -n "${CONTAINER_BACKEND:-}" ]]; then
    if ! dc_config_is_known_backend "${CONTAINER_BACKEND}"; then
      printf 'ERROR: Unsupported CONTAINER_BACKEND in %s: %s\n' "$config_file" "${CONTAINER_BACKEND}" >&2
      return 1
    fi
  fi

  if [[ -n "${CONTAINER_PROJECT:-}" ]]; then
    if [[ ! "${CONTAINER_PROJECT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      printf 'ERROR: Invalid CONTAINER_PROJECT in %s: %s\n' "$config_file" "${CONTAINER_PROJECT}" >&2
      return 1
    fi
  fi

  if [[ -n "${CONTAINER_IMAGE:-}" ]]; then
    if [[ ! "${CONTAINER_IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
      printf 'ERROR: Invalid CONTAINER_IMAGE in %s: %s\n' "$config_file" "${CONTAINER_IMAGE}" >&2
      return 1
    fi
  fi

  if [[ -n "${CONTAINER_OVERLAY_SCOPES:-}" ]]; then
    if ! dc_normalize_scopes_csv "${CONTAINER_OVERLAY_SCOPES}" >/dev/null 2>&1; then
      printf 'ERROR: Invalid CONTAINER_OVERLAY_SCOPES in %s: %s\n' "$config_file" "${CONTAINER_OVERLAY_SCOPES}" >&2
      return 1
    fi
  fi

  local port=""
  if declare -p PORTS >/dev/null 2>&1; then
    for port in "${PORTS[@]}"; do
      [[ -z "$port" ]] && continue
      if [[ ! "$port" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
        printf 'ERROR: Invalid port mapping in %s: %s (expected N or N:N)\n' "$config_file" "$port" >&2
        return 1
      fi
    done
  fi

  if declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1 && [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
    if ! dc_normalize_hidden_paths_values "${CONTAINER_HIDDEN_PATHS[@]}" >/dev/null 2>&1; then
      printf 'ERROR: Invalid CONTAINER_HIDDEN_PATHS in %s.\n' "$config_file" >&2
      return 1
    fi
  fi

  # Each persisted network entry is "<name>" or "<name>:<ipv4>". Names and IPs are
  # validated independently; an invalid entry is rejected rather than reaching the
  # backend create/connect flags.
  if declare -p CONTAINER_NETWORKS >/dev/null 2>&1 && [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
    local nentry=""
    local nname=""
    local nip=""
    for nentry in "${CONTAINER_NETWORKS[@]}"; do
      [[ -n "$nentry" ]] || continue
      if [[ "$nentry" == *:* ]]; then
        nname="${nentry%%:*}"
        nip="${nentry#*:}"
      else
        nname="$nentry"
        nip=""
      fi
      if ! dc_validate_network_name "$nname"; then
        printf 'ERROR: Invalid network name in CONTAINER_NETWORKS entry %q in %s\n' "$nentry" "$config_file" >&2
        return 1
      fi
      if [[ -n "$nip" ]]; then
        if ! dc_validate_ip_value "$nip" >&2; then
          printf '  in CONTAINER_NETWORKS entry %q in %s\n' "$nentry" "$config_file" >&2
          return 1
        fi
      fi
    done
  fi

  # Persisted paths must be absolute and free of control characters.
  local path_key=""
  local path_val=""
  for path_key in REPOS_DIR SECRET_DIR SSH_KEY_PATH TOKEN_FILE NPMRC_PATH; do
    path_val="${!path_key:-}"
    [[ -n "$path_val" ]] || continue
    if [[ "$path_val" != /* ]]; then
      printf 'ERROR: Invalid %s in %s: must be an absolute path (%s)\n' "$path_key" "$config_file" "$path_val" >&2
      return 1
    fi
    if [[ "$path_val" =~ [[:cntrl:]] ]]; then
      printf 'ERROR: Invalid %s in %s: contains control characters\n' "$path_key" "$config_file" >&2
      return 1
    fi
  done

  return 0
}

# Load a project config file through the hardened, single path. Validates file
# safety (regular file, not a symlink, not group/other-writable) and line shape
# (known keys, no shell syntax or unescaped command substitution) BEFORE sourcing,
# then validates the loaded values. On success the config keys are set as globals
# in the caller's scope and it returns 0. Security violations (file/line shape)
# exit via dc_die; value violations return 1 so callers under `set -e` exit while
# maintenance commands can choose to skip a bad project.
dc_load_project_config() {
  local config_file="$1"

  [[ -n "$config_file" ]] || dc_die "dc_load_project_config: config file path required"

  if [[ -L "$config_file" ]]; then
    dc_die "Refusing to load config via symlink: $config_file"
  fi
  if [[ ! -f "$config_file" ]]; then
    dc_die "Config file not found: $config_file"
  fi

  local parent=""
  parent="$(dirname "$config_file")"
  if dc_path_is_group_or_other_writable "$config_file"; then
    dc_die "Refusing to load group/other-writable config: $config_file
  Fix with: chmod 600 \"$config_file\""
  fi
  if dc_path_is_group_or_other_writable "$parent"; then
    dc_die "Refusing to load config from group/other-writable directory: $parent
  Fix with: chmod 700 \"$parent\""
  fi

  local line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ! dc_config_line_is_safe "$line"; then
      dc_die "Unsafe or invalid line in config $config_file:
  $line
Only blank lines, comments, and known KEY=\"value\" assignments are allowed."
    fi
  done < "$config_file"

  # Reset optional arrays so a config lacking them (or a prior load) doesn't leak
  # stale values; plain assignments sourced below become globals automatically.
  PORTS=()
  CONTAINER_HIDDEN_PATHS=()
  CONTAINER_NETWORKS=()

  # shellcheck disable=SC1090
  source "$config_file"

  dc_validate_config_values "$config_file" || return 1
}

# Extract a single double-quoted scalar value for KEY from a config file WITHOUT
# executing anything: pure line + escape-aware parsing. Used for the global config
# (DC_TEAM_DIR / DC_USER_DIR) and anywhere only one key is needed, so call sites
# never have to `source`. Echoes the literal (unescaped) value; returns 1 if not
# found or not a clean quoted assignment.
dc_config_extract_scalar() {
  local file="$1"
  local key="$2"
  local line=""
  local raw=""
  local content=""
  local i=0
  local ch=""
  local escaped=0
  local out=""

  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Match only the requested key as a full identifier (anchored word boundary).
    [[ "$line" =~ ^[[:space:]]*${key}= ]] || continue

    raw="${line#*=}"
    if [[ "$raw" != \"*\" ]]; then
      return 1
    fi
    content="${raw#\"}"
    content="${content%\"}"

    # Inverse of dc_escape_config_value: interpret backslash escapes literally.
    out=""
    escaped=0
    for ((i = 0; i < ${#content}; i++)); do
      ch="${content:i:1}"
      if [[ "$escaped" -eq 1 ]]; then
        out+="$ch"
        escaped=0
        continue
      fi
      if [[ "$ch" == '\' ]]; then
        escaped=1
        continue
      fi
      out+="$ch"
    done

    printf '%s' "$out"
    return 0
  done < "$file"

  return 1
}

# Set or replace a single KEY="value" line in a project config file safely.
# Rewrites via a temp file and atomic mv, serializing the value through the shared
# dc_escape_config_value helper (escapes backslash/quote/$/backtick, rejects
# control characters) so the value round-trips inertly through dc_load_project_config.
# Appends the key if absent.
dc_set_config_key() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  local escaped=""
  escaped="$(dc_escape_config_value "$value")" || return 1

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

# Replace (or append) an array assignment line `KEY=(...)` in a project config.
# Elements are serialized with `printf '%q'` exactly as new-container.sh emits
# them, so the result round-trips inertly through dc_load_project_config. An empty
# element list writes `KEY=()`. Uses mktemp (not a PID-based name) for the atomic
# rewrite. Returns non-zero if the temp file cannot be created.
dc_set_config_array() {
  local config_file="$1"
  local key="$2"
  shift 2

  local tmp_file=""
  tmp_file="$(mktemp "${config_file}.tmp.XXXXXX")" || return 1
  local updated=0
  local line=""

  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$key="* ]]; then
        if [[ "$updated" -eq 0 ]]; then
          printf '%s=(' "$key"
          if [[ $# -gt 0 ]]; then
            printf ' %q' "$@"
          fi
          printf ' )\n'
        fi
        updated=1
      else
        printf '%s\n' "$line"
      fi
    done < "$config_file"
    if [[ "$updated" -eq 0 ]]; then
      printf '%s=(' "$key"
      if [[ $# -gt 0 ]]; then
        printf ' %q' "$@"
      fi
      printf ' )\n'
    fi
  } > "$tmp_file"

  mv "$tmp_file" "$config_file"
}
