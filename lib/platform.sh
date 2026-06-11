#!/usr/bin/env bash
# Platform and shell-profile policy helpers.

if [[ -n "${_DC_PLATFORM_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_PLATFORM_SH_LOADED=1

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

platform_bash_profile() {
  if [[ "$(platform_os)" == "macos" ]]; then
    printf '%s/.bash_profile' "$HOME"
  else
    printf '%s/.bashrc' "$HOME"
  fi
}
