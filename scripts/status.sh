#!/usr/bin/env bash
# =============================================================================
# scripts/status.sh - `dc status`: detailed status across all dev containers.
#
# Shows backend/system info, all containers, then per-project detail (running
# state, image, scopes, repos dir, resource limits, hidden paths, token/SSH-key
# presence, ports). Each project may use a different backend, so the backend is
# resolved per project.
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
    PORTS=()
    CONTAINER_HIDDEN_PATHS=()
    dc_load_project_config "$config_file"

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
    echo "    Image:        ${CONTAINER_IMAGE:-(none)}"
    echo "    Scopes:       $scope_value"
    echo "    Repos dir:    ${REPOS_DIR:-unknown}"
    if [[ -n "${CONTAINER_CPUS:-}" || -n "${CONTAINER_MEMORY:-}" ]]; then
      echo "    Resources:    ${CONTAINER_CPUS:-(default)} CPU, ${CONTAINER_MEMORY:-(default)} memory"
    fi
    if declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1 && [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
      echo "    Hidden paths: ${CONTAINER_HIDDEN_PATHS[*]}"
    fi
    if declare -p CONTAINER_NETWORKS >/dev/null 2>&1 && [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
      echo "    Networks:     ${CONTAINER_NETWORKS[*]}"
    fi
    echo "    GitHub token: $token_set"
    echo "    SSH key:      $ssh_key_exists"

    # One-line image provenance from the project log (team/user commit + built
    # time), when present. Skipped silently for projects with no log yet.
    prov_log="$HOME/.config/dev-containers/$project/provenance.jsonl"
    if [[ -s "$prov_log" ]]; then
      prov_last="$(tail -n1 "$prov_log" 2>/dev/null || true)"
      if [[ -n "$prov_last" ]] && command -v jq >/dev/null 2>&1; then
        p_ts="$(printf '%s' "$prov_last" | jq -r '.ts' 2>/dev/null || printf '?')"
        p_team="$(printf '%s' "$prov_last" | jq -r 'if .team.git_commit == "" then "content:\(.team.content_hash[0:8])" else "git:\(.team.git_commit[0:12])" end' 2>/dev/null || printf '?')"
        p_user="$(printf '%s' "$prov_last" | jq -r 'if .user.git_commit == "" then "content:\(.user.content_hash[0:8])" else "git:\(.user.git_commit[0:12])" end' 2>/dev/null || printf '?')"
        echo "    Provenance:   team=$p_team user=$p_user built=$p_ts"
      else
        echo "    Provenance:   (see dc provenance $project)"
      fi
    fi

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
echo "  dc provenance <name>         - show image provenance / overlay commits"
echo "  dc clean                     - remove old and orphan managed image tags"
