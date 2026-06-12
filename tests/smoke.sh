#!/usr/bin/env bash
# Smoke test harness for dev-containers command surface.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC_BIN="$ROOT_DIR/scripts/dc"

if [[ ! -x "$DC_BIN" ]]; then
  echo "ERROR: dc entrypoint is not executable: $DC_BIN"
  exit 1
fi

run_check() {
  local label="$1"
  shift

  echo "==> $label"
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ pass"
  else
    local exit_code=$?
    echo "  ✗ fail (exit $exit_code)"
    return $exit_code
  fi
}

run_check "dc help" "$DC_BIN" help

if [[ -n "${CONTAINER_BACKEND:-}" ]]; then
  echo "==> backend-dependent checks"
  echo "  backend override: $CONTAINER_BACKEND"
  run_check "dc list" "$DC_BIN" list
  run_check "dc status" "$DC_BIN" status
  run_check "dc clean --dry-run" "$DC_BIN" clean --dry-run
else
  if "$DC_BIN" list >/dev/null 2>&1; then
    echo "==> backend-dependent checks"
    echo "  ✓ backend reachable"
    run_check "dc status" "$DC_BIN" status
    run_check "dc clean --dry-run" "$DC_BIN" clean --dry-run
  else
    echo "==> backend-dependent checks"
    echo "  - skipped (no supported backend detected or runtime unavailable)"
  fi
fi

echo ""
echo "Smoke checks completed."
echo "Notes: list/status/clean may require a reachable backend and configured projects."
