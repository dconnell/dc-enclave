#!/usr/bin/env bash
# =============================================================================
# lib/complete-data.sh - Shared completion candidate discovery.
#
# Sourced (never executed) by BOTH scripts/dce-complete.bash (bash) and
# scripts/_dce (zsh). This is the single source of truth for project names,
# overlay scopes, subcommands, and rebuild-image targets, so the two
# completion front-ends never duplicate logic -- in particular the hardened,
# no-source global-config parsers (_dce_read_team_dir / _dce_read_user_dir),
# which are a security boundary (see tests/unit/config-security.sh).
#
# Portability: written to source cleanly under bash 4+ and zsh 5+. Uses only
# `[[ ]]`, `=~`, `$'...'`, and printf -- no associative arrays and no arrays
# at all; each function emits one candidate per line so the caller can split
# the output however its shell prefers.
# =============================================================================

# Include guard (sourced in two shells; keep the marker shell-agnostic).
if [[ -n "${_DC_COMPLETE_DATA_SH_LOADED:-}" ]]; then
  return 0
fi
_DC_COMPLETE_DATA_SH_LOADED=1

# Print the static list of dce subcommands (including aliases and version/help
# spellings). Mirrors the dispatch table in scripts/dce.
dce_complete_subcommands() {
  printf '%s\n' \
    "new" \
    "start" \
    "stop" \
    "status" \
    "s" \
    "list" \
    "ls" \
    "shell" \
    "logs" \
    "editor" \
    "sync-status" \
    "extensions" \
    "exec" \
    "restart" \
    "rm" \
    "rebuild-container" \
    "rebuild-image" \
    "snapshot" \
    "snapshots" \
    "provenance" \
    "clean" \
    "config" \
    "network" \
    "net" \
    "doctor" \
    "install" \
    "rotate-token" \
    "version" \
    "--version" \
    "-v" \
    "help" \
    "--help" \
    "-h"
}

# Read DC_TEAM_DIR / DC_USER_DIR from the global config WITHOUT sourcing or
# executing it. Restricted line + quoted-value parsing only: a malicious config
# line can never run code through completion. Echoes the value; returns 1 if
# absent or malformed. (Moved verbatim from scripts/dce-complete.bash and
# generalized for the two-root layout -- security boundary.)
_dce_read_config_root() {
  local config="$1" key="$2"
  local line raw content

  [[ -f "$config" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*${key}= ]] || continue
    raw="${line#*=}"
    # Require a double-quoted value.
    if [[ "$raw" != \"*\" ]]; then
      return 1
    fi
    content="${raw#\"}"
    content="${content%\"}"
    # Reject any $/backtick outright (a root path never needs them), then undo
    # the minimal escapes the serializer emits. No interpretation means no
    # execution.
    if [[ "$content" == *'$'* || "$content" == *'`'* ]]; then
      return 1
    fi
    content="${content//\\\"/\"}"
    content="${content//\\\\/\\}"
    printf '%s' "$content"
    return 0
  done < "$config"
  return 1
}

_dce_read_team_dir() { _dce_read_config_root "$1" DC_TEAM_DIR; }
_dce_read_user_dir() { _dce_read_config_root "$1" DC_USER_DIR; }

# Print configured project names (dirs under ~/.config/dce-enclave with a
# `config` file). When $1 is non-empty, only names with that prefix are printed.
dce_complete_projects() {
  local cur="${1:-}"
  local base="$HOME/.config/dce-enclave"
  local d name

  [[ -d "$base" ]] || return 0

  # zsh errors when a glob matches nothing; bash leaves the literal pattern,
  # which the [[ -d ]] test below filters out. So only zsh needs null-glob, and
  # local_options scopes the change so it never leaks into the caller's shell.
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt local_options NULL_GLOB
  fi

  for d in "$base"/*; do
    [[ -d "$d" && -f "$d/config" ]] || continue
    name="$(basename "$d")"
    if [[ -z "$cur" || "$name" == "$cur"* ]]; then
      printf '%s\n' "$name"
    fi
  done
}

# Print available overlay scope names discovered from the team and user
# overlays/ leaf directories, applying the same DC_TEAM_DIR / DC_USER_DIR
# resolution as the runtime helpers. Order is preserved and duplicates removed
# (first occurrence wins). Dedup uses a newline-delimited accumulator so a
# scope name can never partially match another (names cannot contain newlines).
dce_complete_scopes() {
  local config="$HOME/.config/dce-enclave/config"
  local team_dir="" user_dir=""
  local f name
  local nl=$'\n'
  local seen="$nl"

  if [[ -f "$config" ]]; then
    team_dir="$(_dce_read_team_dir "$config")" || team_dir=""
    user_dir="$(_dce_read_user_dir "$config")" || user_dir=""
    team_dir="$(_dce_complete_resolve_root "$team_dir")"
    user_dir="$(_dce_complete_resolve_root "$user_dir")"
  fi

  [[ -z "$team_dir" ]] && team_dir="$HOME/.config/dce-enclave/team"
  [[ -z "$user_dir" ]] && user_dir="$HOME/.config/dce-enclave/user"

  local team_od="$team_dir/overlays"
  local user_od="$user_dir/overlays"
  [[ -d "$team_od" || -d "$user_od" ]] || return 0

  # See dce_complete_projects: only zsh needs null-glob (local-scoped).
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt local_options NULL_GLOB
  fi

  for f in "$team_od"/Containerfile.* "$user_od"/Containerfile.*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    name="${name#Containerfile.}"
    [[ -z "$name" ]] && continue
    # Whole-line membership test: both sides delimited by newlines.
    if [[ "$seen" != *"$nl$name$nl"* ]]; then
      seen+="${name}${nl}"
      printf '%s\n' "$name"
    fi
  done
}

# Apply the same ~ / relative-path resolution the runtime loader does.
# Used by dce_complete_scopes so completion resolves the same root the runtime
# would. dce_expand_tilde (lib/common/core.sh) implements the same rule, but
# complete-data.sh is sourced into zsh completion, which cannot source core.sh
# (it uses bash-only constructs elsewhere); keep the two in sync if the rule
# changes.
_dce_complete_resolve_root() {
  local val="$1"
  # shellcheck disable=SC2088
  # ~ is a literal char being matched against user input, not an expansion.
  if [[ "$val" == "~" || "$val" == "~/"* ]]; then
    val="$HOME${val#\~}"
  elif [[ "$val" != /* && -n "$val" ]]; then
    val="$HOME/.config/dce-enclave/$val"
  fi
  printf '%s' "$val"
}

# Print the valid targets for `dce rebuild-image`.
dce_complete_rebuild_image_targets() {
  printf '%s\n' "all" "base"
}

# Print the subactions of `dce network` (create/ls/members/rm/add/remove and
# aliases). Mirrors the dispatch table in scripts/network.sh.
dce_complete_network_subactions() {
  printf '%s\n' \
    "create" \
    "ls" \
    "list" \
    "members" \
    "rm" \
    "add" \
    "remove"
}

# Print the subactions of `dce config` (show/get/set/sync-vscode/ls). Mirrors the dispatch
# table in scripts/config.sh.
dce_complete_config_subactions() {
  printf '%s\n' \
    "show" \
    "get" \
    "set" \
    "sync-vscode" \
    "ls"
}

# Print the writable friendly key names for `dce config get/set` (the settable
# vocabulary; read-only keys are intentionally not offered for completion).
dce_complete_config_keys() {
  printf '%s\n' \
    "cpus" \
    "memory" \
    "scopes" \
    "ports" \
    "hide" \
    "networks"
}

# Print the candidate targets for `dce doctor`: the five backend names followed by
# configured project names. A backend name takes priority at runtime when a
# project happens to share one, but completion offers both.
dce_complete_doctor_targets() {
  local cur="${1:-}"
  local d name
  printf '%s\n' apple docker orbstack colima podman
  for d in "$HOME/.config/dce-enclave"/*; do
    [[ -d "$d" && -f "$d/config" ]] || continue
    name="$(basename "$d")"
    [[ -z "$cur" || "$name" == "$cur"* ]] && printf '%s\n' "$name"
  done 2>/dev/null
}

# Print known editor ids for `dce editor --editor <TAB>`. Mirrors the registry
# in lib/editor.sh:dce_editor_known_ids. Kept here (not sourced from
# lib/editor.sh) so completion stays dependency-light -- complete-data.sh is
# sourced into both bash and zsh completion paths and intentionally avoids
# pulling in the runtime lib chain.
dce_complete_editor_ids() {
  printf '%s\n' vscode vscode-insiders
}

# Print the subactions of `dce extensions` (list/host/available/show/diff/
# capture). Mirrors the dispatch table in scripts/extensions.sh.
dce_complete_extensions_subactions() {
  printf '%s\n' \
    "list" \
    "host" \
    "available" \
    "show" \
    "diff" \
    "capture"
}

# Print editor ids that have extension management support, for
# `dce extensions ... --editor <TAB>`. v1: vscode only (a separate, smaller
# subset than dce_complete_editor_ids -- the launcher registry).
dce_complete_extensions_editor_ids() {
  printf '%s\n' vscode
}
