#!/usr/bin/env bash
# =============================================================================
# scripts/stop.sh - `dce stop`: stop one or all dev containers.
#
# Stopping preserves the container filesystem - it can be restarted with
# `dce start` without data loss. Use `dce rebuild-container` to fully destroy.
# =============================================================================
set -euo pipefail
shopt -s nullglob

# Resolve real script dir (follows symlinks) and repo root.
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

# Stop a single project; already-stopped containers are reported, not errored.
_stop_container() {
  local project="$1"
  local config="$HOME/.config/dce-enclave/$project/config"

  if [[ ! -f "$config" ]]; then
    echo "✗ No config found for '$project' at $config"
    return 1
  fi

  dce_load_project_config "$config"
  backend_use "${CONTAINER_BACKEND:-}" || return 1

  local active_backend=""
  active_backend="$(backend_name)"

  if backend_is_running "$project"; then
    echo "  -> Stopping $project on $active_backend..."
    backend_stop "$project"
    echo "  ✓ $project - stopped"
  else
    echo "  ✓ $project - not running ($active_backend)"
  fi
}

if [[ $# -gt 0 ]]; then
  for project in "$@"; do
    _stop_container "$project"
  done
else
  PROJECTS=("$HOME"/.config/dce-enclave/*/config)
  if [[ ${#PROJECTS[@]} -eq 0 ]]; then
    echo "No containers configured."
    exit 0
  fi

  echo "Stopping all containers..."
  for config_file in "${PROJECTS[@]}"; do
    project="$(basename "$(dirname "$config_file")")"
    _stop_container "$project"
  done
fi
