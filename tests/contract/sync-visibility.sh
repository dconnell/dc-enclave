#!/usr/bin/env bash
# =============================================================================
# tests/contract/sync-visibility.sh - Contract coverage for the sync visibility
# feature (plans/sync-visibility.md): dce sync-status, the dce shell entry-wait,
# and the dce editor entry-wait. Stubbed docker/mutagen/code; no real backend.
#
# Covers:
#   dce sync-status:   default execs `mutagen sync monitor <session>`;
#                      --once execs `mutagen sync list <session>`; non-synced
#                      and missing-session friendly failures.
#   dce shell:         interactive synced path flushes; HAS_COMMAND does NOT;
#                      --no-wait and DCE_SYNC_NO_WAIT=1 skip the flush.
#   dce editor:        synced path flushes before launch; --no-wait skips.
#
# The helpers themselves (short_status classification, soft-fail ordering) are
# covered in tests/unit/sync-entry-wait.sh; this file pins the SCRIPT-level
# wiring (argv parsing, gating, dispatch).
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
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
# VS Code user dirs (Linux + macOS layouts) so the named-attach seed finds a
# live parent on either platform (mirrors tests/contract/editor.sh).
mkdir -p "$HOME/.config/Code/User" "$HOME/Library/Application Support/Code/User"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"
chmod 600 "$DC_ROOT/config"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
RUNNING_FILE="$WORK/running.lst"
CONTAINERS_FILE="$WORK/containers.lst"
CODE_LOG="$WORK/code.log"
: > "$LOG"; : > "$CODE_LOG"; : > "$RUNNING_FILE"; : > "$CONTAINERS_FILE"

# ---------------------------------------------------------------------------
# docker stub: stateful (running/containers files), logs every call. Answers
# the predicates shell.sh/editor.sh/start.sh exercise. exec drains stdin for
# -i calls and exits 0 for the wrapper subcommands.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_run="${DC_STUB_RUNNING:?}"
_ctrs="${DC_STUB_CONTAINERS:?}"
printf 'CALL docker %s\n' "$*" >> "$_log"

_drain=false
for _a in "$@"; do
  case "$_a" in -i|--interactive|-i*|-it) _drain=true ;; esac
done

case "${1:-}" in
  info) exit 0 ;;
  context) [[ "${2:-}" == "show" ]] && printf 'default\n'; exit 0 ;;
  ps)
    any=""
    for _a in "$@"; do [[ "$_a" == "-a" ]] && any=1; done
    [[ -n "$any" ]] && { cat "$_ctrs" 2>/dev/null || true; } || { cat "$_run" 2>/dev/null || true; }
    exit 0
    ;;
  start)
    _name="${@: -1}"
    grep -qxF -- "$_name" "$_run" 2>/dev/null || printf '%s\n' "$_name" >> "$_run"
    exit 0
    ;;
  image|images) exit 0 ;;
  volume) exit 0 ;;
  exec)
    $_drain && cat >/dev/null 2>&1 || true
    exit 0
    ;;
  create) exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"
cp "$STUB_DIR/docker" "$STUB_DIR/container"

# ---------------------------------------------------------------------------
# mutagen stub: logs every call to the SAME log so cross-tool ordering
# (resume-before-flush) can be asserted. `sync list` reports a healthy,
# present session unless DC_STUB_SYNC_ABSENT=1.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/mutagen" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
printf 'CALL mutagen %s\n' "$*" >> "$_log"
case "${1:-} ${2:-}" in
  "sync list")
    [[ "${DC_STUB_SYNC_ABSENT:-0}" == "1" ]] && exit 1
    printf 'Status:\n    Alpha:\n        Watcher: Watching for changes\n    Beta:\n        Watcher: Watching for changes\n'
    exit 0
    ;;
  "sync resume") exit 0 ;;
  "sync flush") exit 0 ;;
  "sync monitor") exit 0 ;;
  "sync create") exit 0 ;;
  "sync terminate") exit 0 ;;
  "version ") printf 'mutagen 0.18.1\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/mutagen"

# ---------------------------------------------------------------------------
# code stub: captures argv so editor launch can be asserted.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/code" <<'STUB'
#!/usr/bin/env bash
# Log to the MAIN calls log (DC_STUB_LOG) so launch ordering can be compared
# against mutagen/docker calls in the same file; also keep a dedicated trace.
printf 'CALL code %s\n' "$*" >> "${DC_STUB_LOG:?}"
printf 'CALL code %s\n' "$*" >> "${DC_STUB_CODE_LOG:?}"
exit 0
STUB
chmod +x "$STUB_DIR/code"

ORIG_PATH="$PATH"

# Build a project config + register the container. $3 = "sync" to mark it a
# synced workspace; $4 = "running" to pre-mark the container running.
make_project() {
  local project="$1" cfg_dir="$2" mode="${3:-}" running="${4:-}"
  local repos="$WORK/home/repos/$project"
  mkdir -p "$cfg_dir" "$repos"
  chmod 700 "$cfg_dir"
  {
    printf 'CONTAINER_PROJECT="%s"\n' "$project"
    printf 'CONTAINER_BACKEND="docker"\n'
    printf 'CONTAINER_IMAGE="dce-base:latest"\n'
    printf 'REPOS_DIR="%s"\n' "$repos"
    printf 'SECRET_DIR="%s"\n' "$cfg_dir"
    printf 'PORTS=()\n'
    printf 'CONTAINER_HIDDEN_PATHS=()\n'
    printf 'CONTAINER_NETWORKS=()\n'
    [[ "$mode" == "sync" ]] && printf 'CONTAINER_SYNC="1"\n'
  } > "$cfg_dir/config"
  chmod 600 "$cfg_dir/config"
  if ! grep -qxF -- "$project" "$CONTAINERS_FILE" 2>/dev/null; then
    printf '%s\n' "$project" >> "$CONTAINERS_FILE"
  fi
  if [[ "$running" == "running" ]] && ! grep -qxF -- "$project" "$RUNNING_FILE" 2>/dev/null; then
    printf '%s\n' "$project" >> "$RUNNING_FILE"
  fi
}

# Common env for every script invocation. Exports the shared stub state and
# runs the command passed as args. For per-call env overrides, prefix the
# command with `env VAR=val ...`.
run_env() {
  export DC_STUB_LOG="$LOG"
  export DC_STUB_RUNNING="$RUNNING_FILE"
  export DC_STUB_CONTAINERS="$CONTAINERS_FILE"
  export DC_STUB_CODE_LOG="$CODE_LOG"
  export PATH="$STUB_DIR:$ORIG_PATH"
  export CONTAINER_BACKEND="docker"
  export DEV_CONTAINERS_BACKEND=""
  export HOME="$WORK/home"
  "$@"
}
reset_log() { : > "$LOG"; }
saw() { grep -q "$1" "$LOG"; }

# ===========================================================================
# dce sync-status
# ===========================================================================
SYNC_PROJ="syncstat"
make_project "$SYNC_PROJ" "$DC_ROOT/$SYNC_PROJ" sync

# default -> mutagen sync monitor <session>
reset_log
run_env "$ROOT_DIR/scripts/sync-status.sh" "$SYNC_PROJ" >/dev/null 2>&1 \
  || fail "sync-status (default) exited non-zero"
SESSION="$(dce_sync_session_name "$SYNC_PROJ")"
saw "sync monitor $SESSION" || fail "sync-status default should exec mutagen sync monitor"
pass "dce sync-status: default execs mutagen sync monitor"

# --once -> mutagen sync list <session>
reset_log
run_env "$ROOT_DIR/scripts/sync-status.sh" "$SYNC_PROJ" --once >/dev/null 2>&1 \
  || fail "sync-status --once exited non-zero"
saw "sync list $SESSION" || fail "sync-status --once should exec mutagen sync list"
pass "dce sync-status: --once execs mutagen sync list"

# non-synced project -> friendly failure (point at --sync), no monitor call.
NOSYNC_PROJ="nosync"
make_project "$NOSYNC_PROJ" "$DC_ROOT/$NOSYNC_PROJ" ""
reset_log
if run_env "$ROOT_DIR/scripts/sync-status.sh" "$NOSYNC_PROJ" >/dev/null 2>"$WORK/err"; then
  fail "sync-status on non-synced project should fail"
fi
grep -Fqi -- '--sync' "$WORK/err" || fail "non-synced failure should mention --sync"
! saw 'sync monitor' || fail "non-synced project must not reach mutagen monitor"
pass "dce sync-status: non-synced project fails fast with --sync hint"

# missing session -> friendly failure (point at rebuild-container).
reset_log
if run_env env DC_STUB_SYNC_ABSENT=1 "$ROOT_DIR/scripts/sync-status.sh" "$SYNC_PROJ" >/dev/null 2>"$WORK/err"; then
  fail "sync-status with missing session should fail"
fi
grep -Fqi 'rebuild-container' "$WORK/err" || fail "missing-session failure should mention rebuild-container"
pass "dce sync-status: missing session fails fast with rebuild-container hint"

# ===========================================================================
# dce shell: interactive synced path flushes; HAS_COMMAND does not.
# ===========================================================================
SHELL_PROJ="shproj"
make_project "$SHELL_PROJ" "$DC_ROOT/$SHELL_PROJ" sync running

# Interactive path -> flush invoked (and resume precedes flush).
reset_log
run_env "$ROOT_DIR/scripts/shell.sh" "$SHELL_PROJ" </dev/null >/dev/null 2>&1 \
  || fail "dce shell (synced, interactive) exited non-zero"
saw "sync flush" || fail "interactive synced shell should flush"
resume_ln="$(grep -n 'sync resume' "$LOG" | head -n1 | cut -d: -f1)"
flush_ln="$(grep -n 'sync flush' "$LOG" | head -n1 | cut -d: -f1)"
[[ -n "$resume_ln" && -n "$flush_ln" && "$resume_ln" -lt "$flush_ln" ]] \
  || fail "interactive shell: resume must precede flush"
pass "dce shell: interactive synced path flushes (resume before flush)"

# HAS_COMMAND (one-shot) -> NO flush.
reset_log
run_env "$ROOT_DIR/scripts/shell.sh" "$SHELL_PROJ" "true" </dev/null >/dev/null 2>&1 \
  || fail "dce shell <name> <command> exited non-zero"
! saw "sync flush" || fail "one-shot shell path must NOT flush"
pass "dce shell: <name> <command> (non-interactive) does not wait"

# --no-wait -> NO flush (interactive).
reset_log
run_env "$ROOT_DIR/scripts/shell.sh" --no-wait "$SHELL_PROJ" </dev/null >/dev/null 2>&1 \
  || fail "dce shell --no-wait exited non-zero"
! saw "sync flush" || fail "--no-wait must skip the flush"
pass "dce shell: --no-wait skips the settle wait"

# DCE_SYNC_NO_WAIT=1 -> NO flush (interactive).
reset_log
run_env env DCE_SYNC_NO_WAIT=1 "$ROOT_DIR/scripts/shell.sh" "$SHELL_PROJ" </dev/null >/dev/null 2>&1 \
  || fail "dce shell with DCE_SYNC_NO_WAIT=1 exited non-zero"
! saw "sync flush" || fail "DCE_SYNC_NO_WAIT=1 must skip the flush"
pass "dce shell: DCE_SYNC_NO_WAIT=1 skips the settle wait"

# `dce shell <name> -- <cmd>` drops the -- and runs the command (no flush).
reset_log
run_env "$ROOT_DIR/scripts/shell.sh" "$SHELL_PROJ" -- true </dev/null >/dev/null 2>&1 \
  || fail "dce shell <name> -- <cmd> exited non-zero"
! saw "sync flush" || fail "shell <name> -- <cmd> is non-interactive and must not flush"
pass "dce shell: <name> -- <cmd> separator is honored (no wait)"

# Non-synced project: no flush, no status line (smoke).
NOSHELL_PROJ="noshell"
make_project "$NOSHELL_PROJ" "$DC_ROOT/$NOSHELL_PROJ" "" running
reset_log
run_env "$ROOT_DIR/scripts/shell.sh" "$NOSHELL_PROJ" </dev/null >/dev/null 2>&1 \
  || fail "dce shell (non-synced) exited non-zero"
! saw "sync flush" || fail "non-synced shell must not flush"
pass "dce shell: non-synced project unchanged (no flush)"

# ===========================================================================
# dce editor: synced path flushes before launch; --no-wait skips.
# ===========================================================================
ED_PROJ="edproj"
make_project "$ED_PROJ" "$DC_ROOT/$ED_PROJ" sync running

# Synced -> flush invoked before code launch.
reset_log
: > "$CODE_LOG"
run_env "$ROOT_DIR/scripts/editor.sh" "$ED_PROJ" >/dev/null 2>&1 \
  || fail "dce editor (synced) exited non-zero"
saw "sync flush" || fail "synced editor should flush before launch"
grep -q '^CALL code ' "$LOG" || fail "editor should still launch code after wait"
flush_ln="$(grep -n 'sync flush' "$LOG" | head -n1 | cut -d: -f1)"
launch_ln="$(grep -n '^CALL code ' "$LOG" | head -n1 | cut -d: -f1)"
[[ -n "$flush_ln" && -n "$launch_ln" && "$flush_ln" -lt "$launch_ln" ]] \
  || fail "editor: flush must precede code launch"
pass "dce editor: synced path flushes before launch"

# --no-wait -> NO flush, still launches.
reset_log
: > "$CODE_LOG"
run_env "$ROOT_DIR/scripts/editor.sh" --no-wait "$ED_PROJ" >/dev/null 2>&1 \
  || fail "dce editor --no-wait exited non-zero"
! saw "sync flush" || fail "editor --no-wait must skip the flush"
grep -q '^CALL code ' "$LOG" || fail "editor --no-wait should still launch code"
pass "dce editor: --no-wait skips the settle wait"

echo "ALL SECTIONS PASSED"
