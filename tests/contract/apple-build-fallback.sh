#!/usr/bin/env bash
# =============================================================================
# tests/contract/apple-build-fallback.sh - apple/container's builder runs in a
# vmnet-NAT'd namespace that cannot traverse a host VPN, so every apt/apk RUN
# fails with "Temporary failure resolving" / "no installation candidate". That
# is a build-environment problem (no outbound network), not a Containerfile bug,
# and persists until host networking is fixed -- so a native rebuild can NEVER
# succeed.
#
# apple/container also ships the Dockerfile to its builder base64-encoded in a
# ~16KB-capped gRPC header (an ~11.5KB effective file cap), so an oversized
# Containerfile kills the transport mid-build ("Transport became inactive" /
# "Stream unexpectedly closed", issue #735). That is likewise an apple-builder
# limitation -- the peer has no size cap -- and must fall back the same way.
#
# backend_build_image (apple) must, on those specific failure classes,
# transparently rebuild the image on a reachable docker/podman peer (exporting
# an image archive) and load it into apple/container's store under the same tag.
# Other build failures must propagate untouched (never masked by a peer build),
# and a failure matching no known class must not inherit a stale class.
# Stub-driven.
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
        #   egress          : apt cannot resolve (no outbound network)
        #   noctx           : COPY/ADD fails because the builder got an empty context
        #   transport14     : gRPC transport death, older CLI wording (issue #735)
        #   transportstream : gRPC transport death, newer CLI wording (issue #735)
        #   other           : an unrecognized failure (no class; must NOT fall back)
        #   error/other-any : a genuine Containerfile error (must NOT fall back)
        case "${DC_STUB_BUILD_MODE:-egress}" in
          egress) printf "RUN apt-get update\nTemporary failure resolving 'deb.debian.org'\nE: Package 'ca-certificates' has no installation candidate\n" ;;
          noctx)  printf "COPY rootfs.tar /\nfailed to calculate checksum of ref x::y: \"/rootfs.tar\": not found\nError: failed to solve\n" ;;
          transport14) printf 'probing "alpine:3"\nError: unavailable (14): Transport became inactive\n' ;;
          transportstream) printf 'probing "alpine:3"\nError: unavailable: "Stream unexpectedly closed."\n' ;;
          other)  printf 'Error: unknown (42): inexplicable builder failure\n' ;;
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
      build) exit 0 ;;                                      # docker build --tag succeeds
      save)
        # docker save -o <tar> <tag>: materialize the exported archive file.
        while [[ $# -gt 0 ]]; do
          [[ "$1" == -o && -n "${2:-}" ]] && { touch "$2"; shift 2; continue; }
          shift
        done
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
has_call '^CALL docker save' \
  || fail "egress fallback: peer build must export the image (docker save)"
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

# ---------------------------------------------------------------------------
# Case 4: gRPC transport death, older CLI wording ("unavailable (14)") ->
# peer fallback + load, with an accurate oversized-Dockerfile warning.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_BUILD_MODE=transport14
if ! out="$(backend_build_image testtag:latest /tmp/cf /ctx 2>&1)"; then
  fail "transport-14 fallback: backend_build_image should succeed via peer build+load; got:
$out"
fi
has_call '^CALL container build' \
  || fail "transport-14 fallback: native apple build must be attempted first"
has_call '^CALL docker build' \
  || fail "transport-14 fallback: did not invoke docker peer build"
has_call '^CALL docker save' \
  || fail "transport-14 fallback: peer build must export the image (docker save)"
has_call '^CALL container image load' \
  || fail "transport-14 fallback: did not load the OCI archive into apple/container"
[[ "$out" == *"gRPC transport"* && "$out" == *"11.5KB"* && "$out" == *735* ]] \
  || fail "transport-14 fallback: warning must name the gRPC transport, the ~11.5KB
cap and issue #735; got:
$out"
pass "transport-14 fallback: peer rebuild on 'Transport became inactive' with cap warning"

# ---------------------------------------------------------------------------
# Case 5: gRPC transport death, newer CLI wording ("Stream unexpectedly
# closed") -> same peer fallback + load + accurate warning.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_BUILD_MODE=transportstream
if ! out="$(backend_build_image testtag:latest /tmp/cf /ctx 2>&1)"; then
  fail "transport-stream fallback: backend_build_image should succeed via peer build+load; got:
$out"
fi
has_call '^CALL docker build' \
  || fail "transport-stream fallback: did not invoke docker peer build"
has_call '^CALL container image load' \
  || fail "transport-stream fallback: did not load the OCI archive into apple/container"
[[ "$out" == *"gRPC transport"* && "$out" == *"11.5KB"* && "$out" == *735* ]] \
  || fail "transport-stream fallback: warning must name the gRPC transport, the ~11.5KB
cap and issue #735; got:
$out"
pass "transport-stream fallback: peer rebuild on 'Stream unexpectedly closed' with cap warning"

# ---------------------------------------------------------------------------
# Case 6: stale-class guard -- an unclassified failure must not inherit the
# transport class from a previous build: the classifier resets the global on
# entry, so no peer fallback and no transport warning happen here.
# ---------------------------------------------------------------------------
reset_log
_DC_APPLE_BLOCK_CLASS=transport   # simulate a stale class left by an earlier build
export DC_STUB_BUILD_MODE=other
# NOTE: backend_build_image runs in a command-substitution subshell, so the
# classifier's global reset is NOT visible back here; behavioral assertions
# (propagation, no fallback, no transport warning) go through its output, and
# the reset itself is asserted by calling the classifier directly afterwards.
if ! out="$(backend_build_image testtag:latest /tmp/cf /ctx 2>&1)"; then :; else
  fail "stale-class guard: unclassified failure must propagate, not succeed:
$out"
fi
if has_call '^CALL docker build'; then
  fail "stale-class guard: must NOT fall back to docker peer on an unclassified log"
fi
if [[ "$out" == *"gRPC transport"* || "$out" == *735* ]]; then
  fail "stale-class guard: must not warn about the transport class; got:
$out"
fi
if _backend_apple_native_build_blocked 'Error: unknown (42): inexplicable builder failure'; then
  fail "stale-class guard: unclassified log must not classify as blocked"
fi
if [[ -n "${_DC_APPLE_BLOCK_CLASS:-}" ]]; then
  fail "stale-class guard: classifier must reset _DC_APPLE_BLOCK_CLASS on no match;
got: '$_DC_APPLE_BLOCK_CLASS'"
fi
pass "stale-class guard: unclassified failure sets no class and never falls back"

echo ""
echo "All apple-build-fallback checks passed."
