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

USE_ROOT=false
PROJECT=""

# Only --root is consumed as a dce option, and only before the project name.
# The first non-option token is the project; everything after it is the command
# verbatim (so command args that start with '-' are passed through untouched).
while [[ $# -gt 0 ]]; do
  case "$1" in
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
    -*)
      echo "ERROR: Unknown option: $1" >&2
      echo "Usage: dce exec [--root] <name> <command...>" >&2
      exit 1
      ;;
    *)
      PROJECT="$1"
      shift
      break
      ;;
  esac
done

CMD=("$@")

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Project name is required." >&2
  echo "Usage: dce exec [--root] <name> <command...>" >&2
  exit 1
fi

if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "ERROR: No command specified." >&2
  echo "  For an interactive shell, use: dce shell $PROJECT" >&2
  exit 1
fi

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

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'. Run: dce new $PROJECT" >&2
  exit 1
fi

dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"

if ! backend_is_running "$PROJECT"; then
  echo "ERROR: Container '$PROJECT' is not running." >&2
  echo "  Start it first: dce start $PROJECT" >&2
  exit 1
fi

if $USE_ROOT; then
  backend_exec_as_root "$PROJECT" "${CMD[@]}"
elif [[ -t 0 && -t 1 ]]; then
  backend_exec_interactive "$PROJECT" -- "${CMD[@]}"
else
  backend_exec "$PROJECT" "${CMD[@]}"
fi
