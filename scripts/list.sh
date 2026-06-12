#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

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

backend_use "${CONTAINER_BACKEND:-}"
DEFAULT_BACKEND="$(backend_name)"

PROJECTS=("$HOME"/.config/dev-containers/*/config)
if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  echo "No projects found."
  exit 0
fi

printf "%-24s %-12s %-10s %s\n" "NAME" "STATUS" "BACKEND" "TYPE"

for config_file in "${PROJECTS[@]}"; do
  source "$config_file"
  project="${CONTAINER_PROJECT:-$(basename "$(dirname "$config_file")")}"
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

  type_value="${CONTAINER_TYPE:-${CONTAINER_RUNTIME_TYPES:-unknown}}"
  printf "%-24s %-12s %-10s %s\n" "$project" "$state" "$project_backend" "$type_value"
done
