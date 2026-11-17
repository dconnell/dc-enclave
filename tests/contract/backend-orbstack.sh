#!/usr/bin/env bash
# =============================================================================
# tests/contract/backend-orbstack.sh - Conformance contract for
# lib/backends/orbstack.sh sourced WITHOUT the facade (plans/cleanup-plan.md
# §4/§8: every backend module must validate standalone).
#
# Step 1 (structural): the main test shell sources ONLY lib/common.sh and
# lib/backends/orbstack.sh -- NEVER lib/container-backend.sh -- and pins the
# module's exported surface (function names, include-guard no-op, exit 0).
#
# Step 2 (behavior): orbstack.sh has NO cross-file lib callees (the matcher is
# a pure string test; the pin shells out to `docker context ls` directly), so
# no sibling module is sourced. A stub `docker` on a private PATH logs
# `CALL <argv>` and answers from fixture env vars; expectations mirror
# tests/contract/backend-dispatch.sh (docker context ls noise shape).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/backends/orbstack.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

LOG="$WORK/calls.log"
: > "$LOG"
export DC_STUB_LOG="$LOG"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# Stub `docker`: answers `context ls --format {{.Name}}` from
# $DC_STUB_DOCKER_CONTEXT_LS; everything else is a logged no-op.
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
printf 'CALL %s %s\n' "${0##*/}" "$*" >> "$_log"
if [[ "${1:-}/${2:-}" == "context/ls" ]]; then
  printf '%s\n' "${DC_STUB_DOCKER_CONTEXT_LS:-}"
fi
exit 0
STUB
chmod +x "$STUB_DIR/docker"
export PATH="$STUB_DIR:$PATH"

# Fixture variables must cross into the stub as child-process env.
export DC_STUB_DOCKER_CONTEXT_LS

call_count() { grep -c '^CALL ' "$LOG" || true; }

# ---------------------------------------------------------------------------
# Step 1: standalone-module guarantee (plans/cleanup-plan.md §8).
# ---------------------------------------------------------------------------
ORBSTACK_FNS=(_backend_context_is_orbstack _backend_use_orbstack_context)

for fn in "${ORBSTACK_FNS[@]}"; do
  declare -F "$fn" >/dev/null \
    || fail "orbstack: standalone source did not define $fn"
done
pass "orbstack: sources standalone (common.sh only, no facade); all 2 module functions defined"

if ! bash -c '
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$1/lib/common.sh"
  # shellcheck source=/dev/null
  source "$1/lib/backends/orbstack.sh"
  [[ -n "${_DC_BACKENDS_ORBSTACK_SH_LOADED:-}" ]] || exit 2
  _backend_context_is_orbstack() { echo MARKER; }
  # shellcheck source=/dev/null
  source "$1/lib/backends/orbstack.sh"
  [[ "$(_backend_context_is_orbstack x)" == "MARKER" ]] || exit 3
' _ "$ROOT_DIR" >/dev/null 2>&1; then
  fail "orbstack: standalone source must exit 0 and the include guard must make a re-source a no-op"
fi
pass "orbstack: include guard makes re-source a no-op (standalone source exits 0)"

# ---------------------------------------------------------------------------
# _backend_context_is_orbstack matcher matrix: case-insensitive SUBSTRING on
# the name only; negatives must not match.
# ---------------------------------------------------------------------------
match_case() { # <label> <context> <expected-rc>
  local label="$1" ctx="$2" expected="$3" got=0
  _backend_context_is_orbstack "$ctx" || got=1
  [[ "$got" == "$expected" ]] \
    || fail "orbstack: context matcher [$label]: rc=$got, expected $expected"
}

match_case "exact-name" "orbstack" 0
match_case "mixed-case" "OrbStack" 0
match_case "substring" "dev-orbstack-ctx" 0
match_case "negative-default" "default" 1
match_case "negative-orb-prefix-only" "orb" 1
match_case "negative-empty" "" 1
pass "orbstack: _backend_context_is_orbstack case-insensitive substring matcher matrix"

# ---------------------------------------------------------------------------
# _backend_use_orbstack_context: locate an OrbStack context and pin+export
# DOCKER_CONTEXT; exactly one `docker context ls` CALL.
# ---------------------------------------------------------------------------
DC_STUB_DOCKER_CONTEXT_LS=$'default\nOrbStack'
: > "$LOG"
unset DOCKER_CONTEXT
if ! _backend_use_orbstack_context; then
  fail "orbstack: use_orbstack_context must succeed when an OrbStack context exists"
fi
if [[ "${DOCKER_CONTEXT:-}" != "OrbStack" ]] \
   || ! bash -c '[[ "${DOCKER_CONTEXT:-}" == "OrbStack" ]]'; then
  fail "orbstack: use_orbstack_context must pin+export DOCKER_CONTEXT with the ORIGINAL name; got '${DOCKER_CONTEXT:-}'"
fi
got_log="$(grep '^CALL ' "$LOG" || true)"
[[ "$got_log" == "CALL docker context ls --format {{.Name}}" ]] \
  || fail "orbstack: use_orbstack_context CALL set drifted (exactly one context ls); got:
$got_log"
pass "orbstack: use_orbstack_context pins+exports DOCKER_CONTEXT with exactly one 'docker context ls' CALL"

# Case-insensitive pick: the matcher scans lowercased lines, the pin keeps the
# context's original case.
DC_STUB_DOCKER_CONTEXT_LS=$'default\nmy-orbstack-context'
if ! _backend_use_orbstack_context >/dev/null 2>&1; then
  fail "orbstack: use_orbstack_context must match case-insensitively"
fi
[[ "${DOCKER_CONTEXT:-}" == "my-orbstack-context" ]] \
  || fail "orbstack: use_orbstack_context must pin the original context name; got '${DOCKER_CONTEXT:-}'"
pass "orbstack: use_orbstack_context picks a lowercase-listed context via case-insensitive scan"

# Failure path: no OrbStack context -> byte-exact guidance, DOCKER_CONTEXT
# untouched.
DOCKER_CONTEXT="sentinel"
export DOCKER_CONTEXT
DC_STUB_DOCKER_CONTEXT_LS="default"
rc=0
err="$( { _backend_use_orbstack_context >/dev/null; } 2>&1 )" || rc=$?
want=$'ERROR: OrbStack backend requires an OrbStack Docker context.\n  Install OrbStack or create a Docker context pointing to it.'
[[ "$rc" -eq 1 && "$err" == "$want" ]] \
  || fail "orbstack: use_orbstack_context failure text drifted; rc=$rc
-- expected:
$want
-- got:
$err"
[[ "${DOCKER_CONTEXT:-}" == "sentinel" ]] \
  || fail "orbstack: use_orbstack_context failure must leave DOCKER_CONTEXT untouched; got '${DOCKER_CONTEXT:-}'"
pass "orbstack: use_orbstack_context byte-exact failure text and untouched DOCKER_CONTEXT when no OrbStack context exists"

echo ""
echo "All backend-orbstack conformance checks passed."
