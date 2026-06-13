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
