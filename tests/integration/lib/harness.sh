#!/usr/bin/env bash
# =============================================================================
# tests/integration/lib/harness.sh - Core integration test harness.
#
# Owns the per-run workspace, the resource registry, command logging, the
# pass/fail result log, and the trap that GUARANTEES cleanup runs even on
# interrupt. Case files and the matrix engine use ONLY the public `it_*` API
# here, never the dce/lib internals, so the cleanup contract holds regardless
# of what a case does.
#
# Public API (see per-function docs):
#   it_init                       stamp run id, build workspace, arm the trap
#   it_register_project <name>    record a created project for cleanup replay
#   it_register_network <name>    record a created network for cleanup replay
#   it_log_path <backend> <case>  artifacts log file for one case
#   it_dce <b> <case> <args...>   run scripts/dce (logged), return real rc
#   it_dce_capture <b> <case>...  same, and echo combined output to stdout
#   it_record <b> <status> <case> [detail]   append to the results log
#   it_run_case <b> <case> <fn>   run a case fn; record PASS/FAIL; per-case rm
#
# Cleanup contract lives in cleanup.sh (sourced below): the EXIT/INT/TERM trap
# replays `dce rm --yes` for every registered project, runs backend sweeps,
# drops test networks + temp dirs, and verifies zero leftovers.
# =============================================================================
if [[ -n "${_IT_HARNESS_SH_LOADED:-}" ]]; then return 0; fi
declare -gr _IT_HARNESS_SH_LOADED=1

_IT_HARNESS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IT_ROOT="$(cd "$_IT_HARNESS_DIR/../../.." && pwd)"
_IT_LIB_DIR="$_IT_ROOT/lib"
_IT_DCE="$_IT_ROOT/scripts/dce"
export _IT_ROOT _IT_LIB_DIR _IT_DCE

# Bring in naming + discovery. (cleanup.sh is sourced after its deps below.)
# shellcheck disable=SC1091  # sibling lib, path resolved above
source "$_IT_HARNESS_DIR/naming.sh"
# shellcheck disable=SC1091  # sibling lib, path resolved above
source "$_IT_HARNESS_DIR/backend-discovery.sh"

# Stamp the run id up front so every helper shares one token.
it_run_id >/dev/null

# Workspace layout (one self-contained tree per run under /tmp):
#   $IT_ROOT_WS/                          /tmp/dce-integration/<runid>/
#     repos/                              DC_REPOS_DIR target (isolated host mounts)
#     created.tsv                         resource registry: kind<TAB>backend<TAB>name
#     results.tsv                         per-case: backend<TAB>status<TAB>case<TAB>detail
#     backends.tsv                        the selected backend list (one per line)
# Repo-relative artifacts (kept out of the working tree via .gitignore):
#   tests/integration/artifacts/<runid>/<backend>/<case>.log
export IT_ROOT_WS; IT_ROOT_WS="$(it_workspace_root)"
export IT_REPOS_DIR; IT_REPOS_DIR="$IT_ROOT_WS/repos"
export IT_REGISTRY; IT_REGISTRY="$IT_ROOT_WS/created.tsv"
export IT_RESULTS; IT_RESULTS="$IT_ROOT_WS/results.tsv"
export IT_ARTIFACTS_ROOT; IT_ARTIFACTS_ROOT="$_IT_ROOT/tests/integration/artifacts"
mkdir -p "$IT_REPOS_DIR" "$IT_ARTIFACTS_ROOT"
: > "$IT_REGISTRY"
: > "$IT_RESULTS"

# Isolate repo mounts so host projects are never touched by the suite.
export DC_REPOS_DIR="$IT_REPOS_DIR"

# Isolate HOME + the global config too, not just repos. `dce new` calls
# dce_load_global_config, which hard-requires ~/.config/dce-enclave/config: it
# IGNORES env DC_TEAM_DIR (roots are unset first) and dce_die's if the file or
# the team/user roots are missing. A host that never ran scripts/setup.sh (e.g.
# CI) therefore sees every `dce new` fail. Two modes:
#   - Default (apple/docker/orbstack): isolate HOME under the run workspace and
#     write a minimal global config, so the suite is hermetic and never touches
#     the operator's real config. Cleanup wipes IT_ROOT_WS, which holds this HOME.
#   - Real HOME (colima/podman): colima's docker socket/context and podman's
#     machine connection live under ~/.docker and ~/.config/containers, which an
#     isolated HOME cannot see. The suite keeps the real HOME and only seeds the
#     config when it is MISSING -- never overwrite, so a developer's real setup
#     is left intact. This is auto-detected; DCE_TEST_REAL_HOME=1 forces it on.
_it_ensure_global_config() {  # <home>
  local h="$1" team user cfg
  team="$h/.config/dce-enclave/team"
  user="$h/.config/dce-enclave/user"
  cfg="$h/.config/dce-enclave/config"
  if [[ -f "$cfg" ]]; then
    return 0
  fi
  mkdir -p "$team/overlays" "$team/container-recipes" \
           "$user/overlays" "$user/container-recipes"
  cat > "$cfg" <<EOF
DC_TEAM_DIR="$team"
DC_USER_DIR="$user"
EOF
}

# True if the real HOME must be kept for this run. Colima stores its docker
# socket/context under ~/.docker; podman stores its machine connection under
# ~/.config/containers -- both are invisible to an isolated HOME. Auto-detects
# from INTEGRATION_BACKENDS (explicit selection) or CLI availability (auto-detect
# path), so the operator never has to set DCE_TEST_REAL_HOME manually.
_it_should_use_real_home() {
  # Explicit override (escape hatch for CI or debugging).
  [[ "${DCE_TEST_REAL_HOME:-0}" == "1" ]] && return 0

  local backends="${INTEGRATION_BACKENDS:-}"
  if [[ -z "$backends" ]]; then
    # No explicit selection: auto-detection will pick up any installed backend.
    command -v colima >/dev/null 2>&1 && return 0
    command -v podman >/dev/null 2>&1 && return 0
    return 1
  fi
  # Explicit selection: check if colima or podman is in the comma-list.
  [[ ",${backends}," == *",colima,"* || ",${backends}," == *",podman,"* ]]
}

if _it_should_use_real_home; then
  _it_ensure_global_config "$HOME"
else
  _IT_REAL_HOME="$HOME"
  export HOME="$IT_ROOT_WS/home"
  # Safety guard: the isolated HOME must be a fresh path UNDER the run workspace
  # and distinct from the operator's real home. If IT_ROOT_WS were ever empty the
  # assignment above would collapse HOME to "/home" (a real/system dir); refuse
  # to proceed before writing anything so the suite can never land in a real home.
  if [[ -z "$IT_ROOT_WS" || "$HOME" == "$_IT_REAL_HOME" || "$HOME" != "$IT_ROOT_WS"/* ]]; then
    echo "ERROR: integration harness refusing unsafe isolated HOME" >&2
    echo "  IT_ROOT_WS='${IT_ROOT_WS:-<empty>}'  new HOME='$HOME'  real HOME='$_IT_REAL_HOME'" >&2
    exit 1
  fi
  # The isolated HOME hides docker CLI plugins (notably buildx, which lives at
  # ~/.docker/cli-plugins) that are installed under the real HOME. apple/
  # container's peer-build fallback drives `docker build`, and modern
  # Containerfiles (Containerfile.base heredocs) need buildx -- so without this
  # link the apple fallback aborts with "buildx component missing" on apple-only
  # runs (which use the isolated HOME). Link only the plugins dir so the real
  # docker config/contexts stay unexposed.
  if [[ -d "$_IT_REAL_HOME/.docker/cli-plugins" ]]; then
    mkdir -p "$HOME/.docker"
    ln -s "$_IT_REAL_HOME/.docker/cli-plugins" "$HOME/.docker/cli-plugins"
  fi
  _it_ensure_global_config "$HOME"
fi

# cleanup.sh pulls in the lib (for leak sweeps) and defines it_cleanup, which is
# the trap body. Sourced here (after _IT_DCE / globals exist) so it sees them.
# shellcheck disable=SC1091  # sibling lib, path resolved above
source "$_IT_HARNESS_DIR/cleanup.sh"

_IT_CLEANUP_RAN=0
_IT_CASE_SEQ=0
# Arm the safety net: EXIT covers normal return + `exit`, INT/TERM cover Ctrl-C
# and `kill`. The body is idempotent and re-entrant (guarded by _IT_CLEANUP_RAN).
trap it_cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Resource registry
# ---------------------------------------------------------------------------

# Record a created project so the finalizer can replay `dce rm --yes` on it.
# Call this immediately after a successful `dce new` (cleanup contract: every
# created project is tracked + removed).
it_register_project() {  # <project-name> <backend>
  printf 'project\t%s\t%s\n' "$2" "$1" >> "$IT_REGISTRY"
}

# Record a created private network so the finalizer can drop it.
it_register_network() {  # <network-name> <backend>
  printf 'network\t%s\t%s\n' "$2" "$1" >> "$IT_REGISTRY"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Echo the artifact log path for one (backend, case); creates the dir.
it_log_path() {  # <backend> <case>
  local d="$IT_ARTIFACTS_ROOT/$IT_RUN_ID/$1"
  [[ -d "$d" ]] || mkdir -p "$d"
  printf '%s/%s.log\n' "$d" "$2"
}

# Run scripts/dce under CONTAINER_BACKEND=<backend>, appending a timestamped
# command line + exit code and all output to the case log. Output is NOT shown
# on stdout (use it_dce_capture when a case must inspect output). Returns the
# real exit code so cases can assert expected_exit.
it_dce() {  # <backend> <case> <args...>
  local backend="$1" case_id="$2"; shift 2
  local log; log="$(it_log_path "$backend" "$case_id")"
  {
    printf '\n[%s] $ CONTAINER_BACKEND=%s dce %s\n' "$(date -u +%FT%TZ)" "$backend" "$*"
  } >> "$log"
  local rc
  CONTAINER_BACKEND="$backend" "$_IT_DCE" "$@" >>"$log" 2>&1 && rc=0 || rc=$?
  printf '[%s] exit=%d\n' "$(date -u +%FT%TZ)" "$rc" >> "$log"
  return "$rc"
}

# Like it_dce, but also echoes the command's combined output to stdout (after
# logging it) so the case can grep it. The `&& rc=0 || rc=$?` form survives a
# caller's `set -e` (the assignment is part of an AND/OR list, so a non-zero
# command does not abort before rc is captured).
it_dce_capture() {  # <backend> <case> <args...>
  local backend="$1" case_id="$2"; shift 2
  local log; log="$(it_log_path "$backend" "$case_id")"
  {
    printf '\n[%s] $ CONTAINER_BACKEND=%s dce %s\n' "$(date -u +%FT%TZ)" "$backend" "$*"
  } >> "$log"
  local out rc
  out="$(CONTAINER_BACKEND="$backend" "$_IT_DCE" "$@" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "$out" >> "$log"
  printf '[%s] exit=%d\n' "$(date -u +%FT%TZ)" "$rc" >> "$log"
  printf '%s\n' "$out"
  return "$rc"
}

# Run scripts/dce with a fixed string on stdin (for prompt-gated paths like
# rebuild-container --rotate-keys, whose key-rotation pause needs an Enter even
# under --yes). Logged like it_dce; returns the real exit code.
it_dce_in() {  # <backend> <case> <stdin-string> <args...>
  local backend="$1" case_id="$2" input="$3"; shift 3
  local log; log="$(it_log_path "$backend" "$case_id")"
  {
    printf '\n[%s] $ CONTAINER_BACKEND=%s dce %s  (stdin fed)\n' "$(date -u +%FT%TZ)" "$backend" "$*"
  } >> "$log"
  local rc
  printf '%s' "$input" | CONTAINER_BACKEND="$backend" "$_IT_DCE" "$@" >>"$log" 2>&1 && rc=0 || rc=$?
  printf '[%s] exit=%d\n' "$(date -u +%FT%TZ)" "$rc" >> "$log"
  return "$rc"
}

# Portable bounded execution. Prefers GNU `timeout`/`gtimeout` when present;
# falls back to a native bg-job + sleep + kill. Returns 124 on timeout (GNU
# convention) so callers can distinguish "ran out of time" from a real exit.
# Used by the `logs --follow` case so the suite never hangs on a -f stream.
it_timeout() {  # <seconds> <cmd...>
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  # Native fallback.
  "$@" &
  local pid=$!
  ( sleep "$secs" 2>/dev/null; kill "$pid" >/dev/null 2>&1 ) &
  local killer=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill "$killer" >/dev/null 2>&1 || true
  wait "$killer" 2>/dev/null || true
  [[ $rc -gt 128 ]] && return 124   # killed by our signal == timeout
  return "$rc"
}

# ---------------------------------------------------------------------------
# Result recording + case runner
# ---------------------------------------------------------------------------

# Append one result row. status ∈ PASS|FAIL|SKIP. detail is forced to one line
# (newlines collapsed) so the TSV stays parseable for the final summary.
it_record() {  # <backend> <status> <case> [detail...]
  local backend="$1" status="$2" case_id="$3"; shift 3
  local detail="$*"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$backend" "$status" "$case_id" "$detail" >> "$IT_RESULTS"
}

# Run a single case: invoke <fn> (which may call it_dce*/it_register_*), then
# ALWAYS run per-case cleanup (`dce rm --yes`) for any project this case
# registered, then record PASS/FAIL. The case fn signals failure by calling
# `it_case_fail "detail"` (which sets a flag) OR by returning non-zero; either
# is recorded as FAIL without aborting the run. Per-case rm guarantees the
# "every created project removed via dce rm at least once" contract even when a
# case dies mid-flight (the global finalizer is the idempotent backstop).
it_run_case() {  # <backend> <case-id> <fn> [fn-args...]
  local backend="$1" case_id="$2" fn="$3"; shift 3

  # Shard support: split a backend's cases across parallel jobs (modulo) so a
  # slow backend (e.g. podman on WSL2) can be parallelized without reducing
  # coverage. The counter advances for EVERY case so the case->shard mapping
  # is stable per run order; sharded-out cases return without running or
  # recording. No-op when INTEGRATION_SHARD_TOTAL is unset (full run).
  _IT_CASE_SEQ=$((_IT_CASE_SEQ + 1))
  if [[ -n "${INTEGRATION_SHARD_TOTAL:-}" ]]; then
    if (( _IT_CASE_SEQ % INTEGRATION_SHARD_TOTAL != ${INTEGRATION_SHARD_INDEX:-0} )); then
      return 0
    fi
  fi

  local _it_started _it_finished _it_elapsed
  _it_started="$(date +%s)"

  _IT_CASE_FAILED=0
  _IT_CASE_SKIPPED=0
  _IT_CASE_DETAIL=""

  # shellcheck disable=SC1091  # case fn is caller-supplied, invoked by name
  if ! "$fn" "$backend" "$case_id" "$@"; then
    if [[ $_IT_CASE_SKIPPED -eq 0 && $_IT_CASE_FAILED -eq 0 ]]; then
      _IT_CASE_FAILED=1
      _IT_CASE_DETAIL="${_IT_CASE_DETAIL:-case fn returned non-zero}"
    fi
  fi

  # Per-case cleanup: rm --yes every project in the registry. Cases run
  # sequentially and each registers only its own project(s), so this removes the
  # case's project; re-running rm on an already-removed project is a harmless
  # no-op (the global finalizer is the idempotent backstop for interrupts).
  local kind pname pback
  while IFS=$'\t' read -r kind pback pname; do
    [[ "$kind" == "project" ]] || continue
    CONTAINER_BACKEND="$pback" "$_IT_DCE" rm "$pname" --yes \
      >>"$(it_log_path "$pback" "$case_id")" 2>&1 || true
  done < "$IT_REGISTRY"

  _it_finished="$(date +%s)"
  _it_elapsed=$((_it_finished - _it_started))
  printf '[%s] case-duration=%ss\n' "$(date -u +%FT%TZ)" "$_it_elapsed" \
    >>"$(it_log_path "$backend" "$case_id")"

  if [[ $_IT_CASE_SKIPPED -eq 1 ]]; then
    it_record "$backend" SKIP "$case_id" "${_IT_CASE_DETAIL:-skipped}"
    printf '    - %s  (skipped: %s; %ss)\n' "$case_id" "${_IT_CASE_DETAIL:-skipped}" "$_it_elapsed"
  elif [[ $_IT_CASE_FAILED -eq 0 ]]; then
    it_record "$backend" PASS "$case_id"
    printf '    \xe2\x9c\x93 %s  (%ss)\n' "$case_id" "$_it_elapsed"
  else
    it_record "$backend" FAIL "$case_id" "${_IT_CASE_DETAIL:-failed}"
    printf '    \xe2\x9c\x97 %s\n' "$case_id"
    printf '        backend: %s\n' "$backend"
    printf '        duration: %ss\n' "$_it_elapsed"
    printf '        log:     %s\n' "$(it_log_path "$backend" "$case_id")"
  fi
}

# Case functions call this to mark the current case SKIPPED with a reason. Use
# when a case cannot meaningfully run on the current backend configuration (a
# documented capability gap, e.g. IPv6 disabled by default on OrbStack) -- never
# to hide a real regression. Always returns 0 so a `return $(it_case_skip ...)`
# exits the case cleanly without it_run_case treating the non-zero it_case_fail
# path as a failure.
it_case_skip() {  # [detail...]
  _IT_CASE_SKIPPED=1
  _IT_CASE_FAILED=0
  if [[ -n "$1" ]]; then
    if [[ -n "${_IT_CASE_DETAIL:-}" ]]; then _IT_CASE_DETAIL+="; $*"; else _IT_CASE_DETAIL="$*"; fi
  fi
  return 0
}

# Case functions call this to mark the current case failed with a reason. Always
# returns 1 so `it_case_fail "x"` can be used as `return`-style early exit.
it_case_fail() {  # [detail...]
  _IT_CASE_FAILED=1
  if [[ -n "$1" ]]; then
    if [[ -n "${_IT_CASE_DETAIL:-}" ]]; then _IT_CASE_DETAIL+="; $*"; else _IT_CASE_DETAIL="$*"; fi
  fi
  return 1
}
