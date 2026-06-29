#!/usr/bin/env bash
# =============================================================================
# tests/contract/security-token-argv.sh - The git token must NOT appear in host
# process argv during `dce shell` (one-shot or interactive), for EVERY provider.
#
# Host process args are readable via `ps` and /proc/<pid>/cmdline while a shell
# session is active, so the token must cross the host/container boundary through
# a stdin pipe into a short-lived in-container file -- never through argv.
#
# This test is self-contained and DATA-DRIVEN over the provider registry
# (lib/git-host.sh): for each known provider (github -> GITHUB_TOKEN, gitlab ->
# GITLAB_TOKEN) it drives a stubbed `docker` CLI (no real backend) and asserts:
#   - the sentinel token value never appears in any recorded backend argv,
#   - the sentinel *does* cross via the stdin pipe used to seed the token file,
#   - the token file is created via mktemp, consumed, deleted, and cleaned up,
#   - the provider's env-var NAME is exported from the seeded file (not inline),
#   - PS1 propagation is unchanged,
#   - placeholder / comment-only token files still behave as unset.
#
# End-to-end token availability inside a real container shell is covered by the
# backend-dependent verification checklist, not here.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Load the provider registry so the loop is driven by the same source of truth.
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/git-host.sh"

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
          printf '%s\n' "/tmp/dce-git-token.STUB01"
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
# Static guard: shell.sh must not inject the token VALUE inline into an exec
# argv. The env-var NAME may appear (it is not secret), but the value must only
# cross via the stdin-seeded temp file. Checked once for every provider's name.
# ---------------------------------------------------------------------------
for _provider in $(dce_git_host_known_providers); do
  _envvar="$(dce_git_host_field "$_provider" env_var)"
  # shellcheck disable=SC2016  # literal $ in the grep pattern under test
  if grep -nE "${_envvar}=\\\$\{?GIT_TOKEN|--env[[:space:]]+\"${_envvar}=" "$ROOT_DIR/scripts/shell.sh" >/dev/null; then
    fail "static: shell.sh injects $_envvar value inline into exec argv"
  fi
done
pass "static: shell.sh never injects a token value inline into exec argv"

# ---------------------------------------------------------------------------
# Per-provider scenarios. The mechanism is identical; only the sentinel and the
# env-var name differ.
# ---------------------------------------------------------------------------
run_provider() {
  local provider="$1"
  local env_var="" sentinel="" token_path="" logx="" capx=""

  env_var="$(dce_git_host_field "$provider" env_var)"
  sentinel="$(dce_git_host_field "$provider" sentinel)"
  # A real (non-placeholder) token: the provider's real prefix (ghp_ / glpat_)
  # with a payload that is NOT the placeholder, so dce_read_git_token treats it
  # as set. Unique enough to grep for; never the ${sentinel} value.
  local real_token="${sentinel%%_REPLACE_ME}_REAL0123456789abcdefXYZ"

  # Per-provider capture files so the loop's providers don't share buffers.
  logx="$WORK/docker-$provider.log"
  capx="$WORK/stdin-$provider.cap"
  : > "$logx"
  : > "$capx"

  token_path="$WORK/$(dce_git_host_field "$provider" token_filename)"
  printf '%s\n' "$real_token" > "$token_path"
  chmod 600 "$token_path"

  local fake_home="$WORK/home-$provider"
  local cfg_dir="$fake_home/.config/dce-enclave/$PROJECT"
  mkdir -p "$cfg_dir"
  chmod 700 "$cfg_dir"
  cat > "$cfg_dir/config" <<CFG
CONTAINER_PROJECT="$PROJECT"
CONTAINER_BACKEND="docker"
CONTAINER_GIT_HOST="$provider"
CONTAINER_IMAGE="dce-base:latest"
REPOS_DIR="$WORK/repos"
SECRET_DIR="$WORK/secret"
SSH_KEY_PATH="$WORK/secret/ssh_key"
TOKEN_FILE="$token_path"
NPMRC_PATH="$WORK/secret/.npmrc"
PORTS=()
CONTAINER_HIDDEN_PATHS=()
CFG
  chmod 600 "$cfg_dir/config"

  # Run shell.sh against the stub backend. stdin is /dev/null so the interactive
  # exec never blocks reading the TTY; the token-seeding stdin comes from
  # shell.sh itself (printf | backend_exec_stdin), not from here.
  run_shell() {
    DC_STUB_LOG="$logx" \
    DC_STUB_CAP="$capx" \
    DC_STUB_PROJECT="$PROJECT" \
    HOME="$fake_home" \
    PATH="$STUB_DIR:$PATH" \
    CONTAINER_BACKEND="docker" \
    DEV_CONTAINERS_BACKEND="" \
    "$ROOT_DIR/scripts/shell.sh" "$PROJECT" "$@"
  }

  # --- one-shot path with a real token ------------------------------------
  : > "$logx"; : > "$capx"
  # shellcheck disable=SC2016  # command string; expands when run inside
  run_shell "printf \"%s\" \"\$$env_var\"" < /dev/null

  grep -Fq "$real_token" "$logx" && fail "$provider one-shot: token leaked into host argv"
  pass "$provider one-shot: token absent from host argv"

  grep -Fq "$real_token" "$capx" || fail "$provider one-shot: token did not cross via stdin pipe"
  pass "$provider one-shot: token delivered via stdin"

  grep -Fq "mktemp" "$logx" || fail "$provider one-shot: token file not created via mktemp"
  grep -Fq '/tmp/dce-git-token.STUB01' "$logx" || fail "$provider one-shot: temp token file not referenced in argv"
  # shellcheck disable=SC2016  # literal text being grep'd from the log
  grep -Fq 'cat "$1"' "$logx" || fail "$provider one-shot: wrapper does not read+delete token file"
  pass "$provider one-shot: token seeded via temp file and consumed"

  grep -Eq 'rm[[:space:]]+-f[[:space:]]+/tmp/dce-git-token' "$logx" \
    || fail "$provider one-shot: cleanup trap did not remove token file"
  pass "$provider one-shot: cleanup trap removes token file"

  grep -Fq 'PS1=[' "$logx" || fail "$provider one-shot: PS1 not propagated"
  pass "$provider one-shot: PS1 propagated"

  # --- interactive path with a real token ---------------------------------
  : > "$logx"; : > "$capx"
  run_shell < /dev/null

  grep -Fq "$real_token" "$logx" && fail "$provider interactive: token leaked into host argv"
  pass "$provider interactive: token absent from host argv"

  grep -Fq "$real_token" "$capx" || fail "$provider interactive: token did not cross via stdin pipe"
  pass "$provider interactive: token delivered via stdin"

  grep -Fq "mktemp" "$logx" || fail "$provider interactive: token file not created via mktemp"
  # shellcheck disable=SC2016  # literal text being grep'd from the log
  grep -Fq 'cat "$1"' "$logx" || fail "$provider interactive: wrapper does not read+delete token file"
  grep -Eq 'rm[[:space:]]+-f[[:space:]]+/tmp/dce-git-token' "$logx" \
    || fail "$provider interactive: cleanup trap did not remove token file"
  grep -Fq 'PS1=[' "$logx" || fail "$provider interactive: PS1 not propagated"
  pass "$provider interactive: token seeded, consumed, cleanup trap, PS1 ok"

  # --- placeholder token: must be treated as unset (no seeding, no wrapper) -
  printf '%s\n' "$sentinel" > "$token_path"
  : > "$logx"; : > "$capx"
  run_shell "echo placeholder-token" < /dev/null

  grep -Fq "mktemp" "$logx" && fail "$provider placeholder: token file should not be created"
  # shellcheck disable=SC2016  # literal text being grep'd from the log
  grep -Fq 'cat "$1"' "$logx" && fail "$provider placeholder: should not use token wrapper"
  grep -Fq "$env_var" "$logx" && fail "$provider placeholder: $env_var must not appear in argv"
  pass "$provider placeholder: treated as unset (no seeding, no wrapper)"

  # --- comment-only token file: still unset -------------------------------
  printf '# comment only\n\n   \n' > "$token_path"
  : > "$logx"
  run_shell "echo comment-only" < /dev/null
  grep -Fq "mktemp" "$logx" && fail "$provider comment-only: should be treated as unset"
  pass "$provider comment-only: treated as unset"
}

for provider in $(dce_git_host_known_providers); do
  run_provider "$provider"
done

echo ""
echo "All security-token-argv checks passed (data-driven over providers)."
