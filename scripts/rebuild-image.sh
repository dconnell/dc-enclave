#!/usr/bin/env bash
# =============================================================================
# rebuild-image.sh - Rebuild base and configured derived images
# =============================================================================
set -euo pipefail

TARGET="${1:-all}"

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

case "$TARGET" in
  all|base)
    ;;
  *)
    echo "Usage: dc rebuild-image [all|base]"
    exit 1
    ;;
esac

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

case "$ACTIVE_BACKEND" in
  apple)
    echo "==> Starting apple/container system daemon..."
    backend_system_start 2>/dev/null && echo "✓ Daemon started" || echo "  (already running or not needed)"
    ;;
  colima)
    echo "==> Checking Colima runtime availability..."
    if backend_system_start; then
      echo "✓ Colima Docker runtime is reachable"
    else
      echo "✗ ERROR: Colima runtime is not reachable."
      echo "  Ensure Colima uses Docker runtime and Docker context points to Colima."
      echo "  Try: colima start --runtime docker && docker context use colima"
      exit 1
    fi
    ;;
  docker|orbstack)
    echo "==> Checking Docker-compatible runtime availability..."
    if backend_system_start 2>/dev/null; then
      echo "✓ Docker engine is reachable"
    else
      echo "✗ ERROR: Docker engine is not reachable."
      echo "  Start Docker Desktop or OrbStack and retry."
      exit 1
    fi
    ;;
  podman)
    echo "==> Checking Podman runtime availability..."
    if backend_system_start 2>/dev/null; then
      echo "✓ Podman runtime is reachable"
    else
      echo "✗ ERROR: Podman runtime is not reachable."
      echo "  Start Podman (for macOS: podman machine start) and retry."
      exit 1
    fi
    ;;
esac

echo ""
echo "Selected backend: $ACTIVE_BACKEND"
echo "CLI version: $(backend_version)"
echo "Target: $TARGET"

echo ""
echo "--- Building dev-base ---"
backend_build_image \
  "dev-base:latest" \
  "$ROOT_DIR/Containerfiles/Containerfile.base" \
  "$ROOT_DIR"

if [[ "$TARGET" == "base" ]]; then
  echo ""
  echo "✓ Image rebuild complete for target: $TARGET"
  echo "  Next: run dc rebuild-container <project> to recreate containers from updated images."
  exit 0
fi

dc_load_global_config

CONFIG_DIR="$HOME/.config/dev-containers"
COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"
if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
  echo "ERROR: Compose helper not found at $COMPOSE_SCRIPT"
  exit 1
fi

declare -A BUILT_REPOS=()
declare -A SKIPPED_REPOS=()

while IFS= read -r config_file; do
  [[ -z "$config_file" ]] && continue

  scope_csv="$(bash -c 'source "$1" 2>/dev/null && printf "%s" "${CONTAINER_OVERLAY_SCOPES:-}"' _ "$config_file")"
  scope_csv="$(dc_normalize_scopes_csv "$scope_csv")" || exit 1

  image_ref="$(dc_image_ref_from_scopes "$DC_OVERLAYS_DIR" "$scope_csv")" || exit 1
  image_repo="${image_ref%%:*}"

  if [[ "$image_ref" == "dev-base:latest" ]]; then
    continue
  fi

  if [[ -n "${BUILT_REPOS[$image_repo]-}" || -n "${SKIPPED_REPOS[$image_repo]-}" ]]; then
    continue
  fi

  image_hash="$(dc_image_hash_from_ref "$image_ref")" || {
    echo "ERROR: Could not derive image hash from image ref: $image_ref"
    exit 1
  }

  composed_file="$ROOT_DIR/Containerfiles/generated/Containerfile.${image_hash}"

  echo ""
  echo "--- Building $image_ref ---"
  bash "$COMPOSE_SCRIPT" "$composed_file" "$scope_csv"
  backend_build_image "$image_ref" "$composed_file" "$ROOT_DIR"
  BUILT_REPOS["$image_repo"]=1
done < <(for f in "$CONFIG_DIR"/*/config; do [[ -f "$f" ]] && printf '%s\n' "$f"; done)

echo ""
if [[ ${#BUILT_REPOS[@]} -eq 0 ]]; then
  echo "No configured derived images found to rebuild."
else
  echo "Rebuilt derived repos: $(dc_join_by ', ' "${!BUILT_REPOS[@]}")"
fi

echo ""
echo "✓ Image rebuild complete for target: $TARGET"
echo "  Next: run dc rebuild-container <project> to recreate containers from updated images."
