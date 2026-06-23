#!/usr/bin/env bash
# =============================================================================
# tests/completion.sh - Tab-completion regression and behavior coverage.
#
# Covers:
#   - Shared discovery (lib/complete-data.sh): project names, scope dedup/order,
#     the hardened global-config parser, and the subcommand list. This data is
#     shared by the bash and zsh front-ends, so it is the highest-leverage test.
#   - Bash dispatcher (scripts/dc-complete.bash): driven in-process by faking
#     COMP_WORDS/COMP_CWORD. Pins the variadic-project fix (dc start a b <TAB>).
#   - zsh completion (scripts/_dc): gated on zsh being installed; checks load +
#     registration, project exclusion, scope dedup, and per-subcommand specs.
#   - Shell-aware wiring (lib/platform.sh) + the migration that strips a stale
#     bash-completion line from a zsh rc.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

export HOME="$WORK"
DC_ROOT="$HOME/.config/dev-containers"
mkdir -p "$DC_ROOT"/{alpha,beta,gamma}
touch "$DC_ROOT"/alpha/config "$DC_ROOT"/beta/config "$DC_ROOT"/gamma/config
# A dir without a config file must NOT be offered as a project.
mkdir -p "$DC_ROOT/incomplete"

TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
touch "$TEAM_DIR/overlays/Containerfile.node" "$TEAM_DIR/overlays/Containerfile.all"
touch "$USER_DIR/overlays/Containerfile.node" "$USER_DIR/overlays/Containerfile.golang"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

# ---------------------------------------------------------------------------
# Section 1 - shared discovery library (lib/complete-data.sh)
# ---------------------------------------------------------------------------
# shellcheck source=../lib/complete-data.sh
source "$ROOT_DIR/lib/complete-data.sh"

expect_sorted() {
  local label="$1" got="$2"; shift 2
  local want
  want="$(printf '%s\n' "$@" | sort)"
  got="$(printf '%s\n' "$got" | sort)"
  [[ "$got" == "$want" ]] || fail "$label: expected [$*] got [$got]"
  pass "$label"
}

expect_sorted "projects list" \
  "$(dc_complete_projects)" alpha beta gamma

expect_sorted "projects prefix filter (al)" \
  "$(dc_complete_projects al)" alpha

# Scopes dedup node (team+user) and preserve first-seen order; gamma-style
# whole-line matching prevents partial collisions.
scopes_out="$(dc_complete_scopes | sort)"
[[ "$scopes_out" == "$(printf '%s\n' all golang node | sort)" ]] \
  || fail "scopes dedup: expected [all golang node] got [$scopes_out]"
pass "scopes dedup + membership"

subs="$(dc_complete_subcommands | sort)"
for c in new start stop status s list ls shell logs exec restart rm \
         rebuild-container rebuild-image provenance clean network net doctor install version help; do
  grep -qx "$c" <<<"$subs" || fail "subcommands missing: $c"
done
pass "subcommands list"

# doctor targets: the five backend names plus configured projects.
expect_sorted "doctor targets" \
  "$(dc_complete_doctor_targets)" apple docker orbstack colima podman alpha beta gamma

# Hardened global-config parser: must accept a clean quoted value and reject
# anything that could execute ($, backtick, or unquoted).
ok_cfg="$DC_ROOT/config"
[[ "$(_dc_read_team_dir "$ok_cfg")" == "$TEAM_DIR" ]] \
  || fail "parser should accept valid DC_TEAM_DIR quoted value"
[[ "$(_dc_read_user_dir "$ok_cfg")" == "$USER_DIR" ]] \
  || fail "parser should accept valid DC_USER_DIR quoted value"
printf 'DC_TEAM_DIR="$HOME/evil"\n' > "$WORK/dollar"
printf 'DC_TEAM_DIR="x`id`"\n'      > "$WORK/btick"
printf 'DC_TEAM_DIR=unquoted\n'      > "$WORK/unq"
_dc_read_team_dir "$WORK/dollar" >/dev/null && fail "parser leaked a \$-value"
_dc_read_team_dir "$WORK/btick"  >/dev/null && fail "parser leaked a backtick-value"
_dc_read_team_dir "$WORK/unq"    >/dev/null && fail "parser leaked an unquoted value"
pass "hardened parser accepts valid, rejects unsafe"

# Empty/missing dirs must not crash under either shell.
EMPTY_HOME="$(mktemp -d)"
( HOME="$EMPTY_HOME" bash -c "source '$ROOT_DIR/lib/complete-data.sh'; \
     dc_complete_projects >/dev/null; dc_complete_scopes >/dev/null" ) \
  || fail "empty HOME crashed the discovery functions under bash"
rm -rf "$EMPTY_HOME"
pass "discovery safe on empty HOME (bash)"

# ---------------------------------------------------------------------------
# Section 2 - bash dispatcher (scripts/dc-complete.bash)
# ---------------------------------------------------------------------------
# Stub `complete` so sourcing the file does not register globally.
complete() { :; }
# shellcheck source=../scripts/dc-complete.bash
source "$ROOT_DIR/scripts/dc-complete.bash"

# Drive _dc_complete by faking the completion line. $1 = COMP_CWORD, rest =
# COMP_WORDS (the word being completed is COMP_WORDS[COMP_CWORD]).
drive() {
  local cword="$1"; shift
  COMP_WORDS=("$@")
  COMP_CWORD="$cword"
  COMPREPLY=()
  _dc_complete
}

reply_sorted() {
  printf '%s\n' "${COMPREPLY[@]}" | sort
}

assert_reply() {
  local label="$1"; shift
  local got
  got="$(reply_sorted)"
  local want
  want="$(printf '%s\n' "$@" | sort)"
  [[ "$got" == "$want" ]] || fail "$label: expected [$*] got [${COMPREPLY[*]}]"
  pass "$label"
}
assert_empty() {
  local label="$1"
  [[ ${#COMPREPLY[@]} -eq 0 ]] || fail "$label: expected no replies, got [${COMPREPLY[*]}]"
  pass "$label"
}

drive 1 dc "st"; assert_reply "subcommand prefix 'st'" start stop status

# Headline regression: variadic project completion + already-typed exclusion.
drive 3 dc start alpha "";            assert_reply "start alpha <TAB>" beta gamma
drive 4 dc start alpha beta "";       assert_reply "start alpha beta <TAB>" gamma
drive 5 dc stop alpha beta gamma "";  assert_empty   "stop all three <TAB>"

# shell takes exactly one project; nothing past it.
drive 2 dc shell "";       assert_reply "shell <TAB>" alpha beta gamma
drive 3 dc shell alpha ""; assert_empty   "shell alpha <TAB>"

# rebuild-container: one project, then the two flags.
drive 2 dc rebuild-container "";  assert_reply "rebuild-container <TAB>" alpha beta gamma
drive 3 dc rebuild-container alpha "--"; assert_reply "rebuild-container alpha --<TAB>" \
  --keep-hidden-volumes --rotate-keys

# install: one project, then a directory.
drive 2 dc install "";     assert_reply "install <TAB>" alpha beta gamma
# Directory completion is cwd-based (compgen -d), so run it from a controlled
# dir with a known subdir instead of depending on wherever this test (or a
# runner like run-all.sh) was invoked from.
mkdir -p "$WORK/dirs/subdir"
_prev_pwd="$PWD"
cd "$WORK/dirs"
drive 3 dc install alpha ""; COMPREPLY=("${COMPREPLY[@]/%//}")  # dirs get a trailing /
[[ "${COMPREPLY[*]}" == *subdir/* ]] \
  || fail "install pos3 should complete directories (got [${COMPREPLY[*]:-}])"
cd "$_prev_pwd"
pass "install pos3 completes directories"

# rebuild-image targets.
drive 2 dc rebuild-image ""; assert_reply "rebuild-image <TAB>" all base

# provenance: one project, then --history/--all flags.
drive 2 dc provenance "";              assert_reply "provenance <TAB>" alpha beta gamma
drive 3 dc provenance alpha "--";      assert_reply "provenance alpha --<TAB>" --all --history

# network: subactions at position 2.
drive 2 dc network ""; assert_reply "network <TAB>" \
  add create list ls members remove rm

# doctor: one optional target (backend or project). Backends are always offered;
# configured projects (alpha/beta/gamma) appear too.
drive 2 dc doctor ""; assert_reply "doctor <TAB>" \
  apple colima docker gamma orbstack podman alpha beta

# logs: one project, then log flags (--tail's value is not completed).
drive 2 dc logs "";                assert_reply "logs <TAB>" alpha beta gamma
drive 3 dc logs alpha "";          assert_reply "logs alpha <TAB>" --follow -f --tail
drive 3 dc logs alpha "--";        assert_reply "logs alpha --<TAB>" --follow --tail
drive 4 dc logs alpha --tail "";   assert_empty "logs alpha --tail <val> (no completion)"

# exec: optional leading --root, one project, then a free-form command.
drive 2 dc exec "";                assert_reply "exec <TAB>" --root alpha beta gamma
drive 3 dc exec --root "";         assert_reply "exec --root <TAB>" alpha beta gamma
drive 3 dc exec alpha "";          assert_empty "exec alpha <cmd> (free-form)"

# restart: variadic projects (excludes already-typed), like start/stop.
drive 2 dc restart "";             assert_reply "restart <TAB>" alpha beta gamma
drive 3 dc restart alpha "";       assert_reply "restart alpha <TAB>" beta gamma

# rm: one project, then removal flags.
drive 2 dc rm "";                  assert_reply "rm <TAB>" alpha beta gamma
drive 3 dc rm alpha "";            assert_reply "rm alpha <TAB>" --yes -y --keep-config --keep-volumes

# clean: flags + a single project when --hidden-volumes is active.
drive 2 dc clean "--"; assert_reply "clean --<TAB>" --dry-run --hidden-volumes
drive 3 dc clean --hidden-volumes ""; assert_reply "clean --hidden-volumes <TAB>" \
  --dry-run --hidden-volumes alpha beta gamma
# once a project is typed, only flags remain.
drive 4 dc clean --hidden-volumes alpha "--"; assert_reply "clean --hidden-volumes alpha --<TAB>" \
  --dry-run --hidden-volumes

# new: name is free text (no completion), pos3 = scope + flags.
drive 2 dc new "";               assert_empty "new <name> (free text, no completion)"
drive 3 dc new foo "";           assert_reply "new foo <TAB> (scope + flags)" \
  --config --cpus --hide --ip --memory --network --repo-path --save-team --save-user all golang node
# --network/--ip consume a value (no completion offered for the value).
drive 4 dc new foo --network ""; assert_empty "new foo --network <val> (no completion)"

# ---------------------------------------------------------------------------
# Section 3 - zsh completion (scripts/_dc), gated on zsh being installed
# ---------------------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  # 3a. Load + registration: the file must define its functions and register
  #     via compdef without errors under a real compinit.
  zsh -c "
    fpath=('$ROOT_DIR/scripts' \$fpath)
    autoload -Uz compinit && compinit -u 2>/dev/null
    autoload -Uz _dc
    compdef _dc dc
    [[ \"\${_comps[dc]}\" == _dc ]] || { print 'FAIL: compdef did not register _dc for dc'; exit 1 }
    print 'PASS: zsh load + compdef registration'
  " || fail "zsh completion load/registration failed"

  # 3b. Leaf logic, routing, and dispatch specs via stubbed primitives.
  #     The _arguments stub simulates the real '1: :->subcmd' '*:: :->args'
  #     state machine (including the *:: word/CURRENT reset), so the routing
  #     and reduced-context assertions exercise the off-by-one fix rather than
  #     the real _arguments engine (which needs a live ZLE widget).
  zsh -c '
    typeset -ga ADD SPEC
    # _arguments stub: detect the top-level router call by its ->state specs
    # and emulate the state transition + the *:: word re-slice. Per-subcommand
    # spec calls (no ->) are just recorded for later assertion.
    _arguments() {
      local spec is_router=0
      for spec in "$@"; do [[ "$spec" == *"->"* ]] && is_router=1; done
      if (( is_router )); then
        if (( CURRENT == 2 )); then
          state=subcmd
        else
          state=args
          words=("${words[@]:1}")   # drop command word, mirroring the *:: reset
          (( CURRENT-- ))
        fi
      else
        SPEC+=("$@")
      fi
    }
    _wanted()   { shift 3; "$@"; }      # _wanted tag expl descr cmd args
    _files()    { :; }
    _message()  { :; }
    # compadd stub: -a and -d each take an array-name argument; resolve the -a
    # array to its contents. The -d display array is otherwise irrelevant here.
    compadd() {
      local -a vals; local use_array=0 arrname
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -a) use_array=1; arrname="$2"; shift 2 ;;
          -d) shift 2 ;;
          -*) shift ;;
          *) vals+=("$1"); shift ;;
        esac
      done
      (( use_array )) && vals=("${(@P)arrname}")
      ADD+=("${vals[@]}")
    }

    source "'"$ROOT_DIR"'/lib/complete-data.sh"
    source "'"$ROOT_DIR"'/scripts/_dc"
    # The lib is already sourced above, so the lazy loader should be a no-op.
    _dc_load_complete_data() { return 0; }

    # Top-level routing. Completing the subcommand slot (CURRENT==2, whether
    # empty or partially typed) must offer subcommands; once a subcommand token
    # is committed, _dc_dispatch runs in the REDUCED context produced by the
    # *:: reset -- $words[1] is the subcommand and $CURRENT is decremented.
    # This is the regression for the off-by-one: without the reset, $words[1]
    # would be `dc` and $CURRENT would stay unchanged, so every numbered
    # _arguments spec would target the wrong slot.
    functions -c _dc_subcommands _dc_subcommands_real
    functions -c _dc_dispatch _dc_dispatch_real
    typeset TOP="" RC_CURRENT=0 RC_W1=""
    _dc_subcommands() { TOP="subs"; }
    _dc_dispatch() { TOP="dispatch:$1"; RC_CURRENT=$CURRENT; RC_W1="${words[1]}"; }

    for line in "dc |2" "dc st|2"; do
      w="${line%|*}"; c="${line#*|}"
      words=(${(z)w})
      CURRENT=$c
      TOP=""; _dc
      [[ "$TOP" == "subs" ]] || { print "FAIL: zsh subcommand routing for [$w] -> [$TOP]"; exit 1 }
    done

    words=(dc shell "")
    CURRENT=3
    TOP=""; RC_CURRENT=99; RC_W1=""; _dc
    [[ "$TOP" == "dispatch:shell" ]] || { print "FAIL: zsh dispatch arg -> [$TOP]"; exit 1 }
    [[ "$RC_W1" == "shell" ]] || { print "FAIL: *:: reset words[1] should be the subcommand, got [$RC_W1]"; exit 1 }
    [[ "$RC_CURRENT" == 2 ]] || { print "FAIL: *:: reset should decrement CURRENT to 2, got [$RC_CURRENT]"; exit 1 }

    # Variadic position keeps the same reset (start: further args still route).
    words=(dc start alpha "")
    CURRENT=4
    TOP=""; RC_CURRENT=99; _dc
    [[ "$TOP" == "dispatch:start" && "$RC_CURRENT" == 3 ]] \
      || { print "FAIL: zsh variadic routing/reset -> [$TOP] CURRENT=[$RC_CURRENT]"; exit 1 }

    functions -c _dc_subcommands_real _dc_subcommands
    functions -c _dc_dispatch_real _dc_dispatch
    unfunction _dc_subcommands_real _dc_dispatch_real
    print "PASS: zsh top-level routing + *:: word/CURRENT reset"

    ADD=(); _dc_projects alpha beta
    [[ "${ADD[*]}" == "gamma" ]] || { print "FAIL: zsh project exclude -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh projects exclude already-typed"

    ADD=(); _dc_scopes
    expected="all golang node"
    [[ "$(print -l -- "${ADD[@]}" | sort | tr "\n" " ")" == "$expected " ]] \
      || { print "FAIL: zsh scopes -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh scopes dedup"

    # rebuild-image targets come from the shared lib (single source of truth).
    ADD=(); _dc_rebuild_image_targets
    [[ "$(print -l -- "${ADD[@]}" | sort | tr "\n" " ")" == "all base " ]] \
      || { print "FAIL: zsh rebuild-image targets -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh rebuild-image targets"

    # Subcommand candidate set (also from the shared lib).
    ADD=(); _dc_subcommands
    local want="--help --version -h -v clean doctor exec help install list logs ls net network new provenance rebuild-container rebuild-image restart rm s shell start status stop version"
    [[ "$(print -l -- "${ADD[@]}" | sort | tr "\n" " ")" == "$want " ]] \
      || { print "FAIL: zsh subcommand values -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh subcommand candidate set"

    # Dispatch specs encode the per-command grammar (the main authoring risk).
    chk() { SPEC=(); _dc_dispatch "$1"; [[ "${SPEC[*]}" == *"$2"* ]] || { print "FAIL: zsh $1 spec missing [$2] got [${SPEC[*]}]"; exit 1 }; }
    chk start            "*:project:"
    chk shell            "1:project:"
    chk logs             "1:project:"
    chk logs             "--follow["
    chk exec             "--root["
    chk exec             "1:project:"
    chk restart          "*:project:"
    chk rm               "1:project:"
    chk rm               "--keep-config["
    chk rebuild-container "--rotate-keys["
    chk install          "2:dotfiles directory:_files -/"
    chk rebuild-image    "1:target:_dc_rebuild_image_targets"
    chk provenance       "1:project:_dc_projects_simple"
    chk provenance       "--history["
    chk new              "2:scope:_dc_scopes"
    print "PASS: zsh per-subcommand dispatch specs"
  ' || fail "zsh completion logic/spec test failed"
else
  echo "SKIP: zsh completion tests (zsh not installed)"
fi

# ---------------------------------------------------------------------------
# Section 4 - shell-aware wiring (lib/platform.sh) + migration
# ---------------------------------------------------------------------------
# shellcheck source=../lib/platform.sh
source "$ROOT_DIR/lib/platform.sh"

check_profile() { # <shell> <expected_basename>
  local got
  got="$(platform_profile_file "$1")"
  [[ "${got##*/}" == "$2" ]] || fail "platform_profile_file $1 -> expected ~/$2 got $got"
  pass "profile for $1 -> ~/$2"
}
# macOS profile resolution.
platform_os() { printf macos; }
check_profile zsh  .zshrc
check_profile bash .bash_profile
# Linux profile resolution.
platform_os() { printf linux; }
check_profile zsh  .zshrc
check_profile bash .bashrc

# Migration: a zsh rc with a stale bash-completion bridge must lose exactly that
# line and keep everything else. Mirrors setup.sh's migration step.
mig_rc="$WORK/.zshrc"
{
  echo "# my config"
  echo "alias dc='$ROOT_DIR/scripts/dc'"
  echo "source '$ROOT_DIR/scripts/dc-complete.bash'"
  echo "export EDITOR=vim"
} > "$mig_rc"
stale="source '$ROOT_DIR/scripts/dc-complete.bash'"
grep -Fv "$stale" "$mig_rc" > "$WORK/.zshrc.new"
cat "$WORK/.zshrc.new" > "$mig_rc"
grep -Fq "$stale" "$mig_rc" && fail "migration did not remove the stale line"
grep -Fq "# my config" "$mig_rc" || fail "migration dropped unrelated content"
grep -Fq "alias dc='$ROOT_DIR/scripts/dc'" "$mig_rc" || fail "migration unexpectedly removed legacy dc alias"
grep -Fq "export EDITOR=vim" "$mig_rc" || fail "migration dropped unrelated content"
pass "migration strips only the stale bash-completion line"

# setup.sh zsh command wiring: add function + unalias, remove managed legacy
# alias, and avoid duplicate inserts when rerun.
sim_rc="$WORK/.zshrc.setup"
{
  echo "# preexisting"
  echo "alias dc='$ROOT_DIR/scripts/dc'"
} > "$sim_rc"

dc_unalias="unalias dc 2>/dev/null"
dc_func="dc() { \"$ROOT_DIR/scripts/dc\" \"\$@\"; }"
legacy_alias="alias dc='$ROOT_DIR/scripts/dc'"

if ! grep -Fxq "$dc_func" "$sim_rc"; then
  {
    echo ""
    echo "# dev-containers command"
    echo "$dc_unalias"
    echo "$dc_func"
  } >> "$sim_rc"
fi
if grep -Fxq "$legacy_alias" "$sim_rc"; then
  tmp="$WORK/.zshrc.setup.new"
  grep -Fxv "$legacy_alias" "$sim_rc" > "$tmp"
  cat "$tmp" > "$sim_rc"
fi

# Re-run simulation: no duplicates should be appended.
before_hash="$(sha256sum "$sim_rc" | cut -d' ' -f1)"
if ! grep -Fxq "$dc_func" "$sim_rc"; then
  {
    echo ""
    echo "# dev-containers command"
    echo "$dc_unalias"
    echo "$dc_func"
  } >> "$sim_rc"
fi
if grep -Fxq "$legacy_alias" "$sim_rc"; then
  tmp="$WORK/.zshrc.setup.new2"
  grep -Fxv "$legacy_alias" "$sim_rc" > "$tmp"
  cat "$tmp" > "$sim_rc"
fi
after_hash="$(sha256sum "$sim_rc" | cut -d' ' -f1)"

grep -Fxq "$dc_unalias" "$sim_rc" || fail "zsh setup simulation missing unalias line"
grep -Fxq "$dc_func" "$sim_rc" || fail "zsh setup simulation missing dc function"
grep -Fxq "$legacy_alias" "$sim_rc" && fail "zsh setup simulation kept legacy alias"
[[ "$before_hash" == "$after_hash" ]] || fail "zsh setup simulation is not idempotent"
pass "zsh setup command wiring migrates alias -> function idempotently"

# setup.sh compdef migration: the canonical line is `compdef _dc dc` (dc is a
# shell function, so no path-keyed binding). A pre-existing path-qualified line
# from older setups must migrate to it. Regression guard: the "already present"
# check must be an exact-line match (-Fxq), because the new short line is a
# substring of the legacy path-qualified line -- a plain -F substring check
# would falsely treat the legacy line as already migrated.
compdef_new="compdef _dc dc"
compdef_legacy="compdef _dc dc '$ROOT_DIR/scripts/dc'"

run_compdef_migration() {  # <rc contents on stdin>
  local rc="$WORK/.zshrc.compdef"
  cat > "$rc"
  if grep -Fxq "$compdef_new" "$rc"; then
    :
  elif grep -Fxq "$compdef_legacy" "$rc"; then
    local t="$WORK/.zshrc.compdef.new"
    awk -v old="$compdef_legacy" -v new="$compdef_new" '$0 == old { print new; next } { print }' "$rc" > "$t"
    cat "$t" > "$rc"
  else
    { echo ""; echo "$compdef_new"; } >> "$rc"
  fi
  if grep -Fxq "$compdef_legacy" "$rc" && grep -Fxq "$compdef_new" "$rc"; then
    local t="$WORK/.zshrc.compdef.new"
    grep -Fxv "$compdef_legacy" "$rc" > "$t"
    cat "$t" > "$rc"
  fi
  printf '%s' "$(grep -E '^compdef _dc' "$rc")"
}

out="$(printf '%s\n' "$compdef_legacy" | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: legacy not migrated -> [$out]"
out="$(printf '%s\n' "$compdef_new" | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: new form changed -> [$out]"
out="$(printf '# fresh\n' | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: fresh install not wired -> [$out]"
out="$(printf '%s\n%s\n' "$compdef_new" "$compdef_legacy" | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: both-present did not drop legacy -> [$out]"
pass "zsh compdef migrates path-form -> compdef _dc dc"

echo ""
echo "All completion checks passed."
