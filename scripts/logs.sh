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
      [[ $# -ge 2 ]] || { echo "ERROR: --tail requires a value" >&2; exit 1; }
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
      echo "ERROR: Unknown option: $1" >&2
      echo "Usage: dce logs <name> [-f|--follow] [--tail N]" >&2
      exit 1
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        echo "Usage: dce logs <name> [-f|--follow] [--tail N]" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Project name is required." >&2
  echo "Usage: dce logs <name> [-f|--follow] [--tail N]" >&2
  exit 1
fi

if [[ -n "$TAIL" ]] && [[ ! "$TAIL" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --tail requires a non-negative integer (got: $TAIL)" >&2
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
ACTIVE_BACKEND="$(backend_name)"

if ! backend_exists "$PROJECT"; then
  echo "ERROR: Container '$PROJECT' does not exist on backend '$ACTIVE_BACKEND'." >&2
  echo "  Run: dce start $PROJECT" >&2
  exit 1
fi

backend_logs "$PROJECT" "$FOLLOW" "$TAIL"
