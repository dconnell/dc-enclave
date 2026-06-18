#!/usr/bin/env bash
# =============================================================================
# scripts/start.sh - `dc start`: start one or all dev containers.
#
# Starts named projects, or all configured projects when none are given. Brings
# up the runtime if needed, verifies hidden-volume mounts, and re-injects the
# SSH deploy key if it's missing from the container filesystem.
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

source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/container-backend.sh"

# Start a single project: reach the backend, ensure hidden mounts are live, and
# re-inject the SSH key if the container lost it (e.g. after a host reboot).
_start_container() {
  local project="$1"
  local config="$HOME/.config/dev-containers/$project/config"

  if [[ ! -f "$config" ]]; then
    echo "✗ No config found for '$project' at $config"
    return 1
  fi

  dc_load_project_config "$config"
  backend_use "${CONTAINER_BACKEND:-}" || return 1

  local active_backend=""
  active_backend="$(backend_name)"

  if ! backend_system_start >/dev/null 2>&1; then
    echo "  ✗ $project - backend unavailable ($active_backend)"
    case "$active_backend" in
      colima)
        echo "    Ensure Colima uses Docker runtime and Docker context points to Colima."
        echo "    Try: colima start --runtime docker && docker context use colima"
        ;;
      docker|orbstack)
        echo "    Start Docker Desktop or OrbStack and retry."
        ;;
      podman)
        echo "    Start Podman (for macOS: podman machine start) and retry."
        ;;
      apple)
        echo "    Start apple/container daemon and retry."
        ;;
    esac
    return 1
  fi

  if backend_is_running "$project"; then
    echo "  ✓ $project - already running ($active_backend)"
    return 0
  fi

  if ! declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1; then
    CONTAINER_HIDDEN_PATHS=()
  fi

  echo "  -> Starting $project on $active_backend..."
  backend_start "$project"

  if [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
    sleep 2
    if ! dc_ensure_hidden_mounts "$project" "${CONTAINER_HIDDEN_PATHS[@]}"; then
      echo "  ✗ $project - hidden volume mounts not active"
      return 1
    fi
  fi

  if [[ -n "${SSH_KEY_PATH:-}" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
    if ! backend_exec "$project" test -f ~/.ssh/id_ed25519 2>/dev/null; then
      backend_exec "$project" zsh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
      backend_exec_stdin "$project" zsh -c "cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519" < "$SSH_KEY_PATH"
      # GitHub host keys are pinned in the base image; no runtime ssh-keyscan.
      echo "  ✓ SSH key injected"
    fi
  fi

  echo "  ✓ $project - started"
}

if [[ $# -gt 0 ]]; then
  for project in "$@"; do
    _start_container "$project"
  done
else
  PROJECTS=("$HOME"/.config/dev-containers/*/config)
  if [[ ${#PROJECTS[@]} -eq 0 ]]; then
    echo "No containers configured yet. Run: dc new <name> [scope]"
    exit 0
  fi

  echo "Starting all containers..."
  for config_file in "${PROJECTS[@]}"; do
    project="$(basename "$(dirname "$config_file")")"
    _start_container "$project"
  done
fi

echo ""
echo "Run 'dc status' to see running containers."
