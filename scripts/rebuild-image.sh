#!/usr/bin/env bash
# =============================================================================
# rebuild-image.sh - Rebuild shared base image without recreating containers
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

echo ""
echo "✓ Image rebuild complete for target: $TARGET"
echo "  Next: run dc rebuild <project> to recreate containers from updated image(s)."
