#!/usr/bin/env bash
# =============================================================================
# tests/unit/extensions-helpers.sh - Pure lib/extensions.sh API unit tests.
#
# Covers the host-side, pure helpers in lib/extensions.sh in-process with
# crafted manifest fixtures: no backend, no scripts/*.sh subprocess.
#   - dce_ext_supported_editors / dce_ext_is_supported / dce_ext_namespace
#   - dce_ext_normalize_editor / dce_ext_default_editor
#   - dce_ext_manifest_path
#   - dce_ext_parse_manifest (comments, blanks, inline comments, de-dup, CR)
#   - dce_ext_resolve_set (layering order, de-dup first-occurrence, all-first)
#   - dce_ext_manifests_exist (migration-guard predicate)
#   - dce_ext_format (ids / manifest / json)
#   - dce_ext_minus (set difference)
#
# Container/host dispatch (dce_ext_list_installed / _list_host / _install_one)
# is exercised end-to-end in tests/contract/extensions.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/extensions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

TEAM_ROOT="$WORK/team"
USER_ROOT="$WORK/user"
mkdir -p "$TEAM_ROOT" "$USER_ROOT"

# =============================================================================
# A. Registry helpers
# =============================================================================
[[ "$(dce_ext_supported_editors)" == "vscode" ]] \
  || fail "supported_editors: expected vscode only, got [$(dce_ext_supported_editors)]"
dce_ext_is_supported vscode || fail "is_supported: vscode must be supported"
if dce_ext_is_supported vscode-insiders; then
  fail "is_supported: vscode-insiders must NOT be supported in v1"
fi
[[ "$(dce_ext_namespace vscode)" == "vscode" ]] \
  || fail "namespace: vscode -> vscode"
if dce_ext_namespace vscode-insiders >/dev/null 2>&1; then
  fail "namespace: vscode-insiders must fail (not yet supported)"
fi
[[ "$(dce_ext_default_editor)" == "vscode" ]] || fail "default_editor: vscode"
# normalize: code -> vscode alias; unknown passes through (gated by is_supported).
[[ "$(dce_ext_normalize_editor code)" == "vscode" ]] \
  || fail "normalize_editor: code -> vscode"
[[ "$(dce_ext_normalize_editor vscode)" == "vscode" ]] \
  || fail "normalize_editor: vscode passthrough"
pass "registry: supported_editors / is_supported / namespace / default / normalize"

# =============================================================================
# B. manifest_path
# =============================================================================
P="$(dce_ext_manifest_path "$TEAM_ROOT" vscode nodejs)"
[[ "$P" == "$TEAM_ROOT/extensions/vscode/nodejs.txt" ]] \
  || fail "manifest_path: expected team/extensions/vscode/nodejs.txt, got $P"
if dce_ext_manifest_path "$TEAM_ROOT" zed nodejs >/dev/null 2>&1; then
  fail "manifest_path: unknown editor must fail"
fi
pass "manifest_path: layout + namespace; unknown editor rejected"

# =============================================================================
# C. parse_manifest: comments, blanks, inline comments, de-dup, CR
# =============================================================================
MF="$WORK/m1.txt"
printf '# header comment\n\nfoo.bar\nfoo.bar\n  spaced.line  \n# mid\nbaz.qux # inline comment\nignored\r\n' > "$MF"
OUT="$(dce_ext_parse_manifest "$MF")"
EXP=$'foo.bar\nspaced.line\nbaz.qux # inline comment\nignored'

# Hmm: inline comment handling. The plan says "# comments" are allowed. An
# inline trailing comment should be stripped. Re-derive expected after we
# decide the rule: strip from the first '#' on any line (extension IDs contain
# no '#'), then trim whitespace. So 'baz.qux # inline comment' -> 'baz.qux'.
EXP=$'foo.bar\nspaced.line\nbaz.qux\nignored'
[[ "$OUT" == "$EXP" ]] || fail "parse_manifest: got [$OUT] expected [$EXP]"
# de-dup: foo.bar appears twice but emits once.
[[ "$(printf '%s\n' "$OUT" | grep -c '^foo.bar$')" -eq 1 ]] \
  || fail "parse_manifest: duplicate foo.bar not de-duped"
# missing file -> no output, success.
[[ -z "$(dce_ext_parse_manifest "$WORK/does-not-exist.txt")" ]] \
  || fail "parse_manifest: missing file must produce no output"
pass "parse_manifest: strips comments/blanks/CR, trims, de-dups; missing file ok"

# =============================================================================
# D. resolve_set: layering order + de-dup (first occurrence wins), all-first
# =============================================================================
# Build a full fixture:
#   team/all.txt        : all.team, shared.id
#   user/all.txt        : all.user
#   team/nodejs.txt     : node.team, shared.id
#   user/nodejs.txt     : node.user
mkdir -p "$TEAM_ROOT/extensions/vscode" "$USER_ROOT/extensions/vscode"
printf 'all.team\nshared.id\n' > "$TEAM_ROOT/extensions/vscode/all.txt"
printf 'all.user\n'           > "$USER_ROOT/extensions/vscode/all.txt"
printf 'node.team\nshared.id\n' > "$TEAM_ROOT/extensions/vscode/nodejs.txt"
printf 'node.user\n'            > "$USER_ROOT/extensions/vscode/nodejs.txt"

RES="$(dce_ext_resolve_set vscode "$TEAM_ROOT" "$USER_ROOT" "nodejs")"
# Expected order: all.team, shared.id, all.user, node.team, node.user
# (shared.id appears in team/nodejs too but is de-duped at first occurrence.)
EXP=$'all.team\nshared.id\nall.user\nnode.team\nnode.user'
[[ "$RES" == "$EXP" ]] || fail "resolve_set: got [$RES] expected [$EXP]"

# No 'all' manifests present + a scope manifest -> just that scope's set.
TEAM2="$WORK/t2"; USER2="$WORK/u2"
mkdir -p "$TEAM2/extensions/vscode" "$USER2/extensions/vscode"
printf 'only.node\n' > "$USER2/extensions/vscode/nodejs.txt"
RES2="$(dce_ext_resolve_set vscode "$TEAM2" "$USER2" "nodejs")"
[[ "$RES2" == "only.node" ]] || fail "resolve_set(no all): got [$RES2]"

# Empty scopes + no all manifests -> empty output.
RES3="$(dce_ext_resolve_set vscode "$TEAM2" "$USER2" "")"
[[ -z "$RES3" ]] || fail "resolve_set(empty): must be empty, got [$RES3]"

# Unknown editor -> failure.
if dce_ext_resolve_set zed "$TEAM_ROOT" "$USER_ROOT" "nodejs" >/dev/null 2>&1; then
  fail "resolve_set: unknown editor must fail"
fi

# Missing scope (requested but no manifest anywhere) -> silently skipped (no error).
RES4="$(dce_ext_resolve_set vscode "$TEAM2" "$USER2" "nodejs,rust")"
[[ "$RES4" == "only.node" ]] || fail "resolve_set: missing scope must be skipped, got [$RES4]"
pass "resolve_set: layering order, de-dup first-occurrence, all-first, missing scope skipped"

# resolve_csv: same set as a comma-joined CSV; empty -> "".
CSV="$(dce_ext_resolve_csv vscode "$TEAM_ROOT" "$USER_ROOT" "nodejs")"
[[ "$CSV" == "all.team,shared.id,all.user,node.team,node.user" ]] \
  || fail "resolve_csv: got [$CSV]"
ECSV="$(dce_ext_resolve_csv vscode "$TEAM2" "$USER2" "")"
[[ -z "$ECSV" ]] || fail "resolve_csv: empty resolution must be \"\", got [$ECSV]"
pass "resolve_csv: CSV rendering + empty handling"

# =============================================================================
# E. manifests_exist: migration-guard predicate
# =============================================================================
dce_ext_manifests_exist vscode "$TEAM_ROOT" "$USER_ROOT" "nodejs" \
  || fail "manifests_exist: nodejs project with all+nodejs manifests must be true"
dce_ext_manifests_exist vscode "$TEAM_ROOT" "$USER_ROOT" "" \
  || fail "manifests_exist: empty scopes but all.txt exists must be true"
# Empty roots dir, no manifests at all.
if dce_ext_manifests_exist vscode "$TEAM2" "$USER2" ""; then
  : # TEAM2/USER2 has nodejs.txt in user; all.txt absent. empty scopes -> all only.
  fail "manifests_exist: TEAM2/USER2 has no all manifest; empty scopes -> false"
fi
EMPTY_T="$WORK/et"; EMPTY_U="$WORK/eu"
mkdir -p "$EMPTY_T" "$EMPTY_U"
if dce_ext_manifests_exist vscode "$EMPTY_T" "$EMPTY_U" "nodejs"; then
  fail "manifests_exist: empty roots must be false"
fi
# Scope-only manifest (no all) counts as existing.
mkdir -p "$EMPTY_T/extensions/vscode"
printf 'x.y\n' > "$EMPTY_T/extensions/vscode/rust.txt"
dce_ext_manifests_exist vscode "$EMPTY_T" "$EMPTY_U" "rust" \
  || fail "manifests_exist: rust scope manifest present must be true"
# But a scope NOT present + no all -> false.
if dce_ext_manifests_exist vscode "$EMPTY_T" "$EMPTY_U" "python"; then
  fail "manifests_exist: absent scope + no all must be false"
fi
# A malformed (non-empty) scope set fails CLOSED (consistent with resolve_set),
# rather than silently degrading to "only the all manifest" lookups.
if dce_ext_manifests_exist vscode "$EMPTY_T" "$EMPTY_U" "Bad Scope" 2>/dev/null; then
  fail "manifests_exist: malformed non-empty scope must fail closed"
fi
pass "manifests_exist: all/scope presence; empty -> false; malformed -> fail closed"

# =============================================================================
# F. format: ids / manifest / json
# =============================================================================
IDS="$(dce_ext_format ids vscode a.b c.d)"
[[ "$IDS" == $'a.b\nc.d' ]] || fail "format ids: got [$IDS]"
MAN="$(dce_ext_format manifest vscode a.b c.d)"
[[ "$MAN" == $'a.b\nc.d' ]] || fail "format manifest: must equal ids, got [$MAN]"
JSON="$(dce_ext_format json vscode a.b c.d)"
[[ "$JSON" == '["a.b","c.d"]' ]] || fail "format json: got [$JSON]"
# JSON escapes a double-quote.
JSON2="$(dce_ext_format json vscode 'a"b')"
[[ "$JSON2" == '["a\"b"]' ]] || fail "format json escape: got [$JSON2]"
# Empty set -> ids/manifest empty; json -> [].
[[ -z "$(dce_ext_format ids vscode)" ]] || fail "format ids empty: must be empty"
[[ "$(dce_ext_format json vscode)" == '[]' ]] || fail "format json empty: must be []"
# Bad format -> failure.
if dce_ext_format bogus vscode a.b >/dev/null 2>&1; then
  fail "format: bogus format must fail"
fi
pass "format: ids/manifest/json + escape + empty + bad format"

# =============================================================================
# G. minus: set difference (stdin A minus args B)
# =============================================================================
DIFF="$(printf '%s\n' a b c d | dce_ext_minus b d)"
[[ "$DIFF" == $'a\nc' ]] || fail "minus: got [$DIFF]"
# Empty B -> A unchanged.
DIFF2="$(printf 'a\nb\n' | dce_ext_minus)"
[[ "$DIFF2" == $'a\nb' ]] || fail "minus: empty B must pass through"
# Blanks in stdin are skipped.
DIFF3="$(printf 'a\n\nb\n' | dce_ext_minus)"
[[ "$DIFF3" == $'a\nb' ]] || fail "minus: blank lines skipped"
pass "minus: set difference, empty B, blanks skipped"

# =============================================================================
# H. is_valid_id: publisher.name format gate (protects manifest integrity)
# =============================================================================
dce_ext_is_valid_id "esbenp.prettier-vscode" || fail "is_valid_id: publisher.name rejected"
dce_ext_is_valid_id "dbaeumer.vscode-eslint" || fail "is_valid_id: second valid id rejected"
dce_ext_is_valid_id "a.b"                     || fail "is_valid_id: minimal a.b rejected"
# No dot -> invalid.
dce_ext_is_valid_id "nohostdot"               && fail "is_valid_id: missing dot must be rejected"
# Space / hash / slash -> invalid (would break manifest parse / path).
dce_ext_is_valid_id "esbenp prettier"         && fail "is_valid_id: embedded space must be rejected"
dce_ext_is_valid_id "esbenp.prettier#x"       && fail "is_valid_id: hash must be rejected"
dce_ext_is_valid_id "esbenp/prettier"         && fail "is_valid_id: slash must be rejected"
# Empty / leading dot / leading hyphen -> invalid.
dce_ext_is_valid_id ""                        && fail "is_valid_id: empty must be rejected"
dce_ext_is_valid_id ".nohostpublisher"        && fail "is_valid_id: leading dot rejected"
dce_ext_is_valid_id "-bad.id"                 && fail "is_valid_id: leading hyphen rejected"
pass "is_valid_id: publisher.name format gate"

echo ""
echo "All extensions helper checks passed."
