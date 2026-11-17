#!/usr/bin/env bash
# =============================================================================
# tests/contract/chained-build.sh - backend_build_image_chained, the build
# counterpart of compose-containerfile.sh's apple transport chaining (issue
# #735): when the apple-mode composed file exceeds apple/container's effective
# Dockerfile cap, compose writes chained part files <file>.p0 .. <file>.pN
# (p0 FROM dce-base:latest, pk FROM dce-stage-<hash>-<k-1>:latest). The builder
# must then:
#   - apple + parts: build p0..pN sequentially with the NATIVE apple builder,
#     part k tagged dce-stage-<hash>-<k>:latest, the FINAL part tagged <tag>
#     and the only one receiving extra build-args (non-final parts declare no
#     ARGs); the canonical file itself is never built natively.
#   - a part that is environment/transport-blocked in apple's native builder
#     CANNOT be continued on a peer mid-chain: part k chains FROM the previous
#     stage tag, which exists only in apple's store when parts 0..k-1 built
#     natively (the peer store has no such image). The FIRST blocked part
#     therefore RESTARTS the whole chain on the peer FROM PART 0: parts
#     0..N-2 build directly on the peer CLI under their stage tags, and the
#     final part goes through the peer build -> save -> `container image load`
#     path (with build-args), landing <tag> in apple/container's store.
#   - no reachable peer, or a REAL (unclassified) native build error, aborts
#     the chain with no peer builds (real errors are never masked).
#   - docker-family/podman + parts: exactly one build of the canonical file
#     (those builders have no cap; parts are never touched, gaps included).
#   - no .p0: plain passthrough, indistinguishable from backend_build_image.
#   - a gap in the part sequence (e.g. .p0 then .p2, or .p0 next to a stray
#     .p08 whose zero-padded index would misparse as octal) dies naming the
#     missing part, before building anything.
#   - parts present but the basename not matching Containerfile.<hash> dies
#     (the stage tags embed the hash -- same contract compose enforces).
# Stub-driven (fake container/docker/podman CLIs that log argv).
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

# One stub installed as `container`, `docker`, and `podman`. Every call is
# logged; the apple native `container build` failure shape is selectable:
#   DC_STUB_FAIL_NATIVE      : every native build dies transport-class
#   DC_STUB_FAIL_NATIVE_FROM : dies transport-class when the --file value ends
#                              with this suffix (per-part selection)
#   DC_STUB_REAL_ERROR_FROM  : dies with an UNCLASSIFIED real error when the
#                              --file value ends with this suffix (must abort,
#                              never fall back)
# DC_STUB_DOCKER_DOWN=1 makes `docker info` fail so the podman peer is picked.
cat > "$STUB_DIR/_cb_stub" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"
case "$me" in
  container)
    case "${1:-}" in
      build)
        # Capture which file this build is for (argv: build --tag T --file F ctx).
        f=""
        while [[ $# -gt 0 ]]; do
          [[ "$1" == --file ]] && f="${2:-}"
          shift
        done
        native_fail=0
        [[ -n "${DC_STUB_FAIL_NATIVE:-}" ]] && native_fail=1
        if [[ -n "${DC_STUB_FAIL_NATIVE_FROM:-}" && "$f" == *"$DC_STUB_FAIL_NATIVE_FROM" ]]; then
          native_fail=1
        fi
        if (( native_fail )); then
          printf 'probing "alpine:3"\nError: unavailable (14): Transport became inactive\n'
          exit 1
        fi
        if [[ -n "${DC_STUB_REAL_ERROR_FROM:-}" && "$f" == *"$DC_STUB_REAL_ERROR_FROM" ]]; then
          printf "Containerfile:3:4: RUN must be uppercase\nError: failed to solve\n"
          exit 1
        fi
        exit 0
        ;;
      image)
        case "${2:-}" in
          load) exit 0 ;;                                # peer OCI load succeeds
          ls)   printf '%s\n' "${DC_STUB_IMAGE_LS:-}" ;; # backend_image_exists
        esac
        ;;
    esac
    ;;
  docker)
    case "${1:-}" in
      info)
        [[ -n "${DC_STUB_DOCKER_DOWN:-}" ]] && exit 1    # force the podman peer
        exit 0 ;;                                        # peer engine reachable
      context)
        [[ "${2:-}" == "show" ]] && printf 'colima\n'    # backend_cli colima re-check
        ;;
      build) exit 0 ;;                                   # docker build succeeds
      save)
        while [[ $# -gt 0 ]]; do
          [[ "$1" == -o && -n "${2:-}" ]] && { touch "$2"; shift 2; continue; }
          shift
        done
        exit 0
        ;;
    esac
    ;;
  podman)
    case "${1:-}" in
      info)
        [[ -n "${DC_STUB_PODMAN_DOWN:-}" ]] && exit 1    # no peer at all
        exit 0 ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_cb_stub"
cp "$STUB_DIR/_cb_stub" "$STUB_DIR/container"
cp "$STUB_DIR/_cb_stub" "$STUB_DIR/docker"
cp "$STUB_DIR/_cb_stub" "$STUB_DIR/podman"
export PATH="$STUB_DIR:$PATH"

GEN="$WORK/generated"
mkdir -p "$GEN"
HASH="abcdef0123456789"
CANON="$GEN/Containerfile.$HASH"
TAG="dce-img-$HASH:latest"
printf 'FROM dce-base:latest\n' > "$CANON"

reset_log() { : > "$LOG"; }
build_calls() { grep -E '^CALL (container|docker) build ' "$LOG" || true; }

# ---------------------------------------------------------------------------
# Case 1: apple + parts -> sequential chained builds with stage tags; only the
# final part gets <tag> + build-args; the canonical file is never built.
# ---------------------------------------------------------------------------
printf 'FROM dce-base:latest\nRUN true\n' > "$CANON.p0"
printf 'FROM dce-stage-%s-0:latest\nRUN true\n' "$HASH" > "$CANON.p1"

# shellcheck disable=SC2034  # read by backend_name(), not exported
DEV_CONTAINERS_BACKEND=apple
_DC_CLI=container
reset_log
if ! out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" \
      --build-arg DC_BASE_ID=bid --build-arg DC_BUILT_UTC=bts 2>&1)"; then
  fail "apple chained: should succeed; got:
$out"
fi

want="$(printf 'CALL container build --tag dce-stage-%s-0:latest --file %s.p0 %s\nCALL container build --tag %s --file %s.p1 --build-arg DC_BASE_ID=bid --build-arg DC_BUILT_UTC=bts %s\n' "$HASH" "$CANON" "$ROOT_DIR" "$TAG" "$CANON" "$ROOT_DIR")"
got="$(build_calls)"
[[ "$got" == "$want" ]] \
  || fail "apple chained: build sequence must be p0 (stage tag, no args) then p1 (caller tag + build-args), canonical file never built
-- expected:
$want
-- got:
$got"
[[ "$out" == *"chained part 1/2 -> dce-stage-$HASH-0:latest"* \
   && "$out" == *"chained part 2/2 -> $TAG"* ]] \
  || fail "apple chained: per-part progress lines expected; got:
$out"
pass "apple chained: p0..pN in order with stage tags; final gets tag+args; canonical never built"

# ---------------------------------------------------------------------------
# Case 2: every part transport-blocked natively -> the WHOLE chain restarts on
# the docker peer from part 0. Only p0 gets a native attempt: it is blocked
# FIRST, so the restart begins there and the final part never runs natively --
# p0 is rebuilt under its stage tag directly on the peer CLI (no build-args),
# the final part via the peer build -> save -> `container image load` path
# (with build-args), and <tag> lands in apple's store via the final guard. A
# per-part fallback would dead-end here: p1 chains FROM a stage tag that
# exists only in apple's store, invisible to the peer builder.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_FAIL_NATIVE=1
# The peer path's final guard (backend_image_exists) must see the caller tag.
DC_STUB_IMAGE_LS="$(printf '%s\ndce-stage-%s-0:latest\n' "$TAG" "$HASH")"
export DC_STUB_IMAGE_LS
if ! out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" \
      --build-arg DC_BASE_ID=bid --build-arg DC_BUILT_UTC=bts 2>&1)"; then
  fail "all-blocked chain: should succeed via full peer restart from part 0; got:
$out"
fi
unset DC_STUB_FAIL_NATIVE DC_STUB_IMAGE_LS
want="$(printf 'CALL container build --tag dce-stage-%s-0:latest --file %s.p0 %s\nCALL docker build --tag dce-stage-%s-0:latest --file %s.p0 %s\nCALL docker build --tag %s --file %s.p1 --build-arg DC_BASE_ID=bid --build-arg DC_BUILT_UTC=bts %s\n' \
  "$HASH" "$CANON" "$ROOT_DIR" \
  "$HASH" "$CANON" "$ROOT_DIR" \
  "$TAG" "$CANON" "$ROOT_DIR")"
got="$(build_calls)"
[[ "$got" == "$want" ]] \
  || fail "all-blocked chain: must attempt p0 natively, then restart the whole chain on docker from part 0 (stage tag, then final tag + build-args via peer)
-- expected:
$want
-- got:
$got"
grep -q '^CALL docker save' "$LOG" \
  || fail "all-blocked chain: final part must be exported from the peer (docker save)
$(cat "$LOG")"
grep -q '^CALL container image load' "$LOG" \
  || fail "all-blocked chain: final image must be loaded into apple/container
$(cat "$LOG")"
[[ "$out" == *"Restarting the whole chain"* ]] \
  || fail "all-blocked chain: the peer-restart warning must appear; got:
$out"
pass "all-blocked chain: full peer restart from part 0; final tag lands in apple store via load"

# ---------------------------------------------------------------------------
# Case 2b: mixed chain -- p0 builds natively, only p1 is transport-blocked.
# The stage tag p1 chains FROM lives only in apple's store, so the chain must
# still restart on the peer FROM PART 0 (p0 rebuilt under its stage tag on
# docker, without build-args), then the final part via peer build+load WITH
# build-args; the function succeeds and the restart warning appears.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_FAIL_NATIVE_FROM=.p1
DC_STUB_IMAGE_LS="$(printf '%s\ndce-stage-%s-0:latest\n' "$TAG" "$HASH")"
export DC_STUB_IMAGE_LS
if ! out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" \
      --build-arg DC_BASE_ID=bid --build-arg DC_BUILT_UTC=bts 2>&1)"; then
  fail "mixed chain: should succeed via peer restart from part 0; got:
$out"
fi
unset DC_STUB_FAIL_NATIVE_FROM DC_STUB_IMAGE_LS
want="$(printf 'CALL container build --tag dce-stage-%s-0:latest --file %s.p0 %s\nCALL container build --tag %s --file %s.p1 --build-arg DC_BASE_ID=bid --build-arg DC_BUILT_UTC=bts %s\nCALL docker build --tag dce-stage-%s-0:latest --file %s.p0 %s\nCALL docker build --tag %s --file %s.p1 --build-arg DC_BASE_ID=bid --build-arg DC_BUILT_UTC=bts %s\n' \
  "$HASH" "$CANON" "$ROOT_DIR" "$TAG" "$CANON" "$ROOT_DIR" \
  "$HASH" "$CANON" "$ROOT_DIR" "$TAG" "$CANON" "$ROOT_DIR")"
got="$(build_calls)"
[[ "$got" == "$want" ]] \
  || fail "mixed chain: p1's native block must restart the chain on docker from part 0 (p0 rebuilt under its stage tag, final part with build-args via peer)
-- expected:
$want
-- got:
$got"
grep -q '^CALL docker save' "$LOG" \
  || fail "mixed chain: final part must be exported from the peer (docker save)
$(cat "$LOG")"
grep -q '^CALL container image load' "$LOG" \
  || fail "mixed chain: final image must be loaded into apple/container
$(cat "$LOG")"
[[ "$out" == *"Restarting the whole chain"* ]] \
  || fail "mixed chain: the peer-restart warning must appear; got:
$out"
pass "mixed chain: p0 native success + p1 blocked -> peer restarts from part 0; final tag lands in apple store"

# ---------------------------------------------------------------------------
# Case 2c: podman peer -- with docker down, the restart uses podman: the non-
# final parts build with `podman build --format oci` under their stage tags,
# the final part via the podman peer path (oci-archive save -> `container
# image load` -> localhost/ re-tag), and the chain completes.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_FAIL_NATIVE=1 DC_STUB_DOCKER_DOWN=1
DC_STUB_IMAGE_LS="$(printf '%s\nlocalhost/%s\ndce-stage-%s-0:latest\n' "$TAG" "$TAG" "$HASH")"
export DC_STUB_IMAGE_LS
if ! out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" 2>&1)"; then
  fail "podman-peer chain: should succeed via podman restart from part 0; got:
$out"
fi
unset DC_STUB_FAIL_NATIVE DC_STUB_DOCKER_DOWN DC_STUB_IMAGE_LS
if grep -Eq '^CALL docker (build|save) ' "$LOG"; then
  fail "podman-peer chain: docker was forced down, no docker builds allowed
$(cat "$LOG")"
fi
grep -q "^CALL podman build --format oci --tag dce-stage-$HASH-0:latest --file $CANON.p0 $ROOT_DIR\$" "$LOG" \
  || fail "podman-peer chain: p0 must build on podman under its stage tag (--format oci)
$(cat "$LOG")"
grep -q "^CALL podman build --format oci --tag $TAG --file $CANON.p1 $ROOT_DIR\$" "$LOG" \
  || fail "podman-peer chain: the final part must build on podman under the caller tag
$(cat "$LOG")"
grep -q "^CALL podman save --format oci-archive -o .* $TAG\$" "$LOG" \
  || fail "podman-peer chain: the final image must be exported (podman save oci-archive)
$(cat "$LOG")"
grep -q '^CALL container image load' "$LOG" \
  || fail "podman-peer chain: the final image must be loaded into apple/container
$(cat "$LOG")"
grep -q "^CALL container image tag localhost/$TAG $TAG\$" "$LOG" \
  || fail "podman-peer chain: the loaded localhost/-prefixed image must be re-tagged
$(cat "$LOG")"
[[ "$out" == *"Restarting the whole chain"* ]] \
  || fail "podman-peer chain: the peer-restart warning must appear; got:
$out"
pass "podman-peer chain: full restart on podman from part 0; final tag re-tagged into apple store"

# ---------------------------------------------------------------------------
# Case 2c': no reachable peer at all -> the blocked chain cannot proceed: the
# class-specific no-peer warning appears (naming that the CHAIN cannot
# proceed), the function fails, and nothing is built on any peer.
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_FAIL_NATIVE=1 DC_STUB_DOCKER_DOWN=1 DC_STUB_PODMAN_DOWN=1
if out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" 2>&1)"; then
  fail "no-peer chain: must abort when no peer is reachable; got success:
$out"
fi
unset DC_STUB_FAIL_NATIVE DC_STUB_DOCKER_DOWN DC_STUB_PODMAN_DOWN
[[ "$out" == *"The chained build cannot proceed"* ]] \
  || fail "no-peer chain: warning must say the chained build cannot proceed; got:
$out"
if grep -Eq '^CALL (docker|podman) (build|save) ' "$LOG"; then
  fail "no-peer chain: nothing may build on a peer
$(cat "$LOG")"
fi
pass "no-peer chain: blocked part aborts the chain with the cannot-proceed warning"

# ---------------------------------------------------------------------------
# Case 2d: a REAL (unclassified) native error mid-chain aborts the chain --
# no peer restart, no peer builds, non-zero propagation (a genuine
# Containerfile error would fail on the peer identically, never mask it).
# ---------------------------------------------------------------------------
reset_log
export DC_STUB_REAL_ERROR_FROM=.p1
if out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" 2>&1)"; then
  fail "real-error chain: must abort, not succeed:
$out"
fi
unset DC_STUB_REAL_ERROR_FROM
if grep -Eq '^CALL (docker|podman) ' "$LOG"; then
  fail "real-error chain: must never reach a peer
$(cat "$LOG")"
fi
[[ "$out" == *"RUN must be uppercase"* ]] \
  || fail "real-error chain: the streamed real error must surface; got:
$out"
if [[ "$out" == *"Restarting the whole chain"* ]]; then
  fail "real-error chain: must not announce a peer restart; got:
$out"
fi
pass "real-error chain: mid-chain real error aborts with no peer builds"

rm -f "$CANON.p0" "$CANON.p1"

# ---------------------------------------------------------------------------
# Case 3: docker-family/podman + parts -> exactly one canonical build, parts
# never touched. Pinned across the whole docker family.
# ---------------------------------------------------------------------------
printf 'FROM dce-base:latest\nRUN true\n' > "$CANON.p0"
printf 'FROM dce-stage-%s-0:latest\nRUN true\n' "$HASH" > "$CANON.p1"
for fam in docker orbstack colima podman; do
  DEV_CONTAINERS_BACKEND="$fam"
  # Every docker-family backend drives the `docker` CLI; podman its own.
  case "$fam" in podman) fam_bin="podman" ;; *) fam_bin="docker" ;; esac
  _DC_CLI="$fam_bin"
  reset_log
  if ! out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" \
        --build-arg DC_BASE_ID=bid 2>&1)"; then
    fail "$fam + parts: should build the canonical file once; got:
$out"
  fi
  want="$(printf 'CALL %s build --tag %s --file %s --build-arg DC_BASE_ID=bid %s\n' "$fam_bin" "$TAG" "$CANON" "$ROOT_DIR")"
  got="$(grep -E '^CALL (container|docker|podman) build ' "$LOG" || true)"
  [[ "$got" == "$want" ]] \
    || fail "$fam + parts: must issue exactly one canonical-file build (parts ignored)
-- expected:
$want
-- got:
$got"
  if grep -q '\.p[0-9]' "$LOG"; then
    fail "$fam + parts: parts must never be built
$(cat "$LOG")"
  fi
done
pass "docker-family/podman + parts: single canonical build, parts ignored"

rm -f "$CANON.p0" "$CANON.p1"

# ---------------------------------------------------------------------------
# Case 4: no parts -> indistinguishable passthrough of backend_build_image.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # read by backend_name(), not exported
DEV_CONTAINERS_BACKEND=apple
_DC_CLI=container
reset_log
backend_build_image "$TAG" "$CANON" "$ROOT_DIR" --build-arg DC_BASE_ID=bid >/dev/null 2>&1
plain="$(build_calls)"
reset_log
if ! out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" \
      --build-arg DC_BASE_ID=bid 2>&1)"; then
  fail "no parts: passthrough should succeed; got:
$out"
fi
chained="$(build_calls)"
[[ -n "$plain" && "$plain" == "$chained" ]] \
  || fail "no parts: chained build must be byte-identical to backend_build_image
-- plain:
$plain
-- chained:
$chained"
case "$out" in
  *"chained part"*) fail "no parts: must not log chained-part progress lines; got:
$out" ;;
esac
pass "no parts: single build via passthrough, identical argv to backend_build_image"

# ---------------------------------------------------------------------------
# Case 5: gap in the part sequence -> dies naming the missing part, building
# nothing (stale/pruned mid-sequence corruption guard).
# ---------------------------------------------------------------------------
printf 'FROM dce-base:latest\nRUN true\n' > "$CANON.p0"
printf 'FROM dce-stage-%s-1:latest\nRUN true\n' "$HASH" > "$CANON.p2"
reset_log
if out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" 2>&1)"; then
  fail "gap: must die on a broken part sequence; got success:
$out"
fi
[[ "$out" == *"$CANON.p1"* ]] \
  || fail "gap: error must name the missing part file; got:
$out"
[[ -z "$(build_calls)" ]] \
  || fail "gap: must die before building anything
$(cat "$LOG")"
rm -f "$CANON.p0" "$CANON.p2"
pass "gap: dies naming the missing part before any build"

# ---------------------------------------------------------------------------
# Case 5b: a stray zero-padded part (.p08) next to .p0 must die in the same
# gap guard. 08 parses as INVALID OCTAL in bare bash arithmetic, so the index
# compare needs forced base-10 (10#); otherwise the stray escapes the check
# and a truncated image can build silently.
# ---------------------------------------------------------------------------
printf 'FROM dce-base:latest\nRUN true\n' > "$CANON.p0"
printf 'FROM dce-base:latest\nRUN true\n' > "$CANON.p08"
reset_log
if out="$(backend_build_image_chained "$TAG" "$CANON" "$ROOT_DIR" 2>&1)"; then
  fail "stray .p08: must die in the gap guard (08 must not misparse as octal and escape); got success:
$out"
fi
[[ "$out" == *"$CANON.p1' is missing but later parts exist"* ]] \
  || fail "stray .p08: error must name the missing part file ('...p1' is missing...); got:
$out"
[[ "$out" == *"$CANON.p08"* ]] \
  || fail "stray .p08: error must cite the stray part that triggered the guard; got:
$out"
[[ -z "$(build_calls)" ]] \
  || fail "stray .p08: must die before building anything
$(cat "$LOG")"
rm -f "$CANON.p0" "$CANON.p08"
pass "stray padded part (.p08): dies in the gap guard naming the missing .p1, zero builds"

# ---------------------------------------------------------------------------
# Case 6: parts present but the basename lacks the <hash> -> dies (the stage
# tags embed the hash; same Containerfile.<hash> contract compose enforces).
# ---------------------------------------------------------------------------
NOHASH="$GEN/Containerfile"
printf 'FROM dce-base:latest\nRUN true\n' > "$NOHASH"
printf 'FROM dce-base:latest\nRUN true\n' > "$NOHASH.p0"
reset_log
if out="$(backend_build_image_chained "$TAG" "$NOHASH" "$ROOT_DIR" 2>&1)"; then
  fail "no-hash basename: must die when parts exist; got success:
$out"
fi
[[ "$out" == *"Containerfile.<hash>"* ]] \
  || fail "no-hash basename: error must state the Containerfile.<hash> contract; got:
$out"
[[ -z "$(build_calls)" ]] \
  || fail "no-hash basename: must die before building anything
$(cat "$LOG")"
rm -f "$NOHASH" "$NOHASH.p0"
pass "no-hash basename with parts: dies stating the Containerfile.<hash> contract"

echo ""
echo "All chained-build checks passed."
