#!/usr/bin/env bash
# =============================================================================
# scripts/rm.sh - `dce rm`: fully remove a dev container project.
#
# Default (full teardown) removes, for the named project:
#   - the container (stopped first if running)
#   - every managed hidden volume (dce-hide-<project>-<hash>)
#   - the per-project config + secrets dir (~/.config/dce-enclave/<name>)
# Escape hatches: --keep-config preserves config+secrets; --keep-volumes
# preserves hidden volumes. --yes/-y skips the confirmation prompt.
#
# Safety:
#   - The host code directory ($REPOS_DIR) is NEVER touched by this command.
#   - The project name is validated and the secrets dir's real path is checked
#     to be under the DC Enclave config root before any rm -rf, so a
#     symlinked project dir cannot redirect deletion elsewhere.
#   - Destructive: requires typing 'yes' to confirm (unless --yes).
# =============================================================================
set -euo pipefail

PROJECT=""
ASSUME_YES=false
KEEP_CONFIG=false
KEEP_VOLUMES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --keep-config)
      KEEP_CONFIG=true
      shift
      ;;
    --keep-volumes)
      KEEP_VOLUMES=true
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      echo "Usage: dce rm <name> [--yes|-y] [--keep-config] [--keep-volumes]" >&2
      exit 1
      ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2
        echo "Usage: dce rm <name> [--yes|-y] [--keep-config] [--keep-volumes]" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Project name is required." >&2
  echo "Usage: dce rm <name> [--yes|-y] [--keep-config] [--keep-volumes]" >&2
  exit 1
fi

# Reject anything outside the identifier grammar new-container accepts, so the
# constructed secrets path can never contain traversal/escape sequences.
if [[ ! "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "ERROR: Invalid project name: $PROJECT" >&2
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

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"

SECRET_DIR="$HOME/.config/dce-enclave/$PROJECT"
CONFIG="$SECRET_DIR/config"

HIDDEN_PATHS=()
REPOS_DIR_VAL=""
BACKEND_OK=false
ACTIVE_BACKEND=""

if [[ -f "$CONFIG" ]]; then
  dce_load_project_config "$CONFIG"
  if ! declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1; then
    CONTAINER_HIDDEN_PATHS=()
  fi
  HIDDEN_PATHS=("${CONTAINER_HIDDEN_PATHS[@]}")
  REPOS_DIR_VAL="${REPOS_DIR:-}"
  if backend_use "${CONTAINER_BACKEND:-}" >/dev/null 2>&1; then
    BACKEND_OK=true
    ACTIVE_BACKEND="$(backend_name)"
  fi
else
  echo "WARN: No config for '$PROJECT' at $CONFIG; attempting best-effort removal by name."
  if backend_use "${CONTAINER_BACKEND:-}" >/dev/null 2>&1; then
    BACKEND_OK=true
    ACTIVE_BACKEND="$(backend_name)"
  fi
fi

if ! $BACKEND_OK; then
  echo "WARN: Backend not reachable; skipping container/volume/snapshot removal."
  echo "      Config + secrets will still be removed (unless --keep-config)."
fi

# Snapshot-artifact disposition for the summary: the snapshot set (image +
# volume + manifest) is atomic and follows --keep-volumes -- preserved with the
# flag, reclaimed without it. When the backend is unreachable the sweep cannot
# run, so any leftover snapshot images/volumes must be reclaimed later by hand.
if $BACKEND_OK; then
  if $KEEP_VOLUMES; then
    SNAP_DISP="PRESERVED (--keep-volumes)"
  else
    SNAP_DISP="REMOVED (snapshot images/volumes/manifests, if any)"
  fi
else
  SNAP_DISP="skipped (backend unreachable; reclaim with 'dce clean --snapshots')"
fi

echo "======================================================================"
echo "Removing project: $PROJECT"
echo "======================================================================"
echo "  Backend:        ${ACTIVE_BACKEND:-(unreachable)}"
echo "  Config/secrets: $SECRET_DIR"
if $KEEP_CONFIG; then
  echo "                 -> PRESERVED (--keep-config)"
else
  echo "                 -> REMOVED"
fi
if [[ ${#HIDDEN_PATHS[@]} -gt 0 ]]; then
  echo "  Hidden paths:   ${HIDDEN_PATHS[*]}"
  if $KEEP_VOLUMES; then
    echo "                 -> volumes PRESERVED (--keep-volumes)"
  else
    echo "                 -> volumes REMOVED"
  fi
fi
echo "  Snapshots:      $SNAP_DISP"
echo "  Host code dir:  ${REPOS_DIR_VAL:-(unknown)}  (NEVER touched by dce rm)"
echo ""
echo "This will remove the container, hidden volumes, snapshot artifacts, and config+secrets for '$PROJECT'"
echo "(each step honors its --keep-* flag as shown above)."
if ! $ASSUME_YES; then
  echo ""
  read -r -p "Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""

if $BACKEND_OK; then
  if backend_exists "$PROJECT"; then
    if backend_is_running "$PROJECT"; then
      echo "==> Stopping container..."
      backend_stop "$PROJECT"
      echo "  ✓ Stopped"
    fi
    echo "==> Removing container..."
    if backend_delete "$PROJECT" 2>/dev/null; then
      echo "  ✓ Container removed"
    else
      echo "  ✗ Could not remove container '$PROJECT' (backend: $ACTIVE_BACKEND)"
    fi
  else
    echo "==> Container already absent"
  fi

  if [[ ${#HIDDEN_PATHS[@]} -gt 0 ]] && ! $KEEP_VOLUMES; then
    echo "==> Removing hidden volumes..."
    for hidden_path in "${HIDDEN_PATHS[@]}"; do
      [[ -z "$hidden_path" ]] && continue
      hidden_volume="$(dce_hidden_volume_name "$PROJECT" "$hidden_path")"
      if backend_remove_volume "$hidden_volume" 2>/dev/null; then
        echo "  ✓ Removed: $hidden_volume ($hidden_path)"
      else
        echo "  - Already gone or in use: $hidden_volume ($hidden_path)"
      fi
    done
  fi

  # Reclaim snapshot artifacts this project owns so they do not leak until a
  # manual `dce clean --snapshots`. Snapshot objects are an atomic
  # (image, volume, manifest) set that follows --keep-volumes: preserved with the
  # flag, reclaimed without it -- the same lifecycle as hidden volumes. When
  # reclaimed, all three go together so no dangling manifest references a swept
  # image/volume.
  if ! $KEEP_VOLUMES; then
    proj_slug="$(dce_project_slug "$PROJECT")"
    snapvol_prefix="dce-snapvol-$proj_slug-"
    snapimg_prefix="dce-snap-$proj_slug-"
    swept=0
    while IFS= read -r listed_obj; do
      [[ -z "$listed_obj" ]] && continue
      [[ "$listed_obj" == "$snapvol_prefix"* ]] || continue
      backend_remove_volume "$listed_obj" 2>/dev/null && swept=$((swept + 1)) || true
    done < <(backend_list_volumes 2>/dev/null)
    while IFS=$'\t' read -r img_repo img_tag _; do
      [[ -z "$img_repo" ]] && continue
      [[ "$img_repo" == "$snapimg_prefix"* ]] || continue
      backend_remove_image "$img_repo:$img_tag" 2>/dev/null && swept=$((swept + 1)) || true
    done < <(backend_list_images 2>/dev/null)
    # Drop this project's snapshot manifests so reclaimed snapshots leave no
    # dangling metadata (image + volume + manifest reclaimed together). The
    # project name is validated above, so the path cannot traverse.
    rm -rf "$(dce_snapshot_volumes_dir "$PROJECT")" 2>/dev/null || true
    if [[ $swept -gt 0 ]]; then
      echo "==> Removed $swept snapshot image(s)/volume(s) for '$PROJECT'."
    fi
  fi
fi

if ! $KEEP_CONFIG; then
  echo "==> Removing config + secrets dir..."
  if [[ -d "$SECRET_DIR" ]]; then
    # Guard against a symlinked project dir escaping the config root: resolve
    # both and require the secrets dir to live under the DC Enclave root.
    dce_root_real="$(cd -P "$HOME/.config/dce-enclave" 2>/dev/null && pwd)"
    secret_real="$(cd -P "$SECRET_DIR" 2>/dev/null && pwd)"
    if [[ -n "$dce_root_real" && -n "$secret_real" ]]; then
      if [[ "$secret_real" != "$dce_root_real" && "$secret_real" != "$dce_root_real"/* ]]; then
        echo "ERROR: Refusing to remove '$SECRET_DIR': resolves outside the DC Enclave config root." >&2
        exit 1
      fi
    fi
    rm -rf "$SECRET_DIR"
    echo "  ✓ Removed: $SECRET_DIR"
  else
    echo "  ✓ Config dir already absent: $SECRET_DIR"
  fi
else
  echo "==> Preserving config + secrets dir (--keep-config): $SECRET_DIR"
fi

echo ""
echo "======================================================================"
echo "Removal complete: $PROJECT"
echo "======================================================================"
if [[ -n "$REPOS_DIR_VAL" ]]; then
  echo "Host code preserved at: $REPOS_DIR_VAL"
  echo "Remove it manually if no longer needed:  rm -rf \"$REPOS_DIR_VAL\""
fi
