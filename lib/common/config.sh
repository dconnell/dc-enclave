#!/usr/bin/env bash
# =============================================================================
# lib/common/config.sh - Project config schema, validation, load, and write.
#
# Sourced (never executed directly) via lib/common.sh. Owns the hardened,
# single-path project-config loader: validates file safety (regular file, not a
# symlink, not group/other-writable) and line shape (known keys, no shell
# syntax or unescaped command substitution) BEFORE sourcing, then validates the
# loaded values. Also exposes the schema arrays (_DC_CONFIG_*_KEYS,
# _DC_KNOWN_BACKENDS), the typed validators (cpus/memory/network/ip/subnet),
# the value serializer/parser pair (escape_config_value / extract_scalar), and
# the atomic key/array setters used by maintenance commands. Depends on core.sh
# (dce_die) and -- at call time only -- on scopes.sh / hidden-volumes.sh /
# git-host.sh for cross-cutting validators inside dce_validate_config_values.
# =============================================================================

if [[ -n "${_DC_COMMON_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_CONFIG_SH_LOADED=1

# Known scalar and array keys permitted in a project config file. The loader
# rejects any key outside these sets so an attacker cannot introduce arbitrary
# assignments. Keep in sync with scripts/new-container.sh config emission.
declare -gra _DC_CONFIG_SCALAR_KEYS=(
  CONTAINER_PROJECT CONTAINER_OVERLAY_SCOPES CONTAINER_IMAGE CONTAINER_BACKEND
  CONTAINER_GIT_HOST
  CONTAINER_CPUS CONTAINER_MEMORY REPOS_DIR SECRET_DIR
  SSH_KEY_PATH TOKEN_FILE NPMRC_PATH
)
declare -ga _DC_CONFIG_ARRAY_KEYS=(PORTS CONTAINER_HIDDEN_PATHS CONTAINER_NETWORKS)

# Supported container backend names (mirrors lib/container-backend.sh selection).
declare -ga _DC_KNOWN_BACKENDS=(apple docker orbstack colima podman)

# Validate a CONTAINER_CPUS value: empty (default) or a positive decimal such as
# 1, 2, 1.5, 0.25. Rejects zero/negative, exponent notation, whitespace, and any
# shell metacharacter. Prints a diagnostic and returns 1 on rejection.
dce_validate_cpus_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf 'ERROR: Invalid CPU value: %q\n' "$value" >&2
    printf '  Expected a positive decimal (e.g. 1, 2, 1.5, 0.25); no exponents or units.\n' >&2
    return 1
  fi

  if [[ "$value" =~ ^0+(\.0+)?$ ]]; then
    printf 'ERROR: CPU value must be greater than zero: %s\n' "$value" >&2
    return 1
  fi

  return 0
}

# Validate a CONTAINER_MEMORY value: empty (default) or a positive integer with an
# optional single unit suffix (k, m, g; case-insensitive), e.g. 512m, 4g, 1024.
# Rejects zero/negative, unsupported suffixes, whitespace, and shell metacharacters.
dce_validate_memory_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]+[kKmMgG]?$ ]]; then
    printf 'ERROR: Invalid memory value: %q\n' "$value" >&2
    printf '  Expected a positive integer with optional unit (k, m, g), e.g. 512m, 4g, 1024.\n' >&2
    return 1
  fi

  if [[ "$value" =~ ^0+[kKmMgG]?$ ]]; then
    printf 'ERROR: memory value must be greater than zero: %s\n' "$value" >&2
    return 1
  fi

  return 0
}

# Validate a network name. Networks are user-defined objects shared across
# containers and embedded in backend `network create/connect` flags, so they use
# the same conservative identifier pattern as overlay scopes (no shell
# metacharacters, no whitespace, no leading dash). Returns 0 (valid) / 1 silent.
dce_validate_network_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# Validate an IPv4 address value: empty (means "auto-allocate") or a dotted-quad
# with each octet in 0-255. Rejects zero-octet padding beyond leading-zero rules,
# whitespace, exponents, and any shell metacharacter. Prints a diagnostic and
# returns 1 on rejection. (Mirrors dce_validate_cpus_value / dce_validate_memory_value.)
dce_validate_ip_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    printf 'ERROR: Invalid IPv4 address: %q\n' "$value" >&2
    printf '  Expected dotted-quad (e.g. 10.20.30.40).\n' >&2
    return 1
  fi

  local octet=""
  local -a octets=()
  IFS=. read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    # Reject leading zeros like 010 (ambiguous octal) while allowing single 0.
    if [[ "$octet" =~ ^0[0-9]+$ ]]; then
      printf 'ERROR: Invalid IPv4 octet (leading zero): %s in %s\n' "$octet" "$value" >&2
      return 1
    fi
    if [[ "$octet" -gt 255 ]]; then
      printf 'ERROR: Invalid IPv4 octet (>255): %s in %s\n' "$octet" "$value" >&2
      return 1
    fi
  done

  return 0
}

# Validate an IPv4 CIDR subnet value: empty (means "auto-allocate by backend") or
# dotted-quad / prefix with octets 0-255 and prefix 0-32. Prints a diagnostic and
# returns 1 on rejection.
dce_validate_subnet_value() {
  local value="$1"

  [[ -n "$value" ]] || return 0

  if [[ ! "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    printf 'ERROR: Invalid IPv4 subnet (expected A.B.C.D/N): %q\n' "$value" >&2
    return 1
  fi

  local prefix="${value##*/}"
  local addr="${value%/*}"

  if [[ "$prefix" -gt 32 ]]; then
    printf 'ERROR: Invalid subnet prefix (>32): %s in %s\n' "$prefix" "$value" >&2
    return 1
  fi

  if ! dce_validate_ip_value "$addr" 2>/dev/null; then
    printf 'ERROR: Invalid subnet address in %s\n' "$value" >&2
    return 1
  fi

  return 0
}

# Serialize a value for safe embedding inside a double-quoted shell assignment.
# Escapes backslash, quote, $, and backtick (in that order) so a later `source`
# reproduces the exact bytes without executing command substitution. Rejects
# control characters (newline, tab, NUL, ...) outright; they never belong in a
# config value. Echoes the escaped string on success; returns 1 on rejection.
dce_escape_config_value() {
  local value="$1"

  if [[ "$value" =~ [[:cntrl:]] ]]; then
    printf 'ERROR: config value rejected: contains control characters.\n' >&2
    return 1
  fi

  local out="$value"
  out="${out//\\/\\\\}"
  out="${out//\"/\\\"}"
  out="${out//\$/\\\$}"
  out="${out//\`/\\\`}"

  printf '%s' "$out"
}

# Return 0 if KEY is an allowed scalar project-config key.
dce_config_is_scalar_key() {
  local key="$1"
  local k=""
  for k in "${_DC_CONFIG_SCALAR_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# Return 0 if KEY is an allowed array project-config key.
dce_config_is_array_key() {
  local key="$1"
  local k=""
  for k in "${_DC_CONFIG_ARRAY_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# Return 0 if NAME is a supported container backend identifier.
dce_config_is_known_backend() {
  local name="$1"
  local b=""
  for b in "${_DC_KNOWN_BACKENDS[@]}"; do
    [[ "$b" == "$name" ]] && return 0
  done
  return 1
}

# Return 0 (true) if PATH is group- or other-writable. Uses single-bit -perm
# checks (portable across GNU and BSD find) combined with -o so either bit trips.
dce_path_is_group_or_other_writable() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  [[ -n "$(find "$path" -maxdepth 0 \( -perm -020 -o -perm -002 \) -print 2>/dev/null)" ]]
}

# Echo the octal permission bits of a file (e.g. "600") for portable re-application.
# Tries GNU `stat -c %a` then BSD/macOS `stat -f %Lp` (same fallback-chain idiom as
# dce_sha256_hex), so the same call works on Linux, macOS, and WSL2. Returns 1 if
# neither stat dialect is available; callers should fall back to 600 (the canonical
# project-config mode written by new-container.sh).
dce_file_mode_octal() {
  local file="$1"
  local mode=""
  mode="$(stat -c %a "$file" 2>/dev/null || true)"
  if [[ -n "$mode" ]]; then
    printf '%s' "$mode"
    return 0
  fi
  mode="$(stat -f %Lp "$file" 2>/dev/null || true)"
  if [[ -n "$mode" ]]; then
    printf '%s' "$mode"
    return 0
  fi
  return 1
}

# Scan the content of a double-quoted value and return 0 if an UNESCAPED command
# substitution token ($ or backtick) is present. Escaped forms (\$, \`) are
# treated as literal data and ignored, since the serializer emits those for any
# real $/backtick in a value. This is the guard that lets us source safely.
dce_quoted_has_unescaped_subst() {
  local content="$1"
  local i=0
  local len=${#content}
  local ch=""
  local escaped=0

  for ((i = 0; i < len; i++)); do
    ch="${content:i:1}"
    if [[ "$escaped" -eq 1 ]]; then
      escaped=0
      continue
    fi
    # shellcheck disable=SC1003
    # '\' is a literal single-backslash comparison (valid in single quotes).
    if [[ "$ch" == '\' ]]; then
      escaped=1
      continue
    fi
    if [[ "$ch" == '$' || "$ch" == '`' ]]; then
      return 0
    fi
  done

  return 1
}

# Validate one line of a project config against the strict assignment grammar.
# Returns 0 if the line is blank, a (non-continuing) comment, or a known
# KEY="value" / KEY=(array) assignment with no unescaped command substitution.
# Returns 1 (reject) for unknown keys, bare shell syntax, or dangerous tokens.
dce_config_line_is_safe() {
  local line="$1"

  # Blank / whitespace-only line.
  [[ -z "${line//[[:space:]]/}" ]] && return 0

  # Comment line. Reject a trailing backslash, which would continue the comment
  # onto the next line and could hide a payload after the comment.
  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    # shellcheck disable=SC1003
    # *'\' tests whether the line ends with a literal backslash.
    [[ "$line" != *'\' ]]
    return $?
  fi

  # Must be a KEY=... assignment with an uppercase identifier key.
  if [[ ! "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
    return 1
  fi

  local key="${BASH_REMATCH[1]}"
  local rest="${BASH_REMATCH[2]}"

  if dce_config_is_array_key "$key"; then
    # Array assignment must be wrapped in (...).
    [[ "${rest:0:1}" == "(" ]] || return 1
    [[ "${rest: -1}" == ")" ]] || return 1
    # Array elements are emitted with printf '%q'; reject any shell metacharacter
    # that %q output never produces, as it would indicate hand-crafted content.
    case "$rest" in
      *'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*) return 1 ;;
    esac
    return 0
  fi

  if dce_config_is_scalar_key "$key"; then
    # Scalar must be a single, well-formed double-quoted string (handles escaped
    # quotes/backslashes). This also rejects trailing content after the closing
    # quote, e.g. KEY="x"; rm -rf /.
    if [[ ! "$rest" =~ ^\"([^\"\\]|\\.)*\"$ ]]; then
      return 1
    fi
    local content="${rest#\"}"
    content="${content%\"}"
    if dce_quoted_has_unescaped_subst "$content"; then
      return 1
    fi
    return 0
  fi

  # Unknown key.
  return 1
}

# Validate the values loaded from a project config (called after sourcing, while
# the variables are in scope). Prints a diagnostic and returns 1 (does NOT exit)
# on any out-of-contract value: security-critical file/line checks are handled
# earlier by dce_load_project_config via dce_die, but value problems are left to
# the caller so maintenance commands (e.g. `dce clean`) can skip a bad project
# without aborting the whole run.
dce_validate_config_values() {
  local config_file="$1"

  if ! dce_validate_cpus_value "${CONTAINER_CPUS:-}" >&2; then
    printf '  in %s\n' "$config_file" >&2
    return 1
  fi

  if ! dce_validate_memory_value "${CONTAINER_MEMORY:-}" >&2; then
    printf '  in %s\n' "$config_file" >&2
    return 1
  fi

  if [[ -n "${CONTAINER_BACKEND:-}" ]]; then
    if ! dce_config_is_known_backend "${CONTAINER_BACKEND}"; then
      printf 'ERROR: Unsupported CONTAINER_BACKEND in %s: %s\n' "$config_file" "${CONTAINER_BACKEND}" >&2
      return 1
    fi
  fi

  # CONTAINER_GIT_HOST selects the git-host provider (github/gitlab). Absent is
  # valid (defaults to github via dce_project_git_host); a present value must be
  # a known provider id so a typo fails at load time, not silently mid-auth.
  if [[ -n "${CONTAINER_GIT_HOST:-}" ]]; then
    if ! dce_git_host_is_known "${CONTAINER_GIT_HOST}"; then
      printf 'ERROR: Unsupported CONTAINER_GIT_HOST in %s: %s\n' "$config_file" "${CONTAINER_GIT_HOST}" >&2
      return 1
    fi
  fi

  if [[ -n "${CONTAINER_PROJECT:-}" ]]; then
    if [[ ! "${CONTAINER_PROJECT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      printf 'ERROR: Invalid CONTAINER_PROJECT in %s: %s\n' "$config_file" "${CONTAINER_PROJECT}" >&2
      return 1
    fi
  fi

  if [[ -n "${CONTAINER_IMAGE:-}" ]]; then
    if [[ ! "${CONTAINER_IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then
      printf 'ERROR: Invalid CONTAINER_IMAGE in %s: %s\n' "$config_file" "${CONTAINER_IMAGE}" >&2
      return 1
    fi
  fi

  if [[ -n "${CONTAINER_OVERLAY_SCOPES:-}" ]]; then
    if ! dce_normalize_scopes_csv "${CONTAINER_OVERLAY_SCOPES}" >/dev/null 2>&1; then
      printf 'ERROR: Invalid CONTAINER_OVERLAY_SCOPES in %s: %s\n' "$config_file" "${CONTAINER_OVERLAY_SCOPES}" >&2
      return 1
    fi
  fi

  local port=""
  if declare -p PORTS >/dev/null 2>&1; then
    for port in "${PORTS[@]}"; do
      [[ -z "$port" ]] && continue
      if [[ ! "$port" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
        printf 'ERROR: Invalid port mapping in %s: %s (expected N or N:N)\n' "$config_file" "$port" >&2
        return 1
      fi
    done
  fi

  if declare -p CONTAINER_HIDDEN_PATHS >/dev/null 2>&1 && [[ ${#CONTAINER_HIDDEN_PATHS[@]} -gt 0 ]]; then
    if ! dce_normalize_hidden_paths_values "${CONTAINER_HIDDEN_PATHS[@]}" >/dev/null 2>&1; then
      printf 'ERROR: Invalid CONTAINER_HIDDEN_PATHS in %s.\n' "$config_file" >&2
      return 1
    fi
  fi

  # Each persisted network entry is "<name>" or "<name>:<ipv4>". Names and IPs are
  # validated independently; an invalid entry is rejected rather than reaching the
  # backend create/connect flags.
  if declare -p CONTAINER_NETWORKS >/dev/null 2>&1 && [[ ${#CONTAINER_NETWORKS[@]} -gt 0 ]]; then
    local nentry=""
    local nname=""
    local nip=""
    for nentry in "${CONTAINER_NETWORKS[@]}"; do
      [[ -n "$nentry" ]] || continue
      if [[ "$nentry" == *:* ]]; then
        nname="${nentry%%:*}"
        nip="${nentry#*:}"
      else
        nname="$nentry"
        nip=""
      fi
      if ! dce_validate_network_name "$nname"; then
        printf 'ERROR: Invalid network name in CONTAINER_NETWORKS entry %q in %s\n' "$nentry" "$config_file" >&2
        return 1
      fi
      if [[ -n "$nip" ]]; then
        if ! dce_validate_ip_value "$nip" >&2; then
          printf '  in CONTAINER_NETWORKS entry %q in %s\n' "$nentry" "$config_file" >&2
          return 1
        fi
      fi
    done
  fi

  # Persisted paths must be absolute and free of control characters.
  local path_key=""
  local path_val=""
  for path_key in REPOS_DIR SECRET_DIR SSH_KEY_PATH TOKEN_FILE NPMRC_PATH; do
    path_val="${!path_key:-}"
    [[ -n "$path_val" ]] || continue
    if [[ "$path_val" != /* ]]; then
      printf 'ERROR: Invalid %s in %s: must be an absolute path (%s)\n' "$path_key" "$config_file" "$path_val" >&2
      return 1
    fi
    if [[ "$path_val" =~ [[:cntrl:]] ]]; then
      printf 'ERROR: Invalid %s in %s: contains control characters (%s)\n' "$path_key" "$config_file" "$path_val" >&2
      return 1
    fi
  done

  return 0
}

# Load a project config file through the hardened, single path. Validates file
# safety (regular file, not a symlink, not group/other-writable) and line shape
# (known keys, no shell syntax or unescaped command substitution) BEFORE sourcing,
# then validates the loaded values. On success the config keys are set as globals
# in the caller's scope and it returns 0. Security violations (file/line shape)
# exit via dce_die; value violations return 1 so callers under `set -e` exit while
# maintenance commands can choose to skip a bad project.
dce_load_project_config() {
  local config_file="$1"

  [[ -n "$config_file" ]] || dce_die "dce_load_project_config: config file path required"

  if [[ -L "$config_file" ]]; then
    dce_die "Refusing to load config via symlink: $config_file"
  fi
  if [[ ! -f "$config_file" ]]; then
    dce_die "Config file not found: $config_file"
  fi

  local parent=""
  parent="$(dirname "$config_file")"
  if dce_path_is_group_or_other_writable "$config_file"; then
    dce_die "Refusing to load group/other-writable config: $config_file
  Fix with: chmod 600 \"$config_file\""
  fi
  if dce_path_is_group_or_other_writable "$parent"; then
    dce_die "Refusing to load config from group/other-writable directory: $parent
  Fix with: chmod 700 \"$parent\""
  fi

  local line=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ! dce_config_line_is_safe "$line"; then
      dce_die "Unsafe or invalid line in config $config_file:
  $line
Only blank lines, comments, and known KEY=\"value\" assignments are allowed."
    fi
  done < "$config_file"

  # Reset optional arrays so a config lacking them (or a prior load) doesn't leak
  # stale values; plain assignments sourced below become globals automatically.
  PORTS=()
  CONTAINER_HIDDEN_PATHS=()
  CONTAINER_NETWORKS=()

  # shellcheck disable=SC1090
  source "$config_file"

  dce_validate_config_values "$config_file" || return 1
}

# Extract a single double-quoted scalar value for KEY from a config file WITHOUT
# executing anything: pure line + escape-aware parsing. Used for the global config
# (DC_TEAM_DIR / DC_USER_DIR) and anywhere only one key is needed, so call sites
# never have to `source`. Echoes the literal (unescaped) value; returns 1 if not
# found or not a clean quoted assignment.
dce_config_extract_scalar() {
  local file="$1"
  local key="$2"
  local line=""
  local raw=""
  local content=""
  local i=0
  local ch=""
  local escaped=0
  local out=""

  [[ -f "$file" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Match only the requested key as a full identifier (anchored word boundary).
    [[ "$line" =~ ^[[:space:]]*${key}= ]] || continue

    raw="${line#*=}"
    if [[ "$raw" != \"*\" ]]; then
      return 1
    fi
    content="${raw#\"}"
    content="${content%\"}"

    # Inverse of dce_escape_config_value: interpret backslash escapes literally.
    out=""
    escaped=0
    for ((i = 0; i < ${#content}; i++)); do
      ch="${content:i:1}"
      if [[ "$escaped" -eq 1 ]]; then
        out+="$ch"
        escaped=0
        continue
      fi
      # shellcheck disable=SC1003
      # '\' is a literal single-backslash comparison (valid in single quotes).
      if [[ "$ch" == '\' ]]; then
        escaped=1
        continue
      fi
      out+="$ch"
    done

    printf '%s' "$out"
    return 0
  done < "$file"

  return 1
}

# Set or replace a single KEY="value" line in a project config file safely.
# Rewrites via a temp file and atomic mv, serializing the value through the shared
# dce_escape_config_value helper (escapes backslash/quote/$/backtick, rejects
# control characters) so the value round-trips inertly through dce_load_project_config.
# Appends the key if absent. Preserves the original file's permission bits (mv does
# not, so without this the rewrite would relax 600 -> umask default).
dce_set_config_key() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  local escaped=""
  escaped="$(dce_escape_config_value "$value")" || return 1

  local orig_mode=""
  orig_mode="$(dce_file_mode_octal "$config_file" 2>/dev/null || true)"

  local tmp_file="${config_file}.tmp.$$"
  local updated=0
  local line=""

  : > "$tmp_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then
      printf '%s="%s"\n' "$key" "$escaped" >> "$tmp_file"
      updated=1
    else
      printf '%s\n' "$line" >> "$tmp_file"
    fi
  done < "$config_file"

  if [[ "$updated" -eq 0 ]]; then
    printf '%s="%s"\n' "$key" "$escaped" >> "$tmp_file"
  fi

  chmod "${orig_mode:-600}" "$tmp_file"
  mv "$tmp_file" "$config_file"
}

# Replace (or append) an array assignment line `KEY=(...)` in a project config.
# Elements are serialized with `printf '%q'` exactly as new-container.sh emits
# them, so the result round-trips inertly through dce_load_project_config. An empty
# element list writes `KEY=()`. Uses mktemp (not a PID-based name) for the atomic
# rewrite. Preserves the original file's permission bits (see dce_set_config_key).
# Returns non-zero if the temp file cannot be created.
dce_set_config_array() {
  local config_file="$1"
  local key="$2"
  shift 2

  local orig_mode=""
  orig_mode="$(dce_file_mode_octal "$config_file" 2>/dev/null || true)"

  local tmp_file=""
  tmp_file="$(mktemp "${config_file}.tmp.XXXXXX")" || return 1
  local updated=0
  local line=""

  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$key="* ]]; then
        if [[ "$updated" -eq 0 ]]; then
          printf '%s=(' "$key"
          if [[ $# -gt 0 ]]; then
            printf ' %q' "$@"
          fi
          printf ' )\n'
        fi
        updated=1
      else
        printf '%s\n' "$line"
      fi
    done < "$config_file"
    if [[ "$updated" -eq 0 ]]; then
      printf '%s=(' "$key"
      if [[ $# -gt 0 ]]; then
        printf ' %q' "$@"
      fi
      printf ' )\n'
    fi
  } > "$tmp_file"

  chmod "${orig_mode:-600}" "$tmp_file"
  mv "$tmp_file" "$config_file"
}
