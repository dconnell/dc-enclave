#!/usr/bin/env bash
# =============================================================================
# scripts/_editor-ext-watch.sh - Detached first-open extension watcher.
#
# Spawned by scripts/editor.sh when a `dce editor` open hits a container whose
# VS Code Server is not yet injected (first-ever attach). The server is
# injected by VS Code only AFTER it attaches -- the chicken-and-egg that makes
# synchronous enforcement impossible on first open -- so this watcher polls
# for it in the background and then runs the same idempotent enforcement
# (dce_ext_enforce_declared) the synchronous path would have run.
#
# The underscore prefix marks it internal (scripts/_dce precedent): the
# scripts/dce dispatcher only ever reaches explicitly registered
# scripts/<cmd>.sh case branches, so this can never be invoked as a dce
# subcommand. Best-effort by design: it ALWAYS exits 0, mirroring
# dce_ext_enforce_declared -- a watcher failure must never surface as a `dce
# editor` failure. That contract is enforced by running the entire post-argv
# body in a subshell (see the containment comment at the bottom of this file).
# Its outcome is recorded in the per-project log instead.
#
# argv: <project> <editor-id> <interval> <timeout>
# =============================================================================
set -euo pipefail

# Symlink-following script-root resolution, mirroring scripts/editor.sh:21-29:
# setup.sh may install dce through symlinks, so the libs must be sourced from
# the directory this script physically ships in, not from $PWD.
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/extensions.sh"

# Wrong argv is a caller (editor.sh) bug, not a user error: usage to stderr
# and exit 0 keeps the best-effort contract without ever blocking a launch.
if [[ $# -ne 4 ]]; then
  {
    echo "Usage: _editor-ext-watch.sh <project> <editor-id> <interval> <timeout>"
    echo "Internal watcher; spawned by scripts/editor.sh -- not a dce subcommand."
  } >&2
  exit 0
fi

# Timestamped, append-only log line. Explicit >>"$LOG" (never stdout): nohup
# detaches the watcher from any caller-owned redirection, so output must be
# appended to the log directly. Content is timestamps + extension IDs + status
# lines only -- never tokens/PII.
wlog() {
  local ts=""
  ts="$(date '+%Y-%m-%dT%H:%M:%S')" || ts="time-unavailable"
  # A failed append (e.g. an unwritable TMPDIR) must never kill the watcher:
  # losing one diagnostic line is always cheaper than a non-zero exit.
  printf '%s %s\n' "$ts" "$*" >> "$LOG" || true
}

# Usable-project-name failure note (see _dce_ext_watch_log_path /
# _dce_ext_watch_lock_dir in lib/extensions.sh, which fail closed on a name
# that cannot form a safe TMPDIR path). Usage-style note to stderr + success:
# an unusable name is not a user-facing error, and the containment below makes
# the exit-0 belt-and-braces anyway -- this exists to explain WHY nothing ran.
_watch_unusable_project_note() {
  {
    echo "Project name '$1' is not usable for watcher state paths; nothing to watch."
    echo "Internal watcher; spawned by scripts/editor.sh -- not a dce subcommand."
  } >&2
}

watch_main() {
  PROJECT="$1"
  EDITOR_ID="$2"
  INTERVAL="$3"
  TIMEOUT="$4"

  LOG="$(_dce_ext_watch_log_path "$PROJECT")" || {
    _watch_unusable_project_note "$PROJECT"
    return 0
  }
  LOCK="$(_dce_ext_watch_lock_dir "$PROJECT")" || {
    _watch_unusable_project_note "$PROJECT"
    return 0
  }

  # Project config supplies CONTAINER_BACKEND + CONTAINER_OVERLAY_SCOPES; a
  # missing config means there is nothing declared for this project to converge.
  CONFIG="$HOME/.config/dce-enclave/$PROJECT/config"
  if [[ ! -f "$CONFIG" ]]; then
    wlog "no config for '$PROJECT'; nothing to watch"
    return 0
  fi
  if ! dce_load_project_config "$CONFIG"; then
    wlog "config for '$PROJECT' failed validation; watch aborted"
    return 0
  fi
  if ! backend_use "${CONTAINER_BACKEND:-}"; then
    wlog "container backend unavailable for '$PROJECT'; watch aborted"
    return 0
  fi
  # Global config supplies DC_TEAM_DIR/DC_USER_DIR for the enforcement call.
  # Deliberately tolerant (mirrors the editor.sh spawn site): a broken global
  # config must never crash the watcher -- empty roots then behave as
  # pre-adoption inside dce_ext_enforce_declared's own guards (quiet no-op).
  # The `|| true` alone cannot contain a dce_die (it exits the whole process);
  # the subshell wrapping watch_main is what actually contains it.
  dce_load_global_config >/dev/null 2>&1 || true

  # --- Single-flight lock ------------------------------------------------------
  # (a) A fresh lock means another watcher is already mid-watch for this
  #     project: log and leave WITHOUT touching the log truncation below (a
  #     latecomer must never clobber the active watcher's log).
  if [[ -d "$LOCK" ]] && ! _dce_ext_watch_lock_stale "$LOCK"; then
    wlog "watcher already active for '$PROJECT'; exiting without installing"
    return 0
  fi
  # (b)+(c) Stale/missing lock: take over. mkdir is the atomic primitive that
  #     decides a race -- the loser fails here and exits quietly.
  #     Accepted TOCTOU: a concurrently starting watcher can observe this lock
  #     in the mkdir->deadline-write window and read it as stale (stealing it).
  #     The window is a scheduler tick and the worst case is duplicate but
  #     idempotent installs, while failing open here is what guarantees a
  #     garbage or half-written lock can never wedge convergence permanently.
  rm -rf "$LOCK"
  if ! mkdir "$LOCK" 2>/dev/null; then
    wlog "could not acquire the watch lock for '$PROJECT'; exiting"
    return 0
  fi
  # Traps are registered immediately after winning the lock: from here on, the
  # lock is removed synchronously in the EXIT trap on EVERY exit path (success,
  # timeout, stopped container, INT/TERM folded into the same path, and any
  # failure between taking the lock and writing the deadline -- a trap-last
  # order would leak the lock on exactly those intermediate failures).
  # Earlier exit paths (unusable name, no config, already-active watcher, lost
  # mkdir race) never register the trap -- they can therefore never remove a
  # lock they do not hold, in particular the one an active watcher owns.
  trap 'rm -rf "$LOCK"' EXIT
  # Terminal closed / logout mid-watch: fold into the same exit path so the EXIT
  # trap (lock removal) still runs and the exit status stays 0.
  trap 'exit 0' INT TERM
  # (d) Deadline = now + timeout + 2*interval, rounded UP to an integer epoch.
  #     It bounds how long an orphaned lock (SIGKILLed watcher, host crash) can
  #     block a replacement. awk does the math: bash arithmetic cannot hold the
  #     fractional interval.
  now="$(date +%s)" || now=0
  deadline=""
  if ! deadline="$(awk -v _now="$now" -v _t="$TIMEOUT" -v _i="$INTERVAL" \
    'BEGIN { _d = _now + _t + 2 * _i; printf "%d\n", (_d == int(_d)) ? _d : int(_d) + 1 }')"; then
    # Unusable deadline -> the lock reads as stale immediately (fail open), so a
    # follow-up watcher can always take over rather than be blocked forever.
    deadline="$now"
  fi
  printf '%s\n' "$deadline" > "$LOCK/deadline" || true
  # (e) Truncate + lock down the log ONLY after winning the lock: the log
  #     reflects the latest PROCEEDING watch (start-of-run truncate + append),
  #     and a latecomer that exited at (a) can never wipe the active watcher's
  #     lines. Truncation is guarded: an unwritable log must not kill the lock
  #     holder via set -e -- the run then proceeds log-less (best-effort).
  : > "$LOG" 2>/dev/null || true
  chmod 600 "$LOG" 2>/dev/null || true

  # --- Wait loop ---------------------------------------------------------------
  # bash SECONDS is integer, so the fractional timeout is pre-ceil'd to an
  # integer deadline (awk again; bash arithmetic cannot hold e.g. 0.2).
  timeout_ceil="$(awk -v _t="$TIMEOUT" \
    'BEGIN { printf "%d\n", (_t == int(_t)) ? _t : int(_t) + 1 }')" || timeout_ceil=1
  watch_start="$SECONDS"
  while :; do
    # Container went away (stopped/rebuilt mid-watch): bail quietly; the next
    # `dce editor` re-spawns a watcher.
    if ! backend_is_running "$PROJECT" 2>/dev/null; then
      wlog "container '$PROJECT' stopped before VS Code Server was injected; watch ended without installs"
      return 0
    fi
    # Server landed (VS Code injected its code-server CLI): converge now.
    if dce_ext_list_installed "$EDITOR_ID" "$PROJECT" >/dev/null 2>&1; then
      break
    fi
    elapsed=$(( SECONDS - watch_start ))
    if (( elapsed >= timeout_ceil )); then
      wlog "VS Code Server not injected within ${TIMEOUT}s; extensions not installed. Run 'dce editor $PROJECT' again once the editor has attached."
      return 0
    fi
    sleep "$INTERVAL"
  done

  # Re-arm the deadline to now+timeout: enforcement can outlast the original
  # 2*interval grace, and an expiring deadline mid-install would let a re-run
  # take over and truncate this live watcher's log. Unusable re-arm -> now
  # (immediately stale, i.e. fail open, matching the (d) posture).
  now="$(date +%s)" || now=0
  deadline="$now"
  deadline="$(awk -v _now="$now" -v _t="$TIMEOUT" \
    'BEGIN { _d = _now + _t; printf "%d\n", (_d == int(_d)) ? _d : int(_d) + 1 }' 2>/dev/null)" \
    || deadline="$now"
  printf '%s\n' "$deadline" > "$LOCK/deadline" 2>/dev/null || true

  wlog "VS Code Server detected for '$PROJECT'; enforcing declared extensions"
  # Same idempotent enforcement as the synchronous path (same per-id retry
  # semantics); output goes to the log, and failure is never fatal here.
  dce_ext_enforce_declared "$PROJECT" "$EDITOR_ID" "${DC_TEAM_DIR:-}" "${DC_USER_DIR:-}" \
    "${CONTAINER_OVERLAY_SCOPES:-}" >>"$LOG" 2>&1 || true
  wlog "watch complete for '$PROJECT'"
  return 0
}

# The post-argv body runs inside a subshell because dce_die
# (lib/common/core.sh) calls `exit 1` on the WHOLE process: `|| true` and
# `if !` guards around the config loaders cannot contain it, so without this
# containment a missing/broken global config or a security-shape failure in a
# project config would leak a non-zero exit and break the ALWAYS-exits-0
# contract. A dce_die or set -e failure anywhere inside watch_main exits only
# the subshell -- which the outer `|| exit 0` neutralizes. All state (loaded
# config vars, lock, traps) lives inside for the same reason.
( watch_main "$@" ) || exit 0
exit 0
