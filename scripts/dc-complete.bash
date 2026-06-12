#!/usr/bin/env bash
# Bash completion for the dc command.

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
    "rebuild" \
    "rebuild-image" \
    "clean" \
    "install" \
    "help"
}

_dc_types() {
  printf '%s\n' "nodejs" "golang" "nodejs,golang"
}

_dc_rebuild_image_targets() {
  printf '%s\n' "all" "base" "nodejs" "golang"
}

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
      if [[ "$prev" == "--overlay-containerfile" ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
        return 0
      fi
      if [[ $COMP_CWORD -eq 3 ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_types)" -- "$cur") )
        return 0
      fi
      COMPREPLY=( $(compgen -W "--repo-path --overlay-containerfile" -- "$cur") )
      ;;
    start|stop|shell|rebuild|install)
      if [[ $COMP_CWORD -eq 2 ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_project_names "$cur")" -- "$cur") )
        return 0
      fi
      if [[ "$cmd" == "rebuild" && $COMP_CWORD -eq 3 ]]; then
        COMPREPLY=( $(compgen -W "--rotate-keys" -- "$cur") )
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
        COMPREPLY=( $(compgen -W "--dry-run" -- "$cur") )
      fi
      ;;
  esac
}

complete -F _dc_complete dc
