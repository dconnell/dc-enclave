#!/usr/bin/env bash
# =============================================================================
# lib/common/core.sh - Foundation helpers shared by every dce host script.
#
# Sourced (never executed directly) via lib/common.sh. Lowest-level module: no
# internal dce_* dependencies, so any other common/ module may call into it.
# Exposes the always-on error/diagnostic helpers, the canonical string-join and
# path-resolution primitives, the cross-platform SHA-256 helpers, and the
# filesystem-safe project-slug derivation used by volume / snapshot naming.
# =============================================================================

if [[ -n "${_DC_COMMON_CORE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_CORE_SH_LOADED=1

# Print an error message to stderr and exit non-zero. Standard failure path.
dce_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Print a non-fatal warning to stderr.
dce_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

# Join positional arguments with the given separator (first arg). Echoes the
# result without a trailing newline; empty args are preserved as empty fields.
dce_join_by() {
  local separator="$1"
  shift

  local out=""
  local item=""
  for item in "$@"; do
    if [[ -n "$out" ]]; then
      out+="$separator"
    fi
    out+="$item"
  done

  printf '%s' "$out"
}

# Canonicalize a path to an absolute, symlink-resolved form. Works for both
# existing directories and not-yet-existing file paths (resolving the parent).
dce_resolve_path() {
  local input="$1"

  if [[ -d "$input" ]]; then
    (cd -P "$input" && pwd)
    return $?
  fi

  local parent=""
  parent="$(cd -P "$(dirname "$input")" && pwd)" || return 1
  printf '%s/%s\n' "$parent" "$(basename "$input")"
}

# Echo the SHA-256 hex digest of a string.
#
# Tries sha256sum (Linux), shasum (macOS default), then openssl, so the same
# code works across all supported host platforms without extra dependencies.
dce_sha256_hex() {
  local input="$1"
  local digest=""

  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$input" | sha256sum)"
    printf '%s\n' "${digest%% *}"
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$input" | shasum -a 256)"
    printf '%s\n' "${digest%% *}"
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s' "$input" | openssl dgst -sha256 -r)"
    printf '%s\n' "${digest%% *}"
    return 0
  fi

  dce_die "No SHA-256 tool available (sha256sum, shasum, or openssl required)."
}

# Echo the SHA-256 hex digest of a file's raw bytes.
#
# Companion to dce_sha256_hex for the cases (provenance fingerprints) where the
# input is a file and every byte -- including trailing newlines -- must count.
# Same tool fallback chain as dce_sha256_hex so it works on every supported host.
dce_sha256_file() {
  local file="$1"
  local digest=""

  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$file")"
    printf '%s\n' "${digest%% *}"
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "$file")"
    printf '%s\n' "${digest%% *}"
    return 0
  fi

  if command -v openssl >/dev/null 2>&1; then
    digest="$(openssl dgst -sha256 -r "$file")"
    printf '%s\n' "${digest%% *}"
    return 0
  fi

  dce_die "No SHA-256 tool available (sha256sum, shasum, or openssl required)."
}

# Echo the SHA-256 hex digest of stdin (raw bytes). stdin-based companion to
# dce_sha256_hex: use it to hash a secret by piping (`printf ... |
# _dce_sha256_stdin`) so the value is never placed in an argv or a shell
# variable. Same tool fallback chain as the other hash helpers.
_dce_sha256_stdin() {
  local digest=""
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum)"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256)"
  elif command -v openssl >/dev/null 2>&1; then
    digest="$(openssl dgst -sha256 -r)"
  else
    dce_die "No SHA-256 tool available (sha256sum, shasum, or openssl required)."
  fi
  printf '%s\n' "${digest%% *}"
}

# Derive a filesystem-safe slug from a project name (lowercased, non-alnum
# collapsed to '-', trimmed, capped at 24 chars). Used to build volume names.
dce_project_slug() {
  local project="$1"
  local project_slug="${project,,}"

  project_slug="${project_slug//[^a-z0-9]/-}"
  while [[ "$project_slug" == *--* ]]; do
    project_slug="${project_slug//--/-}"
  done
  project_slug="${project_slug#-}"
  project_slug="${project_slug%-}"
  [[ -n "$project_slug" ]] || project_slug="project"
  project_slug="${project_slug:0:24}"

  printf '%s\n' "$project_slug"
}
