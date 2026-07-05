#!/usr/bin/env bash
# =============================================================================
# lib/common.sh - Facade over lib/common/*.sh shared helper modules.
#
# Sourced (never executed directly) by every script under scripts/. This file is
# the single public entry: it enforces the Bash 4+ requirement, guards against
# double-sourcing, defines DC_VERSION, then loads the common/ sub-modules. The
# historical flat layout (one ~2100-line file) has been split by concern; this
# facade preserves the original API verbatim so existing one-liner call sites
# `source "$ROOT_DIR/lib/common.sh"` keep working unchanged.
#
# Module map (sourced in the order shown; bash resolves cross-module function
# calls at invocation time, so the order is logical/convenience, not required):
#   common/core.sh              dce_die/warn, dce_join_by, dce_resolve_path,
#                               dce_sha256_{hex,file,stdin}, dce_project_slug
#   common/timezone.sh          dce_host_timezone + zone-name/localtime helpers
#   common/global-config.sh     team/user root paths + dce_load_global_config
#   common/scopes.sh            overlay scope validation, dce_effective_scopes_csv,
#                               dce_image_ref_from_scopes, dce_image_hash_from_ref
#   common/hidden-volumes.sh    hidden-path normalization + volume lifecycle
#   common/git-credentials.sh   token/PAT/SSH insteadOf wiring + VS Code setting
#   common/snapshots.sh         snapshot image/volume naming + volume manifests
#   common/image-provenance.sh  provenance hashing, JSON escaping, JSONL logging
#   common/config.sh            project config schema, validators, load/write
#
# Key concepts (unchanged from the historical single-file layout):
#   - Overlay scopes  -> see dce_effective_scopes_csv / dce_image_ref_from_scopes
#   - Hidden volumes  -> see dce_hidden_volume_name and friends
#   - Per-project cfg -> ~/.config/dce-enclave/<name>/config (key=value)
# =============================================================================

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "ERROR: DC Enclave requires Bash 4+ (scripts must run under bash)." >&2
  exit 1
fi

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "ERROR: DC Enclave requires Bash 4+ (current: $BASH_VERSION)" >&2
  echo "  macOS: brew install bash" >&2
  exit 1
fi

# Include guard: scripts chain-source lib files; this makes re-sourcing a no-op
# so helpers and globals are defined exactly once per shell.
if [[ -n "${_DC_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_SH_LOADED=1

# Single source of truth for the DC Enclave version. Sourced by every host
# script (via the dce dispatcher and each subcommand), so both `dce --version` and
# any subcommand can read $DC_VERSION. Bump this in the same commit that tags a
# release (e.g. `git tag v0.2.0`) so the embedded string tracks the git tag.
#
# Exported (-grx) rather than just global (-gr): the value is read cross-file by
# dce_log_provenance in lib/common/image-provenance.sh, and ShellCheck analyzes
# each module in isolation (external-sources=false, see .shellcheckrc). Exporting
# documents the cross-cutting intent and silences SC2034 without a directive.
declare -grx DC_VERSION="0.2.0"

# Resolve our own directory once so the module sources below use a stable path
# regardless of how common.sh was reached (script-relative, symlink, etc.).
_dce_common_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the concern-split sub-modules. Each carries its own include guard, so
# they are also safe to source directly from tests that want only one slice.
# shellcheck disable=SC1091
# Sibling lib include; path resolved above, not followed statically.
source "$_dce_common_lib_dir/common/core.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/timezone.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/global-config.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/scopes.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/hidden-volumes.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/git-credentials.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/snapshots.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/image-provenance.sh"
# shellcheck disable=SC1091
source "$_dce_common_lib_dir/common/config.sh"

# Pull in the git-host provider registry (lib/git-host.sh) so the git-auth
# helpers (dce_read_git_token, dce_git_auth_method, dce_ensure_git_credentials,
# dce_validate_config_values) can resolve the active provider's
# host/sentinel/etc. via dce_project_git_host / dce_git_host_field. Sourced AFTER
# this file's own include guard is set, so git-host.sh's auto-source of common.sh
# is a no-op (no recursion). Every script that sources common.sh therefore gets
# the registry transitively.
if [[ -z "${_DC_GIT_HOST_SH_LOADED:-}" ]]; then
  # shellcheck disable=SC1091
  # Sibling lib include; path resolved above, not followed statically.
  source "$_dce_common_lib_dir/git-host.sh"
fi

unset _dce_common_lib_dir
