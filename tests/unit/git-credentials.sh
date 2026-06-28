#!/usr/bin/env bash
# =============================================================================
# tests/unit/git-credentials.sh - dce_ensure_git_credentials / dce_git_auth_method.
#
# Proves the conditional insteadOf + credential-store wiring is correct and that
# the PAT never crosses the host/container boundary via argv (only stdin):
#   - PAT present        -> HTTPS insteadOf + credential.helper store +
#                           ~/.git-credentials (x-access-token line, via stdin)
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
    if [[ "$a" == *"test -f ~/.git-credentials"* ]]; then
      return 1
    fi
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

grep -Fq 'config --global credential.helper store' "$ARGV_LOG" \
  || fail "pat: credential.helper store not set"
pass "pat: credential.helper store set"

# ~/.git-credentials seeded via stdin (not argv), x-access-token form.
grep -Fq "https://x-access-token:$SENTINEL@github.com" "$STDIN_CAP" \
  || fail "pat: credential line not delivered via stdin (x-access-token form)"
grep -Fq 'cat > ~/.git-credentials' "$ARGV_LOG" \
  || fail "pat: credential write wrapper missing"
pass "pat: ~/.git-credentials seeded via stdin"

# --- SSH branch: SSH insteadOf, no PAT credential wiring ----------------------
write_token "ghp_REPLACE_ME"; write_ssh_key
reset_state
dce_ensure_git_credentials "$PROJECT"
grep -Fq 'config --global url.git@github.com:.insteadOf https://github.com/' "$ARGV_LOG" \
  || fail "ssh: SSH insteadOf not set"
grep -Fq 'config --global credential.helper store' "$ARGV_LOG" \
  && fail "ssh: credential.helper store must not be set"
grep -Fq 'cat > ~/.git-credentials' "$ARGV_LOG" \
  && fail "ssh: must not seed ~/.git-credentials"
grep -Fq "$SENTINEL" "$ARGV_LOG" && fail "ssh: no sentinel expected in argv"
pass "ssh: SSH insteadOf set, no PAT credential wiring"

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
pass "none: stale credential state cleared"

echo ""
echo "All git-credentials helper checks passed."
