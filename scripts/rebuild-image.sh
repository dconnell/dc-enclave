#!/usr/bin/env zsh
# =============================================================================
# rebuild-image.sh — Rebuild dev-container images without recreating containers
#
# Usage:
#   rebuild-image.sh [all|base|nodejs|golang]
#
# Notes:
#   - Uses the same backend abstraction as setup/new/rebuild scripts.
#   - Rebuilding images does not restart existing containers.
#   - Run dc rebuild <project> after image rebuild to pick up changes.
#   - Rebuilds affected combined runtime images from projects/*/config.
# =============================================================================
set -euo pipefail
setopt null_glob

TARGET="${1:-all}"

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
POSTGRES_CLIENT_MAJOR="${POSTGRES_CLIENT_MAJOR:-16}"

case "$TARGET" in
  all|base|nodejs|golang)
    ;;
  *)
    echo "Usage: scripts/rebuild-image.sh [all|base|nodejs|golang]"
    exit 1
    ;;
esac

if [[ "$ACTIVE_BACKEND" == "apple" ]]; then
  echo "==> Starting apple/container system daemon..."
  backend_system_start 2>/dev/null && echo "✓ Daemon started" || echo "  (already running or not needed)"
else
  echo "==> Checking Docker-compatible runtime availability..."
  if backend_system_start 2>/dev/null; then
    echo "✓ Docker engine is reachable"
  else
    echo "✗ ERROR: Docker engine is not reachable."
    echo "  Start Docker Desktop or OrbStack and retry."
    exit 1
  fi
fi

echo ""
echo "Selected backend: $ACTIVE_BACKEND"
echo "CLI version: $(backend_version)"
echo "Target: $TARGET"
echo "PostgreSQL client major (base only): $POSTGRES_CLIENT_MAJOR"

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

generate_combined_containerfile() {
  local combined_file="$1"
  shift
  local -a types=("$@")

  mkdir -p "${combined_file:h}"

  {
    echo "FROM dev-base:latest"

    for t in "${types[@]}"; do
      local source_containerfile="$ROOT_DIR/Containerfiles/Containerfile.$t"
      if [[ ! -f "$source_containerfile" ]]; then
        echo "ERROR: Missing source Containerfile: $source_containerfile" >&2
        exit 1
      fi

      echo ""
      echo "# --- begin Containerfile.$t ---"
      awk 'NR == 1 && $1 == "FROM" { next } $1 == "CMD" { next } { print }' "$source_containerfile"
      echo "# --- end Containerfile.$t ---"
    done

    echo ""
    echo 'CMD ["sleep", "infinity"]'
  } > "$combined_file"
}

rebuild_affected_combined_images() {
  local -a project_configs=("$ROOT_DIR"/projects/*/config)
  local -i rebuilt_count=0
  local -i skipped_backend=0
  typeset -A built_slugs

  if [[ ${#project_configs[@]} -eq 0 ]]; then
    echo ""
    echo "No project configs found, skipping combined image rebuilds."
    return
  fi

  for config_file in "${project_configs[@]}"; do
    source "$config_file"

    local project="${CONTAINER_PROJECT:-${config_file:h:t}}"
    local project_backend="${CONTAINER_BACKEND:-$ACTIVE_BACKEND}"
    local project_types="${CONTAINER_TYPE:-}"
    local project_image="${CONTAINER_IMAGE:-}"

    if [[ "$project_backend" != "$ACTIVE_BACKEND" ]]; then
      ((skipped_backend++))
      continue
    fi

    if [[ "$project_types" != *,* ]]; then
      continue
    fi

    if ! target_affects_types "$project_types"; then
      continue
    fi

    local -a raw_types=("${(@s:,:)project_types}")
    local -a ordered_types=()
    typeset -A selected_types
    for raw_type in "${raw_types[@]}"; do
      local normalized_type="${raw_type//[[:space:]]/}"
      case "$normalized_type" in
        nodejs|golang)
          selected_types[$normalized_type]=1
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

    local type_slug="${(j:-:)ordered_types}"
    if [[ -n "${built_slugs[$type_slug]-}" ]]; then
      continue
    fi

    local combined_containerfile="$ROOT_DIR/Containerfiles/generated/Containerfile.$type_slug"
    local combined_image="${project_image:-dev-${type_slug}:latest}"

    echo ""
    echo "--- Building combined image $combined_image (types: ${(j:,:)ordered_types}) ---"
    generate_combined_containerfile "$combined_containerfile" "${ordered_types[@]}"
    backend_build_image "$combined_image" "$combined_containerfile" "$ROOT_DIR"

    built_slugs[$type_slug]=1
    ((rebuilt_count++))
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
}

build_base() {
  echo ""
  echo "--- Building dev-base ---"
  backend_build_image \
    "dev-base:latest" \
    "$ROOT_DIR/Containerfiles/Containerfile.base" \
    "$ROOT_DIR" \
    --build-arg "PG_CLIENT_MAJOR=$POSTGRES_CLIENT_MAJOR"
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
