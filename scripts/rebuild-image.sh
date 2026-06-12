#!/usr/bin/env bash
# =============================================================================
# rebuild-image.sh - Rebuild dev-container images without recreating containers
# =============================================================================
set -euo pipefail
shopt -s nullglob

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

COMPOSE_SCRIPT="$SCRIPT_DIR/compose-containerfile.sh"
if [[ ! -f "$COMPOSE_SCRIPT" ]]; then
  echo "ERROR: Compose helper not found at $COMPOSE_SCRIPT"
  exit 1
fi

backend_use "${CONTAINER_BACKEND:-}"
ACTIVE_BACKEND="$(backend_name)"

case "$TARGET" in
  all|base|nodejs|golang)
    ;;
  *)
    echo "Usage: dc rebuild-image [all|base|nodejs|golang]"
    exit 1
    ;;
esac

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

target_affects_types() {
  local project_types="$1"

  case "$TARGET" in
    all|base)
      return 0
      ;;
    nodejs)
      [[ ",$project_types," == *",nodejs,"* ]]
      ;;
    golang)
      [[ ",$project_types," == *",golang,"* ]]
      ;;
  esac
}

rebuild_affected_combined_images() {
  local -a project_configs=("$HOME"/.config/dev-containers/*/config)
  local rebuilt_count=0
  local skipped_backend=0
  local skipped_project_mode=0
  local -A built_slugs=()

  if [[ ${#project_configs[@]} -eq 0 ]]; then
    echo ""
    echo "No project configs found, skipping combined image rebuilds."
    return
  fi

  for config_file in "${project_configs[@]}"; do
    source "$config_file"

    local project_backend="${CONTAINER_BACKEND:-$ACTIVE_BACKEND}"
    local project_types="${CONTAINER_RUNTIME_TYPES:-${CONTAINER_TYPE:-}}"
    local project_mode="${CONTAINER_IMAGE_MODE:-shared}"
    local project_image="${CONTAINER_IMAGE:-}"

    if [[ "$project_backend" != "$ACTIVE_BACKEND" ]]; then
      skipped_backend=$((skipped_backend + 1))
      continue
    fi

    if [[ "$project_mode" != "shared" ]]; then
      skipped_project_mode=$((skipped_project_mode + 1))
      continue
    fi

    if [[ "$project_types" != *,* ]]; then
      continue
    fi

    if ! target_affects_types "$project_types"; then
      continue
    fi

    local -a raw_types=()
    IFS=',' read -r -a raw_types <<< "$project_types"

    local -A selected_types=()
    local -a ordered_types=()

    for raw_type in "${raw_types[@]}"; do
      local normalized_type="${raw_type//[[:space:]]/}"
      case "$normalized_type" in
        nodejs|golang)
          selected_types["$normalized_type"]=1
          ;;
      esac
    done

    for t in nodejs golang; do
      if [[ -n "${selected_types[$t]-}" ]]; then
        ordered_types+=("$t")
      fi
    done

    if [[ ${#ordered_types[@]} -lt 2 ]]; then
      continue
    fi

    local type_slug=""
    type_slug="$(dc_join_by '-' "${ordered_types[@]}")"
    if [[ -n "${built_slugs[$type_slug]-}" ]]; then
      continue
    fi

    local combined_containerfile="$ROOT_DIR/Containerfiles/generated/Containerfile.$type_slug"
    local combined_image="${project_image:-dev-${type_slug}:latest}"
    local ordered_csv=""
    ordered_csv="$(dc_join_by ',' "${ordered_types[@]}")"

    echo ""
    echo "--- Building shared combined image $combined_image (types: $ordered_csv) ---"
    bash "$COMPOSE_SCRIPT" "$combined_containerfile" "$ordered_csv"
    backend_build_image "$combined_image" "$combined_containerfile" "$ROOT_DIR"

    built_slugs["$type_slug"]=1
    rebuilt_count=$((rebuilt_count + 1))
  done

  echo ""
  if [[ $rebuilt_count -gt 0 ]]; then
    echo "✓ Rebuilt $rebuilt_count combined runtime image type(s) for active backend: $ACTIVE_BACKEND"
  else
    echo "No affected combined runtime images to rebuild for target: $TARGET"
  fi

  if [[ $skipped_backend -gt 0 ]]; then
    echo "Note: skipped $skipped_backend project config(s) with backend different from active backend: $ACTIVE_BACKEND"
  fi

  if [[ $skipped_project_mode -gt 0 ]]; then
    echo "Note: skipped $skipped_project_mode project-scoped image config(s); rebuild those with 'dc rebuild <project>'."
  fi
}

build_base() {
  echo ""
  echo "--- Building dev-base ---"
  backend_build_image \
    "dev-base:latest" \
    "$ROOT_DIR/Containerfiles/Containerfile.base" \
    "$ROOT_DIR"
}

build_nodejs() {
  echo ""
  echo "--- Building dev-nodejs ---"
  backend_build_image \
    "dev-nodejs:latest" \
    "$ROOT_DIR/Containerfiles/Containerfile.nodejs" \
    "$ROOT_DIR"
}

build_golang() {
  echo ""
  echo "--- Building dev-golang ---"
  backend_build_image \
    "dev-golang:latest" \
    "$ROOT_DIR/Containerfiles/Containerfile.golang" \
    "$ROOT_DIR"
}

case "$TARGET" in
  all)
    build_base
    build_nodejs
    build_golang
    ;;
  base)
    build_base
    ;;
  nodejs)
    build_nodejs
    ;;
  golang)
    build_golang
    ;;
esac

rebuild_affected_combined_images

echo ""
echo "✓ Image rebuild complete for target: $TARGET"
echo "  Next: run dc rebuild <project> to recreate containers from updated image(s)."
