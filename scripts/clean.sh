#!/usr/bin/env bash
# =============================================================================
# scripts/clean.sh - `dc clean`: reclaim backend storage.
#
# Two modes:
#   default             Remove old/orphan managed *image* tags. Expected repos
#                       (dev-base + currently-configured dev-img-*) keep
#                       :latest and shed other tags; orphan repos lose all tags.
#   --hidden-volumes    Remove orphan managed *hidden volumes* (dc-hide-* no
#                       longer referenced by an active project config). An
#                       optional project name scopes it to one project.
#
# Unrelated images/volumes are never touched. --dry-run previews only.
# =============================================================================
set -euo pipefail
shopt -s nullglob

DRY_RUN=false
CLEAN_HIDDEN_VOLUMES=false
TARGET_PROJECT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --hidden-volumes)
      CLEAN_HIDDEN_VOLUMES=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -* )
      echo "Usage: dc clean [--dry-run] [--hidden-volumes [name]]"
      exit 1
      ;;
    *)
      if [[ -n "$TARGET_PROJECT" ]]; then
        echo "Usage: dc clean [--dry-run] [--hidden-volumes [name]]"
        exit 1
      fi
      TARGET_PROJECT="$1"
      shift
      ;;
  esac
done

if [[ -n "$TARGET_PROJECT" && "$CLEAN_HIDDEN_VOLUMES" == "false" ]]; then
  echo "Usage: dc clean [--dry-run] [--hidden-volumes [name]]"
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

dc_load_global_config

# --- Hidden-volume cleanup mode -----------------------------------------------
# Build the set of volumes still referenced by active project configs, then
# remove any dc-hide-* volume not in that set (optionally scoped to one project).
if $CLEAN_HIDDEN_VOLUMES; then
  declare -A EXPECTED_VOLUMES=()

  for config_file in "$HOME"/.config/dev-containers/*/config; do
    [[ -f "$config_file" ]] || continue

    project_name="$(basename "$(dirname "$config_file")")"
    if [[ -n "$TARGET_PROJECT" && "$project_name" != "$TARGET_PROJECT" ]]; then
      continue
    fi

    CONTAINER_HIDDEN_PATHS=()
    # Load through the hardened path; skip (don't abort) projects whose config
    # has invalid values so cleanup of healthy projects still proceeds.
    if ! dc_load_project_config "$config_file"; then
      dc_warn "Skipping invalid or unsafe config: $config_file"
      continue
    fi

    if ! declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1; then
      CONTAINER_HIDDEN_PATHS=()
    fi

    normalized_hidden_csv=""
    if ! normalized_hidden_csv="$(dc_normalize_hidden_paths_values "${CONTAINER_HIDDEN_PATHS[@]:-}")"; then
      dc_warn "Skipping invalid hidden paths in $config_file"
      continue
    fi

    normalized_hidden_paths=()
    if [[ -n "$normalized_hidden_csv" ]]; then
      IFS=',' read -r -a normalized_hidden_paths <<< "$normalized_hidden_csv"
    fi

    for hidden_path in "${normalized_hidden_paths[@]}"; do
      [[ -z "$hidden_path" ]] && continue
      hidden_volume="$(dc_hidden_volume_name "$project_name" "$hidden_path")"
      EXPECTED_VOLUMES["$hidden_volume"]=1
    done
  done

  managed_prefix="dc-hide-"
  if [[ -n "$TARGET_PROJECT" ]]; then
    managed_prefix="dc-hide-$(dc_project_slug "$TARGET_PROJECT")-"
  fi

  REMOVE_VOLUMES=()
  declare -A SEEN_VOLUMES=()
  while IFS= read -r volume_name; do
    [[ -z "$volume_name" ]] && continue
    [[ "$volume_name" == "$managed_prefix"* ]] || continue
    if [[ -n "${EXPECTED_VOLUMES[$volume_name]-}" ]]; then
      continue
    fi
    if [[ -z "${SEEN_VOLUMES[$volume_name]-}" ]]; then
      REMOVE_VOLUMES+=("$volume_name")
      SEEN_VOLUMES["$volume_name"]=1
    fi
  done < <(backend_list_volumes)

  if [[ ${#REMOVE_VOLUMES[@]} -eq 0 ]]; then
    if [[ -n "$TARGET_PROJECT" ]]; then
      echo "No orphan hidden volumes found for project '$TARGET_PROJECT'."
    else
      echo "No orphan hidden volumes found."
    fi
    exit 0
  fi

  IFS=$'\n' clean_hidden_volumes=($(printf '%s\n' "${REMOVE_VOLUMES[@]}" | sort))
  unset IFS

  echo "Active backend: $ACTIVE_BACKEND"
  echo "The following orphan hidden volumes will be removed:"
  for volume_name in "${clean_hidden_volumes[@]}"; do
    echo "  - $volume_name"
  done

  if $DRY_RUN; then
    echo ""
    echo "Dry run only; nothing removed."
    exit 0
  fi

  removed=0
  failed=0
  for volume_name in "${clean_hidden_volumes[@]}"; do
    if backend_remove_volume "$volume_name"; then
      removed=$((removed + 1))
    else
      failed=$((failed + 1))
      echo "WARN: Could not remove hidden volume $volume_name (may be in use)."
    fi
  done

  echo ""
  echo "Hidden volume cleanup complete. Removed: $removed"
  if [[ $failed -gt 0 ]]; then
    echo "Could not remove: $failed"
  fi
  exit 0
fi

# A repo is "managed" by dev-containers if it's dev-base or a dev-img-<16hex>.
# Only these are ever candidates for cleanup; everything else is left alone.
is_managed_repo() {
  local repo="$1"
  [[ "$repo" == "dev-base" || "$repo" =~ ^dev-img-[0-9a-f]{16}$ ]]
}

# --- Image-tag cleanup mode --------------------------------------------------
# Expected repos = dev-base + every image currently selected by a project config.
declare -A EXPECTED_REPOS=()
EXPECTED_REPOS["dev-base"]=1

for config_file in "$HOME"/.config/dev-containers/*/config; do
  [[ -f "$config_file" ]] || continue

  if ! scope_csv="$(dc_config_extract_scalar "$config_file" CONTAINER_OVERLAY_SCOPES)"; then
    dc_warn "Skipping config without CONTAINER_OVERLAY_SCOPES: $config_file"
    continue
  fi
  if ! scope_csv="$(dc_normalize_scopes_csv "$scope_csv")"; then
    dc_warn "Skipping invalid scope config: $config_file"
    continue
  fi

  if ! image_ref="$(dc_image_ref_from_scopes "$(dc_team_overlays_dir)" "$(dc_user_overlays_dir)" "$scope_csv")"; then
    dc_warn "Skipping config with unresolved scopes: $config_file"
    continue
  fi
  EXPECTED_REPOS["${image_ref%%:*}"]=1
done

declare -A MANAGED_REPOS=()
while IFS=$'\t' read -r repo tag image_id; do
  [[ -z "$repo" || "$repo" == "<none>" ]] && continue
  if is_managed_repo "$repo"; then
    MANAGED_REPOS["$repo"]=1
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

  is_expected=false
  if [[ -n "${EXPECTED_REPOS[$repo]-}" ]]; then
    is_expected=true
  fi

  if $is_expected; then
    if [[ "$tag" == "latest" || "$tag" == "<none>" ]]; then
      continue
    fi
  else
    [[ "$tag" == "<none>" ]] && continue
  fi

  ref="$repo:$tag"
  if [[ -z "${SEEN_REFS[$ref]-}" ]]; then
    REMOVE_REFS+=("$ref")
    SEEN_REFS["$ref"]=1
  fi
done < <(backend_list_images)

if [[ ${#REMOVE_REFS[@]} -eq 0 ]]; then
  echo "No managed image tags found to remove."
  exit 0
fi

IFS=$'\n' refs=($(printf '%s\n' "${REMOVE_REFS[@]}" | sort))
unset IFS

expected_repo_names=("${!EXPECTED_REPOS[@]}")
managed_repo_names=("${!MANAGED_REPOS[@]}")
IFS=$'\n' expected_repo_names=($(printf '%s\n' "${expected_repo_names[@]}" | sort))
IFS=$'\n' managed_repo_names=($(printf '%s\n' "${managed_repo_names[@]}" | sort))
unset IFS

echo "Active backend: $ACTIVE_BACKEND"
echo "Expected repos: ${expected_repo_names[*]}"
echo "Managed repos: ${managed_repo_names[*]}"
echo ""
echo "The following managed image tags will be removed:"
for ref in "${refs[@]}"; do
  repo="${ref%%:*}"
  if [[ -n "${EXPECTED_REPOS[$repo]-}" ]]; then
    echo "  - $ref (old tag)"
  else
    echo "  - $ref (orphan repo)"
  fi
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
