#!/usr/bin/env bash
# =============================================================================
# tests/contract/security-token-argv.sh - The git token must NOT appear in host
# process argv during `dce shell` (one-shot or interactive) or `dce install`,
# for EVERY provider.
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
#   - placeholder / comment-only token files still behave as unset,
#   - `dce install` wires git credentials BEFORE running install.sh and exports
#     the env var to install.sh via the same stdin-seeded temp-file pattern.
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
  local cfg_dir="$fake_home/.config/dc-enclave/projects/$PROJECT"
  mkdir -p "$cfg_dir"
  chmod 700 "$cfg_dir"
  cat > "$cfg_dir/config" <<CFG
CONTAINER_PROJECT="$PROJECT"
CONFIG_SCHEMA_VERSION="2"
CONTAINER_BACKEND="docker"
CONTAINER_GIT_HOST="$provider"
CONTAINER_IMAGE="dce-base:latest"
REPO_NAMES=("$PROJECT")
REPO_PATHS=("$WORK/repos/$PROJECT")
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

  # --- rotate-token: force-pushes the current PAT via stdin, never argv ----
  # The same force mechanism backs `rebuild-container --inject-creds`; proving it
  # here for rotate-token covers the token-write invariant for both callers.
  printf '%s\n' "$real_token" > "$token_path"
  : > "$logx"; : > "$capx"
  DC_STUB_LOG="$logx" DC_STUB_CAP="$capx" DC_STUB_PROJECT="$PROJECT" \
    HOME="$fake_home" PATH="$STUB_DIR:$PATH" CONTAINER_BACKEND="docker" \
    DEV_CONTAINERS_BACKEND="" \
    "$ROOT_DIR/scripts/rotate-token.sh" "$PROJECT" < /dev/null

  grep -Fq "$real_token" "$logx" && fail "$provider rotate-token: token leaked into host argv"
  pass "$provider rotate-token: token absent from host argv"
  grep -Fq "$real_token" "$capx" || fail "$provider rotate-token: token did not cross via stdin pipe"
  pass "$provider rotate-token: token force-pushed via stdin"

  # --- dce install: creds wired BEFORE install.sh; token crosses via stdin ---
  # Drives scripts/install-dotfiles.sh through the same stubbed backend. The
  # fixture dotfiles dir holds a no-op install.sh; the assertions pin the
  # token-handling CONTRACT of the install path (argv hygiene, credential
  # ordering, wrapper shape) -- not the dotfile contents.
  local dotfiles_dir="$WORK/dotfiles-$provider"
  mkdir -p "$dotfiles_dir"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$dotfiles_dir/install.sh"
  chmod +x "$dotfiles_dir/install.sh"

  run_install() {
    DC_STUB_LOG="$logx" \
    DC_STUB_CAP="$capx" \
    DC_STUB_PROJECT="$PROJECT" \
    HOME="$fake_home" \
    PATH="$STUB_DIR:$PATH" \
    CONTAINER_BACKEND="docker" \
    DEV_CONTAINERS_BACKEND="" \
    "$ROOT_DIR/scripts/install-dotfiles.sh" "$PROJECT" "$dotfiles_dir"
  }

  # Real-token run: install must exit 0, the token must never touch argv, git
  # credentials must be wired BEFORE the install.sh exec, and the install exec
  # must export the env-var NAME from the stdin-seeded temp file.
  printf '%s\n' "$real_token" > "$token_path"
  : > "$logx"; : > "$capx"
  if ! run_install < /dev/null; then
    fail "$provider install: install-dotfiles.sh exited non-zero against the stub backend"
  fi

  grep -Fq "$real_token" "$logx" && fail "$provider install: token leaked into host argv"
  pass "$provider install: token absent from host argv"

  # Ordering: the first `git config --global` exec (dce_ensure_git_credentials)
  # must precede the exec that RUNS install.sh (a `sh -c`/`zsh -c` wrapper whose
  # argv mentions install.sh; the chmod exec mentions install.sh too but carries
  # no `-c`). While install.sh runs there is no PAT yet otherwise, so a
  # dotfiles install.sh doing git clone/pull fails auth.
  local git_line="" install_line="" install_exec=""
  git_line="$(awk '/git config --global/ { print NR; exit }' "$logx")"
  install_line="$(awk '/install\.sh/ && /-c / { print NR; exit }' "$logx")"
  [[ -n "$git_line" && -n "$install_line" ]] \
    || fail "$provider install: expected both a git config exec and an install.sh exec in the backend log (git@$git_line install@$install_line)"
  [[ "$git_line" -lt "$install_line" ]] \
    || fail "$provider install: git credentials wired AFTER install.sh (log line $git_line vs $install_line); dce_ensure_git_credentials must run BEFORE the install exec"
  pass "$provider install: git credentials wired before install.sh"

  # Wrapper shape: the install exec must be an sh -c wrapper that exports the
  # provider's env-var NAME reading the value from the seeded temp file via a
  # positional cat (mirroring shell.sh's `_ "$file" "$ENV_VAR"` pattern) -- the
  # token VALUE must never appear inline.
  install_exec="$(awk '/install\.sh/ && /-c / { print; exit }' "$logx")"
  grep -Fq "$env_var" <<< "$install_exec" \
    || fail "$provider install: install.sh exec does not export $env_var (env-var NAME absent from exec argv)"
  grep -Eq 'export[[:space:]]' <<< "$install_exec" \
    || fail "$provider install: install.sh exec wrapper does not export the provider env var"
  # shellcheck disable=SC2016  # literal $ in the grep pattern under test
  grep -Eq 'cat "\$\{?[0-9]+\}?"' <<< "$install_exec" \
    || fail "$provider install: install.sh exec must read the token from the seeded temp file via positional cat (cat \"\$N\"), not inline"
  # The wrapper must delete the seeded token file in-consumption (rm of the
  # positional token-file arg) BEFORE exec'ing install.sh, mirroring shell.sh's
  # consumption pattern -- not just rely on the host-side EXIT-trap cleanup.
  # shellcheck disable=SC2016  # literal $ in the grep pattern under test
  grep -Fq 'rm -f "$1"' <<< "$install_exec" \
    || fail "$provider install: install.sh exec wrapper does not delete the seeded token file before exec'ing install.sh (in-consumption rm of the positional token-file arg absent)"
  grep -Fq "$real_token" <<< "$install_exec" && fail "$provider install: token value inline in install.sh exec argv"
  pass "$provider install: install.sh exec exports $env_var from seeded file (never inline)"
  pass "$provider install: install exec deletes the seeded token file in-consumption (rm -f positional arg)"

  # The token still must cross the host/container boundary through a stdin pipe
  # (the token-file seed), captured by the stub's stdin buffer.
  grep -Fq "$real_token" "$capx" || fail "$provider install: token did not cross via stdin pipe"
  pass "$provider install: token delivered via stdin"

  # Placeholder token: no seeding at all, but the install itself must still run.
  printf '%s\n' "$sentinel" > "$token_path"
  : > "$logx"; : > "$capx"
  if ! run_install < /dev/null; then
    fail "$provider install placeholder: install must still succeed with an unfilled token file"
  fi
  grep -Fq "mktemp" "$logx" && fail "$provider install placeholder: token file should not be created"
  grep -Fq "$env_var" "$logx" && fail "$provider install placeholder: $env_var must not appear in argv"
  grep -Fq "$real_token" "$logx" && fail "$provider install placeholder: stale token leaked into argv"
  pass "$provider install placeholder: treated as unset (no seeding), install still runs"
}

for provider in $(dce_git_host_known_providers); do
  run_provider "$provider"
done

echo ""
echo "All security-token-argv checks passed (data-driven over providers)."
