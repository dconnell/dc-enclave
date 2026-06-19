#!/usr/bin/env bash
# =============================================================================
# lib/platform.sh - Host platform and shell-profile helpers.
#
# Small policy layer for deciding which OS we're on and which shell profile
# file setup.sh should edit. Sourced (never executed directly).
# =============================================================================

# Include guard (see common.sh for the same pattern).
if [[ -n "${_DC_PLATFORM_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_PLATFORM_SH_LOADED=1

# Echo the host platform class: macos, linux, wsl2, or unknown.
# WSL2 is detected via the microsoft marker in /proc/version even though uname
# reports Linux, since bind-mount and backend behavior differs there.
platform_os() {
  case "$(uname -s)" in
    Darwin)
      printf 'macos'
      ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        printf 'wsl2'
      else
        printf 'linux'
      fi
      ;;
    *)
      printf 'unknown'
      ;;
  esac
}

# Echo the user's login shell (basename of $SHELL, lowercased), defaulting to
# bash when $SHELL is unset. This is the right signal for which rc file to
# edit: $SHELL is the login shell, which is what reads the rc file at startup
# (NOT the shell setup.sh happens to run under -- a bash user can invoke
# setup.sh from a zsh session and vice versa).
platform_user_shell() {
  local sh="${SHELL:-}"
  sh="${sh##*/}"
  sh="${sh:-bash}"
  # Lowercase portably (platform.sh is sourced under bash; ${sh:l} is zsh-only).
  sh="$(printf '%s' "$sh" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$sh"
}

# Echo the interactive rc/profile file for a given shell. Profiles are chosen by
# shell, not by OS: macOS defaults to zsh, so platform-driven .bash_profile
# selection was wrong for most Mac users. Mapping:
#   zsh  -> ~/.zshrc            (interactive rc, read by all zsh setups)
#   bash -> ~/.bash_profile on macOS, ~/.bashrc elsewhere (login-rc convention)
#   *    -> bash profile as a safe fallback (completion only ships for zsh/bash)
platform_profile_file() {
  local shell="${1:-$(platform_user_shell)}"
  case "$shell" in
    zsh)
      printf '%s/.zshrc' "$HOME"
      ;;
    bash)
      platform_bash_profile
      ;;
    *)
      platform_bash_profile
      ;;
  esac
}

# Echo the bash profile path setup.sh should modify. macOS login bash shells
# read ~/.bash_profile; Linux/WSL2 read ~/.bashrc. Retained for back-compat;
# new code should use platform_profile_file "$(platform_user_shell)".
platform_bash_profile() {
  if [[ "$(platform_os)" == "macos" ]]; then
    printf '%s/.bash_profile' "$HOME"
  else
    printf '%s/.bashrc' "$HOME"
  fi
}
