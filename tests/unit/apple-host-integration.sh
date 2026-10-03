#!/usr/bin/env bash
# =============================================================================
# tests/unit/apple-host-integration.sh - apple/container host-integration probes.
#
# Covers the apple capability surface in lib/container-backend.sh that gives
# containers host-loopback reachability (parity with docker's
# host.docker.internal):
#
#   - constants      -> the gateway line pin (IP + both names) shared with
#                       lib/common/container-hosts.sh
#   - version gate   -> _backend_version_at_least comparison table (numeric
#                       dotted compare, fail-safe on garbage) plus end-to-end
#                       backend_apple_version_supported over real `container
#                       --version` output shapes
#   - dns probe      -> backend_apple_dns_domain_present over sample
#                       `container system dns list` outputs (json + table
#                       forms, present/absent/malformed/failed)
#   - bootstrap cmd  -> backend_apple_dns_bootstrap_command echoes the exact
#                       canonical admin command
#   - mutation guard -> the probes only ever invoke read-only container
#                       subcommands; dce never runs sudo or
#                       `dns create`/`dns delete`
#
# In-process: the `container` CLI is stubbed on PATH (the probes must not
# depend on it being installed), and `sudo` is stubbed to FAIL LOUDLY so an
# accidental privileged call can never reach the real binary.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
chmod 700 "$WORK"

STUB_DIR="$WORK/bin"
EMPTY_BIN="$WORK/empty"
mkdir -p "$STUB_DIR" "$EMPTY_BIN"
LOG="$WORK/calls.log"
: > "$LOG"

cat > "$STUB_DIR/container" <<'STUB'
#!/usr/bin/env bash
# Stub `container` CLI: logs every invocation, then answers the two read-only
# probes the host-integration helpers use, from fixtures:
#   container --version                    -> $DC_STUB_VERSION (rc $DC_STUB_VERSION_RC)
#   container system dns list --format json-> contents of $DC_STUB_DNS_JSON
#                                             (rc $DC_STUB_DNS_JSON_RC; a non-zero
#                                             rc simulates a CLI without the flag)
#   container system dns list              -> contents of $DC_STUB_DNS_TABLE
#                                             (rc $DC_STUB_DNS_TABLE_RC)
# Anything else is logged and answered with success-as-no-op -- the mutation
# guard below asserts the log never contains a mutating subcommand.
_log="${DC_STUB_LOG:?}"
printf 'CALL %s\n' "$*" >> "$_log"

case "${1:-}" in
  --version)
    if [[ -n "${DC_STUB_VERSION_RC:-}" && "${DC_STUB_VERSION_RC}" != "0" ]]; then
      exit "${DC_STUB_VERSION_RC}"
    fi
    printf '%s\n' "${DC_STUB_VERSION:-}"
    exit 0
    ;;
  system)
    if [[ "${2:-}" == "dns" && "${3:-}" == "list" ]]; then
      if [[ "${4:-}" == "--format" && "${5:-}" == "json" ]]; then
        if [[ -n "${DC_STUB_DNS_JSON_RC:-}" && "${DC_STUB_DNS_JSON_RC}" != "0" ]]; then
          exit "${DC_STUB_DNS_JSON_RC}"
        fi
        if [[ -n "${DC_STUB_DNS_JSON:-}" && -f "${DC_STUB_DNS_JSON}" ]]; then
          cat "${DC_STUB_DNS_JSON}"
        fi
        exit 0
      fi
      if [[ -n "${DC_STUB_DNS_TABLE_RC:-}" && "${DC_STUB_DNS_TABLE_RC}" != "0" ]]; then
        exit "${DC_STUB_DNS_TABLE_RC}"
      fi
      if [[ -n "${DC_STUB_DNS_TABLE:-}" && -f "${DC_STUB_DNS_TABLE}" ]]; then
        cat "${DC_STUB_DNS_TABLE}"
      fi
      exit 0
    fi
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/container"

# sudo must never be invoked by dce; stub it to log + fail so a regression is
# caught here instead of prompting against the real host.
cat > "$STUB_DIR/sudo" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
printf 'CALL %s\n' "sudo $*" >> "$_log"
echo "FAIL: dce attempted a sudo call: sudo $*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/sudo"

export PATH="$STUB_DIR:$PATH"
export DC_STUB_LOG="$LOG"

# shellcheck source=/dev/null
source "$ROOT_DIR/lib/container-backend.sh"

# Fixture variables must cross into the stub as child-process env, so export
# them up front; the individual cases only assign values from here on.
export DC_STUB_VERSION DC_STUB_VERSION_RC
export DC_STUB_DNS_JSON DC_STUB_DNS_JSON_RC DC_STUB_DNS_TABLE DC_STUB_DNS_TABLE_RC

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- constants: the gateway line pin (shared contract with container-hosts.sh) -
[[ "${_DCE_HOSTS_GATEWAY_IP:-}" == "203.0.113.113" ]] \
  || fail "gateway IP constant drifted: ${_DCE_HOSTS_GATEWAY_IP:-<unset>}"
[[ "${_DCE_HOSTS_GATEWAY_DOCKER_NAME:-}" == "host.docker.internal" ]] \
  || fail "docker alias constant drifted: ${_DCE_HOSTS_GATEWAY_DOCKER_NAME:-<unset>}"
[[ "${_DCE_HOSTS_GATEWAY_APPLE_NAME:-}" == "host.container.internal" ]] \
  || fail "apple domain constant drifted: ${_DCE_HOSTS_GATEWAY_APPLE_NAME:-<unset>}"
[[ "${_DCE_HOSTS_GATEWAY_LINE:-}" == "203.0.113.113 host.docker.internal host.container.internal" ]] \
  || fail "gateway hosts line drifted: ${_DCE_HOSTS_GATEWAY_LINE:-<unset>}"
pass "constants: gateway IP / docker alias / apple domain / hosts line pinned"

# --- version compare: _backend_version_at_least table --------------------------
# have|need|expected(0 = have >= need)|label -- fail-safe expectation: anything
# malformed compares as "unsupported".
vc_pass=0
while IFS='|' read -r have need expected label; do
  [[ -n "$label" ]] || continue
  if _backend_version_at_least "$have" "$need"; then got=0; else got=1; fi
  if [[ "$got" != "$expected" ]]; then
    fail "version_at_least[$label]: have=$have need=$need -> $got, expected $expected"
  fi
  vc_pass=$((vc_pass + 1))
done <<'EOF'
0.8.5|0.9.0|1|patch-older
0.9.0|0.9.0|0|exact-min
0.9.1|0.9.0|0|patch-newer
0.10.0|0.9.0|0|minor-numeric-not-lexical
1.5.0|0.9.0|0|major-newer
1.4|0.9.0|0|two-component-have
0.8|0.9.0|1|two-component-older
0.9|0.9.0|0|two-component-exact
1.4.1|1.4|0|need-shorter-than-have
1.3|1.4|1|need-major-newer
0.9.0.1|0.9.0|0|four-component-have-greater
0.9.0|0.9.0.1|1|four-component-need-greater
1.2.3.4.5|1.2.3|0|five-component-have-greater
1.99999999999999999999999|0.9.0|1|overlong-component-failsafe
abc|0.9.0|1|garbage-have
1.4.1|garbage|1|garbage-need
|0.9.0|1|empty-have
01.2|1.2|0|leading-zero-base10
EOF
pass "version compare: $vc_pass table cases (numeric dotted compare, fail-safe)"

# --- backend_apple_version_supported: end-to-end over real version shapes ------
vspec_case() {  # <label> <expected-rc>
  local label="$1" expected="$2"
  local got=0
  backend_apple_version_supported || got=1
  [[ "$got" == "$expected" ]] \
    || fail "version_supported[$label]: rc=$got, expected $expected"
}

DC_STUB_VERSION="container CLI version 1.4.1 (build: release, commit: 9a8917c)"
DC_STUB_VERSION_RC=0
vspec_case "cli-current" 0

DC_STUB_VERSION="container CLI version 0.9.0 (build: release, commit: abc1234)"
vspec_case "cli-exact-min" 0

DC_STUB_VERSION="container CLI version 0.8.5 (build: release, commit: abc1234)"
vspec_case "cli-pre-min" 1

DC_STUB_VERSION="totally unexpected output"
vspec_case "cli-garbage" 1

DC_STUB_VERSION=""
vspec_case "cli-empty" 1

DC_STUB_VERSION="container CLI version 1.4.1"
DC_STUB_VERSION_RC=1
vspec_case "cli-command-fails" 1

# Binary absent -> unsupported (never a crash under set -e).
if ( PATH="$EMPTY_BIN" backend_apple_version_supported ) >/dev/null 2>&1; then
  fail "version_supported[binary-absent]: expected non-zero without the CLI"
fi
pass "version_supported: real version shapes, garbage, failure, absent CLI"

# --- dns-domain probe: table over sample `dns list` outputs --------------------
# Fixtures mirror the real CLI: --format json renders a bare array of domain
# strings; the table renders a DOMAIN header plus one row per domain.
fx() {  # <name> <content>
  printf '%s' "$2" > "$WORK/$1"
}
fx dns_json_present.json '["host.container.internal"]'
fx dns_json_among.json '["db.corp.internal","host.container.internal"]'
fx dns_json_fqdn.json '["host.container.internal."]'
fx dns_json_absent.json '["something-else.internal"]'
fx dns_json_empty.json '[]'
fx dns_json_garbage.json 'not json at all {{{'
fx dns_table_present.txt 'DOMAIN
host.container.internal
'
fx dns_table_absent.txt 'DOMAIN
something-else.internal
'
fx dns_table_garbage.txt '??? broken ??'

dns_case() {  # <label> <expected-rc> <json-rc> <json-file> <table-rc> <table-file>
  local label="$1" expected="$2"
  DC_STUB_DNS_JSON_RC="${3:-0}"
  DC_STUB_DNS_JSON="${4:+$WORK/$4}"
  DC_STUB_DNS_TABLE_RC="${5:-0}"
  DC_STUB_DNS_TABLE="${6:+$WORK/$6}"
  local got=0
  backend_apple_dns_domain_present || got=1
  if [[ "$got" != "$expected" ]]; then
    fail "dns_domain[$label]: rc=$got, expected $expected"
  fi
}

dns_case "json-present"          0 0 dns_json_present.json
dns_case "json-present-among"    0 0 dns_json_among.json
dns_case "json-present-fqdn-dot" 0 0 dns_json_fqdn.json
dns_case "json-absent"           1 0 dns_json_absent.json
dns_case "json-empty-array"      1 0 dns_json_empty.json
dns_case "json-garbage"          1 0 dns_json_garbage.json
dns_case "json-fails-table-present" 0 1 "" 0 dns_table_present.txt
dns_case "json-fails-table-absent"  1 1 "" 0 dns_table_absent.txt
dns_case "json-fails-table-garbage" 1 1 "" 0 dns_table_garbage.txt
dns_case "both-fail"             1 1 "" 1 ""
pass "dns-domain probe: json/table, present/absent/malformed/failed tolerated"

# --- bootstrap command: the canonical admin one-liner --------------------------
bootstrap="$(backend_apple_dns_bootstrap_command)"
[[ "$bootstrap" == "sudo container system dns create host.container.internal --localhost 203.0.113.113" ]] \
  || fail "bootstrap command drifted: $bootstrap"
pass "bootstrap command: canonical sudo dns create one-liner echoed"

# --- mutation guard: probes are strictly read-only ------------------------------
# Every logged call must be one of the two read-only probes; sudo is stubbed to
# fail (and would be logged as "sudo ..."), and any dns create/delete argv
# would land in the log via the container stub.
if grep -Eq 'dns (create|delete)|^CALL sudo' "$LOG"; then
  fail "mutation guard: dce issued a privileged or mutating call:
$(grep -E 'dns (create|delete)|^CALL sudo' "$LOG")"
fi
if ! grep -q 'CALL --version' "$LOG" || ! grep -q 'CALL system dns list --format json' "$LOG"; then
  fail "mutation guard: expected the read-only probes in the call log:
$(cat "$LOG")"
fi
pass "mutation guard: only read-only container subcommands were invoked"

echo "All apple host-integration checks passed."
