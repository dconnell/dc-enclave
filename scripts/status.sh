#!/usr/bin/env bash
# =============================================================================
# status.sh - Show status of all dev containers
# =============================================================================
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

echo "======================================================================"
echo "dev-containers status"
echo "======================================================================"
echo ""
echo "Active backend: $DEFAULT_BACKEND"
echo ""

echo "System:"
backend_system_info 2>/dev/null || echo "  (system info unavailable)"
echo ""

echo "Containers (active backend):"
backend_list_all 2>/dev/null || echo "  (none)"
echo ""

PROJECTS=("$HOME"/.config/dev-containers/*/config)
if [[ ${#PROJECTS[@]} -gt 0 ]]; then
  echo "Project details:"
  for config_file in "${PROJECTS[@]}"; do
    source "$config_file"

    project="${CONTAINER_PROJECT:-$(basename "$(dirname "$config_file")")}"
    project_backend="${CONTAINER_BACKEND:-$DEFAULT_BACKEND}"

    if backend_use "$project_backend" 2>/dev/null; then
      resolved_backend="$(backend_name)"
      if backend_is_running "$project"; then
        is_running="running"
      else
        is_running="stopped"
      fi
    else
      resolved_backend="$project_backend"
      is_running="unknown (backend unavailable)"
    fi

    token_set="✗ NOT SET"
    if [[ -n "${TOKEN_FILE:-}" ]] && [[ -f "$TOKEN_FILE" ]]; then
      if grep -v '^#' "$TOKEN_FILE" 2>/dev/null | grep -v '^ghp_REPLACE_ME' | grep -q .; then
        token_set="✓"
      fi
    fi

    ssh_key_exists="✗ MISSING"
    if [[ -n "${SSH_KEY_PATH:-}" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
      ssh_key_exists="✓"
    fi

    scope_value="${CONTAINER_OVERLAY_SCOPES:-unknown}"

    echo "  [$project]  $is_running"
    echo "    Backend:      $resolved_backend"
    echo "    Scopes:       $scope_value"
    echo "    Repos dir:    ${REPOS_DIR:-unknown}"
    echo "    GitHub token: $token_set"
    echo "    SSH key:      $ssh_key_exists"
    if declare -p PORTS >/dev/null 2>&1 && [[ ${#PORTS[@]} -gt 0 ]]; then
      echo "    Ports:        ${PORTS[*]}"
    fi
    echo ""
  done
fi

echo "Quick commands:"
echo "  dc start <name>       - start a container"
echo "  dc shell <name>       - open a shell"
echo "  dc stop <name>        - stop a container"
echo "  dc rebuild-container <name>  - destroy and rebuild container"
echo "  dc rebuild-image [all|base]  - rebuild managed images"
echo "  dc clean                     - remove old and orphan managed image tags"
