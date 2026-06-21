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

# Like run_check, but also asserts a regex appears in the command's combined
# output. Used where exit code alone is not enough (e.g. version/help text).
run_check_output() {
  local label="$1"
  local pattern="$2"
  shift 2

  local out=""
  out="$("$@" 2>&1)" || true

  echo "==> $label"
  if [[ "$out" =~ $pattern ]]; then
    echo "  ✓ pass"
  else
    echo "  ✗ fail: expected /$pattern/ in output"
    echo "    command: $*"
    echo "    output:  $out"
    return 1
  fi
}

run_check "dc help" "$DC_BIN" help

echo ""
echo "==> dc version"
run_check "dc version" "$DC_BIN" version
run_check "dc --version" "$DC_BIN" --version
run_check "dc -v" "$DC_BIN" -v
run_check_output "dc --version prints 'dc <semver>'" '^dc [0-9]+\.[0-9]+\.[0-9]+$' "$DC_BIN" --version
run_check_output "dc help summary shows a version number" '[0-9]+\.[0-9]+\.[0-9]+' "$DC_BIN" help
run_check_output "dc help documents the version command" 'version' "$DC_BIN" help
run_check "dc help version" "$DC_BIN" help version

run_check "hidden path helper checks" "$ROOT_DIR/tests/hidden-paths.sh"
run_check "rebuild hidden-volume checks" "$ROOT_DIR/tests/rebuild-hidden-volumes.sh"
run_check "config security checks" "$ROOT_DIR/tests/config-security.sh"
run_check "supply-chain guard" "$ROOT_DIR/tests/supply-chain.sh"
run_check "overlay conventions guard" "$ROOT_DIR/tests/overlays.sh"
run_check "security token argv checks" "$ROOT_DIR/tests/security-token-argv.sh"
run_check "SSH host trust guard" "$ROOT_DIR/tests/security-ssh-host-trust.sh"
run_check "completion checks" "$ROOT_DIR/tests/completion.sh"
run_check "scopes + image-ref unit checks" "$ROOT_DIR/tests/scopes-image-ref.sh"
run_check "compose layering checks" "$ROOT_DIR/tests/compose-layering.sh"
run_check "backend dispatch matrix" "$ROOT_DIR/tests/backend-dispatch.sh"
run_check "new/rebuild lifecycle checks" "$ROOT_DIR/tests/new-container-lifecycle.sh"
run_check "internal-networking checks" "$ROOT_DIR/tests/networks.sh"

echo ""
echo "==> dc doctor --help (usage, no backend required)"
run_check_output "dc doctor --help shows usage" 'doctor \[backend\|project\]' "$DC_BIN" doctor --help

echo ""
echo "==> dc help <command> (detailed help)"
run_check "dc help new" "$DC_BIN" help new
run_check "dc help start" "$DC_BIN" help start
run_check "dc help stop" "$DC_BIN" help stop
run_check "dc help status" "$DC_BIN" help status
run_check "dc help list" "$DC_BIN" help list
run_check "dc help shell" "$DC_BIN" help shell
run_check "dc help logs" "$DC_BIN" help logs
run_check "dc help exec" "$DC_BIN" help exec
run_check "dc help restart" "$DC_BIN" help restart
run_check "dc help rm" "$DC_BIN" help rm
run_check "dc help rebuild-container" "$DC_BIN" help rebuild-container
run_check "dc help rebuild-image" "$DC_BIN" help rebuild-image
run_check "dc help clean" "$DC_BIN" help clean
run_check "dc help doctor" "$DC_BIN" help doctor
run_check "dc help network" "$DC_BIN" help network
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
