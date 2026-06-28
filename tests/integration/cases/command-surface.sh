#!/usr/bin/env bash
# =============================================================================
# tests/integration/cases/command-surface.sh - Command-surface + alias checks.
#
# Exercises the dispatcher end-to-end per backend: version (--version/-v), help
# (--help/-h), per-command help, alias dispatch (s/ls/net), and the
# unknown-command path. status/list aliases double as the "at least one real-
# backend assertion" for those commands; the rest are backend-agnostic but run
# under CONTAINER_BACKEND for uniform per-backend accounting.
#
# Entry point (called by run-all.sh once per selected backend):
#   it_cases_command_surface <backend>
# =============================================================================
set -uo pipefail

# Each case fn signature matches it_run_case's contract: <backend> <case_id>.

_it_cs_version() {  # <backend> <case_id>
  local backend="$1" out rc
  out="$(it_dce_capture "$backend" "$2" --version)" && rc=0 || rc=$?
  [[ "$rc" -eq 0 && "$out" =~ ^dce\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || { it_case_fail "version output: $out"; return 1; }
  it_dce "$backend" "$2" -v >/dev/null && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "-v exit $rc"; return 1; }
  return 0
}

_it_cs_help() {  # <backend> <case_id>
  local backend="$1"
  it_dce "$backend" "$2" help >/dev/null || { it_case_fail "dce help"; return 1; }
  it_dce "$backend" "$2" --help >/dev/null || { it_case_fail "dce --help"; return 1; }
  it_dce "$backend" "$2" -h >/dev/null || { it_case_fail "dce -h"; return 1; }
  return 0
}

_it_cs_help_per_command() {  # <backend> <case_id>
  local backend="$1" c
  for c in new start stop restart status list shell logs exec rm \
           rebuild-container rebuild-image snapshot provenance clean config \
           doctor network install version help; do
    it_dce "$backend" "$2" help "$c" >/dev/null || { it_case_fail "dce help $c"; return 1; }
  done
  return 0
}

_it_cs_aliases() {  # <backend> <case_id>
  local backend="$1" rc
  # s -> status, ls -> list: real backend hits (exit 0 with no projects).
  it_dce "$backend" "$2" s >/dev/null && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "alias 's' (status) exit $rc"; return 1; }
  it_dce "$backend" "$2" ls >/dev/null && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "alias 'ls' (list) exit $rc"; return 1; }
  return 0
}

_it_cs_help_unknown() {  # <backend> <case_id>
  local backend="$1" rc
  it_dce "$backend" "$2" help nonexistent >/dev/null && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || { it_case_fail "dce help <unknown> should exit non-zero"; return 1; }
  return 0
}

it_cases_command_surface() {  # <backend>
  local backend="$1"
  it_run_case "$backend" "version"            _it_cs_version
  it_run_case "$backend" "help"               _it_cs_help
  it_run_case "$backend" "help-per-command"   _it_cs_help_per_command
  it_run_case "$backend" "aliases-s-ls"       _it_cs_aliases
  it_run_case "$backend" "help-unknown-fails" _it_cs_help_unknown
}
