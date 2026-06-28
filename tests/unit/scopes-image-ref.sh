#!/usr/bin/env bash
# =============================================================================
# tests/unit/scopes-image-ref.sh - Unit coverage for the scope/image-ref helpers in
# lib/common.sh that bridge `dce new` and `dce rebuild-container`.
#
# These helpers decide which overlay fragments compose and which derived image
# a project resolves to. They are the contract that makes new/rebuild image
# derivation deterministic, so they get focused unit tests independent of any
# backend or container.
#
# Covers:
#   - dce_normalize_scopes_csv   (trim/lowercase/dedup/validate)
#   - dce_effective_scopes_csv   (auto-all, fail-fast on missing scope, order)
#   - dce_image_ref_from_scopes  (dce-base vs dce-img-<hash>, determinism)
#   - dce_image_hash_from_ref    (hash extraction + rejection)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

OV="$WORK/overlays"
mkdir -p "$OV/team" "$OV/user"

# ---------------------------------------------------------------------------
# dce_normalize_scopes_csv
# ---------------------------------------------------------------------------
n() { dce_normalize_scopes_csv "$1" || true; }

[[ "$(n "NodeJS, nodejs")" == "nodejs" ]] \
  || fail "normalize: lowercase+trim+dedup (got [$(n "NodeJS, nodejs")])"
[[ "$(n "nodejs,golang")" == "nodejs,golang" ]] \
  || fail "normalize: preserves order (got [$(n "nodejs,golang")])"
[[ "$(n "a,,a")" == "a" ]] \
  || fail "normalize: drops empties+dedup (got [$(n "a,,a")])"
[[ "$(n "ALL")" == "all" ]] \
  || fail "normalize: lowercases ALL (got [$(n "ALL")])"
[[ "$(n "  golang  ")" == "golang" ]] \
  || fail "normalize: trims surrounding whitespace (got [$(n "  golang  ")])"

# Invalid tokens must be rejected (regex ^[a-z0-9][a-z0-9._-]*$ after trim/lower).
dce_normalize_scopes_csv ".x" >/dev/null 2>&1 && fail "normalize: leading-dot scope must be rejected"
dce_normalize_scopes_csv "a/b" >/dev/null 2>&1 && fail "normalize: slash scope must be rejected"
# shellcheck disable=SC2016  # literal $ in the invalid input under test
dce_normalize_scopes_csv 'a$b' >/dev/null 2>&1 && fail "normalize: dollar scope must be rejected"

pass "dce_normalize_scopes_csv (valid, dedup, invalid)"

# ---------------------------------------------------------------------------
# dce_effective_scopes_csv
# ---------------------------------------------------------------------------
# Helper: write overlay files for a scope in team/user namespaces.
mk_overlay() { local ns="$1" scope="$2"; mkdir -p "$OV/$ns"; printf 'RUN echo %s-%s\n' "$ns" "$scope" > "$OV/$ns/Containerfile.$scope"; }
rm_overlay() { local ns="$1" scope="$2"; rm -f "$OV/$ns/Containerfile.$scope"; }
reset_overlays() { rm -f "$OV/team"/Containerfile.* "$OV/user"/Containerfile.* 2>/dev/null || true; }

# No `all` present: effective = requested scopes only.
reset_overlays
mk_overlay team nodejs
[[ "$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs")" == "nodejs" ]] \
  || fail "effective: nodejs only (got [$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs")])"

# team/all present -> auto-prepended before requested scopes.
mk_overlay team all
[[ "$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs")" == "all,nodejs" ]] \
  || fail "effective: all auto-prepended (got [$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs")])"

# user/all alone also triggers auto-all.
rm_overlay team all; mk_overlay user all
[[ "$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs")" == "all,nodejs" ]] \
  || fail "effective: user/all triggers auto-all (got [$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs")])"

# Request-side `all` is ignored (not doubled); auto-all still applies once.
mk_overlay team all
[[ "$(dce_effective_scopes_csv "$OV/team" "$OV/user" "all,nodejs")" == "all,nodejs" ]] \
  || fail "effective: request-side all ignored (got [$(dce_effective_scopes_csv "$OV/team" "$OV/user" "all,nodejs")])"
[[ "$(dce_effective_scopes_csv "$OV/team" "$OV/user" "all")" == "all" ]] \
  || fail "effective: request all alone collapses (got [$(dce_effective_scopes_csv "$OV/team" "$OV/user" "all")])"

# Multi-scope order preserved; team+user for same scope both compose later.
mk_overlay team golang; mk_overlay user nodejs
[[ "$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs,golang")" == "all,nodejs,golang" ]] \
  || fail "effective: multi-scope order (got [$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs,golang")])"

# Dedup while preserving first occurrence.
[[ "$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs,nodejs")" == "all,nodejs" ]] \
  || fail "effective: dedup preserves order (got [$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs,nodejs")])"

# Fail fast when a named scope is missing in BOTH team and user.
reset_overlays
mk_overlay team nodejs
if dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs,ghost" >/dev/null 2>&1; then
  fail "effective: missing named scope must fail fast"
fi
# And the error names the missing scope.
err="$(dce_effective_scopes_csv "$OV/team" "$OV/user" "nodejs,ghost" 2>&1 || true)"
[[ "$err" == *"ghost"* ]] || fail "effective: error must name missing scope (got [$err])"

pass "dce_effective_scopes_csv (auto-all, order, dedup, fail-fast)"

# ---------------------------------------------------------------------------
# dce_image_ref_from_scopes
# ---------------------------------------------------------------------------
reset_overlays

# No effective scopes -> shared base image (empty request, no auto-all).
[[ "$(dce_image_ref_from_scopes "$OV/team" "$OV/user" "")" == "dce-base:latest" ]] \
  || fail "image_ref: empty scopes -> dce-base:latest"
# A request for a named scope that has no overlay file fails fast (does NOT
# silently fall back to base) -- effective_scopes_csv rejects missing scopes.
if dce_image_ref_from_scopes "$OV/team" "$OV/user" "nodejs" >/dev/null 2>&1; then
  fail "image_ref: missing named scope must fail (not fall back to dce-base)"
fi

# Effective scopes -> dce-img-<16hex>:latest.
mk_overlay team nodejs
ref="$(dce_image_ref_from_scopes "$OV/team" "$OV/user" "nodejs")"
[[ "$ref" =~ ^dce-img-[0-9a-f]{16}:latest$ ]] \
  || fail "image_ref: expected dce-img-<16hex>:latest (got [$ref])"

# Deterministic: same scopes -> same ref, stable across runs.
ref2="$(dce_image_ref_from_scopes "$OV/team" "$OV/user" "nodejs")"
[[ "$ref" == "$ref2" ]] || fail "image_ref: must be deterministic"

# Insensitive to request formatting (case/whitespace) since it normalizes.
[[ "$(dce_image_ref_from_scopes "$OV/team" "$OV/user" " NodeJS ")" == "$ref" ]] \
  || fail "image_ref: must normalize before hashing"

# Order matters by design: a,b != b,a.
mk_overlay team golang
mk_overlay team alpha
ab="$(dce_image_ref_from_scopes "$OV/team" "$OV/user" "alpha,golang")"
ba="$(dce_image_ref_from_scopes "$OV/team" "$OV/user" "golang,alpha")"
[[ "$ab" != "$ba" ]] || fail "image_ref: different scope order must hash differently"
# Same order repeats.
[[ "$(dce_image_ref_from_scopes "$OV/team" "$OV/user" "alpha,golang")" == "$ab" ]] \
  || fail "image_ref: ordered scopes must be stable"

pass "dce_image_ref_from_scopes (base vs derived, determinism, order-sensitivity)"

# ---------------------------------------------------------------------------
# dce_image_hash_from_ref
# ---------------------------------------------------------------------------
[[ "$(dce_image_hash_from_ref "dce-img-abcdef0123456789:latest")" == "abcdef0123456789" ]] \
  || fail "image_hash: must extract 16 hex from dce-img ref"
if dce_image_hash_from_ref "dce-base:latest" >/dev/null 2>&1; then
  fail "image_hash: dce-base:latest must not yield a hash"
fi
if dce_image_hash_from_ref "ubuntu:24.04" >/dev/null 2>&1; then
  fail "image_hash: arbitrary ref must be rejected"
fi
# Round-trip: hash extracted from a derived ref matches a 16-hex prefix.
rt="$(dce_image_hash_from_ref "$ref")"
[[ "$ref" == "dce-img-$rt:latest" ]] \
  || fail "image_hash: round-trip mismatch (got [$rt] from [$ref])"

pass "dce_image_hash_from_ref (extract, reject non-derived)"

echo ""
echo "All scope/image-ref unit checks passed."
