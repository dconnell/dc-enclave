#!/usr/bin/env bash
# Smoke test harness for DC Enclave command surface.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC_BIN="$ROOT_DIR/scripts/dce"

if [[ ! -x "$DC_BIN" ]]; then
  echo "ERROR: dce entrypoint is not executable: $DC_BIN"
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

run_check "dce help" "$DC_BIN" help

echo ""
echo "==> dce version"
run_check "dce version" "$DC_BIN" version
run_check "dce --version" "$DC_BIN" --version
run_check "dce -v" "$DC_BIN" -v
run_check_output "dce --version prints 'dce <semver>'" '^dce [0-9]+\.[0-9]+\.[0-9]+$' "$DC_BIN" --version
run_check_output "dce help summary shows a version number" '[0-9]+\.[0-9]+\.[0-9]+' "$DC_BIN" help
run_check_output "dce help documents the version command" 'version' "$DC_BIN" help
run_check "dce help version" "$DC_BIN" help version

run_check "hidden path helper checks" "$ROOT_DIR/tests/unit/hidden-paths.sh"
run_check "rebuild hidden-volume checks" "$ROOT_DIR/tests/unit/rebuild-hidden-volumes.sh"
run_check "config security checks" "$ROOT_DIR/tests/unit/config-security.sh"
run_check "supply-chain guard" "$ROOT_DIR/tests/lint/supply-chain.sh"
run_check "overlay conventions guard" "$ROOT_DIR/tests/lint/overlays.sh"
run_check "security token argv checks" "$ROOT_DIR/tests/contract/security-token-argv.sh"
run_check "SSH host trust guard" "$ROOT_DIR/tests/lint/security-ssh-host-trust.sh"
run_check "completion checks" "$ROOT_DIR/tests/unit/completion.sh"
run_check "scopes + image-ref unit checks" "$ROOT_DIR/tests/unit/scopes-image-ref.sh"
run_check "compose layering checks" "$ROOT_DIR/tests/contract/compose-layering.sh"
run_check "backend dispatch matrix" "$ROOT_DIR/tests/contract/backend-dispatch.sh"
run_check "new/rebuild lifecycle checks" "$ROOT_DIR/tests/contract/new-container-lifecycle.sh"
run_check "snapshot checks" "$ROOT_DIR/tests/contract/snapshots.sh"
run_check "snapshot-volume checks" "$ROOT_DIR/tests/contract/snapshot-volumes.sh"
run_check "internal-networking checks" "$ROOT_DIR/tests/contract/networks.sh"

echo ""
echo "==> dce doctor --help (usage, no backend required)"
run_check_output "dce doctor --help shows usage" 'doctor \[backend\|project\]' "$DC_BIN" doctor --help

echo ""
echo "==> dce help <command> (detailed help)"
run_check "dce help new" "$DC_BIN" help new
run_check "dce help start" "$DC_BIN" help start
run_check "dce help stop" "$DC_BIN" help stop
run_check "dce help status" "$DC_BIN" help status
run_check "dce help list" "$DC_BIN" help list
run_check "dce help shell" "$DC_BIN" help shell
run_check "dce help editor" "$DC_BIN" help editor
run_check "dce help logs" "$DC_BIN" help logs
run_check "dce help exec" "$DC_BIN" help exec
run_check "dce help restart" "$DC_BIN" help restart
run_check "dce help rm" "$DC_BIN" help rm
run_check "dce help rebuild-container" "$DC_BIN" help rebuild-container
run_check "dce help rebuild-image" "$DC_BIN" help rebuild-image
run_check "dce help snapshot" "$DC_BIN" help snapshot
run_check "dce help provenance" "$DC_BIN" help provenance
run_check "dce help clean" "$DC_BIN" help clean
run_check "dce help config" "$DC_BIN" help config
run_check "dce help doctor" "$DC_BIN" help doctor
run_check "dce help network" "$DC_BIN" help network
run_check "dce help install" "$DC_BIN" help install
run_check "dce help help" "$DC_BIN" help help

echo ""
echo "==> dce help <alias>"
run_check "dce help s (status alias)" "$DC_BIN" help s
run_check "dce help ls (list alias)" "$DC_BIN" help ls

echo ""
echo "==> dce help <unknown> (should fail)"
if "$DC_BIN" help nonexistent >/dev/null 2>&1; then
  echo "  ✗ fail (expected non-zero exit)"
  exit 1
else
  echo "  ✓ pass"
fi

if [[ -n "${CONTAINER_BACKEND:-}" ]]; then
  echo "==> backend-dependent checks"
  echo "  backend override: $CONTAINER_BACKEND"
  run_check "dce list" "$DC_BIN" list
  run_check "dce status" "$DC_BIN" status
  run_check "dce clean --dry-run" "$DC_BIN" clean --dry-run
  run_check "dce clean --hidden-volumes --dry-run" "$DC_BIN" clean --hidden-volumes --dry-run
else
  if "$DC_BIN" list >/dev/null 2>&1; then
    echo "==> backend-dependent checks"
    echo "  ✓ backend reachable"
    run_check "dce status" "$DC_BIN" status
    run_check "dce clean --dry-run" "$DC_BIN" clean --dry-run
    run_check "dce clean --hidden-volumes --dry-run" "$DC_BIN" clean --hidden-volumes --dry-run
  else
    echo "==> backend-dependent checks"
    echo "  - skipped (no supported backend detected or runtime unavailable)"
  fi
fi

echo ""
echo "Smoke checks completed."
echo "Notes: list/status/clean may require a reachable backend and configured projects."
