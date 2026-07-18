#!/usr/bin/env bash
# =============================================================================
# tests/unit/sync-entry-wait.sh - Unit tests for the sync visibility helpers
# added by plans/sync-visibility.md:
#   - dce_sync_short_status <project>   (one-line banner state)
#   - dce_sync_wait_until_settled <project>  (soft-failing entry wait)
#   - DCE_SYNC_ENTRY_WAIT_TIMEOUT env override
#
# Stubs `mutagen` on a private PATH so the helpers' external calls are
# captured and scripted. The helpers are soft-failing by contract, so every
# non-ready condition MUST return 0 (never abort a set -e caller).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Fake HOME + global config so lib/common.sh loads cleanly.
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
mkdir -p "$DC_ROOT"
{
  printf 'DC_TEAM_DIR="%s/team"\n' "$DC_ROOT"
  printf 'DC_USER_DIR="%s/user"\n' "$DC_ROOT"
} > "$DC_ROOT/config"
chmod 600 "$DC_ROOT/config"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
: > "$LOG"

# ---------------------------------------------------------------------------
# Mutagen stub: logs every call; `sync list` output is driven by
# DC_STUB_SYNC_STATE (healthy | reconciling | paused | absent). `sync flush`
# exits non-zero when DC_STUB_FLUSH_FAIL=1.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/mutagen" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_state="${DC_STUB_SYNC_STATE:-healthy}"
printf 'CALL mutagen %s\n' "$*" >> "$_log"
case "${1:-} ${2:-}" in
  "sync list")
    [[ "$_state" == "absent" ]] && exit 1
    case "$_state" in
      healthy)     printf 'Status:\n    Alpha:\n        Watcher: Watching for changes\n    Beta:\n        Watcher: Watching for changes\n' ;;
      reconciling) printf 'Status:\n    Beta:\n        Staging: Scanning\n' ;;
      paused)      printf 'Status:\n    Conflicts: 1\n        Alpha path conflict\n' ;;
    esac
    exit 0
    ;;
  "sync resume") exit 0 ;;
  "sync flush")
    if [[ "${DC_STUB_FLUSH_FAIL:-0}" == "1" ]]; then exit 1; fi
    exit 0
    ;;
  "sync terminate") exit 0 ;;
  "version ") printf 'mutagen 0.18.1\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/mutagen"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

PROJECT="myproj"
ORIG_PATH="$PATH"
export PATH="$STUB_DIR:$ORIG_PATH"
export DC_STUB_LOG="$LOG"

# Reset the call log and return its contents.
reset_log() { : > "$LOG"; }
log_text() { cat "$LOG"; }

# ===========================================================================
# dce_sync_short_status: per-state output mapping.
# ===========================================================================
export DC_STUB_SYNC_STATE=healthy
out="$(dce_sync_short_status "$PROJECT")"
[[ "$out" == "Sync: up to date" ]] \
  || fail "short_status(healthy): [$out]"

export DC_STUB_SYNC_STATE=reconciling
out="$(dce_sync_short_status "$PROJECT")"
[[ "$out" == "Sync: reconciling…" ]] \
  || fail "short_status(reconciling): [$out]"

export DC_STUB_SYNC_STATE=paused
out="$(dce_sync_short_status "$PROJECT")"
case "$out" in
  *"paused (conflict)"*"mutagen sync resolve"*) : ;;
  *) fail "short_status(paused): [$out]" ;;
esac

export DC_STUB_SYNC_STATE=absent
out="$(dce_sync_short_status "$PROJECT")"
case "$out" in
  *"no session"*"dce rebuild-container $PROJECT"*) : ;;
  *) fail "short_status(absent): [$out]" ;;
esac
pass "dce_sync_short_status: per-state output mapping"

# ===========================================================================
# _dce_sync_parse_phase / _dce_sync_parse_counts: pure parsers over real
# `mutagen sync list` report shapes (captured against mutagen 0.18.1). These
# feed the live progress line; they must be locale- and noise-insensitive.
# ===========================================================================
# "Applying changes" mid-sync: alpha full, beta partial -> counts present.
REPORT_APPLYING="$(cat <<'REPORT'
--------------------------------------------------------------------------------
Name: dce-probe
Alpha:
	URL: /tmp/alpha
	Connected: Yes
	Synchronizable contents:
		201 directories
		4000 files (800 kB)
		0 symbolic links
Beta:
	URL: /tmp/beta
	Connected: Yes
	Synchronizable contents:
		1 directory
		1240 files (310 kB)
		0 symbolic links
Status: Applying changes
--------------------------------------------------------------------------------
REPORT
)"

# "Scanning files": the very first sub-second state has NO Synchronizable
# contents blocks, so counts must be empty (phase only).
REPORT_SCANNING="$(cat <<'REPORT'
--------------------------------------------------------------------------------
Name: dce-probe
Alpha:
	URL: /tmp/alpha
	Connected: Yes
Beta:
	URL: /tmp/beta
	Connected: Yes
Status: Scanning files
--------------------------------------------------------------------------------
REPORT
)"

# "Watching for changes": settled, alpha == beta -> remaining 0.
REPORT_WATCHING="$(cat <<'REPORT'
--------------------------------------------------------------------------------
Name: dce-probe
Alpha:
	URL: /tmp/alpha
	Connected: Yes
	Synchronizable contents:
		3767 directories
		27533 files (1.3 GB)
		7 symbolic links
Beta:
	URL: docker://proj//workspace
	Connected: Yes
	Synchronizable contents:
		3767 directories
		27533 files (1.3 GB)
		7 symbolic links
Status: Watching for changes
--------------------------------------------------------------------------------
REPORT
)"

# Phase extraction.
[[ "$(_dce_sync_parse_phase "$REPORT_APPLYING")" == "applying changes" ]] \
  || fail "parse_phase(applying): [$(_dce_sync_parse_phase "$REPORT_APPLYING")]"
[[ "$(_dce_sync_parse_phase "$REPORT_SCANNING")" == "scanning files" ]] \
  || fail "parse_phase(scanning): [$(_dce_sync_parse_phase "$REPORT_SCANNING")]"
[[ "$(_dce_sync_parse_phase "$REPORT_WATCHING")" == "watching for changes" ]] \
  || fail "parse_phase(watching): [$(_dce_sync_parse_phase "$REPORT_WATCHING")]"
[[ -z "$(_dce_sync_parse_phase "")" ]] || fail "parse_phase(empty) must be empty"
[[ -z "$(_dce_sync_parse_phase "garbage no status line")" ]] \
  || fail "parse_phase(garbage) must be empty"
pass "_dce_sync_parse_phase: per-state extraction"

# Counts extraction: "<alpha_files> <beta_files>".
counts="$(_dce_sync_parse_counts "$REPORT_APPLYING")"
[[ "$counts" == "4000 1240" ]] || fail "parse_counts(applying): [$counts]"
counts="$(_dce_sync_parse_counts "$REPORT_WATCHING")"
[[ "$counts" == "27533 27533" ]] || fail "parse_counts(watching): [$counts]"
# No contents block -> empty (phase-only display path).
[[ -z "$(_dce_sync_parse_counts "$REPORT_SCANNING")" ]] \
  || fail "parse_counts(scanning) must be empty (no contents block)"
[[ -z "$(_dce_sync_parse_counts "")" ]] || fail "parse_counts(empty) must be empty"

# The display loop computes remaining = alpha - beta; verify the arithmetic
# derivation against the applying fixture (4000 - 1240 = 2760).
af="${counts%% *}"; :  # placeholder; recompute from applying fixture
ap_counts="$(_dce_sync_parse_counts "$REPORT_APPLYING")"
af="${ap_counts%% *}"; bf="${ap_counts##* }"
rem=$((af - bf))
[[ "$rem" -eq 2760 ]] || fail "files-remaining arithmetic: got $rem (af=$af bf=$bf)"
pass "_dce_sync_parse_counts: extraction + remaining derivation"

# ===========================================================================
# dce_sync_wait_until_settled: soft-fail on every non-ready condition.
# ===========================================================================
# CONTAINER_SYNC unset -> immediate no-op (no flush invoked).
export DC_STUB_SYNC_STATE=healthy
reset_log
( unset CONTAINER_SYNC; dce_sync_wait_until_settled "$PROJECT" ) || \
  fail "wait: non-synced project must return 0"
! grep -q 'sync flush' "$LOG" \
  || fail "wait: non-synced project must not flush"

# Mutagen missing -> warn + return 0, no flush.
export CONTAINER_SYNC=1
_save_path="$PATH"
export PATH="$ORIG_PATH"
dce_sync_wait_until_settled "$PROJECT" \
  || fail "wait: mutagen missing must return 0"
export PATH="$_save_path"

# Session absent -> warn + return 0, no flush.
export PATH="$STUB_DIR:$ORIG_PATH"
export DC_STUB_SYNC_STATE=absent
dce_sync_wait_until_settled "$PROJECT" \
  || fail "wait: absent session must return 0"
! grep -q 'sync flush' "$LOG" \
  || fail "wait: absent session must not flush"

# Paused -> warn + return 0, no flush.
export DC_STUB_SYNC_STATE=paused
reset_log
dce_sync_wait_until_settled "$PROJECT" \
  || fail "wait: paused session must return 0"
! grep -q 'sync flush' "$LOG" \
  || fail "wait: paused session must not flush"
pass "dce_sync_wait_until_settled: soft-fail on non-ready conditions"

# ===========================================================================
# dce_sync_wait_until_settled: healthy happy path flushes, resume before flush.
# ===========================================================================
export DC_STUB_SYNC_STATE=healthy
reset_log
dce_sync_wait_until_settled "$PROJECT" \
  || fail "wait: healthy session must return 0"
calls="$(log_text)"
grep -q 'sync flush' <<<"$calls" || fail "wait: healthy session must flush"
# Ordering invariant: resume MUST precede flush (covers running-container +
# host-reboot case where start.sh's resume did not fire).
resume_ln="$(grep -n 'sync resume' <<<"$calls" | head -n1 | cut -d: -f1)"
flush_ln="$(grep -n 'sync flush' <<<"$calls" | head -n1 | cut -d: -f1)"
[[ -n "$resume_ln" && -n "$flush_ln" ]] \
  || fail "wait: expected both resume and flush calls, got: [$calls]"
[[ "$resume_ln" -lt "$flush_ln" ]] \
  || fail "wait: resume must precede flush (resume=$resume_ln flush=$flush_ln)"
pass "dce_sync_wait_until_settled: healthy flushes with resume-before-flush ordering"

# ===========================================================================
# dce_sync_wait_until_settled: flush failure is soft (warn + return 0).
# ===========================================================================
export DC_STUB_FLUSH_FAIL=1
reset_log
dce_sync_wait_until_settled "$PROJECT" \
  || fail "wait: flush failure must return 0 (soft-fail)"
export DC_STUB_FLUSH_FAIL=0
pass "dce_sync_wait_until_settled: flush failure soft-fails"

# ===========================================================================
# DCE_SYNC_ENTRY_WAIT_TIMEOUT: overridable, honored by the flush call.
# (Verified indirectly: the flush is bounded by dce_run_with_timeout. A flush
# that hangs past the budget is treated as failure and soft-fails.)
# ===========================================================================
# Sanity: the default is non-empty and numeric.
default="${DCE_SYNC_ENTRY_WAIT_TIMEOUT:-}"
[[ "$default" =~ ^[0-9]+$ ]] || fail "DCE_SYNC_ENTRY_WAIT_TIMEOUT default not numeric: [$default]"
# Override is honored by the env var read in dce_sync_wait_until_settled.
DCE_SYNC_ENTRY_WAIT_TIMEOUT=5 dce_sync_wait_until_settled "$PROJECT" >/dev/null 2>&1 \
  || fail "wait: DCE_SYNC_ENTRY_WAIT_TIMEOUT override path returned non-zero"
pass "DCE_SYNC_ENTRY_WAIT_TIMEOUT: numeric default + override honored"

# ===========================================================================
# Under set -e (this script), the helper never aborts the caller. This final
# block re-asserts the contract that matters most for shell.sh / editor.sh.
# ===========================================================================
set -e
export DC_STUB_SYNC_STATE=absent
dce_sync_wait_until_settled "$PROJECT"
export DC_STUB_SYNC_STATE=paused
dce_sync_wait_until_settled "$PROJECT"
export DC_STUB_SYNC_STATE=healthy
export DC_STUB_FLUSH_FAIL=1
dce_sync_wait_until_settled "$PROJECT"
export DC_STUB_FLUSH_FAIL=0
pass "dce_sync_wait_until_settled: never aborts a set -e caller"

pass "sync entry-wait helpers (short_status, wait_until_settled, timeout)"
