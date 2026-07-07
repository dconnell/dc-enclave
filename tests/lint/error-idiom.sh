#!/usr/bin/env bash
# =============================================================================
# tests/lint/error-idiom.sh - Fatal-error style guards for scripts/.
#
# Enforces three invariants in tracked scripts/ files:
#   1) no inline echo/printf "ERROR: ..." (use dce_die),
#   2) no "USAGE >&2; dce_die ..." ordering (error message must come first),
#   3) no dce_die call before sourcing lib/common.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# Scan every tracked script entrypoint (including extensionless wrappers such as
# scripts/dce), not only *.sh files.
mapfile -t SCRIPTS < <(git -C "$ROOT_DIR" ls-files 'scripts/*' || true)
[[ ${#SCRIPTS[@]} -gt 0 ]] || fail "no tracked scripts found to scan"

inline_error_prints=()
usage_before_die=()
die_before_source=()

for s in "${SCRIPTS[@]}"; do
  f="$ROOT_DIR/$s"
  [[ -f "$f" ]] || continue

  # Inline `echo|printf "ERROR: ..."` should be replaced by dce_die.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    inline_error_prints+=("$s:$line")
  done < <(grep -nE '^[[:space:]]*[^#].*\b(echo|printf)[[:space:]]+(-[[:alnum:]-]+[[:space:]]+)*["'"'"']ERROR:[[:space:]]*' "$f" 2>/dev/null || true)

  # Usage must not be printed before dce_die.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    usage_before_die+=("$s:$line")
  done < <(grep -nE '[Uu][Ss][Aa][Gg][Ee][[:space:]]*>&2[[:space:]]*;[[:space:]]*dce_die([[:space:]]|$)' "$f" 2>/dev/null || true)

  # dce_die depends on lib/common.sh and must not appear before that source line.
  analysis="$(awk '
    BEGIN { source_ln=0; die_ln=0 }
    /^[[:space:]]*#/ { next }
    source_ln == 0 && /^[[:space:]]*(source|\.)[[:space:]]+"\$ROOT_DIR\/lib\/common\.sh"/ { source_ln=NR }
    die_ln == 0 && /(^|[^[:alnum:]_])dce_die([[:space:]]|$)/ { die_ln=NR }
    END { printf "%d %d\n", source_ln, die_ln }
  ' "$f")"
  read -r source_ln die_ln <<< "$analysis"
  if [[ "$die_ln" -gt 0 ]] && { [[ "$source_ln" -eq 0 ]] || [[ "$die_ln" -lt "$source_ln" ]]; }; then
    die_before_source+=("$s:$die_ln (source at ${source_ln:-0})")
  fi
done

if [[ ${#inline_error_prints[@]} -gt 0 || ${#usage_before_die[@]} -gt 0 || ${#die_before_source[@]} -gt 0 ]]; then
  if [[ ${#inline_error_prints[@]} -gt 0 ]]; then
    echo "Inline fatal-error printing is disallowed; use dce_die (found ${#inline_error_prints[@]} site(s)):" >&2
    for v in "${inline_error_prints[@]}"; do
      printf '  %s\n' "$v" >&2
    done
  fi

  if [[ ${#usage_before_die[@]} -gt 0 ]]; then
    echo "Usage banner must not be printed before dce_die (found ${#usage_before_die[@]} site(s)):" >&2
    for v in "${usage_before_die[@]}"; do
      printf '  %s\n' "$v" >&2
    done
  fi

  if [[ ${#die_before_source[@]} -gt 0 ]]; then
    echo "dce_die appears before sourcing lib/common.sh (found ${#die_before_source[@]} file(s)):" >&2
    for v in "${die_before_source[@]}"; do
      printf '  %s\n' "$v" >&2
    done
  fi
  exit 1
fi

pass "scripts/ fatal-error style guards passed"
