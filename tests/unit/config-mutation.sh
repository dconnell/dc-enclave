#!/usr/bin/env bash
# =============================================================================
# tests/config-mutation.sh - Atomic-rewrite invariants for the config mutators.
#
# dce_set_config_key / dce_set_config_array rewrite the project config via a
# temp file + mv. mv does NOT preserve the target's mode, so a naive rewrite
# relaxes the file from 600 (created by new-container.sh) to the umask default
# (typically 644) -- a readable-by-group/other posture regression that also
# affects `dce network add|remove`. This file pins the invariant: the rewrite
# must preserve the original file mode, and the result must still load cleanly.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
chmod 700 "$WORK"

# Run the whole file under a hostile umask so a naive temp file would be 644;
# this guarantees the mode-preservation invariant is actually exercised.
umask 022

# Return 0 if $1 has mode $2 (portable across GNU/BSD find via -perm).
mode_is() {
  local file="$1" want="$2"
  [[ -n "$(find "$file" -maxdepth 0 -perm "$want" -print 2>/dev/null)" ]]
}

# Write a small but loadable config at mode 600 under a 0700 project dir.
write_config() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  chmod 700 "$(dirname "$file")"
  {
    echo '# DC Enclave config'
    echo 'CONTAINER_PROJECT="testproj"'
    echo 'CONTAINER_BACKEND="docker"'
    echo 'CONTAINER_IMAGE="dce-base:latest"'
    echo 'CONTAINER_CPUS="2"'
    echo 'PORTS=(3000:3000)'
    echo 'CONTAINER_HIDDEN_PATHS=()'
    echo 'CONTAINER_NETWORKS=()'
  } > "$file"
  chmod 600 "$file"
}

# --- scalar rewrite preserves mode and round-trips ----------------------------
cfg1="$WORK/p1/config"
write_config "$cfg1"
mode_is "$cfg1" 600 || fail "setup: config must start at mode 600"

dce_set_config_key "$cfg1" CONTAINER_MEMORY "4g"
mode_is "$cfg1" 600 || fail "dce_set_config_key must preserve mode 600 (got $(find "$cfg1" -maxdepth 0 -perm -777 -printf '%m\n' 2>/dev/null || stat -c '%a' "$cfg1" 2>/dev/null || echo '?'))"

CONTAINER_MEMORY=""
dce_load_project_config "$cfg1"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "scalar set did not round-trip (got '${CONTAINER_MEMORY:-}')"
[[ "${CONTAINER_CPUS:-}" == "2" ]] || fail "scalar set clobbered an unrelated key"

pass "scalar rewrite preserves mode and round-trips"

# --- scalar append-when-absent preserves mode ---------------------------------
cfg2="$WORK/p2/config"
write_config "$cfg2"
dce_set_config_key "$cfg2" CONTAINER_MEMORY "512m"
mode_is "$cfg2" 600 || fail "dce_set_config_key append must preserve mode 600"
dce_load_project_config "$cfg2"
[[ "${CONTAINER_MEMORY:-}" == "512m" ]] || fail "appended scalar did not round-trip"

pass "scalar append preserves mode"

# --- array rewrite preserves mode and round-trips -----------------------------
cfg3="$WORK/p3/config"
write_config "$cfg3"
dce_set_config_array "$cfg3" PORTS 8080:8080 9090:9090
mode_is "$cfg3" 600 || fail "dce_set_config_array must preserve mode 600"

PORTS=()
dce_load_project_config "$cfg3"
[[ "${PORTS[0]:-}" == "8080:8080" ]] || fail "array set element 0 wrong (got '${PORTS[0]:-}')"
[[ "${PORTS[1]:-}" == "9090:9090" ]] || fail "array set element 1 wrong (got '${PORTS[1]:-}')"

pass "array rewrite preserves mode and round-trips"

# --- array set to empty preserves mode ----------------------------------------
cfg4="$WORK/p4/config"
write_config "$cfg4"
dce_set_config_array "$cfg4" PORTS
mode_is "$cfg4" 600 || fail "dce_set_config_array empty must preserve mode 600"
PORTS=()
dce_load_project_config "$cfg4"
[[ ${#PORTS[@]} -eq 0 ]] || fail "array empty did not round-trip (got ${#PORTS[@]} elements)"

pass "array empty preserves mode"

# --- idempotent rewrite preserves mode ----------------------------------------
cfg5="$WORK/p5/config"
write_config "$cfg5"
dce_set_config_key "$cfg5" CONTAINER_CPUS "2"
mode_is "$cfg5" 600 || fail "idempotent rewrite must preserve mode 600"

pass "idempotent rewrite preserves mode"

echo ""
echo "All config-mutation invariants passed."
