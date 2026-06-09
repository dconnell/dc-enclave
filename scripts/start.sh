#!/usr/bin/env zsh
# =============================================================================
# start.sh — Start one or all dev containers
#
# Usage:
#   start.sh                  # start all containers defined in projects/
#   start.sh <project-name>   # start a specific container
# =============================================================================
set -euo pipefail
setopt null_glob

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

source "$BACKEND_LIB"

_start_container() {
  local project="$1"
  local config="$ROOT_DIR/projects/$project/config"

  if [[ ! -f "$config" ]]; then
    echo "✗ No config found for '$project' at $config"
    return 1
  fi

  source "$config"
  backend_use "${CONTAINER_BACKEND:-}" || return 1
  local active_backend
  active_backend="$(backend_name)"

  # Check if already running
  if backend_is_running "$project"; then
    echo "  ✓ $project — already running ($active_backend)"
    return 0
  fi

  echo "  → Starting $project on $active_backend..."
  backend_start "$project"

  # Re-inject SSH key on start (persists in VM but good practice after rebuild)
  if [[ -f "$SSH_KEY_PATH" ]]; then
    # Only inject if key isn't already present (avoids redundant writes)
    if ! backend_exec "$project" test -f ~/.ssh/id_ed25519 2>/dev/null; then
      backend_exec "$project" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
      backend_exec_stdin "$project" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY_PATH"
      backend_exec "$project" zsh -c "ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null && chmod 644 ~/.ssh/known_hosts"
      echo "  ✓ SSH key injected"
    fi
  fi

  echo "  ✓ $project — started"
}

if [[ $# -gt 0 ]]; then
  # Start specific container(s)
  for project in "$@"; do
    _start_container "$project"
  done
else
  # Start all projects
  PROJECTS=("$ROOT_DIR"/projects/*/config)
  if [[ ${#PROJECTS[@]} -eq 0 || ! -f "${PROJECTS[1]}" ]]; then
    echo "No containers configured yet. Run: scripts/new-container.sh <name> <type>"
    exit 0
  fi

  echo "Starting all containers..."
  for config_file in "${PROJECTS[@]}"; do
    project="${${config_file:h}:t}"
    _start_container "$project"
  done
fi

echo ""
echo "Run 'scripts/status.sh' to see running containers."
