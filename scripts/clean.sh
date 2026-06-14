#!/usr/bin/env bash
# =============================================================================
# clean.sh - Remove old dev-container image tags, keep latest tags only
# =============================================================================
set -euo pipefail
shopt -s nullglob

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: dc clean [--dry-run]"
  exit 1
fi

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
ACTIVE_BACKEND="$(backend_name)"

case "$ACTIVE_BACKEND" in
  apple)
    backend_system_start 2>/dev/null || true
    ;;
  colima)
    if ! backend_system_start; then
      echo "ERROR: Colima runtime is not reachable."
      echo "Ensure Colima uses Docker runtime and Docker context points to Colima."
      echo "Try: colima start --runtime docker && docker context use colima"
      exit 1
    fi
    ;;
  docker|orbstack)
    if ! backend_system_start 2>/dev/null; then
      echo "ERROR: Docker-compatible runtime is not reachable."
      echo "Start Docker Desktop or OrbStack and retry."
      exit 1
    fi
    ;;
  podman)
    if ! backend_system_start 2>/dev/null; then
      echo "ERROR: Podman runtime is not reachable."
      echo "Start Podman (for macOS: podman machine start) and retry."
      exit 1
    fi
    ;;
esac

is_managed_repo() {
  local repo="$1"
  [[ "$repo" == dev-* && "$repo" != */* ]]
}

is_managed_combined_repo() {
  local repo="$1"
  [[ "$repo" == dev-* ]] || return 1
  [[ "$repo" == "dev-base" ]] && return 1

  local slug="${repo#dev-}"
  local -a parts=()
  IFS='-' read -r -a parts <<< "$slug"
  [[ ${#parts[@]} -ge 2 ]] || return 1

  return 0
}

declare -A MANAGED_REPOS=()
add_managed_repo() {
  local repo="$1"
  [[ -z "$repo" || "$repo" == "<none>" ]] && return
  if is_managed_repo "$repo"; then
    MANAGED_REPOS["$repo"]=1
  fi
}

add_managed_repo "dev-base"

for config_file in "$HOME"/.config/dev-containers/*/config; do
  source "$config_file"
  image_ref="${CONTAINER_IMAGE:-}"
  [[ -z "$image_ref" ]] && continue
  add_managed_repo "${image_ref%%:*}"
done

for generated_file in "$ROOT_DIR"/Containerfiles/generated/Containerfile.*; do
  slug="$(basename "$generated_file")"
  slug="${slug#Containerfile.}"
  [[ -z "$slug" ]] && continue
  add_managed_repo "dev-$slug"
done

while IFS=$'\t' read -r repo tag image_id; do
  [[ -z "$repo" || "$repo" == "<none>" ]] && continue
  if is_managed_combined_repo "$repo"; then
    add_managed_repo "$repo"
  fi
done < <(backend_list_images)

if [[ ${#MANAGED_REPOS[@]} -eq 0 ]]; then
  echo "No managed image repositories found."
  exit 0
fi

REMOVE_REFS=()
declare -A SEEN_REFS=()
while IFS=$'\t' read -r repo tag image_id; do
  [[ -z "$repo" || -z "$tag" || -z "$image_id" ]] && continue
  [[ -z "${MANAGED_REPOS[$repo]-}" ]] && continue

  if [[ "$tag" != "latest" && "$tag" != "<none>" ]]; then
    ref="$repo:$tag"
    if [[ -z "${SEEN_REFS[$ref]-}" ]]; then
      REMOVE_REFS+=("$ref")
      SEEN_REFS["$ref"]=1
    fi
  fi
done < <(backend_list_images)

if [[ ${#REMOVE_REFS[@]} -eq 0 ]]; then
  echo "No old managed image tags found. Managed latest tags are already clean."
  exit 0
fi

IFS=$'\n' refs=($(printf '%s\n' "${REMOVE_REFS[@]}" | sort))
unset IFS

managed_repo_names=("${!MANAGED_REPOS[@]}")
IFS=$'\n' managed_repo_names=($(printf '%s\n' "${managed_repo_names[@]}" | sort))
unset IFS

echo "Active backend: $ACTIVE_BACKEND"
echo "Managed repos: ${managed_repo_names[*]}"
echo ""
echo "The following managed image tags will be removed (latest tags are preserved):"
for ref in "${refs[@]}"; do
  echo "  - $ref"
done

if $DRY_RUN; then
  echo ""
  echo "Dry run only; nothing removed."
  exit 0
fi

removed=0
failed=0
for ref in "${refs[@]}"; do
  if backend_remove_image "$ref"; then
    removed=$((removed + 1))
  else
    failed=$((failed + 1))
    echo "WARN: Could not remove $ref (may be in use)."
  fi
done

echo ""
echo "Cleanup complete. Removed: $removed"
if [[ $failed -gt 0 ]]; then
  echo "Could not remove: $failed"
fi
