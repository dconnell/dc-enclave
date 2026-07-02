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

# Render the dce-managed remoteEnv block for attach-mode PAT auth. This uses
# Git's runtime config env (GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n /
# GIT_CONFIG_VALUE_n) so editor/terminal processes attached by VS Code ignore
# VS Code's own host-forwarding credential.helper and instead see the same
# `credential.helper = ""` + `store` chain dce shell/start configure. The PAT
# itself remains in ~/.git-credentials; these env vars only select the helper.
_dce_vscode_pat_remote_env_json() {
  cat <<'EOF'
{
  "GIT_CONFIG_COUNT": "2",
  "GIT_CONFIG_KEY_0": "credential.helper",
  "GIT_CONFIG_VALUE_0": "",
  "GIT_CONFIG_KEY_1": "credential.helper",
  "GIT_CONFIG_VALUE_1": "store"
}
EOF
}

# Full JSON for a fresh attached-container named config. The workspace folder is
# JSON-escaped defensively (the current caller always passes /workspace, but this
# helper is a public API and should never emit broken JSON for an unusual path).
_dce_vscode_render_named_attach_config() {
  local workspace_folder="$1"
  local auth_method="$2"
  local ws_esc=""
  ws_esc="$(dce_json_escape "$workspace_folder")"

  if [[ "$auth_method" == "pat" ]]; then
    cat <<EOF
{
  "workspaceFolder": "$ws_esc",
  "remoteEnv": {
    "GIT_CONFIG_COUNT": "2",
    "GIT_CONFIG_KEY_0": "credential.helper",
    "GIT_CONFIG_VALUE_0": "",
    "GIT_CONFIG_KEY_1": "credential.helper",
    "GIT_CONFIG_VALUE_1": "store"
  }
}
EOF
  else
    cat <<EOF
{
  "workspaceFolder": "$ws_esc"
}
EOF
  fi
}

# jq path: merge the dce-managed fields into an existing attached-container
# config, preserving user-authored keys. Managed scope:
#   - workspaceFolder          always synced to <workspace_folder>
#   - remoteEnv GIT_CONFIG_*   present only for PAT auth; removed otherwise
_dce_vscode_sync_named_attach_config_jq() {
  local file="$1"
  local workspace_folder="$2"
  local auth_method="$3"

  local orig_mode=""
  orig_mode="$(dce_file_mode_octal "$file" 2>/dev/null || true)"
  local tmp_file=""
  tmp_file="$(mktemp "${file}.tmp.XXXXXX")" || return 1

  local pat_remote_env_json='{}'
  if [[ "$auth_method" == "pat" ]]; then
    pat_remote_env_json="$(_dce_vscode_pat_remote_env_json)"
  fi

  if ! jq \
      --arg ws "$workspace_folder" \
      --arg auth "$auth_method" \
      --argjson patEnv "$pat_remote_env_json" '
      .workspaceFolder = $ws
      | if $auth == "pat" then
          .remoteEnv = ((.remoteEnv // {}) + $patEnv)
        else
          .remoteEnv = ((.remoteEnv // {})
            | del(.GIT_CONFIG_COUNT,
                  .GIT_CONFIG_KEY_0, .GIT_CONFIG_VALUE_0,
                  .GIT_CONFIG_KEY_1, .GIT_CONFIG_VALUE_1))
        end
      | if (.remoteEnv // {}) == {} then del(.remoteEnv) else . end
    ' "$file" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    return 1
  fi

  chmod "${orig_mode:-600}" "$tmp_file"
  mv "$tmp_file" "$file"
}

# No-jq fallback for existing attached-container configs. Safe/limited by
# design: it updates workspaceFolder, inserts the managed remoteEnv block when
# PAT auth is requested and no remoteEnv exists yet, and otherwise warns+leaves
# the file untouched when a structural merge would be unsafe without JSON
# tooling. This keeps the common no-remoteEnv case working while avoiding a
# lossy rewrite of user-authored attached-container settings.
_dce_vscode_sync_named_attach_config_fallback() {
  local file="$1"
  local workspace_folder="$2"
  local auth_method="$3"

  local orig_mode=""
  orig_mode="$(dce_file_mode_octal "$file" 2>/dev/null || true)"
  local tmp_file=""
  tmp_file="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  local ws_json=""
  ws_json="$(dce_json_escape "$workspace_folder")"

  if grep -Eq '"workspaceFolder"[[:space:]]*:' "$file" 2>/dev/null; then
    awk -v ws="$ws_json" '
      BEGIN { done=0 }
      {
        if (!done && $0 ~ /"workspaceFolder"[[:space:]]*:/) {
          sub(/"workspaceFolder"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"workspaceFolder\": \"" ws "\"")
          done=1
        }
        print
      }
    ' "$file" > "$tmp_file"
  else
    rm -f "$tmp_file"
    dce_warn "Attached-container config lacks workspaceFolder; install jq to sync managed fields safely: $file"
    return 2
  fi

  if [[ "$auth_method" != "pat" ]]; then
    if grep -Eq '"GIT_CONFIG_(COUNT|KEY_0|VALUE_0|KEY_1|VALUE_1)"' "$tmp_file" 2>/dev/null; then
      if ! awk '
          {
            lines[NR]=$0
            if ($0 ~ /"remoteEnv"[[:space:]]*:[[:space:]]*{/) {
              in_remote=1
              block_start=NR
            } else if (in_remote && $0 ~ /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/) {
              block_end=NR
              in_remote=0
            } else if (in_remote) {
              if ($0 ~ /"GIT_CONFIG_(COUNT|KEY_0|VALUE_0|KEY_1|VALUE_1)"/) {
                managed[NR]=1
              } else if ($0 !~ /^[[:space:]]*$/) {
                keep[NR]=1
                keep_count++
              }
            }
          }
          END {
            if (block_start == 0 || block_end == 0) exit 1

            if (keep_count == 0) {
              prev=block_start-1
              while (prev > 0 && lines[prev] ~ /^[[:space:]]*$/) prev--
              next_i=block_end+1
              while (next_i <= NR && lines[next_i] ~ /^[[:space:]]*$/) next_i++
              if (prev > 0 && next_i <= NR && lines[next_i] ~ /^[[:space:]]*}[[:space:]]*$/) {
                sub(/,[[:space:]]*$/, "", lines[prev])
              }
              for (i = 1; i < block_start; i++) print lines[i]
              for (i = block_end + 1; i <= NR; i++) print lines[i]
              exit 0
            }

            last_keep=0
            for (i = block_start + 1; i < block_end; i++) if (keep[i]) last_keep=i
            for (i = 1; i <= NR; i++) {
              if (i > block_start && i < block_end && managed[i]) continue
              line = lines[i]
              if (i == last_keep) sub(/,[[:space:]]*$/, "", line)
              print line
            }
          }
        ' "$tmp_file" > "${tmp_file}.2"; then
        rm -f "$tmp_file" "${tmp_file}.2"
        return 1
      fi
      mv "${tmp_file}.2" "$tmp_file"
    fi
    chmod "${orig_mode:-600}" "$tmp_file"
    mv "$tmp_file" "$file"
    return 0
  fi

  if grep -Eq '"remoteEnv"[[:space:]]*:' "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    dce_warn "Existing attached-container config has remoteEnv; install jq to merge managed Git overrides safely: $file"
    return 2
  fi

  if ! awk '
      { lines[NR]=$0 }
      END {
        last=NR
        while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
        if (last == 0 || lines[last] !~ /^[[:space:]]*}[[:space:]]*$/) exit 1
        prev=last-1
        while (prev > 0 && lines[prev] ~ /^[[:space:]]*$/) prev--
        if (prev > 0 && lines[prev] !~ /^[[:space:]]*{[[:space:]]*$/ && lines[prev] !~ /,[[:space:]]*$/) {
          lines[prev]=lines[prev] ","
        }
        for (i = 1; i < last; i++) print lines[i]
        print "  \"remoteEnv\": {"
        print "    \"GIT_CONFIG_COUNT\": \"2\"," 
        print "    \"GIT_CONFIG_KEY_0\": \"credential.helper\"," 
        print "    \"GIT_CONFIG_VALUE_0\": \"\"," 
        print "    \"GIT_CONFIG_KEY_1\": \"credential.helper\"," 
        print "    \"GIT_CONFIG_VALUE_1\": \"store\""
        print "  }"
        print lines[last]
        for (i = last + 1; i <= NR; i++) print lines[i]
      }
    ' "$tmp_file" > "${tmp_file}.2"; then
    rm -f "$tmp_file" "${tmp_file}.2"
    return 1
  fi

  mv "${tmp_file}.2" "$tmp_file"
  chmod "${orig_mode:-600}" "$tmp_file"
  mv "$tmp_file" "$file"
}

# Seed (or sync) the VS Code named-attach config for a container so attach mode
# lands in /workspace and, for PAT auth, attached editor/terminal processes use
# Git's `store` helper via remoteEnv (rather than VS Code's host-forwarding
# helper). Existing user-authored fields are preserved when jq is available; the
# no-jq fallback safely handles the common "no remoteEnv yet" case.
dce_vscode_seed_named_attach_config() {
  local container_name="$1"
  local workspace_folder="${2:-/workspace}"
  local auth_method="${3:-}"
  local encoded_name=""
  local storage_dir=""
  local config_dir=""
  local config_file=""

  encoded_name="$(dce_vscode_encode_attach_key "$container_name")"

  while IFS= read -r storage_dir; do
    [[ -z "$storage_dir" ]] && continue

    config_dir="$storage_dir/nameConfigs"
    config_file="$config_dir/${encoded_name}.json"

    if [[ ! -f "$config_file" ]]; then
      if ! mkdir -p "$config_dir"; then
        dce_warn "Unable to create VS Code attach config directory: $config_dir"
        continue
      fi

      if ! _dce_vscode_render_named_attach_config "$workspace_folder" "$auth_method" > "$config_file"; then
        dce_warn "Unable to write VS Code attach config: $config_file"
        continue
      fi

      printf '%s\n' "$config_file"
      continue
    fi

    if command -v jq >/dev/null 2>&1; then
      if _dce_vscode_sync_named_attach_config_jq "$config_file" "$workspace_folder" "$auth_method"; then
        printf '%s\n' "$config_file"
        continue
      fi
    fi

    if _dce_vscode_sync_named_attach_config_fallback "$config_file" "$workspace_folder" "$auth_method"; then
      printf '%s\n' "$config_file"
      continue
    fi

    rc=$?
    case "$rc" in
      2)
        # Warning already emitted by the fallback; do not print a misleading
        # success path.
        continue
        ;;
      *)
        if command -v jq >/dev/null 2>&1; then
          dce_warn "Unable to merge VS Code attach config (invalid JSON or unsupported no-jq fallback case): $config_file"
        else
          dce_warn "Unable to update VS Code attach config without jq: $config_file"
        fi
        continue
        ;;
    esac
  done < <(dce_vscode_remote_containers_storage_dirs)
}
