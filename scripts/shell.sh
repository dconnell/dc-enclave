#!/usr/bin/env zsh
# =============================================================================
# shell.sh — Open an interactive shell in a dev container
#
# Usage:
#   shell.sh <project-name>
#   shell.sh <project-name> <command>   # run a specific command instead
#
# Examples:
#   shell.sh myapp-frontend
#   shell.sh myapp-backend "go test ./..."
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

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG="$ROOT_DIR/projects/$PROJECT/config"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

source "$BACKEND_LIB"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'. Run: scripts/new-container.sh $PROJECT <type>"
  exit 1
fi

source "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

# Start if not running
if ! backend_is_running "$PROJECT"; then
  echo "  Container '$PROJECT' is not running — starting it..."
  "$SCRIPT_DIR/start.sh" "$PROJECT"
fi

# Load GITHUB_TOKEN from secrets into the exec environment
GITHUB_TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
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
echo "  Workspace: /workspace (→ $REPOS_DIR on host)"
[[ -n "$GITHUB_TOKEN" ]] && echo "  GITHUB_TOKEN: set" || echo "  GITHUB_TOKEN: NOT SET (edit $TOKEN_FILE)"
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
