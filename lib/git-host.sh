#!/usr/bin/env bash
# =============================================================================
# lib/git-host.sh - Git host provider registry (single source of truth).
#
# Everything that differs per git host (GitHub today, GitLab added, future:
# Bitbucket/Gitea/self-hosted) lives HERE as data, not scattered as hardcoded
# constants across lib/common.sh and the scripts. A provider is a short id
# ("github", "gitlab"); each field is returned by dce_git_host_field.
#
# Adding a provider = adding one line to each case below + a pin file under
# Containerfiles/ssh/. Nothing host-specific leaks outside this file.
#
# See plans/gitlab.md (Design §1, §5) for the full rationale, and
# docs/how-to/add-git-host.md for the per-host SSH-key pinning procedure.
# =============================================================================

# Auto-source deps if this lib is loaded directly (single-import convenience),
# mirroring the idiom in lib/devcontainer.sh.
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_git_host_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_git_host_lib_dir/common.sh"
  unset _dce_git_host_lib_dir
fi

if [[ -n "${_DC_GIT_HOST_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_GIT_HOST_SH_LOADED=1

# Echo the default provider id. Used when a project config has no
# CONTAINER_GIT_HOST key (every pre-existing project).
dce_git_host_default() {
  printf 'github'
}

# Return 0 if PROVIDER is a known id, 1 otherwise.
dce_git_host_is_known() {
  local provider="$1"
  case "$provider" in
    github|gitlab) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo every known provider id, one per line. Used by the git-credential
# cleanup to unset stale insteadOf rules for ALL hosts (the base image bakes a
# github default; a provider switch must not leave it dangling). Adding a
# provider = adding one line here, and the cleanup scales automatically.
dce_git_host_known_providers() {
  printf 'github\ngitlab\n'
}

# Return one field of a provider on stdout. Fails closed (non-zero, no output)
# for an unknown provider OR an unknown field, so a typo can never silently
# fall back to a default host string.
#
# Fields:
#   web_host             HTTPS host used in insteadOf + ~/.git-credentials
#   ssh_host             SSH host used in insteadOf + known_hosts pin
#   sentinel             placeholder value filtered out as "no token set"
#   https_user           username embedded in the https://<user>:<tok>@<host> line
#   env_var              shell env-var name the token is exported as in `dce shell`
#   vscode_setting       VS Code setting key written to defer Source Control to
#                        git's credential helper (empty when the provider has no
#                        equivalent conflict)
#   has_vscode_git_auth  "true"/"false" -- whether vscode_setting applies
#   token_filename       leaf name of the per-project token file
#   known_hosts_filename leaf name of the SSH host-key pin file under ssh/
#   fingerprint_doc_url  hoster's published-fingerprints doc URL (Channel C)
#   deploy_url_doc       host-relative doc path for adding a deploy key
#   display_name         human-facing name (GitHub / GitLab) for status/help copy
dce_git_host_field() {
  local provider="$1"
  local field="$2"

  dce_git_host_is_known "$provider" || return 1

  case "$field" in
    web_host)
      case "$provider" in
        github) printf 'github.com' ;;
        gitlab) printf 'gitlab.com' ;;
      esac
      ;;
    ssh_host)
      case "$provider" in
        github) printf 'github.com' ;;
        gitlab) printf 'gitlab.com' ;;
      esac
      ;;
    sentinel)
      case "$provider" in
        github) printf 'ghp_REPLACE_ME' ;;
        gitlab) printf 'glpat_REPLACE_ME' ;;
      esac
      ;;
    https_user)
      case "$provider" in
        github) printf 'x-access-token' ;;
        gitlab) printf 'oauth2' ;;
      esac
      ;;
    env_var)
      case "$provider" in
        github) printf 'GITHUB_TOKEN' ;;
        gitlab) printf 'GITLAB_TOKEN' ;;
      esac
      ;;
    vscode_setting)
      case "$provider" in
        github) printf 'github.gitAuthentication' ;;
        gitlab) printf '' ;;
      esac
      ;;
    has_vscode_git_auth)
      case "$provider" in
        github) printf 'true' ;;
        gitlab) printf 'false' ;;
      esac
      ;;
    token_filename)
      case "$provider" in
        github) printf 'github-token' ;;
        gitlab) printf 'gitlab-token' ;;
      esac
      ;;
    known_hosts_filename)
      case "$provider" in
        github) printf 'github_known_hosts' ;;
        gitlab) printf 'gitlab_known_hosts' ;;
      esac
      ;;
    fingerprint_doc_url)
      case "$provider" in
        github) printf 'https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints' ;;
        gitlab) printf 'https://docs.gitlab.com/ee/user/gitlab_com/#ssh-host-keys-fingerprints' ;;
      esac
      ;;
    deploy_url_doc)
      case "$provider" in
        github) printf 'github.com/ORG/REPO/settings/keys' ;;
        gitlab) printf 'gitlab.com/<group>/<project>/-/settings/repository#deploy-keys' ;;
      esac
      ;;
    display_name)
      case "$provider" in
        github) printf 'GitHub' ;;
        gitlab) printf 'GitLab' ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

# Effective provider id for the currently-loaded project config. Reads
# CONTAINER_GIT_HOST (set by dce_load_project_config) and defaults to "github"
# when unset/empty, so every pre-existing project resolves to github without a
# config migration. This is the single point callers use; nobody reads
# CONTAINER_GIT_HOST directly.
dce_project_git_host() {
  local h="${CONTAINER_GIT_HOST:-}"
  if [[ -z "$h" ]]; then
    h="$(dce_git_host_default)"
  fi
  printf '%s' "$h"
}
