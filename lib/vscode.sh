#!/usr/bin/env bash
# =============================================================================
# lib/vscode.sh - VS Code "attach to running container" config helpers.
#
# Used by every backend (docker-compatible AND apple/container). When a
# container is created or rebuilt, we seed VS Code's per-container "named
# attach" config so "Attach to Running Container" (and apple/container's
# "Attach to Running Apple Container") lands in the right workspace across
# image rebuilds/re-tags. Existing configs are preserved. Managed fields:
#   - workspaceFolder          always /workspace
#   - remoteEnv PS1            always; gives attached terminals the same
#                              "[project]" prompt as `dce shell`
#   - remoteEnv GIT_CONFIG_*   PAT auth only (Git credential-helper overrides)
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

# Full JSON for a fresh attached-container named config. The workspace folder
# and the PS1 project prompt are JSON-escaped defensively (container names are
# restricted to [A-Za-z0-9._-], so the escape is a no-op in practice, but this
# helper is a public API and should never emit broken JSON).
# The managed PS1 gives VS Code attached terminals the same "[project]" prompt
# as `dce shell` in every auth mode.
_dce_vscode_render_named_attach_config() {
  local workspace_folder="$1"
  local auth_method="$2"
  local container_name="${3:-}"
  local ws_esc=""
  ws_esc="$(dce_json_escape "$workspace_folder")"
  local ps1_esc=""
  ps1_esc="$(dce_json_escape "[${container_name}] %~ %# ")"

  if [[ "$auth_method" == "pat" ]]; then
    cat <<EOF
{
  "workspaceFolder": "$ws_esc",
  "remoteEnv": {
    "PS1": "$ps1_esc",
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
  "workspaceFolder": "$ws_esc",
  "remoteEnv": {
    "PS1": "$ps1_esc"
  }
}
EOF
  fi
}

# jq path: merge the dce-managed fields into an existing attached-container
# config, preserving user-authored keys. Managed scope:
#   - workspaceFolder          always synced to <workspace_folder>
#   - remoteEnv PS1            always synced to "[<container_name>] %~ %# "
#   - remoteEnv GIT_CONFIG_*   present only for PAT auth; removed otherwise
_dce_vscode_sync_named_attach_config_jq() {
  local file="$1"
  local workspace_folder="$2"
  local auth_method="$3"
  local container_name="${4:-}"

  local orig_mode=""
  orig_mode="$(dce_file_mode_octal "$file" 2>/dev/null || true)"
  local tmp_file=""
  tmp_file="$(mktemp "${file}.tmp.XXXXXX")" || return 1

  # Fully-quoted JSON string for the managed PS1 value; escaped via
  # dce_json_escape and passed as argjson so no double-escaping occurs.
  local ps1_json=""
  ps1_json="\"$(dce_json_escape "[${container_name}] %~ %# ")\""

  local pat_remote_env_json='{}'
  if [[ "$auth_method" == "pat" ]]; then
    pat_remote_env_json="$(_dce_vscode_pat_remote_env_json)"
  fi

  if ! jq \
      --arg ws "$workspace_folder" \
      --arg auth "$auth_method" \
      --argjson ps1 "$ps1_json" \
      --argjson patEnv "$pat_remote_env_json" '
      .workspaceFolder = $ws
      | .remoteEnv = ((.remoteEnv // {}) + {PS1: $ps1})
      | if $auth == "pat" then
          .remoteEnv = (.remoteEnv + $patEnv)
        else
          .remoteEnv |= del(.GIT_CONFIG_COUNT,
                .GIT_CONFIG_KEY_0, .GIT_CONFIG_VALUE_0,
                .GIT_CONFIG_KEY_1, .GIT_CONFIG_VALUE_1)
        end
      | if (.remoteEnv // {}) == {} then del(.remoteEnv) else . end
    ' "$file" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    return 1
  fi

  chmod "${orig_mode:-600}" "$tmp_file"
  mv "$tmp_file" "$file"
}

# No-jq fallback for existing attached-container configs. Limited by design:
# it updates workspaceFolder; inserts a managed remoteEnv block when none
# exists (PS1 in every auth mode, plus the GIT_CONFIG_* Git overrides for PAT);
# and for non-PAT auth with an existing block, removes stale GIT_CONFIG_* keys
# and ensures exactly one managed PS1 line. When a structural merge would be
# unsafe without JSON tooling (existing remoteEnv + PAT auth) it warns and
# leaves the file untouched rather than lossily rewriting user-authored
# attached-container settings.
_dce_vscode_sync_named_attach_config_fallback() {
  local file="$1"
  local workspace_folder="$2"
  local auth_method="$3"
  local container_name="${4:-}"

  local orig_mode=""
  orig_mode="$(dce_file_mode_octal "$file" 2>/dev/null || true)"
  local tmp_file=""
  tmp_file="$(mktemp "${file}.tmp.XXXXXX")" || return 1
  local ws_json=""
  ws_json="$(dce_json_escape "$workspace_folder")"
  local ps1_json=""
  ps1_json="$(dce_json_escape "[${container_name}] %~ %# ")"
  # Managed remoteEnv entry, emitted with a trailing comma; consumers strip it
  # when the entry lands last in the block.
  local ps1_line=""
  ps1_line="    \"PS1\": \"${ps1_json}\","

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

  if grep -Eq '"remoteEnv"[[:space:]]*:' "$tmp_file" 2>/dev/null; then
    if [[ "$auth_method" == "pat" ]]; then
      rm -f "$tmp_file"
      dce_warn "Existing attached-container config has remoteEnv; install jq to merge managed Git overrides safely: $file"
      return 2
    fi

    # Non-PAT with existing remoteEnv: drop stale GIT_CONFIG_* lines, keep user
    # keys (blank lines inside the block are dropped), and append the managed
    # PS1 entry if absent. Commas are normalized so the emitted JSON stays
    # valid; the block can never end up empty because PS1 is always ensured.
    # The opener regex requires the brace to end its line, so inline shapes
    # like "remoteEnv": { "FOO": "bar" } or "remoteEnv": {}, stay unmatched,
    # block_start remains 0, and the rewrite bails below instead of corrupting
    # the surrounding JSON. Interior lines ending in an opening brace/bracket
    # (hand-edited nested object/array) also bail: the closer regex would match
    # the inner closer and truncate the block.
    if ! awk -v ps1_line="$ps1_line" '
        {
          lines[NR]=$0
          if ($0 ~ /"remoteEnv"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/) {
            in_remote=1
            block_start=NR
          } else if (in_remote && $0 ~ /^[[:space:]]*}[[:space:]]*,?[[:space:]]*$/) {
            block_end=NR
            in_remote=0
          } else if (in_remote) {
            if ($0 ~ /[{[][[:space:]]*$/) {
              # Nested object/array: unsafe to rewrite; bail untouched.
              unsafe=1
            } else if ($0 ~ /"GIT_CONFIG_(COUNT|KEY_0|VALUE_0|KEY_1|VALUE_1)"/) {
              # Dropped: stale managed Git overrides (not marked keep).
            } else if ($0 ~ /"PS1"[[:space:]]*:/) {
              has_ps1=1
              keep[NR]=1
            } else if ($0 !~ /^[[:space:]]*$/) {
              keep[NR]=1
            }
          }
        }
        END {
          if (block_start == 0 || block_end == 0 || unsafe) exit 1
          n=0
          for (i = block_start + 1; i < block_end; i++) if (keep[i]) kept[++n]=i
          total=n
          if (!has_ps1) total=n+1
          for (j = 1; j <= n; j++) out[j]=lines[kept[j]]
          if (!has_ps1) out[total]=ps1_line
          for (j = 1; j <= total; j++) {
            if (j < total) {
              sub(/[[:space:]]*$/, "", out[j])
              if (out[j] !~ /,$/) out[j]=out[j] ","
            } else {
              sub(/,[[:space:]]*$/, "", out[j])
            }
          }
          for (i = 1; i <= block_start; i++) print lines[i]
          for (j = 1; j <= total; j++) print out[j]
          for (i = block_end; i <= NR; i++) print lines[i]
        }
      ' "$tmp_file" > "${tmp_file}.2"; then
      rm -f "$tmp_file" "${tmp_file}.2"
      return 1
    fi
    mv "${tmp_file}.2" "$tmp_file"
  else
    # No remoteEnv yet: insert a managed block before the closing brace.
    if ! awk -v ps1_line="$ps1_line" -v pat="$([[ "$auth_method" == "pat" ]] && printf '1' || printf '0')" '
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
          if (pat == 1) {
            print ps1_line
            print "    \"GIT_CONFIG_COUNT\": \"2\","
            print "    \"GIT_CONFIG_KEY_0\": \"credential.helper\","
            print "    \"GIT_CONFIG_VALUE_0\": \"\","
            print "    \"GIT_CONFIG_KEY_1\": \"credential.helper\","
            print "    \"GIT_CONFIG_VALUE_1\": \"store\""
          } else {
            sub(/,[[:space:]]*$/, "", ps1_line)
            print ps1_line
          }
          print "  }"
          print lines[last]
          for (i = last + 1; i <= NR; i++) print lines[i]
        }
      ' "$tmp_file" > "${tmp_file}.2"; then
      rm -f "$tmp_file" "${tmp_file}.2"
      return 1
    fi
    mv "${tmp_file}.2" "$tmp_file"
  fi

  chmod "${orig_mode:-600}" "$tmp_file"
  mv "$tmp_file" "$file"
}

# Seed (or sync) the VS Code named-attach config for a container so attach mode
# lands in /workspace and attached editor/terminal processes get a managed
# remoteEnv PS1 ("[<container_name>] %~ %# "), giving them the same "[project]"
# prompt as `dce shell`. For PAT auth the remoteEnv additionally selects Git's
# `store` helper (rather than VS Code's host-forwarding helper). Existing
# user-authored fields are preserved when jq is available; without jq the
# fallback covers the safe cases and leaves anything else untouched.
dce_vscode_seed_named_attach_config() {
  local container_name="$1"
  local workspace_folder="${2:-/workspace}"
  local auth_method="${3:-}"
  local encoded_name=""
  local storage_dir=""
  local config_dir=""
  local config_file=""
  local rc=""

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

      if ! _dce_vscode_render_named_attach_config "$workspace_folder" "$auth_method" "$container_name" > "$config_file"; then
        dce_warn "Unable to write VS Code attach config: $config_file"
        continue
      fi

      printf '%s\n' "$config_file"
      continue
    fi

    if command -v jq >/dev/null 2>&1; then
      if _dce_vscode_sync_named_attach_config_jq "$config_file" "$workspace_folder" "$auth_method" "$container_name"; then
        printf '%s\n' "$config_file"
        continue
      fi
    fi

    if _dce_vscode_sync_named_attach_config_fallback "$config_file" "$workspace_folder" "$auth_method" "$container_name"; then
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
