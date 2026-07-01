#!/usr/bin/env bash
# =============================================================================
# tests/unit/git-credentials.sh - dce_ensure_git_credentials / dce_git_auth_method.
#
# Proves the conditional insteadOf + credential-store wiring is correct and that
# the PAT never crosses the host/container boundary via argv (only stdin):
#   - PAT present        -> HTTPS insteadOf + credential.helper store +
#                           ~/.git-credentials (x-access-token line, via stdin)
#                           + VS Code machine setting github.gitAuthentication=false
#   - SSH key only       -> SSH insteadOf (legacy), no credential store/file
#   - placeholder token  -> treated as SSH (when key present) / none otherwise
#   - neither            -> no insteadOf; any stale auth state cleared
#   - security           -> the sentinel PAT never appears in recorded backend argv
#
# In-process: backend_exec / backend_exec_stdin are stubbed; no container runtime.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
chmod 700 "$WORK"

SENTINEL="ghp_SENTINEL0123456789abcdefXYZ"
TOKEN_FILE="$WORK/github-token"
SSH_KEY_PATH="$WORK/ssh_key"
PROJECT="tc-proj"

ARGV_LOG="$WORK/argv.log"     # space-joined argv per backend_exec call
STDIN_CAP="$WORK/stdin.cap"   # bytes piped into backend_exec_stdin
: > "$ARGV_LOG"; : > "$STDIN_CAP"

# Stubbed backend surface: record argv, and for the credential existence probe
# ('test -f ~/.git-credentials') return missing (1) so the write path is taken.
# Every other exec succeeds. backend_exec_stdin drains stdin into STDIN_CAP --
# the only path the PAT may take into the container.
backend_exec() {
  printf 'EXEC %s\n' "$*" >> "$ARGV_LOG"
  local a
  for a in "$@"; do
    case "$a" in
      *'cat ~/.git-credentials'*)
        printf '%s' "${CONTAINER_CREDS:-}"; return 0 ;;
      *'test -f ~/.git-credentials'*)
        [[ -n "${CONTAINER_CREDS:-}" ]] && return 0 || return 1 ;;
    esac
  done
  return 0
}
backend_exec_stdin() {
  printf 'EXECSTDIN %s\n' "$*" >> "$ARGV_LOG"
  cat >> "$STDIN_CAP"
}

write_token() { printf '%s\n' "$1" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; }
write_ssh_key() { printf 'key\n' > "$SSH_KEY_PATH"; chmod 600 "$SSH_KEY_PATH"; }
reset_state() { : > "$ARGV_LOG"; : > "$STDIN_CAP"; }

# --- dce_read_github_token: filtering ----------------------------------------
write_token "$SENTINEL"
[[ "$(dce_read_github_token)" == "$SENTINEL" ]] || fail "read: real token not returned"
write_token "ghp_REPLACE_ME"
[[ -z "$(dce_read_github_token)" ]] || fail "read: placeholder must be treated as unset"
printf '# only a comment\n\n   \n' > "$TOKEN_FILE"
[[ -z "$(dce_read_github_token)" ]] || fail "read: comment-only must be unset"
pass "dce_read_github_token: real/placeholder/comment filtering"

# --- dce_git_auth_method: PAT wins -------------------------------------------
write_token "$SENTINEL"; write_ssh_key
[[ "$(dce_git_auth_method)" == "pat" ]] || fail "method: PAT must win over SSH key"
write_token "ghp_REPLACE_ME"; write_ssh_key
[[ "$(dce_git_auth_method)" == "ssh" ]] || fail "method: placeholder+key -> ssh"
write_token "ghp_REPLACE_ME"; rm -f "$SSH_KEY_PATH"
[[ "$(dce_git_auth_method)" == "none" ]] || fail "method: no creds -> none"
pass "dce_git_auth_method: pat-wins / ssh / none"

# --- PAT branch: HTTPS insteadOf + credential store + ~/.git-credentials ------
write_token "$SENTINEL"; write_ssh_key
reset_state
dce_ensure_git_credentials "$PROJECT"

# Security: sentinel never in any recorded backend argv (must cross via stdin).
grep -Fq "$SENTINEL" "$ARGV_LOG" && fail "pat: sentinel leaked into backend argv"
pass "pat: sentinel absent from backend argv"

# HTTPS-direction insteadOf set; SSH-direction insteadOf explicitly unset so the
# two opposing rules can never coexist.
grep -Fq 'config --global url.https://github.com/.insteadOf git@github.com:' "$ARGV_LOG" \
  || fail "pat: HTTPS insteadOf not set"
grep -Fq 'config --global --unset-all url.git@github.com:.insteadOf' "$ARGV_LOG" \
  || fail "pat: stale SSH insteadOf not unset"
pass "pat: HTTPS insteadOf set, SSH insteadOf unset"

grep -Fq 'config --global --unset-all credential.helper' "$ARGV_LOG" \
  || fail "pat: stale credential.helper entries not cleared"
grep -Fq 'config --global --add credential.helper ' "$ARGV_LOG" \
  || fail "pat: credential.helper reset entry (empty) not set"
grep -Fq 'config --global --add credential.helper store' "$ARGV_LOG" \
  || fail "pat: credential.helper store not set"
pass "pat: credential.helper chain reset + store set"

# ~/.git-credentials seeded via stdin (not argv), x-access-token form.
grep -Fq "https://x-access-token:$SENTINEL@github.com" "$STDIN_CAP" \
  || fail "pat: credential line not delivered via stdin (x-access-token form)"
grep -Fq 'cat > ~/.git-credentials' "$ARGV_LOG" \
  || fail "pat: credential write wrapper missing"
pass "pat: ~/.git-credentials seeded via stdin"

# VS Code machine setting github.gitAuthentication=false is written to the
# container's vscode-server so the Source Control panel uses the PAT-backed
# credential store instead of the GitHub extension OAuth prompt.
grep -Fq 'cat > ~/.vscode-server/data/Machine/settings.json' "$ARGV_LOG" \
  || fail "pat: VS Code machine settings write missing"
grep -Fq '"github.gitAuthentication":false' "$STDIN_CAP" \
  || fail "pat: github.gitAuthentication=false not delivered via stdin"
pass "pat: VS Code machine setting github.gitAuthentication=false written"

# --- SSH branch: SSH insteadOf, no PAT credential wiring ----------------------
write_token "ghp_REPLACE_ME"; write_ssh_key
reset_state
dce_ensure_git_credentials "$PROJECT"
grep -Fq 'config --global url.git@github.com:.insteadOf https://github.com/' "$ARGV_LOG" \
  || fail "ssh: SSH insteadOf not set"
grep -Fq 'config --global --add credential.helper store' "$ARGV_LOG" \
  && fail "ssh: credential.helper store must not be set"
grep -Fq 'cat > ~/.git-credentials' "$ARGV_LOG" \
  && fail "ssh: must not seed ~/.git-credentials"
grep -Fq "$SENTINEL" "$ARGV_LOG" && fail "ssh: no sentinel expected in argv"
# No VS Code machine settings write needed (no existing setting to remove).
grep -Fq 'cat > ~/.vscode-server/data/Machine/settings.json' "$ARGV_LOG" \
  && fail "ssh: VS Code machine settings write must not happen when no existing setting"
pass "ssh: SSH insteadOf set, no PAT credential wiring, no VS Code write"

# --- none branch: clears stale state -----------------------------------------
write_token "ghp_REPLACE_ME"; rm -f "$SSH_KEY_PATH"
reset_state
dce_ensure_git_credentials "$PROJECT"
grep -Fq 'config --global --unset-all url.git@github.com:.insteadOf' "$ARGV_LOG" \
  || fail "none: stale SSH insteadOf not unset"
grep -Fq 'config --global --unset-all url.https://github.com/.insteadOf' "$ARGV_LOG" \
  || fail "none: stale HTTPS insteadOf not unset"
grep -Fq 'config --global --unset-all credential.helper' "$ARGV_LOG" \
  || fail "none: stale credential.helper not unset"
# No VS Code machine settings write needed (no existing setting to remove).
grep -Fq 'cat > ~/.vscode-server/data/Machine/settings.json' "$ARGV_LOG" \
  && fail "none: VS Code machine settings write must not happen when no existing setting"
pass "none: stale credential state cleared"

# --- GitLab provider: full parity, provider-specific values -------------------
# Switch the active provider to gitlab and re-run every check. The mechanism is
# identical; only the host strings, HTTPS username, and the absence of a VS Code
# setting differ.
GL_SENTINEL="glpat_SENTINEL0123456789abcdefXYZ"
# shellcheck disable=SC2034
# Read indirectly by dce_project_git_host in the sourced lib.
CONTAINER_GIT_HOST="gitlab"
write_token "$GL_SENTINEL"; write_ssh_key
reset_state
dce_ensure_git_credentials "$PROJECT"

# Security: gitlab sentinel never in backend argv (crosses via stdin).
grep -Fq "$GL_SENTINEL" "$ARGV_LOG" && fail "gitlab-pat: sentinel leaked into backend argv"
pass "gitlab-pat: sentinel absent from backend argv"

# HTTPS-direction insteadOf for gitlab.com; SSH-direction unset.
grep -Fq 'config --global url.https://gitlab.com/.insteadOf git@gitlab.com:' "$ARGV_LOG" \
  || fail "gitlab-pat: HTTPS insteadOf not set for gitlab.com"
grep -Fq 'config --global --unset-all url.git@gitlab.com:.insteadOf' "$ARGV_LOG" \
  || fail "gitlab-pat: stale SSH insteadOf not unset for gitlab.com"
pass "gitlab-pat: HTTPS insteadOf set, SSH insteadOf unset"

# credential.helper store chain (same shape as github).
grep -Fq 'config --global --add credential.helper store' "$ARGV_LOG" \
  || fail "gitlab-pat: credential.helper store not set"
pass "gitlab-pat: credential.helper store set"

# ~/.git-credentials seeded via stdin in the oauth2:<token>@gitlab.com form.
grep -Fq "https://oauth2:$GL_SENTINEL@gitlab.com" "$STDIN_CAP" \
  || fail "gitlab-pat: credential line not delivered via stdin (oauth2 form)"
pass "gitlab-pat: ~/.git-credentials seeded via stdin (oauth2@gitlab.com)"

# No VS Code machine-settings write for gitlab (no github.gitAuthentication
# equivalent -- gitlab has no VS Code git-auth conflict to suppress).
grep -Fq 'cat > ~/.vscode-server/data/Machine/settings.json' "$ARGV_LOG" \
  && fail "gitlab-pat: must NOT touch VS Code machine settings (no setting for gitlab)"
pass "gitlab-pat: no VS Code machine-settings write"

# Cross-provider cleanup: the github insteadOf rules (baked into the base image
# / left from a prior github config) must be cleared so they cannot coexist with
# the active gitlab wiring.
grep -Fq 'config --global --unset-all url.https://github.com/.insteadOf' "$ARGV_LOG" \
  || fail "gitlab-pat: stale github HTTPS insteadOf not cleared"
grep -Fq 'config --global --unset-all url.git@github.com:.insteadOf' "$ARGV_LOG" \
  || fail "gitlab-pat: stale github SSH insteadOf not cleared"
pass "gitlab-pat: stale github insteadOf rules cleared (no coexistence)"

# --- GitLab ssh branch: SSH insteadOf for gitlab, no PAT wiring --------------
write_token "glpat_REPLACE_ME"; write_ssh_key
reset_state
dce_ensure_git_credentials "$PROJECT"
grep -Fq 'config --global url.git@gitlab.com:.insteadOf https://gitlab.com/' "$ARGV_LOG" \
  || fail "gitlab-ssh: SSH insteadOf not set for gitlab.com"
grep -Fq 'config --global --add credential.helper store' "$ARGV_LOG" \
  && fail "gitlab-ssh: credential.helper store must not be set"
pass "gitlab-ssh: SSH insteadOf set, no PAT credential wiring"

# Restore the default provider so later test additions are not surprised.
unset CONTAINER_GIT_HOST

# --- force mode: compare-and-write (idempotent), default still only-if-missing --
# The stubbed backend_exec (defined above) returns the CONTAINER_CREDS variable
# for `cat ~/.git-credentials` and gates the `test -f` probe on it, so the force
# path's hash compare is observable. Each case below sets CONTAINER_CREDS to the
# container's simulated current credential (unset/empty == absent). The default
# sections above leave it unset, preserving the "missing -> seed" behavior.
write_token "$SENTINEL"; write_ssh_key
CRED_LINE="https://x-access-token:$SENTINEL@github.com"

# force overwrites when the container's value differs (stale/compromised).
reset_state; CONTAINER_CREDS=$'https://x-access-token:STALE@github.com\n'
dce_ensure_git_credentials "$PROJECT" force
grep -Fq "$CRED_LINE" "$STDIN_CAP" || fail "force-drift: must overwrite a differing credential"
grep -Fq "$SENTINEL" "$ARGV_LOG" && fail "force-drift: sentinel leaked into backend argv"
pass "force: overwrites when the container credential differs (no argv leak)"

# force is idempotent when the value already matches: no rewrite of ~/.git-credentials.
reset_state; CONTAINER_CREDS=$"$CRED_LINE"$'\n'
dce_ensure_git_credentials "$PROJECT" force
if grep -Fq "$CRED_LINE" "$STDIN_CAP"; then
  fail "force-idempotent: must NOT rewrite ~/.git-credentials when it already matches"
fi
pass "force: idempotent (no rewrite when the credential already matches)"

# default (force unset) preserves an existing credential (only-if-missing).
reset_state; CONTAINER_CREDS=$'https://x-access-token:STALE@github.com\n'
dce_ensure_git_credentials "$PROJECT"
if grep -Fq "$CRED_LINE" "$STDIN_CAP"; then
  fail "default-existing: must NOT overwrite an existing credential (only-if-missing)"
fi
pass "default: only-if-missing (existing credential preserved)"

# default (force unset) seeds when the credential is absent.
reset_state; CONTAINER_CREDS=""
dce_ensure_git_credentials "$PROJECT"
grep -Fq "$CRED_LINE" "$STDIN_CAP" || fail "default-absent: must seed when the credential is absent"
pass "default: seeds when the credential is absent"

# drift helper mirrors the same compare, read-only, never printing the token.
reset_state; CONTAINER_CREDS=$"$CRED_LINE"$'\n'
[[ "$(dce_check_git_token_drift "$PROJECT")" == "match" ]] \
  || fail "drift: identical credential must report 'match'"
CONTAINER_CREDS=$'https://x-access-token:STALE@github.com\n'
[[ "$(dce_check_git_token_drift "$PROJECT")" == "drift" ]] \
  || fail "drift: differing credential must report 'drift'"
CONTAINER_CREDS=""
[[ "$(dce_check_git_token_drift "$PROJECT")" == "absent" ]] \
  || fail "drift: missing credential must report 'absent'"
grep -Fq "$SENTINEL" "$ARGV_LOG" && fail "drift: sentinel leaked into backend argv during compare"
pass "dce_check_git_token_drift: match/drift/absent, no argv leak"

echo ""
echo "All git-credentials helper checks passed."
