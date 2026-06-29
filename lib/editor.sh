#!/usr/bin/env bash
# =============================================================================
# lib/editor.sh - Editor registry + cross-platform launcher.
#
# Everything that differs per editor lives HERE as data, not scattered as
# hardcoded constants across scripts. An editor is a short id ("vscode",
# "vscode-insiders"); each field is returned by dce_editor_field.
#
# Adding an editor = adding lines to dce_editor_known_ids and the relevant
# case branches below. Nothing editor-specific leaks outside this file.
#
# v1 ships the VS Code family (vscode + vscode-insiders). They share the
# vscode-remote attached-container URI scheme and the --folder-uri flag, so
# one adapter (dce_editor_launch_attach) covers both; only binary discovery
# differs. Future editors (Cursor, Windsurf, VSCodium) reuse the same scheme;
# truly different editors (Zed, JetBrains) would need their own adapter.
# =============================================================================

# Auto-source deps if this lib is loaded directly (single-import convenience),
# mirroring the idiom in lib/devcontainer.sh / lib/vscode.sh.
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_editor_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_editor_lib_dir/common.sh"
  unset _dce_editor_lib_dir
fi

if [[ -z "${_DC_PLATFORM_SH_LOADED:-}" ]]; then
  _dce_editor_platform_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_editor_platform_lib_dir/platform.sh"
  unset _dce_editor_platform_lib_dir
fi

if [[ -n "${_DC_EDITOR_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_EDITOR_SH_LOADED=1

# Canonical id for an alias. The selection resolver accepts a few common
# spellings users are likely to set in $EDITOR / $DCE_EDITOR (the binary name
# "code", "code-insiders") and normalizes them to the registry id. Anything
# else passes through unchanged (and is then validated against
# dce_editor_known_ids by the caller).
dce_editor_normalize_id() {
  local raw="$1"
  case "$raw" in
    code)             printf 'vscode' ;;
    code-insiders)    printf 'vscode-insiders' ;;
    *)                printf '%s' "$raw" ;;
  esac
}

# Echo every known editor id, one per line. Mirrors dce_git_host_known_providers
# in lib/git-host.sh. Adding an editor = adding a line here.
dce_editor_known_ids() {
  printf 'vscode\nvscode-insiders\n'
}

# Return 0 if ID is a known editor id, 1 otherwise. Mirrors
# dce_git_host_is_known in lib/git-host.sh.
dce_editor_is_known() {
  local id="$1"
  local known=""
  known="$(dce_editor_known_ids)"
  # Whole-line comparison so a substring cannot match.
  while IFS= read -r known; do
    [[ "$known" == "$id" ]] && return 0
  done <<< "$known"
  return 1
}

# Echo the default editor id. Used when no override resolves. VS Code is the
# only editor with a built-in "attach to running container" CLI in widespread
# use, and the existing seed in lib/vscode.sh is VS Code-centric.
dce_editor_default() {
  printf 'vscode'
}

# Read DCE_EDITOR from the global config (best-effort). Absent or unparseable
# yields empty + return 0 so callers can fall through cleanly. Uses the shared,
# no-source scalar extractor (the same one scripts/setup.sh uses for
# DC_TEAM_DIR / DC_USER_DIR), so a hand-edited global config cannot execute
# code through this lookup.
_dce_editor_read_global() {
  local cfg=""
  cfg="$(dce_global_config_path)"
  [[ -f "$cfg" ]] || return 0
  local val=""
  val="$(dce_config_extract_scalar "$cfg" DCE_EDITOR 2>/dev/null || true)"
  printf '%s' "$val"
}

# Resolve the active editor id by precedence. Each step's value is normalized
# and validated before being accepted.
#
#   1. $1 (explicit --editor value, if non-empty)        -> hard error if unknown
#   2. $DCE_EDITOR environment variable                  -> hard error if unknown
#   3. DCE_EDITOR in global config                       -> hard error if unknown
#   4. $VISUAL                                          -> warn+skip if unknown
#   5. $EDITOR                                          -> warn+skip if unknown
#   6. default (vscode)
#
# The asymmetric failure mode is intentional: an explicit dce-chosen value
# (--editor or DCE_EDITOR) is a statement of intent and a typo should fail
# loudly. $VISUAL/$EDITOR are general-purpose env vars shared with many other
# tools (often set to a terminal editor like nano/vim), so an unknown value
# there is warned about and skipped rather than breaking the command.
dce_editor_select() {
  local explicit="${1:-}"
  local val="" norm=""

  # 1. explicit --editor
  if [[ -n "$explicit" ]]; then
    norm="$(dce_editor_normalize_id "$explicit")"
    if dce_editor_is_known "$norm"; then
      printf '%s' "$norm"
      return 0
    fi
    dce_die "Unknown editor '$explicit'.
  Known editors: $(tr '\n' ' ' <<<"$(dce_editor_known_ids)")"
  fi

  # 2. $DCE_EDITOR env
  val="${DCE_EDITOR:-}"
  if [[ -n "$val" ]]; then
    norm="$(dce_editor_normalize_id "$val")"
    if dce_editor_is_known "$norm"; then
      printf '%s' "$norm"
      return 0
    fi
    dce_die "Unknown editor '$val' in \$DCE_EDITOR.
  Known editors: $(tr '\n' ' ' <<<"$(dce_editor_known_ids)")"
  fi

  # 3. DCE_EDITOR in global config
  val="$(_dce_editor_read_global)"
  if [[ -n "$val" ]]; then
    norm="$(dce_editor_normalize_id "$val")"
    if dce_editor_is_known "$norm"; then
      printf '%s' "$norm"
      return 0
    fi
    dce_die "Unknown editor '$val' in DCE_EDITOR (~/.config/dce-enclave/config).
  Known editors: $(tr '\n' ' ' <<<"$(dce_editor_known_ids)")"
  fi

  # 4. $VISUAL
  val="${VISUAL:-}"
  if [[ -n "$val" ]]; then
    norm="$(dce_editor_normalize_id "$val")"
    if dce_editor_is_known "$norm"; then
      printf '%s' "$norm"
      return 0
    fi
    dce_warn "Ignoring unknown \$VISUAL value '$val' (not a dce editor id)."
  fi

  # 5. $EDITOR
  val="${EDITOR:-}"
  if [[ -n "$val" ]]; then
    norm="$(dce_editor_normalize_id "$val")"
    if dce_editor_is_known "$norm"; then
      printf '%s' "$norm"
      return 0
    fi
    dce_warn "Ignoring unknown \$EDITOR value '$val' (not a dce editor id)."
  fi

  # 6. default
  dce_editor_default
}

# Full lowercase hex encoding of the input bytes. Pure bash, no new dependency.
# Used to build the VS Code attached-container URI token.
dce_editor_hex_encode() {
  local raw="$1"
  local i=0 ch ord hex=""
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    ord=$(printf '%d' "'$ch" 2>/dev/null || printf '0')
    printf -v hex '%02x' "$ord"
    printf '%s' "$hex"
  done
}

# Build the VS Code "attached-container" folder URI for a container name +
# in-container workspace path. Format:
#
#   vscode-remote://attached-container+<hex>/<workspace_path>
#
# <hex> is the full lowercase hex encoding of "/<container_name>". The leading
# "/" is the Docker namespace prefix VS Code keys on; it must be part of the
# encoded identifier, not stripped. This is a DIFFERENT encoding from
# dce_vscode_encode_attach_key in lib/vscode.sh (which is filename-safe partial
# encoding for VS Code's nameConfigs storage). The two helpers are related but
# not interchangeable; both must agree on the input container name.
dce_editor_vscode_attached_container_uri() {
  local container_name="$1"
  local workspace="${2:-/workspace}"
  local hex=""
  hex="$(dce_editor_hex_encode "/$container_name")"
  printf 'vscode-remote://attached-container+%s%s' "$hex" "$workspace"
}

# Resolve the editor binary path. Returns 0 and echoes the path on success,
# 1 (silent) when no candidate is found.
#
# Discovery order per editor id + platform_os:
#   1. $DCE_EDITOR_BIN override (applies regardless of editor id)
#   2. editor-specific CLI on PATH
#   3. macOS .app bundle fallback
#
# On WSL2 we prefer the Windows binary (.exe via WSL interop) over the Linux
# one because that matches the dominant Docker Desktop + Dev Containers WSL
# setup. The Linux binary is the fallback so a user running Linux VS Code
# inside WSL still works.
dce_editor_find_binary() {
  local editor="$1"

  # 1. explicit override (single knob in v1; applies to any editor id)
  if [[ -n "${DCE_EDITOR_BIN:-}" ]]; then
    if [[ -x "${DCE_EDITOR_BIN}" ]]; then
      printf '%s' "$DCE_EDITOR_BIN"
      return 0
    fi
    # Non-executable override is a hard error: the user told us exactly where
    # the binary is, so a silent fall-through would mask a broken setting.
    dce_die "DCE_EDITOR_BIN='$DCE_EDITOR_BIN' is not executable."
  fi

  local os=""
  os="$(platform_os)"

  case "$editor" in
    vscode)
      case "$os" in
        wsl2)
          command -v code.exe >/dev/null 2>&1 && { command -v code.exe; return 0; }
          command -v code >/dev/null 2>&1 && { command -v code; return 0; }
          ;;
        macos)
          command -v code >/dev/null 2>&1 && { command -v code; return 0; }
          [[ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]] \
            && { printf '%s' "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; return 0; }
          ;;
        linux|*)
          command -v code >/dev/null 2>&1 && { command -v code; return 0; }
          ;;
      esac
      ;;
    vscode-insiders)
      case "$os" in
        wsl2)
          command -v code-insiders.exe >/dev/null 2>&1 && { command -v code-insiders.exe; return 0; }
          command -v code-insiders >/dev/null 2>&1 && { command -v code-insiders; return 0; }
          ;;
        macos)
          command -v code-insiders >/dev/null 2>&1 && { command -v code-insiders; return 0; }
          [[ -x "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders" ]] \
            && { printf '%s' "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code-insiders"; return 0; }
          ;;
        linux|*)
          command -v code-insiders >/dev/null 2>&1 && { command -v code-insiders; return 0; }
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac

  return 1
}

# Launch the editor attached to a running container's workspace.
#
# All VS Code-family editors share the vscode-remote attached-container URI
# scheme and the --folder-uri flag, so one adapter covers them; only binary
# discovery differs (delegated to dce_editor_find_binary).
#
# Uses `exec` so the launched editor replaces this process. VS Code's CLI
# forks and returns immediately (the editor runs in its own process group),
# so the user gets their prompt back without us having to background anything.
# If a future editor's CLI blocks instead, that adapter gets its own launcher.
dce_editor_launch_attach() {
  local editor="$1"
  local project="$2"
  local workspace="${3:-/workspace}"

  local binary=""
  if ! binary="$(dce_editor_find_binary "$editor")"; then
    local hint=""
    case "$(platform_os)" in
      macos)
        hint="On macOS: run VS Code's \"Install 'code' command in PATH\" command from the Command Palette, or set DCE_EDITOR_BIN=/path/to/code"
        ;;
      wsl2)
        hint="On WSL2: ensure 'code.exe' (Windows VS Code) or 'code' (Linux VS Code) is on PATH, or set DCE_EDITOR_BIN=/path/to/code"
        ;;
      *)
        hint="Ensure 'code' is on PATH, or set DCE_EDITOR_BIN=/path/to/code"
        ;;
    esac
    dce_die "Editor binary not found for '$editor'.
  $hint"
  fi

  local uri=""
  uri="$(dce_editor_vscode_attached_container_uri "$project" "$workspace")"

  printf '  Launching editor (%s) attached to: %s\n' "$editor" "$project"
  exec "$binary" --folder-uri "$uri"
}
