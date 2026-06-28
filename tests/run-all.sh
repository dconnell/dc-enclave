#!/usr/bin/env bash
# =============================================================================
# tests/run-all.sh - Aggregator over the three fast test tiers.
#
# Runs, in order, every fast/deterministic tier, each with its own discovery
# runner:
#   tests/unit/run-all.sh      - pure host-side helper unit tests
#   tests/contract/run-all.sh  - stubbed-backend functional / contract tests
#   tests/lint/run-all.sh      - static-analysis / policy guards
#
# Real-backend end-to-end coverage lives under tests/integration/run-all.sh and
# is NEVER run from here (it creates/removes real containers).
#
# Usage:
#   tests/run-all.sh            # run all three tiers (quiet)
#   tests/run-all.sh -v         # verbose: stream each file's output live
#   tests/run-all.sh contract   # run a single tier: unit | contract | lint
#   tests/run-all.sh -v lint    # verbose, single tier
# =============================================================================
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: tests/run-all.sh requires Bash 4+ (current: ${BASH_VERSION:-unknown})" >&2
  echo "  macOS: brew install bash" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERBOSE=0
TIERS=(unit contract lint)
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    unit|contract|lint) TIERS=("$arg") ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (usage: $0 [-v] [unit|contract|lint])" >&2; exit 2 ;;
  esac
done

overall_rc=0
for tier in "${TIERS[@]}"; do
  runner="$ROOT/$tier/run-all.sh"
  if [[ ! -f "$runner" ]]; then
    echo "ERROR: $tier runner not found at $runner" >&2
    exit 1
  fi
  printf '\n########## %s tier ##########\n' "$tier"
  if [[ "$VERBOSE" -eq 1 ]]; then
    bash "$runner" -v || overall_rc=1
  else
    bash "$runner" || overall_rc=1
  fi
done

exit "$overall_rc"
