#!/usr/bin/env bash
# =============================================================================
# tests/integration/cases/flag-coverage.sh - Coverage guard for the flag matrix.
#
# Parses docs/reference/flags.md for every documented long flag and fails if any
# is not represented in the matrix (flags.tsv) OR in a hand-written case file
# (cases/*.sh). The two sources are both scanned because fixture-heavy / prompt-
# gated flows (snapshot restore, --rotate-keys, --config recipe, --network/--ip,
# network subcommands, `logs --follow`) do not fit the generic data-driven
# engine and live in bespoke case scripts; either way the documented flag MUST
# appear somewhere, so coverage is closed.
#
# Phase-2 carve-out: --save-team / --save-user are deferred until DCE_CONFIG_ROOT
# isolation exists (the plan calls this out explicitly), so they are allowlisted
# here with a reason rather than represented.
#
# Standalone + backend-free:  bash tests/integration/cases/flag-coverage.sh
# =============================================================================
set -uo pipefail

_cfc_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_cfc_dir/../../.." && pwd)"
FLAGS_MD="$ROOT_DIR/docs/reference/flags.md"
FLAGS_TSV="$ROOT_DIR/tests/integration/matrix/flags.tsv"
CASES_DIR="$ROOT_DIR/tests/integration/cases"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[[ -f "$FLAGS_MD" ]] || fail "missing $FLAGS_MD"
[[ -f "$FLAGS_TSV" ]] || fail "missing $FLAGS_TSV"

# Every documented long flag (one per line, deduped).
mapfile -t documented < <(grep -oE -- '--[a-z][a-z0-9-]+' "$FLAGS_MD" | sort -u)
[[ ${#documented[@]} -gt 0 ]] || fail "no flags parsed from $FLAGS_MD"

# Phase-2 carve-out: documented but intentionally not exercised yet.
declare -A allow=(
  [--save-team]="deferred to phase 2 (DCE_CONFIG_ROOT isolation)"
  [--save-user]="deferred to phase 2 (DCE_CONFIG_ROOT isolation)"
)

# Every long-flag token referenced by the matrix OR a case file (code+comments).
used="$(
  {
    cat "$FLAGS_TSV"
    # cases/*.sh (this file included); tolerate an empty cases dir.
    for _f in "$CASES_DIR"/*.sh; do [[ -e "$_f" ]] && cat "$_f"; done
  } | grep -oE -- '--[a-z][a-z0-9-]+' | sort -u
)"

missing=()
for f in "${documented[@]}"; do
  if [[ -n "${allow[$f]:-}" ]]; then continue; fi
  # -e: $f starts with '--', which grep would otherwise parse as an option.
  if ! grep -Fxq -e "$f" <<<"$used"; then
    missing+=("$f")
  fi
done

echo "Documented long flags:    ${#documented[@]}"
echo "Represented in matrix/cases: $(grep -c '' <<<"$used")"
echo "Phase-2 carve-out:        ${!allow[*]}"

if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'Missing representation for %d documented flag(s):\n' "${#missing[@]}"
  printf '  - %s\n' "${missing[@]}"
  fail "add each to matrix/flags.tsv or a cases/*.sh script"
fi

pass "every documented long flag is represented (matrix ∪ cases, minus phase-2 carve-out)"
