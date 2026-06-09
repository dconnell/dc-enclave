#!/usr/bin/env sh
set -eu

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Git ──────────────────────────────────────────────────────────────────────
# Symlinks gitconfig to ~/.gitconfig (user.name, user.email, personal aliases)
setup_git() {
  src="$DOTFILES_DIR/gitconfig"
  dest="$HOME/.gitconfig"

  if [ ! -f "$src" ]; then
    echo "[dotfiles] Skipping git: $src not found"
    return 0
  fi

  if [ -L "$dest" ]; then
    echo "[dotfiles] git: $dest already symlinked"
    return 0
  fi

  if [ -f "$dest" ]; then
    echo "[dotfiles] git: $dest exists (not overwriting); backing up to $dest.bak"
    mv "$dest" "$dest.bak"
  fi

  ln -s "$src" "$dest"
  echo "[dotfiles] git: linked $dest -> $src"
}

# ── Vim ──────────────────────────────────────────────────────────────────────
# Symlinks vimrc to ~/.vimrc
setup_vim() {
  src="$DOTFILES_DIR/vimrc"
  dest="$HOME/.vimrc"

  if [ ! -f "$src" ]; then
    echo "[dotfiles] Skipping vim: $src not found"
    return 0
  fi

  if [ -L "$dest" ]; then
    echo "[dotfiles] vim: $dest already symlinked"
    return 0
  fi

  if [ -f "$dest" ]; then
    echo "[dotfiles] vim: $dest exists (not overwriting); backing up to $dest.bak"
    mv "$dest" "$dest.bak"
  fi

  ln -s "$src" "$dest"
  echo "[dotfiles] vim: linked $dest -> $src"
}

# ── Zsh ──────────────────────────────────────────────────────────────────────
# Appends personal additions to ~/.zshrc (idempotent — checks for marker)
setup_zsh() {
  src="$DOTFILES_DIR/zshrc-additions"
  dest="$HOME/.zshrc"
  marker="# >>> dotfiles-managed >>>"

  if [ ! -f "$src" ]; then
    echo "[dotfiles] Skipping zsh: $src not found"
    return 0
  fi

  if [ -f "$dest" ] && grep -qF "$marker" "$dest" 2>/dev/null; then
    echo "[dotfiles] zsh: additions already present in $dest"
    return 0
  fi

  {
    echo ""
    echo "$marker"
    cat "$src"
    echo "# <<< dotfiles-managed <<<"
  } >> "$dest"

  echo "[dotfiles] zsh: appended additions to $dest"
}

# ── Run all modules ──────────────────────────────────────────────────────────
setup_git
setup_vim
setup_zsh

echo "[dotfiles] Done."
exit 0
