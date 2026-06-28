#!/usr/bin/env bash
# =============================================================================
# tests/contract/run-all.sh - Stubbed-backend functional / contract tests.
#
# Single entrypoint that runs every test file in tests/contract/. These drive
# the real `dce` CLI (or real scripts/*.sh) through fakes of docker/container/
# podman on a private PATH, across multi-step workflows. The real daemon is
# never contacted: the fakes make the suite fast and deterministic while the
# scope stays at the orchestration/contract level.
#
# tests/integration/ is what validates that the backend contract these tests
# assume is actually correct against a real daemon; it is never run from here.
#
# `smoke.sh` is intentionally excluded (it chains selected files AND adds the
# `dce` command-surface checks).
#
# Usage:
#   tests/contract/run-all.sh          # quiet: one line per file; dump failing output
#   tests/contract/run-all.sh -v       # verbose: stream each file's output live
#   CONTAINER_BACKEND=podman tests/contract/run-all.sh   # passed through to test files
# =============================================================================
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: tests/contract/run-all.sh requires Bash 4+ (current: ${BASH_VERSION:-unknown})" >&2
  echo "  macOS: brew install bash" >&2
  exit 1
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE=false
case "${1:-}" in
  -v|--verbose) VERBOSE=true ;;
  -h|--help)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  "") : ;;
  *) echo "Unknown argument: $1 (usage: $0 [-v])" >&2; exit 2 ;;
esac

# Deterministic, sorted discovery of this directory's tests. Exclude this script
# itself and smoke.sh (which lives two levels up, but guard anyway).
mapfile -t FILES < <(
  for f in "$TESTS_DIR"/*.sh; do
    [[ -e "$f" ]] || continue
    base="${f##*/}"
    [[ "$base" == "run-all.sh" ]] && continue
    [[ "$base" == "smoke.sh" ]] && continue
    printf '%s\n' "$f"
  done | sort
)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: no test files found in $TESTS_DIR" >&2
  exit 1
fi

# Run each file as its own process; capture output so a failure can be shown
# without aborting the rest of the suite. rc is read immediately after the
# assignment so set -e (off here anyway) cannot mask it.
passed=0
failed=0
declare -a failed_names=()

for f in "${FILES[@]}"; do
  base="${f##*/}"
  if $VERBOSE; then
    printf '\n========== %s ==========\n' "$base"
    if bash "$f"; then
      printf '  -> PASS: %s\n' "$base"
      passed=$((passed + 1))
    else
      printf '  -> FAIL: %s\n' "$base"
      failed=$((failed + 1))
      failed_names+=("$base")
    fi
  else
    out="$(bash "$f" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      printf '  -> PASS: %s\n' "$base"
      # Surface the project's WARN: convention (e.g. a test noting a missing
      # optional tool) even from a passing test, otherwise quiet mode would
      # swallow it. Reuses the same indent as the failure path.
      warnings="$(printf '%s\n' "$out" | grep 'WARN' || true)"
      [[ -z "$warnings" ]] || printf '%s\n' "$warnings" | sed 's/^/      /'
      passed=$((passed + 1))
    else
      printf '  -> FAIL: %s (exit %s)\n' "$base" "$rc"
      # Re-show the failing file's output, indented for context.
      printf '%s\n' "$out" | sed 's/^/      /'
      failed=$((failed + 1))
      failed_names+=("$base")
    fi
  fi
done

total=$((passed + failed))
printf '\n'
printf '======================================\n'
printf 'Summary: %d passed, %d failed, %d total\n' "$passed" "$failed" "$total"
printf '======================================\n'

if [[ ${#failed_names[@]} -gt 0 ]]; then
  printf 'Failed files:\n'
  for n in "${failed_names[@]}"; do
    printf '  - %s\n' "$n"
  done
  exit 1
fi
exit 0
