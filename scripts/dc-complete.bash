#!/usr/bin/env bash
# Bash completion for the dc command.

if [[ -z "${_DC_ROOT_DIR:-}" ]]; then
  _dc_source_path="${BASH_SOURCE[0]:-}"
  if [[ -n "$_dc_source_path" && -f "$_dc_source_path" ]]; then
    while [[ -L "$_dc_source_path" ]]; do
      _dc_source_dir="$(cd -P "$(dirname "$_dc_source_path")" && pwd)"
      _dc_source_path="$(readlink "$_dc_source_path")"
      [[ "$_dc_source_path" != /* ]] && _dc_source_path="$_dc_source_dir/$_dc_source_path"
    done

    _dc_source_dir="$(cd -P "$(dirname "$_dc_source_path")" && pwd)"
    _DC_ROOT_DIR="$(cd "$_dc_source_dir/.." && pwd)"
  fi
  unset _dc_source_path _dc_source_dir
fi

_dc_complete_root_dir() {
  if [[ -n "${_DC_ROOT_DIR:-}" ]] && [[ -d "$_DC_ROOT_DIR/projects" ]]; then
    printf '%s\n' "$_DC_ROOT_DIR"
    return 0
  fi

  local alias_line=""
  local alias_target=""
  local dc_path=""

  alias_line="$(alias dc 2>/dev/null || true)"
  if [[ -n "$alias_line" ]]; then
    case "$alias_line" in
      alias\ dc=*)
        alias_target="${alias_line#alias dc=}"
        ;;
      dc=*)
        alias_target="${alias_line#dc=}"
        ;;
    esac
    alias_target="${alias_target#\'}"
    alias_target="${alias_target%\'}"
    alias_target="${alias_target#\"}"
    alias_target="${alias_target%\"}"
    alias_target="${alias_target%% *}"

    if [[ -n "$alias_target" && -f "$alias_target" ]]; then
      _DC_ROOT_DIR="$(cd "$(dirname "$alias_target")/.." && pwd)"
      if [[ -d "$_DC_ROOT_DIR/projects" ]]; then
        printf '%s\n' "$_DC_ROOT_DIR"
        return 0
      fi
    fi
  fi

  dc_path="$(type -P dc 2>/dev/null || true)"
  if [[ -n "$dc_path" && -f "$dc_path" ]]; then
    _DC_ROOT_DIR="$(cd "$(dirname "$dc_path")/.." && pwd)"
    if [[ -d "$_DC_ROOT_DIR/projects" ]]; then
      printf '%s\n' "$_DC_ROOT_DIR"
      return 0
    fi
  fi

  local source_path="${BASH_SOURCE[0]:-}"
  local dir=""

  if [[ -n "$source_path" && -f "$source_path" ]]; then
    while [[ -L "$source_path" ]]; do
      dir="$(cd -P "$(dirname "$source_path")" && pwd)"
      source_path="$(readlink "$source_path")"
      [[ "$source_path" != /* ]] && source_path="$dir/$source_path"
    done

    dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    _DC_ROOT_DIR="$(cd "$dir/.." && pwd)"
    if [[ -d "$_DC_ROOT_DIR/projects" ]]; then
      printf '%s\n' "$_DC_ROOT_DIR"
      return 0
    fi
  fi

  return 1
}

_dc_project_names() {
  local cur="${1:-}"
  local root_dir=""
  root_dir="$(_dc_complete_root_dir)" || return 0

  local projects_dir="$root_dir/projects"
  local -a names=()

  if [[ -d "$projects_dir" ]]; then
    local d
    for d in "$projects_dir"/*; do
      [[ -d "$d" && -f "$d/config" ]] || continue
      local name=""
      name="$(basename "$d")"
      if [[ -z "$cur" || "$name" == "$cur"* ]]; then
        names+=("$name")
      fi
    done
  fi

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
      if [[ $COMP_CWORD -eq 3 ]]; then
        COMPREPLY=( $(compgen -W "$(_dc_types)" -- "$cur") )
      fi
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
