#!/usr/bin/env bash
# =============================================================================
# scripts/install-dotfiles.sh - `dce install`: apply personal dotfiles into a
# running container. Streams the dotfiles dir into the container via tar, runs
# its install.sh as the dev user, then removes the temp copy. Re-run after any
# rebuild to restore personal config.
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

CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
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
backend_exec "$PROJECT" zsh -c "cd $REMOTE_DIR && ./$INSTALL_CMD"

backend_exec "$PROJECT" rm -rf "$REMOTE_DIR"

# Also (re)wire git auth from this project's configured credential, so a
# post-rebuild `dce install` restores working `git pull` alongside dotfiles.
dce_ensure_git_credentials "$PROJECT"

echo "  ✓ Dotfiles installed"
echo "  ✓ Git credentials installed"
