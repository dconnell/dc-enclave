#!/usr/bin/env bash
# =============================================================================
# scripts/rotate-token.sh - `dce rotate-token`: push the project's current host
# git token (PAT) into a container, state-preserving and idempotent.
#
# Run this right after editing the host token file
# (~/.config/dce-enclave/<name>/<host>-token) to refresh the container's
# ~/.git-credentials without a full rebuild. It force-writes the current token
# (overwriting a stale or compromised value) and re-wires git auth, leaving all
# container state (packages, caches, running processes) untouched.
#
# This is the lightweight, state-preserving counterpart to:
#   - `dce rebuild-container --rotate-keys` (regenerates the SSH deploy key;
#     rebuild-bound, incident response), and
#   - `dce rebuild-container --from-snap --inject-creds` (force-injects current
#     credentials into a restored snapshot).
# Under ssh/none auth there is no PAT to push, so it reports and exits 0.
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: rotate-token.sh <project-name>}"

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
if [[ ! -f "$CONFIG" ]]; then
  dce_die "No config for '$PROJECT'."
fi

dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"

# No PAT configured -> nothing to push. Fail fast without touching the container.
METHOD="$(dce_git_auth_method)"
if [[ "$METHOD" != "pat" ]]; then
  echo "rotate-token: '$PROJECT' uses '$METHOD' auth (no PAT configured). Nothing to do."
  echo "  To regenerate the SSH deploy key instead: dce rebuild-container $PROJECT --rotate-keys"
  exit 0
fi

if ! backend_is_running "$PROJECT"; then
  echo "==> Starting stopped container '$PROJECT' to refresh its token..."
  backend_start "$PROJECT"
fi

echo "==> Refreshing git token in '$PROJECT'..."
# Force: overwrite ~/.git-credentials when it differs from the current host token
# (idempotent -- no rewrite when already current). The token crosses the
# host/container boundary via a stdin pipe, never host argv.
dce_ensure_git_credentials "$PROJECT" force

echo "  ✓ Token refreshed"
echo "  Verify with: dce doctor $PROJECT"
