#!/usr/bin/env bash
# =============================================================================
# scripts/status.sh - `dce status`: detailed status across all dev containers.
#
# Shows backend/system info, all containers, then per-project detail (running
# state, image, scopes, repos dir, resource limits, hidden paths, token/SSH-key
# presence, ports). Each project may use a different backend, so the backend is
# resolved per project. A trailing "Stale containers" section names any project
# whose container is bound to an older image than its configured image tag
# resolves to today; run `dce rebuild-container <name>` to bring it back in sync.
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
echo "DC Enclave status"
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

PROJECTS=("$HOME"/.config/dce-enclave/*/config)
STALE_PROJECTS=()
if [[ ${#PROJECTS[@]} -gt 0 ]]; then
  echo "Project details:"
  for config_file in "${PROJECTS[@]}"; do
    PORTS=()
    CONTAINER_HIDDEN_PATHS=()
    dce_load_project_config "$config_file"

    project="${CONTAINER_PROJECT:-$(basename "$(dirname "$config_file")")}"
    project_backend="${CONTAINER_BACKEND:-$DEFAULT_BACKEND}"

    if backend_use "$project_backend" 2>/dev/null; then
      resolved_backend="$(backend_name)"
      if backend_is_running "$project"; then
        is_running="running"
      else
        is_running="stopped"
      fi

      # Stale is only meaningful when the container exists; a missing container
      # is never stale. backend_container_is_stale returns non-zero for every
      # indeterminate case, so a project only lands in STALE_PROJECTS when drift
      # is proven.
      if [[ "$is_running" == "stopped" || "$is_running" == "running" ]] \
         && [[ -n "${CONTAINER_IMAGE:-}" ]] \
         && backend_container_is_stale "$project" "${CONTAINER_IMAGE:-}" >/dev/null 2>&1; then
        STALE_PROJECTS+=("$project")
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
    prov_log="$HOME/.config/dce-enclave/$project/provenance.jsonl"
    if [[ -s "$prov_log" ]]; then
      prov_last="$(tail -n1 "$prov_log" 2>/dev/null || true)"
      if [[ -n "$prov_last" ]] && command -v jq >/dev/null 2>&1; then
        p_ts="$(printf '%s' "$prov_last" | jq -r '.ts' 2>/dev/null || printf '?')"
        p_team="$(printf '%s' "$prov_last" | jq -r 'if .team.git_commit == "" then "content:\(.team.content_hash[0:8])" else "git:\(.team.git_commit[0:12])" end' 2>/dev/null || printf '?')"
        p_user="$(printf '%s' "$prov_last" | jq -r 'if .user.git_commit == "" then "content:\(.user.content_hash[0:8])" else "git:\(.user.git_commit[0:12])" end' 2>/dev/null || printf '?')"
        echo "    Provenance:   team=$p_team user=$p_user built=$p_ts"
      else
        echo "    Provenance:   (see dce provenance $project)"
      fi
    fi

    if declare -p PORTS >/dev/null 2>&1 && [[ ${#PORTS[@]} -gt 0 ]]; then
      echo "    Ports:        ${PORTS[*]}"
    fi
    echo ""
  done
fi

echo ""
echo "Stale containers:"
if [[ ${#STALE_PROJECTS[@]} -eq 0 ]]; then
  echo "  none"
else
  for sp in "${STALE_PROJECTS[@]}"; do
    echo "  - $sp (run: dce rebuild-container $sp)"
  done
fi

echo ""
echo "Quick commands:"
echo "  dce start <name>       - start a container"
echo "  dce shell <name>       - open a shell"
echo "  dce stop <name>        - stop a container"
echo "  dce rebuild-container <name>  - destroy and rebuild container"
echo "  dce rebuild-image [all|base]  - rebuild managed images"
echo "  dce provenance <name>         - show image provenance / overlay commits"
echo "  dce clean                     - remove old and orphan managed image tags"
