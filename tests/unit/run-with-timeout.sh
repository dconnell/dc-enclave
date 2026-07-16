#!/usr/bin/env bash
# =============================================================================
# tests/unit/run-with-timeout.sh - Unit tests for dce_run_with_timeout.
#
# Verifies the portable timeout helper: a fast command returns its exit code,
# a slow command is killed and returns 124 (GNU timeout convention), and the
# function works on macOS (no system `timeout`) via the bash-native fallback.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- fast command succeeds ---
dce_run_with_timeout 5 true || fail "fast command should succeed"

# --- fast failing command returns non-zero ---
if dce_run_with_timeout 5 false 2>/dev/null; then
  fail "failing command should return non-zero"
fi

# --- exit code preserved on success (0) ---
dce_run_with_timeout 5 bash -c 'exit 0' || fail "exit 0 not preserved"

# --- exit code preserved on failure (non-timeout, non-zero) ---
_rc=0
dce_run_with_timeout 5 bash -c 'exit 3' 2>/dev/null || _rc=$?
[[ $_rc -eq 3 ]] || fail "exit 3 not preserved (got $_rc)"

# --- slow command is killed, returns 124 ---
_start="$(date +%s)"
_rc=0
dce_run_with_timeout 1 sleep 10 2>/dev/null || _rc=$?
_elapsed=$(( $(date +%s) - _start ))
[[ $_rc -eq 124 ]] || fail "timeout should return 124 (got $_rc)"
[[ $_elapsed -le 3 ]] || fail "timeout took too long (${_elapsed}s)"

# --- stdout is captured (not swallowed by the timeout mechanism) ---
_out="$(dce_run_with_timeout 5 printf 'hello')"
[[ "$_out" == "hello" ]] || fail "stdout not captured [$_out]"

pass "dce_run_with_timeout: fast/slow/success/fail/timeout/stdout"
