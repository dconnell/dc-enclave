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
FAKE_STORAGE_DIR=""
# Make this test host-OS agnostic: pick the first platform-native storage
# candidate and make only that root "live" (so run_seed emits a single path).
while IFS= read -r _storage; do
  [[ -z "$_storage" ]] && continue
  FAKE_STORAGE_DIR="$_storage"
  break
done < <(HOME="$FAKE_HOME" dce_vscode_remote_containers_storage_candidates)
[[ -n "$FAKE_STORAGE_DIR" ]] || fail "no VS Code storage candidate for platform"
mkdir -p "$(dirname "$FAKE_STORAGE_DIR")"

run_seed() {
  HOME="$FAKE_HOME" dce_vscode_seed_named_attach_config "$@"
}

cfg_path() {
  local name="$1"
  printf '%s/nameConfigs/%s.json' "$FAKE_STORAGE_DIR" "$(dce_vscode_encode_attach_key "$name")"
}

# =============================================================================
# Section A - missing config: create workspaceFolder + managed remoteEnv
# =============================================================================
cfg_a="$(run_seed myapp /workspace pat)"
[[ -f "$cfg_a" ]] || fail "missing-config: expected attach config to be created"
jq -e '
  .workspaceFolder == "/workspace"
  and .remoteEnv.PS1 == "[myapp] %~ %# "
  and .remoteEnv.GIT_CONFIG_COUNT == "2"
  and .remoteEnv.GIT_CONFIG_KEY_0 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_0 == ""
  and .remoteEnv.GIT_CONFIG_KEY_1 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_1 == "store"
' "$cfg_a" >/dev/null || fail "missing-config: created config missing managed remoteEnv"

pass "Section A: create named attach config with managed remoteEnv"

# =============================================================================
# Section A2 - missing config, non-PAT: create workspaceFolder + PS1-only
# managed remoteEnv (no GIT_CONFIG keys)
# =============================================================================
cfg_a2="$(run_seed soloapp /workspace none)"
[[ -f "$cfg_a2" ]] || fail "missing-config-none: expected attach config to be created"
jq -e '
  .workspaceFolder == "/workspace"
  and .remoteEnv.PS1 == "[soloapp] %~ %# "
  and (.remoteEnv | has("GIT_CONFIG_COUNT") | not)
  and (.remoteEnv | has("GIT_CONFIG_KEY_0") | not)
  and (.remoteEnv | has("GIT_CONFIG_VALUE_0") | not)
  and (.remoteEnv | has("GIT_CONFIG_KEY_1") | not)
  and (.remoteEnv | has("GIT_CONFIG_VALUE_1") | not)
' "$cfg_a2" >/dev/null || fail "missing-config-none: non-PAT create should emit PS1-only remoteEnv"

pass "Section A2: non-PAT create named attach config with PS1-only remoteEnv"

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
  and .remoteEnv.PS1 == "[mergeapp] %~ %# "
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
grep -Fq '"PS1": "[fallbackapp] %~ %# "' "$cfg_c" \
  || fail "fallback: managed PS1 missing"
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
# Section C2 - no jq fallback, non-PAT, config without remoteEnv: the inserted
# block must contain exactly one PS1 entry and stay valid JSON.
# =============================================================================
cfg_c2="$(cfg_path insertonce)"
mkdir -p "$(dirname "$cfg_c2")"
cat > "$cfg_c2" <<'EOF'
{
  "workspaceFolder": "/old",
  "extensions": ["x"]
}
EOF

out_c2="$(PATH="$STUB_BIN:$PATH" run_seed insertonce /workspace none)"
[[ "$out_c2" == "$cfg_c2" ]] || fail "insertonce: seed should echo updated config path"
jq -e . "$cfg_c2" >/dev/null || fail "insertonce: inserted config is not valid JSON"
ps1_c2="$(grep -Fc '"PS1"' "$cfg_c2")"
[[ "$ps1_c2" -eq 1 ]] || fail "insertonce: expected exactly one PS1 line, got $ps1_c2"
jq -e '.remoteEnv.PS1 == "[insertonce] %~ %# "' "$cfg_c2" >/dev/null \
  || fail "insertonce: managed PS1 missing from remoteEnv"

pass "Section C2: no-jq non-PAT insert emits exactly one PS1 entry"

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
  and .remoteEnv.PS1 == "[removeapp] %~ %# "
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
grep -Fq '"PS1": "[removefallback] %~ %# "' "$cfg_e" \
  || fail "removefallback: managed PS1 missing"
grep -Fc '"PS1"' "$cfg_e" | grep -qx 1 \
  || fail "removefallback: expected exactly one PS1 line"
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

# =============================================================================
# Section H - no jq fallback, non-PAT, remoteEnv already containing PS1:
# idempotent - exactly one PS1 line after the run, existing keys preserved.
# =============================================================================
cfg_h="$(cfg_path idemapp)"
mkdir -p "$(dirname "$cfg_h")"
cat > "$cfg_h" <<'EOF'
{
  "workspaceFolder": "/old",
  "remoteEnv": {
    "FOO": "bar",
    "PS1": "[idemapp] %~ %# "
  }
}
EOF

out_h="$(PATH="$STUB_BIN:$PATH" run_seed idemapp /workspace none)"
[[ "$out_h" == "$cfg_h" ]] || fail "idem: seed should echo updated config path"
jq -e '
  .workspaceFolder == "/workspace"
  and .remoteEnv.FOO == "bar"
  and .remoteEnv.PS1 == "[idemapp] %~ %# "
' "$cfg_h" >/dev/null || fail "idem: existing PS1/FOO not preserved or JSON invalid"
ps1_count="$(grep -Fc '"PS1"' "$cfg_h")"
[[ "$ps1_count" -eq 1 ]] || fail "idem: expected exactly one PS1 line, got $ps1_count"

pass "Section H: no-jq non-PAT fallback is idempotent for PS1"

# =============================================================================
# Section I - no jq fallback, non-PAT, remoteEnv written inline on one line:
# the rewrite cannot safely restructure it, so it must bail with a warning and
# leave the file byte-identical.
# =============================================================================
cfg_i="$(cfg_path inlinenv)"
mkdir -p "$(dirname "$cfg_i")"
cat > "$cfg_i" <<'EOF'
{
  "workspaceFolder": "/old",
  "remoteEnv": { "FOO": "bar" },
  "extensions": ["x"]
}
EOF
sha_i_before="$(shasum -a 256 "$cfg_i" | awk '{print $1}')"

: > "$WORK/inline.err"
out_i="$(PATH="$STUB_BIN:$PATH" run_seed inlinenv /workspace none 2>"$WORK/inline.err")"
[[ -z "$out_i" ]] \
  || fail "inline-remoteEnv: should not echo a success path for an inline remoteEnv shape"
sha_i_after="$(shasum -a 256 "$cfg_i" | awk '{print $1}')"
[[ "$sha_i_before" == "$sha_i_after" ]] \
  || fail "inline-remoteEnv: file should be left byte-identical on unsupported shape"
grep -Eq 'jq|merge' "$WORK/inline.err" \
  || fail "inline-remoteEnv: missing warning mentioning jq/merge"

pass "Section I: no-jq non-PAT inline remoteEnv bails untouched with a warning"

# =============================================================================
# Section J - no jq fallback, non-PAT, remoteEnv written as a multi-line block
# that contains a nested object: the rewrite cannot safely restructure it (the
# block-closer regex would match the inner closer and truncate the block), so
# it must bail with a warning and leave the file byte-identical.
# =============================================================================
cfg_j="$(cfg_path nestedenv)"
mkdir -p "$(dirname "$cfg_j")"
cat > "$cfg_j" <<'EOF'
{
  "workspaceFolder": "/old",
  "remoteEnv": {
    "A": {
      "B": "c"
    },
    "FOO": "bar"
  }
}
EOF
sha_j_before="$(shasum -a 256 "$cfg_j" | awk '{print $1}')"

: > "$WORK/nested.err"
out_j="$(PATH="$STUB_BIN:$PATH" run_seed nestedenv /workspace none 2>"$WORK/nested.err")"
[[ -z "$out_j" ]] \
  || fail "nested-remoteEnv: should not echo a success path for a nested remoteEnv shape"
sha_j_after="$(shasum -a 256 "$cfg_j" | awk '{print $1}')"
[[ "$sha_j_before" == "$sha_j_after" ]] \
  || fail "nested-remoteEnv: file should be left byte-identical on unsupported shape"
grep -Eq 'jq|merge' "$WORK/nested.err" \
  || fail "nested-remoteEnv: missing warning mentioning jq/merge"

pass "Section J: no-jq non-PAT nested remoteEnv bails untouched with a warning"

echo ""
echo "All VS Code helper checks passed."
