#!/usr/bin/env bash
# =============================================================================
# tests/unit/container-hosts.sh - dce_hosts_normalize / _dce_hosts_reconcile_script
#                                 / dce_ensure_container_hosts.
#
# Proves the per-project hosts fragment flows into the container's /etc/hosts
# as a single marker-delimited managed block:
#   - normalize  -> full-line comments / blank / CRLF / 1-field lines stripped
#                   (with a warning naming the bad line); multi-name entries,
#                   IPv6 addresses, and trailing inline comments kept
#   - reconcile  -> fresh apply, idempotent re-apply, fragment edit replaces the
#                   block, empty fragment removes it, lines outside the markers
#                   survive, and a stale mid-file block is stripped wherever it
#                   sits
#   - driver     -> missing fragment is a zero-backend-call no-op; entries
#                   stream via stdin to the root exec; any backend failure --
#                   staging or the reconcile exec -- warns (naming the project)
#                   but never fails the caller
#   - guards     -> the emitted script never swaps the /etc/hosts inode (no
#                   sed -i / mv / rename); replays with two stale blocks and a
#                   no-trailing-newline stale block at EOF; a hand-mangled
#                   unmatched BEGIN recovers instead of truncating to EOF
#
# In-process: backend_exec_as_root / backend_exec_stdin_as_root are stubbed; no
# container runtime. The generated reconcile script is executed with `sh`
# against files under $WORK so the on-disk effects are observable.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
chmod 700 "$WORK"

# The driver resolves the fragment under $HOME; isolate it for the test run.
export HOME="$WORK/home"

# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

PROJECT="hosts-proj"
PROJ_DIR="$HOME/.config/dc-enclave/projects/$PROJECT"
FRAGMENT="$PROJ_DIR/hosts"
mkdir -p "$PROJ_DIR"

HOSTS="$WORK/hosts"           # simulated container /etc/hosts for replay
FRAG="$WORK/frag"             # simulated staged fragment for replay
ARGV_LOG="$WORK/argv.log"     # space-joined argv per backend_* stub call
STDIN_CAP="$WORK/stdin.cap"   # bytes streamed into backend_exec_stdin_as_root
: > "$ARGV_LOG"; : > "$STDIN_CAP"
LAST_SCRIPT=""                # sh -c payload captured by the exec-as-root stub
BACKEND_RC=0                  # set to 1 to simulate a failing backend call
ROOT_RC=""                    # set to 1 to fail ONLY backend_exec_as_root

# Stubbed backend surface: record argv, capture stdin, and keep the reconcile
# script for inspection. The driver's script is NEVER replayed here -- it
# targets the real /etc/hosts; the reconcile cases below generate their own
# script against $WORK paths instead.
backend_exec_as_root() {
  printf 'EXECROOT %s\n' "$*" >> "$ARGV_LOG"
  if [[ "${2:-}" == "sh" && "${3:-}" == "-c" ]]; then
    LAST_SCRIPT="${4:-}"
  fi
  # ROOT_RC isolates a failure to the reconcile exec while staging still succeeds.
  if [[ -n "$ROOT_RC" ]]; then
    return "$ROOT_RC"
  fi
  return "$BACKEND_RC"
}
backend_exec_stdin_as_root() {
  printf 'EXECSTDINROOT %s\n' "$*" >> "$ARGV_LOG"
  cat >> "$STDIN_CAP"
  return "$BACKEND_RC"
}

reset_state() { : > "$ARGV_LOG"; : > "$STDIN_CAP"; LAST_SCRIPT=""; BACKEND_RC=0; ROOT_RC=""; }

# Backend-aware driver cases need a loadable project config: the apple backend
# must reconcile even without a fragment (it stages the host-gateway line), so
# the driver resolves CONTAINER_BACKEND from the project config itself via the
# hardened loader. DC_REPOS_DIR is pinned so the schema-v2 repo validators judge
# the fixture paths deterministically regardless of the ambient environment.
DC_REPOS_DIR="$WORK/repos"
mkdir -p "$DC_REPOS_DIR"

# Write a minimal valid schema-v2 config for <project> selecting <backend>.
make_config() {  # <project> <backend>
  local project="$1" backend="$2"
  local cfg_dir="$HOME/.config/dc-enclave/projects/$project"
  local repo_path="$DC_REPOS_DIR/$project"
  mkdir -p "$cfg_dir" "$repo_path"
  cat > "$cfg_dir/config" <<CFG
CONTAINER_PROJECT="$project"
CONFIG_SCHEMA_VERSION="2"
CONTAINER_BACKEND="$backend"
REPO_NAMES=("$project")
REPO_PATHS=("$repo_path")
CFG
  chmod 600 "$cfg_dir/config"
}

# Run the generated reconciler against $WORK files, as the container root sh would.
# The script consumes (rm's) the fragment it is given, so each replay gets its
# own copy of $FRAG -- re-running with "the same fragment" stays honest.
apply_reconcile() {
  if [[ -f "$FRAG" ]]; then
    cp "$FRAG" "$FRAG.replay"
  else
    : > "$FRAG.replay"
  fi
  sh -c "$(_dce_hosts_reconcile_script "$HOSTS" "$FRAG.replay")"
}

count_marker() { grep -cFx "$1" "$HOSTS" || true; }

# --- dce_hosts_normalize: filtering -------------------------------------------
printf '# header comment\r\n\r\n   \r\n\t\t\r\n   10.0.0.2 alpha beta  \r\nfd00::5 registry.corp\r\n10.0.0.3 host # inline\r\n10.0.0.9\r\n' > "$FRAGMENT"
normalized="$(dce_hosts_normalize "$FRAGMENT" 2>"$WORK/norm.err")" \
  || fail "normalize: unexpected failure"
[[ "$normalized" == $'10.0.0.2 alpha beta\nfd00::5 registry.corp\n10.0.0.3 host # inline' ]] \
  || fail "normalize: entries mismatch, got: $normalized"
if grep -q $'\r' <<< "$normalized"; then
  fail "normalize: CR survived CRLF stripping"
fi
grep -q 'WARN' "$WORK/norm.err" || fail "normalize: dce_warn not fired for 1-field line"
grep -Fq '10.0.0.9' "$WORK/norm.err" || fail "normalize: warn does not name the offending line"
pass "dce_hosts_normalize: comments/blank/CRLF/whitespace stripped, 1-field skipped with warn"

# The surviving cases from the same fragment, asserted individually so a failure
# message pinches which rule broke: multi-name, IPv6, inline comment.
grep -Fq '10.0.0.2 alpha beta' <<< "$normalized" || fail "normalize: multi-name entry lost"
grep -Fq 'fd00::5 registry.corp' <<< "$normalized" || fail "normalize: IPv6 entry lost"
grep -Fq '10.0.0.3 host # inline' <<< "$normalized" || fail "normalize: trailing inline comment lost"
pass "dce_hosts_normalize: multi-name / IPv6 / inline-comment entries kept"

# --- reconcile script: a. fresh apply -----------------------------------------
printf '127.0.0.1\tlocalhost\n::1 localhost ip6-localhost\n127.0.1.1 devbox\n' > "$HOSTS"
printf '10.0.0.5 registry.corp\nfd00::5 api.corp\n' > "$FRAG"
apply_reconcile
cat > "$WORK/a.expected" <<'EOF'
127.0.0.1	localhost
::1 localhost ip6-localhost
127.0.1.1 devbox
# >>> dc-enclave hosts (managed) >>>
10.0.0.5 registry.corp
fd00::5 api.corp
# <<< dc-enclave hosts (managed) <<<
EOF
cmp -s "$HOSTS" "$WORK/a.expected" || fail "fresh apply: file mismatch"
[[ "$(count_marker '# >>> dc-enclave hosts (managed) >>>')" -eq 1 ]] \
  || fail "fresh apply: begin marker not exactly once"
pass "reconcile: fresh apply writes exactly one managed block, originals untouched"

# --- reconcile script: b. idempotent re-apply ---------------------------------
cp "$HOSTS" "$WORK/a.snapshot"
apply_reconcile
cmp -s "$HOSTS" "$WORK/a.snapshot" || fail "idempotent re-apply: file changed"
[[ "$(count_marker '# >>> dc-enclave hosts (managed) >>>')" -eq 1 ]] \
  || fail "idempotent re-apply: block duplicated"
pass "reconcile: re-apply with same fragment is byte-identical (single block)"

# --- reconcile script: c. host-side edit replaces the block -------------------
printf '10.0.0.6 registry.corp\n' > "$FRAG"
apply_reconcile
grep -Fq '10.0.0.5 registry.corp' "$HOSTS" && fail "edit: stale entry still present"
grep -Fq '10.0.0.6 registry.corp' "$HOSTS" || fail "edit: new entry missing"
grep -Fq '127.0.1.1 devbox' "$HOSTS" || fail "edit: original host line lost"
[[ "$(count_marker '# >>> dc-enclave hosts (managed) >>>')" -eq 1 ]] \
  || fail "edit: managed block duplicated"
pass "reconcile: fragment edit replaces old entries with the new set"

# --- reconcile script: d. empty/invalid-only fragment removes the block -------
printf '# only a comment\n\n   \n10.0.0.99\n' > "$FRAG"
apply_reconcile
[[ "$(count_marker '# >>> dc-enclave hosts (managed) >>>')" -eq 0 ]] \
  || fail "empty fragment: managed block still present"
[[ "$(count_marker '# <<< dc-enclave hosts (managed) <<<')" -eq 0 ]] \
  || fail "empty fragment: end marker still present"
grep -Fq '127.0.0.1	localhost' "$HOSTS" || fail "empty fragment: original content damaged"
grep -Fq '10.0.0.6' "$HOSTS" && fail "empty fragment: old entry survived"
pass "reconcile: empty/invalid-only fragment removes the block, file intact"

# --- reconcile script: e. manual lines outside the markers survive ------------
printf '10.0.0.6 registry.corp\n' > "$FRAG"
apply_reconcile
{ printf '10.20.0.1 manual-pre\n'; cat "$HOSTS"; printf '10.20.0.2 manual-post\n'; } > "$WORK/manual" \
  && cat "$WORK/manual" > "$HOSTS"
apply_reconcile
grep -Fq '10.20.0.1 manual-pre' "$HOSTS" || fail "manual lines: pre-block line lost"
grep -Fq '10.20.0.2 manual-post' "$HOSTS" || fail "manual lines: post-block line lost"
grep -Fq '10.0.0.6 registry.corp' "$HOSTS" || fail "manual lines: managed entry lost"
[[ "$(count_marker '# >>> dc-enclave hosts (managed) >>>')" -eq 1 ]] \
  || fail "manual lines: block duplicated"
pass "reconcile: manual lines outside the markers survive re-apply"

# --- reconcile script: f. stale mid-file block stripped wherever it sits ------
cat > "$HOSTS" <<'EOF'
127.0.0.1 localhost
# >>> dc-enclave hosts (managed) >>>
10.99.0.1 stale.corp
# <<< dc-enclave hosts (managed) <<<
::1 localhost6
EOF
printf '10.0.0.7 fresh.corp\n' > "$FRAG"
apply_reconcile
cat > "$WORK/f.expected" <<'EOF'
127.0.0.1 localhost
::1 localhost6
# >>> dc-enclave hosts (managed) >>>
10.0.0.7 fresh.corp
# <<< dc-enclave hosts (managed) <<<
EOF
cmp -s "$HOSTS" "$WORK/f.expected" || fail "mid-file block: file mismatch"
grep -Fq '10.99.0.1 stale.corp' "$HOSTS" && fail "mid-file block: stale entry survived"
pass "reconcile: stale mid-file block stripped in place, later lines preserved"

# --- driver: g. missing fragment is a strict no-op ----------------------------
rm -f "$FRAGMENT"
reset_state
dce_ensure_container_hosts "$PROJECT"
if [[ -s "$ARGV_LOG" || -s "$STDIN_CAP" ]]; then
  fail "missing fragment: backend calls were made for a pre-feature project"
fi
pass "driver: missing hosts fragment -> zero backend calls"

# --- driver: h. entries present -> stdin staging + root reconcile -------------
printf '# project hosts\n\n10.0.0.5 registry.corp\nfd00::5 api.corp\n' > "$FRAGMENT"
reset_state
dce_ensure_container_hosts "$PROJECT"
printf '10.0.0.5 registry.corp\nfd00::5 api.corp\n' > "$WORK/stdin.expected"
cmp -s "$STDIN_CAP" "$WORK/stdin.expected" \
  || fail "driver: stdin payload is not the normalized fragment"
grep -Fq "EXECSTDINROOT $PROJECT sh -c cat > /tmp/.dce-hosts" "$ARGV_LOG" \
  || fail "driver: fragment not staged at /tmp/.dce-hosts via root stdin exec"
# One stdin staging call + one reconcile exec (the script itself spans many
# logged lines, so count log entries by their EXEC prefix).
[[ "$(grep -c '^EXEC' "$ARGV_LOG")" -eq 2 ]] || fail "driver: expected exactly two backend calls"
[[ "$LAST_SCRIPT" == *'/etc/hosts'* && "$LAST_SCRIPT" == *'/tmp/.dce-hosts'* ]] \
  || fail "driver: reconcile script does not reference /etc/hosts and /tmp/.dce-hosts"
grep -Fq 'rm -f' <<< "$LAST_SCRIPT" \
  || fail "driver: reconcile script does not clean up its temp files"
pass "driver: normalized fragment staged via stdin; root exec reconciles /etc/hosts"

# --- driver: i. backend failure warns but never fails the caller --------------
reset_state
printf '10.0.0.5 registry.corp\n' > "$FRAGMENT"
BACKEND_RC=1
rc=0
out="$(dce_ensure_container_hosts "$PROJECT" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "driver: backend failure must not fail the caller (rc=$rc)"
grep -q 'WARN' <<< "$out" || fail "driver: backend failure did not warn"
grep -Fq "$PROJECT" <<< "$out" || fail "driver: warn does not mention the project"
pass "driver: backend failure -> warn + return 0 (entry continues)"

# --- driver: j. reconcile-exec failure (staging OK) warns, never fails --------
reset_state
printf '10.0.0.5 registry.corp\n' > "$FRAGMENT"
ROOT_RC=1
rc=0
out="$(dce_ensure_container_hosts "$PROJECT" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "driver: reconcile exec failure must not fail the caller (rc=$rc)"
grep -q 'WARN' <<< "$out" || fail "driver: reconcile exec failure did not warn"
grep -Fq "$PROJECT" <<< "$out" || fail "driver: reconcile warn does not mention the project"
grep -q 'could not reconcile' <<< "$out" \
  || fail "driver: expected the reconcile-stage warning, got: $out"
# Staging succeeded (exactly one stdin call) before the failing reconcile exec.
[[ "$(grep -c '^EXECSTDINROOT' "$ARGV_LOG")" -eq 1 ]] \
  || fail "driver: stdin staging did not run before the reconcile failure"
[[ "$(grep -c '^EXECROOT' "$ARGV_LOG")" -eq 1 ]] \
  || fail "driver: expected exactly one reconcile exec"
pass "driver: reconcile-exec failure (staging OK) -> warn + return 0"

# --- guard: k. emitted script never swaps the /etc/hosts inode ----------------
# Docker bind-mounts /etc/hosts: inode replacement (sed -i / mv / rename)
# lands the write on an orphan inode the container never sees.
script_probe="$(_dce_hosts_reconcile_script /etc/hosts /tmp/.dce-hosts)"
if grep -q 'sed -i' <<< "$script_probe"; then
  fail "guard: reconcile script contains 'sed -i'"
fi
if grep -q 'mv ' <<< "$script_probe"; then
  fail "guard: reconcile script contains 'mv '"
fi
if grep -q 'rename' <<< "$script_probe"; then
  fail "guard: reconcile script contains 'rename'"
fi
pass "guard: emitted script is truncate-write only (no sed -i / mv / rename)"

# --- reconcile script: l. two separate stale blocks both stripped -------------
cat > "$HOSTS" <<'EOF'
first line
# >>> dc-enclave hosts (managed) >>>
10.91.0.1 stale-one.corp
# <<< dc-enclave hosts (managed) <<<
middle line
# >>> dc-enclave hosts (managed) >>>
10.92.0.2 stale-two.corp
# <<< dc-enclave hosts (managed) <<<
last line
EOF
printf '10.0.0.11 fresh.corp\n' > "$FRAG"
apply_reconcile
cat > "$WORK/l.expected" <<'EOF'
first line
middle line
last line
# >>> dc-enclave hosts (managed) >>>
10.0.0.11 fresh.corp
# <<< dc-enclave hosts (managed) <<<
EOF
cmp -s "$HOSTS" "$WORK/l.expected" || fail "two stale blocks: file mismatch"
grep -Fq '10.91.0.1 stale-one.corp' "$HOSTS" && fail "two stale blocks: first stale entry survived"
grep -Fq '10.92.0.2 stale-two.corp' "$HOSTS" && fail "two stale blocks: second stale entry survived"
[[ "$(count_marker '# >>> dc-enclave hosts (managed) >>>')" -eq 1 ]] \
  || fail "two stale blocks: fresh block not appended exactly once"
pass "reconcile: two stale blocks stripped, other content kept, one fresh block"

# --- reconcile script: m. stale block at EOF without a trailing newline -------
printf '127.0.0.1 localhost\n# >>> dc-enclave hosts (managed) >>>\n10.93.0.3 stale-eof.corp\n# <<< dc-enclave hosts (managed) <<<' > "$HOSTS"
printf '10.0.0.12 fresh.corp\n' > "$FRAG"
apply_reconcile
cat > "$WORK/m.expected" <<'EOF'
127.0.0.1 localhost
# >>> dc-enclave hosts (managed) >>>
10.0.0.12 fresh.corp
# <<< dc-enclave hosts (managed) <<<
EOF
cmp -s "$HOSTS" "$WORK/m.expected" || fail "eof block: file mismatch"
grep -Fq '10.93.0.3 stale-eof.corp' "$HOSTS" && fail "eof block: stale entry survived"
[[ "$(tail -c 1 "$HOSTS" | wc -l)" -eq 1 ]] || fail "eof block: output missing trailing newline"
pass "reconcile: stale block at EOF (no trailing newline) stripped, output well-formed"

# --- reconcile script: n. unmatched BEGIN (hand-mangled) recovers -------------
# The tool writes balanced pairs, but /etc/hosts is hand-editable; a BEGIN
# without an END must NOT silently drop everything after it.
cat > "$HOSTS" <<'EOF'
127.0.0.1 localhost
# >>> dc-enclave hosts (managed) >>>
10.94.0.4 user-added.corp
::1 localhost6
EOF
printf '10.0.0.13 fresh.corp\n' > "$FRAG"
apply_reconcile
cat > "$WORK/n.expected" <<'EOF'
127.0.0.1 localhost
10.94.0.4 user-added.corp
::1 localhost6
# >>> dc-enclave hosts (managed) >>>
10.0.0.13 fresh.corp
# <<< dc-enclave hosts (managed) <<<
EOF
cmp -s "$HOSTS" "$WORK/n.expected" || fail "unmatched begin: file mismatch"
pass "reconcile: unmatched BEGIN restores its lines instead of truncating to EOF"

# --- reconcile script: o. stray END outside any block is dropped --------------
cat > "$HOSTS" <<'EOF'
127.0.0.1 localhost
# <<< dc-enclave hosts (managed) <<<
::1 localhost6
EOF
printf '10.0.0.14 fresh.corp\n' > "$FRAG"
apply_reconcile
cat > "$WORK/o.expected" <<'EOF'
127.0.0.1 localhost
::1 localhost6
# >>> dc-enclave hosts (managed) >>>
10.0.0.14 fresh.corp
# <<< dc-enclave hosts (managed) <<<
EOF
cmp -s "$HOSTS" "$WORK/o.expected" || fail "stray end: file mismatch"
pass "reconcile: stray END outside any block is dropped"

# --- driver: p. apple + fragment -> fragment lines AND the gateway line --------
# apple/container gets host-loopback reachability by staging the dce-managed
# gateway line (TEST-NET-3 IP redirected into host loopback by the container
# system's packet-filter rule) after the user's own lines, inside the SAME
# managed block; the in-container reconcile script is unchanged.
APPLE_PROJ="apple-proj"
make_config "$APPLE_PROJ" apple
printf '# corp hosts\n10.0.0.5 registry.corp\n' > "$(dce_project_hosts_file "$APPLE_PROJ")"
reset_state
dce_ensure_container_hosts "$APPLE_PROJ"
printf '10.0.0.5 registry.corp\n203.0.113.113 host.docker.internal host.container.internal\n' \
  > "$WORK/p.stdin.expected"
cmp -s "$STDIN_CAP" "$WORK/p.stdin.expected" \
  || fail "apple+fragment: staged payload is not fragment lines + gateway line
got: $(cat "$STDIN_CAP")"
[[ "$(grep -c '^EXEC' "$ARGV_LOG")" -eq 2 ]] \
  || fail "apple+fragment: expected exactly two backend calls"
[[ "$LAST_SCRIPT" == *'/etc/hosts'* ]] \
  || fail "apple+fragment: reconcile script does not target /etc/hosts"
pass "driver: apple + fragment -> fragment lines composed with the gateway line"

# --- driver: q. apple + NO fragment -> gateway line still staged ---------------
# The apple backend reconciles even with no user fragment: without the managed
# gateway line its containers can never reach host-loopback services.
APPLE_NOFRAG_PROJ="apple-nofrag"
make_config "$APPLE_NOFRAG_PROJ" apple
rm -f "$(dce_project_hosts_file "$APPLE_NOFRAG_PROJ")"
reset_state
dce_ensure_container_hosts "$APPLE_NOFRAG_PROJ"
printf '203.0.113.113 host.docker.internal host.container.internal\n' \
  > "$WORK/q.stdin.expected"
cmp -s "$STDIN_CAP" "$WORK/q.stdin.expected" \
  || fail "apple+no-fragment: gateway line not staged
got: $(cat "$STDIN_CAP")"
[[ "$(grep -c '^EXEC' "$ARGV_LOG")" -eq 2 ]] \
  || fail "apple+no-fragment: expected exactly two backend calls (staging + reconcile)"
grep -Fq "EXECSTDINROOT $APPLE_NOFRAG_PROJ sh -c cat > /tmp/.dce-hosts" "$ARGV_LOG" \
  || fail "apple+no-fragment: gateway line not staged via root stdin exec"
[[ "$LAST_SCRIPT" == *'/etc/hosts'* ]] \
  || fail "apple+no-fragment: reconcile exec missing"
pass "driver: apple + NO fragment -> gateway line staged and reconciled"

# --- driver: r. non-apple + NO fragment -> strict no-op (prior contract) -------
DOCKER_PROJ="docker-proj"
make_config "$DOCKER_PROJ" docker
rm -f "$(dce_project_hosts_file "$DOCKER_PROJ")"
reset_state
dce_ensure_container_hosts "$DOCKER_PROJ"
if [[ -s "$ARGV_LOG" || -s "$STDIN_CAP" ]]; then
  fail "non-apple+no-fragment: backend calls were made (contract requires zero)
$(cat "$ARGV_LOG")"
fi
pass "driver: non-apple + NO fragment -> zero backend calls (exact prior behavior)"

# --- driver: s. non-apple + fragment -> unchanged (no gateway line) ------------
printf '# corp hosts\n10.0.0.5 registry.corp\n' > "$(dce_project_hosts_file "$DOCKER_PROJ")"
reset_state
dce_ensure_container_hosts "$DOCKER_PROJ"
printf '10.0.0.5 registry.corp\n' > "$WORK/s.stdin.expected"
cmp -s "$STDIN_CAP" "$WORK/s.stdin.expected" \
  || fail "non-apple+fragment: staged payload changed
got: $(cat "$STDIN_CAP")"
if grep -Fq 'host.docker.internal' "$STDIN_CAP"; then
  fail "non-apple+fragment: gateway line leaked into a docker-family stage"
fi
pass "driver: non-apple + fragment -> unchanged payload, no gateway line"

# --- driver: t. apple + comment-only fragment -> gateway line only -------------
# `dce new` scaffolds a comment-only fragment; apple must still net out to the
# gateway line (the empty normalized fragment is replaced, not skipped).
APPLE_COMMENT_PROJ="apple-comment"
make_config "$APPLE_COMMENT_PROJ" apple
printf '# scaffold comment\n\n' > "$(dce_project_hosts_file "$APPLE_COMMENT_PROJ")"
reset_state
dce_ensure_container_hosts "$APPLE_COMMENT_PROJ"
printf '203.0.113.113 host.docker.internal host.container.internal\n' \
  > "$WORK/t.stdin.expected"
cmp -s "$STDIN_CAP" "$WORK/t.stdin.expected" \
  || fail "apple+comment-only: staged payload is not exactly the gateway line
got: $(cat "$STDIN_CAP")"
pass "driver: apple + comment-only fragment -> exactly the gateway line"

# --- driver: u. config exists but is unloadable -> degrades to non-apple -------
# A config that EXISTS but fails the hardened loader (here: group-writable file
# -> dce_die inside the _dce_hosts_project_backend subshell) leaves the backend
# UNKNOWN, and "unknown" degrades to the non-apple path by design. Pin both
# halves of that degradation:
#   - no fragment  -> strict no-op, zero backend calls (entry continues);
#   - fragment     -> still reconciled exactly as a non-apple project's would
#                     be (fragment only, NO gateway line, rc 0) -- the gateway
#                     line is never staged on an unproven apple backend.
# In neither half may the driver abort the container entry point.
APPLE_UNLOADABLE_PROJ="apple-unloadable"
make_config "$APPLE_UNLOADABLE_PROJ" apple
chmod 664 "$HOME/.config/dc-enclave/projects/$APPLE_UNLOADABLE_PROJ/config"
UNLOADABLE_FRAG="$(dce_project_hosts_file "$APPLE_UNLOADABLE_PROJ")"

rm -f "$UNLOADABLE_FRAG"
reset_state
rc=0
out="$(dce_ensure_container_hosts "$APPLE_UNLOADABLE_PROJ" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "unloadable-config: driver must not fail the caller (rc=$rc)"
if [[ -s "$ARGV_LOG" || -s "$STDIN_CAP" ]]; then
  fail "unloadable-config: backend calls were made with an unknown backend and no fragment
$(cat "$ARGV_LOG")"
fi
pass "driver: apple + unloadable config + NO fragment -> degrades to strict no-op"

printf '# corp hosts\n10.0.0.5 registry.corp\n' > "$UNLOADABLE_FRAG"
reset_state
rc=0
out="$(dce_ensure_container_hosts "$APPLE_UNLOADABLE_PROJ" 2>&1)" || rc=$?
[[ "$rc" -eq 0 ]] || fail "unloadable-config+fragment: driver must not fail the caller (rc=$rc)"
printf '10.0.0.5 registry.corp\n' > "$WORK/u.stdin.expected"
cmp -s "$STDIN_CAP" "$WORK/u.stdin.expected" \
  || fail "unloadable-config+fragment: staged payload is not the plain fragment
got: $(cat "$STDIN_CAP")"
if grep -Fq 'host.docker.internal' "$STDIN_CAP"; then
  fail "unloadable-config+fragment: gateway line staged though the backend could not be proven apple"
fi
[[ "$(grep -c '^EXEC' "$ARGV_LOG")" -eq 2 ]] \
  || fail "unloadable-config+fragment: expected exactly two backend calls (staging + reconcile)"
pass "driver: apple + unloadable config + fragment -> reconciled as non-apple (no gateway line)"

echo "All container-hosts checks passed."
