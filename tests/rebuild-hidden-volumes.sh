#!/usr/bin/env bash
# Rebuild hidden-volume handling checks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

STUB_LIST_FAIL=false
STUB_REMOVE_FAIL_VOLUMES=()
STUB_EXISTING_VOLUMES=()
REMOVE_CALLS=()

reset_stubs() {
  STUB_LIST_FAIL=false
  STUB_REMOVE_FAIL_VOLUMES=()
  STUB_EXISTING_VOLUMES=()
  REMOVE_CALLS=()
}

backend_remove_volume() {
  local volume_name="$1"
  local fail_volume=""

  REMOVE_CALLS+=("$volume_name")
  for fail_volume in "${STUB_REMOVE_FAIL_VOLUMES[@]}"; do
    if [[ "$volume_name" == "$fail_volume" ]]; then
      return 1
    fi
  done

  return 0
}

backend_list_volumes() {
  if $STUB_LIST_FAIL; then
    return 1
  fi

  printf '%s\n' "${STUB_EXISTING_VOLUMES[@]}"
}

reset_stubs
if ! dce_rebuild_handle_hidden_volumes "myproj" true "node_modules" >/dev/null; then
  fail "keep-hidden mode should succeed"
fi
[[ ${#REMOVE_CALLS[@]} -eq 0 ]] || fail "keep-hidden mode should not remove volumes"

reset_stubs
expected_a="$(dce_hidden_volume_name "myproj" "node_modules")"
expected_b="$(dce_hidden_volume_name "myproj" "apps/web/node_modules")"
if ! dce_rebuild_handle_hidden_volumes "myproj" false "node_modules" "apps/web/node_modules" >/dev/null; then
  fail "default remove mode should succeed when removals succeed"
fi
[[ ${#REMOVE_CALLS[@]} -eq 2 ]] || fail "expected two removal calls"
[[ "${REMOVE_CALLS[0]}" == "$expected_a" ]] || fail "unexpected first removed volume"
[[ "${REMOVE_CALLS[1]}" == "$expected_b" ]] || fail "unexpected second removed volume"

reset_stubs
missing_volume="$(dce_hidden_volume_name "myproj" "node_modules")"
STUB_REMOVE_FAIL_VOLUMES=("$missing_volume")
if ! dce_rebuild_handle_hidden_volumes "myproj" false "node_modules" >/dev/null; then
  fail "remove failure should be tolerated only when volume is already absent"
fi

reset_stubs
compromised_volume="$(dce_hidden_volume_name "myproj" "node_modules")"
STUB_REMOVE_FAIL_VOLUMES=("$compromised_volume")
STUB_EXISTING_VOLUMES=("$compromised_volume")
if dce_rebuild_handle_hidden_volumes "myproj" false "node_modules" >/dev/null 2>&1; then
  fail "remove failure with existing volume must fail"
fi

reset_stubs
unverifiable_volume="$(dce_hidden_volume_name "myproj" "node_modules")"
STUB_REMOVE_FAIL_VOLUMES=("$unverifiable_volume")
STUB_LIST_FAIL=true
if dce_rebuild_handle_hidden_volumes "myproj" false "node_modules" >/dev/null 2>&1; then
  fail "remove failure with unverifiable state must fail"
fi

pass "rebuild hidden-volume handling"
