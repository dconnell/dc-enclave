#!/usr/bin/env bash
# =============================================================================
# scripts/exec.sh - `dce exec`: run a single command in a running container.
#
# Raw exec (docker-exec style): the command runs directly as the dev user with
# no GITHUB_TOKEN seeding, no PS1 prefix, and no zsh -ic wrapping. A TTY is
# auto-allocated only when both stdin and stdout are interactive, so piped use
# (e.g. `dce exec name cat file | grep x`) is not corrupted. Use `dce shell` for
# an interactive session or token-seeded one-shot commands.
#
# --root runs the command as uid 0 (non-TTY) for permission-debugging; it maps
# to backend_exec_as_root, the same path rebuild-container uses for chown.
# =============================================================================
set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"

USE_ROOT=false
REPO_NAME=""
PROJECT=""

# `dce exec <project> [--repo <name>] [--root] <command...>`. The project is the
# first argument; a short option window follows for exec-scoped flags, then the
# remaining words are passed through as the command verbatim. `--` can be used
# after the project to force a command beginning with '-'.
PROJECT="${1:-}"
if [[ -z "$PROJECT" ]]; then
  dce_die "Project name is required.
Usage: dce exec <name> [--repo <name>] [--root] <command...>"
fi
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 && "$2" != --* ]] || dce_die "--repo requires a repo name
Usage: dce exec <name> [--repo <name>] [--root] <command...>"
      REPO_NAME="$2"
      shift 2
      ;;
    --root)
      USE_ROOT=true
      shift
      ;;
    --root=*)
      USE_ROOT=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -* )
      dce_die "Unknown option: $1
Usage: dce exec <name> [--repo <name>] [--root] <command...>"
      ;;
    *)
      break
      ;;
  esac
done

CMD=("$@")

if [[ ${#CMD[@]} -eq 0 ]]; then
  dce_die "No command specified.
  For an interactive shell, use: dce shell $PROJECT"
fi

CONFIG="$(dce_project_config_path "$PROJECT")"
if [[ ! -f "$CONFIG" ]]; then
  dce_die "No config for '$PROJECT'. Run: dce new $PROJECT"
fi

dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"

WORKDIR=""
if [[ -n "$REPO_NAME" ]]; then
  WORKDIR="$(dce_project_repo_workdir "$REPO_NAME" 2>/dev/null)" \
    || dce_die "Unknown repo '$REPO_NAME' in project '$PROJECT'."
fi

if ! backend_is_running "$PROJECT"; then
  dce_die "Container '$PROJECT' is not running.
  Start it first: dce start $PROJECT"
fi

if [[ -n "$WORKDIR" ]]; then
  cmd_joined="$(printf '%q ' "${CMD[@]}")"
  cmd_joined="${cmd_joined% }"
  if $USE_ROOT; then
    backend_exec_as_root "$PROJECT" sh -lc "cd $WORKDIR && exec $cmd_joined"
  elif [[ -t 0 && -t 1 ]]; then
    backend_exec_interactive "$PROJECT" -- sh -lc "cd $WORKDIR && exec $cmd_joined"
  else
    backend_exec "$PROJECT" sh -lc "cd $WORKDIR && exec $cmd_joined"
  fi
elif $USE_ROOT; then
  backend_exec_as_root "$PROJECT" "${CMD[@]}"
elif [[ -t 0 && -t 1 ]]; then
  backend_exec_interactive "$PROJECT" -- "${CMD[@]}"
else
  backend_exec "$PROJECT" "${CMD[@]}"
fi
