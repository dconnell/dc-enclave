#!/usr/bin/env bash
# =============================================================================
# tests/unit/devcontainer-helpers.sh - Pure lib/devcontainer.sh API unit tests.
#
# Covers the devcontainer.json drift-detection + sync library API in-process
# with crafted JSON fixtures, no backend and no scripts/*.sh subprocess:
#   - dce_devcontainer_expected_state (canonical comparable form)
#   - dce_devcontainer_recorded_state (parse managed fields from JSON)
#   - dce_devcontainer_detect_drift (in-sync vs each drifted field)
#   - dce_devcontainer_render (full JSON, managed fields present)
#   - dce_devcontainer_sync (jq-required rewrite preserving user fields)
#
# jq policy: detection is jq-optional (grep fallback); sync REQUIRES jq. The
# sync subtests skip-with-reason when jq is absent, and a dedicated subtest
# forces the grep-fallback branch by shadowing jq with a failing stub.
#
# End-to-end behavior of the `dce config sync-vscode` subcommand and the drift
# notices emitted by `dce rebuild-container` / `dce new` (stubbed backend) live
# in tests/contract/devcontainer-sync.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/devcontainer.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# A project whose slug is itself ("myapp" lowercased -> "myapp"). Used so the
# managed hidden-volume source pattern dce-hide-myapp- is easy to assert.
PROJECT="myapp"
SLUG="$(dce_project_slug "$PROJECT")"
[[ "$SLUG" == "myapp" ]] || fail "fixture: expected slug 'myapp', got '$SLUG'"

# A 16-hex hash standing in for a scope-derived dockerfile name.
HASH16="deadbeefdeadbeef"
BASE_DF="$ROOT_DIR/Containerfiles/Containerfile.base"
DERIVED_DF="$ROOT_DIR/Containerfiles/generated/Containerfile.$HASH16"
hidden_vol() { dce_hidden_volume_name "$PROJECT" "$1"; }

# Write a devcontainer.json fixture from a bash variable; returns its path.
# Each call passes a UNIQUE name (callers hold pointers to several fixtures at
# once, so they must not share a path; a counter would not survive the
# command-substitution subshell write_dc runs in).
write_dc() {
  local name="$1" content="$2"
  local file="$WORK/devcontainer.${name}.json"
  printf '%s\n' "$content" > "$file"
  printf '%s' "$file"
}

# Capture a function's stdout to a sorted, newline-joined string for set
# comparison (order-independent). Trailing/blank lines dropped.
sorted_out() {
  local out="$1"
  printf '%s\n' "$out" | grep -v '^$' | LC_ALL=C sort | tr '\n' '|'
}

# =============================================================================
# A. dce_devcontainer_expected_state: canonical comparable form from inputs
# =============================================================================
EXP="$(dce_devcontainer_expected_state "$PROJECT" "$DERIVED_DF" \
  "node_modules,.cache" "mynet:10.0.0.5,obs" "3000:3000,8080")"

# scopes -> derived:<hash> (basename Containerfile.<16hex>).
printf '%s\n' "$EXP" | grep -Fxq $'scopes\tderived:deadbeefdeadbeef' \
  || fail "expected_state: scopes token (got:$(printf '%s\n' "$EXP" | grep ^scopes))"

# hidden -> one line per hidden path (the managed mount TARGET path).
for hp in node_modules .cache; do
  printf '%s\n' "$EXP" | grep -Fxq $'hidden\t'"$hp" \
    || fail "expected_state: missing hidden '$hp'"
done
# networks -> name[:ip], one per entry, primary ip preserved.
printf '%s\n' "$EXP" | grep -Fxq $'networks\tmynet:10.0.0.5' \
  || fail "expected_state: networks primary ip"
printf '%s\n' "$EXP" | grep -Fxq $'networks\tobs' \
  || fail "expected_state: networks extra"
# ports -> container port (after ':' or the bare port).
printf '%s\n' "$EXP" | grep -Fxq $'ports\t3000' || fail "expected_state: port 3000"
printf '%s\n' "$EXP" | grep -Fxq $'ports\t8080' || fail "expected_state: port 8080"

# base project (no scopes) -> scopes=base; empty build_dockerfile -> scopes OMITTED.
EXP_BASE="$(dce_devcontainer_expected_state "$PROJECT" "$BASE_DF" "" "" "")"
printf '%s\n' "$EXP_BASE" | grep -Fxq $'scopes\tbase' || fail "expected_state: base scopes"
EXP_NODF="$(dce_devcontainer_expected_state "$PROJECT" "" "" "mynet" "")"
! printf '%s\n' "$EXP_NODF" | grep -q '^scopes' \
  || fail "expected_state: empty build_dockerfile must omit scopes line"
printf '%s\n' "$EXP_NODF" | grep -Fxq $'networks\tmynet' \
  || fail "expected_state: networks still emitted when build_dockerfile empty"

pass "dce_devcontainer_expected_state: canonical scopes/hidden/networks/ports"

# =============================================================================
# B. dce_devcontainer_recorded_state: parse managed fields out of a JSON file
# (user-added mounts/keys are ignored for the managed subset)
# =============================================================================
DC_FILE="$(write_dc dcfile "{
  \"name\": \"dce-$PROJECT\",
  \"build\": { \"dockerfile\": \"$DERIVED_DF\", \"context\": \"$ROOT_DIR\" },
  \"workspaceFolder\": \"/workspace\",
  \"remoteUser\": \"dev\",
  \"forwardPorts\": [3000, 8080],
  \"mounts\": [
    \"source=$WORK/sec/.npmrc,target=/home/dev/.npmrc,type=bind,readonly\",
    \"source=$(hidden_vol node_modules),target=/workspace/node_modules,type=volume\",
    \"source=/host/.cache,target=/workspace/.cache,type=bind\"
  ],
  \"runArgs\": [\"--network\", \"mynet\", \"--ip\", \"10.0.0.5\", \"--network\", \"obs\"],
  \"containerEnv\": { \"TZ\": \"America/New_York\", \"FOO\": \"bar\" },
  \"extensions\": [\"ms-python.python\"]
}")"

REC="$(dce_devcontainer_recorded_state "$PROJECT" "$DC_FILE")"
printf '%s\n' "$REC" | grep -Fxq $'scopes\tderived:deadbeefdeadbeef' \
  || fail "recorded_state: scopes"
printf '%s\n' "$REC" | grep -Fxq $'hidden\tnode_modules' \
  || fail "recorded_state: managed hidden path extracted from target"
# The user bind mount (/host/.cache) and the npmrc bind must NOT appear as hidden.
! printf '%s\n' "$REC" | grep -Fxq $'hidden\t.cache' \
  || fail "recorded_state: user bind mount must not count as managed hidden"
printf '%s\n' "$REC" | grep -Fxq $'networks\tmynet:10.0.0.5' || fail "recorded_state: networks primary"
printf '%s\n' "$REC" | grep -Fxq $'networks\tobs' || fail "recorded_state: networks extra"
printf '%s\n' "$REC" | grep -Fxq $'ports\t3000' || fail "recorded_state: port 3000"
printf '%s\n' "$REC" | grep -Fxq $'ports\t8080' || fail "recorded_state: port 8080"

pass "dce_devcontainer_recorded_state: parses managed fields, ignores user mounts/keys"

# =============================================================================
# C. dce_devcontainer_detect_drift: in-sync vs each drifted field
# =============================================================================

# (C0) fully in sync -> exit 0, NO stderr output.
DC_SYNCED="$DC_FILE"
ERR="$(dce_devcontainer_detect_drift "$PROJECT" "$DC_SYNCED" "$DERIVED_DF" \
  "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" 2>&1 >/dev/null)" || true
[[ -z "$ERR" ]] || fail "detect_drift: in-sync must print nothing (got: $ERR)"
if dce_devcontainer_detect_drift "$PROJECT" "$DC_SYNCED" "$DERIVED_DF" \
    "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" >/dev/null 2>&1; then
  :
else
  fail "detect_drift: in-sync must return 0"
fi
pass "detect_drift: in-sync returns 0, silent"

# Helper: run detect_drift capturing combined output; fail unless it returns
# non-zero (drift). Echoes the combined output for needle assertions.
drift_has() {
  local dc="$1"; shift            # rest are detect args
  local out rc
  out="$(dce_devcontainer_detect_drift "$PROJECT" "$dc" "$@" 2>&1 >/dev/null)" && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || { fail "detect_drift: expected non-zero (drift) but got 0; out=$out"; }
  printf '%s' "$out"
}

# (C1) scopes drifted (different derived hash) -> mentions scopes + pointer.
DC_SCOPES="$(write_dc scopes "{
  \"build\": { \"dockerfile\": \"$ROOT_DIR/Containerfiles/generated/Containerfile.aaaaaaaaaaaaaaaa\" },
  \"mounts\": [\"source=$(hidden_vol node_modules),target=/workspace/node_modules,type=volume\"],
  \"runArgs\": [\"--network\", \"mynet\", \"--ip\", \"10.0.0.5\", \"--network\", \"obs\"],
  \"forwardPorts\": [3000, 8080]
}")"
OUT="$(dce_devcontainer_detect_drift "$PROJECT" "$DC_SCOPES" "$DERIVED_DF" \
  "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" 2>&1 >/dev/null)" || true
grep -Fqi 'scopes' <<<"$OUT" || fail "detect_drift(scopes): notice must mention scopes"
grep -Fqi 'sync-vscode' <<<"$OUT" || fail "detect_drift(scopes): must point at sync-vscode"

# (C2) hidden paths drifted (expected adds .cache) -> mentions hidden.
OUT="$(dce_devcontainer_detect_drift "$PROJECT" "$DC_SYNCED" "$DERIVED_DF" \
  "node_modules,.cache" "mynet:10.0.0.5,obs" "3000:3000,8080" 2>&1 >/dev/null)" || true
grep -Eqi 'hidden|hide' <<<"$OUT" || fail "detect_drift(hidden): notice must mention hidden"

# (C3) networks drifted (expected drops obs) -> mentions networks.
OUT="$(dce_devcontainer_detect_drift "$PROJECT" "$DC_SYNCED" "$DERIVED_DF" \
  "node_modules" "mynet:10.0.0.5" "3000:3000,8080" 2>&1 >/dev/null)" || true
grep -Eqi 'network' <<<"$OUT" || fail "detect_drift(networks): notice must mention networks"

# (C4) ports drifted (expected adds 9000) -> mentions ports.
OUT="$(dce_devcontainer_detect_drift "$PROJECT" "$DC_SYNCED" "$DERIVED_DF" \
  "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080,9000" 2>&1 >/dev/null)" || true
grep -Eqi 'port' <<<"$OUT" || fail "detect_drift(ports): notice must mention ports"

# (C5) user-only edit (add extensions, change nothing managed) -> NO drift.
DC_USEREDIT="$(write_dc useredit "{
  \"build\": { \"dockerfile\": \"$DERIVED_DF\" },
  \"mounts\": [\"source=$(hidden_vol node_modules),target=/workspace/node_modules,type=volume\"],
  \"runArgs\": [\"--network\", \"mynet\", \"--ip\", \"10.0.0.5\", \"--network\", \"obs\"],
  \"forwardPorts\": [3000, 8080],
  \"extensions\": [\"ms-python.python\"],
  \"settings\": { \"editor.formatOnSave\": true }
}")"
if dce_devcontainer_detect_drift "$PROJECT" "$DC_USEREDIT" "$DERIVED_DF" \
    "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" >/dev/null 2>&1; then
  :
else
  fail "detect_drift: non-managed user edit must NOT count as drift"
fi
pass "detect_drift: per-field drift detected; user-only edits ignored"

# (C6) grep fallback: shadow jq with a failing stub so detection must use grep.
if [[ ${DC_SKIP_JQ_SHADOW:-0} -ne 1 ]]; then
  STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
  printf '#!/usr/bin/env bash\nexit 127\n' > "$STUB_BIN/jq"
  chmod +x "$STUB_BIN/jq"
  OUT="$(PATH="$STUB_BIN:$PATH" dce_devcontainer_detect_drift "$PROJECT" "$DC_SCOPES" \
    "$DERIVED_DF" "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" 2>&1 >/dev/null)" || true
  if PATH="$STUB_BIN:$PATH" dce_devcontainer_detect_drift "$PROJECT" "$DC_SCOPES" \
      "$DERIVED_DF" "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" >/dev/null 2>&1; then
    fail "detect_drift: grep fallback must still detect scopes drift (jq shadowed)"
  fi
  grep -Fqi 'scopes' <<<"$OUT" \
    || fail "detect_drift: grep fallback must mention scopes (got: $OUT)"
  pass "detect_drift: jq-optional (grep fallback works when jq is broken/absent)"
else
  pass "detect_drift: grep fallback (skipped via DC_SKIP_JQ_SHADOW)"
fi

# =============================================================================
# D. dce_devcontainer_render: full JSON, valid + managed fields present
# (byte-equivalence vs the shipped `dce new` output is additionally pinned by
#  tests/new-container-lifecycle.sh, which greps the file dce new writes.)
# =============================================================================
if command -v jq >/dev/null 2>&1; then
  RENDERED="$(dce_devcontainer_render "$PROJECT" "$DERIVED_DF" "$ROOT_DIR" "$WORK/sec" \
    "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" "America/New_York" "pat")"
  printf '%s' "$RENDERED" | jq -e '.name=="dce-myapp" and .build.dockerfile=="'"$DERIVED_DF"'" and .build.context=="'"$ROOT_DIR"'" and .workspaceFolder=="/workspace" and .remoteUser=="dev" and .postCreateCommand=="true"' >/dev/null \
    || fail "render: core fields wrong/invalid JSON"
  printf '%s' "$RENDERED" | jq -e '.forwardPorts==[3000,8080]' >/dev/null || fail "render: forwardPorts"
  printf '%s' "$RENDERED" | jq -e '.runArgs==["--network","mynet","--ip","10.0.0.5","--network","obs"]' >/dev/null \
    || fail "render: runArgs ordering"
  printf '%s' "$RENDERED" | jq -e '.containerEnv.TZ=="America/New_York"' >/dev/null || fail "render: containerEnv.TZ"
  printf '%s' "$RENDERED" | jq -e '[.mounts[] | capture("source=(?<s>[^,]+)").s] | index("'"$(hidden_vol node_modules)"'") != null' >/dev/null \
    || fail "render: managed hidden mount missing"
  printf '%s' "$RENDERED" | jq -e '[.mounts[] | capture("source=(?<s>[^,]+)").s] | index("'"$WORK"'/sec/.npmrc") != null' >/dev/null \
    || fail "render: managed npmrc mount missing"
  # PAT auth: VS Code must defer git ops to git's credential helper so the PAT
  # in ~/.git-credentials is used instead of the GitHub extension's OAuth.
  printf '%s' "$RENDERED" | jq -e '.customizations.vscode.settings["github.gitAuthentication"] == false' >/dev/null \
    || fail "render (pat): github.gitAuthentication must be false"
  pass "dce_devcontainer_render: valid JSON with all managed fields (pat auth)"

  # With non-PAT auth (ssh or none), the setting must NOT be emitted so VS Code
  # falls back to its default (GitHub extension OAuth prompt) -- the only way to
  # authenticate when no dce-managed PAT is available.
  RENDERED_SSH="$(dce_devcontainer_render "$PROJECT" "$DERIVED_DF" "$ROOT_DIR" "$WORK/sec" \
    "node_modules" "mynet" "3000" "" "ssh")"
  printf '%s' "$RENDERED_SSH" | jq -e '.customizations.vscode.settings["github.gitAuthentication"] == null' >/dev/null \
    || fail "render (ssh): github.gitAuthentication must be absent"
  RENDERED_NONE="$(dce_devcontainer_render "$PROJECT" "$DERIVED_DF" "$ROOT_DIR" "$WORK/sec" \
    "" "" "" "" "none")"
  printf '%s' "$RENDERED_NONE" | jq -e '.customizations.vscode.settings["github.gitAuthentication"] == null' >/dev/null \
    || fail "render (none): github.gitAuthentication must be absent"
  pass "dce_devcontainer_render: no git auth setting for ssh/none (VS Code default preserved)"
else
  pass "dce_devcontainer_render (skipped — jq not installed)"
fi

# =============================================================================
# E. dce_devcontainer_sync: jq-required rewrite preserving user fields
# =============================================================================
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: dce_devcontainer_sync subtests require jq (not installed)"
  pass "dce_devcontainer_sync (skipped — jq not installed)"
else
  SECRET="$WORK/sec"; mkdir -p "$SECRET"

  # Starting JSON: stale managed fields + USER fields that must survive
  # (an extension list, a user bind mount, and a user containerEnv key).
  DC_SYNC_TARGET="$(write_dc synctarget "{
    \"name\": \"stale-name\",
    \"build\": { \"dockerfile\": \"$ROOT_DIR/Containerfiles/generated/Containerfile.0000000000000000\", \"context\": \"/old\" },
    \"workspaceFolder\": \"/old\",
    \"forwardPorts\": [1111],
    \"mounts\": [
      \"source=/old/npmrc,target=/home/dev/.npmrc,type=bind,readonly\",
      \"source=$(hidden_vol node_modules),target=/workspace/node_modules,type=volume\",
      \"source=/host/.user-cache,target=/workspace/.user-cache,type=bind\"
    ],
    \"runArgs\": [\"--network\", \"oldnet\"],
    \"containerEnv\": { \"TZ\": \"UTC\", \"USERKEY\": \"keepme\" },
    \"extensions\": [\"ms-python.python\"],
    \"settings\": { \"editor\": { \"formatOnSave\": true } },
    \"customizations\": {
      \"vscode\": {
        \"extensions\": [\"github.copilot\"],
        \"settings\": { \"files.autoSave\": \"onFocusChange\" }
      }
    }
  }")"
  chmod 600 "$DC_SYNC_TARGET"

  dce_devcontainer_sync "$PROJECT" "$DC_SYNC_TARGET" "$DERIVED_DF" "$ROOT_DIR" "$SECRET" \
    "node_modules,.cache" "mynet:10.0.0.5,obs" "3000:3000,8080" "America/New_York" "false" "pat" \
    >"$WORK/sync.out" 2>"$WORK/sync.err" || fail "sync exited non-zero ($(cat "$WORK/sync.err"))"

  AFTER="$(cat "$DC_SYNC_TARGET")"
  # managed fields updated.
  echo "$AFTER" | jq -e '.name=="dce-myapp"' >/dev/null || fail "sync: name not updated"
  echo "$AFTER" | jq -e '.build.dockerfile=="'"$DERIVED_DF"'" and .build.context=="'"$ROOT_DIR"'"' >/dev/null \
    || fail "sync: build not updated"
  echo "$AFTER" | jq -e '.forwardPorts==[3000,8080]' >/dev/null || fail "sync: forwardPorts not replaced"
  echo "$AFTER" | jq -e '.runArgs==["--network","mynet","--ip","10.0.0.5","--network","obs"]' >/dev/null \
    || fail "sync: runArgs not replaced"
  echo "$AFTER" | jq -e '.containerEnv.TZ=="America/New_York"' >/dev/null || fail "sync: TZ not refreshed"
  # user fields preserved.
  echo "$AFTER" | jq -e '.extensions==["ms-python.python"]' >/dev/null || fail "sync: user extensions lost"
  echo "$AFTER" | jq -e '.settings.editor.formatOnSave==true' >/dev/null || fail "sync: user settings lost"
  echo "$AFTER" | jq -e '.containerEnv.USERKEY=="keepme"' >/dev/null || fail "sync: user containerEnv key lost"
  # managed VS Code setting injected so VS Code git ops defer to git's
  # credential helper (PAT-backed ~/.git-credentials) instead of the GitHub
  # extension's OAuth prompt.
  echo "$AFTER" | jq -e '.customizations.vscode.settings["github.gitAuthentication"] == false' >/dev/null \
    || fail "sync: github.gitAuthentication not set to false"
  # user VS Code customizations preserved alongside the managed setting.
  echo "$AFTER" | jq -e '.customizations.vscode.settings["files.autoSave"] == "onFocusChange"' >/dev/null \
    || fail "sync: user vscode settings lost"
  echo "$AFTER" | jq -e '.customizations.vscode.extensions == ["github.copilot"]' >/dev/null \
    || fail "sync: user vscode extensions lost"
  # mounts merged: stale npmrc + stale single hidden vol dropped; new managed
  # (npmrc + node_modules + .cache) added; user bind mount preserved.
  echo "$AFTER" | jq -e '[.mounts[] | capture("source=(?<s>[^,]+)").s] | index("'"$SECRET"'/.npmrc") != null' >/dev/null \
    || fail "sync: new managed npmrc mount missing"
  echo "$AFTER" | jq -e '[.mounts[] | capture("source=(?<s>[^,]+)").s] | index("'"$(hidden_vol .cache)"'") != null' >/dev/null \
    || fail "sync: new managed hidden (.cache) mount missing"
  echo "$AFTER" | jq -e '[.mounts[] | capture("source=(?<s>[^,]+)").s] | index("/host/.user-cache") != null' >/dev/null \
    || fail "sync: user bind mount dropped"
  echo "$AFTER" | jq -e '[.mounts[] | capture("source=(?<s>[^,]+)").s] | index("/old/npmrc") == null' >/dev/null \
    || fail "sync: stale npmrc mount not dropped"
  # file mode preserved at 600.
  _mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
  [[ "$(_mode "$DC_SYNC_TARGET")" == "600" ]] || fail "sync: file mode not preserved (got $(_mode "$DC_SYNC_TARGET"))"
  # post-sync: detection reports in sync.
  dce_devcontainer_detect_drift "$PROJECT" "$DC_SYNC_TARGET" "$DERIVED_DF" \
    "node_modules,.cache" "mynet:10.0.0.5,obs" "3000:3000,8080" >/dev/null 2>&1 \
    || fail "sync: post-sync detection still reports drift"
  pass "dce_devcontainer_sync: rewrites managed fields, preserves user fields, keeps mode 600"

  # Non-PAT auth (ssh/none): the managed setting must be REMOVED so VS Code
  # falls back to its default (GitHub extension OAuth). Starting fixture has
  # the setting present (stale from a previous PAT-configured sync).
  DC_NOPAT="$(write_dc nopat "{
    \"name\": \"dce-$PROJECT\",
    \"customizations\": {
      \"vscode\": {
        \"extensions\": [\"github.copilot\"],
        \"settings\": { \"github.gitAuthentication\": false, \"files.autoSave\": \"afterDelay\" }
      }
    }
  }")"
  dce_devcontainer_sync "$PROJECT" "$DC_NOPAT" "$DERIVED_DF" "$ROOT_DIR" "$SECRET" \
    "node_modules" "mynet" "3000" "" "false" "ssh" \
    >"$WORK/nopat.out" 2>"$WORK/nopat.err" || fail "sync (ssh) exited non-zero ($(cat "$WORK/nopat.err"))"
  NOPAT_AFTER="$(cat "$DC_NOPAT")"
  echo "$NOPAT_AFTER" | jq -e '.customizations.vscode.settings["github.gitAuthentication"] == null' >/dev/null \
    || fail "sync (ssh): github.gitAuthentication must be removed"
  echo "$NOPAT_AFTER" | jq -e '.customizations.vscode.settings["files.autoSave"] == "afterDelay"' >/dev/null \
    || fail "sync (ssh): user vscode settings must survive the managed-key removal"
  echo "$NOPAT_AFTER" | jq -e '.customizations.vscode.extensions == ["github.copilot"]' >/dev/null \
    || fail "sync (ssh): user vscode extensions lost"
  pass "dce_devcontainer_sync (ssh): removes managed git-auth setting, preserves user customizations"

  # --dry-run writes nothing.
  DC_DRY="$(write_dc dry "{ \"forwardPorts\": [1111] }")"
  SHA_BEFORE="$(dce_sha256_file "$DC_DRY")"
  dce_devcontainer_sync "$PROJECT" "$DC_DRY" "$DERIVED_DF" "$ROOT_DIR" "$SECRET" \
    "node_modules" "mynet" "3000" "" "true" "pat" >"$WORK/dry.out" 2>&1 || fail "sync --dry-run exited non-zero"
  [[ "$(dce_sha256_file "$DC_DRY")" == "$SHA_BEFORE" ]] \
    || fail "sync --dry-run must not modify the file"
  pass "dce_devcontainer_sync: --dry-run leaves the file untouched"
fi

echo ""
echo "All devcontainer helper checks passed."
