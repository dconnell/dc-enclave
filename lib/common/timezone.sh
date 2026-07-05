#!/usr/bin/env bash
# =============================================================================
# lib/common/timezone.sh - Host IANA timezone resolution.
#
# Sourced (never executed directly) via lib/common.sh. Pure host-side helpers
# that select a clean zone name so a container can mirror the host clock.
# Depends only on core.sh (dce_warn).
# =============================================================================

if [[ -n "${_DC_COMMON_TIMEZONE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_TIMEZONE_SH_LOADED=1

# Validate an IANA timezone name: only the characters that legitimately appear in
# zone names (letters, digits, '_', '/', '+', '-'). Rejects whitespace, colons,
# and every shell metacharacter unconditionally -- the value is embedded in a
# backend `--env TZ=` flag, so it can never be allowed to escape the assignment.
dce_timezone_name_is_valid() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9_+./-]+$ ]]
}

# Extract the zone name from a /etc/localtime symlink target. Cross-platform by
# design: both conventions embed the zone after a "zoneinfo/" segment --
#   Linux: /usr/share/zoneinfo/<Area>/<Location>
#   macOS: /var/db/timezone/zoneinfo/<Area>/<Location>
# Returns 0 with the zone on stdout when a clean segment is found; returns 1 for
# regular-file copies, missing paths, non-zoneinfo links, or invalid names.
dce_timezone_from_localtime_file() {
  local path="$1"
  local target=""
  local zone=""

  [[ -L "$path" ]] || return 1
  target="$(readlink "$path" 2>/dev/null)" || return 1
  [[ -n "$target" ]] || return 1

  if [[ "$target" == *zoneinfo/* ]]; then
    zone="${target##*zoneinfo/}"
    zone="${zone%%/}"
    if dce_timezone_name_is_valid "$zone"; then
      printf '%s\n' "$zone"
      return 0
    fi
  fi

  return 1
}

# Resolve the host's IANA timezone name so a container can mirror it.
#
# Selection order: an explicit $TZ (when it passes the strict zone-name check)
# is honored first; otherwise the zone is parsed from /etc/localtime. When
# neither yields a clean value, nothing is echoed and the call returns non-zero
# so the caller simply omits `--env TZ` and leaves the container on the image
# default. An explicitly-set but invalid $TZ is warned about and rejected rather
# than silently substituted from /etc/localtime (an explicit value is intentional).
dce_host_timezone() {
  local tz="${TZ:-}"

  if [[ -n "$tz" ]]; then
    if dce_timezone_name_is_valid "$tz"; then
      printf '%s\n' "$tz"
      return 0
    fi
    dce_warn "Ignoring invalid TZ value: $tz"
    return 1
  fi

  dce_timezone_from_localtime_file "/etc/localtime"
}
