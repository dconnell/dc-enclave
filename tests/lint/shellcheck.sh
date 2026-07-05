#!/usr/bin/env bash
# =============================================================================
# tests/lint/shellcheck.sh - Static analysis pass over every Bash script in the repo.
#
# Auto-discovered by tests/run-all.sh alongside the functional tests, so the
# same invocation that runs the behavioral suite also surfaces ShellCheck
# findings. ShellCheck is OPTIONAL at runtime:
#   - installed + clean   -> exit 0, one PASS: line per file
#   - installed + finding -> exit 1, the finding is shown
#   - absent              -> one WARN: line per script (with install link) on
#                            stderr, exit 0 (suite stays green but the gap is
#                            visible; tests/run-all.sh surfaces those WARN lines
#                            even in quiet mode)
#
# Developed against ShellCheck >= 0.9.0; existing directives in the repo imply
# 0.7.x+ already. Version is not hard-checked -- only documented here.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SC_URL="https://github.com/koalaman/shellcheck"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# A file is in scope if it has a .sh/.bash extension OR its first line is a
# shebang whose interpreter is a POSIX/Bash shell. Covers #!/usr/bin/env bash,
# #!/bin/bash, #!/usr/bin/env sh, etc. Returns 0 (true) if in scope.
is_shell_script() {
  local f="$1"
  local base="${f##*/}"

  # Extension rule.
  case "$base" in
    *.sh|*.bash) return 0 ;;
  esac

  # Shebang rule: read only the first line. Match #!/usr/bin/env bash,
  # #!/bin/bash, #!/usr/bin/env sh, etc. Bash ERE has no \b word boundary, so
  # require a non-word char (or string edge) around the shell name; this keeps
  # "zsh"/"ash" out while matching the four POSIX/Bash shells we care about.
  local shebang
  shebang="$(head -n 1 "$f" 2>/dev/null || true)"
  [[ "$shebang" =~ ^#![[:space:]]*/.*[^[:alnum:]_](bash|sh|dash|ksh)([^[:alnum:]_]|$) ]]
}

# Emit the repo-root-relative paths of every script in scope, sorted and
# de-duplicated. Walks only the four roots the plan names (scripts/, lib/,
# tests/, templates/) -- node_modules/ and vendored content are never searched.
discover_scripts() {
  local root
  for root in scripts lib tests templates; do
    [[ -d "$ROOT_DIR/$root" ]] || continue
    while IFS= read -r -d '' f; do
      is_shell_script "$f" || continue
      printf '%s\n' "${f#"$ROOT_DIR/"}"
    done < <(find "$ROOT_DIR/$root" -type f -print0)
  done | sort -u
}

mapfile -t FILES < <(discover_scripts)

if [[ ${#FILES[@]} -eq 0 ]]; then
  fail "shellcheck discovered no scripts (discovery bug?)"
fi

# Missing tool: warn loudly per script + the install link, but stay green.
if ! command -v shellcheck >/dev/null 2>&1; then
  for f in "${FILES[@]}"; do
    printf 'WARN: shellcheck not installed; skipped %s\n' "$f" >&2
  done
  printf 'WARN: install shellcheck to enable static analysis: %s\n' "$SC_URL" >&2
  pass "shellcheck (skipped — tool not installed)"
  exit 0
fi

# Settings source of truth: this driver passes no flag overrides, so a missing
# .shellcheckrc would let shellcheck fall back to its built-in defaults and the
# verdict could silently drift. Fail fast instead.
[[ -f "$ROOT_DIR/.shellcheckrc" ]] \
  || fail "missing $ROOT_DIR/.shellcheckrc -- settings source of truth is gone"

# Installed: any finding fails the suite. Settings (shell dialect, severity,
# external-sources) live in .shellcheckrc at the repo root -- this driver
# invokes `shellcheck <file>` with NO flag overrides, so the rc is the single
# source of truth consumed by both this harness and editor integrations.
# Suppressions live as inline `# shellcheck disable=SCxxxx` directives per site.
failures=0
for f in "${FILES[@]}"; do
  if shellcheck "$ROOT_DIR/$f"; then
    pass "shellcheck $f"
  else
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -gt 0 ]]; then
  fail "shellcheck reported problems in $failures file(s)"
fi
pass "shellcheck (${#FILES[@]} files clean)"
