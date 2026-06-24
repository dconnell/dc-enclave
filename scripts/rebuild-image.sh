#!/usr/bin/env bash
# =============================================================================
# scripts/rebuild-image.sh - `dce rebuild-image`: rebuild managed images.
#
# `base` rebuilds only dce-base:latest. `all` (default) rebuilds dce-base plus
# every derived image (dce-img-<hash>) currently selected by configured project
# scopes, composing each on the fly. Images are rebuilt into the active
# backend's store only. After rebuilding, run `dce rebuild-container <name>` to
# recreate containers from the refreshed images.
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
    echo "Usage: dce rebuild-image [all|base]"
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
echo "--- Building dce-base ---"
backend_build_image \
  "dce-base:latest" \
  "$ROOT_DIR/Containerfiles/Containerfile.base" \
  "$ROOT_DIR"

if [[ "$TARGET" == "base" ]]; then
  echo ""
  echo "✓ Image rebuild complete for target: $TARGET"
  echo "  Next: run dce rebuild-container <project> to recreate containers from updated images."
  exit 0
fi

dce_load_global_config

CONFIG_DIR="$HOME/.config/dce-enclave"
COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"
if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
  echo "ERROR: Compose helper not found at $COMPOSE_SCRIPT"
  exit 1
fi

# Scan every project config, derive its image, and build each unique derived
# repo once. dce-base-only projects are skipped (built above as the base).
declare -A BUILT_REPOS=()

# Provenance inputs shared across this rebuild run: the dce-base Id feeds the
# base.id label, and one build timestamp stamps every image built in this run.
PROV_BASE_ID="$(backend_image_id "dce-base:latest")"
PROV_BUILT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

while IFS= read -r config_file; do
  [[ -z "$config_file" ]] && continue

  scope_csv="$(dce_config_extract_scalar "$config_file" CONTAINER_OVERLAY_SCOPES)" || exit 1
  scope_csv="$(dce_normalize_scopes_csv "$scope_csv")" || exit 1

  image_ref="$(dce_image_ref_from_scopes "$(dce_team_overlays_dir)" "$(dce_user_overlays_dir)" "$scope_csv")" || exit 1
  image_repo="${image_ref%%:*}"

  # dce-base-only projects have no overlay provenance to record.
  [[ "$image_ref" == "dce-base:latest" ]] && continue

  project_name="$(basename "$(dirname "$config_file")")"

  # Build each unique derived repo once; other projects sharing it reuse it.
  if [[ -z "${BUILT_REPOS[$image_repo]-}" ]]; then
    image_hash="$(dce_image_hash_from_ref "$image_ref")" || {
      echo "ERROR: Could not derive image hash from image ref: $image_ref"
      exit 1
    }

    composed_file="$ROOT_DIR/Containerfiles/generated/Containerfile.${image_hash}"

    echo ""
    echo "--- Building $image_ref ---"
    bash "$COMPOSE_SCRIPT" "$composed_file" "$scope_csv"
    backend_build_image "$image_ref" "$composed_file" "$ROOT_DIR" \
      --build-arg "DC_BASE_ID=$PROV_BASE_ID" \
      --build-arg "DC_BUILT_UTC=$PROV_BUILT_UTC"
    BUILT_REPOS["$image_repo"]=1
  fi

  # Record provenance per project (deduped). Shared images get an entry in each
  # project's log so `dce provenance <project>` is populated.
  dce_log_provenance "$project_name" "$image_ref" "rebuild" "$DC_TEAM_DIR" "$DC_USER_DIR" "$scope_csv" "$PROV_BASE_ID"
done < <(for f in "$CONFIG_DIR"/*/config; do [[ -f "$f" ]] && printf '%s\n' "$f"; done)

echo ""
if [[ ${#BUILT_REPOS[@]} -eq 0 ]]; then
  echo "No configured derived images found to rebuild."
else
  echo "Rebuilt derived repos: $(dce_join_by ', ' "${!BUILT_REPOS[@]}")"
fi

echo ""
echo "✓ Image rebuild complete for target: $TARGET"
echo "  Next: run dce rebuild-container <project> to recreate containers from updated images."
