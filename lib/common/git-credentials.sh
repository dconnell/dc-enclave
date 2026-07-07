#!/usr/bin/env bash
# =============================================================================
# lib/common/git-credentials.sh - Git auth wiring (PAT / SSH deploy key).
#
# Sourced (never executed directly) via lib/common.sh. Owns the git-auth
# decision tree for a loaded project config: reads the host token, picks the
# auth method (pat/ssh/none), and idempotently wires url.insteadOf + credential
# store inside the running container, plus the VS Code machine setting that
# routes Source Control through git's helper. The PAT NEVER crosses the
# host/container boundary via argv: it is piped through short-lived sh -c
# invocations and compared by hash only (see tests/contract/security-token-argv.sh).
# Depends on core.sh (_dce_sha256_stdin) and git-host.sh (provider registry);
# backend_* calls resolve via lib/container-backend.sh.
# =============================================================================

if [[ -n "${_DC_COMMON_GIT_CREDENTIALS_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_GIT_CREDENTIALS_SH_LOADED=1

# Read the project's git token from TOKEN_FILE, skipping comments and the
# provider placeholder value so an unfilled token file never leaks its
# sentinel (e.g. "ghp_REPLACE_ME" / "glpat_REPLACE_ME"). Echoes the bare token
# (whitespace-trimmed); echoes nothing when TOKEN_FILE is unset, missing, or
# contains only comments/placeholder. Single source of truth -- shell.sh's
# status display and dce_ensure_git_credentials both read through here.
dce_read_git_token() {
  [[ -n "${TOKEN_FILE:-}" ]] || return 0
  [[ -f "$TOKEN_FILE" ]] || return 0
  local sentinel=""
  sentinel="$(dce_git_host_field "$(dce_project_git_host)" sentinel)"
  # Pattern on a single line: under mawk a multi-line `&&` pattern followed by a
  # newline-prefixed `{` action parses the action as a separate unconditional
  # rule, which would defeat the comment/placeholder filtering below.
  awk -v sentinel="$sentinel" '
    $0 !~ /^#/ && $0 !~ "^"sentinel && $0 ~ /[^[:space:]]/ {
      gsub(/[[:space:]]+/, "", $0)
      print
      exit
    }
  ' "$TOKEN_FILE" 2>/dev/null || true
}

# Back-compat shim: the historical name. Delegates to dce_read_git_token so the
# security-token-argv contract test and any external callers keep working.
# dce_read_git_token is the canonical name; new code uses it.
dce_read_github_token() {
  dce_read_git_token
}

# Decide which git auth method is in effect for the loaded project config.
# PAT wins: a real (non-placeholder) token selects HTTPS+PAT even when an SSH
# deploy key is also present (the default once a user fills in the token file).
# Echoes "pat", "ssh", or "none".
dce_git_auth_method() {
  if [[ -n "$(dce_read_git_token)" ]]; then
    printf 'pat'
    return 0
  fi
  if [[ -n "${SSH_KEY_PATH:-}" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
    printf 'ssh'
    return 0
  fi
  printf 'none'
}

# Inject (or re-inject) the project's SSH deploy key into the container's
# ~/.ssh/id_ed25519, idempotently. No-op when SSH_KEY_PATH is unset or the key
# file is absent on the host.
#
# The path test runs inside the container shell (sh -c) so ~ resolves to the
# dev user's HOME there rather than being expanded on the host before the
# backend ever sees it.
#
# Mode:
#   default (no second arg) -> only-if-missing: skip when the container already
#                              has the key. Forensics-safe; used by start /
#                              snapshot so a restored image isn't rewritten.
#   force                   -> always (over)write. Used by new-container and
#                              rebuild-container (--inject-creds / --rotate-keys).
#
# Git host keys are pinned in the base image; no runtime ssh-keyscan.
dce_inject_ssh_deploy_key() {
  local project="$1"
  local force="${2:-}"

  [[ -n "${SSH_KEY_PATH:-}" ]] || return 0
  [[ -f "$SSH_KEY_PATH" ]] || return 0

  if [[ -z "$force" ]]; then
    # shellcheck disable=SC2016
    # sh -c runs in the container; ~ expands to dev's home there.
    backend_exec "$project" sh -c 'test -f ~/.ssh/id_ed25519' 2>/dev/null && return 0
  fi

  # shellcheck disable=SC2016
  backend_exec "$project" sh -c 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
  # shellcheck disable=SC2016
  backend_exec_stdin "$project" sh -c 'cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519' < "$SSH_KEY_PATH"
}

# Ensure git authentication is wired inside <project>'s container, idempotently.
#
# Replaces the unconditional HTTPS->SSH insteadOf that used to be baked into
# `dce new` / `dce rebuild-container`. The rewrite direction now follows the
# configured credential for the project's git host provider:
#   pat  -> url."https://<web>/".insteadOf "git@<ssh>:"
#           + credential.helper store + ~/.git-credentials (re-injected if missing)
#           + VS Code machine setting (when the provider has one)
#   ssh  -> url."git@<ssh>:".insteadOf "https://<web>/"  (image default for github)
#   none -> no insteadOf; any stale credential state is cleared
# The opposite-direction rule for the active provider is always unset, and any
# stale insteadOf rule from a DIFFERENT provider (including the github rule
# baked into the base image) is also cleared, so a provider switch can never
# leave two opposing rules coexisting.
#
# For PAT auth on a provider that ships a VS Code git-auth setting (github),
# the setting is also written to the container's
# ~/.vscode-server/data/Machine/settings.json so the Source Control panel
# (pull/push/sync) defers to git's credential helper (the PAT in
# ~/.git-credentials) instead of routing through the hoster extension's OAuth
# prompt. This complements the devcontainer.json customizations approach
# (which is only read on (re)attach); the machine settings file is always read
# by the VS Code Server on connect.
#
# The PAT crosses the host/container boundary via a stdin pipe into a short-lived
# sh -c -- never via argv -- preserving the invariant enforced by
# tests/contract/security-token-argv.sh (host `ps`/`/proc` must not see the PAT).
#
# Requires a loaded project config (TOKEN_FILE, SSH_KEY_PATH) and an active,
# running backend. Best-effort: cleanup/unset failures are tolerated.
#
# The optional second argument enables FORCE mode: under PAT, ~/.git-credentials
# is rewritten whenever the current value differs (compare-by-hash, idempotent),
# instead of the default only-if-missing seed. Force mode is the explicit
# "push current credentials" path used by `dce rotate-token` and `dce
# rebuild-container --inject-creds`; the default (unset) preserves the
# forensics-safe only-if-missing behavior relied on by `start`/`shell`/`install`
# so a restored/compromised snapshot's credential state is never silently
# overwritten. The token is never placed in argv or printed -- it is piped into a
# short-lived sh -c and (under force) into the hash comparison.
dce_ensure_git_credentials() {
  local project="$1"
  local force="${2:-}"
  local method=""
  method="$(dce_git_auth_method)"

  local provider=""
  provider="$(dce_project_git_host)"
  local web_host="" ssh_host="" https_user=""
  web_host="$(dce_git_host_field "$provider" web_host)"
  ssh_host="$(dce_git_host_field "$provider" ssh_host)"
  https_user="$(dce_git_host_field "$provider" https_user)"
  local has_vscode_git_auth=""
  has_vscode_git_auth="$(dce_git_host_field "$provider" has_vscode_git_auth)"

  case "$method" in
    pat)
      # HTTPS + PAT: route any SSH host URL through HTTPS and enable the file
      # credential store, then seed ~/.git-credentials if the container lost it
      # (mirroring the SSH deploy-key re-inject in dce start). VS Code may also
      # inject a credential.helper at /etc/gitconfig; reset inherited helpers
      # with an empty helper entry before adding `store` so PAT auth always wins
      # (and terminal git avoids the username/password askpass popup).
      backend_exec "$project" git config --global url."https://${web_host}/".insteadOf "git@${ssh_host}:"
      backend_exec "$project" git config --global --unset-all credential.helper 2>/dev/null || true
      backend_exec "$project" git config --global --add credential.helper ""
      backend_exec "$project" git config --global --add credential.helper store
      backend_exec "$project" git config --global --unset-all url."git@${ssh_host}:".insteadOf 2>/dev/null || true
      _dce_clear_other_provider_insteadof "$project" "$provider"
      if [[ -n "$force" ]]; then
        # Force: rewrite ~/.git-credentials whenever the current value differs
        # (idempotent). Compare by hash so the token is never printed, and pipe
        # both the expected line and the container's current file through the
        # hasher so the token never sits in an argv or a variable.
        local _exp_hash="" _cur_hash=""
        _exp_hash="$(printf 'https://%s:%s@%s\n' "$https_user" "$(dce_read_git_token)" "$web_host" | _dce_sha256_stdin)"
        _cur_hash="$(backend_exec "$project" sh -c 'cat ~/.git-credentials 2>/dev/null' | _dce_sha256_stdin)"
        if [[ "$_exp_hash" != "$_cur_hash" ]]; then
          # shellcheck disable=SC2016
          # sh -c runs in the container; $() and the redirect expand there.
          printf 'https://%s:%s@%s\n' "$https_user" "$(dce_read_git_token)" "$web_host" \
            | backend_exec_stdin "$project" sh -c 'cat > ~/.git-credentials && chmod 600 ~/.git-credentials'
        fi
      elif ! backend_exec "$project" sh -c 'test -f ~/.git-credentials'; then
        # Default: seed only when absent (forensics-safe).
        # shellcheck disable=SC2016
        # sh -c runs in the container; $() and the redirect expand there.
        printf 'https://%s:%s@%s\n' "$https_user" "$(dce_read_git_token)" "$web_host" \
          | backend_exec_stdin "$project" sh -c 'cat > ~/.git-credentials && chmod 600 ~/.git-credentials'
      fi
      _dce_ensure_vscode_git_auth "$project" "$has_vscode_git_auth"
      ;;
    ssh)
      # SSH deploy key: route any HTTPS host URL through SSH (image default for
      # github; explicit for other providers).
      backend_exec "$project" git config --global url."git@${ssh_host}:".insteadOf "https://${web_host}/"
      backend_exec "$project" git config --global --unset-all url."https://${web_host}/".insteadOf 2>/dev/null || true
      backend_exec "$project" git config --global --unset-all credential.helper 2>/dev/null || true
      backend_exec "$project" sh -c 'rm -f ~/.git-credentials' 2>/dev/null || true
      _dce_clear_other_provider_insteadof "$project" "$provider"
      _dce_ensure_vscode_git_auth "$project" false
      ;;
    none)
      # No host credential configured: clear any stale auth state so git falls
      # back to its defaults. Clear BOTH directions for EVERY known provider so
      # the image-baked github rule and any prior provider's rule are gone too.
      _dce_clear_all_provider_insteadof "$project"
      backend_exec "$project" git config --global --unset-all credential.helper 2>/dev/null || true
      backend_exec "$project" sh -c 'rm -f ~/.git-credentials' 2>/dev/null || true
      _dce_ensure_vscode_git_auth "$project" false
      ;;
  esac
}

# Compare the host PAT to the container's ~/.git-credentials, read-only and for
# display only (`dce doctor`). PAT auth only. Echoes one of:
#   match   the container's stored credential matches the current host token
#   drift   the container's credential differs from the host token (stale/rotated)
#   absent  the container has no ~/.git-credentials while a host token is set
#   skip    auth mode is ssh/none (no PAT to compare)
# The token is never printed: comparison is hash-only, and both the expected line
# and the container file are piped through the hasher. Requires a loaded project
# config and a running container (doctor skips silently if it cannot reach it).
dce_check_git_token_drift() {
  local project="$1"

  local method=""
  method="$(dce_git_auth_method)"
  [[ "$method" == "pat" ]] || { printf 'skip'; return 0; }

  local provider="" web_host="" https_user=""
  provider="$(dce_project_git_host)"
  web_host="$(dce_git_host_field "$provider" web_host)"
  https_user="$(dce_git_host_field "$provider" https_user)"

  local exp_hash=""
  exp_hash="$(printf 'https://%s:%s@%s\n' "$https_user" "$(dce_read_git_token)" "$web_host" | _dce_sha256_stdin)"

  if ! backend_exec "$project" sh -c 'test -f ~/.git-credentials' 2>/dev/null; then
    printf 'absent'
    return 0
  fi

  local cur_hash=""
  cur_hash="$(backend_exec "$project" sh -c 'cat ~/.git-credentials 2>/dev/null' | _dce_sha256_stdin)"
  if [[ "$exp_hash" == "$cur_hash" ]]; then
    printf 'match'
  else
    printf 'drift'
  fi
}

# Unset both insteadOf directions for every known provider except the active
# one, so a stale rule from another host (including the github rule baked into
# the base image) cannot coexist with the active provider's wiring.
_dce_clear_other_provider_insteadof() {
  local project="$1"
  local active="$2"
  local p="" web="" ssh=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" == "$active" ]] && continue
    web="$(dce_git_host_field "$p" web_host)"
    ssh="$(dce_git_host_field "$p" ssh_host)"
    backend_exec "$project" git config --global --unset-all url."https://${web}/".insteadOf 2>/dev/null || true
    backend_exec "$project" git config --global --unset-all url."git@${ssh}:".insteadOf 2>/dev/null || true
  done < <(dce_git_host_known_providers)
}

# Unset both insteadOf directions for every known provider (the "no auth" case).
_dce_clear_all_provider_insteadof() {
  local project="$1"
  local p="" web="" ssh=""
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    web="$(dce_git_host_field "$p" web_host)"
    ssh="$(dce_git_host_field "$p" ssh_host)"
    backend_exec "$project" git config --global --unset-all url."https://${web}/".insteadOf 2>/dev/null || true
    backend_exec "$project" git config --global --unset-all url."git@${ssh}:".insteadOf 2>/dev/null || true
  done < <(dce_git_host_known_providers)
}

# Best-effort: write/remove the provider's VS Code git-auth machine setting
# inside the container's vscode-server so VS Code's Source Control panel uses
# git's credential helper (PAT) instead of the hoster extension OAuth prompt.
# jq-on-host is required; absence is silently tolerated (best-effort).  The
# setting is merged into the existing machine settings JSON, preserving any user
# preferences. When enable is not "true" (ssh/none, or a provider with no VS
# Code setting like gitlab), the key is removed so VS Code's default is restored.
_dce_ensure_vscode_git_auth() {
  local project="$1"
  local enable="$2"

  local vscode_setting=""
  vscode_setting="$(dce_git_host_field "$(dce_project_git_host)" vscode_setting)"

  # Only github ships a VS Code git-auth setting. For providers without one
  # (gitlab), there is nothing to write OR remove -- skip entirely so we never
  # touch the machine settings file for a no-conflict provider.
  if [[ -z "$vscode_setting" ]]; then
    return 0
  fi

  command -v jq >/dev/null 2>&1 || return 0

  local existing="{}"
  # shellcheck disable=SC2016
  # sh -c runs in the container; ~ expands to dev's home there.
  existing="$(backend_exec "$project" sh -c 'cat ~/.vscode-server/data/Machine/settings.json 2>/dev/null' 2>/dev/null || printf '{}')"
  printf '%s' "$existing" | jq -e . >/dev/null 2>&1 || existing='{}'

  local existing_normalized=""
  existing_normalized="$(printf '%s' "$existing" | jq -c . 2>/dev/null)" || existing_normalized='{}'

  local merged=""
  if [[ "$enable" == "true" ]]; then
    merged="$(printf '%s' "$existing" | jq -c --arg k "$vscode_setting" '. + {($k): false}' 2>/dev/null)" || return 0
  else
    merged="$(printf '%s' "$existing" | jq -c --arg k "$vscode_setting" 'del(.[$k])' 2>/dev/null)" || return 0
  fi

  # Skip the write if nothing changed (avoids creating an empty file for no reason).
  [[ "$merged" == "$existing_normalized" ]] && return 0

  # shellcheck disable=SC2016
  # sh -c runs in the container; ~ expands to dev's home there.
  printf '%s' "$merged" \
    | backend_exec_stdin "$project" sh -c 'mkdir -p ~/.vscode-server/data/Machine && cat > ~/.vscode-server/data/Machine/settings.json' 2>/dev/null || true
}
