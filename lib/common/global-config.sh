#!/usr/bin/env bash
# =============================================================================
# lib/common/global-config.sh - Global dce-enclave config (team/user roots).
#
# Sourced (never executed directly) via lib/common.sh. Owns the path layout of
# the global config (~/.config/dce-enclave/config) and the four leaf overlay /
# recipe directories under the two roots it exports (DC_TEAM_DIR, DC_USER_DIR).
# dce_load_global_config parses the file without `source` (via
# dce_config_extract_scalar from config.sh) so a malicious or corrupted file
# cannot execute code; both roots are then normalized and required to exist.
# =============================================================================

if [[ -n "${_DC_COMMON_GLOBAL_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_GLOBAL_CONFIG_SH_LOADED=1

# Path to the global DC Enclave config file (DC_TEAM_DIR/DC_USER_DIR live here).
dce_global_config_path() {
  printf '%s/.config/dce-enclave/config\n' "$HOME"
}

# Default team/user roots used by setup.sh when bootstrapping global config. Each
# is an independent root that may be its own git repo, containing both overlays/
# (image layers) and container-recipes/ (per-container-name recipe files).
dce_team_default_root() {
  printf '%s/.config/dce-enclave/team\n' "$HOME"
}

dce_user_default_root() {
  printf '%s/.config/dce-enclave/user\n' "$HOME"
}

# Single source of truth for the four leaf directories under the two roots. The
# root variables must be set (dce_load_global_config guarantees this for runtime;
# callers that bypass the loader must set them first).
dce_team_overlays_dir() {
  printf '%s/overlays\n' "$DC_TEAM_DIR"
}

dce_user_overlays_dir() {
  printf '%s/overlays\n' "$DC_USER_DIR"
}

dce_team_recipes_dir() {
  printf '%s/container-recipes\n' "$DC_TEAM_DIR"
}

dce_user_recipes_dir() {
  printf '%s/container-recipes\n' "$DC_USER_DIR"
}

# Normalize a global-config root path in place by variable name: expand a leading
# ~ and resolve a relative path against the config dir. Shared by the two-root
# loader so the exact rule lives in one place (previously it was triplicated).
_dce_normalize_config_root() {
  local varname="$1"
  local val="${!varname}"
  # shellcheck disable=SC2088
  # ~ is a literal char being matched against user input, not an expansion.
  if [[ "$val" == "~" || "$val" == "~/"* ]]; then
    val="$HOME${val#\~}"
  elif [[ "$val" != /* ]]; then
    val="$HOME/.config/dce-enclave/$val"
  fi
  printf -v "$varname" '%s' "$val"
}

# Load and validate the global config, exporting DC_TEAM_DIR and DC_USER_DIR.
#
# The global config is parsed with dce_config_extract_scalar (no `source`), so a
# malicious or corrupted file cannot execute code. Both roots are deliberately
# unset first so a stale/environment value can't leak in; each is then normalized
# (~ and relative paths resolved against the config dir) and required to exist.
# Each root may be its own git repo holding both overlays/ and container-recipes/.
dce_load_global_config() {
  local cfg=""
  cfg="$(dce_global_config_path)"

  if [[ ! -f "$cfg" ]]; then
    dce_die "Global config not found: ~/.config/dce-enclave/config
Run: scripts/setup.sh"
  fi

  if [[ -L "$cfg" ]]; then
    dce_die "Refusing to load global config via symlink: $cfg"
  fi

  unset DC_TEAM_DIR DC_USER_DIR

  if ! DC_TEAM_DIR="$(dce_config_extract_scalar "$cfg" DC_TEAM_DIR)"; then
    dce_die "DC_TEAM_DIR is not set (or is not a clean quoted value) in ~/.config/dce-enclave/config
Set DC_TEAM_DIR and rerun scripts/setup.sh"
  fi
  if ! DC_USER_DIR="$(dce_config_extract_scalar "$cfg" DC_USER_DIR)"; then
    dce_die "DC_USER_DIR is not set (or is not a clean quoted value) in ~/.config/dce-enclave/config
Set DC_USER_DIR and rerun scripts/setup.sh"
  fi

  if [[ -z "${DC_TEAM_DIR:-}" ]]; then
    dce_die "DC_TEAM_DIR is not set in ~/.config/dce-enclave/config
Set DC_TEAM_DIR and rerun scripts/setup.sh"
  fi
  if [[ -z "${DC_USER_DIR:-}" ]]; then
    dce_die "DC_USER_DIR is not set in ~/.config/dce-enclave/config
Set DC_USER_DIR and rerun scripts/setup.sh"
  fi

  _dce_normalize_config_root DC_TEAM_DIR
  _dce_normalize_config_root DC_USER_DIR

  if [[ ! -d "$DC_TEAM_DIR" ]]; then
    dce_die "Team root does not exist: $DC_TEAM_DIR
Run: scripts/setup.sh"
  fi
  if [[ ! -d "$DC_USER_DIR" ]]; then
    dce_die "User root does not exist: $DC_USER_DIR
Run: scripts/setup.sh"
  fi
}
