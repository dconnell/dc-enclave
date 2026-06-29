#!/usr/bin/env bash
# =============================================================================
# tests/unit/editor-helpers.sh - Pure host-side editor launcher helper tests.
#
# Exercises lib/editor.sh in-process with no backend and no stubs: id
# normalization, registry membership, selection precedence, URI/encoding
# helpers, and cross-platform binary discovery (with command -v stubbed via
# PATH manipulation and platform_os overridden via the documented hook).
#
# The stubbed-backend coverage of the editor feature (dce editor against fake
# docker / fake code) lives in tests/contract/editor.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/platform.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/editor.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ===========================================================================
# Section A - id normalization + registry
# ===========================================================================
[[ "$(dce_editor_normalize_id "code")" == "vscode" ]] || fail "normalize code -> vscode"
[[ "$(dce_editor_normalize_id "code-insiders")" == "vscode-insiders" ]] || fail "normalize code-insiders"
[[ "$(dce_editor_normalize_id "vscode")" == "vscode" ]] || fail "normalize idempotent on known id"
[[ "$(dce_editor_normalize_id "acme")" == "acme" ]] || fail "normalize unknown passthrough"

[[ "$(dce_editor_known_ids)" == $'vscode\nvscode-insiders' ]] || fail "known_ids list"
dce_editor_is_known vscode || fail "is_known vscode"
dce_editor_is_known vscode-insiders || fail "is_known vscode-insiders"
if dce_editor_is_known acme 2>/dev/null; then fail "is_known rejects unknown"; fi

[[ "$(dce_editor_default)" == "vscode" ]] || fail "default is vscode"

pass "Section A: id normalization + registry"

# ===========================================================================
# Section B - selection precedence
#
# dce_editor_select reads: $1 (explicit) > $DCE_EDITOR > global DCE_EDITOR >
# $VISUAL > $EDITOR > default. Use a private fake HOME so global-config reads
# are deterministic and isolated from the test runner's real config.
# ===========================================================================
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.config/dce-enclave"
GLOBAL_CFG="$FAKE_HOME/.config/dce-enclave/config"

run_select() {
  HOME="$FAKE_HOME" \
  DCE_EDITOR="${DCE_EDITOR:-}" \
  VISUAL="${VISUAL:-}" \
  EDITOR="${EDITOR:-}" \
  dce_editor_select "${1:-}"
}

# 6. default
[[ "$(run_select)" == "vscode" ]] || fail "precedence: default"

# 5. $EDITOR known
DCE_EDITOR="" VISUAL="" EDITOR="code" \
  out="$(run_select)"; [[ "$out" == "vscode" ]] || fail "precedence: \$EDITOR=code"

# 5b. $EDITOR unknown -> warn+skip, fall to default
out="$(DCE_EDITOR="" VISUAL="" EDITOR="nano" run_select 2>/dev/null)"
[[ "$out" == "vscode" ]] || fail "precedence: unknown \$EDITOR falls through to default"

# 4. $VISUAL wins over $EDITOR
out="$(DCE_EDITOR="" VISUAL="code-insiders" EDITOR="code" run_select)"
[[ "$out" == "vscode-insiders" ]] || fail "precedence: \$VISUAL over \$EDITOR"

# 4b. $VISUAL unknown -> warn+skip, fall to $EDITOR
out="$(DCE_EDITOR="" VISUAL="nano" EDITOR="code" run_select 2>/dev/null)"
[[ "$out" == "vscode" ]] || fail "precedence: unknown \$VISUAL falls through to \$EDITOR"

# 3. global DCE_EDITOR wins over $VISUAL/$EDITOR
printf 'DCE_EDITOR="vscode-insiders"\n' > "$GLOBAL_CFG"
chmod 600 "$GLOBAL_CFG"
out="$(DCE_EDITOR="" VISUAL="code" EDITOR="code" run_select)"
[[ "$out" == "vscode-insiders" ]] || fail "precedence: global DCE_EDITOR over env"

# 3b. global DCE_EDITOR absent -> fall through
rm -f "$GLOBAL_CFG"
out="$(DCE_EDITOR="" VISUAL="code" EDITOR="" run_select)"
[[ "$out" == "vscode" ]] || fail "precedence: no global falls through"

# 2. $DCE_EDITOR env wins over global
printf 'DCE_EDITOR="vscode-insiders"\n' > "$GLOBAL_CFG"
chmod 600 "$GLOBAL_CFG"
out="$(DCE_EDITOR="code" VISUAL="vscode-insiders" EDITOR="vscode-insiders" run_select)"
[[ "$out" == "vscode" ]] || fail "precedence: \$DCE_EDITOR env over global/env"

# 1. explicit --editor wins over everything
out="$(DCE_EDITOR="vscode-insiders" VISUAL="code-insiders" EDITOR="code-insiders" run_select vscode)"
[[ "$out" == "vscode" ]] || fail "precedence: explicit over all"
rm -f "$GLOBAL_CFG"

# 1b. explicit accepts the alias too
[[ "$(run_select code-insiders)" == "vscode-insiders" ]] || fail "precedence: explicit alias normalized"

# Hard-error cases: unknown explicit / $DCE_EDITOR / global DCE_EDITOR.
# Run in a subshell so dce_die's exit doesn't tear down the test runner.
if (run_select acme) 2>/dev/null; then fail "select: unknown --editor must hard error"; fi
if (DCE_EDITOR="acme" run_select) 2>/dev/null; then fail "select: unknown \$DCE_EDITOR must hard error"; fi
printf 'DCE_EDITOR="acme"\n' > "$GLOBAL_CFG"; chmod 600 "$GLOBAL_CFG"
if (DCE_EDITOR="" run_select) 2>/dev/null; then fail "select: unknown global DCE_EDITOR must hard error"; fi
rm -f "$GLOBAL_CFG"

pass "Section B: selection precedence"

# ===========================================================================
# Section C - hex encoder + attach URI
# ===========================================================================
# Hex encoder: ASCII for "/dce-myapp" -> 2f6463652d6d79617070
[[ "$(dce_editor_hex_encode "/dce-myapp")" == "2f6463652d6d79617070" ]] \
  || fail "hex_encode '/dce-myapp' (got $(dce_editor_hex_encode "/dce-myapp"))"
[[ "$(dce_editor_hex_encode "")" == "" ]] || fail "hex_encode empty"
[[ "$(dce_editor_hex_encode "A")" == "41" ]] || fail "hex_encode uppercase -> lowercase"

# Attach URI: vscode-remote://attached-container+<hex>/<workspace>
uri="$(dce_editor_vscode_attached_container_uri "dce-myapp" "/workspace")"
expected="vscode-remote://attached-container+2f6463652d6d79617070/workspace"
[[ "$uri" == "$expected" ]] || fail "attach uri (got $uri)"

# Default workspace
uri="$(dce_editor_vscode_attached_container_uri "proj")"
[[ "$uri" == "vscode-remote://attached-container+2f70726f6a/workspace" ]] \
  || fail "attach uri default workspace (got $uri)"

# Round-trip: the hex in the URI must decode back to "/<container_name>".
hex_decode() {
  local h="$1" i b out=""
  for ((i = 0; i < ${#h}; i += 2)); do
    # %b interprets backslash escapes; the \xHH form is built from the hex pair.
    # shellcheck disable=SC2059
    # pair is constructed from a charset-restricted hex string at the call site.
    b="$(printf '%b' "\\x${h:i:2}")"
    out+="$b"
  done
  printf '%s' "$out"
}
hex_in_uri="${uri#*+}"
hex_in_uri="${hex_in_uri%%/*}"
[[ "$(hex_decode "$hex_in_uri")" == "/proj" ]] \
  || fail "attach uri hex round-trips to '/proj' (got $(hex_decode "$hex_in_uri"))"

pass "Section C: hex encoder + attach URI"

# ===========================================================================
# Section D - binary discovery (cross-platform)
#
# platform_os reads uname -s / /proc/version, so we cannot fake the host OS
# cheaply here. Instead we test the platform-independent contract:
#   - DCE_EDITOR_BIN override wins when executable
#   - DCE_EDITOR_BIN override hard-errors when not executable
#   - PATH-discovered binary is returned for a known editor id
#   - unknown editor id yields no binary (rc=1)
# The per-OS preference (code.exe on WSL2, .app fallback on macOS) is
# exercised by tests/contract/editor.sh via platform-stubbed scenarios.
# ===========================================================================
STUB_BIN_DIR="$WORK/bin"
mkdir -p "$STUB_BIN_DIR"

# Make a fake `code` on PATH.
cat > "$STUB_BIN_DIR/code" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_BIN_DIR/code"

with_stub_path() {
  PATH="$STUB_BIN_DIR:$PATH" "$@"
}

# PATH lookup finds the fake code.
with_stub_path command -v code >/dev/null || fail "stub setup: fake code should be on PATH"
found="$(with_stub_path dce_editor_find_binary vscode)"
[[ "$found" == "$STUB_BIN_DIR/code" ]] || fail "find_binary vscode via PATH (got $found)"

# Unknown editor id yields rc=1.
if with_stub_path dce_editor_find_binary acme 2>/dev/null; then
  fail "find_binary must fail for unknown editor id"
fi

# DCE_EDITOR_BIN override wins when executable.
CUSTOM="$WORK/custom-editor"
cat > "$CUSTOM" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$CUSTOM"
found="$(DCE_EDITOR_BIN="$CUSTOM" with_stub_path dce_editor_find_binary vscode)"
[[ "$found" == "$CUSTOM" ]] || fail "find_binary honors executable DCE_EDITOR_BIN"

# DCE_EDITOR_BIN override hard-errors when not executable.
if (DCE_EDITOR_BIN="$WORK/does-not-exist" with_stub_path dce_editor_find_binary vscode) 2>/dev/null; then
  fail "find_binary must hard-error on non-executable DCE_EDITOR_BIN"
fi

pass "Section D: binary discovery (platform-independent contract)"

echo ""
echo "All editor helper checks passed."
