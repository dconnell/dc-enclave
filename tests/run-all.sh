#!/usr/bin/env bash
# =============================================================================
# tests/run-all.sh - Single entrypoint that runs every test file in tests/.
#
# Auto-discovers all test scripts in this directory (excluding itself and
# smoke.sh), runs each to completion (no fail-fast), and prints a pass/fail
# summary with a single aggregate exit code. Designed for local pre-push and
# CI use: deterministic order, clean one-line-per-file output by default, full
# output dumped only for failures.
#
# `smoke.sh` is intentionally excluded: it chains these same files AND adds the
# `dc` command-surface checks (help/version) plus the optional backend-dependent
# checks (dc list/status/clean). Run it separately when you want those, e.g.:
#   tests/smoke.sh
#   CONTAINER_BACKEND=podman tests/run-all.sh   # passed through to test files
#
# Usage:
#   tests/run-all.sh          # quiet: one line per file; dump failing output
#   tests/run-all.sh -v       # verbose: stream each file's output live
# =============================================================================
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: tests/run-all.sh requires Bash 4+ (current: ${BASH_VERSION:-unknown})" >&2
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

# Deterministic, sorted discovery. Exclude this script and smoke.sh (see header).
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
