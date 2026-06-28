#!/usr/bin/env bash
# =============================================================================
# tests/lint/run-all.sh - Static analysis / policy guards.
#
# Single entrypoint that runs every file in tests/lint/. These do not test
# runtime behavior; they run a linter (shellcheck) or grep committed sources to
# enforce build-time / supply-chain conventions (no curl|bash, digest pinning,
# overlay structural shape, SSH host-trust pin integrity).
#
# Some guards degrade gracefully when an optional tool is absent: for example,
# the static-analysis guard for shell scripts emits WARN: lines and exits 0.
# The runner surfaces those WARN lines even in quiet mode so the gap stays
# visible.
#
# `smoke.sh` is intentionally excluded (it chains selected files AND adds the
# `dce` command-surface checks).
#
# Usage:
#   tests/lint/run-all.sh          # quiet: one line per file; dump failing output
#   tests/lint/run-all.sh -v       # verbose: stream each file's output live
# =============================================================================
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: tests/lint/run-all.sh requires Bash 4+ (current: ${BASH_VERSION:-unknown})" >&2
  echo "  macOS: brew install bash" >&2
  exit 1
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE=false
case "${1:-}" in
  -v|--verbose) VERBOSE=true ;;
  -h|--help)
    sed -n '2,18p' "$0"
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
      # Surface the project's WARN: convention (e.g. shellcheck.sh noting a
      # missing ShellCheck install) even from a passing test, otherwise quiet
      # mode would swallow it. Reuses the same indent as the failure path.
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
