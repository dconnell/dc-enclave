#!/usr/bin/env bash
# =============================================================================
# scripts/clean.sh - `dce clean`: reclaim backend storage.
#
# Two modes:
#   default             Remove old/orphan managed *image* tags. Expected repos
#                       (dce-base + currently-configured dce-img-*) keep
#                       :latest and shed other tags; orphan repos lose all tags.
#   --hidden-volumes    Remove orphan managed *hidden volumes* (dce-hide-* no
#                       longer referenced by an active project config). An
#                       optional project name scopes it to one project.
#
# Unrelated images/volumes are never touched. --dry-run previews only.
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

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"

DRY_RUN=false
CLEAN_HIDDEN_VOLUMES=false
CLEAN_SNAPSHOTS=false
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
    --snapshots)
      CLEAN_SNAPSHOTS=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -* )
      echo "Usage: dce clean [--dry-run] [--hidden-volumes [name]] [--snapshots [name]]"
      exit 1
      ;;
    *)
      if [[ -n "$TARGET_PROJECT" ]]; then
        echo "Usage: dce clean [--dry-run] [--hidden-volumes [name]] [--snapshots [name]]"
        exit 1
      fi
      TARGET_PROJECT="$1"
      shift
      ;;
  esac
done

if [[ -n "$TARGET_PROJECT" && "$CLEAN_HIDDEN_VOLUMES" == "false" && "$CLEAN_SNAPSHOTS" == "false" ]]; then
  echo "Usage: dce clean [--dry-run] [--hidden-volumes [name]] [--snapshots [name]]"
  exit 1
fi

if [[ "$CLEAN_HIDDEN_VOLUMES" == "true" && "$CLEAN_SNAPSHOTS" == "true" ]]; then
  dce_die "--hidden-volumes and --snapshots are mutually exclusive."
fi

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

case "$ACTIVE_BACKEND" in
  apple)
    backend_system_start 2>/dev/null || true
    ;;
  colima)
    if ! backend_system_start; then
      dce_die "Colima runtime is not reachable.
Ensure Colima uses Docker runtime and Docker context points to Colima.
Try: colima start --runtime docker && docker context use colima"
    fi
    ;;
  docker|orbstack)
    if ! backend_system_start 2>/dev/null; then
      dce_die "Docker-compatible runtime is not reachable.
Start Docker Desktop or OrbStack and retry."
    fi
    ;;
  podman)
    if ! backend_system_start 2>/dev/null; then
      dce_die "Podman runtime is not reachable.
Start Podman (for macOS: podman machine start) and retry."
    fi
    ;;
esac

dce_load_global_config

# --- Hidden-volume cleanup mode -----------------------------------------------
# Build the set of volumes still referenced by active project configs, then
# remove any dce-hide-* volume not in that set (optionally scoped to one project).
if $CLEAN_HIDDEN_VOLUMES; then
  declare -A EXPECTED_VOLUMES=()

  for config_file in "$HOME"/.config/dce-enclave/*/config; do
    [[ -f "$config_file" ]] || continue

    project_name="$(basename "$(dirname "$config_file")")"
    if [[ -n "$TARGET_PROJECT" && "$project_name" != "$TARGET_PROJECT" ]]; then
      continue
    fi

    CONTAINER_HIDDEN_PATHS=()
    # Load through the hardened path; skip (don't abort) projects whose config
    # has invalid values so cleanup of healthy projects still proceeds.
    if ! dce_load_project_config "$config_file"; then
      dce_warn "Skipping invalid or unsafe config: $config_file"
      continue
    fi

    if ! declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1; then
      CONTAINER_HIDDEN_PATHS=()
    fi

    normalized_hidden_csv=""
    if ! normalized_hidden_csv="$(dce_normalize_hidden_paths_values "${CONTAINER_HIDDEN_PATHS[@]:-}")"; then
      dce_warn "Skipping invalid hidden paths in $config_file"
      continue
    fi

    normalized_hidden_paths=()
    if [[ -n "$normalized_hidden_csv" ]]; then
      IFS=',' read -r -a normalized_hidden_paths <<< "$normalized_hidden_csv"
    fi

    for hidden_path in "${normalized_hidden_paths[@]}"; do
      [[ -z "$hidden_path" ]] && continue
      hidden_volume="$(dce_hidden_volume_name "$project_name" "$hidden_path")"
      EXPECTED_VOLUMES["$hidden_volume"]=1
    done
  done

  managed_prefix="dce-hide-"
  if [[ -n "$TARGET_PROJECT" ]]; then
    managed_prefix="dce-hide-$(dce_project_slug "$TARGET_PROJECT")-"
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

  mapfile -t clean_hidden_volumes < <(printf '%s\n' "${REMOVE_VOLUMES[@]}" | sort)

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

# --- Snapshot cleanup mode ----------------------------------------------------
# Reclaim dce-snap-* images (one-off container-FS snapshots). The default sweep
# above already ignores them (is_managed_repo only matches dce-base /
# dce-img-<16hex>), so snapshots are NEVER reclaimed without this flag. An
# optional project name scopes to dce-snap-<slug>-*. --dry-run previews only.
if $CLEAN_SNAPSHOTS; then
  snap_prefix="dce-snap-"
  if [[ -n "$TARGET_PROJECT" ]]; then
    snap_prefix="dce-snap-$(dce_project_slug "$TARGET_PROJECT")-"
  fi

  declare -A SEEN_SNAPS=()
  REMOVE_SNAPS=()
  while IFS=$'\t' read -r repo tag image_id; do
    [[ -z "$repo" || "$repo" == "<none>" ]] && continue
    [[ "$repo" == "$snap_prefix"* ]] || continue
    [[ "$tag" == "latest" || "$tag" == "<none>" ]] || continue
    local_ref="$repo:$tag"
    if [[ -z "${SEEN_SNAPS[$local_ref]-}" ]]; then
      REMOVE_SNAPS+=("$local_ref")
      SEEN_SNAPS["$local_ref"]=1
    fi
  done < <(backend_list_images)

  # Snapshot volumes (dce-snapvol-*) are reclaimed alongside images. They are
  # named dce-snapvol-<slug>-<label>-<hash>; scope by the same project slug.
  vol_prefix="dce-snapvol-"
  if [[ -n "$TARGET_PROJECT" ]]; then
    vol_prefix="dce-snapvol-$(dce_project_slug "$TARGET_PROJECT")-"
  fi
  REMOVE_SNAPVOLS=()
  while IFS= read -r vol_name; do
    [[ -z "$vol_name" ]] && continue
    [[ "$vol_name" == "$vol_prefix"* ]] || continue
    REMOVE_SNAPVOLS+=("$vol_name")
  done < <(backend_list_volumes 2>/dev/null)

  if [[ ${#REMOVE_SNAPS[@]} -eq 0 && ${#REMOVE_SNAPVOLS[@]} -eq 0 ]]; then
    if [[ -n "$TARGET_PROJECT" ]]; then
      echo "No snapshots found for project '$TARGET_PROJECT'."
    else
      echo "No snapshots found."
    fi
    exit 0
  fi

  echo "Active backend: $ACTIVE_BACKEND"
  echo "The following snapshots will be removed:"
  for ref in "${REMOVE_SNAPS[@]}"; do
    sz="$(backend_image_size "$ref" 2>/dev/null || true)"
    if [[ -n "$sz" ]]; then
      sz_h="$(awk -v b="$sz" 'BEGIN { split("B KB MB GB TB", u, " "); i=1; while (b>=1024 && i<5){b/=1024;i++} printf "%.1f%s", b, u[i] }')"
      printf '  - %s (%s)\n' "$ref" "$sz_h"
    else
      printf '  - %s\n' "$ref"
    fi
  done
  if [[ ${#REMOVE_SNAPVOLS[@]} -gt 0 ]]; then
    echo "The following snapshot volumes will be removed:"
    for vol_name in "${REMOVE_SNAPVOLS[@]}"; do
      printf '  - %s\n' "$vol_name"
    done
  fi

  if $DRY_RUN; then
    echo ""
    echo "Dry run only; nothing removed."
    exit 0
  fi

  removed=0
  failed=0
  for ref in "${REMOVE_SNAPS[@]}"; do
    if backend_remove_image "$ref"; then
      removed=$((removed + 1))
    else
      failed=$((failed + 1))
      echo "WARN: Could not remove $ref (may be in use)."
    fi
  done

  vol_removed=0
  vol_failed=0
  for vol_name in "${REMOVE_SNAPVOLS[@]}"; do
    if backend_remove_volume "$vol_name" 2>/dev/null; then
      vol_removed=$((vol_removed + 1))
    else
      vol_failed=$((vol_failed + 1))
    fi
  done

  echo ""
  echo "Snapshot cleanup complete. Images removed: $removed"
  [[ $failed -gt 0 ]] && echo "Could not remove (images): $failed"
  if [[ ${#REMOVE_SNAPVOLS[@]} -gt 0 ]]; then
    echo "Volumes removed: $vol_removed"
    [[ $vol_failed -gt 0 ]] && echo "Could not remove (volumes, may be in use): $vol_failed"
  fi
  exit 0
fi

# A repo is "managed" by DC Enclave if it's dce-base or a dce-img-<16hex>.
# Only these are ever candidates for cleanup; everything else is left alone.
is_managed_repo() {
  local repo="$1"
  [[ "$repo" == "dce-base" || "$repo" =~ ^dce-img-[0-9a-f]{16}$ ]]
}

# --- Image-tag cleanup mode --------------------------------------------------
# Expected repos = dce-base + every image currently selected by a project config.
declare -A EXPECTED_REPOS=()
EXPECTED_REPOS["dce-base"]=1

for config_file in "$HOME"/.config/dce-enclave/*/config; do
  [[ -f "$config_file" ]] || continue

  if ! scope_csv="$(dce_config_extract_scalar "$config_file" CONTAINER_OVERLAY_SCOPES)"; then
    dce_warn "Skipping config without CONTAINER_OVERLAY_SCOPES: $config_file"
    continue
  fi
  if ! scope_csv="$(dce_normalize_scopes_csv "$scope_csv")"; then
    dce_warn "Skipping invalid scope config: $config_file"
    continue
  fi

  if ! image_ref="$(dce_image_ref_from_scopes "$(dce_team_overlays_dir)" "$(dce_user_overlays_dir)" "$scope_csv")"; then
    dce_warn "Skipping config with unresolved scopes: $config_file"
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

mapfile -t refs < <(printf '%s\n' "${REMOVE_REFS[@]}" | sort)

expected_repo_names=("${!EXPECTED_REPOS[@]}")
managed_repo_names=("${!MANAGED_REPOS[@]}")
mapfile -t expected_repo_names < <(printf '%s\n' "${expected_repo_names[@]}" | sort)
mapfile -t managed_repo_names < <(printf '%s\n' "${managed_repo_names[@]}" | sort)

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
