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
    "repo" \
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

# Echo the default host repos root (`${DC_REPOS_DIR:-$HOME/repos}`) with a
# leading `~` expanded. Kept local to completion so bash/zsh can discover repo
# candidates without sourcing the full runtime lib chain.
_dce_complete_default_repos_root() {
  local val="${DC_REPOS_DIR:-$HOME/repos}"
  # shellcheck disable=SC2088
  # ~ is a literal char being matched against user input, not an expansion.
  if [[ "$val" == "~" || "$val" == "~/"* ]]; then
    val="$HOME${val#\~}"
  fi
  printf '%s' "$val"
}

# Parse one simple shell-style array assignment from a project config WITHOUT
# sourcing it. Accepts the exact `printf %q`-style form emitted by dce's config
# writers: KEY=( elem ... ). Echoes one decoded element per line.
_dce_complete_extract_array() {
  local file="$1" key="$2"
  local line="" raw=""

  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$key="* ]] || continue
    raw="${line#*=}"
    [[ "${raw:0:1}" == "(" && "${raw: -1}" == ")" ]] || return 1
    raw="${raw#(}"
    raw="${raw%)}"
    raw="${raw# }"
    raw="${raw% }"
    [[ -n "$raw" ]] || return 0

    local token="" ch="" i=0 escaped=0
    for ((i = 0; i < ${#raw}; i++)); do
      ch="${raw:i:1}"
      if (( escaped )); then
        token+="$ch"
        escaped=0
        continue
      fi
      # shellcheck disable=SC1003
      # '\\' is a literal single-backslash comparison.
      if [[ "$ch" == '\\' ]]; then
        escaped=1
        continue
      fi
      if [[ "$ch" == ' ' ]]; then
        if [[ -n "$token" ]]; then
          printf '%s\n' "$token"
          token=""
        fi
        continue
      fi
      token+="$ch"
    done
    [[ -n "$token" ]] && printf '%s\n' "$token"
    return 0
  done < "$file"

  return 1
}

# Print the subactions of `dce repo` (list/add/remove). Mirrors the dispatch
# table in scripts/repo.sh.
dce_complete_repo_subactions() {
  printf '%s\n' \
    "list" \
    "add" \
    "remove"
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

# Print configured project names (dirs under ~/.config/dc-enclave/projects with
# a `config` file). When $1 is non-empty, only names with that prefix are
# printed.
dce_complete_projects() {
  local cur="${1:-}"
  local base="$HOME/.config/dc-enclave/projects"
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

# Print the configured repo names for one project (REPO_NAMES), optionally
# filtered by a prefix. Parsed directly from the project config so completion
# does not need to source project config files.
dce_complete_project_repos() {
  local project="$1"
  local cur="${2:-}"
  local config="$HOME/.config/dc-enclave/projects/$project/config"
  local name=""

  [[ -f "$config" ]] || return 0

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ -z "$cur" || "$name" == "$cur"* ]]; then
      printf '%s\n' "$name"
    fi
  done < <(_dce_complete_extract_array "$config" REPO_NAMES)
}

# Print directories under the default repos root, optionally filtered by a
# prefix. Used for `shell` / `exec` `--repo <name>` completion.
dce_complete_repo_root_names() {
  local cur="${1:-}"
  local root=""
  local d name

  root="$(_dce_complete_default_repos_root)"
  [[ -d "$root" ]] || return 0

  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt local_options NULL_GLOB
  fi

  for d in "$root"/*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -z "$cur" || "$name" == "$cur"* ]]; then
      printf '%s\n' "$name"
    fi
  done
}

# Print the configured hidden-volume paths for one project (CONTAINER_HIDDEN_PATHS),
# optionally filtered by a prefix. Parsed directly from the project config.
dce_complete_project_hidden_paths() {
  local project="$1"
  local cur="${2:-}"
  local config="$HOME/.config/dc-enclave/projects/$project/config"
  local path=""

  [[ -f "$config" ]] || return 0

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ -z "$cur" || "$path" == "$cur"* ]]; then
      printf '%s\n' "$path"
    fi
  done < <(_dce_complete_extract_array "$config" CONTAINER_HIDDEN_PATHS)
}

# Print the configured network names for one project (CONTAINER_NETWORKS),
# optionally filtered by a prefix. The stored form is <name> or <name>:<ip>.
dce_complete_project_networks() {
  local project="$1"
  local cur="${2:-}"
  local config="$HOME/.config/dc-enclave/projects/$project/config"
  local entry="" name=""

  [[ -f "$config" ]] || return 0

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    name="${entry%%:*}"
    if [[ -z "$cur" || "$name" == "$cur"* ]]; then
      printf '%s\n' "$name"
    fi
  done < <(_dce_complete_extract_array "$config" CONTAINER_NETWORKS)
}

# Print the union of configured network names across all projects, filtered by a
# prefix. Used for `dce network` completions without requiring backend access.
dce_complete_network_names() {
  local cur="${1:-}"
  local config="" project="" seen=""
  local name=""

  while IFS= read -r config; do
    [[ -f "$config" ]] || continue
    project="$(basename "$(dirname "$config")")"
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      case " $seen " in
        *" $name "*) continue ;;
      esac
      seen+=" $name"
      printf '%s\n' "$name"
    done < <(dce_complete_project_networks "$project" "$cur")
  done < <(printf '%s\n' "$HOME/.config/dc-enclave/projects"/*/config)
}

# Print snapshot labels recorded for one project, filtered by a prefix. Labels
# come from the snapshot manifest names (<label>.volumes) under the project dir.
dce_complete_snapshot_labels() {
  local project="$1"
  local cur="${2:-}"
  local dir="$HOME/.config/dc-enclave/projects/$project/snapshots"
  local file="" label=""

  [[ -d "$dir" ]] || return 0

  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt local_options NULL_GLOB
  fi

  for file in "$dir"/*.volumes; do
    [[ -f "$file" ]] || continue
    label="$(basename "$file" .volumes)"
    if [[ -z "$cur" || "$label" == "$cur"* ]]; then
      printf '%s\n' "$label"
    fi
  done
}

# Print the writable and read-only friendly key names accepted by `dce config
# get`. `set` intentionally keeps the smaller writable-only key set.
dce_complete_config_get_keys() {
  printf '%s\n' \
    "cpus" \
    "memory" \
    "scopes" \
    "ports" \
    "hide" \
    "networks" \
    "project" \
    "backend" \
    "image" \
    "repos"
}

# Print available overlay scope names discovered from the team and user
# overlays/ leaf directories, applying the same DC_TEAM_DIR / DC_USER_DIR
# resolution as the runtime helpers. Order is preserved and duplicates removed
# (first occurrence wins). Dedup uses a newline-delimited accumulator so a
# scope name can never partially match another (names cannot contain newlines).
dce_complete_scopes() {
  local config="$HOME/.config/dc-enclave/config"
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

  [[ -z "$team_dir" ]] && team_dir="$HOME/.config/dc-enclave/team"
  [[ -z "$user_dir" ]] && user_dir="$HOME/.config/dc-enclave/user"

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
    val="$HOME/.config/dc-enclave/$val"
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
  for d in "$HOME/.config/dc-enclave/projects"/*; do
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
