#!/usr/bin/env bash
# =============================================================================
# scripts/config.sh - `dce config`: thin validating wrapper over project config.
#
# The per-project config (~/.config/dce-enclave/<name>/config) is the source of
# truth. This command never edits any other state and needs NO container backend
# and NO global config: it loads, validates, and rewrites that one file through
# the hardened helpers in lib/common.sh (dce_load_project_config, the per-key
# validators, dce_set_config_key / dce_set_config_array). The file's permission
# bits are preserved across the atomic rewrite by those helpers.
#
# Only user-input keys are writable; identity/derived/path keys are read-only so
# a user can never desync the container from its managed state through here.
#
# Subcommands: show, get, set, ls.
# =============================================================================
set -euo pipefail

_sub="${BASH_SOURCE[0]}"
while [[ -L "$_sub" ]]; do
  _d="$(cd -P "$(dirname "$_sub")" && pwd)"
  _sub="$(readlink "$_sub")"
  [[ "$_sub" != /* ]] && _sub="$_d/$_sub"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_sub")" && pwd)"
unset _sub _d
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/devcontainer.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/extensions.sh"

# --- friendly-key vocabulary -------------------------------------------------
# Mutable keys map a short name to the real config key + kind. Read-only keys
# (identity/derived/paths owned by `new`/`rebuild-container`) are get/show-only;
# `set` rejects them so this surface can never desync managed state.
declare -A _CFG_MUTABLE_REAL=(
  [cpus]=CONTAINER_CPUS
  [memory]=CONTAINER_MEMORY
  [scopes]=CONTAINER_OVERLAY_SCOPES
  [ports]=PORTS
  [hide]=CONTAINER_HIDDEN_PATHS
  [networks]=CONTAINER_NETWORKS
)
declare -A _CFG_MUTABLE_KIND=(
  [cpus]=scalar
  [memory]=scalar
  [scopes]=scalar
  [ports]=array
  [hide]=array
  [networks]=array
)
declare -A _CFG_READONLY_REAL=(
  [project]=CONTAINER_PROJECT
  [backend]=CONTAINER_BACKEND
  [image]=CONTAINER_IMAGE
  [repos]=REPOS_DIR
)

_CFG_MUTABLE_ORDER=(cpus memory scopes ports hide networks)
_CFG_READONLY_ORDER=(project backend image repos)

# Echo all valid friendly key names (mutable then read-only), space-separated.
_cfg_all_keys() {
  printf '%s' "${_CFG_MUTABLE_ORDER[*]} ${_CFG_READONLY_ORDER[*]}"
}

USAGE() {
  cat <<EOF
Usage: dce config <subcommand> [args]

Inspect and edit a project's config file (~/.config/dce-enclave/<name>/config)
without leaving the CLI. The file stays the source of truth; this is a thin,
validating wrapper. Needs no container backend.

Subcommands:
  show <name>                       Print a grouped, human-readable view.
  get  <name> <key>                 Print one value (scalars: the value; arrays:
                                    one element per line). Empty = unset.
  set  <name> <key>=<value>         Validate, atomically write, then reload to
        dce config set <name> <key> <value>   prove the file still loads.
                                    Arrays take a comma-separated value.
  sync-vscode <name> [--dry-run]    Rewrite the MANAGED fields of the project's
                                    .devcontainer/devcontainer.json to match the
                                    current config, preserving user edits.
                                    Requires jq + a docker-compatible backend.
  ls                                List projects that have a config (no backend).

Mutable keys (set/get): $(_cfg_all_keys_multiline)
Read-only keys (get only): ${_CFG_READONLY_ORDER[*]}

Set clears a key by giving an empty value (e.g. \`cpus=\` -> backend default).
Resource/scope/network/hidden-path changes take effect only after:
  dce rebuild-container <name>
EOF
}

# Multi-line listing of mutable keys with their kind, for USAGE.
_cfg_all_keys_multiline() {
  local k
  for k in "${_CFG_MUTABLE_ORDER[@]}"; do
    printf '\n  %-10s %s' "$k" "${_CFG_MUTABLE_KIND[$k]}"
  done
}

# --- value canonicalization --------------------------------------------------
# Echo CSV elements one per line (empty input -> no output).
_csv_lines() {
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  local IFS=','
  local -a parts=()
  local p
  read -r -a parts <<< "$csv"
  for p in "${parts[@]}"; do
    [[ -z "$p" ]] && continue
    printf '%s\n' "$p"
  done
}

# Validate and canonicalize a value for a MUTABLE key. Echoes the canonical
# scalar (one line) or canonical array elements (one per line). Returns 1 with a
# diagnostic on stderr for any invalid value. Reuses the shared validators so the
# contract is identical to `new`/`rebuild-container`.
_cfg_normalize_value() {
  local key="$1" value="$2"
  case "$key" in
    cpus)
      dce_validate_cpus_value "$value" || return 1
      printf '%s\n' "$value"
      ;;
    memory)
      dce_validate_memory_value "$value" || return 1
      printf '%s\n' "$value"
      ;;
    scopes)
      local norm=""
      norm="$(dce_normalize_scopes_csv "$value")" || return 1
      printf '%s\n' "$norm"
      ;;
    ports)
      local p
      while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if [[ ! "$p" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
          printf 'ERROR: invalid port %q (expected N or N:N)\n' "$p" >&2
          return 1
        fi
        printf '%s\n' "$p"
      done < <(_csv_lines "$value")
      ;;
    hide)
      local -a elems=()
      mapfile -t elems < <(_csv_lines "$value")
      if [[ ${#elems[@]} -gt 0 ]]; then
        local norm=""
        norm="$(dce_normalize_hidden_paths_values "${elems[@]}")" || return 1
        local IFS=','
        local -a arr=()
        read -r -a arr <<< "$norm"
        local e
        for e in "${arr[@]}"; do [[ -n "$e" ]] && printf '%s\n' "$e"; done
      fi
      ;;
    networks)
      local n name ip
      while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if [[ "$n" == *:* ]]; then name="${n%%:*}"; ip="${n#*:}"; else name="$n"; ip=""; fi
        if ! dce_validate_network_name "$name"; then
          printf 'ERROR: invalid network name in %q\n' "$n" >&2
          return 1
        fi
        if [[ -n "$ip" ]] && ! dce_validate_ip_value "$ip" >&2; then
          return 1
        fi
        printf '%s\n' "$n"
      done < <(_csv_lines "$value")
      ;;
    *)
      printf 'ERROR: unknown key %q\n' "$key" >&2
      return 1
      ;;
  esac
}

# Resolve $project to its config path, or die. Does not require a backend.
_cfg_require_config() {
  local project="$1"
  local config=""
  config="$HOME/.config/dce-enclave/$project/config"
  if [[ ! -f "$config" ]]; then
    dce_die "No config for project '$project'.
Run 'dce new $project ...' first, or 'dce config ls' to see configured projects."
  fi
  printf '%s' "$config"
}

# Join a global array (by VARNAME) with ", ", or "(none)" if empty.
_join_array_or_none() {
  local varname="$1"
  local ref="${varname}[@]"
  local out="" e
  for e in "${!ref}"; do
    [[ -z "$e" ]] && continue
    [[ -n "$out" ]] && out+=", "
    out+="$e"
  done
  printf '%s' "${out:-(none)}"
}

# --- show --------------------------------------------------------------------
do_show() {
  local project="${1:-}"
  [[ -n "$project" ]] || { echo "ERROR: 'dce config show' requires <name>" >&2; USAGE >&2; exit 1; }
  local config=""
  config="$(_cfg_require_config "$project")"
  dce_load_project_config "$config"

  echo "Project: ${CONTAINER_PROJECT:-$project}"
  echo "Backend: ${CONTAINER_BACKEND:-(default)}"
  echo "Image:   ${CONTAINER_IMAGE:-(default)}"
  echo "Scopes:  ${CONTAINER_OVERLAY_SCOPES:-(none)}"
  echo ""
  echo "Resources:"
  echo "  CPUs:    ${CONTAINER_CPUS:-(default)}"
  echo "  Memory:  ${CONTAINER_MEMORY:-(default)}"
  echo ""
  echo "Networking:"
  echo "  Ports:     $(_join_array_or_none PORTS)"
  echo "  Networks:  $(_join_array_or_none CONTAINER_NETWORKS)"
  echo ""
  echo "Hidden paths:"
  local _ref="CONTAINER_HIDDEN_PATHS[@]" _hp _any=0
  for _hp in "${!_ref}"; do
    [[ -n "$_hp" ]] && { echo "  $_hp"; _any=1; }
  done
  [[ $_any -eq 1 ]] || echo "  (none)"
  echo ""
  echo "Paths:"
  echo "  Repos:   ${REPOS_DIR:-(unset)}"
}

# --- get ---------------------------------------------------------------------
do_get() {
  local project="${1:-}" friendly="${2:-}"
  if [[ -z "$project" || -z "$friendly" ]]; then
    echo "ERROR: 'dce config get' requires <name> <key>" >&2
    printf '  Valid keys: %s\n' "$(_cfg_all_keys)" >&2
    exit 1
  fi
  local config=""
  config="$(_cfg_require_config "$project")"
  dce_load_project_config "$config"

  local real="" kind="scalar"
  if [[ -n "${_CFG_MUTABLE_REAL[$friendly]:-}" ]]; then
    real="${_CFG_MUTABLE_REAL[$friendly]}"
    kind="${_CFG_MUTABLE_KIND[$friendly]}"
  elif [[ -n "${_CFG_READONLY_REAL[$friendly]:-}" ]]; then
    real="${_CFG_READONLY_REAL[$friendly]}"
  else
    dce_die "Unknown key '$friendly'. Valid keys: $(_cfg_all_keys)."
  fi

  if [[ "$kind" == "array" ]]; then
    local _ref="${real}[@]" _e
    for _e in "${!_ref}"; do
      [[ -n "$_e" ]] && printf '%s\n' "$_e"
    done
  else
    local _s="$real"
    printf '%s\n' "${!_s:-}"
  fi
}

# --- set ---------------------------------------------------------------------
do_set() {
  local project="${1:-}"
  local second="${2:-}"
  local friendly="" value=""

  if [[ -z "$project" || -z "$second" ]]; then
    echo "ERROR: 'dce config set' requires <name> <key>=<value>" >&2
    USAGE >&2
    exit 1
  fi

  if [[ "$second" == *=* ]]; then
    # equals form: project + key=value (no extra args)
    if [[ $# -ne 2 ]]; then
      echo "ERROR: 'key=value' form takes no extra args" >&2
      exit 1
    fi
    friendly="${second%%=*}"
    value="${second#*=}"
  else
    # space form: project key value
    if [[ $# -ne 3 ]]; then
      echo "ERROR: 'dce config set' needs <name> <key> <value> (or <key>=<value>)" >&2
      exit 1
    fi
    friendly="$second"
    value="${3:-}"
  fi

  # Resolve kind. Read-only keys are rejected so this surface cannot desync
  # managed state; unknown keys list the valid set.
  local real="" kind=""
  if [[ -n "${_CFG_MUTABLE_REAL[$friendly]:-}" ]]; then
    real="${_CFG_MUTABLE_REAL[$friendly]}"
    kind="${_CFG_MUTABLE_KIND[$friendly]}"
  elif [[ -n "${_CFG_READONLY_REAL[$friendly]:-}" ]]; then
    dce_die "'$friendly' is read-only (owned by 'dce new' / 'dce rebuild-container').
  Writable keys: ${_CFG_MUTABLE_ORDER[*]}."
  else
    dce_die "Unknown key '$friendly'.
  Valid keys: $(_cfg_all_keys)."
  fi

  local config=""
  config="$(_cfg_require_config "$project")"

  # Validate + canonicalize BEFORE touching the file. Capture stdout and the
  # exit status together: `mapfile < <(cmd)` would NOT propagate cmd's failure
  # (the array branch needs the canonicalized lines, but the error must still
  # abort the write).
  local canon_out=""
  canon_out="$(_cfg_normalize_value "$friendly" "$value")" || exit 1

  if [[ "$kind" == "scalar" ]]; then
    dce_set_config_key "$config" "$real" "$canon_out"
  else
    local -a elems=()
    # An empty canonical result means "clear": write KEY=(). `<<< ""` would
    # otherwise yield a single empty element.
    if [[ -n "$canon_out" ]]; then
      mapfile -t elems <<< "$canon_out"
    fi
    if [[ ${#elems[@]} -gt 0 ]]; then
      dce_set_config_array "$config" "$real" "${elems[@]}"
    else
      dce_set_config_array "$config" "$real"
    fi
  fi

  # Reload to PROVE the rewritten file still passes the hardened loader. A set
  # that produces an unloadable file is a bug; fail closed rather than lie.
  if ! dce_load_project_config "$config"; then
    dce_die "Config failed to reload after update (please report this bug): $config"
  fi

  echo "Updated '$friendly' for project '$project'."
  echo "Run 'dce rebuild-container $project' for the change to take effect."
}

# --- ls ----------------------------------------------------------------------
do_ls() {
  local base="$HOME/.config/dce-enclave"
  [[ -d "$base" ]] || return 0
  local d name
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/config" ]] || continue
    name="$(basename "$d")"
    printf '%s\n' "$name"
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
}

# --- sync-vscode -------------------------------------------------------------
# Carved-out exception to config's "never edits other state / needs no backend"
# invariant: this subcommand rewrites the project's .devcontainer/devcontainer.json
# (outside the config file) and loads global config (to re-derive the managed
# dockerfile path). It still performs NO container-backend call. Requires jq.
do_sync_vscode() {
  local project="${1:-}"
  local dry_run="false"

  if [[ -z "$project" ]]; then
    echo "ERROR: 'dce config sync-vscode' requires <name>" >&2
    USAGE >&2
    exit 1
  fi
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="true"; shift ;;
      -h|--help|help)
        sed -n '/sync-vscode/,/Requires jq/p' "$0" 2>/dev/null || true
        return 0
        ;;
      *)
        echo "ERROR: Unknown option for sync-vscode: $1" >&2
        echo "  Usage: dce config sync-vscode <name> [--dry-run]" >&2
        exit 1
        ;;
    esac
  done

  local config=""
  config="$(_cfg_require_config "$project")"
  dce_load_project_config "$config"

  if [[ "${CONTAINER_BACKEND:-}" == "apple" ]]; then
    dce_die "sync-vscode applies to docker-compatible backends; project '$project' uses apple (no devcontainer.json)."
  fi
  if ! command -v jq >/dev/null 2>&1; then
    dce_die "sync-vscode requires jq (it is optional everywhere else).
  Install jq, then rerun."
  fi
  if [[ -z "${REPOS_DIR:-}" ]]; then
    dce_die "Project '$project' config has no REPOS_DIR; cannot locate devcontainer.json."
  fi

  # Re-derive the managed dockerfile (needs the overlay dirs -> global config).
  dce_load_global_config

  local scopes_csv="${CONTAINER_OVERLAY_SCOPES:-}"
  local build_file=""
  build_file="$(dce_devcontainer_build_file "$ROOT_DIR" "$scopes_csv")" \
    || dce_die "Could not derive the managed Containerfile path for scopes '$scopes_csv'."

  local dc_file="$REPOS_DIR/.devcontainer/devcontainer.json"
  if [[ ! -f "$dc_file" ]]; then
    dce_die "No devcontainer.json to sync at: $dc_file
  Run 'dce new $project' first (sync-vscode reconciles an existing file)."
  fi

  local hidden_csv nets_csv ports_csv
  hidden_csv="$(dce_normalize_hidden_paths_values "${CONTAINER_HIDDEN_PATHS[@]:-}")" || hidden_csv=""
  if declare -p CONTAINER_NETWORKS >/dev/null 2>&1 && [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
    nets_csv="$(dce_join_by ',' "${CONTAINER_NETWORKS[@]}")"
  else
    nets_csv=""
  fi
  if declare -p PORTS >/dev/null 2>&1 && [[ ${#PORTS[@]} -gt 0 ]]; then
    ports_csv="$(dce_join_by ',' "${PORTS[@]}")"
  else
    ports_csv=""
  fi
  local tz=""
  tz="$(dce_host_timezone)" || tz=""

  # Resolve the editor-extensions set for this project's scopes (vscode in v1)
  # and the adoption flag (any effective manifest present). Passed to sync so it
  # either fully-manages customizations.vscode.extensions (adopted) or leaves a
  # hand-curated array untouched (migration guard). See plans/extensions.md.
  local ext_csv=""
  local ext_manifests="false"
  if dce_ext_manifests_exist vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "$scopes_csv" 2>/dev/null; then
    ext_manifests="true"
    ext_csv="$(dce_ext_resolve_csv vscode "$DC_TEAM_DIR" "$DC_USER_DIR" "$scopes_csv" 2>/dev/null)"
  fi

  # SECRET_DIR is a global populated by dce_load_project_config (not a typo).
  dce_devcontainer_sync "$project" "$dc_file" "$build_file" "$ROOT_DIR" "$SECRET_DIR" \
    "$hidden_csv" "$nets_csv" "$ports_csv" "$tz" "$dry_run" "$(dce_git_auth_method)" \
    "vscode" "$ext_csv" "$ext_manifests"
}

# --- dispatch ----------------------------------------------------------------
SUBACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$SUBACTION" in
  show)        do_show "$@" ;;
  get)         do_get "$@" ;;
  set)         do_set "$@" ;;
  sync-vscode) do_sync_vscode "$@" ;;
  ls)          do_ls "$@" ;;
  ""|-h|--help|help) USAGE ;;
  *)
    echo "Unknown config subcommand: $SUBACTION" >&2
    USAGE >&2
    exit 1
    ;;
esac
