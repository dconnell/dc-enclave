#!/usr/bin/env bash
# =============================================================================
# shell.sh - Open an interactive shell in a dev container
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: shell.sh <project-name> [command]}"
shift

HAS_COMMAND=false
COMMAND=""
if [[ $# -gt 0 ]]; then
  HAS_COMMAND=true
  COMMAND="$*"
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

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/container-backend.sh"

CONFIG="$HOME/.config/dev-containers/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'. Run: dc new $PROJECT <scope>"
  exit 1
fi

source "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

if ! backend_is_running "$PROJECT"; then
  echo "  Container '$PROJECT' is not running - starting it..."
  "$SCRIPT_DIR/start.sh" "$PROJECT"
fi

GITHUB_TOKEN=""
if [[ -n "${TOKEN_FILE:-}" ]] && [[ -f "$TOKEN_FILE" ]]; then
  GITHUB_TOKEN="$(awk '
    $0 !~ /^#/ &&
    $0 !~ /^ghp_REPLACE_ME/ &&
    $0 ~ /[^[:space:]]/
    {
      gsub(/[[:space:]]+/, "", $0)
      print
      exit
    }
  ' "$TOKEN_FILE" 2>/dev/null || true)"
fi

echo "  Entering container: $PROJECT"
echo "  Backend: $ACTIVE_BACKEND"
echo "  Workspace: /workspace (-> $REPOS_DIR on host)"
if [[ -n "$GITHUB_TOKEN" ]]; then
  echo "  GITHUB_TOKEN: set"
else
  echo "  GITHUB_TOKEN: NOT SET (edit ${TOKEN_FILE:-token file})"
fi
echo ""

if $HAS_COMMAND; then
  if [[ -n "$GITHUB_TOKEN" ]]; then
    backend_exec "$PROJECT" env \
      "GITHUB_TOKEN=$GITHUB_TOKEN" \
      "PS1=[${PROJECT}] %~ %# " \
      zsh -ic "$COMMAND"
  else
    backend_exec "$PROJECT" env \
      "PS1=[${PROJECT}] %~ %# " \
      zsh -ic "$COMMAND"
  fi
else
  backend_exec "$PROJECT" sh -lc 'echo "  Connected to container: $(hostname) (user=$(whoami), pwd=$(pwd))"'
  if [[ -n "$GITHUB_TOKEN" ]]; then
    backend_exec_interactive "$PROJECT" \
      --env "GITHUB_TOKEN=$GITHUB_TOKEN" \
      --env "PS1=[${PROJECT}] %~ %# " \
      -- \
      zsh -ic 'cd /workspace 2>/dev/null || true; exec zsh -i'
  else
    backend_exec_interactive "$PROJECT" \
      --env "PS1=[${PROJECT}] %~ %# " \
      -- \
      zsh -ic 'cd /workspace 2>/dev/null || true; exec zsh -i'
  fi
fi
