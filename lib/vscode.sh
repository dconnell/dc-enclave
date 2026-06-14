#!/usr/bin/env bash
# VS Code attached-container configuration helpers.

if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dc_vscode_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_dc_vscode_lib_dir/common.sh"
  unset _dc_vscode_lib_dir
fi

if [[ -z "${_DC_PLATFORM_SH_LOADED:-}" ]]; then
  _dc_vscode_platform_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_dc_vscode_platform_lib_dir/platform.sh"
  unset _dc_vscode_platform_lib_dir
fi

if [[ -n "${_DC_VSCODE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_VSCODE_SH_LOADED=1

dc_vscode_remote_containers_storage_candidates() {
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

dc_vscode_remote_containers_storage_dirs() {
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
  done < <(dc_vscode_remote_containers_storage_candidates)
}

dc_vscode_encode_attach_key() {
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

dc_vscode_seed_named_attach_config() {
  local container_name="$1"
  local workspace_folder="${2:-/workspace}"
  local encoded_name=""
  local storage_dir=""
  local config_dir=""
  local config_file=""
  local existing_workspace=""

  encoded_name="$(dc_vscode_encode_attach_key "$container_name")"

  while IFS= read -r storage_dir; do
    [[ -z "$storage_dir" ]] && continue

    config_dir="$storage_dir/nameConfigs"
    config_file="$config_dir/${encoded_name}.json"

    if [[ -f "$config_file" ]]; then
      existing_workspace="$(grep -Eo '"workspaceFolder"[[:space:]]*:[[:space:]]*"[^"]*"' "$config_file" 2>/dev/null || true)"
      if [[ "$existing_workspace" != *"\"$workspace_folder\""* ]]; then
        dc_warn "Named attach config exists with a different workspaceFolder: $config_file"
      fi
      printf '%s\n' "$config_file"
      continue
    fi

    if ! mkdir -p "$config_dir"; then
      dc_warn "Unable to create VS Code attach config directory: $config_dir"
      continue
    fi

    if ! cat > "$config_file" <<EOF
{
  "workspaceFolder": "$workspace_folder"
}
EOF
    then
      dc_warn "Unable to write VS Code attach config: $config_file"
      continue
    fi

    printf '%s\n' "$config_file"
  done < <(dc_vscode_remote_containers_storage_dirs)
}
