#!/usr/bin/env zsh
# =============================================================================
# clean.sh — Remove old dev-container image tags, keep latest tags only
#
# Usage:
#   clean.sh [--dry-run]
#
# Notes:
#   - Backend-agnostic via lib/container-backend.sh
#   - Only touches managed dev-container image repositories (dev-*)
#   - Keeps <repo>:latest, removes other tags for managed repos
#   - Does not delete unrelated images
# =============================================================================
set -euo pipefail
setopt null_glob

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: scripts/clean.sh [--dry-run]"
  exit 1
fi

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

source "$BACKEND_LIB"

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

if [[ "$ACTIVE_BACKEND" == "apple" ]]; then
  backend_system_start 2>/dev/null || true
else
  if ! backend_system_start 2>/dev/null; then
    echo "ERROR: Docker-compatible runtime is not reachable."
    echo "Start Docker Desktop or OrbStack and retry."
    exit 1
  fi
fi

is_managed_repo() {
  local repo="$1"
  [[ "$repo" == dev-* && "$repo" != */* ]]
}

is_managed_combined_repo() {
  local repo="$1"
  [[ "$repo" == dev-* ]] || return 1
  [[ "$repo" == "dev-base" || "$repo" == "dev-nodejs" || "$repo" == "dev-golang" ]] && return 1

  local slug="${repo#dev-}"
  local -a parts=("${(@s:-:)slug}")
  [[ ${#parts[@]} -ge 2 ]] || return 1

  for part in "${parts[@]}"; do
    case "$part" in
      nodejs|golang)
        ;;
      *)
        return 1
        ;;
    esac
  done

  return 0
}

typeset -A MANAGED_REPOS
add_managed_repo() {
  local repo="$1"
  [[ -z "$repo" ]] && return
  [[ "$repo" == "<none>" ]] && return
  if is_managed_repo "$repo"; then
    MANAGED_REPOS[$repo]=1
  fi
}

# Standard image repos built by setup/rebuild-image.
add_managed_repo "dev-base"
add_managed_repo "dev-nodejs"
add_managed_repo "dev-golang"

# Add per-project image repos for combined or custom dev-* image names.
for config_file in "$ROOT_DIR"/projects/*/config; do
  source "$config_file"
  image_ref="${CONTAINER_IMAGE:-}"
  [[ -z "$image_ref" ]] && continue
  add_managed_repo "${image_ref%%:*}"
done

# Add generated combined runtime repos from Containerfiles/generated.
for generated_file in "$ROOT_DIR"/Containerfiles/generated/Containerfile.*; do
  slug="${generated_file:t}"
  slug="${slug#Containerfile.}"
  [[ -z "$slug" ]] && continue
  add_managed_repo "dev-$slug"
done

# Fallback: include image repos that match known combined runtime naming.
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

typeset -a REMOVE_REFS
typeset -A SEEN_REFS
while IFS=$'\t' read -r repo tag image_id; do
  [[ -z "$repo" || -z "$tag" || -z "$image_id" ]] && continue
  [[ -z "${MANAGED_REPOS[$repo]-}" ]] && continue

  if [[ "$tag" != "latest" && "$tag" != "<none>" ]]; then
    ref="$repo:$tag"
    if [[ -z "${SEEN_REFS[$ref]-}" ]]; then
      REMOVE_REFS+=("$ref")
      SEEN_REFS[$ref]=1
    fi
  fi
done < <(backend_list_images)

if [[ ${#REMOVE_REFS[@]} -eq 0 ]]; then
  echo "No old managed image tags found. Managed latest tags are already clean."
  exit 0
fi

refs=("${(@o)REMOVE_REFS}")

echo "Active backend: $ACTIVE_BACKEND"
echo "Managed repos: ${(@k)MANAGED_REPOS}"
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
