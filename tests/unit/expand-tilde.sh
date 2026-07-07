#!/usr/bin/env bash
# =============================================================================
# tests/unit/expand-tilde.sh - dce_expand_tilde.
#
# Proves the canonical ~ / relative-path normalization helper produces the same
# results the previously duplicated inline copies did:
#   - "~" and "~/..." -> $HOME / $HOME/...
#   - absolute paths -> untouched
#   - relative path + base="config" -> $HOME/.config/dce-enclave/<path>
#   - relative path + base empty (or omitted) -> untouched
#   - empty value -> empty (never becomes .../dce-enclave/)
#
# Pure string handling, no I/O. Sourced from core.sh so the same helper is
# reachable by every runtime script that sources lib/common.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- tilde expansion (both bases) --------------------------------------------
# Tilde test inputs built via $'\x7e' (ANSI-C hex escape for '~') because a
# literal '~' in quotes trips SC2088; these are DATA passed to the helper, not
# shell expansions the shell would resolve on its own.
T_BARE=$'\x7e'              # ~
T_SLASH=$'\x7e/'            # ~/
T_FOO=$'\x7e/foo'           # ~/foo
T_NESTED=$'\x7e/a/b/c'      # ~/a/b/c
[[ "$(dce_expand_tilde "$T_BARE")" == "$HOME" ]] \
  || fail "tilde: '~' must expand to \$HOME (got: $(dce_expand_tilde "$T_BARE"))"
[[ "$(dce_expand_tilde "$T_SLASH")" == "$HOME/" ]] \
  || fail "tilde: '~/' must expand to \$HOME/ (trailing slash preserved)"
[[ "$(dce_expand_tilde "$T_FOO")" == "$HOME/foo" ]] \
  || fail "tilde: '~/foo' must expand to \$HOME/foo"
[[ "$(dce_expand_tilde "$T_NESTED")" == "$HOME/a/b/c" ]] \
  || fail "tilde: nested ~/ must preserve the rest"
# tilde expansion applies regardless of base.
[[ "$(dce_expand_tilde "$T_FOO" config)" == "$HOME/foo" ]] \
  || fail "tilde: '~/foo' + config base must still expand ~ (not config-relative)"
pass "tilde: ~ and ~/... expand to \$HOME under every base"

# --- absolute paths untouched ------------------------------------------------
[[ "$(dce_expand_tilde '/usr/local')" == "/usr/local" ]] \
  || fail "absolute: must be left untouched (default base)"
[[ "$(dce_expand_tilde '/usr/local' config)" == "/usr/local" ]] \
  || fail "absolute: must be left untouched (config base)"
pass "absolute: untouched under every base"

# --- relative path + config base -> config dir -------------------------------
[[ "$(dce_expand_tilde 'myroot' config)" == "$HOME/.config/dce-enclave/myroot" ]] \
  || fail "config-relative: 'myroot' + config must resolve under the config dir"
[[ "$(dce_expand_tilde 'team/sub' config)" == "$HOME/.config/dce-enclave/team/sub" ]] \
  || fail "config-relative: nested relative must resolve under the config dir"
pass "config-relative: resolves against ~/.config/dce-enclave"

# --- relative path + empty/omitted base -> untouched -------------------------
[[ "$(dce_expand_tilde 'myroot')" == "myroot" ]] \
  || fail "default base: relative must be left untouched when base is omitted"
[[ "$(dce_expand_tilde 'myroot' '')" == "myroot" ]] \
  || fail "empty base: relative must be left untouched when base is empty"
# Only the literal "config" triggers relative resolution.
[[ "$(dce_expand_tilde 'myroot' pwd)" == "myroot" ]] \
  || fail "unknown base: relative must be left untouched for any non-config base"
pass "empty/unknown base: relative paths untouched"

# --- empty value -> empty (never .../dce-enclave/) ---------------------------
[[ -z "$(dce_expand_tilde '')" ]] \
  || fail "empty: '' must stay empty (default base)"
[[ -z "$(dce_expand_tilde '' config)" ]] \
  || fail "empty: '' + config must stay empty, not become .../dce-enclave/"
pass "empty: preserved under every base"

echo ""
echo "All dce_expand_tilde checks passed."
