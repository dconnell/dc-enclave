#!/usr/bin/env zsh
# =============================================================================
# tests/unit/completion-widget.zsh - real-widget completion tests (zpty).
#
# tests/unit/completion.sh validates _arguments SPEC STRINGS against a stub.
# That cannot detect a spec whose action never renders anything -- the exact
# bug class that shipped three broken "hint" attempts on this branch. This
# harness instead spawns `zsh -f` (clean: no rc files, no oh-my-zsh, no fzf
# wrappers) under a pty, types real command lines, presses TAB, and asserts
# on what zsh actually renders -- the same technique zsh's own test suite
# uses for completion.
#
# Section 1: bake-off of the candidate message-only action forms.
# Section 2: every approved free-text hint slot in the real `dce` completer.
#
# Prints SKIP and exits 0 when zsh/zpty is unavailable. All read loops use
# `zpty -r -t` (non-blocking) and are iteration-bounded, so the script always
# terminates. Invoked from tests/unit/completion.sh (zsh-gated there).
# =============================================================================

emulate -L zsh

pass() { print "PASS: $*" }
fail() { print "FAIL: $*" >&2; exit 1 }
skip() { print "SKIP: $*"; exit 0 }
dbg()  { print "[widget-test] $*" }

REPO_ROOT="${0:A:h:h:h}"

zmodload zsh/zpty 2>/dev/null || skip "zsh/zpty unavailable; widget render test not run"

ZSH_BIN="${commands[zsh]:-zsh}"
export TERM=xterm
WORK="$(mktemp -d)"
trap 'zpty -d wtest 2>/dev/null; rm -rf "$WORK"' EXIT

# --- pty plumbing -----------------------------------------------------------

PTY_BUF=""

_pty_render() {
  # PTY_BUF minus CR and ANSI CSI sequences; hint words must stay contiguous.
  local s="$PTY_BUF"
  s="${s//$'\r'/}"
  print -r -- "$s" | command sed $'s/\033\\[[0-9;?]*[A-Za-z]//g'
}

# Every read uses `zpty -r -t`: the non-blocking form. Without -t, a read on
# a quiet pty blocks forever, which hung the first version of this harness.
_pty_drain() {                 # _pty_drain <seconds>
  local iters chunk i
  iters=$(( $1 * 20 )); (( iters < 1 )) && iters=1
  for (( i = 0; i < iters; i++ )); do
    if zpty -r -t wtest chunk 2>/dev/null && [[ -n "$chunk" ]]; then
      PTY_BUF+="$chunk"
    fi
    sleep 0.05
  done
}

_pty_wait_for() {              # _pty_wait_for <substring> [seconds]
  local want="$1" ttl="${2:-6}" iters chunk i
  iters=$(( ttl * 20 ))
  for (( i = 0; i < iters; i++ )); do
    if zpty -r -t wtest chunk 2>/dev/null && [[ -n "$chunk" ]]; then
      PTY_BUF+="$chunk"
      [[ "$(_pty_render)" == *"$want"* ]] && return 0
    fi
    sleep 0.05
  done
  print "TIMEOUT waiting for [$want]; pty buffer follows:" >&2
  _pty_render >&2
  return 1
}

# Drive one TAB cycle (type line, TAB twice -- some setups defer the listing
# to the second press -- then ^C to clear) and leave the sanitized screen in
# $PTY_SCREEN.
_pty_capture() {               # _pty_capture <line>
  PTY_BUF=""
  zpty -w -n wtest "$1"
  sleep 0.15
  zpty -w -n wtest $'\t'
  sleep 0.25
  zpty -w -n wtest $'\t'
  _pty_drain 0.6
  zpty -w -n wtest $'\003'
  sleep 0.1
  _pty_drain 0.15
  PTY_SCREEN="$(_pty_render)"
}

_check_hint() {                # _check_hint <line> <want>
  _pty_capture "$1"
  [[ "$PTY_SCREEN" == *"$2"* ]]
}

_check_absent() {              # _check_absent <line> <unwanted>
  _pty_capture "$1"
  [[ "$PTY_SCREEN" != *"$2"* ]]
}

# --- clean shell -------------------------------------------------------------

# -e: echo input back so the captured buffer proves the child is alive even
# when a completion renders nothing.
zpty -e wtest "$ZSH_BIN" -f
zpty -w wtest 'stty cols 80 rows 24 2>/dev/null'
zpty -w wtest "PS1='WIDGET> '"
zpty -w wtest 'unsetopt beep'
zpty -w wtest 'autoload -Uz compinit && compinit -u'
# Handshake markers are emitted via $R so the pty ECHO of the typed command
# (`print -r -- SHELL-$R`) cannot match the wait pattern -- only the child's
# real output can. A literal marker matched its own echo and returned before
# compinit finished, so the bake-off raced an unready child and every check
# failed (deterministically right after any compinit-heavy sibling process).
zpty -w wtest 'R=READY; print -r -- SHELL-$R'
_pty_wait_for 'SHELL-READY' 6 || fail "clean zsh under pty did not start (ZSH_BIN=$ZSH_BIN)"
dbg "clean zsh -f is up"

# --- section 1: mechanism bake-off -------------------------------------------

cat > "$WORK/bakeoff.zsh" <<'EOF'
# Candidate message-only action forms for "required but not completable"
# arguments. The bake-off determines which actually renders text.
_bake_a() { _arguments '1:enter project name: ' }
_bake_b() { _arguments '1:project name:_message -r "enter project name"' }
_bake_c() {
  local state
  _arguments '1:project name:->hint'
  case $state in
    hint) _message -r "enter project name" ;;
  esac
}
_bake_d() { _arguments '1:project name:_guard "*" "enter project name"' }
_bake_e() { _arguments '1:project name:_bake_e_hint' }
_bake_e_hint() { _message -r "enter project name" }
_bake_f() { _arguments '1:enter project name:' }
compdef _bake_a bake-a
compdef _bake_b bake-b
compdef _bake_c bake-c
compdef _bake_d bake-d
compdef _bake_e bake-e
compdef _bake_f bake-f
EOF
zpty -w wtest "source '$WORK/bakeoff.zsh' && R=READY && print -r -- BAKEOFF-\$R"
_pty_wait_for 'BAKEOFF-READY' 6 || fail "bake-off setup failed to load"

typeset -a RENDERED
RENDERED=()
for c in a b c d e f; do
  if _check_hint "bake-$c " "enter project name"; then
    RENDERED+=("$c")
    pass "bake-off: form ($c) renders the hint"
  else
    print "INFO: bake-off form ($c) does NOT render the hint"
  fi
done
(( ${#RENDERED} )) || fail "no candidate form renders a hint; pick another mechanism"
print "bake-off winners: ${RENDERED[*]}"

# --- section 2: real dce hint slots ------------------------------------------

# Isolate the child's HOME so scope candidates are deterministic (fixture
# mirrors tests/unit/completion.sh) and host-independent. Must run before the
# first dce completion, which caches the data library for the shell session.
zpty -w wtest "export HOME='$WORK/home'"
# _dce_complete_default_repos_root prefers DC_REPOS_DIR over $HOME/repos, so a
# value leaking in from the invoking shell would redirect the repo-spec checks
# away from the fixture. Isolate it like HOME above.
zpty -w wtest 'unset DC_REPOS_DIR'
zpty -w wtest "mkdir -p '$WORK/home/.config/dc-enclave/team/overlays' '$WORK/home/.config/dc-enclave/user/overlays' '$WORK/home/repos/api' '$WORK/home/repos/web' '$WORK/home/repos/tools'"
zpty -w wtest "touch '$WORK/home/.config/dc-enclave/team/overlays/Containerfile.node' '$WORK/home/.config/dc-enclave/team/overlays/Containerfile.all' '$WORK/home/.config/dc-enclave/user/overlays/Containerfile.node' '$WORK/home/.config/dc-enclave/user/overlays/Containerfile.golang'"
zpty -w wtest 'HS=SET; print -r -- HOME-$HS'
_pty_wait_for 'HOME-SET' 6 || fail "isolated HOME setup failed"

zpty -w wtest "fpath=('$REPO_ROOT/scripts' \$fpath)"
zpty -w wtest 'autoload -Uz _dce && compdef _dce dce && R=READY && print -r -- DCE-$R'
_pty_wait_for 'DCE-READY' 6 || fail "scripts/_dce failed to load under zsh -f"

_dce_slot() {                  # _dce_slot <line> <want> <label>
  if _check_hint "$1" "$2"; then
    pass "widget render: $3"
  else
    fail "widget render: $3 -- [$2] not rendered"
  fi
}

_dce_slot "dce new "                       "enter project name"  "dce new <TAB> hints project name"
_dce_slot "dce shell alpha "               "enter command"      "dce shell <proj> <TAB> hints command"
_dce_slot "dce exec alpha "                "enter command"      "dce exec <proj> <TAB> hints command"
_dce_slot "dce config set alpha cpus "     "enter value"        "dce config set ... <TAB> hints value"
_dce_slot "dce logs alpha --tail "         "enter line count"   "dce logs --tail <TAB> hints line count"
_dce_slot "dce new foo --cpus "            "enter cpu limit"    "dce new --cpus <TAB> hints cpu limit"
_dce_slot "dce new foo --memory "          "enter memory limit" "dce new --memory <TAB> hints memory limit"
_dce_slot "dce new foo --ip "              "enter IPv4 address" "dce new --ip <TAB> hints IPv4 address"
_dce_slot "dce network create "            "enter network name" "dce network create <TAB> hints name"
_dce_slot "dce network create n1 --subnet "    "enter IPv4 CIDR" "dce network create --subnet <TAB> hints CIDR"
_dce_slot "dce network create n1 --subnet-v6 " "enter IPv6 CIDR" "dce network create --subnet-v6 <TAB> hints CIDR"

# Hint lifecycle: a hint belongs to an EMPTY slot under the cursor only.
# A partially typed value, or completing the NEXT slot, must not render the
# hint -- especially not beside real candidates like the scope list.
_dce_pair() {                  # _dce_pair <line> <must> <must-not> <label>
  _pty_capture "$1"
  [[ "$PTY_SCREEN" == *"$2"* ]] || fail "widget render: $4 -- [$2] not rendered"
  [[ "$PTY_SCREEN" != *"$3"* ]] || fail "widget render: $4 -- [$3] still rendered"
  pass "widget render: $4"
}
_dce_absent() {                # _dce_absent <line> <unwanted> <label>
  if _check_absent "$1" "$2"; then
    pass "widget render: $3"
  else
    fail "widget render: $3 -- [$2] rendered but should be suppressed"
  fi
}

_dce_absent "dce new te"          "enter project name" "dce new <partial> <TAB> suppresses the hint"
_dce_absent "dce shell alpha run" "enter command"      "dce shell <partial cmd> <TAB> suppresses the hint"
_dce_pair   "dce new test "       "golang" "enter project name" "dce new <name> <TAB> shows scopes without the project hint"

# Default-repos completion parity: `new --repo` and `repo add` offer bare
# repo names from the default repos root -- no path prefix inserted, no
# trailing slash -- so zsh lists plain names and appends a space on insert.
_pty_capture "dce new test nodejs,shellcheck --repo "
if [[ "$PTY_SCREEN" == *"api"* && "$PTY_SCREEN" != *"home/repos"* && "$PTY_SCREEN" != *"enter project name"* ]]; then
  pass "widget render: dce new ... --repo <TAB> lists repo names, no path, no hint"
else
  fail "widget render: dce new ... --repo <TAB> lists repo names, no path, no hint"
fi
_dce_slot "dce new test nodejs --repo web=" "api" "dce new --repo name= <TAB> completes the name half"
_dce_slot "dce repo add alpha "             "api" "dce repo add <proj> <TAB> lists repo names"

print "PASS: all widget render checks passed"
