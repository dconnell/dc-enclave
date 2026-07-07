#!/usr/bin/env bash
# =============================================================================
# tests/lint/script-dir-resolution.sh - Pin the SCRIPT_DIR/ROOT_DIR resolution idiom.
#
# Every standalone scripts/ entrypoint resolves its own location before it can
# source lib/common.sh (the dispatcher execs each subcommand as a separate
# process, and tests invoke scripts directly), so each script carries the same
# symlink-chasing block. That block is currently duplicated across 26 files; a
# subtle change to the resolution logic (e.g. handling a new symlink edge case)
# would otherwise have to land in lockstep everywhere.
#
# This guard pins the canonical form: for each script that has a
# BASH_SOURCE[0]-based self-resolution block, it extracts the block, normalizes
# the two throwaway temp-var names to placeholders, and byte-compares the
# structural lines against the canonical idiom. Temp-var spelling is cosmetic;
# the structural lines (the symlink loop, -P, readlink, unset, ROOT_DIR) are the
# invariants that must not drift.
#
# Completion files (scripts/_dce, scripts/dce-complete.bash) use a different,
# completion-context resolver and are out of scope.
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

# Canonical idiom, temp vars canonicalized to _x (the BASH_SOURCE carrier) and
# _y (the per-iteration dir). Each non-empty line is matched exactly.
#
# Two accepted forms:
#   FULL        — resolves SCRIPT_DIR AND ROOT_DIR (scripts that source a lib).
#   SCRIPT_ONLY — resolves SCRIPT_DIR only (e.g. restart.sh, an orchestrator
#                 over $SCRIPT_DIR siblings that never sources lib/common.sh).
read -r -d '' CANONICAL_FULL <<'EOF' || true
_x="${BASH_SOURCE[0]}"
while [[ -L "$_x" ]]; do
  _y="$(cd -P "$(dirname "$_x")" && pwd)"
  _x="$(readlink "$_x")"
  [[ "$_x" != /* ]] && _x="$_y/$_x"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_x")" && pwd)"
unset _x _y
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EOF
read -r -d '' CANONICAL_SCRIPT_ONLY <<'EOF' || true
_x="${BASH_SOURCE[0]}"
while [[ -L "$_x" ]]; do
  _y="$(cd -P "$(dirname "$_x")" && pwd)"
  _x="$(readlink "$_x")"
  [[ "$_x" != /* ]] && _x="$_y/$_x"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_x")" && pwd)"
unset _x _y
EOF
# Normalize to no trailing newline so they compare cleanly against the
# command-substitution-extracted block (which also has none).
while [[ "$CANONICAL_FULL" == *$'\n' ]]; do CANONICAL_FULL="${CANONICAL_FULL%$'\n'}"; done
while [[ "$CANONICAL_SCRIPT_ONLY" == *$'\n' ]]; do CANONICAL_SCRIPT_ONLY="${CANONICAL_SCRIPT_ONLY%$'\n'}"; done

# Only tracked scripts/ files count; tests/ and generated/ are out of scope.
mapfile -t SCRIPTS < <(git -C "$ROOT_DIR" ls-files 'scripts/*' || true)
[[ ${#SCRIPTS[@]} -gt 0 ]] || fail "no tracked scripts found to scan"

violations=()
checked=0

for s in "${SCRIPTS[@]}"; do
  f="$ROOT_DIR/$s"
  [[ -f "$f" ]] || continue
  # Scope: files that carry a BASH_SOURCE[0] self-resolution block.
  grep -qE '^_[A-Za-z][A-Za-z0-9_]*="\$\{BASH_SOURCE\[0\]\}"' "$f" || continue

  checked=$((checked + 1))

  # Extract the contiguous block (it is always a tight run with no internal
  # blanks) and detect the two temp-var names in one pass.
  #   line 1: "<main>\t<dir>"   (the throwaway identifiers)
  #   then:   the raw block lines, from the BASH_SOURCE assignment through the
  #           last contiguous resolution line (ROOT_DIR=, or unset when the
  #           script needs only SCRIPT_DIR).
  #
  # The dir var is read from the `unset <main> <dir>` line; it is whatever
  # token on that line is not the main var.
  extracted="$(
    awk '
      /^_[A-Za-z][A-Za-z0-9_]*="\$\{BASH_SOURCE\[0\]\}"/ {
        if (!inb) {
          inb = 1
          match($0, /^_[A-Za-z][A-Za-z0-9_]*/)
          main = substr($0, RSTART, RLENGTH)
          buf = $0
          next
        }
      }
      inb {
        # The block is contiguous; a blank line ends it.
        if ($0 ~ /^[[:space:]]*$/) {
          if (!emitted) {
            printf "%s\t%s\n", main, dirv
            printf "%s", buf
            emitted = 1
          }
          exit
        }
        buf = buf "\n" $0
        if ($0 ~ /^unset[[:space:]]/) {
          n = split($0, parts, /[[:space:]]+/)
          for (i = 2; i <= n; i++) {
            if (parts[i] != main) { dirv = parts[i]; break }
          }
        }
      }
      END {
        if (inb && !emitted) {
          printf "%s\t%s\n", main, dirv
          printf "%s", buf
        }
      }
    ' "$f"
  )"

  main="$(printf '%s' "$extracted" | head -n1 | cut -f1)"
  dirv="$(printf '%s' "$extracted" | head -n1 | cut -f2)"
  block="$(printf '%s' "$extracted" | tail -n +2)"

  [[ -n "$main" ]] || { violations+=("$s (could not detect main temp var)"); continue; }
  [[ -n "$dirv" ]] || { violations+=("$s (could not detect dir temp var / missing unset)"); continue; }

  # Normalize temp vars -> placeholders so the comparison is structural, not
  # spelling-sensitive. Replace the longer name first so a short name that is a
  # prefix of the longer one cannot corrupt it. These identifiers are simple
  # (_src/_dir, _sub/_d) and never appear as proper substrings of other tokens
  # in the block, so a plain global replace is exact here.
  if ((${#dirv} > ${#main})); then
    norm="$(printf '%s\n' "$block" | sed "s/${dirv}/_y/g; s/${main}/_x/g")"
  else
    norm="$(printf '%s\n' "$block" | sed "s/${main}/_x/g; s/${dirv}/_y/g")"
  fi

  if [[ "$norm" != "$CANONICAL_FULL" && "$norm" != "$CANONICAL_SCRIPT_ONLY" ]]; then
    violations+=("$s")
  fi
done

[[ $checked -gt 0 ]] || fail "no scripts with a SCRIPT_DIR resolution block found to scan"

if [[ ${#violations[@]} -gt 0 ]]; then
  echo "SCRIPT_DIR/ROOT_DIR resolution must match the canonical symlink-chasing idiom" >&2
  echo "(drift in ${#violations[@]} of $checked file(s)):" >&2
  for v in "${violations[@]}"; do
    printf '  %s\n' "$v" >&2
  done
  echo "" >&2
  echo "Accepted form (FULL; temp vars may be any _name, every other line must match)." >&2
  echo "Scripts that only need SCRIPT_DIR may omit the trailing ROOT_DIR line." >&2
  printf '%s\n' "$CANONICAL_FULL" | sed 's/^/    /' >&2
  exit 1
fi

pass "scripts/ SCRIPT_DIR/ROOT_DIR resolution blocks are canonical ($checked file(s))"
