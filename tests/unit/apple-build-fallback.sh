#!/usr/bin/env bash
# =============================================================================
# tests/unit/apple-build-fallback.sh - apple/container's builder runs in a
# vmnet-NAT'd namespace that cannot traverse a host VPN, so every apt/apk RUN
# fails with "Temporary failure resolving" / "no installation candidate". That
# is a build-environment problem (no outbound network), not a Containerfile bug,
# and persists until host networking is fixed -- so a native rebuild can NEVER
# succeed.
#
# backend_build_image (apple) must, on that specific failure class, transparently
# rebuild the image on a reachable docker/podman peer (emitting an OCI archive)
# and load it into apple/container's store under the same tag. Other build
# failures must propagate untouched (never masked by a peer build). Stub-driven.
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

# One stub installed as `container` and `docker`. Every call is logged; the
# `container build` payload is chosen by $DC_STUB_BUILD_MODE to simulate either
# the no-egress failure (default) or a genuine Containerfile error.
cat > "$STUB_DIR/_ab_stub" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"
case "$me" in
  container)
    case "${1:-}" in
      build)
        # Mirror apple/container's environment-blocked failures:
        #   egress : apt cannot resolve (no outbound network)
        #   noctx  : COPY/ADD fails because the builder got an empty context
        #   error  : a genuine Containerfile error (must NOT fall back)
        case "${DC_STUB_BUILD_MODE:-egress}" in
          egress) printf "RUN apt-get update\nTemporary failure resolving 'deb.debian.org'\nE: Package 'ca-certificates' has no installation candidate\n" ;;
          noctx)  printf "COPY rootfs.tar /\nfailed to calculate checksum of ref x::y: \"/rootfs.tar\": not found\nError: failed to solve\n" ;;
          *)      printf "Containerfile:1:1: RUN must be uppercase\nError: failed to solve\n" ;;
        esac
        exit 1
        ;;
      image)
        case "${2:-}" in
          load) exit 0 ;;                       # peer OCI load succeeds
          ls)   printf 'testtag:latest\n' ;;    # backend_image_exists sees the tag
        esac
        ;;
    esac
    ;;
  docker)
    case "${1:-}" in
      info) exit 0 ;;                                       # peer engine reachable
      build)
        # docker buildx --output type=oci,dest=<tar>: materialize the archive.
        for a in "$@"; do [[ "$a" == dest=* ]] && touch "${a#dest=}"; done
        exit 0
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_ab_stub"
cp "$STUB_DIR/_ab_stub" "$STUB_DIR/container"
cp "$STUB_DIR/_ab_stub" "$STUB_DIR/docker"
export PATH="$STUB_DIR:$PATH"

# Pin backend=apple so no detection runs; only the apple build path is exercised.
# shellcheck disable=SC2034  # read by backend_name()
DEV_CONTAINERS_BACKEND=apple
_DC_CLI=container

reset_log() { : > "$LOG"; }
has_call() { grep -q -- "$1" "$LOG"; }

# ---------------------------------------------------------------------------
# Case 1: no-egress failure -> rebuild on docker peer + load into apple. OK.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_BUILD_MODE=egress
if ! out="$(backend_build_image testtag:latest /tmp/cf /ctx 2>&1)"; then
  fail "egress fallback: backend_build_image should succeed via peer build+load; got:
$out"
fi
has_call '^CALL container build' \
  || fail "egress fallback: native apple build must be attempted first"
has_call '^CALL docker build' \
  || fail "egress fallback: did not invoke docker peer build"
has_call 'type=oci,dest=' \
  || fail "egress fallback: peer build must emit an OCI archive (--output type=oci,dest=)"
has_call '^CALL container image load' \
  || fail "egress fallback: did not load the OCI archive into apple/container"
pass "egress fallback: rebuilds on docker peer and loads into apple/container"

# ---------------------------------------------------------------------------
# Case 2: genuine build error (not egress) -> propagate, NO peer fallback.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_BUILD_MODE=error
if backend_build_image testtag:latest /tmp/cf /ctx >/dev/null 2>&1; then
  fail "real build error: backend_build_image must propagate the failure, not mask it"
fi
if has_call '^CALL docker build'; then
  fail "real build error: must NOT fall back to docker peer (would mask real errors)"
fi
pass "real build error: propagated without peer fallback"

# ---------------------------------------------------------------------------
# Case 3: no build-context transfer (snapshot path) -> peer fallback + load.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_BUILD_MODE=noctx
if ! out="$(backend_build_image testtag:latest /tmp/cf /ctx 2>&1)"; then
  fail "no-context fallback: backend_build_image should succeed via peer build+load; got:
$out"
fi
has_call '^CALL docker build' \
  || fail "no-context fallback: did not invoke docker peer build"
has_call '^CALL container image load' \
  || fail "no-context fallback: did not load the OCI archive into apple/container"
pass "no-context fallback: rebuilds on docker peer (covers apple snapshot path)"

echo ""
echo "All apple-build-fallback checks passed."
