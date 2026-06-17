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

# Echo the shell profile path setup.sh should modify. macOS login shells read
# ~/.bash_profile; Linux/WSL2 read ~/.bashrc.
platform_bash_profile() {
  if [[ "$(platform_os)" == "macos" ]]; then
    printf '%s/.bash_profile' "$HOME"
  else
    printf '%s/.bashrc' "$HOME"
  fi
}
