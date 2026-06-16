#!/usr/bin/env bash
# Hidden path helper checks.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

expect_invalid() {
  local value="$1"
  if dc_normalize_hidden_paths_csv "$value" >/dev/null 2>&1; then
    fail "expected invalid hidden path: $value"
  fi
}

expect_valid() {
  local value="$1"
  local expected="$2"
  local actual=""
  actual="$(dc_normalize_hidden_paths_csv "$value")" || fail "expected valid hidden path: $value"
  [[ "$actual" == "$expected" ]] || fail "normalize mismatch for '$value' (got '$actual', expected '$expected')"
}

expect_valid "node_modules" "node_modules"
expect_valid " ./apps/web/node_modules/ " "apps/web/node_modules"
expect_valid "apps//api//node_modules" "apps/api/node_modules"

expect_invalid ""
expect_invalid "/absolute/path"
expect_invalid "../node_modules"
expect_invalid "apps/../node_modules"
expect_invalid "."
expect_invalid ".."
expect_invalid "node:modules"
expect_invalid "node modules"

combined="$(dc_normalize_hidden_paths_values "node_modules" "apps/web/node_modules,node_modules" "./apps/api/node_modules/")"
[[ "$combined" == "node_modules,apps/web/node_modules,apps/api/node_modules" ]] || fail "combined hidden paths mismatch: $combined"

vol_a="$(dc_hidden_volume_name "MyProject" "node_modules")"
vol_b="$(dc_hidden_volume_name "MyProject" "apps/web/node_modules")"
vol_c="$(dc_hidden_volume_name "MyProject" "node_modules")"

[[ "$vol_a" == "$vol_c" ]] || fail "hidden volume name must be stable"
[[ "$vol_a" != "$vol_b" ]] || fail "hidden volume names must differ across paths"

pass "hidden path helpers"
