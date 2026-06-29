#!/usr/bin/env bash
# =============================================================================
# tests/unit/git-host.sh - Provider registry in lib/git-host.sh.
#
# Pure unit tests for the git-host provider model: every field for both v1
# providers, unknown-id fails closed, default is "github", and
# dce_project_git_host honors CONTAINER_GIT_HOST and defaults otherwise. No
# container runtime, no scripts subprocess.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/git-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- default + known-set -----------------------------------------------------
[[ "$(dce_git_host_default)" == "github" ]] || fail "default must be github"
dce_git_host_is_known "github" || fail "github must be known"
dce_git_host_is_known "gitlab" || fail "gitlab must be known"
if dce_git_host_is_known "bitbucket"; then fail "bitbucket must be unknown in v1"; fi
if dce_git_host_is_known ""; then fail "empty id must not be known"; fi
pass "default + known-set (github, gitlab)"

# --- field matrix ------------------------------------------------------------
check_field() {
  local provider="$1" field="$2" want="$3"
  local got=""
  got="$(dce_git_host_field "$provider" "$field")" \
    || fail "$provider.$field lookup failed (rc)"
  [[ "$got" == "$want" ]] \
    || fail "$provider.$field = '$got'; expected '$want'"
}

# github (must reproduce today's hardcoded values exactly).
check_field github web_host            "github.com"
check_field github ssh_host            "github.com"
check_field github sentinel            "ghp_REPLACE_ME"
check_field github https_user          "x-access-token"
check_field github env_var             "GITHUB_TOKEN"
check_field github vscode_setting      "github.gitAuthentication"
check_field github token_filename      "github-token"
check_field github known_hosts_filename "github_known_hosts"
check_field github display_name        "GitHub"
check_field github deploy_url_doc      "github.com/ORG/REPO/settings/keys"
[[ "$(dce_git_host_field github has_vscode_git_auth)" == "true" ]] \
  || fail "github.has_vscode_git_auth must be true"
pass "github field matrix reproduces today's constants"

# gitlab (full parity, provider-specific values).
check_field gitlab web_host            "gitlab.com"
check_field gitlab ssh_host            "gitlab.com"
check_field gitlab sentinel            "glpat_REPLACE_ME"
check_field gitlab https_user          "oauth2"
check_field gitlab env_var             "GITLAB_TOKEN"
check_field gitlab token_filename      "gitlab-token"
check_field gitlab known_hosts_filename "gitlab_known_hosts"
check_field gitlab display_name        "GitLab"
check_field gitlab deploy_url_doc      "gitlab.com/<group>/<project>/-/settings/repository#deploy-keys"
[[ "$(dce_git_host_field gitlab has_vscode_git_auth)" == "false" ]] \
  || fail "gitlab.has_vscode_git_auth must be false (no VS Code conflict)"
# gitlab has no VS Code git-auth setting: empty, not an error.
[[ -z "$(dce_git_host_field gitlab vscode_setting)" ]] \
  || fail "gitlab.vscode_setting must be empty"
pass "gitlab field matrix"

# --- fingerprint_doc_url is non-empty for both (used by the pinning test) -----
[[ -n "$(dce_git_host_field github fingerprint_doc_url)" ]] \
  || fail "github.fingerprint_doc_url must be non-empty"
[[ -n "$(dce_git_host_field gitlab fingerprint_doc_url)" ]] \
  || fail "gitlab.fingerprint_doc_url must be non-empty"
pass "fingerprint_doc_url present for both providers"

# --- unknown id / unknown field fails closed ---------------------------------
if dce_git_host_field "nope" web_host >/dev/null 2>&1; then
  fail "unknown provider must fail closed"
fi
if dce_git_host_field github "bogus_field" >/dev/null 2>&1; then
  fail "unknown field must fail closed"
fi
pass "unknown provider/field fails closed"

# --- dce_project_git_host: honors config, defaults otherwise -----------------
unset CONTAINER_GIT_HOST
[[ "$(dce_project_git_host)" == "github" ]] \
  || fail "dce_project_git_host must default to github when unset"
# shellcheck disable=SC2034
# Read indirectly by dce_project_git_host in the sourced lib.
CONTAINER_GIT_HOST="gitlab"
[[ "$(dce_project_git_host)" == "gitlab" ]] \
  || fail "dce_project_git_host must honor CONTAINER_GIT_HOST=gitlab"
# shellcheck disable=SC2034
# Read indirectly by dce_project_git_host in the sourced lib.
CONTAINER_GIT_HOST="github"
[[ "$(dce_project_git_host)" == "github" ]] \
  || fail "dce_project_git_host must honor CONTAINER_GIT_HOST=github"
unset CONTAINER_GIT_HOST
pass "dce_project_git_host honors config + defaults"

echo ""
echo "All git-host registry checks passed."
