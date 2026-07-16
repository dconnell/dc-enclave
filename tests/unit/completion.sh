#!/usr/bin/env bash
# =============================================================================
# tests/unit/completion.sh - Tab-completion regression and behavior coverage.
#
# Covers:
#   - Shared discovery (lib/complete-data.sh): project names, scope dedup/order,
#     the hardened global-config parser, and the subcommand list. This data is
#     shared by the bash and zsh front-ends, so it is the highest-leverage test.
#   - Bash dispatcher (scripts/dce-complete.bash): driven in-process by faking
#     COMP_WORDS/COMP_CWORD. Pins the variadic-project fix (dce start a b <TAB>).
#   - zsh completion (scripts/_dce): gated on zsh being installed; checks load +
#     registration, project exclusion, scope dedup, and per-subcommand specs.
#   - Shell-aware wiring (lib/platform.sh) + the migration that strips a stale
#     bash-completion line from a zsh rc.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

export HOME="$WORK"
DC_ROOT="$HOME/.config/dce-enclave"
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
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/complete-data.sh"
# Portable SHA-256 (dce_sha256_file: sha256sum -> shasum -> openssl) so the
# change-detection hashes below work on macOS too, which lacks sha256sum.
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

expect_sorted() {
  local label="$1" got="$2"; shift 2
  local want
  want="$(printf '%s\n' "$@" | sort)"
  got="$(printf '%s\n' "$got" | sort)"
  [[ "$got" == "$want" ]] || fail "$label: expected [$*] got [$got]"
  pass "$label"
}

expect_sorted "projects list" \
  "$(dce_complete_projects)" alpha beta gamma

expect_sorted "projects prefix filter (al)" \
  "$(dce_complete_projects al)" alpha

# Scopes dedup node (team+user) and preserve first-seen order; gamma-style
# whole-line matching prevents partial collisions.
scopes_out="$(dce_complete_scopes | sort)"
[[ "$scopes_out" == "$(printf '%s\n' all golang node | sort)" ]] \
  || fail "scopes dedup: expected [all golang node] got [$scopes_out]"
pass "scopes dedup + membership"

subs="$(dce_complete_subcommands | sort)"
for c in new start stop status s list ls shell logs editor extensions exec restart rm \
         rebuild-container rebuild-image snapshot snapshots provenance clean config network net doctor install rotate-token version help; do
  grep -qx "$c" <<<"$subs" || fail "subcommands missing: $c"
done
pass "subcommands list"

# config data layer: subactions + writable keys.
expect_sorted "config subactions" \
  "$(dce_complete_config_subactions)" get ls set show sync-vscode
expect_sorted "config keys" \
  "$(dce_complete_config_keys)" cpus hide memory networks ports scopes

# doctor targets: the five backend names plus configured projects.
expect_sorted "doctor targets" \
  "$(dce_complete_doctor_targets)" apple docker orbstack colima podman alpha beta gamma

# Hardened global-config parser: must accept a clean quoted value and reject
# anything that could execute ($, backtick, or unquoted).
ok_cfg="$DC_ROOT/config"
[[ "$(_dce_read_team_dir "$ok_cfg")" == "$TEAM_DIR" ]] \
  || fail "parser should accept valid DC_TEAM_DIR quoted value"
[[ "$(_dce_read_user_dir "$ok_cfg")" == "$USER_DIR" ]] \
  || fail "parser should accept valid DC_USER_DIR quoted value"
# shellcheck disable=SC2016  # literal $/backtick written into a test config
printf 'DC_TEAM_DIR="$HOME/evil"\n' > "$WORK/dollar"
# shellcheck disable=SC2016  # literal backtick written into a test config
printf 'DC_TEAM_DIR="x`id`"\n'      > "$WORK/btick"
printf 'DC_TEAM_DIR=unquoted\n'      > "$WORK/unq"
_dce_read_team_dir "$WORK/dollar" >/dev/null && fail "parser leaked a \$-value"
_dce_read_team_dir "$WORK/btick"  >/dev/null && fail "parser leaked a backtick-value"
_dce_read_team_dir "$WORK/unq"    >/dev/null && fail "parser leaked an unquoted value"
pass "hardened parser accepts valid, rejects unsafe"

# Empty/missing dirs must not crash under either shell.
EMPTY_HOME="$(mktemp -d)"
( HOME="$EMPTY_HOME" bash -c "source '$ROOT_DIR/lib/complete-data.sh'; \
     dce_complete_projects >/dev/null; dce_complete_scopes >/dev/null" ) \
  || fail "empty HOME crashed the discovery functions under bash"
rm -rf "$EMPTY_HOME"
pass "discovery safe on empty HOME (bash)"

# ---------------------------------------------------------------------------
# Section 2 - bash dispatcher (scripts/dce-complete.bash)
# ---------------------------------------------------------------------------
# Stub `complete` so sourcing the file does not register globally.
complete() { :; }
# shellcheck disable=SC1091  # script include, runtime-resolved path
source "$ROOT_DIR/scripts/dce-complete.bash"

# Drive _dce_complete by faking the completion line. $1 = COMP_CWORD, rest =
# COMP_WORDS (the word being completed is COMP_WORDS[COMP_CWORD]).
drive() {
  local cword="$1"; shift
  COMP_WORDS=("$@")
  COMP_CWORD="$cword"
  COMPREPLY=()
  _dce_complete
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

drive 1 dce "st"; assert_reply "subcommand prefix 'st'" start stop status

# Headline regression: variadic project completion + already-typed exclusion.
drive 3 dce start alpha "";            assert_reply "start alpha <TAB>" beta gamma
drive 4 dce start alpha beta "";       assert_reply "start alpha beta <TAB>" gamma
drive 5 dce stop alpha beta gamma "";  assert_empty   "stop all three <TAB>"

# shell takes exactly one project; nothing past it.
drive 2 dce shell "";       assert_reply "shell <TAB>" alpha beta gamma
drive 3 dce shell alpha ""; assert_empty   "shell alpha <TAB>"

# editor: optional --editor <id>, then one project.
drive 2 dce editor "";              assert_reply "editor <TAB>" --editor alpha beta gamma
drive 3 dce editor alpha "";        assert_empty   "editor alpha <TAB> (nothing past project)"
drive 3 dce editor --editor "";     assert_reply "editor --editor <TAB>" vscode vscode-insiders
drive 4 dce editor --editor vscode ""; assert_reply "editor --editor vscode <TAB>" alpha beta gamma

# extensions: subactions at slot 2; project + flags after.
drive 2 dce extensions ""; assert_reply "extensions <TAB>" \
  available capture diff host list show
drive 3 dce extensions show ""; assert_reply "extensions show <TAB>" alpha beta gamma
# Past the project, the output flags are offered (--editor/--format).
drive 4 dce extensions show alpha ""; assert_reply "extensions show alpha <TAB>" --editor --format
# --editor / --format / --scope consume a value.
drive 3 dce extensions --editor ""; assert_reply "extensions --editor <TAB>" vscode
drive 4 dce extensions list --format ""; assert_reply "extensions list --format <TAB>" ids json manifest
# capture offers --scope/--user/--team/--all plus project.
drive 3 dce extensions capture ""; assert_reply "extensions capture <TAB>" alpha beta gamma

# rebuild-container: one project, then the flags.
drive 2 dce rebuild-container "";  assert_reply "rebuild-container <TAB>" alpha beta gamma
drive 3 dce rebuild-container alpha "--"; assert_reply "rebuild-container alpha --<TAB>" \
  --from-snap --inject-creds --keep-hidden-volumes --rotate-keys --sync --sync-ignore --yes

drive 3 dce rebuild-container alpha ""; assert_reply "rebuild-container alpha <TAB>" \
  --from-snap --inject-creds --keep-hidden-volumes --rotate-keys --sync --sync-ignore --yes -y

# install: one project, then a directory.
drive 2 dce install "";     assert_reply "install <TAB>" alpha beta gamma
# Directory completion is cwd-based (compgen -d), so run it from a controlled
# dir with a known subdir instead of depending on wherever this test (or a
# runner like run-all.sh) was invoked from.
mkdir -p "$WORK/dirs/subdir"
_prev_pwd="$PWD"
cd "$WORK/dirs"
drive 3 dce install alpha ""; COMPREPLY=("${COMPREPLY[@]/%//}")  # dirs get a trailing /
[[ "${COMPREPLY[*]}" == *subdir/* ]] \
  || fail "install pos3 should complete directories (got [${COMPREPLY[*]:-}])"
cd "$_prev_pwd"
pass "install pos3 completes directories"

# rebuild-image targets.
drive 2 dce rebuild-image ""; assert_reply "rebuild-image <TAB>" all base

# provenance: one project, then --history/--all flags.
drive 2 dce provenance "";              assert_reply "provenance <TAB>" alpha beta gamma
drive 3 dce provenance alpha "--";      assert_reply "provenance alpha --<TAB>" --all --history

# network: subactions at position 2.
drive 2 dce network ""; assert_reply "network <TAB>" \
  add create list ls members remove rm

# config: subactions at position 2; project at 3; key at 4 (get/set);
# sync-vscode offers --dry-run at position 4.
drive 2 dce config ""; assert_reply "config <TAB>" get ls set show sync-vscode
drive 3 dce config show ""; assert_reply "config show <TAB>" alpha beta gamma
drive 3 dce config get "";  assert_reply "config get <project> <TAB>" alpha beta gamma
drive 4 dce config get alpha ""; assert_reply "config get alpha <key> <TAB>" \
  cpus hide memory networks ports scopes
drive 4 dce config set alpha ""; assert_reply "config set alpha <key> <TAB>" \
  cpus hide memory networks ports scopes
# set's value (position 5) is free-form -> no completion.
drive 5 dce config set alpha cpus ""; assert_empty "config set alpha cpus <val> (free-form)"
# sync-vscode: project at slot 3; --dry-run at slot 4.
drive 3 dce config sync-vscode ""; assert_reply "config sync-vscode <TAB>" alpha beta gamma
drive 4 dce config sync-vscode alpha ""; assert_reply "config sync-vscode alpha <TAB>" --dry-run
# ls takes no further args.
drive 3 dce config ls ""; assert_empty "config ls <TAB> (no further args)"

# doctor: one optional target (backend or project). Backends are always offered;
# configured projects (alpha/beta/gamma) appear too.
drive 2 dce doctor ""; assert_reply "doctor <TAB>" \
  apple colima docker gamma orbstack podman alpha beta

# logs: one project, then log flags (--tail's value is not completed).
drive 2 dce logs "";                assert_reply "logs <TAB>" alpha beta gamma
drive 3 dce logs alpha "";          assert_reply "logs alpha <TAB>" --follow -f --tail
drive 3 dce logs alpha "--";        assert_reply "logs alpha --<TAB>" --follow --tail
drive 4 dce logs alpha --tail "";   assert_empty "logs alpha --tail <val> (no completion)"

# exec: optional leading --root, one project, then a free-form command.
drive 2 dce exec "";                assert_reply "exec <TAB>" --root alpha beta gamma
drive 3 dce exec --root "";         assert_reply "exec --root <TAB>" alpha beta gamma
drive 3 dce exec alpha "";          assert_empty "exec alpha <cmd> (free-form)"

# restart: variadic projects (excludes already-typed), like start/stop.
drive 2 dce restart "";             assert_reply "restart <TAB>" alpha beta gamma
drive 3 dce restart alpha "";       assert_reply "restart alpha <TAB>" beta gamma

# rm: one project, then removal flags.
drive 2 dce rm "";                  assert_reply "rm <TAB>" alpha beta gamma
drive 3 dce rm alpha "";            assert_reply "rm alpha <TAB>" --yes -y --keep-config --keep-volumes

# clean: flags + a single project when --hidden-volumes/--snapshots is active.
drive 2 dce clean "--"; assert_reply "clean --<TAB>" --dry-run --hidden-volumes --snapshots
drive 3 dce clean --hidden-volumes ""; assert_reply "clean --hidden-volumes <TAB>" \
  --dry-run --hidden-volumes --snapshots alpha beta gamma
# once a project is typed, only flags remain.
drive 4 dce clean --hidden-volumes alpha "--"; assert_reply "clean --hidden-volumes alpha --<TAB>" \
  --dry-run --hidden-volumes --snapshots
# --snapshots scopes to a project like --hidden-volumes does.
drive 3 dce clean --snapshots ""; assert_reply "clean --snapshots <TAB>" \
  --dry-run --hidden-volumes --snapshots alpha beta gamma
drive 4 dce clean --snapshots alpha "--"; assert_reply "clean --snapshots alpha --<TAB>" \
  --dry-run --hidden-volumes --snapshots

# snapshot / snapshots: position 1 offers rm/list + projects; labels are free.
drive 2 dce snapshot ""; assert_reply "snapshot <TAB>" rm alpha beta gamma
drive 3 dce snapshot rm ""; assert_reply "snapshot rm <project> <TAB>" alpha beta gamma
# --exclude-volumes / --exclude-volume / --yes are offered once a project is present.
drive 3 dce snapshot alpha "--exc"; assert_reply "snapshot alpha --exc <TAB>" --exclude-volume --exclude-volumes
drive 3 dce snapshot alpha "--yes"; assert_reply "snapshot alpha --yes <TAB>" --yes
# empty prefix offers all create flags, including the -y short form.
drive 3 dce snapshot alpha ""; assert_reply "snapshot alpha <TAB>" --exclude-volume --exclude-volumes --yes -y
drive 2 dce snapshots ""; assert_reply "snapshots <TAB>" list alpha beta gamma
drive 3 dce snapshots list ""; assert_reply "snapshots list <project> <TAB>" alpha beta gamma

# new: name is free text (no completion), pos3 = scope + flags.
drive 2 dce new "";               assert_empty "new <name> (free text, no completion)"
drive 3 dce new foo "";           assert_reply "new foo <TAB> (scope + flags)" \
  --config --cpus --hide --ip --memory --network --repo-path --save-team --save-user --sync --sync-ignore --yes -y all golang node
# --network/--ip consume a value (no completion offered for the value).
drive 4 dce new foo --network ""; assert_empty "new foo --network <val> (no completion)"

# ---------------------------------------------------------------------------
# Section 3 - zsh completion (scripts/_dce), gated on zsh being installed
# ---------------------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  # 3a. Load + registration: the file must define its functions and register
  #     via compdef without errors under a real compinit.
  zsh -c "
    fpath=('$ROOT_DIR/scripts' \$fpath)
    autoload -Uz compinit && compinit -u 2>/dev/null
    autoload -Uz _dce
    compdef _dce dce
    [[ \"\${_comps[dce]}\" == _dce ]] || { print 'FAIL: compdef did not register _dce for dce'; exit 1 }
    print 'PASS: zsh load + compdef registration'
  " || fail "zsh completion load/registration failed"

  # 3b. Leaf logic, routing, and dispatch specs via stubbed primitives.
  #     The _arguments stub simulates the real '1: :->subcmd' '*:: :->args'
  #     state machine (including the *:: word/CURRENT reset), so the routing
  #     and reduced-context assertions exercise the off-by-one fix rather than
  #     the real _arguments engine (which needs a live ZLE widget).
  zsh -c '
    typeset -ga ADD SPEC
    # Validate option specs enough to catch parser-level authoring mistakes.
    # The prior stub only recorded strings and never parsed them, so malformed
    # specs (like an unescaped "[" inside an option description) were missed.
    _validate_zsh_option_spec() {
      local spec="$1"
      local i ch in_desc=0 escaped=0
      for ((i = 1; i <= ${#spec}; i++)); do
        ch="${spec[i]}"
        if (( escaped )); then
          escaped=0
          continue
        fi
        if [[ "$ch" == "\\" ]]; then
          escaped=1
          continue
        fi
        if (( in_desc )); then
          if [[ "$ch" == "[" ]]; then
            print "FAIL: zsh option spec has unescaped [ in description: $spec"
            return 1
          fi
          if [[ "$ch" == "]" ]]; then
            in_desc=0
          fi
          continue
        fi
        [[ "$ch" == "[" ]] && in_desc=1
      done
      if (( in_desc )); then
        print "FAIL: zsh option spec has unterminated description: $spec"
        return 1
      fi
      return 0
    }

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
        # Mirror enough parser behavior to catch malformed option specs.
        for spec in "$@"; do
          if [[ "$spec" == -* || "$spec" == +* || "$spec" == \** ]]; then
            if [[ "$spec" == *"["* ]]; then
              _validate_zsh_option_spec "$spec" || return 1
            fi
          fi
        done
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
    source "'"$ROOT_DIR"'/scripts/_dce"
    # The lib is already sourced above, so the lazy loader should be a no-op.
    _dce_load_complete_data() { return 0; }

    # Top-level routing. Completing the subcommand slot (CURRENT==2, whether
    # empty or partially typed) must offer subcommands; once a subcommand token
    # is committed, _dce_dispatch runs in the REDUCED context produced by the
    # *:: reset -- $words[1] is the subcommand and $CURRENT is decremented.
    # This is the regression for the off-by-one: without the reset, $words[1]
    # would be `dce` and $CURRENT would stay unchanged, so every numbered
    # _arguments spec would target the wrong slot.
    functions -c _dce_subcommands _dce_subcommands_real
    functions -c _dce_dispatch _dce_dispatch_real
    typeset TOP="" RC_CURRENT=0 RC_W1=""
    _dce_subcommands() { TOP="subs"; }
    _dce_dispatch() { TOP="dispatch:$1"; RC_CURRENT=$CURRENT; RC_W1="${words[1]}"; }

    for line in "dce |2" "dce st|2"; do
      w="${line%|*}"; c="${line#*|}"
      words=(${(z)w})
      CURRENT=$c
      TOP=""; _dce
      [[ "$TOP" == "subs" ]] || { print "FAIL: zsh subcommand routing for [$w] -> [$TOP]"; exit 1 }
    done

    words=(dce shell "")
    CURRENT=3
    TOP=""; RC_CURRENT=99; RC_W1=""; _dce
    [[ "$TOP" == "dispatch:shell" ]] || { print "FAIL: zsh dispatch arg -> [$TOP]"; exit 1 }
    [[ "$RC_W1" == "shell" ]] || { print "FAIL: *:: reset words[1] should be the subcommand, got [$RC_W1]"; exit 1 }
    [[ "$RC_CURRENT" == 2 ]] || { print "FAIL: *:: reset should decrement CURRENT to 2, got [$RC_CURRENT]"; exit 1 }

    # Variadic position keeps the same reset (start: further args still route).
    words=(dce start alpha "")
    CURRENT=4
    TOP=""; RC_CURRENT=99; _dce
    [[ "$TOP" == "dispatch:start" && "$RC_CURRENT" == 3 ]] \
      || { print "FAIL: zsh variadic routing/reset -> [$TOP] CURRENT=[$RC_CURRENT]"; exit 1 }

    functions -c _dce_subcommands_real _dce_subcommands
    functions -c _dce_dispatch_real _dce_dispatch
    unfunction _dce_subcommands_real _dce_dispatch_real
    print "PASS: zsh top-level routing + *:: word/CURRENT reset"

    ADD=(); _dce_projects alpha beta
    [[ "${ADD[*]}" == "gamma" ]] || { print "FAIL: zsh project exclude -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh projects exclude already-typed"

    ADD=(); _dce_scopes
    expected="all golang node"
    [[ "$(print -l -- "${ADD[@]}" | sort | tr "\n" " ")" == "$expected " ]] \
      || { print "FAIL: zsh scopes -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh scopes dedup"

    # rebuild-image targets come from the shared lib (single source of truth).
    ADD=(); _dce_rebuild_image_targets
    [[ "$(print -l -- "${ADD[@]}" | sort | tr "\n" " ")" == "all base " ]] \
      || { print "FAIL: zsh rebuild-image targets -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh rebuild-image targets"

    # Subcommand candidate set (also from the shared lib).
    ADD=(); _dce_subcommands
    local want="--help --version -h -v clean config doctor editor exec extensions help install list logs ls net network new provenance rebuild-container rebuild-image restart rm rotate-token s shell snapshot snapshots start status stop version"
    [[ "$(print -l -- "${ADD[@]}" | sort | tr "\n" " ")" == "$want " ]] \
      || { print "FAIL: zsh subcommand values -> [${ADD[*]}]"; exit 1 }
    print "PASS: zsh subcommand candidate set"

    # Dispatch specs encode the per-command grammar (the main authoring risk).
    chk() { SPEC=(); _dce_dispatch "$1"; [[ "${SPEC[*]}" == *"$2"* ]] || { print "FAIL: zsh $1 spec missing [$2] got [${SPEC[*]}]"; exit 1 }; }
    chk start            "*:project:"
    chk shell            "1:project:"
    chk editor           "1:project:"
    chk editor           "--editor+[editor id]"
    chk extensions       "1:subcommand: _dce_extensions_subactions"
    chk extensions       "--scope+[target scope for capture]"
    # capture-only flags must NOT be offered on non-capture subactions.
    words=(extensions show "") CURRENT=3 SPEC=(); _dce_extensions
    [[ "${SPEC[*]}" != *"--scope+"* ]] || { print "FAIL: zsh extensions show must not offer --scope -> [${SPEC[*]}]"; exit 1 }
    [[ "${SPEC[*]}" != *"--all["* ]] || { print "FAIL: zsh extensions show must not offer --all -> [${SPEC[*]}]"; exit 1 }
    words=(extensions capture "") CURRENT=3 SPEC=(); _dce_extensions
    [[ "${SPEC[*]}" == *"--scope+[target scope for capture]"* ]] || { print "FAIL: zsh extensions capture must offer --scope -> [${SPEC[*]}]"; exit 1 }
    [[ "${SPEC[*]}" == *"--all[capture: snapshot the full container install set]"* ]] || { print "FAIL: zsh extensions capture must offer --all -> [${SPEC[*]}]"; exit 1 }
    # extensions show/diff/list/available/capture complete a project at slot 2;
    # `host` does not. Verify the project spec is emitted for a project-taking
    # subaction (parity with editor/shell/logs and with the bash front-end).
    words=(extensions show "") CURRENT=3 SPEC=(); _dce_extensions
    [[ "${SPEC[*]}" == *"2:project"* ]] || { print "FAIL: zsh extensions show should complete a project at slot 2 -> [${SPEC[*]}]"; exit 1 }
    # `host` takes NO project -- the project spec must not appear.
    words=(extensions host "") CURRENT=3 SPEC=(); _dce_extensions
    [[ "${SPEC[*]}" != *"2:project"* ]] || { print "FAIL: zsh extensions host must not offer a project -> [${SPEC[*]}]"; exit 1 }
    chk logs             "1:project:"
    chk logs             "--follow["
    chk exec             "--root["
    chk exec             "1:project:"
    chk restart          "*:project:"
    chk rm               "1:project:"
    chk rm               "--keep-config["
    chk rebuild-container "--rotate-keys["
    chk rebuild-container "--inject-creds["
    chk rebuild-container "--yes["
    chk rebuild-container "-y["
    chk install          "2:dotfiles directory:_files -/"
    chk rotate-token     "1:project:"
    chk rebuild-image    "1:target:_dce_rebuild_image_targets"
    chk provenance       "1:project:_dce_projects_simple"
    chk provenance       "--history["
    chk new              "2:scope:_dce_scopes"
    chk new              "*--hide["
    chk new              "*--network["
    chk new              "--ip+["
    chk new              "--sync[replace the /workspace bind mount with a Mutagen-synced named volume]"
    chk new              "*--sync-ignore[workspace path(s) excluded from Mutagen sync]"
    chk new              "--yes[skip the recipe-repo-path confirmation prompt]"
    chk new              "-y[skip the recipe-repo-path confirmation prompt]"
    chk rebuild-container "--from-snap+[recreate from snapshot"
    chk rebuild-container "--sync[enable/refresh a Mutagen-synced workspace]"
    chk rebuild-container "*--sync-ignore[workspace path(s) excluded from Mutagen sync]"
    chk snapshot         "1:project or rm:"
    chk snapshot         "--exclude-volumes[skip ALL hidden-volume capture]"
    chk snapshot         "*--exclude-volume[exclude specific hidden volume"
    chk snapshot         "--yes[skip the confirmation prompt]"
    chk snapshots        "1:list or project:"
    # config: dispatched subcommand offers its subactions; get/set offer a key.
    chk config           "1:subcommand: _dce_config_subactions"
    words=(config get "") CURRENT=3 SPEC=(); _dce_config
    [[ "${SPEC[*]}" == *"3:key: _dce_config_keys"* ]] || { print "FAIL: zsh config get should offer a key at slot 3 -> [${SPEC[*]}]"; exit 1 }
    print "PASS: zsh config dispatch + key spec"
    # rm subcommand branch: completes a project at slot 2 and offers NO create
    # flags (parity with the bash rm path).
    words=(snapshot rm "") CURRENT=3 SPEC=(); _dce_snapshot
    [[ "${SPEC[*]}" == *"2:project"* ]] || { print "FAIL: zsh snapshot rm should complete a project at slot 2 -> [${SPEC[*]}]"; exit 1 }
    [[ "${SPEC[*]}" != *"--exclude-volumes"* ]] || { print "FAIL: zsh snapshot rm must not offer create flags -> [${SPEC[*]}]"; exit 1 }
    print "PASS: zsh snapshot rm completes a project, no create flags"
    print "PASS: zsh per-subcommand dispatch specs"
  ' || fail "zsh completion logic/spec test failed"
else
  echo "SKIP: zsh completion tests (zsh not installed)"
fi

# ---------------------------------------------------------------------------
# Section 4 - shell-aware wiring (lib/platform.sh) + migration
# ---------------------------------------------------------------------------
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/platform.sh"

check_profile() { # <shell> <expected_basename>
  local got
  got="$(platform_profile_file "$1")"
  [[ "${got##*/}" == "$2" ]] || fail "platform_profile_file $1 -> expected ~/$2 got $got"
  pass "profile for $1 -> ~/$2"
}
# macOS profile resolution.
# shellcheck disable=SC2329
# Test stub overriding the real platform_os; invoked indirectly via platform.sh.
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
  echo "alias dce='$ROOT_DIR/scripts/dce'"
  echo "source '$ROOT_DIR/scripts/dce-complete.bash'"
  echo "export EDITOR=vim"
} > "$mig_rc"
stale="source '$ROOT_DIR/scripts/dce-complete.bash'"
grep -Fv "$stale" "$mig_rc" > "$WORK/.zshrc.new"
cat "$WORK/.zshrc.new" > "$mig_rc"
grep -Fq "$stale" "$mig_rc" && fail "migration did not remove the stale line"
grep -Fq "# my config" "$mig_rc" || fail "migration dropped unrelated content"
grep -Fq "alias dce='$ROOT_DIR/scripts/dce'" "$mig_rc" || fail "migration unexpectedly removed legacy dce alias"
grep -Fq "export EDITOR=vim" "$mig_rc" || fail "migration dropped unrelated content"
pass "migration strips only the stale bash-completion line"

# setup.sh zsh command wiring: add function + unalias, remove managed legacy
# alias, and avoid duplicate inserts when rerun.
sim_rc="$WORK/.zshrc.setup"
{
  echo "# preexisting"
  echo "alias dce='$ROOT_DIR/scripts/dce'"
} > "$sim_rc"

dce_unalias="unalias dce 2>/dev/null"
dce_func="dce() { \"$ROOT_DIR/scripts/dce\" \"\$@\"; }"
legacy_alias="alias dce='$ROOT_DIR/scripts/dce'"

if ! grep -Fxq "$dce_func" "$sim_rc"; then
  {
    echo ""
    echo "# DC Enclave command"
    echo "$dce_unalias"
    echo "$dce_func"
  } >> "$sim_rc"
fi
if grep -Fxq "$legacy_alias" "$sim_rc"; then
  tmp="$WORK/.zshrc.setup.new"
  grep -Fxv "$legacy_alias" "$sim_rc" > "$tmp"
  cat "$tmp" > "$sim_rc"
fi

# Re-run simulation: no duplicates should be appended.
before_hash="$(dce_sha256_file "$sim_rc")"
if ! grep -Fxq "$dce_func" "$sim_rc"; then
  {
    echo ""
    echo "# DC Enclave command"
    echo "$dce_unalias"
    echo "$dce_func"
  } >> "$sim_rc"
fi
if grep -Fxq "$legacy_alias" "$sim_rc"; then
  tmp="$WORK/.zshrc.setup.new2"
  grep -Fxv "$legacy_alias" "$sim_rc" > "$tmp"
  cat "$tmp" > "$sim_rc"
fi
after_hash="$(dce_sha256_file "$sim_rc")"

grep -Fxq "$dce_unalias" "$sim_rc" || fail "zsh setup simulation missing unalias line"
grep -Fxq "$dce_func" "$sim_rc" || fail "zsh setup simulation missing dce function"
grep -Fxq "$legacy_alias" "$sim_rc" && fail "zsh setup simulation kept legacy alias"
[[ "$before_hash" == "$after_hash" ]] || fail "zsh setup simulation is not idempotent"
pass "zsh setup command wiring migrates alias -> function idempotently"

# setup.sh compdef migration: the canonical line is `compdef _dce dce` (dce is a
# shell function, so no path-keyed binding). A pre-existing path-qualified line
# from older setups must migrate to it. Regression guard: the "already present"
# check must be an exact-line match (-Fxq), because the new short line is a
# substring of the legacy path-qualified line -- a plain -F substring check
# would falsely treat the legacy line as already migrated.
compdef_new="compdef _dce dce"
compdef_legacy="compdef _dce dce '$ROOT_DIR/scripts/dce'"

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
  printf '%s' "$(grep -E '^compdef _dce' "$rc")"
}

out="$(printf '%s\n' "$compdef_legacy" | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: legacy not migrated -> [$out]"
out="$(printf '%s\n' "$compdef_new" | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: new form changed -> [$out]"
out="$(printf '# fresh\n' | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: fresh install not wired -> [$out]"
out="$(printf '%s\n%s\n' "$compdef_new" "$compdef_legacy" | run_compdef_migration)"
[[ "$out" == "$compdef_new" ]] || fail "compdef migration: both-present did not drop legacy -> [$out]"
pass "zsh compdef migrates path-form -> compdef _dce dce"

echo ""
echo "All completion checks passed."
