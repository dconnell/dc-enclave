#!/usr/bin/env bash
# =============================================================================
# tests/integration/run-all.sh - Real-backend end-to-end integration suite.
#
# Runs the `dce` command surface against every selected backend's REAL runtime
# (no stubs): full lifecycle, fixture-heavy flag flows, the data-driven flag
# matrix, and install. Every created project is removed via `dce rm`; a global
# trap replays cleanup + a leak check even on interrupt.
#
# Selection / modes (env):
#   INTEGRATION_BACKENDS="docker,podman"  narrow from detected (typo = error)
#   INTEGRATION_SKIP_UNREACHABLE=1         drop undetected/unreachable instead
#   INTEGRATION_MODE=smoke                 command-surface + install only (fast)
#   INTEGRATION_MODE=full                  (default) + lifecycle + flag matrix
#   INTEGRATION_KEEP_ARTIFACTS=1           retain temp workspace + logs
#
# Usage:
#   tests/integration/run-all.sh            # all detected backends, full mode
#   tests/integration/run-all.sh --list     # preview backends + cases, no side effects
#   INTEGRATION_BACKENDS=docker tests/integration/run-all.sh
# =============================================================================
set -uo pipefail

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: integration suite requires Bash 4+ (current: ${BASH_VERSION:-unknown})" >&2
  echo "  macOS: brew install bash" >&2
  exit 1
fi

_RUN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_RUN_DIR/../.." && pwd)"
export ROOT_DIR

# --- arg parsing -------------------------------------------------------------
LIST_ONLY=false
MODE="${INTEGRATION_MODE:-full}"
for a in "$@"; do
  case "$a" in
    --list) LIST_ONLY=true ;;
    -v|--verbose) export INTEGRATION_VERBOSE=1 ;;
    smoke|full) MODE="$a" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $a (usage: $0 [--list] [-v] [smoke|full])" >&2; exit 2 ;;
  esac
done
export INTEGRATION_MODE="$MODE"

# =============================================================================
# --list: preview detected + selected backends and the case inventory, with NO
# side effects (no workspace, no trap, no backend contact beyond detection).
# =============================================================================
# shellcheck disable=SC1091
source "$_RUN_DIR/lib/naming.sh"
# shellcheck disable=SC1091  # brings in lib/container-backend.sh detection
source "$_RUN_DIR/lib/backend-discovery.sh"

if $LIST_ONLY; then
  echo "=== Backend discovery (preview) ==="
  printf 'Detected available backends:\n'
  detected="$(it_detected_backends)"
  if [[ -z "$detected" ]]; then
    echo "  (none)"
  else
    while IFS= read -r b; do printf '  - %s\n' "$b"; done <<< "$detected"
  fi

  printf 'Selected backends (after INTEGRATION_BACKENDS filter):\n'
  if ! selected="$(it_select_backends)"; then
    echo "  ERROR: selection failed (see above)"; exit 1
  fi
  if [[ -z "$selected" ]]; then
    echo "  (none selected -- nothing would run)"
  else
    while IFS= read -r b; do printf '  - %s\n' "$b"; done <<< "$selected"
  fi

  echo
  echo "=== Case inventory (mode=$MODE) ==="
  echo "  command-surface : version/help/aliases + unknown-cmd   [all backends]"
  echo "  install         : real dotfiles install effect         [all backends]"
  if [[ "$MODE" == "full" ]]; then
    echo "  lifecycle       : full flow + fixture flags (--config/--repo-path/"
    echo "                    --from-snap/--rotate-keys/--network/--ip/network subcmds)"
    echo "  sync            : --sync Mutagen lifecycle (skipped if mutagen absent)"
    echo "  flags-matrix    : data-driven rows from matrix/flags.tsv (independent +"
    echo "                    pairwise flags + backend-specific expected failures)"
  fi
  echo
  echo "Coverage guard:"
  ( bash "$_RUN_DIR/cases/flag-coverage.sh" ) || echo "  (coverage guard FAILED -- see above)"
  exit 0
fi

# =============================================================================
# Full run: source the harness (sets up workspace + trap) + matrix + cases.
# =============================================================================
# shellcheck disable=SC1091
source "$_RUN_DIR/lib/harness.sh"
# shellcheck disable=SC1091
source "$_RUN_DIR/lib/matrix.sh"
# shellcheck disable=SC1091
source "$_RUN_DIR/cases/command-surface.sh"
# shellcheck disable=SC1091
source "$_RUN_DIR/cases/lifecycle.sh"
# shellcheck disable=SC1091
source "$_RUN_DIR/cases/sync.sh"
# shellcheck disable=SC1091
source "$_RUN_DIR/cases/install.sh"
# shellcheck disable=SC1091
source "$_RUN_DIR/cases/flags-matrix.sh"

# Fail fast before creating anything if we are inside a container.
it_assert_not_in_container || exit 3

# --- LEAD: what backends were found + what will run ---------------------------
echo "======================================================================"
echo "DC Enclave integration suite"
echo "  run id : $IT_RUN_ID"
echo "  mode   : $MODE"
echo "  repos  : $IT_REPOS_DIR (isolated)"
echo "  logs   : $IT_ARTIFACTS_ROOT/$IT_RUN_ID/<backend>/<case>.log"
echo "======================================================================"

echo
echo "Backends detected:"
detected="$(it_detected_backends)"
if [[ -z "$detected" ]]; then
  echo "  (none) -- nothing to do"
else
  while IFS= read -r b; do printf '  - %s\n' "$b"; done <<< "$detected"
fi

echo "Backends selected:"
if ! selected="$(it_select_backends)"; then
  echo "ERROR: backend selection failed (INTEGRATION_BACKENDS override issue)" >&2
  exit 1
fi
if [[ -z "$selected" ]]; then
  echo "  (none selected)"
fi
# Persist the selection so the cleanup leak-scan iterates exactly these.
printf '%s\n' "$selected" > "$IT_ROOT_WS/backends.tsv"
while IFS= read -r b; do
  [[ -n "$b" ]] && printf '  - %s\n' "$b"
done <<< "$selected"

# --- per-backend execution ---------------------------------------------------
while IFS= read -r backend; do
  [[ -n "$backend" ]] || continue
  echo
  echo "----------------------------------------------------------------------"
  echo "Backend: $backend"
  echo "----------------------------------------------------------------------"

  if ! it_preflight_backend "$backend"; then
    if [[ "${INTEGRATION_SKIP_UNREACHABLE:-0}" == "1" ]]; then
      echo "  (skipping unreachable backend $backend)"
      it_record "$backend" SKIP "preflight" "unreachable (INTEGRATION_SKIP_UNREACHABLE=1)"
      continue
    fi
    echo "  (strict mode: marking backend FAILED -- preflight unreachable)"
    it_record "$backend" FAIL "preflight" "unreachable (set INTEGRATION_SKIP_UNREACHABLE=1 to skip)"
    continue
  fi

  it_cases_command_surface "$backend"
  it_cases_install "$backend"
  if [[ "$MODE" == "full" ]]; then
    it_cases_lifecycle "$backend"
    it_cases_sync "$backend"
    it_cases_flags "$backend"
  fi
done <<< "$selected"

# --- per-backend summary -----------------------------------------------------
echo
echo "======================================================================"
echo "Summary by backend"
echo "======================================================================"
printf '  %-12s %8s %8s %8s %8s\n' "Backend" "Passed" "Failed" "Skipped" "Total"
# Tally results per backend, and remember which backends actually ran (had at
# least one recorded case). Backends that never ran are shown as dashes.
declare -A _pass _fail _skip _ran
while IFS=$'\t' read -r b status _ _; do
  [[ -n "$b" ]] || continue
  _ran[$b]=1
  case "$status" in
    PASS) _pass[$b]=$(( ${_pass[$b]:-0} + 1 )) ;;
    FAIL) _fail[$b]=$(( ${_fail[$b]:-0} + 1 )) ;;
    SKIP) _skip[$b]=$(( ${_skip[$b]:-0} + 1 )) ;;
  esac
done < "$IT_RESULTS"

# Always list every backend the suite can test for, regardless of whether it ran
# on this host. A backend with no recorded results shows "-" in every column.
ALL_BACKENDS=(apple docker orbstack colima podman)
overall_pass=0; overall_fail=0; overall_skip=0
for b in "${ALL_BACKENDS[@]}"; do
  if [[ -z "${_ran[$b]:-}" ]]; then
    printf '  %-12s %8s %8s %8s %8s\n' "$b" "-" "-" "-" "-"
    continue
  fi
  p=${_pass[$b]:-0}; f=${_fail[$b]:-0}; s=${_skip[$b]:-0}
  t=$((p + f + s))
  printf '  %-12s %8d %8d %8d %8d\n' "$b" "$p" "$f" "$s" "$t"
  overall_pass=$((overall_pass + p))
  overall_fail=$((overall_fail + f))
  overall_skip=$((overall_skip + s))
done
total=$((overall_pass + overall_fail + overall_skip))
echo "----------------------------------------------------------------------"
printf '  %-12s %8d %8d %8d %8d\n' "TOTAL" "$overall_pass" "$overall_fail" "$overall_skip" "$total"

# --- cleanup + leak check (also the trap body; idempotent) -------------------
echo
it_cleanup
cleanup_rc=$?
if [[ $cleanup_rc -ne 0 ]]; then
  echo "======================================================================"
  echo "LEAK CHECK FAILED: leftover test resources remain (see remediation above)" >&2
  echo "======================================================================"
fi

# --- final exit code: non-zero on any FAIL or any leak -----------------------
if [[ $overall_fail -gt 0 || $cleanup_rc -ne 0 ]]; then
  echo "Result: FAIL ($overall_fail failed case(s), leak=$([[ $cleanup_rc -ne 0 ]] && echo yes || echo no))" >&2
  exit 1
fi
echo "Result: PASS ($overall_pass case(s), $overall_skip skipped)"
exit 0
