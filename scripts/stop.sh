#!/usr/bin/env zsh
# =============================================================================
# stop.sh — Stop one or all dev containers
#
# Usage:
#   stop.sh                   # stop all containers
#   stop.sh <project-name>    # stop a specific container
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

_stop_container() {
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

  if backend_is_running "$project"; then
    echo "  → Stopping $project on $active_backend..."
    backend_stop "$project"
    echo "  ✓ $project — stopped"
  else
    echo "  ✓ $project — not running ($active_backend)"
  fi
}

if [[ $# -gt 0 ]]; then
  for project in "$@"; do
    _stop_container "$project"
  done
else
  PROJECTS=("$ROOT_DIR"/projects/*/config)
  if [[ ${#PROJECTS[@]} -eq 0 || ! -f "${PROJECTS[1]}" ]]; then
    echo "No containers configured."
    exit 0
  fi

  echo "Stopping all containers..."
  for config_file in "${PROJECTS[@]}"; do
    project="${${config_file:h}:t}"
    _stop_container "$project"
  done
fi
