#!/usr/bin/env zsh
# =============================================================================
# install-dotfiles.sh — Install or update dotfiles in a running container
#
# Usage:
#   install-dotfiles.sh <project-name> <path-to-dotfiles>
#
# Copies the dotfiles directory into the container and runs its install script.
# Safe to re-run — idempotent if the install script is idempotent.
#
# Example:
#   dc install myapp ~/.dotfiles
#   dc install myapp /Users/you/repos/dotfiles
# =============================================================================
set -euo pipefail

PROJECT="${1:?Usage: install-dotfiles.sh <project-name> <path-to-dotfiles>}"
DOTFILES_SRC="${2:?Usage: install-dotfiles.sh <project-name> <path-to-dotfiles>}"

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG="$ROOT_DIR/projects/$PROJECT/config"
BACKEND_LIB="$ROOT_DIR/lib/container-backend.sh"

if [[ ! -f "$BACKEND_LIB" ]]; then
  echo "ERROR: Backend library not found at $BACKEND_LIB"
  exit 1
fi

source "$BACKEND_LIB"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: No config for '$PROJECT'."
  exit 1
fi

source "$CONFIG"
backend_use "${CONTAINER_BACKEND:-}"

DOTFILES_SRC="${DOTFILES_SRC:A}"

if [[ ! -d "$DOTFILES_SRC" ]]; then
  echo "ERROR: Dotfiles directory not found: $DOTFILES_SRC"
  exit 1
fi

INSTALL_CMD=""
if [[ -f "$DOTFILES_SRC/install.sh" ]]; then
  INSTALL_CMD="install.sh"
else
  echo "ERROR: No install.sh found in $DOTFILES_SRC"
  exit 1
fi

if ! backend_is_running "$PROJECT"; then
  echo "ERROR: Container '$PROJECT' is not running."
  echo "  Start it first: dc start $PROJECT"
  exit 1
fi

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

echo "  ✓ Dotfiles installed"
