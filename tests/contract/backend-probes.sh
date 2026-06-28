#!/usr/bin/env bash
# =============================================================================
# tests/contract/backend-probes.sh - Regression coverage for two backend reachability
# probes that broke against current runtime versions:
#   * _backend_colima_runtime must parse MODERN colima's logrus-formatted
#     `colima status` output (msg="runtime: docker"), not just the legacy
#     `runtime: docker` line.
#   * backend_system_info (apple) must call a subcommand that actually exists
#     on apple/container (`container system status`), not the non-existent
#     `container system info`.
# Uses stub CLIs on a private PATH (same style as tests/contract/backend-dispatch.sh).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/container-backend.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
: > "$LOG"
export DC_STUB_LOG="$LOG"

# One stub script installed under multiple names. `colima status` echoes a
# payload from $DC_STUB_COLIMA_STATUS; `container system status` reports
# running; `container system info` is deliberately UNimplemented (it does not
# exist on real apple/container) so any code that calls it fails loudly.
cat > "$STUB_DIR/_probe_stub" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"
case "$me" in
  colima)
    if [[ "${1:-}" == "status" ]]; then
      # Real `colima status` writes to STDERR; mirror that so the test exercises
      # the capture path, not just the parser.
      printf '%s\n' "${DC_STUB_COLIMA_STATUS:-}" >&2
    fi
    ;;
  container)
    if [[ "${1:-}" == "system" && "${2:-}" == "info" ]]; then
      echo "Error: Unexpected argument 'info'" >&2
      exit 64
    fi
    if [[ "${1:-}" == "system" && "${2:-}" == "status" ]]; then
      printf 'FIELD\tVALUE\nstatus\trunning\n'
      exit 0
    fi
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_probe_stub"
cp "$STUB_DIR/_probe_stub" "$STUB_DIR/colima"
cp "$STUB_DIR/_probe_stub" "$STUB_DIR/container"
export PATH="$STUB_DIR:$PATH"

# ---------------------------------------------------------------------------
# _backend_colima_runtime: modern logrus format, legacy format, non-docker.
# ---------------------------------------------------------------------------
colima_case() {  # <label> <status-payload> <expected-runtime>
  local label="$1" payload="$2" expected="$3" got
  export DC_STUB_COLIMA_STATUS="$payload"
  got="$(_backend_colima_runtime 2>/dev/null || true)"
  [[ "$got" == "$expected" ]] \
    || fail "$label: expected runtime '$expected', got '$got'"
  pass "$label"
}

colima_case "colima runtime (modern logrus, docker)" \
  'time="2026-06-27T20:50:24+03:00" level=info msg="runtime: docker"' \
  "docker"

colima_case "colima runtime (modern logrus, containerd)" \
  'time="2026-06-27T20:50:24+03:00" level=info msg="runtime: containerd"' \
  "containerd"

colima_case "colima runtime (legacy plain line, docker)" \
  'runtime: docker' \
  "docker"

# Empty/missing status -> return non-zero, no output (doctor treats as unknown).
export DC_STUB_COLIMA_STATUS=""
if _backend_colima_runtime >/dev/null 2>&1; then
  fail "colima runtime: empty status should return non-zero"
fi
pass "colima runtime: empty status returns non-zero"

# ---------------------------------------------------------------------------
# backend_system_info (apple): must use `container system status` (rc 0), not
# the non-existent `container system info` (rc 64). Pin backend=apple directly
# so no detection runs; only the apple branch is exercised.
# ---------------------------------------------------------------------------
# Pin backend=apple directly so no detection runs; DEV_CONTAINERS_BACKEND is read
# by the lib's backend_name() (cross-function read -> SC2034 false positive).
# shellcheck disable=SC2034
DEV_CONTAINERS_BACKEND=apple
_DC_CLI=container
: > "$LOG"

if backend_system_info >/dev/null 2>&1; then
  : "apple system_info exited 0"
else
  fail "backend_system_info (apple): should exit 0 via 'container system status'"
fi
# Assert it actually called `system status` and NOT `system info`.
if grep -q '^CALL container system info$' "$LOG"; then
  fail "backend_system_info (apple): must not call 'container system info' (no such subcommand)"
fi
grep -q '^CALL container system status$' "$LOG" \
  || fail "backend_system_info (apple): did not call 'container system status'"
pass "backend_system_info (apple): uses 'container system status' (rc 0)"

echo ""
echo "All backend-probe checks passed."
