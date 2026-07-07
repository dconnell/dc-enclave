#!/usr/bin/env bash
# =============================================================================
# scripts/logs.sh - `dce logs`: fetch a container's stdout/stderr log stream.
#
# Unlike `dce shell`, this reads the container's log driver output (entrypoint,
# startup banners, the Node overlay's npm-install sentinel, SSH/credential
# injection messages from `dce start`, and crash output) - none of which is
# visible from an interactive shell or VS Code terminal attached to the
# container. Works on stopped containers so a failed start can be diagnosed.
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

PROJECT=""
FOLLOW=false
TAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--follow)
      FOLLOW=true
      shift
      ;;
    --tail)
      [[ $# -ge 2 ]] || dce_die "--tail requires a value"
      TAIL="$2"
      shift 2
      ;;
    --tail=*)
      TAIL="${1#--tail=}"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      dce_die "Unknown option: $1
Usage: dce logs <name> [-f|--follow] [--tail N]"
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        dce_die "Unexpected argument: $1
Usage: dce logs <name> [-f|--follow] [--tail N]"
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  dce_die "Project name is required.
Usage: dce logs <name> [-f|--follow] [--tail N]"
fi

if [[ -n "$TAIL" ]] && [[ ! "$TAIL" =~ ^[0-9]+$ ]]; then
  dce_die "--tail requires a non-negative integer (got: $TAIL)"
fi

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  dce_die "No config for '$PROJECT'. Run: dce new $PROJECT"
fi

dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

if ! backend_exists "$PROJECT"; then
  dce_die "Container '$PROJECT' does not exist on backend '$ACTIVE_BACKEND'.
  Run: dce start $PROJECT"
fi

backend_logs "$PROJECT" "$FOLLOW" "$TAIL"
