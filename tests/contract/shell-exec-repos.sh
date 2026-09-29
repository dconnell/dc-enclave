#!/usr/bin/env bash
# =============================================================================
# tests/contract/shell-exec-repos.sh - Repo-aware shell/exec targeting.
#
# Stubbed-backend coverage for stage-5 ergonomics:
#   - single-repo interactive shell defaults to /workspace/<repo>
#   - multi-repo interactive shell defaults to /workspace
#   - `dce shell --repo <name>` targets /workspace/<repo>
#   - `dce exec --repo <name>` runs from /workspace/<repo>
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
mkdir -p "$DC_ROOT"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
RUNNING="$WORK/running.lst"
: > "$LOG"
printf 'singlerepo\nmulti\n' > "$RUNNING"

cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_running="${DC_STUB_RUNNING:?}"
printf 'CALL docker %s\n' "$*" >> "$_log"
case "${1:-}" in
  ps)
    cat "$_running"
    exit 0
    ;;
  exec)
    exit 0
    ;;
  context)
    printf 'default\n'
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"

write_config() {
  local project="$1"
  shift
  local dir="$DC_ROOT/$project"
  mkdir -p "$dir"
  chmod 700 "$dir"
  {
    printf 'CONTAINER_PROJECT="%s"\n' "$project"
    echo 'CONFIG_SCHEMA_VERSION="2"'
    echo 'CONTAINER_BACKEND="docker"'
    echo 'CONTAINER_IMAGE="dce-base:latest"'
    printf 'REPO_NAMES=('; printf ' %q' "$@"; printf ' )\n'
    printf 'REPO_PATHS=(' 
    local name=""
    for name in "$@"; do
      printf ' %q' "$WORK/repos/$name"
    done
    printf ' )\n'
    echo 'SECRET_DIR="/tmp/secret"'
    echo 'SSH_KEY_PATH="/tmp/secret/ssh_key"'
    echo 'TOKEN_FILE="/tmp/secret/github-token"'
    echo 'NPMRC_PATH="/tmp/secret/.npmrc"'
    echo 'PORTS=()'
    echo 'CONTAINER_HIDDEN_PATHS=()'
    echo 'CONTAINER_NETWORKS=()'
  } > "$dir/config"
  chmod 600 "$dir/config"
}

run_shell() {
  HOME="$WORK/home" PATH="$STUB_DIR:$PATH" CONTAINER_BACKEND=docker \
    DC_STUB_LOG="$LOG" DC_STUB_RUNNING="$RUNNING" \
    bash "$ROOT_DIR/scripts/shell.sh" "$@"
}

run_exec() {
  HOME="$WORK/home" PATH="$STUB_DIR:$PATH" CONTAINER_BACKEND=docker \
    DC_STUB_LOG="$LOG" DC_STUB_RUNNING="$RUNNING" \
    bash "$ROOT_DIR/scripts/exec.sh" "$@"
}

write_config singlerepo singlerepo
write_config multi web api

# Single-repo interactive shell -> /workspace/<repo>
: > "$LOG"
run_shell singlerepo </dev/null >/dev/null 2>&1 || fail "single-repo shell exited non-zero"
grep -Fq "cd /workspace/singlerepo" "$LOG" || fail "single-repo shell should cd to /workspace/singlerepo"
pass "single-repo shell defaults to repo root"

# Multi-repo interactive shell -> /workspace
: > "$LOG"
run_shell multi </dev/null >/dev/null 2>&1 || fail "multi-repo shell exited non-zero"
grep -Fq "cd /workspace" "$LOG" || fail "multi-repo shell should cd to /workspace"
if grep -Fq "cd /workspace/web" "$LOG"; then
  fail "multi-repo shell must not default to a specific repo"
fi
pass "multi-repo shell defaults to project root"

# Explicit shell --repo targets the selected repo.
: > "$LOG"
run_shell --repo api multi </dev/null >/dev/null 2>&1 || fail "shell --repo exited non-zero"
grep -Fq "cd /workspace/api" "$LOG" || fail "shell --repo should cd to /workspace/api"
pass "shell --repo targets the selected repo"

# Explicit exec --repo targets the selected repo.
: > "$LOG"
run_exec --repo web multi pwd >/dev/null 2>&1 || fail "exec --repo exited non-zero"
grep -Fq "cd /workspace/web && exec pwd" "$LOG" || fail "exec --repo should run from /workspace/web"
pass "exec --repo targets the selected repo"

echo ""
echo "All shell/exec repo-targeting checks passed."
