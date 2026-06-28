#!/usr/bin/env bash
# =============================================================================
# tests/unit/timezone.sh - Unit coverage for the host-timezone helpers in
# lib/common.sh that bridge `dce new` and `dce rebuild-container`.
#
# Each developer's container must match their host timezone, so the zone is
# selected at create time (--env TZ=) rather than baked into the shared image.
# These helpers detect the host zone deterministically and never emit an
# unvalidated value (the result is embedded in a backend create flag).
#
# Covers:
#   - dce_timezone_name_is_valid   (IANA-name charset; rejects shell metachars)
#   - dce_timezone_from_localtime_file (symlink parse, macOS + Linux shapes)
#   - dce_host_timezone            (TZ env honored, invalid rejected, fallback)
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

# ---------------------------------------------------------------------------
# dce_timezone_name_is_valid
# ---------------------------------------------------------------------------
v() { dce_timezone_name_is_valid "$1"; }

v "America/New_York"           || fail "valid: America/New_York rejected"
v "UTC"                        || fail "valid: UTC rejected"
v "Europe/Berlin"              || fail "valid: Europe/Berlin rejected"
v "America/Argentina/Buenos_Aires" || fail "valid: underscore zone rejected"
v "Etc/GMT-5"                  || fail "valid: Etc/GMT-5 (dash) rejected"
v "Asia/Kolkata"               || fail "valid: Asia/Kolkata rejected"

# POSIX-style TZ strings are alnum and must also pass (no shell metachars).
v "EST5EDT"                    || fail "valid: POSIX EST5EDT rejected"

# Rejections: empty, whitespace, colon, and every shell metacharacter.
v ""              && fail "invalid: empty must be rejected"
v "America/New York" && fail "invalid: space must be rejected"
v "America:New_York" && fail "invalid: colon must be rejected"
# shellcheck disable=SC2016  # literal $ in the invalid input under test
v 'a$b'           && fail "invalid: dollar must be rejected"
v 'a;b'           && fail "invalid: semicolon must be rejected"
v 'a`b'           && fail "invalid: backtick must be rejected"
v 'a"b'           && fail "invalid: quote must be rejected"
v 'a b'           && fail "invalid: space must be rejected (2)"

pass "dce_timezone_name_is_valid (IANA charset, rejects shell metachars)"

# ---------------------------------------------------------------------------
# dce_timezone_from_localtime_file (symlink parsing)
# ---------------------------------------------------------------------------
# Linux shape: /usr/share/zoneinfo/<Area>/<Location>
ln -s "/usr/share/zoneinfo/America/Los_Angeles" "$WORK/linux_lt"
got="$(dce_timezone_from_localtime_file "$WORK/linux_lt")" \
  || fail "localtime: Linux symlink must resolve"
[[ "$got" == "America/Los_Angeles" ]] \
  || fail "localtime: Linux zone wrong (got [$got])"

# macOS shape: /var/db/timezone/zoneinfo/<Area>/<Location>
ln -s "/var/db/timezone/zoneinfo/Europe/Berlin" "$WORK/mac_lt"
got="$(dce_timezone_from_localtime_file "$WORK/mac_lt")" \
  || fail "localtime: macOS symlink must resolve"
[[ "$got" == "Europe/Berlin" ]] \
  || fail "localtime: macOS zone wrong (got [$got])"

# Three-segment zone name (America/Argentina/...).
ln -s "/usr/share/zoneinfo/America/Argentina/Buenos_Aires" "$WORK/three_lt"
got="$(dce_timezone_from_localtime_file "$WORK/three_lt")" \
  || fail "localtime: three-segment zone must resolve"
[[ "$got" == "America/Argentina/Buenos_Aires" ]] \
  || fail "localtime: three-segment zone wrong (got [$got])"

# Non-symlink (regular file copy) -> cannot derive a name -> fail.
: > "$WORK/copy_lt"
if dce_timezone_from_localtime_file "$WORK/copy_lt" >/dev/null 2>&1; then
  fail "localtime: regular file must NOT resolve"
fi

# Missing path -> fail (not crash).
if dce_timezone_from_localtime_file "$WORK/does_not_exist" >/dev/null 2>&1; then
  fail "localtime: missing path must NOT resolve"
fi

# Symlink whose target lacks a zoneinfo/ segment -> fail.
ln -s "/opt/somewhere/Foo" "$WORK/bad_lt"
if dce_timezone_from_localtime_file "$WORK/bad_lt" >/dev/null 2>&1; then
  fail "localtime: non-zoneinfo symlink must NOT resolve"
fi

pass "dce_timezone_from_localtime_file (Linux/macOS shapes, rejections)"

# ---------------------------------------------------------------------------
# dce_host_timezone (selection order: TZ env -> /etc/localtime -> none)
# ---------------------------------------------------------------------------
# Explicit, valid TZ env is honored verbatim.
got="$(TZ=America/New_York dce_host_timezone)" \
  || fail "host_tz: valid TZ env must succeed"
[[ "$got" == "America/New_York" ]] \
  || fail "host_tz: TZ env not honored (got [$got])"

got="$(TZ=UTC dce_host_timezone)" || fail "host_tz: UTC env"
[[ "$got" == "UTC" ]] || fail "host_tz: UTC env value wrong (got [$got])"

# Explicit but INVALID TZ -> rejected (warn + non-zero), no stdout, and NOT
# silently substituted from /etc/localtime.
if out="$(TZ='bad;rm -rf tz' dce_host_timezone 2>/dev/null)"; then
  fail "host_tz: shell-metachar TZ must be rejected"
fi
[[ -z "$out" ]] || fail "host_tz: rejected TZ must emit nothing (got [$out])"

# Whitespace TZ likewise rejected.
if out="$(TZ='America/New York' dce_host_timezone 2>/dev/null)"; then
  fail "host_tz: whitespace TZ must be rejected"
fi
[[ -z "$out" ]] || fail "host_tz: whitespace TZ must emit nothing (got [$out])"

pass "dce_host_timezone (TZ env honored, invalid rejected)"

echo ""
echo "All timezone unit checks passed."
