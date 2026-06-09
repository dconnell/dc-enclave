#!/usr/bin/env zsh
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
backend_use "${CONTAINER_BACKEND:-}"
DEFAULT_BACKEND="$(backend_name)"

PROJECTS=("$ROOT_DIR"/projects/*/config)

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  echo "No projects found."
  exit 0
fi

printf "%-24s %-12s %s\n" "NAME" "STATUS" "TYPE"

for config_file in "${PROJECTS[@]}"; do
  source "$config_file"
  project="${CONTAINER_PROJECT}"
  project_backend="${CONTAINER_BACKEND:-$DEFAULT_BACKEND}"

  if backend_use "$project_backend" 2>/dev/null; then
    if backend_is_running "$project" 2>/dev/null; then
      state="running"
    elif backend_exists "$project" 2>/dev/null; then
      state="stopped"
    else
      state="missing"
    fi
  else
    state="unknown"
  fi

  printf "%-24s %-12s %s\n" "$project" "$state" "$CONTAINER_TYPE"
done
