#!/usr/bin/env bash
# =============================================================================
# tests/security-token-argv.sh - M3 regression: GITHUB_TOKEN must not appear in
# host process argv during `dce shell` (one-shot or interactive).
#
# Host process args are readable via `ps` and /proc/<pid>/cmdline while a shell
# session is active, so the PAT must cross the host/container boundary through a
# stdin pipe into a short-lived in-container file -- never through argv.
#
# This test is self-contained: it drives a stubbed `docker` CLI (no real
# backend or container required) and asserts:
#   - the sentinel token value never appears in any recorded backend argv,
#   - the sentinel *does* cross via the stdin pipe used to seed the token file,
#   - the token file is created via mktemp, consumed, deleted, and cleaned up,
#   - PS1 propagation is unchanged,
#   - placeholder / comment-only token files still behave as unset.
#
# End-to-end token availability inside a real container shell is covered by the
# backend-dependent verification checklist, not here.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

# common.sh (sourced transitively by shell.sh) hard-requires Bash 4+.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  echo "FAIL: requires Bash 4+" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
chmod 700 "$WORK"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/docker-calls.log"        # every stub invocation, argv space-joined
STDIN_CAP="$WORK/stdin-captured"    # bytes piped into -i exec calls
: > "$LOG"
: > "$STDIN_CAP"

SENTINEL="ghp_M3SENTINEL0123456789abcdefXYZ"
TOKEN_PATH="$WORK/github-token"
printf '%s\n' "$SENTINEL" > "$TOKEN_PATH"
chmod 600 "$TOKEN_PATH"

PROJECT="dce-m3test"

# ---------------------------------------------------------------------------
# Minimal fake docker: logs each invocation and answers the handful of
# subcommands `dce shell` exercises (ps + exec). It captures stdin only when an
# -i/--interactive flag is present, which is exactly the token-seeding path.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_cap="${DC_STUB_CAP:?}"
_proj="${DC_STUB_PROJECT:?}"

# Space-joined argv per call: sufficient for substring regression checks.
printf 'CALL %s\n' "$*" >> "$_log"

# Drain stdin into the capture buffer only for interactive-stdin exec calls.
for _a in "$@"; do
  case "$_a" in
    -i|--interactive|-i*|-it)
      cat >> "$_cap"
      break
      ;;
  esac
done

case "${1:-}" in
  ps)
    printf '%s\n' "$_proj"
    exit 0
    ;;
  exec)
    for _a in "$@"; do
      case "$_a" in
        mktemp)
          printf '%s\n' "/tmp/dce-gh-token.STUB01"
          exit 0
          ;;
      esac
    done
    # chmod / sh -lc / env / rm / echo wrappers: succeed silently.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUB_DIR/docker"

# ---------------------------------------------------------------------------
# Minimal project config under a fake HOME (no real ~/.config pollution).
# ---------------------------------------------------------------------------
FAKE_HOME="$WORK/home"
CFG_DIR="$FAKE_HOME/.config/dce-enclave/$PROJECT"
mkdir -p "$CFG_DIR"
chmod 700 "$CFG_DIR"
cat > "$CFG_DIR/config" <<CFG
CONTAINER_PROJECT="$PROJECT"
CONTAINER_BACKEND="docker"
CONTAINER_IMAGE="dce-base:latest"
REPOS_DIR="$WORK/repos"
SECRET_DIR="$WORK/secret"
SSH_KEY_PATH="$WORK/secret/ssh_key"
TOKEN_FILE="$TOKEN_PATH"
NPMRC_PATH="$WORK/secret/.npmrc"
PORTS=()
CONTAINER_HIDDEN_PATHS=()
CFG
chmod 600 "$CFG_DIR/config"

# Run shell.sh against the stub backend. stdin is /dev/null so the interactive
# exec never blocks reading the TTY; the token-seeding stdin comes from shell.sh
# itself (printf | backend_exec_stdin), not from here.
run_shell() {
  DC_STUB_LOG="$LOG" \
  DC_STUB_CAP="$STDIN_CAP" \
  DC_STUB_PROJECT="$PROJECT" \
  HOME="$FAKE_HOME" \
  PATH="$STUB_DIR:$PATH" \
  CONTAINER_BACKEND="docker" \
  DEV_CONTAINERS_BACKEND="" \
  "$ROOT_DIR/scripts/shell.sh" "$PROJECT" "$@"
}

# ---------------------------------------------------------------------------
# Static guard: shell.sh must not inject the token value inline into an exec
# argv. Catches a regression where the leak is reintroduced by hand.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # literal $ in the grep pattern under test
if grep -nE 'GITHUB_TOKEN=\$GITHUB_TOKEN|--env[[:space:]]+"GITHUB_TOKEN=' "$ROOT_DIR/scripts/shell.sh" >/dev/null; then
  fail "static: shell.sh still injects GITHUB_TOKEN inline into exec argv"
fi
pass "static: shell.sh has no inline GITHUB_TOKEN exec injection"

# ---------------------------------------------------------------------------
# One-shot path with a real (sentinel) token.
# ---------------------------------------------------------------------------
: > "$LOG"; : > "$STDIN_CAP"
# shellcheck disable=SC2016  # command string; $GITHUB_TOKEN expands when run
run_shell 'printf "%s" "$GITHUB_TOKEN"' < /dev/null

grep -Fq "$SENTINEL" "$LOG" && fail "one-shot: sentinel token leaked into host argv"
pass "one-shot: token absent from host argv"

grep -Fq "$SENTINEL" "$STDIN_CAP" || fail "one-shot: token did not cross via stdin pipe"
pass "one-shot: token delivered via stdin"

grep -Fq "mktemp" "$LOG" || fail "one-shot: token file not created via mktemp"
grep -Fq '/tmp/dce-gh-token.STUB01' "$LOG" || fail "one-shot: temp token file not referenced in argv"
# shellcheck disable=SC2016  # literal text being grep'd from the log
grep -Fq 'cat "$1"' "$LOG" || fail "one-shot: wrapper does not read+delete token file"
pass "one-shot: token seeded via temp file and consumed"

grep -Eq 'rm[[:space:]]+-f[[:space:]]+/tmp/dce-gh-token' "$LOG" \
  || fail "one-shot: cleanup trap did not remove token file"
pass "one-shot: cleanup trap removes token file"

grep -Fq 'PS1=[' "$LOG" || fail "one-shot: PS1 not propagated"
pass "one-shot: PS1 propagated"

# ---------------------------------------------------------------------------
# Interactive path with a real (sentinel) token.
# ---------------------------------------------------------------------------
: > "$LOG"; : > "$STDIN_CAP"
run_shell < /dev/null

grep -Fq "$SENTINEL" "$LOG" && fail "interactive: sentinel token leaked into host argv"
pass "interactive: token absent from host argv"

grep -Fq "$SENTINEL" "$STDIN_CAP" || fail "interactive: token did not cross via stdin pipe"
pass "interactive: token delivered via stdin"

grep -Fq "mktemp" "$LOG" || fail "interactive: token file not created via mktemp"
# shellcheck disable=SC2016  # literal text being grep'd from the log
grep -Fq 'cat "$1"' "$LOG" || fail "interactive: wrapper does not read+delete token file"
grep -Eq 'rm[[:space:]]+-f[[:space:]]+/tmp/dce-gh-token' "$LOG" \
  || fail "interactive: cleanup trap did not remove token file"
grep -Fq 'PS1=[' "$LOG" || fail "interactive: PS1 not propagated"
pass "interactive: token seeded, consumed, cleanup trap, PS1 ok"

# ---------------------------------------------------------------------------
# Placeholder token: must be treated as unset (no seeding, no wrapper).
# ---------------------------------------------------------------------------
printf 'ghp_REPLACE_ME\n' > "$TOKEN_PATH"
: > "$LOG"; : > "$STDIN_CAP"
run_shell 'echo placeholder-token' < /dev/null

grep -Fq "mktemp" "$LOG" && fail "placeholder token: token file should not be created"
# shellcheck disable=SC2016  # literal text being grep'd from the log
grep -Fq 'cat "$1"' "$LOG" && fail "placeholder token: should not use token wrapper"
grep -Fq "GITHUB_TOKEN" "$LOG" && fail "placeholder token: GITHUB_TOKEN must not appear in argv"
pass "placeholder token: treated as unset (no seeding, no wrapper)"

# ---------------------------------------------------------------------------
# Comment-only / whitespace-only token file: still unset.
# ---------------------------------------------------------------------------
printf '# comment only\n\n   \n' > "$TOKEN_PATH"
: > "$LOG"
run_shell 'echo comment-only' < /dev/null
grep -Fq "mktemp" "$LOG" && fail "comment-only token: should be treated as unset"
pass "comment-only token: treated as unset"

echo ""
echo "All M3 security-token-argv checks passed."
