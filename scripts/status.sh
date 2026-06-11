#!/usr/bin/env zsh
# =============================================================================
# status.sh — Show status of all dev containers
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
backend_use "${CONTAINER_BACKEND:-}"
DEFAULT_BACKEND="$(backend_name)"

echo "======================================================================"
echo "dev-containers status"
echo "======================================================================"
echo ""
echo "Active backend: $DEFAULT_BACKEND"
echo ""

# System status
echo "System:"
backend_system_info 2>/dev/null || echo "  (system info unavailable)"
echo ""

# All containers
echo "Containers (active backend):"
backend_list_all 2>/dev/null || echo "  (none)"
echo ""

# Per-project details
PROJECTS=("$ROOT_DIR"/projects/*/config)
if [[ ${#PROJECTS[@]} -gt 0 && -f "${PROJECTS[1]}" ]]; then
  echo "Project details:"
  for config_file in "${PROJECTS[@]}"; do
    source "$config_file"
    project="${CONTAINER_PROJECT}"
    project_backend="${CONTAINER_BACKEND:-$DEFAULT_BACKEND}"

    if backend_use "$project_backend" 2>/dev/null; then
      resolved_backend="$(backend_name)"
      is_running=$(backend_is_running "$project" && echo "running" || echo "stopped")
    else
      resolved_backend="$project_backend"
      is_running="unknown (backend unavailable)"
    fi

    token_set=$(grep -v '^#' "$TOKEN_FILE" 2>/dev/null | grep -v '^ghp_REPLACE_ME' | grep -q . && echo "✓" || echo "✗ NOT SET")
    ssh_key_exists=$([[ -f "$SSH_KEY_PATH" ]] && echo "✓" || echo "✗ MISSING")
    echo "  [$project]  $is_running"
    echo "    Backend:      $resolved_backend"
    echo "    Type:         $CONTAINER_TYPE"
    echo "    Repos dir:    $REPOS_DIR"
    echo "    GitHub token: $token_set"
    echo "    SSH key:      $ssh_key_exists"
    [[ ${#PORTS[@]} -gt 0 ]] && echo "    Ports:        ${PORTS[*]}"
    echo ""
  done
fi

echo "Quick commands:"
echo "  dc start <name>       — start a container"
echo "  dc shell <name>       — open a shell"
echo "  dc stop <name>        — stop a container"
echo "  dc rebuild <name>     — destroy and rebuild"
echo "  dc rebuild-image      — rebuild images (all/base/nodejs/golang)"
echo "  dc clean              — remove old dev image tags (keep latest)"
