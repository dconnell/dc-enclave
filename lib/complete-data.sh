#!/usr/bin/env bash
# =============================================================================
# lib/complete-data.sh - Shared completion candidate discovery.
#
# Sourced (never executed) by BOTH scripts/dc-complete.bash (bash) and
# scripts/_dc (zsh). This is the single source of truth for project names,
# overlay scopes, subcommands, and rebuild-image targets, so the two
# completion front-ends never duplicate logic -- in particular the hardened,
# no-source global-config parser (_dc_read_overlays_dir), which is a security
# boundary (see tests/config-security.sh).
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

# Read DC_OVERLAYS_DIR from the global config WITHOUT sourcing/executing it.
# Restricted line + quoted-value parsing only: a malicious config line can
# never run code through completion. Echoes the value; returns 1 if absent or
# malformed. (Moved verbatim from scripts/dc-complete.bash -- security boundary.)
_dc_read_overlays_dir() {
  local config="$1"
  local line raw content

  [[ -f "$config" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*DC_OVERLAYS_DIR= ]] || continue
    raw="${line#*=}"
    # Require a double-quoted value.
    if [[ "$raw" != \"*\" ]]; then
      return 1
    fi
    content="${raw#\"}"
    content="${content%\"}"
    # Reject any $/backtick outright (an overlays path never needs them),
    # then undo the minimal escapes the serializer emits. No interpretation
    # means no execution.
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

# Print available overlay scope names discovered from team/ and user/ overlays,
# applying the same DC_OVERLAYS_DIR resolution as the runtime helpers. Order is
# preserved and duplicates removed (first occurrence wins). Dedup uses a
# newline-delimited accumulator so a scope name can never partially match
# another (names cannot contain newlines).
dc_complete_scopes() {
  local config="$HOME/.config/dev-containers/config"
  local overlays_dir=""
  local f name
  local nl=$'\n'
  local seen="$nl"

  if [[ -f "$config" ]]; then
    overlays_dir="$(_dc_read_overlays_dir "$config")" || overlays_dir=""
    if [[ -n "$overlays_dir" ]]; then
      if [[ "$overlays_dir" == "~" || "$overlays_dir" == "~/"* ]]; then
        overlays_dir="$HOME${overlays_dir#\~}"
      elif [[ "$overlays_dir" != /* ]]; then
        overlays_dir="$HOME/.config/dev-containers/$overlays_dir"
      fi
    fi
  fi

  if [[ -z "$overlays_dir" ]]; then
    overlays_dir="$HOME/.config/dev-containers/overlays"
  fi

  [[ -d "$overlays_dir/team" || -d "$overlays_dir/user" ]] || return 0

  # See dc_complete_projects: only zsh needs null-glob (local-scoped).
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt local_options NULL_GLOB
  fi

  for f in "$overlays_dir"/team/Containerfile.* "$overlays_dir"/user/Containerfile.*; do
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
