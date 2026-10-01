#!/usr/bin/env bash
# =============================================================================
# tests/unit/image-alias.sh - Unit coverage for per-project image-alias naming
# and the backend image-tag wrapper.
#
# Stage 1 of per-project image aliases: canonical derived images stay
# dce-img-<16hex>:latest (scope-set-addressed, shared across projects); each
# project additionally gets a dce-<project>:latest tag on that same image.
#
# Covers:
#   - dce_project_alias_ref   (dce-<project>:latest construction; grammar and
#                              reservation rejections; silent failure)
#   - dce_is_alias_repo_name  (repo-name validation core; canonical/base/
#                              snapshot families must NOT match)
#   - backend_tag_image       (exact per-backend CLI invocation + rc
#                              propagation, via fake-bin PATH stubs)
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

# ---------------------------------------------------------------------------
# dce_project_alias_ref
# ---------------------------------------------------------------------------
# Valid project -> dce-<project>:latest. Names use docker's exact repo-name
# component grammar: lowercase alnum runs separated by single '.'/'_', double
# '__', or one-or-more '-' (the ERE must backtrack, e.g. 'a__b' tries '__' only
# after the single-'_' branch fails). 'a.b_c-d' pins the single-separator case.
[[ "$(dce_project_alias_ref "test" 2>/dev/null)" == "dce-test:latest" ]] \
  || fail "alias_ref: 'test' must yield dce-test:latest (got [$(dce_project_alias_ref "test" 2>/dev/null)])"
[[ "$(dce_project_alias_ref "a.b_c-d" 2>/dev/null)" == "dce-a.b_c-d:latest" ]] \
  || fail "alias_ref: 'a.b_c-d' must yield dce-a.b_c-d:latest (got [$(dce_project_alias_ref "a.b_c-d" 2>/dev/null)])"
for good in a__b my--app; do
  [[ "$(dce_project_alias_ref "$good" 2>/dev/null)" == "dce-$good:latest" ]] \
    || fail "alias_ref: '$good' must yield dce-$good:latest (got [$(dce_project_alias_ref "$good" 2>/dev/null)])"
done

# Rejected names must return non-zero AND be silent (no stdout).
if dce_project_alias_ref "MyApp" >/dev/null 2>&1; then
  fail "alias_ref: uppercase project 'MyApp' must be rejected"
fi
if dce_project_alias_ref "-dash" >/dev/null 2>&1; then
  fail "alias_ref: leading-dash project must be rejected"
fi
# Names outside docker's repo-name grammar must be rejected: docker would
# refuse the tag and (under set -e) abort `dce new` after the build, before
# the config write. Non-aliasable names degrade safely to the canonical ref.
for bad_grammar in my-app- a..b a___b a._b a.-b; do
  if dce_project_alias_ref "$bad_grammar" >/dev/null 2>&1; then
    fail "alias_ref: '$bad_grammar' is not a valid docker repo name and must be rejected"
  fi
done
for reserved in base img-x snap-x snapvol-x; do
  if dce_project_alias_ref "$reserved" >/dev/null 2>&1; then
    fail "alias_ref: reserved project '$reserved' must be rejected"
  fi
done
[[ -z "$(dce_project_alias_ref "MyApp" 2>/dev/null || true)" ]] \
  || fail "alias_ref: rejection must be silent (no stdout)"

pass "dce_project_alias_ref (valid refs, grammar + reservation rejections, silent)"

# ---------------------------------------------------------------------------
# dce_is_alias_repo_name
# ---------------------------------------------------------------------------
# Valid alias repo names: plain, single separators, double '__', repeated '-'.
for good in dce-test dce-a.b_c-d dce-a__b dce-my--app; do
  if ! dce_is_alias_repo_name "$good" >/dev/null 2>&1; then
    fail "repo_name: '$good' must be accepted"
  fi
done

# The canonical derived-image family is disjoint from the alias family BY
# CONSTRUCTION ('img-' is a reserved alias prefix) -- guard it explicitly.
if dce_is_alias_repo_name "dce-img-abcdef0123456789" >/dev/null 2>&1; then
  fail "repo_name: canonical 'dce-img-<16hex>' must be rejected"
fi

# Reserved and malformed names. The grammar negatives are names docker itself
# rejects as repository names (trailing separator, doubled/mixed separators).
for bad in dce-base dce-snap-foo-v1 dce-snapvol-x dce-MyApp ubuntu "" \
           dce-my-app- dce-a..b dce-a___b dce-a._b dce-a.-b; do
  if dce_is_alias_repo_name "$bad" >/dev/null 2>&1; then
    fail "repo_name: '$bad' must be rejected"
  fi
done

pass "dce_is_alias_repo_name (accepts dce-<X>, rejects canonical/base/snap/foreign)"

# ---------------------------------------------------------------------------
# backend_tag_image (fake-bin PATH stubs, per tests/contract/backend-image-exists.sh)
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

# Stub logs its full argv (space-joined) and exits a controllable rc. Both
# binaries are the same script so the asserted argv distinguishes backends.
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DCE_TAG_LOG:?}"
exit "${DCE_TAG_RC:-0}"
STUB
chmod +x "$STUB_DIR/docker"
cp "$STUB_DIR/docker" "$STUB_DIR/container"

SRC="dce-img-abcdef0123456789:latest"
DST="dce-proj:latest"

# --- docker family (docker CLI: `docker tag <src> <dst>`) -------------------
TAG_LOG="$WORK/docker.log"
set +e
DEV_CONTAINERS_BACKEND=docker _DC_CLI=docker PATH="$STUB_DIR:$PATH" \
  DCE_TAG_LOG="$TAG_LOG" backend_tag_image "$SRC" "$DST"
docker_rc=$?
set -e
[[ "$docker_rc" -eq 0 ]] \
  || fail "tag_image (docker): expected rc 0 (got $docker_rc)"
[[ "$(cat "$TAG_LOG")" == "tag $SRC $DST" ]] \
  || fail "tag_image (docker): expected exactly [tag $SRC $DST], got [$(cat "$TAG_LOG")]"
pass "backend_tag_image (docker): invokes 'docker tag <src> <dst>'"

# --- apple (container CLI: `container image tag <src> <dst>`) ---------------
TAG_LOG="$WORK/apple.log"
set +e
DEV_CONTAINERS_BACKEND=apple _DC_CLI=container PATH="$STUB_DIR:$PATH" \
  DCE_TAG_LOG="$TAG_LOG" backend_tag_image "$SRC" "$DST"
apple_rc=$?
set -e
[[ "$apple_rc" -eq 0 ]] \
  || fail "tag_image (apple): expected rc 0 (got $apple_rc)"
[[ "$(cat "$TAG_LOG")" == "image tag $SRC $DST" ]] \
  || fail "tag_image (apple): expected exactly [image tag $SRC $DST], got [$(cat "$TAG_LOG")]"
pass "backend_tag_image (apple): invokes 'container image tag <src> <dst>'"

# --- rc propagation: the wrapper must surface the CLI's failure -------------
TAG_LOG="$WORK/fail.log"
set +e
DEV_CONTAINERS_BACKEND=docker _DC_CLI=docker PATH="$STUB_DIR:$PATH" \
  DCE_TAG_LOG="$TAG_LOG" DCE_TAG_RC=7 backend_tag_image "$SRC" "$DST"
fail_rc=$?
set -e
[[ "$fail_rc" -eq 7 ]] \
  || fail "tag_image: CLI failure must propagate (expected rc 7, got $fail_rc)"
pass "backend_tag_image: propagates backend CLI failure rc"

echo ""
echo "All image-alias unit checks passed."
