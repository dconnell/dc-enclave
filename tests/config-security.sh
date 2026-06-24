#!/usr/bin/env bash
# shellcheck disable=SC2016
# This file deliberately writes literal $/backtick command-substitution payloads
# into configs to prove they are treated as data, never executed.
# =============================================================================
# tests/config-security.sh - M1 regression coverage.
#
# Proves that config content is treated as data, not an execution surface:
#   - cpus/memory input validation,
#   - robust serialization (escaping) of persisted values,
#   - hardened project-config loader (rejects payloads, accepts valid configs),
#   - safe global-config parsing (no source/eval during completion/setup).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" /tmp/m1-*-pwn 2>/dev/null || true' EXIT
chmod 700 "$WORK"

# Write a valid project config (quoted scalar assignments + array lines), used as
# a baseline that the loader must accept. cpus/memory are optional/empty by default.
write_valid_config() {
  local file="$1"
  local cpus="${2:-}"
  local mem="${3:-}"
  local dir=""
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  chmod 700 "$dir"
  {
    echo '# DC Enclave config'
    echo 'CONTAINER_PROJECT="testproj"'
    echo 'CONTAINER_OVERLAY_SCOPES=""'
    echo 'CONTAINER_IMAGE="dce-base:latest"'
    echo 'CONTAINER_BACKEND="docker"'
    echo "CONTAINER_CPUS=\"$cpus\""
    echo "CONTAINER_MEMORY=\"$mem\""
    echo "REPOS_DIR=\"$WORK/repos\""
    echo "SECRET_DIR=\"$WORK/secret\""
    echo "SSH_KEY_PATH=\"$WORK/secret/ssh_key\""
    echo "TOKEN_FILE=\"$WORK/secret/github-token\""
    echo "NPMRC_PATH=\"$WORK/secret/.npmrc\""
    echo 'PORTS=()'
    echo 'CONTAINER_HIDDEN_PATHS=()'
  } > "$file"
  chmod 600 "$file"
}

# --- cpus validator -----------------------------------------------------------
dce_validate_cpus_value "" || fail "empty cpus should be valid (means default)"
dce_validate_cpus_value "1" 2>/dev/null || fail "cpus '1' should be valid"
dce_validate_cpus_value "2" 2>/dev/null || fail "cpus '2' should be valid"
dce_validate_cpus_value "1.5" 2>/dev/null || fail "cpus '1.5' should be valid"
dce_validate_cpus_value "0.25" 2>/dev/null || fail "cpus '0.25' should be valid"
dce_validate_cpus_value "0" 2>/dev/null && fail "cpus '0' should be invalid"
dce_validate_cpus_value "-1" 2>/dev/null && fail "negative cpus should be invalid"
dce_validate_cpus_value "1e5" 2>/dev/null && fail "exponent cpus should be invalid"
dce_validate_cpus_value "1.5.2" 2>/dev/null && fail "multi-dot cpus should be invalid"
dce_validate_cpus_value '1 core' 2>/dev/null && fail "whitespace cpus should be invalid"
dce_validate_cpus_value '$(touch x)' 2>/dev/null && fail "command-subst cpus should be invalid"
dce_validate_cpus_value '2;rm' 2>/dev/null && fail "metachar cpus should be invalid"

# --- memory validator ---------------------------------------------------------
dce_validate_memory_value "" || fail "empty memory should be valid (means default)"
dce_validate_memory_value "512m" 2>/dev/null || fail "memory '512m' should be valid"
dce_validate_memory_value "4g" 2>/dev/null || fail "memory '4g' should be valid"
dce_validate_memory_value "1024" 2>/dev/null || fail "memory '1024' should be valid"
dce_validate_memory_value "100K" 2>/dev/null || fail "memory '100K' should be valid"
dce_validate_memory_value "0" 2>/dev/null && fail "memory '0' should be invalid"
dce_validate_memory_value "-4g" 2>/dev/null && fail "negative memory should be invalid"
dce_validate_memory_value "4t" 2>/dev/null && fail "unsupported suffix '4t' should be invalid"
dce_validate_memory_value "4gb" 2>/dev/null && fail "double-letter '4gb' should be invalid"
dce_validate_memory_value '$(touch x)' 2>/dev/null && fail "command-subst memory should be invalid"

pass "cpus/memory validators"

# --- serializer ---------------------------------------------------------------
# Backslash first, then quote, $, and backtick must all be escaped.
got="$(dce_escape_config_value 'a$b`c"d\e')" || fail "serializer failed"
expected='a\$b\`c\"d\\e'
[[ "$got" == "$expected" ]] || fail "serializer escape mismatch (got '$got', expected '$expected')"

# Control characters (incl. tab/newline) must be rejected, never silently emitted.
dce_escape_config_value $'a\tb' 2>/dev/null && fail "tab control char should be rejected"
dce_escape_config_value $'a\nb' 2>/dev/null && fail "newline control char should be rejected"

pass "config value serializer"

# --- escaped payload is inert when loaded -------------------------------------
# A serialized value containing $/backtick must round-trip as literal data and
# must NEVER execute during the load.
PAYLOAD='/tmp/foo$(touch /tmp/m1-esc-pwn)`touch /tmp/m1-esc-pwn2`bar'
rm -f /tmp/m1-esc-pwn /tmp/m1-esc-pwn2
ESC="$(dce_escape_config_value "$PAYLOAD")" || fail "escape payload failed"

cfg_esc="$WORK/escproj/config"
mkdir -p "$(dirname "$cfg_esc")"
chmod 700 "$(dirname "$cfg_esc")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo "REPOS_DIR=\"$ESC\""
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_esc"
chmod 600 "$cfg_esc"

# Load in current shell so we can inspect the round-tripped variable. This call
# is expected to succeed, so dce_die (which would exit) must not fire.
dce_load_project_config "$cfg_esc"
[[ ! -e /tmp/m1-esc-pwn ]] || fail "escaped payload \$(...) executed during load"
[[ ! -e /tmp/m1-esc-pwn2 ]] || fail "escaped backtick payload executed during load"
[[ "${REPOS_DIR:-}" == "$PAYLOAD" ]] || fail "escaped value must round-trip (got '${REPOS_DIR:-}')"

pass "escaped values are inert and round-trip"

# --- malicious (unescaped) config line rejected before sourcing ---------------
rm -f /tmp/m1-malicious-pwn
cfg_mal="$WORK/malproj/config"
mkdir -p "$(dirname "$cfg_mal")"
chmod 700 "$(dirname "$cfg_mal")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'CONTAINER_CPUS="$(touch /tmp/m1-malicious-pwn)"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_mal"
chmod 600 "$cfg_mal"

if ( dce_load_project_config "$cfg_mal" ) >/dev/null 2>&1; then
  fail "loader must reject unescaped command substitution in config"
fi
[[ ! -e /tmp/m1-malicious-pwn ]] || fail "malicious line executed before rejection"

pass "malicious config line rejected before sourcing"

# --- non-assignment shell syntax rejected -------------------------------------
cfg_inject="$WORK/injectproj/config"
mkdir -p "$(dirname "$cfg_inject")"
chmod 700 "$(dirname "$cfg_inject")"
{
  echo 'CONTAINER_PROJECT="testproj"; rm -f /tmp/nope #'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_inject"
chmod 600 "$cfg_inject"
if ( dce_load_project_config "$cfg_inject" ) >/dev/null 2>&1; then
  fail "loader must reject trailing shell syntax after assignment"
fi

pass "non-assignment shell syntax rejected"

# --- unknown key rejected -----------------------------------------------------
cfg_unknown="$WORK/unknownproj/config"
mkdir -p "$(dirname "$cfg_unknown")"
chmod 700 "$(dirname "$cfg_unknown")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'EVIL_KEY="whatever"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_unknown"
chmod 600 "$cfg_unknown"
if ( dce_load_project_config "$cfg_unknown" ) >/dev/null 2>&1; then
  fail "loader must reject unknown config keys"
fi

pass "unknown config key rejected"

# --- symlinked config rejected ------------------------------------------------
cfg_link="$WORK/linkproj/config"
mkdir -p "$(dirname "$cfg_link")"
chmod 700 "$(dirname "$cfg_link")"
write_valid_config "$WORK/real_config"
ln -s "$WORK/real_config" "$cfg_link"
if ( dce_load_project_config "$cfg_link" ) >/dev/null 2>&1; then
  fail "loader must refuse to load a config via symlink"
fi

pass "symlinked config rejected"

# --- group/other-writable config rejected -------------------------------------
cfg_world="$WORK/worldproj/config"
mkdir -p "$(dirname "$cfg_world")"
chmod 700 "$(dirname "$cfg_world")"
write_valid_config "$cfg_world"
chmod 666 "$cfg_world"
if ( dce_load_project_config "$cfg_world" ) >/dev/null 2>&1; then
  fail "loader must reject group/other-writable config"
fi

pass "group/other-writable config rejected"

# --- invalid persisted cpus/memory rejected at load ---------------------------
cfg_badcpus="$WORK/badcpusproj/config"
write_valid_config "$cfg_badcpus" "not-a-number" ""
if ( dce_load_project_config "$cfg_badcpus" ) >/dev/null 2>&1; then
  fail "loader must reject invalid persisted CONTAINER_CPUS"
fi

cfg_badmem="$WORK/badmemproj/config"
write_valid_config "$cfg_badmem" "" "999z"
if ( dce_load_project_config "$cfg_badmem" ) >/dev/null 2>&1; then
  fail "loader must reject invalid persisted CONTAINER_MEMORY"
fi

pass "invalid persisted resource values rejected at load"

# --- valid legacy config continues to load ------------------------------------
cfg_ok="$WORK/okproj/config"
write_valid_config "$cfg_ok" "2" "4g"
dce_load_project_config "$cfg_ok"
[[ "${CONTAINER_CPUS:-}" == "2" ]] || fail "legacy cpus not loaded"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "legacy memory not loaded"
[[ "${CONTAINER_BACKEND:-}" == "docker" ]] || fail "legacy backend not loaded"

pass "valid legacy config loads"

# --- valid config with ports + hidden paths loads ----------------------------
cfg_ports="$WORK/portsproj/config"
mkdir -p "$(dirname "$cfg_ports")"
chmod 700 "$(dirname "$cfg_ports")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'PORTS=(5173:5173 8080)'
  echo 'CONTAINER_HIDDEN_PATHS=(node_modules apps/web/node_modules)'
} > "$cfg_ports"
chmod 600 "$cfg_ports"
dce_load_project_config "$cfg_ports"
[[ "${PORTS[0]:-}" == "5173:5173" ]] || fail "ports not loaded"
[[ "${CONTAINER_HIDDEN_PATHS[1]:-}" == "apps/web/node_modules" ]] || fail "hidden paths not loaded"

pass "valid config with ports/hidden paths loads"

# --- safe global-config scalar extraction (no execution) ----------------------
rm -f /tmp/m1-global-pwn
gcfg="$WORK/globalconfig"
{
  echo '# global config'
  echo 'DC_TEAM_DIR="/tmp/team-root"'
  echo 'DC_USER_DIR="/tmp/user-root"'
  echo 'OTHER="$(touch /tmp/m1-global-pwn)"'
} > "$gcfg"
got="$(dce_config_extract_scalar "$gcfg" DC_TEAM_DIR)" || fail "global extract failed"
[[ "$got" == "/tmp/team-root" ]] || fail "global extract mismatch (got '$got')"
[[ ! -e /tmp/m1-global-pwn ]] || fail "global extract must not execute config"

pass "global config parsed without execution"

# --- dce-complete parses overlays dir without executing config -----------------
rm -f /tmp/m1-complete-pwn
gccfg="$WORK/complete-global-config"
{
  echo '# global config'
  echo 'DC_TEAM_DIR="/tmp/safe-team"'
  echo 'DC_USER_DIR="/tmp/safe-user"'
  echo 'EVIL="$(touch /tmp/m1-complete-pwn)"'
} > "$gccfg"
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/dce-complete.bash"
got="$(_dce_read_team_dir "$gccfg")" || fail "dce-complete team root parse failed"
[[ "$got" == "/tmp/safe-team" ]] || fail "dce-complete team root mismatch (got '$got')"
[[ ! -e /tmp/m1-complete-pwn ]] || fail "dce-complete must not execute config code"

pass "dce-complete parses global config without execution"

echo ""
echo "All M1 config-security checks passed."
