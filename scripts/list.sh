#!/usr/bin/env bash
# =============================================================================
# scripts/list.sh - `dce list` / `dce ls`: compact one-line-per-container summary
# (name, running/stopped/missing/unknown, backend, scopes, stale warning). A
# lighter view than `dce status`. Requires a reachable backend to report live
# state. A `STALE` warning in the rightmost column means the container is bound
# to an older image than its configured CONTAINER_IMAGE tag resolves to today;
# run `dce rebuild-container <name>` to bring it back in sync.
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

backend_use "${CONTAINER_BACKEND:-}"
DEFAULT_BACKEND="$(backend_name)"

PROJECTS=("$HOME"/.config/dce-enclave/*/config)
if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  echo "No projects found."
  exit 0
fi

printf "%-24s %-12s %-10s %-24s %s\n" "NAME" "STATUS" "BACKEND" "SCOPES" "WARN"

for config_file in "${PROJECTS[@]}"; do
  dce_load_project_config "$config_file"
  project="${CONTAINER_PROJECT:-$(basename "$(dirname "$config_file")")}"
  project_backend="${CONTAINER_BACKEND:-$DEFAULT_BACKEND}"

  warn=""
  if backend_use "$project_backend" 2>/dev/null; then
    if backend_is_running "$project" 2>/dev/null; then
      state="running"
    elif backend_exists "$project" 2>/dev/null; then
      state="stopped"
    else
      state="missing"
    fi

    # Stale is only meaningful when the container exists: a missing container
    # cannot be on an old image. backend_container_is_stale returns non-zero
    # (not stale / unknown) for every indeterminate case, so a STALE marker
    # only appears when drift is proven.
    if [[ "$state" != "missing" ]] && [[ -n "${CONTAINER_IMAGE:-}" ]] \
       && backend_container_is_stale "$project" "${CONTAINER_IMAGE:-}" >/dev/null 2>&1; then
      warn="STALE"
    fi
  else
    state="unknown"
  fi

  scope_value="${CONTAINER_OVERLAY_SCOPES:-unknown}"
  printf "%-24s %-12s %-10s %-24s %s\n" "$project" "$state" "$project_backend" "$scope_value" "$warn"
done
