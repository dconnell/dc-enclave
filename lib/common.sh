#!/usr/bin/env bash
# Shared Bash guardrails and helper utilities for host-side scripts.

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERROR: dev-containers requires Bash 4+ (scripts must run under bash)." >&2
  exit 1
fi

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: dev-containers requires Bash 4+ (current: $BASH_VERSION)" >&2
  echo "  macOS: brew install bash" >&2
  exit 1
fi

if [[ -n "${_DC_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_SH_LOADED=1

dc_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

dc_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

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

dc_global_config_path() {
  printf '%s/.config/dev-containers/config\n' "$HOME"
}

dc_overlay_default_root() {
  printf '%s/.config/dev-containers/overlays\n' "$HOME"
}

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

dc_validate_scope_name() {
  local scope="$1"
  [[ "$scope" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

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

dc_scope_exists() {
  local overlays_dir="$1"
  local scope="$2"

  [[ -f "$overlays_dir/team/Containerfile.$scope" || -f "$overlays_dir/user/Containerfile.$scope" ]]
}

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

dc_image_hash_from_ref() {
  local image_ref="$1"
  local repo="${image_ref%%:*}"

  if [[ "$repo" =~ ^dev-img-([0-9a-f]{16})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

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
