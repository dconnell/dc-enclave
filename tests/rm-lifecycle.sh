#!/usr/bin/env bash
# =============================================================================
# tests/rm-lifecycle.sh - End-to-end characterization of `dce rm` against a
# stubbed docker backend.
#
# `dce rm` is the only command that deletes a project outright, so this pins
# its safety contract: stop-if-running -> delete -> remove hidden volumes ->
# remove config+secrets, the confirmation gate, the --keep-* escape hatches,
# invalid-name rejection, the already-absent path, and the invariant that the
# host code directory ($REPOS_DIR) is NEVER touched.
#
# The real daemon is never contacted: a stub `docker` logs every call and
# answers the `ps`/`ps -a` existence/running predicates from a controlled
# container-name file.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
STATE="$WORK/state"
mkdir -p "$STATE"

cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_state="${DC_STUB_STATE:?}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"

# image ls -> controlled tag list (harmless for rm, keeps parity with other stubs).
if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then
  [[ -f "${DC_STUB_IMAGES:-}" ]] && cat "${DC_STUB_IMAGES:-}"
  exit 0
fi

# docker context show (not called for the docker backend, but answered anyway).
if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then printf 'default\n'; exit 0; fi

# ps / ps -a --format -> existence + running predicates (backend_exists /
# backend_is_running). Both return the planted container-name list.
if [[ "${1:-}" == "ps" ]]; then
  if [[ "${2:-}" == "--format" ]]; then
    [[ -f "$_state/containers" ]] && cat "$_state/containers"
    exit 0
  fi
  if [[ "${2:-}" == "-a" && "${3:-}" == "--format" ]]; then
    [[ -f "$_state/containers" ]] && cat "$_state/containers"
    exit 0
  fi
  exit 0
fi

# stop / rm -f / volume rm -> succeed silently (state is not mutated; rm.sh
# checks existence exactly once before deleting).
exit 0
STUB
chmod +x "$STUB_DIR/docker"

ORIG_PATH="$PATH"
export PATH="$STUB_DIR:$ORIG_PATH"

PROJECT="rmproj"
REPOS_DIR="$WORK/home/repos/$PROJECT"
SECRET_DIR="$DC_ROOT/$PROJECT"
CONFIG="$SECRET_DIR/config"

# Write a valid project config (strict loader format) + secrets, and plant the
# container as existing+running. idempotent setup so each case can reset.
setup_project() {
  rm -rf "$SECRET_DIR"
  mkdir -p "$SECRET_DIR" "$REPOS_DIR"
  chmod 700 "$SECRET_DIR"
  printf 'touch\n' > "$REPOS_DIR/source.txt"

  {
    printf 'CONTAINER_PROJECT="%s"\n' "$PROJECT"
    printf 'CONTAINER_OVERLAY_SCOPES=""\n'
    printf 'CONTAINER_IMAGE="dce-base:latest"\n'
    printf 'CONTAINER_BACKEND="docker"\n'
    printf 'CONTAINER_CPUS=""\n'
    printf 'CONTAINER_MEMORY=""\n'
    printf 'REPOS_DIR="%s"\n' "$REPOS_DIR"
    printf 'SECRET_DIR="%s"\n' "$SECRET_DIR"
    printf 'SSH_KEY_PATH="%s/ssh_key"\n' "$SECRET_DIR"
    printf 'TOKEN_FILE="%s/github-token"\n' "$SECRET_DIR"
    printf 'NPMRC_PATH="%s/.npmrc"\n' "$SECRET_DIR"
    printf 'PORTS=()\n'
    printf 'CONTAINER_HIDDEN_PATHS=(node_modules)\n'
  } > "$CONFIG"
  chmod 600 "$CONFIG"

  printf 'placeholder\n' > "$SECRET_DIR/github-token"
  chmod 600 "$SECRET_DIR/github-token"
  printf 'KEY\n' > "$SECRET_DIR/ssh_key"
  printf 'KEY.pub\n' > "$SECRET_DIR/ssh_key.pub"
  chmod 600 "$SECRET_DIR/ssh_key"

  printf '%s\n' "$PROJECT" > "$STATE/containers"
  : > "$LOG"
}

setup_absent_container() {
  setup_project
  : > "$STATE/containers"   # backend_exists / backend_is_running now false
}

run_rm() {
  HOME="$WORK/home" \
  DC_STUB_LOG="$LOG" DC_STUB_STATE="$STATE" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  bash "$ROOT_DIR/scripts/rm.sh" "$@"
}

hidden_vol="$(dce_hidden_volume_name "$PROJECT" "node_modules")"

destructive_logged() {
  grep -E "stop $PROJECT|rm -f $PROJECT|volume rm" "$LOG"
}

# ===========================================================================
# A. default rm (confirm 'yes'): stop -> rm -f -> volume rm; config gone;
#    REPOS_DIR preserved.
# ===========================================================================
setup_project
printf 'yes\n' | run_rm "$PROJECT" >"$WORK/a.stdout" 2>"$WORK/a.stderr" \
  || fail "dce rm (default) exited non-zero
-- stderr:$(cat "$WORK/a.stderr")"

stop_ln="$(grep -nE "^CALL docker stop $PROJECT" "$LOG" | head -n1 | cut -d: -f1)"
rm_ln="$(grep -nE "^CALL docker rm -f $PROJECT" "$LOG" | head -n1 | cut -d: -f1)"
[[ -n "$stop_ln" ]] || fail "dce rm: missing stop call
$(grep '^CALL' "$LOG")"
[[ -n "$rm_ln" ]] || fail "dce rm: missing rm -f call
$(grep '^CALL' "$LOG")"
[[ "$stop_ln" -lt "$rm_ln" ]] || fail "dce rm: stop must precede rm -f"
grep -Fq "CALL docker volume rm $hidden_vol" "$LOG" \
  || fail "dce rm: missing hidden volume removal [$hidden_vol]
$(grep '^CALL' "$LOG")"
[[ ! -d "$SECRET_DIR" ]] || fail "dce rm: config+secrets dir should be removed"
[[ -d "$REPOS_DIR" ]] || fail "dce rm: REPOS_DIR must be preserved"
[[ -f "$REPOS_DIR/source.txt" ]] || fail "dce rm: host code file must survive"
pass "dce rm (default): stop<delete<volume-rm, config removed, code preserved"

# ===========================================================================
# B. confirmation gate: a non-'yes' answer aborts with exit 0 and removes
#    nothing (no destructive calls; config still present).
# ===========================================================================
setup_project
printf 'no\n' | run_rm "$PROJECT" >"$WORK/b.stdout" 2>"$WORK/b.stderr" \
  || fail "dce rm: aborted run should exit 0"
[[ -d "$SECRET_DIR" ]] || fail "dce rm: aborted run must keep config dir"
if destructive_logged >/dev/null; then
  fail "dce rm: aborted run must not issue destructive calls
$(destructive_logged)"
fi
pass "dce rm: confirmation gate aborts without side effects"

# ===========================================================================
# C. --yes skips the prompt and removes everything.
# ===========================================================================
setup_project
run_rm "$PROJECT" --yes </dev/null >"$WORK/c.stdout" 2>"$WORK/c.stderr" \
  || fail "dce rm --yes exited non-zero
-- stderr:$(cat "$WORK/c.stderr")"
grep -Fq "CALL docker rm -f $PROJECT" "$LOG" || fail "dce rm --yes: missing rm -f"
[[ ! -d "$SECRET_DIR" ]] || fail "dce rm --yes: config should be removed"
pass "dce rm --yes: skips prompt, full teardown"

# ===========================================================================
# D. --keep-config: container + volumes removed; config+secrets preserved.
# ===========================================================================
setup_project
run_rm "$PROJECT" --yes --keep-config </dev/null >"$WORK/d.stdout" 2>&1 \
  || fail "dce rm --keep-config exited non-zero"
grep -Fq "CALL docker rm -f $PROJECT" "$LOG" || fail "dce rm --keep-config: missing rm -f"
grep -Fq "CALL docker volume rm $hidden_vol" "$LOG" || fail "dce rm --keep-config: missing volume rm"
[[ -d "$SECRET_DIR" ]] || fail "dce rm --keep-config: config dir must be preserved"
[[ -f "$SECRET_DIR/github-token" ]] || fail "dce rm --keep-config: secrets must be preserved"
pass "dce rm --keep-config: preserves config+secrets, removes container+volumes"

# ===========================================================================
# E. --keep-volumes: container + config removed; hidden volumes preserved.
# ===========================================================================
setup_project
run_rm "$PROJECT" --yes --keep-volumes </dev/null >"$WORK/e.stdout" 2>&1 \
  || fail "dce rm --keep-volumes exited non-zero"
grep -Fq "CALL docker rm -f $PROJECT" "$LOG" || fail "dce rm --keep-volumes: missing rm -f"
if grep -qE "volume rm" "$LOG"; then
  fail "dce rm --keep-volumes: must not remove volumes
$(grep 'volume' "$LOG")"
fi
[[ ! -d "$SECRET_DIR" ]] || fail "dce rm --keep-volumes: config should be removed"
pass "dce rm --keep-volumes: preserves volumes, removes container+config"

# ===========================================================================
# F. invalid project name is rejected before any work (no destructive calls).
# ===========================================================================
setup_project
: > "$LOG"
if run_rm "../evil" --yes </dev/null >"$WORK/f1.stdout" 2>"$WORK/f1.stderr"; then
  fail "dce rm: invalid name '../evil' must be rejected"
fi
grep -Fqi 'invalid project name' "$WORK/f1.stderr" || fail "dce rm: invalid-name error message missing"
if destructive_logged >/dev/null; then fail "dce rm: invalid name must not issue destructive calls"; fi
if run_rm "foo bar" --yes </dev/null >/dev/null 2>&1; then
  fail "dce rm: invalid name with space must be rejected"
fi
[[ -d "$SECRET_DIR" ]] || fail "dce rm: invalid-name run must leave existing config untouched"
pass "dce rm: rejects invalid project names safely"

# ===========================================================================
# G. container already absent: no stop/delete calls, but config still removed.
# ===========================================================================
setup_absent_container
run_rm "$PROJECT" --yes </dev/null >"$WORK/g.stdout" 2>&1 \
  || fail "dce rm (absent container) exited non-zero"
if grep -qE "stop $PROJECT|rm -f $PROJECT" "$LOG"; then
  fail "dce rm: must not stop/delete an absent container
$(grep -E 'stop|rm -f' "$LOG")"
fi
[[ ! -d "$SECRET_DIR" ]] || fail "dce rm (absent): config should still be removed"
[[ -d "$REPOS_DIR" ]] || fail "dce rm (absent): REPOS_DIR must be preserved"
pass "dce rm: already-absent container skips backend ops, still cleans config"

echo ""
echo "All dce rm lifecycle checks passed."
