#!/usr/bin/env bash
# =============================================================================
# scripts/install-dotfiles.sh - `dce install`: apply personal dotfiles into a
# running container. Streams the dotfiles dir into the container via tar, wires
# git credentials, then runs its install.sh as the dev user with the provider's
# token env var (GITHUB_TOKEN / GITLAB_TOKEN) exported when set -- so install
# scripts that clone/pull private repos work on the first run, before any
# `dce shell`. Afterwards removes the temp copy. Re-run after any rebuild to
# restore personal config.
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: install-dotfiles.sh <project-name> <path-to-dotfiles>}"
DOTFILES_SRC="${2:?Usage: install-dotfiles.sh <project-name> <path-to-dotfiles>}"

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

CONFIG="$(dce_project_config_path "$PROJECT")"
if [[ ! -f "$CONFIG" ]]; then
  dce_die "No config for '$PROJECT'."
fi

dce_load_project_config "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"

DOTFILES_SRC="$(dce_resolve_path "$DOTFILES_SRC")" || {
  dce_die "Dotfiles path could not be resolved: $DOTFILES_SRC"
}

if [[ ! -d "$DOTFILES_SRC" ]]; then
  dce_die "Dotfiles directory not found: $DOTFILES_SRC"
fi

INSTALL_CMD=""
if [[ -f "$DOTFILES_SRC/install.sh" ]]; then
  INSTALL_CMD="install.sh"
else
  dce_die "No install.sh found in $DOTFILES_SRC"
fi

if ! backend_is_running "$PROJECT"; then
  dce_die "Container '$PROJECT' is not running.
  Start it first: dce start $PROJECT"
fi

# Read the project's git token (skipping comments and the provider placeholder)
# via the shared helper so the filtering logic lives in one place. Empty = unset.
# ENV_VAR is the provider's shell env-var name (GITHUB_TOKEN / GITLAB_TOKEN);
# install.sh runs with it exported so PAT-needing steps work on the first run.
GIT_TOKEN="$(dce_read_git_token)"
ENV_VAR="$(dce_git_host_field "$(dce_project_git_host)" env_var)"

# Wire git auth BEFORE install.sh runs: a first-run install.sh often does git
# clone/pull and needs the PAT already in ~/.git-credentials, so `dce install`
# is consistent with `dce shell`. Idempotent; the PAT, if any, crosses via
# stdin inside the helper. Default mode: only-if-missing (forensics-safe).
echo "==> Configuring git in container..."
dce_ensure_git_credentials "$PROJECT"

# Seed the token into a short-lived file inside the container over stdin, so the
# token value never appears in host process argv (readable via ps / /proc).
# The raw value is written (not a shell assignment) and read back via command
# substitution in the wrapper, so token-file metacharacters are never executed;
# the file is deleted before install.sh is exec'd and best-effort removed again
# on exit/interrupt -- including when install.sh fails under set -e.
_dce_token_env_file=""

_dce_seed_token_file() {
  _dce_token_env_file="$(backend_exec "$PROJECT" mktemp "/tmp/dce-git-token.XXXXXX")"
  backend_exec "$PROJECT" chmod 600 "$_dce_token_env_file"
  # shellcheck disable=SC2016
  # sh -c runs in the container; $1 expands in that inner shell, not here.
  printf '%s' "$GIT_TOKEN" \
    | backend_exec_stdin "$PROJECT" sh -c 'cat >"$1"' _ "$_dce_token_env_file"
}

_dce_cleanup_token_file() {
  if [[ -n "$_dce_token_env_file" ]]; then
    backend_exec "$PROJECT" rm -f "$_dce_token_env_file" 2>/dev/null || true
  fi
}
# Best-effort cleanup on normal exit or interrupt; never let a failed cleanup
# mask the install result.
trap '_dce_cleanup_token_file' EXIT INT TERM

# Stream the dotfiles into a temp dir inside the container (no host path
# coupling), make install.sh executable, run it, then clean up.
REMOTE_DIR="/tmp/dotfiles-$$"

echo "==> Installing dotfiles into '$PROJECT'..."
echo "  Source: $DOTFILES_SRC"

echo "  Copying dotfiles into container..."
backend_exec "$PROJECT" mkdir -p "$REMOTE_DIR"
tar -C "$DOTFILES_SRC" -cf - . | backend_exec_stdin "$PROJECT" tar -x -C "$REMOTE_DIR" -f -
backend_exec "$PROJECT" chmod +x "$REMOTE_DIR/$INSTALL_CMD"

echo "  Running $INSTALL_CMD..."
if [[ -n "$GIT_TOKEN" ]]; then
  echo "  ${ENV_VAR}: available to $INSTALL_CMD"
  _dce_seed_token_file
  # shellcheck disable=SC2016
  # sh -c runs in the container; $1/$2 and $(cat) expand in the inner shell.
  # $2 is the env-var NAME (registry-controlled), exported with the value read
  # from the temp file ($1); the value never touches host argv. The file is
  # removed before install.sh is exec'd.
  backend_exec "$PROJECT" sh -c 'export "$2=$(cat "$1")"; rm -f "$1"; exec zsh -c "cd $3 && ./$4"' \
    _ "$_dce_token_env_file" "$ENV_VAR" "$REMOTE_DIR" "$INSTALL_CMD"
else
  backend_exec "$PROJECT" zsh -c "cd $REMOTE_DIR && ./$INSTALL_CMD"
fi

backend_exec "$PROJECT" rm -rf "$REMOTE_DIR"

# Reconcile the project's hosts fragment into /etc/hosts so a fresh fragment
# edit lands without needing a shell/start round-trip (idempotent; no-op
# without a fragment).
dce_ensure_container_hosts "$PROJECT"

echo "  ✓ Dotfiles installed"
echo "  ✓ Git credentials wired"
