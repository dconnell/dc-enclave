#!/usr/bin/env bash
# =============================================================================
# scripts/dc-complete.bash - Bash tab completion for the `dc` command.
#
# Sourced into the interactive shell by setup.sh (not executed). Provides
# subcommand, project-name, scope, and flag completion. Project/scope lists are
# derived live from ~/.config/dev-containers and the configured overlays dir.
# =============================================================================

# Echo configured project names (dirs with a config file) matching the prefix.
_dc_project_names() {
  local cur="${1:-}"
  local -a names=()
  local d

  for d in "$HOME"/.config/dev-containers/*; do
    [[ -d "$d" && -f "$d/config" ]] || continue
    local name=""
    name="$(basename "$d")"
    if [[ -z "$cur" || "$name" == "$cur"* ]]; then
      names+=("$name")
    fi
  done

  printf '%s\n' "${names[@]}"
}

# Echo the static list of dc subcommands (including aliases).
_dc_subcommands() {
  printf '%s\n' \
    "new" \
    "start" \
    "stop" \
    "status" \
    "s" \
    "list" \
    "ls" \
    "shell" \
    "rebuild-container" \
    "rebuild-image" \
    "clean" \
    "install" \
    "help"
}

# Read DC_OVERLAYS_DIR from the global config WITHOUT sourcing/executing it.
# Restricted line + quoted-value parsing only: a malicious config line can never
# run code through completion. Echoes the value; returns 1 if absent/malformed.
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
    # Reject any $/backtick outright (an overlays path never needs them), then
    # undo the minimal escapes the serializer emits. No interpretation = no exec.
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

# Echo available overlay scope names discovered from team/ and user/ overlays,
# applying the same DC_OVERLAYS_DIR resolution as the runtime helpers.
_dc_scopes() {
  local config="$HOME/.config/dev-containers/config"
  local overlays_dir=""
  local f name
  local -A seen=()

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

  for f in "$overlays_dir"/team/Containerfile.* "$overlays_dir"/user/Containerfile.*; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f")"
    name="${name#Containerfile.}"
    [[ -z "$name" ]] && continue
    [[ -n "${seen[$name]:-}" ]] && continue
    seen["$name"]=1
    printf '%s\n' "$name"
  done
}

# Echo the valid targets for `dc rebuild-image`.
_dc_rebuild_image_targets() {
  printf '%s\n' "all" "base"
}

# Main completion entry point bound to `dc` via `complete -F`.
_dc_complete() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  if [[ $COMP_CWORD -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$(_dc_subcommands)" -- "$cur") )
    return 0
  fi

  local cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    new)
      if [[ $COMP_CWORD -eq 2 ]]; then
        return 0
      fi
      if [[ "$prev" == "--repo-path" ]]; then
        COMPREPLY=( $(compgen -d -- "$cur") )
        return 0
      fi
      if [[ "$prev" == "--cpus" || "$prev" == "--memory" || "$prev" == "--hide" ]]; then
        return 0
      fi
      local flags="--repo-path --cpus --memory --hide"
      if [[ $COMP_CWORD -eq 3 ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_scopes) $flags" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "$flags" -- "$cur") )
      fi
      ;;
    start|stop|shell|rebuild-container|install)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_project_names "$cur")" -- "$cur") )
        return 0
      fi
      if [[ "$cmd" == "rebuild-container" && $COMP_CWORD -ge 3 ]]; then
        COMPREPLY=( $(compgen -W "--rotate-keys --keep-hidden-volumes" -- "$cur") )
      fi
      if [[ "$cmd" == "install" && $COMP_CWORD -eq 3 ]]; then
        COMPREPLY=( $(compgen -d -- "$cur") )
      fi
      ;;
    rebuild-image)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_rebuild_image_targets)" -- "$cur") )
      fi
      ;;
    clean)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "--dry-run --hidden-volumes" -- "$cur") )
      elif [[ "$prev" == "--hidden-volumes" ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_project_names "$cur")" -- "$cur") )
      fi
      ;;
  esac
}

complete -F _dc_complete dc
