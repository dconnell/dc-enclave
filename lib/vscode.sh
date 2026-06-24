#!/usr/bin/env bash
# =============================================================================
# lib/vscode.sh - VS Code "attach to running container" config helpers.
#
# Only Docker-compatible backends use this. When a container is created or
# rebuilt, we seed VS Code's per-container "named attach" config
# (workspaceFolder=/workspace) so "Attach to Running Container" lands in the
# right workspace across image rebuilds/re-tags. Existing configs are preserved.
# =============================================================================

# Auto-source deps if this lib is loaded directly (single-import convenience).
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_vscode_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_vscode_lib_dir/common.sh"
  unset _dce_vscode_lib_dir
fi

if [[ -z "${_DC_PLATFORM_SH_LOADED:-}" ]]; then
  _dce_vscode_platform_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_vscode_platform_lib_dir/platform.sh"
  unset _dce_vscode_platform_lib_dir
fi

if [[ -n "${_DC_VSCODE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_VSCODE_SH_LOADED=1

# Print candidate VS Code Remote-Containers globalStorage dirs for this OS.
# Covers both stable and Insiders installs; callers filter to existing ones.
dce_vscode_remote_containers_storage_candidates() {
  case "$(platform_os)" in
    macos)
      printf '%s\n' \
        "$HOME/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers" \
        "$HOME/Library/Application Support/Code - Insiders/User/globalStorage/ms-vscode-remote.remote-containers"
      ;;
    linux|wsl2)
      printf '%s\n' \
        "$HOME/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers" \
        "$HOME/.config/Code - Insiders/User/globalStorage/ms-vscode-remote.remote-containers"
      ;;
  esac
}

# Return the candidate storage dirs that look "live enough" to write into -
# i.e. the storage dir, its parent, or the User dir already exists. Writing a
# nameConfig subdir only makes sense once VS Code has been run at least once.
dce_vscode_remote_containers_storage_dirs() {
  local candidate=""
  local parent=""
  local user_dir=""

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    parent="$(dirname "$candidate")"
    user_dir="$(dirname "$parent")"
    if [[ -d "$candidate" || -d "$parent" || -d "$user_dir" ]]; then
      printf '%s\n' "$candidate"
    fi
  done < <(dce_vscode_remote_containers_storage_candidates)
}

# URL-encode a container name into the key VS Code uses for its per-container
# attach config file (e.g. "/" -> "%2f"). Only encodes the few characters that
# appear in container names and are unsafe in filenames.
dce_vscode_encode_attach_key() {
  local raw_name="$1"
  local name="${raw_name#/}"
  local encoded=""
  local i=0
  local ch=""

  for ((i = 0; i < ${#name}; i++)); do
    ch="${name:i:1}"
    case "$ch" in
      ':')
        encoded+="%3a"
        ;;
      '/')
        encoded+="%2f"
        ;;
      '%')
        encoded+="%25"
        ;;
      *)
        encoded+="$ch"
        ;;
    esac
  done

  printf '%s\n' "$encoded"
}

# Seed (or check) the VS Code named-attach config for a container so "Attach to
# Running Container" opens /workspace. Creates the config if missing, warns (and
# leaves it untouched) if it exists with a different workspaceFolder. Echoes
# each config file path touched/found.
dce_vscode_seed_named_attach_config() {
  local container_name="$1"
  local workspace_folder="${2:-/workspace}"
  local encoded_name=""
  local storage_dir=""
  local config_dir=""
  local config_file=""
  local existing_workspace=""

  encoded_name="$(dce_vscode_encode_attach_key "$container_name")"

  while IFS= read -r storage_dir; do
    [[ -z "$storage_dir" ]] && continue

    config_dir="$storage_dir/nameConfigs"
    config_file="$config_dir/${encoded_name}.json"

    if [[ -f "$config_file" ]]; then
      existing_workspace="$(grep -Eo '"workspaceFolder"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null || true)"
      if [[ "$existing_workspace" != *"\"$workspace_folder\""* ]]; then
        dce_warn "Named attach config exists with a different workspaceFolder: $config_file"
      fi
      printf '%s\n' "$config_file"
      continue
    fi

    if ! mkdir -p "$config_dir"; then
      dce_warn "Unable to create VS Code attach config directory: $config_dir"
      continue
    fi

    if ! cat > "$config_file" <<EOF
{
  "workspaceFolder": "$workspace_folder"
}
EOF
    then
      dce_warn "Unable to write VS Code attach config: $config_file"
      continue
    fi

    printf '%s\n' "$config_file"
  done < <(dce_vscode_remote_containers_storage_dirs)
}
