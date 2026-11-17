#!/usr/bin/env bash
# =============================================================================
# tests/contract/backend-apple.sh - Conformance contract for lib/backends/apple.sh
# sourced WITHOUT the facade (plans/cleanup-plan.md §4/§8: every backend module
# must validate standalone).
#
# Step 1 (structural): the main test shell sources ONLY lib/common.sh and
# lib/backends/apple.sh -- NEVER lib/container-backend.sh -- and pins the
# module's exported surface (function names, include-guard no-op, exit 0).
#
# Step 2 (behavior): apple.sh resolves dce_warn/dce_die and the
# _DCE_HOSTS_GATEWAY_* constants from common.sh, plus ONE facade dispatcher --
# backend_image_exists, the final tag guard of _backend_apple_build_via_peer --
# at invocation time. common.sh is therefore sourced; the single facade call is
# pinned with a labeled test-local shim logging `CALL facade:<fn> <argv>` into
# the same stub log, so the module's call INTO the facade stays an asserted
# interface contract. Stub CLIs (docker/container/podman) on a private PATH log
# `CALL <argv>`; expectations mirror tests/contract/backend-dispatch.sh,
# tests/contract/apple-build-fallback.sh and tests/unit/apple-host-integration.sh
# so the suites agree.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/backends/apple.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

LOG="$WORK/calls.log"
: > "$LOG"
export DC_STUB_LOG="$LOG"

STUB_DIR="$WORK/bin"
BIN_PODMAN="$WORK/bin-podman" # podman stub only (peer probe: docker absent)
BIN_BASE="$WORK/bin-base"     # bash+grep only: hermetic "CLI absent" PATH
mkdir -p "$STUB_DIR" "$BIN_PODMAN" "$BIN_BASE"
ln -s "$(command -v bash)" "$BIN_BASE/bash"
ln -s "$(command -v grep)" "$BIN_BASE/grep"

# One stub installed as `container`, `docker`, and `podman`. Every call is
# logged; answers come from fixture env vars the cases assign per scenario.
cat > "$STUB_DIR/_apple_stub" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
me="${0##*/}"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"
case "$me" in
  container)
    case "${1:-}" in
      --version)
        if [[ -n "${DC_STUB_VERSION_RC:-}" && "${DC_STUB_VERSION_RC}" != "0" ]]; then
          exit "${DC_STUB_VERSION_RC}"
        fi
        printf '%s\n' "${DC_STUB_VERSION:-}"
        ;;
      system)
        if [[ "${2:-}" == "dns" && "${3:-}" == "list" ]]; then
          if [[ "${4:-}" == "--format" ]]; then
            if [[ -n "${DC_STUB_DNS_JSON_RC:-}" && "${DC_STUB_DNS_JSON_RC}" != "0" ]]; then
              exit "${DC_STUB_DNS_JSON_RC}"
            fi
            printf '%s\n' "${DC_STUB_DNS_JSON:-}"
            exit 0
          fi
          if [[ -n "${DC_STUB_DNS_TABLE_RC:-}" && "${DC_STUB_DNS_TABLE_RC}" != "0" ]]; then
            exit "${DC_STUB_DNS_TABLE_RC}"
          fi
          printf '%s\n' "${DC_STUB_DNS_TABLE:-}"
          exit 0
        fi
        ;;
      image) : ;; # image load / image tag: success-as-no-op (peer fallback path)
    esac
    ;;
  docker|podman)
    case "${1:-}" in
      info)
        rc_var="DC_STUB_${me^^}_INFO_RC"
        if [[ -n "${!rc_var:-}" && "${!rc_var}" != "0" ]]; then
          exit "${!rc_var}"
        fi
        exit 0
        ;;
      build) exit 0 ;;
      save)
        # `save -o <tar> ...`: materialize the archive like a real export.
        while [[ $# -gt 0 ]]; do
          [[ "$1" == "-o" && -n "${2:-}" ]] && { : > "$2"; shift 2; continue; }
          shift
        done
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_apple_stub"
cp "$STUB_DIR/_apple_stub" "$STUB_DIR/container"
cp "$STUB_DIR/_apple_stub" "$STUB_DIR/docker"
cp "$STUB_DIR/_apple_stub" "$STUB_DIR/podman"
cp "$STUB_DIR/_apple_stub" "$BIN_PODMAN/podman"
export PATH="$STUB_DIR:$PATH"

# Fixture variables must cross into the stub as child-process env, so export
# them up front; the individual cases only assign values from here on.
export DC_STUB_VERSION DC_STUB_VERSION_RC
export DC_STUB_DNS_JSON DC_STUB_DNS_JSON_RC DC_STUB_DNS_TABLE DC_STUB_DNS_TABLE_RC
export DC_STUB_DOCKER_INFO_RC DC_STUB_PODMAN_INFO_RC

call_count() { grep -c '^CALL ' "$LOG" || true; }

# ---------------------------------------------------------------------------
# Step 1: standalone-module guarantee (plans/cleanup-plan.md §8).
# ---------------------------------------------------------------------------
APPLE_FNS=(_backend_version_at_least backend_apple_version_supported \
  backend_apple_dns_domain_present backend_apple_dns_bootstrap_command \
  _backend_apple_native_build_blocked _backend_apple_peer_cli \
  _backend_apple_build_via_peer _backend_apple_build_native \
  _backend_apple_build_image backend_build_image_chained \
  backend_apple_attach_ref _backend_apple_container_commit)

for fn in "${APPLE_FNS[@]}"; do
  declare -F "$fn" >/dev/null \
    || fail "apple: standalone source did not define $fn"
done
pass "apple: sources standalone (common.sh only, no facade); all 12 module functions defined"

# Guard: re-sourcing must be a no-op. A marker override of one function must
# survive the second source -- if the guard were broken, the body would
# re-execute and clobber it.
if ! bash -c '
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$1/lib/common.sh"
  # shellcheck source=/dev/null
  source "$1/lib/backends/apple.sh"
  [[ -n "${_DC_BACKENDS_APPLE_SH_LOADED:-}" ]] || exit 2
  _backend_version_at_least() { echo MARKER; }
  # shellcheck source=/dev/null
  source "$1/lib/backends/apple.sh"
  [[ "$(_backend_version_at_least 1 0)" == "MARKER" ]] || exit 3
' _ "$ROOT_DIR" >/dev/null 2>&1; then
  fail "apple: standalone source must exit 0 and the include guard must make a re-source a no-op"
fi
pass "apple: include guard makes re-source a no-op (standalone source exits 0)"

# ---------------------------------------------------------------------------
# _backend_version_at_least boundary matrix (mirrors
# tests/unit/apple-host-integration.sh; fail-safe expectations).
# ---------------------------------------------------------------------------
vc=0
while IFS='|' read -r have need expected label; do
  [[ -n "$label" ]] || continue
  got=0
  _backend_version_at_least "$have" "$need" || got=1
  [[ "$got" == "$expected" ]] \
    || fail "apple: version_at_least[$label]: have=$have need=$need -> $got, expected $expected"
  vc=$((vc + 1))
done <<'EOF'
0.8.5|0.9.0|1|patch-older
0.9.0|0.9.0|0|exact-min
0.9.1|0.9.0|0|patch-newer
0.10.0|0.9.0|0|minor-numeric-not-lexical
1.5.0|0.9.0|0|major-newer
0.9|0.9.0|0|two-component-exact-reads-as-0.9.0
1.4.1|1.4|0|need-shorter-than-have
0.9.0.1|0.9.0|0|four-component-have-greater
0.9.0|0.9.0.1|1|four-component-need-greater
1.99999999999999999999999|0.9.0|1|overlong-component-failsafe
abc|0.9.0|1|garbage-have
1.4.1|garbage|1|garbage-need
|0.9.0|1|empty-have
01.2|1.2|0|leading-zero-base10
EOF
pass "apple: _backend_version_at_least boundary matrix ($vc cases; fail-safe on garbage)"

# ---------------------------------------------------------------------------
# backend_apple_version_supported gate over stubbed `container --version`
# (exact-min passes, pre-min fails), with the CALL argv used to obtain the
# version pinned.
# ---------------------------------------------------------------------------
vs_case() { # <label> <expected-rc>
  local label="$1" expected="$2" got=0
  backend_apple_version_supported || got=1
  [[ "$got" == "$expected" ]] \
    || fail "apple: version gate [$label]: rc=$got, expected $expected"
}

DC_STUB_VERSION="container CLI version 1.4.1 (build: release, commit: 9a8917c)"
DC_STUB_VERSION_RC=0
vs_case "cli-current" 0

DC_STUB_VERSION="container CLI version 0.9.0 (build: release, commit: abc1234)"
vs_case "cli-exact-min" 0

DC_STUB_VERSION="container CLI version 0.8.5 (build: release, commit: abc1234)"
vs_case "cli-pre-min" 1

DC_STUB_VERSION="totally unexpected output"
vs_case "cli-garbage" 1

DC_STUB_VERSION=""
vs_case "cli-empty" 1

DC_STUB_VERSION="container CLI version 1.4.1"
DC_STUB_VERSION_RC=1
vs_case "cli-command-fails" 1

if ( PATH="$BIN_BASE" backend_apple_version_supported ) >/dev/null 2>&1; then
  fail "apple: version gate must fail (not crash) without the container CLI"
fi
pass "apple: version gate exact-min passes; pre-min/garbage/failed/absent CLI fail"

: > "$LOG"
DC_STUB_VERSION="container CLI version 1.4.1 (build: release, commit: 9a8917c)"
DC_STUB_VERSION_RC=0
if ! backend_apple_version_supported >/dev/null; then
  fail "apple: version gate should pass on a current CLI"
fi
grep -Fxq 'CALL container --version' "$LOG" \
  || fail "apple: version gate must obtain the version via 'container --version'; got:
$(cat "$LOG")"
pass "apple: version gate CALL argv pinned (container --version)"

# ---------------------------------------------------------------------------
# _backend_apple_native_build_blocked classifier matrix, including the
# _DC_APPLE_BLOCK_CLASS side effect (set on match, RESET on entry so a
# non-matching log can never leak a stale class).
# ---------------------------------------------------------------------------
cls_case() { # <label> <log-payload> <expected-rc> <expected-class>
  local label="$1" payload="$2" expected="$3" want_class="$4" got=0
  if _backend_apple_native_build_blocked "$payload"; then got=0; else got=1; fi
  [[ "$got" == "$expected" ]] \
    || fail "apple: classifier [$label]: rc=$got, expected $expected"
  [[ "${_DC_APPLE_BLOCK_CLASS:-}" == "$want_class" ]] \
    || fail "apple: classifier [$label]: _DC_APPLE_BLOCK_CLASS='${_DC_APPLE_BLOCK_CLASS:-}', expected '$want_class'"
}

cls_case "egress" \
  $'RUN apt-get update\nTemporary failure resolving deb.debian.org\nE: Package ca-certificates has no installation candidate' \
  0 "egress"
cls_case "context" \
  $'COPY rootfs.tar /\nfailed to calculate checksum of ref x::y\nError: failed to solve\n' \
  0 "context"
cls_case "transport-older-wording" \
  $'probing "alpine:3"\nError: unavailable (14): Transport became inactive\n' \
  0 "transport"
cls_case "transport-newer-wording" \
  $'Error: unavailable: "Stream unexpectedly closed."\n' \
  0 "transport"
cls_case "no-match" \
  $'Error: unknown (42): inexplicable builder failure\n' \
  1 ""
cls_case "empty-log" \
  "" \
  1 ""
pass "apple: classifier matches egress/context/transport and sets _DC_APPLE_BLOCK_CLASS"

# Stale-class guard: pre-seed the global, then a non-matching log must reset it.
_DC_APPLE_BLOCK_CLASS="transport"
if _backend_apple_native_build_blocked 'Error: unknown (42): no known class'; then
  fail "apple: unclassified log must not classify as blocked"
fi
if [[ -n "${_DC_APPLE_BLOCK_CLASS:-}" ]]; then
  fail "apple: classifier must reset _DC_APPLE_BLOCK_CLASS on no match; got '$_DC_APPLE_BLOCK_CLASS'"
fi
pass "apple: classifier resets _DC_APPLE_BLOCK_CLASS (no stale class across builds)"

# ---------------------------------------------------------------------------
# backend_apple_dns_bootstrap_command output shape (the canonical admin
# one-liner; the IP/domain constants come from lib/common/container-hosts.sh).
# ---------------------------------------------------------------------------
bootstrap="$(backend_apple_dns_bootstrap_command)"
want_bootstrap="sudo container system dns create host.container.internal --localhost 203.0.113.113"
[[ "$bootstrap" == "$want_bootstrap" ]] \
  || fail "apple: bootstrap command drifted:
got:      $bootstrap
expected: $want_bootstrap"
pass "apple: dns bootstrap command echoes the canonical sudo one-liner"

# ---------------------------------------------------------------------------
# backend_apple_dns_domain_present (cheap extension from the unit matrix):
# json conclusive both ways, table fallback, both-fail tolerated.
# ---------------------------------------------------------------------------
dns_case() { # <label> <expected-rc> <json-rc> <json-payload> <table-rc> <table-payload>
  local label="$1" expected="$2" got=0
  DC_STUB_DNS_JSON_RC="$3"
  DC_STUB_DNS_JSON="$4"
  DC_STUB_DNS_TABLE_RC="$5"
  DC_STUB_DNS_TABLE="$6"
  backend_apple_dns_domain_present || got=1
  [[ "$got" == "$expected" ]] \
    || fail "apple: dns_domain_present [$label]: rc=$got, expected $expected"
}

dns_case "json-present" 0 0 '["host.container.internal"]' 0 ""
dns_case "json-absent-is-conclusive" 1 0 '["something-else.internal"]' 0 ""
dns_case "json-fails-table-present" 0 1 "" 0 $'DOMAIN\nhost.container.internal\n'
dns_case "both-fail" 1 1 "" 1 ""

# Mutation guard: the probe is strictly read-only (never dns create/delete).
if grep -Eq 'dns (create|delete)' "$LOG"; then
  fail "apple: dns probe issued a mutating call:
$(grep -E 'dns (create|delete)' "$LOG")"
fi
pass "apple: dns_domain_present json/table matrix; probes strictly read-only"

# ---------------------------------------------------------------------------
# _backend_apple_peer_cli probe outcomes + argv (docker info / podman info).
# ---------------------------------------------------------------------------
DC_STUB_DOCKER_INFO_RC=0
DC_STUB_PODMAN_INFO_RC=0
: > "$LOG"
got="$(_backend_apple_peer_cli)"
if [[ "$got" != "docker" ]] \
   || [[ "$(call_count)" -ne 1 ]] \
   || ! grep -Fxq 'CALL docker info' "$LOG"; then
  fail "apple: peer_cli should pick a reachable docker with exactly one 'docker info' probe; got '$got':
$(cat "$LOG")"
fi
pass "apple: peer_cli prefers a reachable docker (argv: docker info)"

DC_STUB_DOCKER_INFO_RC=1
: > "$LOG"
got="$(_backend_apple_peer_cli)"
got_log="$(grep '^CALL ' "$LOG" || true)"
want_log=$'CALL docker info\nCALL podman info'
if [[ "$got" != "podman" || "$got_log" != "$want_log" ]]; then
  fail "apple: peer_cli must fall through to podman when docker info fails
(probes: docker info then podman info); got '$got':
$got_log"
fi
pass "apple: peer_cli falls to podman when docker info fails (argv: docker info + podman info)"

DC_STUB_DOCKER_INFO_RC=0
: > "$LOG"
rc=0
got="$(PATH="$BIN_PODMAN:$BIN_BASE" _backend_apple_peer_cli)" || rc=$?
got_log="$(grep '^CALL ' "$LOG" || true)"
if [[ "$rc" -ne 0 || "$got" != "podman" || "$got_log" != "CALL podman info" ]]; then
  fail "apple: peer_cli must pick podman when docker is absent, probing only podman info; got rc=$rc '$got':
$got_log"
fi
pass "apple: peer_cli picks podman when docker is absent (no docker probe)"

DC_STUB_PODMAN_INFO_RC=1
: > "$LOG"
rc=0
got="$(PATH="$BIN_BASE" _backend_apple_peer_cli)" || rc=$?
if [[ "$rc" -eq 0 || -n "$got" ]] \
   || [[ -n "$(grep '^CALL ' "$LOG" || true)" ]]; then
  fail "apple: peer_cli must return non-zero, no output and no probes when no peer is reachable; got rc=$rc '$got':
$(cat "$LOG")"
fi
pass "apple: peer_cli returns non-zero with no probes when no peer is reachable"
DC_STUB_PODMAN_INFO_RC=0

# ---------------------------------------------------------------------------
# _backend_apple_build_via_peer: full CALL set for each arm. The final tag
# guard calls INTO the facade (backend_image_exists) -- pinned via the labeled
# test-local shim below (no facade sourced in this file).
# ---------------------------------------------------------------------------
# Test-local facade shim (interface contract, kept minimal): logs the call into
# the same stub log and passes, standing in for the facade dispatcher.
backend_image_exists() {
  printf 'CALL facade:backend_image_exists %s\n' "$1" >> "$LOG"
}

TAG="testtag:latest"
CF="/tmp/cf"
CTX="/ctx"

: > "$LOG"
_backend_apple_build_via_peer docker "$TAG" "$CF" "$CTX" \
  || fail "apple: build_via_peer docker arm should succeed (build+save+load+guard)"
got_log="$(grep '^CALL ' "$LOG" | sed -E 's@(-o |--input )[^[:space:]]+@\1<tar>@g')"
want_log=$'CALL docker build --tag testtag:latest --file /tmp/cf /ctx\nCALL docker save -o <tar> testtag:latest\nCALL container image load --input <tar>\nCALL facade:backend_image_exists testtag:latest'
[[ "$got_log" == "$want_log" ]] \
  || fail "apple: docker arm CALL set drifted (build -> save -> container image load -> facade guard)
-- expected:
$want_log
-- got:
$got_log"
pass "apple: build_via_peer docker arm full CALL set (build -> save -> container image load -> facade guard)"

: > "$LOG"
_backend_apple_build_via_peer podman "$TAG" "$CF" "$CTX" \
  || fail "apple: build_via_peer podman arm should succeed (oci build+save+load+retag+guard)"
got_log="$(grep '^CALL ' "$LOG" | sed -E 's@(-o |--input )[^[:space:]]+@\1<tar>@g')"
want_log=$'CALL podman build --format oci --tag testtag:latest --file /tmp/cf /ctx\nCALL podman save --format oci-archive -o <tar> testtag:latest\nCALL container image load --input <tar>\nCALL container image tag localhost/testtag:latest testtag:latest\nCALL facade:backend_image_exists testtag:latest'
[[ "$got_log" == "$want_log" ]] \
  || fail "apple: podman arm CALL set drifted (oci build -> oci-archive save -> load -> localhost/ re-tag -> facade guard)
-- expected:
$want_log
-- got:
$got_log"
pass "apple: build_via_peer podman arm full CALL set (oci build -> oci-archive save -> load -> localhost/ re-tag -> facade guard)"

echo ""
echo "All backend-apple conformance checks passed."
