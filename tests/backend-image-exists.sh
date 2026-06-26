#!/usr/bin/env bash
# =============================================================================
# tests/backend-image-exists.sh - Reproduce and guard the backend_image_exists
# false-negative under `set -o pipefail`.
#
# backend_image_exists uses a `<list> | grep -Fxq "$tag"` pipeline. Under
# pipefail, when the image list is large and the match is not the last entry,
# grep's -q early-exit closes the read end of the pipe; the lister's next write
# then takes SIGPIPE and dies non-zero (141), and pipefail makes the whole
# pipeline return non-zero -- a FALSE NEGATIVE for an image that DOES exist.
#
# Workstream 1, Phase A: reproduce the bug. Section 1 characterizes the unsafe
# pattern directly; Section 2 drives the real backend_image_exists and must
# report a present image as present (RED before the fix, GREEN after).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# A lister that prints the target on line 1, then a large flood. As an external
# awk process it dies on SIGPIPE once the reader exits early. `exit $?` forwards
# awk's SIGPIPE death (141) so the false-negative is observable upstream.
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then
  awk 'BEGIN { print "target:latest"; for (i = 1; i <= 100000; i++) print "x" }'
  exit $?
fi
if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then printf 'default\n'; exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/docker"

# ===========================================================================
# Section 1: the naive `<list> | grep -Fxq` pattern is unsafe under pipefail.
# Characterization -- always passes once reproduced; documents WHY
# backend_image_exists must not rely on an early-exit reader over a producer.
# ===========================================================================
unsafe_image_exists() {
  local tag="$1"
  "$STUB_DIR/docker" image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Fxq "$tag"
}

set +e
unsafe_image_exists "target:latest"; naive_rc=$?
set -e
[[ "$naive_rc" -ne 0 ]] \
  || fail "naive pattern should false-negative under pipefail (rc=$naive_rc); flood too small?"
pass "reproduced: naive <list> | grep -Fxq false-negatives an existing image under pipefail (rc=$naive_rc)"

# ===========================================================================
# Section 2: backend_image_exists must return success for a present image.
# RED before the Workstream 1 fix; GREEN after.
# ===========================================================================
set +e
DEV_CONTAINERS_BACKEND=docker _DC_CLI=docker PATH="$STUB_DIR:$PATH" \
  backend_image_exists "target:latest"; brc=$?
set -e
[[ "$brc" -eq 0 ]] \
  || fail "backend_image_exists should report 'target:latest' as present (rc=$brc)"
pass "backend_image_exists: reports a present image correctly under pipefail (rc=$brc)"

echo ""
echo "All backend_image_exists checks passed."
