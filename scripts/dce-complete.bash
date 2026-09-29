#!/usr/bin/env bash
# =============================================================================
# scripts/dce-complete.bash - Bash tab completion for the `dce` command.
#
# Sourced into the interactive bash shell by setup.sh (not executed). Provides
# subcommand, project-name, scope, and flag completion. Project/scope lists are
# derived live via lib/complete-data.sh, which is shared with the native zsh
# completion (scripts/_dce) so discovery logic -- including the hardened
# global-config parser -- lives in exactly one place.
# =============================================================================

# Resolve this file's directory so we can source the shared discovery library.
# (The file is sourced from an absolute path in the shell profile, so
# ${BASH_SOURCE[0]} is reliable here.)
_dce_complete_self_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
_dce_scripts_dir="$(_dce_complete_self_dir)"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$_dce_scripts_dir/../lib/complete-data.sh"
unset -f _dce_complete_self_dir
unset _dce_scripts_dir

# Main completion entry point bound to `dce` via `complete -F`.
#
# Per-subcommand grammar mirrors the real argument parsing in scripts/*.sh:
#   start|stop              : variadic project names (0 args == all)
#   shell                   : one project, then [--repo <name>], then free-form command
#   editor                  : one project, then [--editor <id>]
#   rebuild-container       : one project + --rotate-keys / --inject-creds /
#                             --keep-hidden-volumes / --from-snap
#   install                 : one project + one dotfiles directory
#   rotate-token            : one project
#   rebuild-image           : one of {all, base}
#   clean                   : --dry-run / --hidden-volumes, then at most one
#                             project (only meaningful with --hidden-volumes)
#   new                     : <name> [scope] [--config <file>] [--save-team]
#                             [--save-user] [--git-host <provider>]
#                             [--repo <spec>] [--cpus N]
#                             [--memory V] [--hide <path>] [--yes|-y]
#                             [port:port ...]
_dce_complete() {
  local cur prev cmd
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  # First word is always a subcommand.
  if [[ $COMP_CWORD -eq 1 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_subcommands)" -- "$cur")
    return 0
  fi

  cmd="${COMP_WORDS[1]}"

  case "$cmd" in
    start|stop|restart)
      # Variadic: complete a project at any position >= 2, excluding projects
      # already typed on this line so `dce start a b <TAB>` offers the rest.
      local -a used=()
      local w
      for w in "${COMP_WORDS[@]:2:COMP_CWORD-2}"; do
        [[ -n "$w" ]] && used+=("$w")
      done
      _dce_reply_projects_excluding "$cur" "${used[@]}"
      return 0
      ;;
    shell)
      _dce_complete_shell "$cur" "$prev"
      return 0
      ;;
    editor)
      _dce_complete_editor "$cur" "$prev"
      return 0
      ;;
    logs)
      # One project, then log flags (--tail takes a value, not completed).
      if [[ $COMP_CWORD -eq 2 ]]; then
        _dce_reply_projects "$cur"
        return 0
      fi
      [[ "$prev" == "--tail" ]] && return 0
      mapfile -t COMPREPLY < <(compgen -W "--follow -f --tail" -- "$cur")
      return 0
      ;;
    exec)
      _dce_complete_exec "$cur" "$prev"
      return 0
      ;;
    rm)
      # One project, then removal flags.
      if [[ $COMP_CWORD -eq 2 ]]; then
        _dce_reply_projects "$cur"
        return 0
      fi
      mapfile -t COMPREPLY < <(compgen -W "--yes -y --keep-config --keep-volumes" -- "$cur")
      return 0
      ;;
    rebuild-container)
      if [[ $COMP_CWORD -eq 2 ]]; then
        _dce_reply_projects "$cur"
        return 0
      fi
      if [[ "$prev" == "--from-snap" ]]; then
        _dce_reply_snapshot_labels "${COMP_WORDS[2]:-}" "$cur"
        return 0
      fi

      local have_from_snap=0 _w
      for _w in "${COMP_WORDS[@]:3:COMP_CWORD-3}"; do
        [[ "$_w" == "--from-snap" ]] && have_from_snap=1
      done

      # >= 3: optional flags (order-independent), but don't suggest --from-snap
      # once it is already present.
      local rb_flags="--rotate-keys --inject-creds --keep-hidden-volumes --yes -y"
      [[ $have_from_snap -eq 0 ]] && rb_flags+=" --from-snap"

      mapfile -t COMPREPLY < <(compgen -W "$rb_flags" -- "$cur")
      return 0
      ;;
    snapshot)
      _dce_complete_snapshot "$cur" "$prev"
      return 0
      ;;
    snapshots)
      _dce_complete_snapshots "$cur" "$prev"
      return 0
      ;;
    install)
      if [[ $COMP_CWORD -eq 2 ]]; then
        _dce_reply_projects "$cur"
      elif [[ $COMP_CWORD -eq 3 ]]; then
        mapfile -t COMPREPLY < <(compgen -d -- "$cur")
      fi
      return 0
      ;;
    rotate-token)
      if [[ $COMP_CWORD -eq 2 ]]; then
        _dce_reply_projects "$cur"
      fi
      return 0
      ;;
    rebuild-image)
      if [[ $COMP_CWORD -eq 2 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_rebuild_image_targets)" -- "$cur")
      fi
      return 0
      ;;
    provenance)
      if [[ $COMP_CWORD -eq 2 ]]; then
        _dce_reply_projects "$cur"
        return 0
      fi
      mapfile -t COMPREPLY < <(compgen -W "--history --all" -- "$cur")
      return 0
      ;;
    clean)
      _dce_complete_clean "$cur" "$prev"
      return 0
      ;;
    doctor)
      mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_doctor_targets "$cur")" -- "$cur")
      return 0
      ;;
    network|net)
      _dce_complete_network "$cur" "$prev"
      return 0
      ;;
    repo)
      _dce_complete_repo "$cur" "$prev"
      return 0
      ;;
    config)
      _dce_complete_config "$cur" "$prev"
      return 0
      ;;
    new)
      _dce_complete_new "$cur" "$prev"
      return 0
      ;;
    extensions)
      _dce_complete_extensions "$cur" "$prev"
      return 0
      ;;
    help)
      _dce_complete_help "$cur"
      return 0
      ;;
  esac
}

# Fill COMPREPLY with project names matching $1, optionally excluding the
# project names passed in $2.. (already present on the command line).
_dce_reply_projects() {
  local cur="$1"
  shift
  _dce_reply_projects_excluding "$cur" "$@"
}

_dce_reply_projects_excluding() {
  local cur="$1"
  shift
  local -A exclude=()
  local p
  for p in "$@"; do
    exclude["$p"]=1
  done

  local -a out=()
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ -n "${exclude[$name]:-}" ]] && continue
    out+=("$name")
  done < <(dce_complete_projects "$cur")

  COMPREPLY=("${out[@]}")
}

_dce_reply_project_repos() {
  local project="$1" cur="$2"
  local -a out=()
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    out+=("$name")
  done < <(dce_complete_project_repos "$project" "$cur")
  COMPREPLY=("${out[@]}")
}

_dce_reply_project_hidden_paths() {
  local project="$1" cur="$2"
  local -a out=()
  local path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    out+=("$path")
  done < <(dce_complete_project_hidden_paths "$project" "$cur")
  COMPREPLY=("${out[@]}")
}

_dce_reply_networks() {
  local cur="$1"
  local -a out=()
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    out+=("$name")
  done < <(dce_complete_network_names "$cur")
  COMPREPLY=("${out[@]}")
}

_dce_reply_snapshot_labels() {
  local project="$1" cur="$2"
  local -a out=()
  local label
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    out+=("$label")
  done < <(dce_complete_snapshot_labels "$project" "$cur")
  COMPREPLY=("${out[@]}")
}

_dce_reply_repo_specs() {
  local cur="$1"
  local prefix=""
  local path_cur="$cur"
  local search="$path_cur"
  local home_prefix=""

  if [[ "$cur" == *=* ]]; then
    prefix="${cur%%=*}="
    path_cur="${cur#*=}"
  fi

  case "$path_cur" in
    ""|[^./~]*)
      search="$(_dce_complete_default_repos_root)/$path_cur"
      ;;
    ~|~/*)
      search="$HOME${path_cur#\~}"
      home_prefix="$HOME"
      ;;
    *)
      search="$path_cur"
      ;;
  esac

  mapfile -t COMPREPLY < <(compgen -d -- "$search")
  if [[ -n "$home_prefix" ]]; then
    local i
    for ((i=0; i<${#COMPREPLY[@]}; i++)); do
      COMPREPLY[$i]="~${COMPREPLY[$i]#"$home_prefix"}"
    done
  fi
  if [[ -n "$prefix" ]]; then
    local i
    for ((i=0; i<${#COMPREPLY[@]}; i++)); do
      COMPREPLY[$i]="${prefix}${COMPREPLY[$i]}"
    done
  fi
}

_dce_complete_shell() {
  local cur="$1" prev="$2"
  if [[ $COMP_CWORD -eq 2 ]]; then
    _dce_reply_projects "$cur"
    return 0
  fi
  if [[ "$prev" == "--repo" ]]; then
    _dce_reply_project_repos "${COMP_WORDS[2]:-}" "$cur"
    return 0
  fi

  local skip_next=0 command_started=0 repo_done=0 w
  for w in "${COMP_WORDS[@]:3:COMP_CWORD-3}"; do
    if (( skip_next )); then
      skip_next=0
      repo_done=1
      continue
    fi
    case "$w" in
      --) command_started=1 ;;
      --repo) skip_next=1 ;;
      -*) : ;;
      *) command_started=1 ;;
    esac
    (( command_started )) && break
  done
  if (( !command_started && !repo_done )); then
    [[ -z "$cur" || "--repo" == "$cur"* ]] && COMPREPLY+=("--repo")
  fi
}

_dce_complete_editor() {
  local cur="$1" prev="$2"
  if [[ $COMP_CWORD -eq 2 ]]; then
    _dce_reply_projects "$cur"
    return 0
  fi
  if [[ "$prev" == "--editor" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_editor_ids)" -- "$cur")
    return 0
  fi

  local skip_next=0 done=0 w
  for w in "${COMP_WORDS[@]:3:COMP_CWORD-3}"; do
    if (( skip_next )); then
      skip_next=0
      done=1
      continue
    fi
    case "$w" in
      --editor) skip_next=1 ;;
      -*) : ;;
      *) done=1 ;;
    esac
    (( done )) && break
  done
  if (( !done )); then
    [[ -z "$cur" || "--editor" == "$cur"* ]] && COMPREPLY+=("--editor")
  fi
}

_dce_complete_exec() {
  local cur="$1" prev="$2"
  if [[ $COMP_CWORD -eq 2 ]]; then
    _dce_reply_projects "$cur"
    return 0
  fi
  if [[ "$prev" == "--repo" ]]; then
    _dce_reply_project_repos "${COMP_WORDS[2]:-}" "$cur"
    return 0
  fi

  local skip_next=0 command_started=0 seen_root=0 seen_repo=0 repo_done=0 w
  for w in "${COMP_WORDS[@]:3:COMP_CWORD-3}"; do
    if (( skip_next )); then
      skip_next=0
      seen_repo=1
      repo_done=1
      continue
    fi
    case "$w" in
      --) command_started=1 ;;
      --repo) skip_next=1 ;;
      --repo=*) seen_repo=1 ;;
      --root|--root=*) seen_root=1 ;;
      -*) : ;;
      *) command_started=1 ;;
    esac
    (( command_started )) && break
  done
  if (( command_started || repo_done )); then
    return 0
  fi
  if (( !seen_repo )); then
    [[ -z "$cur" || "--repo" == "$cur"* ]] && COMPREPLY+=("--repo")
  fi
  if (( !seen_root )); then
    [[ -z "$cur" || "--root" == "$cur"* ]] && COMPREPLY+=("--root")
  fi
}

# `dce clean [--dry-run] [--hidden-volumes [name]] [--snapshots [name]]`: flags
# are always offered; a single optional project is offered once --hidden-volumes
# or --snapshots is active and no project has been typed yet.
_dce_complete_clean() {
  local cur="$1" prev="$2"
  local -a reply=()

  # Always allow the flags at any position.
  local f
  for f in --dry-run --hidden-volumes --snapshots; do
    if [[ -z "$cur" || "$f" == "$cur"* ]]; then
      reply+=("$f")
    fi
  done

  # Track whether a scoping flag is present and whether a project is typed.
  local have_scope=0 have_proj=0 w
  for ((i=2; i<COMP_CWORD; i++)); do
    w="${COMP_WORDS[i]}"
    case "$w" in
      --dry-run|--hidden-volumes|--snapshots) ;;
      --*) ;;
      *)
        if [[ $have_scope -eq 1 && $have_proj -eq 0 ]]; then
          have_proj=1
        fi
        ;;
    esac
    [[ "$w" == "--hidden-volumes" || "$w" == "--snapshots" ]] && have_scope=1
  done

  # Offer a project when the previous word was a scoping flag, or generally when
  # a scope is active and no project has been given yet.
  if [[ "$prev" == "--hidden-volumes" || "$prev" == "--snapshots" ]] \
     || { [[ $have_scope -eq 1 && $have_proj -eq 0 ]]; }; then
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      reply+=("$name")
    done < <(dce_complete_projects "$cur")
  fi

  COMPREPLY=("${reply[@]}")
}

# `dce snapshot <project> [<label>] [--exclude-volumes]` (create) or `dce
# snapshot rm <project> <label>` (remove). Position 2 offers `rm` and project
# names; --exclude-volumes is offered on the create path; after `rm`, position 3
# is a project and position 4 a snapshot label.
_dce_complete_snapshot() {
  local cur="$1" prev="$2"

  # Detect whether `rm` was already typed.
  local have_rm=0 w positional=0
  for ((i=2; i<COMP_CWORD; i++)); do
    w="${COMP_WORDS[i]}"
    [[ -z "$w" ]] && continue
    [[ "$w" == "rm" && $have_rm -eq 0 ]] && { have_rm=1; continue; }
    if [[ "$w" != -* ]]; then positional=$((positional+1)); fi
  done

  if [[ $COMP_CWORD -eq 2 ]]; then
    local -a reply=()
    [[ -z "$cur" || "rm" == "$cur"* ]] && reply+=("rm")
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      reply+=("$name")
    done < <(dce_complete_projects "$cur")
    COMPREPLY=("${reply[@]}")
    return 0
  fi

  # After `rm`: position 3 is a project; position 4 is a snapshot label.
  if [[ $have_rm -eq 1 ]]; then
    if [[ $positional -eq 0 ]]; then
      _dce_reply_projects "$cur"
    elif [[ $positional -eq 1 ]]; then
      _dce_reply_snapshot_labels "${COMP_WORDS[3]:-}" "$cur"
    fi
    return 0
  fi

  # create path: offer the create flags once a project is present.
  local -a sflags=()
  [[ -z "$cur" || "--exclude-volumes" == "$cur"* ]] && sflags+=("--exclude-volumes")
  [[ -z "$cur" || "--exclude-volume" == "$cur"* ]] && sflags+=("--exclude-volume")
  [[ -z "$cur" || "--yes" == "$cur"* ]] && sflags+=("--yes")
  [[ -z "$cur" || "-y" == "$cur"* ]] && sflags+=("-y")
  # --exclude-volume consumes a value (a hidden path); complete that path and do
  # not offer more flags in the same slot.
  if [[ "$prev" == "--exclude-volume" ]]; then
    _dce_reply_project_hidden_paths "${COMP_WORDS[2]:-}" "$cur"
  else
    COMPREPLY+=("${sflags[@]}")
  fi
  return 0
}

# `dce snapshots list [<project>]`.
_dce_complete_snapshots() {
  local cur="$1" prev="$2"
  if [[ $COMP_CWORD -eq 2 ]]; then
    local -a reply=()
    [[ -z "$cur" || "list" == "$cur"* ]] && reply+=("list")
    local name
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      reply+=("$name")
    done < <(dce_complete_projects "$cur")
    COMPREPLY=("${reply[@]}")
    return 0
  fi
  # After `list`, an optional project may follow.
  if [[ "$prev" == "list" ]]; then
    _dce_reply_projects "$cur"
  fi
  return 0
}

# `dce new <name> [scope] [flags] [port:port ...]`.
_dce_complete_new() {
  local cur="$1" prev="$2"

  # name (position 2) is free text -- no completion offered.
  [[ $COMP_CWORD -eq 2 ]] && return 0

  # Flags that consume a following value.
  case "$prev" in
    --config)
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return 0
      ;;
    --repo)
      _dce_reply_repo_specs "$cur"
      return 0
      ;;
    --cpus|--memory|--hide|--network|--ip)
      return 0
      ;;
    --git-host)
      mapfile -t COMPREPLY < <(compgen -W "github gitlab" -- "$cur")
      return 0
      ;;
  esac

  local flags="--config --save-team --save-user --git-host --repo --cpus --memory --hide --network --ip --yes -y"
  if [[ $COMP_CWORD -eq 3 ]]; then
    # Second positional: a scope (with flags also accepted).
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_scopes) $flags" -- "$cur")
  else
    mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
  fi
}

# `dce repo <list|add|remove> ...`: subactions at position 2. `repo add` accepts
# an optional --yes/-y before the project; repo selectors/specs remain free-form.
_dce_complete_repo() {
  local cur="$1" prev="$2"

  if [[ $COMP_CWORD -eq 2 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_repo_subactions)" -- "$cur")
    return 0
  fi

  if [[ "${COMP_WORDS[2]}" == "add" ]]; then
    if [[ "$prev" == "--yes" || "$prev" == "-y" ]]; then
      _dce_reply_projects "$cur"
      return 0
    fi
    if [[ $COMP_CWORD -eq 3 ]]; then
      mapfile -t COMPREPLY < <(compgen -W "--yes -y $(dce_complete_projects "$cur")" -- "$cur")
      return 0
    fi
    if [[ ( "${COMP_WORDS[3]:-}" == "--yes" || "${COMP_WORDS[3]:-}" == "-y" ) && $COMP_CWORD -eq 4 ]]; then
      _dce_reply_projects "$cur"
      return 0
    fi
    if [[ $COMP_CWORD -eq 4 && "${COMP_WORDS[3]:-}" != "--yes" && "${COMP_WORDS[3]:-}" != "-y" ]]; then
      _dce_reply_repo_specs "$cur"
      return 0
    fi
    if [[ ( "${COMP_WORDS[3]:-}" == "--yes" || "${COMP_WORDS[3]:-}" == "-y" ) && $COMP_CWORD -eq 5 ]]; then
      _dce_reply_repo_specs "$cur"
      return 0
    fi
    return 0
  fi

  case "${COMP_WORDS[2]}" in
    list|remove)
      if [[ $COMP_CWORD -eq 3 ]]; then
        _dce_reply_projects "$cur"
      fi
      return 0
      ;;
  esac
}

# `dce network <subaction> ...`: subactions at position 2; afterwards complete
# known network names and project names from config where appropriate.
_dce_complete_network() {
  local cur="$1" prev="$2"

  if [[ $COMP_CWORD -eq 2 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_network_subactions)" -- "$cur")
    return 0
  fi

  local sub="${COMP_WORDS[2]:-}"

  case "$prev" in
    --subnet|--subnet-v6|--ip)
      return 0
      ;;
  esac

  case "$sub" in
    members|rm)
      if [[ $COMP_CWORD -eq 3 ]]; then
        _dce_reply_networks "$cur"
        return 0
      fi
      ;;
    add|remove)
      if [[ $COMP_CWORD -eq 3 ]]; then
        _dce_reply_networks "$cur"
        return 0
      elif [[ $COMP_CWORD -eq 4 ]]; then
        _dce_reply_projects "$cur"
        return 0
      fi
      ;;
  esac

  mapfile -t COMPREPLY < <(compgen -W "--force --ip --subnet --subnet-v6" -- "$cur")
  return 0
}

# `dce config <show|get|set|sync-vscode|ls> ...`: position 2 is the subaction.
# show/get/set/sync-vscode take a project at position 3; get/set take a key at
# position 4; sync-vscode offers --dry-run as an optional flag at position 4.
# set's value (position 5+) is free-form. ls/show take no further completion.
_dce_complete_config() {
  local cur="$1" prev="$2"

  if [[ $COMP_CWORD -eq 2 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_config_subactions)" -- "$cur")
    return 0
  fi

  local subaction="${COMP_WORDS[2]}"

  case "$subaction" in
    ls)
      return 0
      ;;
    show)
      # show takes exactly one project.
      [[ $COMP_CWORD -eq 3 ]] && _dce_reply_projects "$cur"
      return 0
      ;;
    get)
      if [[ $COMP_CWORD -eq 3 ]]; then
        _dce_reply_projects "$cur"
      elif [[ $COMP_CWORD -eq 4 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_config_get_keys)" -- "$cur")
      fi
      return 0
      ;;
    set)
      if [[ $COMP_CWORD -eq 3 ]]; then
        _dce_reply_projects "$cur"
      elif [[ $COMP_CWORD -eq 4 ]]; then
        # Offer bare key names; the value (incl. key=value) is free-form.
        mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_config_keys)" -- "$cur")
      fi
      return 0
      ;;
    sync-vscode)
      if [[ $COMP_CWORD -eq 3 ]]; then
        _dce_reply_projects "$cur"
      elif [[ $COMP_CWORD -eq 4 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "--dry-run" -- "$cur")
      fi
      return 0
      ;;
  esac
}

# `dce extensions <list|host|available|show|diff|capture> <project> [flags]`:
# position 2 is the subaction; project at position 3 (except for `host`);
# --editor/--format/--scope consume a value; --user/--team/--all are flags.
# capture takes trailing free-form <id>... which is not completed.
#
# Grammar assumption: the subaction sits at slot 2 and, for project-taking
# subcommands, the project sits at slot 3. This mirrors the normalized
# project-first command form used elsewhere in dce.
_dce_complete_extensions() {
  local cur="$1" prev="$2"

  if [[ $COMP_CWORD -eq 2 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_extensions_subactions)" -- "$cur")
    return 0
  fi

  # Value-consuming flags: offer no completion for their value except --editor
  # (known ids) and --format/--scope (fixed sets).
  case "$prev" in
    --editor)
      mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_extensions_editor_ids)" -- "$cur")
      return 0
      ;;
    --format)
      mapfile -t COMPREPLY < <(compgen -W "ids json manifest" -- "$cur")
      return 0
      ;;
    --scope)
      mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_scopes)" -- "$cur")
      return 0
      ;;
  esac

  local subaction="${COMP_WORDS[2]}"
  # Output flags apply to every subcommand; the manifest-target flags are
  # capture-only.
  local flags="--editor --format"
  [[ "$subaction" == "capture" ]] && flags="$flags --scope --user --team --all"

  # `host` takes no project; offer flags at every position.
  if [[ "$subaction" == "host" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
    return 0
  fi

  # Slot 3 is the project for every non-host subcommand.
  if [[ $COMP_CWORD -eq 3 ]]; then
    _dce_reply_projects "$cur"
    return 0
  fi

  # Slot 4+: value positions for flags complete above; otherwise offer flags.
  mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
  return 0
}

_dce_complete_help() {
  local cur="$1"
  if [[ $COMP_CWORD -eq 2 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$(dce_complete_subcommands)" -- "$cur")
  fi
}

complete -F _dce_complete dce
