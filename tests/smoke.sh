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
run_check "hidden path helper checks" "$ROOT_DIR/tests/hidden-paths.sh"
run_check "rebuild hidden-volume checks" "$ROOT_DIR/tests/rebuild-hidden-volumes.sh"
run_check "config security checks" "$ROOT_DIR/tests/config-security.sh"
run_check "supply-chain guard" "$ROOT_DIR/tests/supply-chain.sh"

echo ""
echo "==> dc help <command> (detailed help)"
run_check "dc help new" "$DC_BIN" help new
run_check "dc help start" "$DC_BIN" help start
run_check "dc help stop" "$DC_BIN" help stop
run_check "dc help status" "$DC_BIN" help status
run_check "dc help list" "$DC_BIN" help list
run_check "dc help shell" "$DC_BIN" help shell
run_check "dc help rebuild-container" "$DC_BIN" help rebuild-container
run_check "dc help rebuild-image" "$DC_BIN" help rebuild-image
run_check "dc help clean" "$DC_BIN" help clean
run_check "dc help install" "$DC_BIN" help install
run_check "dc help help" "$DC_BIN" help help

echo ""
echo "==> dc help <alias>"
run_check "dc help s (status alias)" "$DC_BIN" help s
run_check "dc help ls (list alias)" "$DC_BIN" help ls

echo ""
echo "==> dc help <unknown> (should fail)"
if "$DC_BIN" help nonexistent >/dev/null 2>&1; then
  echo "  ✗ fail (expected non-zero exit)"
  exit 1
else
  echo "  ✓ pass"
fi

if [[ -n "${CONTAINER_BACKEND:-}" ]]; then
  echo "==> backend-dependent checks"
  echo "  backend override: $CONTAINER_BACKEND"
  run_check "dc list" "$DC_BIN" list
  run_check "dc status" "$DC_BIN" status
  run_check "dc clean --dry-run" "$DC_BIN" clean --dry-run
  run_check "dc clean --hidden-volumes --dry-run" "$DC_BIN" clean --hidden-volumes --dry-run
else
  if "$DC_BIN" list >/dev/null 2>&1; then
    echo "==> backend-dependent checks"
    echo "  ✓ backend reachable"
    run_check "dc status" "$DC_BIN" status
    run_check "dc clean --dry-run" "$DC_BIN" clean --dry-run
    run_check "dc clean --hidden-volumes --dry-run" "$DC_BIN" clean --hidden-volumes --dry-run
  else
    echo "==> backend-dependent checks"
    echo "  - skipped (no supported backend detected or runtime unavailable)"
  fi
fi

echo ""
echo "Smoke checks completed."
echo "Notes: list/status/clean may require a reachable backend and configured projects."
