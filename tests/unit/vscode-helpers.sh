#!/usr/bin/env bash
# =============================================================================
# tests/unit/vscode-helpers.sh - VS Code attached-container config helpers.
#
# Exercises lib/vscode.sh in-process with a fake HOME and no backend: creation
# of a named attach config, jq-based merge of managed fields into an existing
# config, and the no-jq fallback for the common "no remoteEnv yet" case.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/platform.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/vscode.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.config/Code/User"

run_seed() {
  HOME="$FAKE_HOME" dce_vscode_seed_named_attach_config "$@"
}

cfg_path() {
  local name="$1"
  printf '%s/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/%s.json' \
    "$FAKE_HOME" "$(dce_vscode_encode_attach_key "$name")"
}

# =============================================================================
# Section A - missing config: create workspaceFolder + managed remoteEnv
# =============================================================================
cfg_a="$(run_seed myapp /workspace pat)"
[[ -f "$cfg_a" ]] || fail "missing-config: expected attach config to be created"
jq -e '
  .workspaceFolder == "/workspace"
  and .remoteEnv.GIT_CONFIG_COUNT == "2"
  and .remoteEnv.GIT_CONFIG_KEY_0 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_0 == ""
  and .remoteEnv.GIT_CONFIG_KEY_1 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_1 == "store"
' "$cfg_a" >/dev/null || fail "missing-config: created config missing managed remoteEnv"

pass "Section A: create named attach config with managed remoteEnv"

# =============================================================================
# Section B - jq merge: preserve user keys + merge managed remoteEnv
# =============================================================================
cfg_b="$(cfg_path mergeapp)"
mkdir -p "$(dirname "$cfg_b")"
cat > "$cfg_b" <<'EOF'
{
  "workspaceFolder": "/old",
  "extensions": ["ms-python.python"],
  "settings": {
    "editor.formatOnSave": true
  },
  "remoteEnv": {
    "FOO": "bar"
  }
}
EOF

out_b="$(run_seed mergeapp /workspace pat)"
[[ "$out_b" == "$cfg_b" ]] || fail "jq-merge: seed should echo existing config path"
jq -e '
  .workspaceFolder == "/workspace"
  and .extensions == ["ms-python.python"]
  and .settings["editor.formatOnSave"] == true
  and .remoteEnv.FOO == "bar"
  and .remoteEnv.GIT_CONFIG_COUNT == "2"
  and .remoteEnv.GIT_CONFIG_KEY_0 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_0 == ""
  and .remoteEnv.GIT_CONFIG_KEY_1 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_1 == "store"
' "$cfg_b" >/dev/null || fail "jq-merge: existing keys not preserved / managed keys not merged"

pass "Section B: jq merge preserves user keys and adds managed remoteEnv"

# =============================================================================
# Section C - no jq fallback: existing config without remoteEnv is updated
# =============================================================================
cfg_c="$(cfg_path fallbackapp)"
mkdir -p "$(dirname "$cfg_c")"
cat > "$cfg_c" <<'EOF'
{
  "workspaceFolder": "/old",
  "extensions": ["eamodio.gitlens"],
  "settings": {
    "editor.formatOnSave": true
  }
}
EOF

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/jq" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
chmod +x "$STUB_BIN/jq"

out_c="$(PATH="$STUB_BIN:$PATH" run_seed fallbackapp /workspace pat)"
[[ "$out_c" == "$cfg_c" ]] || fail "fallback: seed should echo existing config path"

grep -Fq '"workspaceFolder": "/workspace"' "$cfg_c" \
  || fail "fallback: workspaceFolder not updated"
grep -Fq '"remoteEnv": {' "$cfg_c" \
  || fail "fallback: remoteEnv block not inserted"
grep -Fq '"GIT_CONFIG_COUNT": "2"' "$cfg_c" \
  || fail "fallback: GIT_CONFIG_COUNT missing"
grep -Fq '"GIT_CONFIG_KEY_0": "credential.helper"' "$cfg_c" \
  || fail "fallback: GIT_CONFIG_KEY_0 missing"
grep -Fq '"GIT_CONFIG_VALUE_1": "store"' "$cfg_c" \
  || fail "fallback: GIT_CONFIG_VALUE_1 missing"
grep -Fq '"extensions": ["eamodio.gitlens"]' "$cfg_c" \
  || fail "fallback: existing extensions key not preserved"
grep -Fq '"editor.formatOnSave": true' "$cfg_c" \
  || fail "fallback: existing nested settings not preserved"

pass "Section C: no-jq fallback inserts managed remoteEnv when absent"

# =============================================================================
# Section D - jq merge: non-PAT removes only managed remoteEnv keys
# =============================================================================
cfg_d="$(cfg_path removeapp)"
mkdir -p "$(dirname "$cfg_d")"
cat > "$cfg_d" <<'EOF'
{
  "workspaceFolder": "/old",
  "remoteEnv": {
    "FOO": "bar",
    "GIT_CONFIG_COUNT": "2",
    "GIT_CONFIG_KEY_0": "credential.helper",
    "GIT_CONFIG_VALUE_0": "",
    "GIT_CONFIG_KEY_1": "credential.helper",
    "GIT_CONFIG_VALUE_1": "store"
  }
}
EOF

out_d="$(run_seed removeapp /workspace none)"
[[ "$out_d" == "$cfg_d" ]] || fail "remove-managed: seed should echo existing config path"
jq -e '
  .workspaceFolder == "/workspace"
  and .remoteEnv.FOO == "bar"
  and (.remoteEnv | has("GIT_CONFIG_COUNT") | not)
  and (.remoteEnv | has("GIT_CONFIG_KEY_0") | not)
  and (.remoteEnv | has("GIT_CONFIG_VALUE_0") | not)
  and (.remoteEnv | has("GIT_CONFIG_KEY_1") | not)
  and (.remoteEnv | has("GIT_CONFIG_VALUE_1") | not)
' "$cfg_d" >/dev/null || fail "remove-managed: PAT-only managed remoteEnv keys not removed"

pass "Section D: non-PAT preserves user remoteEnv and removes managed keys"

# =============================================================================
# Section E - no jq fallback: non-PAT removes stale managed keys
# =============================================================================
cfg_e="$(cfg_path removefallback)"
mkdir -p "$(dirname "$cfg_e")"
cat > "$cfg_e" <<'EOF'
{
  "workspaceFolder": "/old",
  "remoteEnv": {
    "FOO": "bar",
    "GIT_CONFIG_COUNT": "2",
    "GIT_CONFIG_KEY_0": "credential.helper",
    "GIT_CONFIG_VALUE_0": "",
    "GIT_CONFIG_KEY_1": "credential.helper",
    "GIT_CONFIG_VALUE_1": "store"
  }
}
EOF

out_e="$(PATH="$STUB_BIN:$PATH" run_seed removefallback /workspace none)"
[[ "$out_e" == "$cfg_e" ]] || fail "removefallback: seed should echo updated config path"
grep -Fq '"workspaceFolder": "/workspace"' "$cfg_e" \
  || fail "removefallback: workspaceFolder not updated"
jq -e '
  .remoteEnv.FOO == "bar"
  and (.remoteEnv | has("GIT_CONFIG_COUNT") | not)
  and (.remoteEnv | has("GIT_CONFIG_KEY_0") | not)
  and (.remoteEnv | has("GIT_CONFIG_VALUE_0") | not)
  and (.remoteEnv | has("GIT_CONFIG_KEY_1") | not)
  and (.remoteEnv | has("GIT_CONFIG_VALUE_1") | not)
' "$cfg_e" >/dev/null || fail "removefallback: stale managed keys not removed without jq"

pass "Section E: no-jq fallback removes stale managed keys for non-PAT"

# =============================================================================
# Section F - no jq + existing remoteEnv under PAT: warn and do NOT pretend the
# file was synced.
# =============================================================================
cfg_f="$(cfg_path warnapp)"
mkdir -p "$(dirname "$cfg_f")"
cat > "$cfg_f" <<'EOF'
{
  "workspaceFolder": "/old",
  "remoteEnv": {
    "FOO": "bar"
  }
}
EOF

: > "$WORK/warn.err"
out_f="$(PATH="$STUB_BIN:$PATH" run_seed warnapp /workspace pat 2>"$WORK/warn.err")"
[[ -z "$out_f" ]] || fail "warnapp: should not echo a success path when PAT remoteEnv could not be merged"
grep -Fq 'remoteEnv' "$WORK/warn.err" \
  || fail "warnapp: missing no-jq remoteEnv merge warning"
grep -Fq '"workspaceFolder": "/old"' "$cfg_f" \
  || fail "warnapp: file should be left untouched on unsupported no-jq PAT merge"

pass "Section F: no-jq PAT remoteEnv merge warns and does not fake success"

# =============================================================================
# Section G - render path escapes unusual workspaceFolder values correctly
# =============================================================================
weird_ws='/workspace/"quoted"\\path'
cfg_g="$(run_seed weirdapp "$weird_ws" none)"
jq -e --arg ws "$weird_ws" '.workspaceFolder == $ws' "$cfg_g" >/dev/null \
  || fail "weirdapp: create path did not JSON-escape workspaceFolder correctly"

pass "Section G: create path JSON-escapes workspaceFolder"

echo ""
echo "All VS Code helper checks passed."
