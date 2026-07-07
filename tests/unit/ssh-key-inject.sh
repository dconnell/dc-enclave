#!/usr/bin/env bash
# =============================================================================
# tests/unit/ssh-key-inject.sh - dce_inject_ssh_deploy_key.
#
# Proves the SSH deploy-key injection helper is correct and idempotent, and
# that the host HOME never participates in the path test (the P1 host-tilde
# bug class): the guard and the injection both run inside the container shell
# so ~ resolves there, never on the host.
#   - SSH_KEY_PATH unset / file absent -> no-op (no backend calls)
#   - default (only-if-missing): injects when the container lacks the key,
#     skips when it already has it
#   - force: always injects, even when the container already has the key
#   - regression: the guard argv carries a literal ~/.ssh (deferred to the
#     container shell), never a host-expanded $HOME path
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

SSH_KEY_PATH="$WORK/ssh_key"
PROJECT="tc-inj"

ARGV_LOG="$WORK/argv.log"     # space-joined argv per backend_exec call
STDIN_CAP="$WORK/stdin.cap"   # bytes piped into backend_exec_stdin
: > "$ARGV_LOG"; : > "$STDIN_CAP"

# Stubbed backend surface. backend_exec records argv and answers the
# only-if-missing guard ('test -f ~/.ssh/id_ed25519', reached via sh -c) from
# CONTAINER_HAS_SSH_KEY. backend_exec_stdin drains stdin into STDIN_CAP --
# the path the key bytes take into the container.
backend_exec() {
  printf 'EXEC %s\n' "$*" >> "$ARGV_LOG"
  local a
  for a in "$@"; do
    case "$a" in
      *'test -f ~/.ssh/id_ed25519'*)
        [[ "${CONTAINER_HAS_SSH_KEY:-0}" == "1" ]] && return 0 || return 1 ;;
    esac
  done
  return 0
}
backend_exec_stdin() {
  printf 'EXECSTDIN %s\n' "$*" >> "$ARGV_LOG"
  cat >> "$STDIN_CAP"
}

write_ssh_key() { printf 'ssh-key-contents\n' > "$SSH_KEY_PATH"; chmod 600 "$SSH_KEY_PATH"; }
reset_state() { : > "$ARGV_LOG"; : > "$STDIN_CAP"; }

write_ssh_key

# --- no-op when SSH_KEY_PATH is unset ----------------------------------------
unset SSH_KEY_PATH
reset_state
dce_inject_ssh_deploy_key "$PROJECT"
[[ ! -s "$ARGV_LOG" ]] || fail "no-op(unset): must not call backend when SSH_KEY_PATH unset"
pass "no-op: SSH_KEY_PATH unset -> no backend calls"

SSH_KEY_PATH="$WORK/ssh_key"

# --- no-op when the key file is absent ---------------------------------------
rm -f "$SSH_KEY_PATH"
reset_state
dce_inject_ssh_deploy_key "$PROJECT"
[[ ! -s "$ARGV_LOG" ]] || fail "no-op(absent): must not call backend when key file absent"
pass "no-op: key file absent -> no backend calls"

write_ssh_key

# --- default: injects when the container lacks the key -----------------------
CONTAINER_HAS_SSH_KEY=0
reset_state
dce_inject_ssh_deploy_key "$PROJECT"
grep -Fq 'mkdir -p ~/.ssh && chmod 700 ~/.ssh' "$ARGV_LOG" \
  || fail "default-missing: ssh dir not created (via container shell)"
grep -Fq 'cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519' "$ARGV_LOG" \
  || fail "default-missing: key not written (via container shell)"
grep -Fq 'ssh-key-contents' "$STDIN_CAP" \
  || fail "default-missing: key bytes not delivered via stdin"
pass "default(missing): injects key via container shell + stdin"

# --- default: skips when the container already has the key -------------------
CONTAINER_HAS_SSH_KEY=1
reset_state
dce_inject_ssh_deploy_key "$PROJECT"
grep -Fq 'cat > ~/.ssh/id_ed25519' "$ARGV_LOG" \
  && fail "default-present: must NOT rewrite when the container already has the key"
[[ ! -s "$STDIN_CAP" ]] || fail "default-present: must not pipe key bytes when skipping"
pass "default(present): skips injection (only-if-missing)"

# --- force: always injects, even when the container has the key --------------
CONTAINER_HAS_SSH_KEY=1
reset_state
dce_inject_ssh_deploy_key "$PROJECT" force
grep -Fq 'cat > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519' "$ARGV_LOG" \
  || fail "force-present: must rewrite the key even when the container has it"
grep -Fq 'ssh-key-contents' "$STDIN_CAP" \
  || fail "force-present: key bytes not delivered via stdin"
pass "force(present): overwrites the existing key"

# --- P1 regression: the guard ~ reaches the container, never host-expanded ----
# The historical bug was `backend_exec "$p" test -f ~/.ssh/id_ed25519` as a raw
# argv, which the host shell tilde-expanded to $HOME before the backend saw it,
# so the guard was a silent no-op (the host path never exists in the container).
# The fix routes the test through sh -c so ~ stays literal in the recorded argv
# and expands only inside the container. Assert the literal ~/ form appears and
# the host HOME path does not.
CONTAINER_HAS_SSH_KEY=0
reset_state
dce_inject_ssh_deploy_key "$PROJECT"
grep -Fq 'test -f ~/.ssh/id_ed25519' "$ARGV_LOG" \
  || fail "regression: guard must carry literal '~/.ssh/id_ed25519' in argv (deferred to container)"
grep -Fq "test -f $HOME/.ssh/id_ed25519" "$ARGV_LOG" \
  && fail "regression: host HOME must NOT appear in guard argv (host-tilde bug)"
pass "regression: guard ~ deferred to the container shell (no host HOME in argv)"

echo ""
echo "All ssh-key-inject helper checks passed."
