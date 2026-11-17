#!/usr/bin/env bash
# =============================================================================
# tests/contract/backend-podman.sh - Conformance contract for lib/backends/podman.sh
# sourced WITHOUT the facade (plans/cleanup-plan.md §4/§8: every backend module
# must validate standalone).
#
# Step 1 (structural): the main test shell sources ONLY lib/common.sh and
# lib/backends/podman.sh -- NEVER lib/container-backend.sh -- and pins the
# module's exported surface (function names, include-guard no-op, exit 0).
#
# Step 2 (behavior): podman.sh is a single capability probe whose result is
# cached in _DC_PODMAN_HOST_GATEWAY_SUPPORTED -- a facade-owned global (the
# facade's globals block declares it; this test seeds it exactly the same way).
# _DC_PODMAN_HOST_GATEWAY_WARNED is WRITTEN by the facade's backend_create
# (one-time fallback warning); the module never reads it, so what is pinned
# here is the contract the warn-once path keys on: a cached answer (either
# polarity) is final and NEVER re-probes `podman create --help`. A stub
# `podman` on a private PATH logs `CALL <argv>` and answers from fixture env.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/backends/podman.sh"

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

# Stub `podman`: answers `create --help` from $DC_STUB_PODMAN_CREATE_HELP.
cat > "$STUB_DIR/podman" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
printf 'CALL %s %s\n' "${0##*/}" "$*" >> "$_log"
if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
  printf '%s\n' "${DC_STUB_PODMAN_CREATE_HELP:-}"
fi
exit 0
STUB
chmod +x "$STUB_DIR/podman"
export PATH="$STUB_DIR:$PATH"

# Fixture variables must cross into the stub as child-process env.
export DC_STUB_PODMAN_CREATE_HELP

call_count() { grep -c '^CALL ' "$LOG" || true; }

# ---------------------------------------------------------------------------
# Step 1: standalone-module guarantee (plans/cleanup-plan.md §8).
# ---------------------------------------------------------------------------
PODMAN_FNS=(_backend_podman_supports_host_gateway)

for fn in "${PODMAN_FNS[@]}"; do
  declare -F "$fn" >/dev/null \
    || fail "podman: standalone source did not define $fn"
done
pass "podman: sources standalone (common.sh only, no facade); module function defined"

if ! bash -c '
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$1/lib/common.sh"
  # shellcheck source=/dev/null
  source "$1/lib/backends/podman.sh"
  [[ -n "${_DC_BACKENDS_PODMAN_SH_LOADED:-}" ]] || exit 2
  _backend_podman_supports_host_gateway() { echo MARKER; }
  # shellcheck source=/dev/null
  source "$1/lib/backends/podman.sh"
  [[ "$(_backend_podman_supports_host_gateway 2>/dev/null)" == "MARKER" ]] || exit 3
' _ "$ROOT_DIR" >/dev/null 2>&1; then
  fail "podman: standalone source must exit 0 and the include guard must make a re-source a no-op"
fi
pass "podman: include guard makes re-source a no-op (standalone source exits 0)"

# Seed the facade-owned cache global exactly as the facade globals block does.
_DC_PODMAN_HOST_GATEWAY_SUPPORTED=""
_DC_PODMAN_HOST_GATEWAY_WARNED=0

# ---------------------------------------------------------------------------
# Supported outcome: `podman create --help` mentions host-gateway -> probe
# once, cache 1, return 0.
# ---------------------------------------------------------------------------
DC_STUB_PODMAN_CREATE_HELP="      --add-host value   add a host-to-IP mapping (host-gateway is the host)"
_DC_PODMAN_HOST_GATEWAY_SUPPORTED=""
: > "$LOG"
if ! _backend_podman_supports_host_gateway; then
  fail "podman: host-gateway capability must report supported when 'podman create --help' mentions host-gateway"
fi
[[ "$_DC_PODMAN_HOST_GATEWAY_SUPPORTED" == "1" ]] \
  || fail "podman: supported outcome must cache _DC_PODMAN_HOST_GATEWAY_SUPPORTED=1; got '$_DC_PODMAN_HOST_GATEWAY_SUPPORTED'"
if [[ "$(call_count)" -ne 1 ]] || ! grep -Fxq 'CALL podman create --help' "$LOG"; then
  fail "podman: supported outcome must probe exactly once via 'podman create --help'; got:
$(cat "$LOG")"
fi
pass "podman: host-gateway supported via 'podman create --help' probe (cached 1, one CALL)"

# ---------------------------------------------------------------------------
# Unsupported outcome: help text lacks host-gateway -> cache 0, return 1.
# ---------------------------------------------------------------------------
DC_STUB_PODMAN_CREATE_HELP="      --add-host value   add a host-to-IP mapping"
_DC_PODMAN_HOST_GATEWAY_SUPPORTED=""
if _backend_podman_supports_host_gateway; then
  fail "podman: host-gateway capability must report unsupported without host-gateway in the help text"
fi
[[ "$_DC_PODMAN_HOST_GATEWAY_SUPPORTED" == "0" ]] \
  || fail "podman: unsupported outcome must cache _DC_PODMAN_HOST_GATEWAY_SUPPORTED=0; got '$_DC_PODMAN_HOST_GATEWAY_SUPPORTED'"
pass "podman: host-gateway unsupported when the help text lacks host-gateway (cached 0)"

# ---------------------------------------------------------------------------
# Memoization: with a cached answer (either polarity) a repeat call makes NO
# new probe CALL.
# ---------------------------------------------------------------------------
: > "$LOG" # cache is 0 from the unsupported case
if _backend_podman_supports_host_gateway; then
  fail "podman: cached negative must keep reporting unsupported"
fi
[[ -z "$(grep '^CALL ' "$LOG" || true)" ]] \
  || fail "podman: cached negative must not re-probe; got:
$(cat "$LOG")"

_DC_PODMAN_HOST_GATEWAY_SUPPORTED="1"
if ! _backend_podman_supports_host_gateway; then
  fail "podman: cached positive must keep reporting supported"
fi
: > "$LOG"
if ! _backend_podman_supports_host_gateway; then
  fail "podman: cached positive must stay positive"
fi
[[ -z "$(grep '^CALL ' "$LOG" || true)" ]] \
  || fail "podman: cached positive must not re-probe; got:
$(cat "$LOG")"
pass "podman: memoized answer (either polarity) never re-probes 'podman create --help'"

# ---------------------------------------------------------------------------
# Warn-once interface: the facade's one-time warning keys on the cached
# answer. Simulate the post-warning state (_WARNED=1) with a cached negative:
# the answer must stay negative with no new probe (and the flag itself is
# never written by the module).
# ---------------------------------------------------------------------------
_DC_PODMAN_HOST_GATEWAY_SUPPORTED="0"
_DC_PODMAN_HOST_GATEWAY_WARNED=1
: > "$LOG"
if _backend_podman_supports_host_gateway; then
  fail "podman: post-warn cached negative must stay unsupported"
fi
[[ -z "$(grep '^CALL ' "$LOG" || true)" ]] \
  || fail "podman: the warn-once path keys on the cache; a repeat call must not re-probe; got:
$(cat "$LOG")"
[[ "$_DC_PODMAN_HOST_GATEWAY_WARNED" -eq 1 ]] \
  || fail "podman: the module must never write _DC_PODMAN_HOST_GATEWAY_WARNED (facade-owned)"
pass "podman: cached-negative + WARNED=1 answers without probing (warn-once contract)"

echo ""
echo "All backend-podman conformance checks passed."
