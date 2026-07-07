#!/usr/bin/env bash
# =============================================================================
# tests/unit/network-helpers.sh - Pure host-side networking helper unit tests.
#
# Exercises the lib/network.sh + lib/common.sh networking helpers in-process
# with no backend and no stubs: argument normalization, entry accessors,
# backend limits, create-args shape, and CONTAINER_NETWORKS round-trips through
# the hardened config loader / dce_set_config_array.
#
# The stubbed-backend coverage of the networking feature (dce new/rebuild/network
# create/ls/rm/add against fake docker/container/podman) lives in
# tests/contract/networks.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/network.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ===========================================================================
# Section A - pure helpers (no backend / no stubs)
# ===========================================================================
[[ "$(dce_normalize_network_arg "myapp,obs")" == "myapp,obs" ]] || fail "normalize plain"
[[ "$(dce_normalize_network_arg " A : 10.0.0.5 , b ")" == "a:10.0.0.5,b" ]] || fail "normalize spaced/ip"
# Embedded tabs are stripped from each token (not just trimmed at the edges),
# so a name containing a tab normalizes cleanly instead of failing validation.
[[ "$(dce_normalize_network_arg $'my\tapp,obs')" == "myapp,obs" ]] || fail "normalize strips embedded tab"
[[ "$(dce_normalize_network_arg $'a\t: 10.0.0.5')" == "a:10.0.0.5" ]] || fail "normalize strips tab before :ip"
[[ -z "$(dce_normalize_network_arg "")" ]] || fail "normalize empty"
[[ "$(dce_normalize_network_arg "x,x")" == "x" ]] || fail "normalize dedupe"
dce_normalize_network_arg "bad name" >/dev/null 2>&1 && fail "normalize rejects whitespace" || true
dce_normalize_network_arg "a:1.2.3.4,a:5.6.7.8" >/dev/null 2>&1 && fail "normalize rejects conflicting ip" || true
[[ "$(dce_network_entry_name "a:10.0.0.5")" == "a" ]] || fail "entry name"
[[ "$(dce_network_entry_ip "a:10.0.0.5")" == "10.0.0.5" ]] || fail "entry ip"
[[ -z "$(dce_network_entry_ip "a")" ]] || fail "entry ip empty"

# backend limits
dce_network_check_backend_limits apple "n1" || fail "apple single ok"
dce_network_check_backend_limits apple "n1" "n2" 2>/dev/null && fail "apple multi rejected" || true
dce_network_check_backend_limits apple "n1:10.0.0.1" 2>/dev/null && fail "apple ip rejected" || true
dce_network_check_backend_limits docker "n1" "n2:10.0.0.1" || fail "docker multi+ip ok"

# create_args
mapfile -t CA < <(DEV_CONTAINERS_BACKEND=docker dce_networks_create_args "n1:10.0.0.5" "n2")
[[ "${CA[*]}" == "--network n1 --ip 10.0.0.5" ]] || fail "create_args docker (got [${CA[*]}])"
mapfile -t CA < <(DEV_CONTAINERS_BACKEND=apple dce_networks_create_args "n1")
[[ "${CA[*]}" == "--network n1" ]] || fail "create_args apple (got [${CA[*]}])"
mapfile -t CA < <(DEV_CONTAINERS_BACKEND=docker dce_networks_create_args)
[[ ${#CA[@]} -eq 0 ]] || fail "create_args empty"

# CONTAINER_NETWORKS round-trips through the hardened loader.
cfgA="$WORK/sectA/config"; mkdir -p "$(dirname "$cfgA")"; chmod 700 "$(dirname "$cfgA")"
{
  echo 'CONTAINER_PROJECT="p"'; echo 'CONTAINER_BACKEND="docker"'; echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'PORTS=()'; echo 'CONTAINER_HIDDEN_PATHS=()'; echo 'CONTAINER_NETWORKS=(myapp:10.0.0.5 obs)'
} > "$cfgA"; chmod 600 "$cfgA"
# shellcheck disable=SC2034
PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
dce_load_project_config "$cfgA"
[[ "${CONTAINER_NETWORKS[*]}" == "myapp:10.0.0.5 obs" ]] || fail "loader CONTAINER_NETWORKS round-trip"

# dce_set_config_array rewrites the array line and round-trips.
dce_set_config_array "$cfgA" CONTAINER_NETWORKS "onlynet"
# shellcheck disable=SC2034
PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
dce_load_project_config "$cfgA"
[[ "${CONTAINER_NETWORKS[*]}" == "onlynet" ]] || fail "set_config_array rewrite"
dce_set_config_array "$cfgA" CONTAINER_NETWORKS   # empty out
# shellcheck disable=SC2034
PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
dce_load_project_config "$cfgA"
[[ ${#CONTAINER_NETWORKS[@]} -eq 0 ]] || fail "set_config_array empty"

pass "Section A: pure helpers"

echo ""
echo "All networking helper checks passed."
