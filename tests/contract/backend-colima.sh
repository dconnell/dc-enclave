#!/usr/bin/env bash
# =============================================================================
# tests/contract/backend-colima.sh - Conformance contract for lib/backends/colima.sh
# sourced WITHOUT the facade (plans/cleanup-plan.md §4/§8: every backend module
# must validate standalone).
#
# Step 1 (structural): the main test shell sources ONLY lib/common.sh and
# lib/backends/colima.sh -- NEVER lib/container-backend.sh -- and pins the
# module's exported surface (function names, include-guard no-op, exit 0).
#
# Step 2 (behavior): colima.sh calls registry.sh's shared capture probes
# (_backend_docker_context_name / _backend_docker_context_host) from its
# context matcher and guard rails, so registry.sh is sourced as the one sibling
# module for the behavior step; nothing else is needed (no facade). Stub
# docker/colima CLIs on a private PATH log `CALL <argv>`; expectations mirror
# tests/contract/backend-probes.sh and tests/contract/backend-dispatch.sh so
# the suites agree.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/backends/colima.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

LOG="$WORK/calls.log"
: > "$LOG"
export DC_STUB_LOG="$LOG"

STUB_DIR="$WORK/bin"
BIN_BASE="$WORK/bin-base"          # bash+grep only: hermetic "CLI absent" PATH
mkdir -p "$STUB_DIR" "$BIN_BASE"
ln -s "$(command -v bash)" "$BIN_BASE/bash"
ln -s "$(command -v grep)" "$BIN_BASE/grep"

# Stub CLIs: `docker` answers the context probes from fixture env vars;
# `colima status` echoes its payload to STDERR (real colima writes status
# output there -- same shape tests/contract/backend-probes.sh exercises).
cat > "$STUB_DIR/_colima_stub" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
me="${0##*/}"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"
case "$me" in
  docker)
    case "${1:-}/${2:-}" in
      context/show) printf '%s\n' "${DC_STUB_DOCKER_CONTEXT_SHOW:-}" ;;
      context/inspect) printf '%s\n' "${DC_STUB_DOCKER_CONTEXT_INSPECT:-}" ;;
      context/ls) printf '%s\n' "${DC_STUB_DOCKER_CONTEXT_LS:-}" ;;
    esac
    ;;
  colima)
    if [[ "${1:-}" == "status" ]]; then
      printf '%s\n' "${DC_STUB_COLIMA_STATUS:-}" >&2
    fi
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_colima_stub"
cp "$STUB_DIR/_colima_stub" "$STUB_DIR/docker"
cp "$STUB_DIR/_colima_stub" "$STUB_DIR/colima"
export PATH="$STUB_DIR:$PATH"

# Fixture variables must cross into the stub as child-process env, so export
# them up front; the individual cases only assign values from here on.
export DC_STUB_DOCKER_CONTEXT_SHOW DC_STUB_DOCKER_CONTEXT_INSPECT DC_STUB_DOCKER_CONTEXT_LS
export DC_STUB_COLIMA_STATUS

call_count() { grep -c '^CALL ' "$LOG" || true; }

# ---------------------------------------------------------------------------
# Step 1: standalone-module guarantee (plans/cleanup-plan.md §8).
# ---------------------------------------------------------------------------
COLIMA_FNS=(_backend_colima_cli_available _backend_context_is_colima \
  _backend_colima_context_active _backend_use_colima_context \
  _backend_colima_runtime _backend_require_colima_context \
  _backend_require_colima_docker_runtime)

for fn in "${COLIMA_FNS[@]}"; do
  declare -F "$fn" >/dev/null \
    || fail "colima: standalone source did not define $fn"
done
pass "colima: sources standalone (common.sh only, no facade); all 7 module functions defined"

if ! bash -c '
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$1/lib/common.sh"
  # shellcheck source=/dev/null
  source "$1/lib/backends/colima.sh"
  [[ -n "${_DC_BACKENDS_COLIMA_SH_LOADED:-}" ]] || exit 2
  _backend_context_is_colima() { echo MARKER; }
  # shellcheck source=/dev/null
  source "$1/lib/backends/colima.sh"
  [[ "$(_backend_context_is_colima x)" == "MARKER" ]] || exit 3
' _ "$ROOT_DIR" >/dev/null 2>&1; then
  fail "colima: standalone source must exit 0 and the include guard must make a re-source a no-op"
fi
pass "colima: include guard makes re-source a no-op (standalone source exits 0)"

# ---------------------------------------------------------------------------
# Step 2 setup: source the one sibling module colima.sh truly needs --
# registry.sh's _backend_docker_context_name/_backend_docker_context_host
# shared capture probes, which the context matcher and guard rails resolve at
# invocation time (still no facade).
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/backends/registry.sh"

# ---------------------------------------------------------------------------
# _backend_colima_cli_available: colima CLI on PATH or not.
# ---------------------------------------------------------------------------
if ! _backend_colima_cli_available >/dev/null 2>&1; then
  fail "colima: cli_available must find the stubbed colima CLI"
fi
if ( PATH="$BIN_BASE" _backend_colima_cli_available ) >/dev/null 2>&1; then
  fail "colima: cli_available must fail without a colima CLI"
fi
pass "colima: _backend_colima_cli_available presence/absence"

# ---------------------------------------------------------------------------
# _backend_context_is_colima matcher matrix: name match (case-insensitive
# substring), host-URL socket path, negatives; empty context must NOT probe.
# ---------------------------------------------------------------------------
match_case() { # <label> <context> <expected-rc>
  local label="$1" ctx="$2" expected="$3" got=0
  _backend_context_is_colima "$ctx" || got=1
  [[ "$got" == "$expected" ]] \
    || fail "colima: context matcher [$label]: rc=$got, expected $expected"
}

match_case "name-exact" "colima" 0
match_case "name-substring-mixed-case" "My-Colima-Dev" 0

DC_STUB_DOCKER_CONTEXT_INSPECT="unix:///Users/dev/.colima/default/docker.sock"
match_case "host-socket-path" "default" 0

DC_STUB_DOCKER_CONTEXT_INSPECT="unix:///run/colima/docker.sock"
match_case "host-colima-token" "default" 0

DC_STUB_DOCKER_CONTEXT_INSPECT="unix:///var/run/docker.sock"
match_case "negative-plain-host" "default" 1

DC_STUB_DOCKER_CONTEXT_INSPECT=""
match_case "negative-empty-host" "default" 1
pass "colima: _backend_context_is_colima matcher matrix (name / host-URL / negatives)"

# Host-URL cases resolve via registry.sh's docker context inspect -- argv pinned.
: > "$LOG"
DC_STUB_DOCKER_CONTEXT_INSPECT="unix:///Users/dev/.colima/default/docker.sock"
if ! _backend_context_is_colima "default"; then
  fail "colima: host-socket-path context should match"
fi
grep -Fxq 'CALL docker context inspect default --format {{ (index .Endpoints "docker").Host }}' "$LOG" \
  || fail "colima: host-URL match must resolve via 'docker context inspect <ctx> --format {{ (index .Endpoints \"docker\").Host }}'; got:
$(cat "$LOG")"
pass "colima: host-URL match probes registry's docker context inspect (argv pinned)"

# Empty context: negative, and never probes docker.
: > "$LOG"
match_case "negative-empty-context" "" 1
if [[ -n "$(grep 'context inspect' "$LOG" || true)" ]]; then
  fail "colima: empty context must not probe 'docker context inspect':
$(cat "$LOG")"
fi
pass "colima: empty context is a negative match with no docker context inspect probe"

# ---------------------------------------------------------------------------
# _backend_colima_runtime parsing (mirrors tests/contract/backend-probes.sh):
# modern logrus format, legacy plain line, non-docker, VM-down/empty.
# ---------------------------------------------------------------------------
runtime_case() { # <label> <status-payload> <expected-runtime-or-FAIL>
  local label="$1" payload="$2" expected="$3" got rc=0
  DC_STUB_COLIMA_STATUS="$payload"
  got="$(_backend_colima_runtime 2>/dev/null)" || rc=$?
  if [[ "$expected" == "FAIL" ]]; then
    [[ "$rc" -ne 0 && -z "${got:-}" ]] \
      || fail "colima: runtime [$label]: expected non-zero with no output; got rc=$rc '$got'"
  else
    [[ "$rc" -eq 0 && "$got" == "$expected" ]] \
      || fail "colima: runtime [$label]: expected '$expected', got rc=$rc '$got'"
  fi
}

runtime_case "modern-logrus-docker" \
  'time="2026-06-27T20:50:24+03:00" level=info msg="runtime: docker"' \
  "docker"
runtime_case "modern-logrus-containerd" \
  'time="2026-06-27T20:50:24+03:00" level=info msg="runtime: containerd"' \
  "containerd"
runtime_case "legacy-plain-line" \
  'runtime: docker' \
  "docker"
runtime_case "empty-status-vm-down" \
  "" \
  "FAIL"
pass "colima: _backend_colima_runtime parses modern logrus + legacy formats, fails on empty"

# ---------------------------------------------------------------------------
# _backend_require_colima_docker_runtime: pass paths + exact failure text on a
# non-docker runtime; unknown/empty runtime is tolerated (rc 0).
# ---------------------------------------------------------------------------
DC_STUB_COLIMA_STATUS='time="2026-06-27T20:50:24+03:00" level=info msg="runtime: docker"'
if ! out="$(_backend_require_colima_docker_runtime 2>&1)"; then
  fail "colima: require_docker_runtime must pass on the docker runtime"
fi
[[ -z "$out" ]] \
  || fail "colima: require_docker_runtime pass path must be silent; got:
$out"

DC_STUB_COLIMA_STATUS='time="2026-06-27T20:50:24+03:00" level=info msg="runtime: containerd"'
rc=0
err="$( { _backend_require_colima_docker_runtime >/dev/null; } 2>&1 )" || rc=$?
want=$'ERROR: Colima backend requires Colima runtime \'docker\'.\n  Current Colima runtime: containerd\n  Recreate/start with Docker runtime: colima stop && colima start --runtime docker'
[[ "$rc" -eq 1 ]] \
  || fail "colima: require_docker_runtime must fail (rc 1) on the containerd runtime; got rc=$rc"
[[ "$err" == "$want" ]] \
  || fail "colima: require_docker_runtime failure text drifted
-- expected:
$want
-- got:
$err"

DC_STUB_COLIMA_STATUS=""
if ! _backend_require_colima_docker_runtime >/dev/null 2>&1; then
  fail "colima: require_docker_runtime must tolerate an unknown/empty runtime (rc 0)"
fi
pass "colima: require_colima_docker_runtime pass/unknown paths + byte-exact containerd failure text"

# ---------------------------------------------------------------------------
# _backend_require_colima_context (guard called by registry.sh's backend_cli
# for colima): pass on a Colima context; exact failure text otherwise.
# ---------------------------------------------------------------------------
DC_STUB_DOCKER_CONTEXT_SHOW="colima"
if ! out="$(_backend_require_colima_context 2>&1)"; then
  fail "colima: require_colima_context must pass on an active Colima context"
fi
[[ -z "$out" ]] \
  || fail "colima: require_colima_context pass path must be silent; got:
$out"

DC_STUB_DOCKER_CONTEXT_INSPECT=""
DC_STUB_DOCKER_CONTEXT_SHOW="default"
rc=0
err="$( { _backend_require_colima_context >/dev/null; } 2>&1 )" || rc=$?
want=$'ERROR: Colima backend requires an active Colima Docker context.\n  Current Docker context: default\n  Docker context is managed by Docker CLI configuration.\n  Run: colima start\n  Or: docker context use colima'
[[ "$rc" -eq 1 && "$err" == "$want" ]] \
  || fail "colima: require_colima_context failure text (named context) drifted; rc=$rc
-- expected:
$want
-- got:
$err"

DC_STUB_DOCKER_CONTEXT_SHOW=""
rc=0
err="$( { _backend_require_colima_context >/dev/null; } 2>&1 )" || rc=$?
want=$'ERROR: Colima backend requires an active Colima Docker context.\n  Docker context is managed by Docker CLI configuration.\n  Run: colima start\n  Or: docker context use colima'
[[ "$rc" -eq 1 && "$err" == "$want" ]] \
  || fail "colima: require_colima_context failure text (unnamed context) drifted; rc=$rc
-- expected:
$want
-- got:
$err"
pass "colima: require_colima_context pass path + byte-exact failure text (with/without current-context line)"

# ---------------------------------------------------------------------------
# _backend_use_colima_context: locate a Colima context (case-insensitive) and
# pin/export DOCKER_CONTEXT; exact CALL set; exact failure text when absent.
# ---------------------------------------------------------------------------
DC_STUB_DOCKER_CONTEXT_LS=$'default\norbstack\ncolima'
: > "$LOG"
if ! _backend_use_colima_context; then
  fail "colima: use_colima_context must succeed when a Colima context exists"
fi
if [[ "${DOCKER_CONTEXT:-}" != "colima" ]] \
   || ! bash -c '[[ "${DOCKER_CONTEXT:-}" == "colima" ]]'; then
  fail "colima: use_colima_context must pin+export DOCKER_CONTEXT=colima; got '${DOCKER_CONTEXT:-}'"
fi
got_log="$(grep '^CALL ' "$LOG" || true)"
[[ "$got_log" == "CALL docker context ls --format {{.Name}}" ]] \
  || fail "colima: use_colima_context CALL set drifted (exactly one context ls); got:
$got_log"
pass "colima: use_colima_context pins+exports DOCKER_CONTEXT with exactly one 'docker context ls' CALL"

DC_STUB_DOCKER_CONTEXT_LS=$'default\nMy-Colima'
if ! _backend_use_colima_context >/dev/null 2>&1; then
  fail "colima: use_colima_context must match case-insensitively"
fi
[[ "${DOCKER_CONTEXT:-}" == "My-Colima" ]] \
  || fail "colima: use_colima_context must pin the ORIGINAL context name; got '${DOCKER_CONTEXT:-}'"
pass "colima: use_colima_context picks a mixed-case context, pinning its original name"

DOCKER_CONTEXT="sentinel"
export DOCKER_CONTEXT
DC_STUB_DOCKER_CONTEXT_LS=$'default\norbstack'
rc=0
err="$( { _backend_use_colima_context >/dev/null; } 2>&1 )" || rc=$?
want=$'ERROR: Colima backend requires a Colima Docker context.\n  Run: colima start\n  Or: docker context use colima'
[[ "$rc" -eq 1 && "$err" == "$want" ]] \
  || fail "colima: use_colima_context failure text drifted; rc=$rc
-- expected:
$want
-- got:
$err"
[[ "${DOCKER_CONTEXT:-}" == "sentinel" ]] \
  || fail "colima: use_colima_context failure must leave DOCKER_CONTEXT untouched; got '${DOCKER_CONTEXT:-}'"
pass "colima: use_colima_context byte-exact failure text and untouched DOCKER_CONTEXT when no Colima context exists"

echo ""
echo "All backend-colima conformance checks passed."
