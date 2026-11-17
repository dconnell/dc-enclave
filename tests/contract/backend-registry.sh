#!/usr/bin/env bash
# =============================================================================
# tests/contract/backend-registry.sh - Conformance contract for the shared
# layer: lib/backends/registry.sh + lib/backends/docker-cli.sh, sourced WITHOUT
# the facade (plans/cleanup-plan.md §4/§8: every backend module must validate
# standalone).
#
# Step 1 (structural): each module is proven standalone in its own pristine
# subshell (common.sh + that module ONLY -- never lib/container-backend.sh):
# exit 0, include-guard no-op re-source, every expected function defined.
#
# Step 2 (behavior): docker-cli.sh's buildx gates resolve backend_name/
# backend_cli from registry.sh at invocation time, so the main shell sources
# both modules. The facade-owned memoization globals (DEV_CONTAINERS_BACKEND,
# _DC_CLI) are seeded directly -- the same trick
# tests/contract/backend-dispatch.sh:20-26 uses -- so no detection runs. The
# colima/orbstack context-pin siblings are NOT sourced: backend_use's
# colima/orbstack arms and backend_cli's colima live re-check belong to the
# per-backend conformance files and backend-dispatch.sh. Stub CLIs on a
# private PATH log `CALL <argv>`; expectations mirror backend-dispatch.sh and
# tests/contract/backend-probes.sh so the suites agree.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/backends/registry.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/backends/docker-cli.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

LOG="$WORK/calls.log"
: > "$LOG"
export DC_STUB_LOG="$LOG"

# Stub dirs for the CLI-presence variants (hermetic: the only other PATH entry
# is BIN_BASE, so host CLIs can never leak into a variant).
STUB_DIR="$WORK/bin"           # container docker podman colima
BIN_DOCKER="$WORK/bin-docker"  # docker only
BIN_COLIMA="$WORK/bin-colima"  # colima only
BIN_BASE="$WORK/bin-base"      # bash+grep only (no CLIs)
mkdir -p "$STUB_DIR" "$BIN_DOCKER" "$BIN_COLIMA" "$BIN_BASE"
ln -s "$(command -v bash)" "$BIN_BASE/bash"
ln -s "$(command -v grep)" "$BIN_BASE/grep"

# One stub installed under the CLI names. Every call is logged; `docker`
# answers the read subcommands the registry/docker-cli helpers issue, driven by
# fixture env vars.
cat > "$STUB_DIR/_registry_stub" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
me="${0##*/}"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"
case "$me" in
  docker)
    case "${1:-}/${2:-}" in
      context/ls) printf '%s\n' "${DC_STUB_DOCKER_CONTEXT_LS:-}" ;;
      image/*) printf '%s\n' "${DC_STUB_IMAGE_LS:-}" ;;
      buildx/*)
        if [[ "${DC_STUB_NO_BUILDX:-0}" == "1" ]]; then
          printf 'docker buildx: plugin not installed\n' >&2
          exit 1
        fi
        printf '%s\n' "${DC_STUB_BUILDX_VERSION:-}"
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_registry_stub"
for name in container docker podman colima; do
  cp "$STUB_DIR/_registry_stub" "$STUB_DIR/$name"
done
cp "$STUB_DIR/_registry_stub" "$BIN_DOCKER/docker"
cp "$STUB_DIR/_registry_stub" "$BIN_COLIMA/colima"
export PATH="$STUB_DIR:$BIN_BASE:$PATH"

# Fixture variables must cross into the stub as child-process env.
export DC_STUB_DOCKER_CONTEXT_LS DC_STUB_IMAGE_LS DC_STUB_BUILDX_VERSION DC_STUB_NO_BUILDX

call_count() { grep -c '^CALL ' "$LOG" || true; }

# ---------------------------------------------------------------------------
# Step 1: standalone-module guarantee (plans/cleanup-plan.md §8), for BOTH
# modules of the shared layer.
# ---------------------------------------------------------------------------
REGISTRY_FNS=(_backend_normalize _backend_cli_available _backend_docker_context_name \
  _backend_docker_context_host _backend_detect_auto backend_detect_available \
  _backend_set_cli _backend_warn_missing_cli backend_use backend_name backend_cli \
  backend_is_docker_compatible)
DOCKER_CLI_FNS=(dce_buildx_present dce_buildx_version dce_buildx_install_hint \
  dce_buildx_require _backend_list_contains _backend_image_list_has)

if ! bash -c '
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$1/lib/common.sh"
  # shellcheck source=/dev/null
  source "$1/lib/backends/registry.sh"
  [[ -n "${_DC_BACKENDS_REGISTRY_SH_LOADED:-}" ]] || exit 2
  _backend_normalize() { echo MARKER; }
  # shellcheck source=/dev/null
  source "$1/lib/backends/registry.sh"
  [[ "$(_backend_normalize colima)" == "MARKER" ]] || exit 3
' _ "$ROOT_DIR" >/dev/null 2>&1; then
  fail "registry: standalone source must exit 0 and the include guard must make a re-source a no-op"
fi
for fn in "${REGISTRY_FNS[@]}"; do
  declare -F "$fn" >/dev/null \
    || fail "registry: standalone source did not define $fn"
done
pass "registry: sources standalone (common.sh only, no facade); all 12 module functions defined; guard no-op verified"

if ! bash -c '
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$1/lib/common.sh"
  # shellcheck source=/dev/null
  source "$1/lib/backends/docker-cli.sh"
  [[ -n "${_DC_BACKENDS_DOCKER_CLI_SH_LOADED:-}" ]] || exit 2
  _backend_list_contains() { echo MARKER; }
  # shellcheck source=/dev/null
  source "$1/lib/backends/docker-cli.sh"
  [[ "$(_backend_list_contains x)" == "MARKER" ]] || exit 3
' _ "$ROOT_DIR" >/dev/null 2>&1; then
  fail "docker-cli: standalone source must exit 0 and the include guard must make a re-source a no-op"
fi
for fn in "${DOCKER_CLI_FNS[@]}"; do
  declare -F "$fn" >/dev/null \
    || fail "docker-cli: standalone source did not define $fn"
done
pass "docker-cli: sources standalone (common.sh only, no facade); all 6 module functions defined; guard no-op verified"

# Facade globals mirror: the facade declares these; seed them so the
# memoization semantics under test match the facade-loaded shape.
_DC_CLI=""

# ---------------------------------------------------------------------------
# registry: DCE_BACKENDS exact contents AND order (order = detection priority,
# NOT alphabetical; the Supported-values text derives from it via sort).
# ---------------------------------------------------------------------------
got="$(printf '%s\n' "${DCE_BACKENDS[@]}")"
want=$'apple\ndocker\norbstack\ncolima\npodman'
[[ "$got" == "$want" && "${#DCE_BACKENDS[@]}" -eq 5 ]] \
  || fail "registry: DCE_BACKENDS drifted
-- expected:
$want
-- got:
$got"
pass "registry: DCE_BACKENDS pinned exactly (apple docker orbstack colima podman, detection-priority order)"

# ---------------------------------------------------------------------------
# registry: _backend_normalize full alias matrix + rejects.
# ---------------------------------------------------------------------------
norm_case() { # <raw> <expected-canonical-or-FAIL> <label>
  local raw="$1" expected="$2" label="$3" got rc=0
  got="$(_backend_normalize "$raw")" || rc=$?
  if [[ "$expected" == "FAIL" ]]; then
    [[ "$rc" -ne 0 && -z "${got:-}" ]] \
      || fail "registry: normalize [$label]: must reject '$raw' (rc!=0, no output); got rc=$rc '$got'"
  else
    [[ "$rc" -eq 0 && "$got" == "$expected" ]] \
      || fail "registry: normalize [$label]: '$raw' -> expected '$expected', got rc=$rc '$got'"
  fi
}

norm_case "apple" "apple" "canonical"
norm_case "container" "apple" "alias-container"
norm_case "apple-container" "apple" "alias-apple-container"
norm_case "docker" "docker" "canonical"
norm_case "docker-desktop" "docker" "alias-docker-desktop"
norm_case "orbstack" "orbstack" "canonical"
norm_case "orb" "orbstack" "alias-orb"
norm_case "colima" "colima" "canonical"
norm_case "podman" "podman" "canonical"
norm_case "podman-desktop" "podman" "alias-podman-desktop"
norm_case "DOCKER" "docker" "case-fold"
norm_case "OrbStack" "orbstack" "case-fold-mixed"
norm_case "" "FAIL" "reject-empty"
norm_case "xyz" "FAIL" "reject-garbage"
norm_case "docker " "FAIL" "reject-trailing-space"
pass "registry: _backend_normalize alias matrix + rejects pinned"

# ---------------------------------------------------------------------------
# registry: backend_use with an unsupported name must fail rc=1 with EXACTLY
# two stderr lines (this pins the DCE_BACKENDS derivation of the text).
# ---------------------------------------------------------------------------
rc=0
err="$( { backend_use xyz >/dev/null; } 2>&1 )" || rc=$?
want=$'ERROR: Unsupported CONTAINER_BACKEND \'xyz\'.\n  Supported values: apple, colima, docker, orbstack, podman'
[[ "$rc" -eq 1 ]] \
  || fail "registry: backend_use xyz must return 1; got rc=$rc"
[[ "$err" == "$want" ]] \
  || fail "registry: unsupported-backend stderr must be byte-exact (two lines)
-- expected:
$want
-- got:
$err"
pass "registry: backend_use unsupported name fails rc=1 with byte-exact Supported-values stderr"

# ---------------------------------------------------------------------------
# registry: _backend_set_cli mapping (and unknown-name reject).
# ---------------------------------------------------------------------------
setcli_case() { # <backend> <expected-cli>
  local backend="$1" expected="$2"
  _DC_CLI="unset-marker"
  if ! _backend_set_cli "$backend"; then
    fail "registry: set_cli must accept '$backend'"
  fi
  [[ "$_DC_CLI" == "$expected" ]] \
    || fail "registry: set_cli [$backend]: expected _DC_CLI=$expected, got $_DC_CLI"
}
setcli_case "apple" "container"
setcli_case "docker" "docker"
setcli_case "orbstack" "docker"
setcli_case "colima" "docker"
setcli_case "podman" "podman"
if _backend_set_cli "finch" 2>/dev/null; then
  fail "registry: set_cli must reject an unknown backend name"
fi
pass "registry: _backend_set_cli maps apple->container, docker-family->docker, podman->podman, rejects unknown"

# ---------------------------------------------------------------------------
# registry: backend_name/backend_cli memoization semantics. With the selection
# state preset (DEV_CONTAINERS_BACKEND + _DC_CLI), repeat calls re-detect
# nothing: zero CALLs. With _DC_CLI empty, backend_cli re-derives via
# _backend_set_cli -- still with zero CALLs for non-colima.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
# Read by the sourced module's backend_name() (external-sources=false).
DEV_CONTAINERS_BACKEND=docker
_DC_CLI=docker
: > "$LOG"
[[ "$(backend_name)" == "docker" && "$(backend_cli)" == "docker" ]] \
  || fail "registry: preset docker selection should resolve to docker/docker"
[[ "$(backend_name)" == "docker" && "$(backend_cli)" == "docker" ]] \
  || fail "registry: repeat calls must be stable"
[[ "$(call_count)" -eq 0 ]] \
  || fail "registry: memoized docker selection must make zero CLI CALLs; got:
$(cat "$LOG")"

_DC_CLI=""
[[ "$(backend_cli)" == "docker" ]] \
  || fail "registry: backend_cli must re-derive docker from DEV_CONTAINERS_BACKEND"
[[ "$(call_count)" -eq 0 ]] \
  || fail "registry: _DC_CLI re-derivation must not probe any CLI; got:
$(cat "$LOG")"

# shellcheck disable=SC2034
DEV_CONTAINERS_BACKEND=podman
_DC_CLI=podman
[[ "$(backend_name)" == "podman" && "$(backend_cli)" == "podman" ]] \
  || fail "registry: preset podman selection should resolve to podman/podman"
[[ "$(call_count)" -eq 0 ]] \
  || fail "registry: memoized podman selection must make zero CLI CALLs; got:
$(cat "$LOG")"
pass "registry: backend_name/backend_cli memoization: preset state answers with zero CLI CALLs; _DC_CLI re-derived via set_cli"

# ---------------------------------------------------------------------------
# registry: backend_is_docker_compatible truth table, including the
# default-to-backend_name path.
# ---------------------------------------------------------------------------
compat_case() { # <arg-or-DEFAULT> <preset-backend> <expected-rc> <label>
  local arg="$1" preset="$2" expected="$3" label="$4" got=0
  # shellcheck disable=SC2034
  DEV_CONTAINERS_BACKEND="$preset"
  if [[ "$arg" == "DEFAULT" ]]; then
    backend_is_docker_compatible || got=1
  else
    backend_is_docker_compatible "$arg" || got=1
  fi
  [[ "$got" == "$expected" ]] \
    || fail "registry: docker_compatible [$label]: rc=$got, expected $expected"
}
compat_case "docker" "apple" 0 "explicit-arg-wins-over-preset"
compat_case "orbstack" "" 0 "orbstack"
compat_case "colima" "" 0 "colima"
compat_case "podman" "" 0 "podman"
compat_case "apple" "docker" 1 "apple-not-docker-compatible"
compat_case "DEFAULT" "docker" 0 "default-path-docker"
compat_case "DEFAULT" "apple" 1 "default-path-apple"
pass "registry: backend_is_docker_compatible truth table incl. default-to-backend_name path"

# ---------------------------------------------------------------------------
# registry: backend_detect_available emission ORDER under stub CLIs.
# Hermetic PATHs (BIN_BASE holds only bash+grep) so host CLIs cannot leak.
# ---------------------------------------------------------------------------
DC_STUB_DOCKER_CONTEXT_LS=$'default\norbstack\ncolima'
got="$(PATH="$STUB_DIR:$BIN_BASE" backend_detect_available)"
want=$'apple\ndocker\norbstack\ncolima\npodman'
[[ "$got" == "$want" ]] \
  || fail "registry: detect_available (all CLIs) must emit exactly apple/docker/orbstack/colima/podman in that order
-- expected:
$want
-- got:
$got"

DC_STUB_DOCKER_CONTEXT_LS="default"
got="$(PATH="$BIN_DOCKER:$BIN_BASE" backend_detect_available)"
[[ "$got" == "docker" ]] \
  || fail "registry: detect_available (docker-only, no orbstack context) must emit only 'docker'; got:
$got"

got="$(PATH="$BIN_COLIMA:$BIN_BASE" backend_detect_available)"
[[ -z "$got" ]] \
  || fail "registry: detect_available must not report colima without the docker CLI (needs BOTH); got:
$got"
pass "registry: detect_available order pinned (all CLIs -> apple docker orbstack colima podman; docker-only -> docker; colima needs both CLIs)"

# ---------------------------------------------------------------------------
# registry: backend_use docker default arm unsets DOCKER_CONTEXT (docker's one
# distinctive behavior) and makes no CLI CALLs.
# ---------------------------------------------------------------------------
DOCKER_CONTEXT="colima"
export DOCKER_CONTEXT
: > "$LOG"
if ! backend_use docker; then
  fail "registry: backend_use docker should succeed with the stub docker CLI"
fi
if [[ -n "${DOCKER_CONTEXT+x}" ]]; then
  fail "registry: backend_use docker must unset DOCKER_CONTEXT; got '${DOCKER_CONTEXT-}'"
fi
[[ "$(call_count)" -eq 0 ]] \
  || fail "registry: backend_use docker must not invoke any CLI; got:
$(cat "$LOG")"
pass "registry: backend_use docker unsets DOCKER_CONTEXT with zero CLI CALLs"

# ---------------------------------------------------------------------------
# docker-cli: _backend_list_contains exact-line semantics + full-capture (no
# early-exit) contract.
# ---------------------------------------------------------------------------
emit_img1() { printf 'img:1\nother\n'; }
emit_img12() { printf 'img:12\nother\n'; }
emit_nothing() { :; }

if ! _backend_list_contains "img:1" emit_img1 >/dev/null; then
  fail "docker-cli: list_contains must find an exact line"
fi
if _backend_list_contains "img:1" emit_img12 >/dev/null; then
  fail "docker-cli: list_contains must NOT match a substring of a longer line (img:1 vs img:12)"
fi
if _backend_list_contains "img:1" emit_nothing >/dev/null; then
  fail "docker-cli: list_contains must fail on empty output"
fi
pass "docker-cli: _backend_list_contains exact-line semantics (present / absent-but-substring / empty)"

# Full capture: the needle is the FIRST line of a LARGE output, and the
# producer logs a marker only after finishing every line. A `cmd | grep -q`
# implementation would early-exit, SIGPIPE the producer (pipefail -> 141) and
# never see the marker; the captured implementation completes.
big_producer() {
  printf 'img:1\n'
  local i
  for ((i = 0; i < 20000; i++)); do
    printf 'filler-line-%06d\n' "$i"
  done
  printf 'CALL producer finished all lines\n' >> "$LOG"
}
: > "$LOG"
if ! _backend_list_contains "img:1" big_producer >/dev/null; then
  fail "docker-cli: list_contains must find the needle in a large output"
fi
grep -Fxq 'CALL producer finished all lines' "$LOG" \
  || fail "docker-cli: producer was cut short -- list membership must capture output IN FULL (no early-exit SIGPIPE)"
pass "docker-cli: _backend_list_contains full-capture contract (producer runs to completion, no SIGPIPE)"

# ---------------------------------------------------------------------------
# docker-cli: _backend_image_list_has localhost/ normalization (podman stores
# unqualified tags as localhost/<tag>; the prefix must normalize away).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
DEV_CONTAINERS_BACKEND=docker
_DC_CLI=docker
DC_STUB_IMAGE_LS=$'localhost/dce-base:latest\nother:1\n'
: > "$LOG"
if ! _backend_image_list_has "dce-base:latest"; then
  fail "docker-cli: image_list_has must strip the podman localhost/ prefix when matching"
fi
if _backend_image_list_has "missing:latest"; then
  fail "docker-cli: image_list_has must not match an absent tag"
fi
grep -Fxq 'CALL docker image ls --format {{.Repository}}:{{.Tag}}' "$LOG" \
  || fail "docker-cli: image_list_has must list via 'image ls --format {{.Repository}}:{{.Tag}}'; got:
$(cat "$LOG")"
pass "docker-cli: _backend_image_list_has localhost/ normalization + exact image-ls argv"

# ---------------------------------------------------------------------------
# docker-cli: buildx gates (dce_buildx_present/version/require) over a stub
# `docker buildx version`, present and absent.
# ---------------------------------------------------------------------------
DC_STUB_BUILDX_VERSION="github.com/docker/buildx v0.12.0 6d12fa9"
DC_STUB_NO_BUILDX=0
# shellcheck disable=SC2034
DEV_CONTAINERS_BACKEND=docker
_DC_CLI=docker
: > "$LOG"
if ! dce_buildx_present; then
  fail "docker-cli: buildx_present must report present when 'docker buildx version' succeeds"
fi
got="$(dce_buildx_version)"
[[ "$got" == "$DC_STUB_BUILDX_VERSION" ]] \
  || fail "docker-cli: buildx_version must echo the first version line; got '$got'"
if ! dce_buildx_require >/dev/null 2>&1; then
  fail "docker-cli: buildx_require must pass when buildx is present"
fi
[[ "$(call_count)" -eq 3 ]] \
  || fail "docker-cli: present+version+require must probe 'docker buildx version' exactly 3 times; got:
$(cat "$LOG")"
pass "docker-cli: buildx gates pass with buildx present (3 probes of 'docker buildx version')"

DC_STUB_NO_BUILDX=1
if dce_buildx_present; then
  fail "docker-cli: buildx_present must report absent when 'docker buildx version' fails"
fi
# The absent-buildx contract is EMPTY OUTPUT; the helper's probe pipeline also
# returns non-zero (pipefail-propagated) -- pinned here so any caller keeps
# tolerating it, e.g. `ver="$(dce_buildx_version)" || ver=""`.
got=""
rc=0
got="$(dce_buildx_version)" || rc=$?
[[ -z "$got" ]] \
  || fail "docker-cli: buildx_version must be empty when buildx is absent; got '$got'"
[[ "$rc" -ne 0 ]] \
  || fail "docker-cli: buildx_version pipeline rc should propagate non-zero on absence"
[[ -z "$got" ]] \
  || fail "docker-cli: buildx_version must be empty when buildx is absent; got '$got'"
rc=0
err="$( { dce_buildx_require >/dev/null; } 2>&1 )" || rc=$?
[[ "$rc" -eq 1 ]] \
  || fail "docker-cli: buildx_require must fail (rc 1) when buildx is absent; got rc=$rc"
[[ "$err" == *"buildx plugin not found"* && "$err" == *"Install:"* && "$err" == *"Verify:   docker buildx version"* ]] \
  || fail "docker-cli: buildx_require absence message must include the not-found line, Install: hint and Verify: line; got:
$err"
got="$(dce_buildx_install_hint)"
[[ -n "$got" ]] \
  || fail "docker-cli: buildx_install_hint must produce a platform hint"
pass "docker-cli: buildx gates fail with the actionable install-hint block when buildx is absent"

# Not applicable on podman/apple: reported present WITHOUT any probe (their
# builders have their own / separate paths).
: > "$LOG"
# shellcheck disable=SC2034
DEV_CONTAINERS_BACKEND=podman
_DC_CLI=podman
if ! dce_buildx_require >/dev/null 2>&1; then
  fail "docker-cli: buildx_require must no-op pass on podman"
fi
# shellcheck disable=SC2034
DEV_CONTAINERS_BACKEND=apple
_DC_CLI=container
if ! dce_buildx_present; then
  fail "docker-cli: buildx_present must report present (not applicable) on apple"
fi
[[ -z "$(grep '^CALL ' "$LOG" || true)" ]] \
  || fail "docker-cli: podman/apple must not probe buildx at all; got:
$(cat "$LOG")"
pass "docker-cli: buildx gates report present without probing on podman/apple (not applicable)"

echo ""
echo "All backend-registry conformance checks passed."
