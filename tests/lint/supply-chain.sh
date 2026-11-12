#!/usr/bin/env bash
# =============================================================================
# tests/lint/supply-chain.sh - M2 build supply-chain regression guard.
#
# Keeps repo-owned Containerfile templates free of remote-script execution and
# ensures the base image is pinned by digest. These are build-time supply-chain
# controls; they do not change runtime behavior.
#
#   - No `curl|bash` (or `wget|bash`) fetch-and-execute patterns in committed
#     Containerfiles. The corpus is every repo-owned Containerfile template:
#     git-tracked sources under Containerfiles/ (so the gitignored
#     `Containerfiles/generated/` build artifacts don't make this flap) plus
#     every `Containerfile.*` under templates/ found on the filesystem — a glob
#     rather than git ls-files so untracked-but-present starters (new pattern
#     dirs) are scanned too. The Containerfile.* name filter keeps README /
#     recipe / dotfile documentation prose out of the corpus, so documentation
#     stays free to reference the discouraged pattern. Comment lines are
#     ignored and backslash continuations are joined first, so multi-line RUN
#     commands are scanned whole.
#   - `Containerfiles/Containerfile.base` FROM line must pin ubuntu:24.04 by a
#     `@sha256:` digest rather than a mutable tag.
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

# Corpus: every repo-owned Containerfile template we control.
#   - Tracked sources under Containerfiles/ keep their existing coverage;
#     gitignored generated/ artifacts are excluded by construction.
#   - Copy-and-modify starters are globbed from the real tree (sorted for a
#     deterministic corpus), so untracked-but-present files (e.g. a pattern dir
#     not yet committed) are scanned too; paths are made repo-relative to match
#     the git ls-files output the offender report prefixes with $ROOT_DIR.
mapfile -t TRACKED_CFS < <(git -C "$ROOT_DIR" ls-files 'Containerfiles/*' | grep -Ei '(^|/)Containerfile\.' || true)

TEMPLATE_CFS=()
if [[ -d "$ROOT_DIR/templates" ]]; then
  while IFS= read -r cf; do
    TEMPLATE_CFS+=("${cf#"$ROOT_DIR/"}")
  done < <(find "$ROOT_DIR/templates" -type f -name 'Containerfile.*' | sort)
fi

CONTAINERFILES=("${TRACKED_CFS[@]}" "${TEMPLATE_CFS[@]}")

[[ ${#CONTAINERFILES[@]} -gt 0 ]] || fail "no Containerfile templates found to scan"

# Collapse backslash line-continuations into single logical lines, then drop
# comment lines. A comment is never executed, so it is not a supply-chain risk;
# joining continuations lets a multi-line RUN be scanned as one unit.
logical_lines() {
  awk '
    {
      buf = buf $0
      if (buf ~ /\\$/) {
        sub(/\\$/, "", buf)
        buf = buf " "
        next
      }
      out = buf; buf = ""
      sub(/^[ \t]+/, "", out)
      if (out != "" && substr(out, 1, 1) != "#") print out
    }
    END {
      if (buf != "") {
        sub(/^[ \t]+/, "", buf)
        if (buf != "" && substr(buf, 1, 1) != "#") print buf
      }
    }
  ' "$1"
}

# --- no remote script execution in committed Containerfiles -------------------
# Match a fetch (curl/wget) piped into a shell interpreter. This is the
# "curl https://... | bash" build-time compromise path.
fetch_exec_re='\b(curl|wget)[[:space:]].*\|[[:space:]]*(bash|sh|zsh)\b'

offenders=()
for cf in "${CONTAINERFILES[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    offenders+=("$ROOT_DIR/$cf: $hit")
  done < <(logical_lines "$ROOT_DIR/$cf" | grep -En "$fetch_exec_re" 2>/dev/null || true)
done

if [[ ${#offenders[@]} -gt 0 ]]; then
  echo "FAIL: remote fetch-and-execute pattern (curl|bash) found in Containerfiles:" >&2
  printf '  %s\n' "${offenders[@]}" >&2
  echo "Remove the remote script execution; install from a distro package or" >&2
  echo "verify a downloaded artifact checksum instead." >&2
  exit 1
fi

pass "no curl|bash remote-script execution in committed Containerfiles"

# --- base image pinned by digest ----------------------------------------------
BASE="$ROOT_DIR/Containerfiles/Containerfile.base"
[[ -f "$BASE" ]] || fail "base Containerfile missing: $BASE"

# First FROM directive (case-insensitive, directive at line start).
from_line="$(grep -Ei '^[[:space:]]*FROM[[:space:]]+' "$BASE" | head -n1 || true)"
[[ -n "$from_line" ]] || fail "no FROM directive found in $BASE"

# Must reference ubuntu:24.04 and pin it with a @sha256: digest.
if [[ "$from_line" != *ubuntu:24.04* ]]; then
  fail "base FROM must use ubuntu:24.04 (got: $from_line)"
fi
if [[ "$from_line" != *@sha256:* ]]; then
  fail "base FROM must pin ubuntu:24.04 by @sha256: digest (got: $from_line). Mutable tags are a build-time supply-chain risk."
fi

pass "base image pinned by digest"

echo ""
echo "All M2 supply-chain checks passed."
