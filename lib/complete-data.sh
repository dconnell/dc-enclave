#!/usr/bin/env bash
# =============================================================================
# lib/complete-data.sh - Shared completion candidate discovery.
#
# Sourced (never executed) by BOTH scripts/dc-complete.bash (bash) and
# scripts/_dc (zsh). This is the single source of truth for project names,
# overlay scopes, subcommands, and rebuild-image targets, so the two
# completion front-ends never duplicate logic -- in particular the hardened,
# no-source global-config parsers (_dc_read_team_dir / _dc_read_user_dir),
# which are a security boundary (see tests/config-security.sh).
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

# Print the static list of dc subcommands (including aliases and version/help
# spellings). Mirrors the dispatch table in scripts/dc.
dc_complete_subcommands() {
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
    "exec" \
    "restart" \
    "rm" \
    "rebuild-container" \
    "rebuild-image" \
    "provenance" \
    "clean" \
    "network" \
    "net" \
    "doctor" \
    "install" \
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
# absent or malformed. (Moved verbatim from scripts/dc-complete.bash and
# generalized for the two-root layout -- security boundary.)
_dc_read_config_root() {
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

_dc_read_team_dir() { _dc_read_config_root "$1" DC_TEAM_DIR; }
_dc_read_user_dir() { _dc_read_config_root "$1" DC_USER_DIR; }

# Print configured project names (dirs under ~/.config/dev-containers with a
# `config` file). When $1 is non-empty, only names with that prefix are printed.
dc_complete_projects() {
  local cur="${1:-}"
  local base="$HOME/.config/dev-containers"
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
dc_complete_scopes() {
  local config="$HOME/.config/dev-containers/config"
  local team_dir="" user_dir=""
  local f name
  local nl=$'\n'
  local seen="$nl"

  if [[ -f "$config" ]]; then
    team_dir="$(_dc_read_team_dir "$config")" || team_dir=""
    user_dir="$(_dc_read_user_dir "$config")" || user_dir=""
    team_dir="$(_dc_complete_resolve_root "$team_dir")"
    user_dir="$(_dc_complete_resolve_root "$user_dir")"
  fi

  [[ -z "$team_dir" ]] && team_dir="$HOME/.config/dev-containers/team"
  [[ -z "$user_dir" ]] && user_dir="$HOME/.config/dev-containers/user"

  local team_od="$team_dir/overlays"
  local user_od="$user_dir/overlays"
  [[ -d "$team_od" || -d "$user_od" ]] || return 0

  # See dc_complete_projects: only zsh needs null-glob (local-scoped).
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
# Used by dc_complete_scopes so completion resolves the same root the runtime
# would.
_dc_complete_resolve_root() {
  local val="$1"
  if [[ "$val" == "~" || "$val" == "~/"* ]]; then
    val="$HOME${val#\~}"
  elif [[ "$val" != /* && -n "$val" ]]; then
    val="$HOME/.config/dev-containers/$val"
  fi
  printf '%s' "$val"
}

# Print the valid targets for `dc rebuild-image`.
dc_complete_rebuild_image_targets() {
  printf '%s\n' "all" "base"
}

# Print the subactions of `dc network` (create/ls/members/rm/add/remove and
# aliases). Mirrors the dispatch table in scripts/network.sh.
dc_complete_network_subactions() {
  printf '%s\n' \
    "create" \
    "ls" \
    "list" \
    "members" \
    "rm" \
    "add" \
    "remove"
}

# Print the candidate targets for `dc doctor`: the five backend names followed by
# configured project names. A backend name takes priority at runtime when a
# project happens to share one, but completion offers both.
dc_complete_doctor_targets() {
  local cur="${1:-}"
  local name
  printf '%s\n' apple docker orbstack colima podman
  for d in "$HOME/.config/dev-containers"/*; do
    [[ -d "$d" && -f "$d/config" ]] || continue
    name="$(basename "$d")"
    [[ -z "$cur" || "$name" == "$cur"* ]] && printf '%s\n' "$name"
  done 2>/dev/null
}
