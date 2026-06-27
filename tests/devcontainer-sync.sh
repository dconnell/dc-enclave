#!/usr/bin/env bash
# =============================================================================
# tests/devcontainer-sync.sh - devcontainer.json drift detection + on-demand
# sync (`dce config sync-vscode`).
#
# Covers the lib/devcontainer.sh API (expected/recorded canonical state,
# detect_drift, render, sync) at the unit level with crafted JSON fixtures,
# plus end-to-end behavior of the `dce config sync-vscode` subcommand and drift
# notices emitted by both `dce rebuild-container` and `dce new` (pre-existing
# devcontainer.json branch). No real backend is contacted: rebuild/new use the
# same stubbed-CLI harness style as tests/new-container-lifecycle.sh.
#
# jq policy: detection is jq-optional (grep fallback); sync REQUIRES jq. The
# sync subtests skip-with-reason when jq is absent, and dedicated subtests
# force both branches in jq-present environments:
#   - grep fallback for detection by shadowing jq with a failing stub;
#   - hard missing-jq rejection for sync-vscode by masking `command -v jq`.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    "node_modules" "mynet:10.0.0.5,obs" "3000:3000,8080" "America/New_York")"
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
  pass "dce_devcontainer_render: valid JSON with all managed fields"
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
    \"settings\": { \"editor\": { \"formatOnSave\": true } }
  }")"
  chmod 600 "$DC_SYNC_TARGET"

  dce_devcontainer_sync "$PROJECT" "$DC_SYNC_TARGET" "$DERIVED_DF" "$ROOT_DIR" "$SECRET" \
    "node_modules,.cache" "mynet:10.0.0.5,obs" "3000:3000,8080" "America/New_York" "false" \
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

  # --dry-run writes nothing.
  DC_DRY="$(write_dc dry "{ \"forwardPorts\": [1111] }")"
  SHA_BEFORE="$(dce_sha256_file "$DC_DRY")"
  dce_devcontainer_sync "$PROJECT" "$DC_DRY" "$DERIVED_DF" "$ROOT_DIR" "$SECRET" \
    "node_modules" "mynet" "3000" "" "true" >"$WORK/dry.out" 2>&1 || fail "sync --dry-run exited non-zero"
  [[ "$(dce_sha256_file "$DC_DRY")" == "$SHA_BEFORE" ]] \
    || fail "sync --dry-run must not modify the file"
  pass "dce_devcontainer_sync: --dry-run leaves the file untouched"
fi

# =============================================================================
# F. `dce config sync-vscode` end-to-end (file-only; no backend needed)
# =============================================================================
export HOME_F="$WORK/home"
HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

PROJ2="cfgproj"
SECRET2="$DC_ROOT/$PROJ2"
REPOS2="$WORK/home/repos/$PROJ2"
mkdir -p "$SECRET2" "$REPOS2/.devcontainer"
chmod 700 "$SECRET2"
# base project config (docker backend, no scopes -> dockerfile = Containerfile.base).
{
  echo "CONTAINER_PROJECT=\"$PROJ2\""
  echo "CONTAINER_BACKEND=\"docker\""
  echo "CONTAINER_IMAGE=\"dce-base:latest\""
  echo "CONTAINER_OVERLAY_SCOPES=\"\""
  echo "REPOS_DIR=\"$REPOS2\""
  echo "SECRET_DIR=\"$SECRET2\""
  echo "PORTS=(3000:3000)"
  echo "CONTAINER_HIDDEN_PATHS=(node_modules)"
  echo "CONTAINER_NETWORKS=()"
} > "$SECRET2/config"
chmod 600 "$SECRET2/config"

DC2="$REPOS2/.devcontainer/devcontainer.json"
printf '{\n  "forwardPorts": [1111],\n  "extensions": ["x"]\n}\n' > "$DC2"
chmod 600 "$DC2"

run_config() {
  HOME="$WORK/home" bash "$ROOT_DIR/scripts/config.sh" "$@"
}

if ! command -v jq >/dev/null 2>&1; then
  # Native no-jq environment: sync-vscode must fail with a clear dependency
  # message (this branch is real in minimal host installs).
  if run_config sync-vscode "$PROJ2" >/dev/null 2>"$WORK/nojq-native.err"; then
    fail "config sync-vscode: missing jq must be rejected when jq is absent"
  fi
  grep -Fqi 'requires jq' "$WORK/nojq-native.err" \
    || fail "config sync-vscode: missing-jq error must mention jq"
  grep -Fqi 'optional everywhere else' "$WORK/nojq-native.err" \
    || fail "config sync-vscode: missing-jq error should mention optional-everywhere-else policy"
  pass "dce config sync-vscode: missing-jq guard (native no-jq env)"
else
  # (F1) sync-vscode updates managed fields + preserves user extensions.
  run_config sync-vscode "$PROJ2" >"$WORK/c.out" 2>"$WORK/c.err" \
    || fail "config sync-vscode exited non-zero ($(cat "$WORK/c.err"))"
  RDC="$(cat "$DC2")"
  echo "$RDC" | jq -e '.forwardPorts==[3000]' >/dev/null || fail "config sync-vscode: forwardPorts not synced"
  echo "$RDC" | jq -e '[.mounts[]|capture("source=(?<s>[^,]+)").s]|index("'"$(dce_hidden_volume_name "$PROJ2" node_modules)"'")!=null' >/dev/null \
    || fail "config sync-vscode: hidden mount not synced"
  echo "$RDC" | jq -e '.extensions==["x"]' >/dev/null || fail "config sync-vscode: user extensions lost"

  # (F2) --dry-run writes nothing.
  printf '{ "forwardPorts": [1111] }\n' > "$DC2"
  before="$(dce_sha256_file "$DC2")"
  run_config sync-vscode "$PROJ2" --dry-run >/dev/null 2>&1 \
    || fail "config sync-vscode --dry-run exited non-zero"
  [[ "$(dce_sha256_file "$DC2")" == "$before" ]] \
    || fail "config sync-vscode --dry-run modified the file"

  # (F3) missing jq is rejected (forced branch even when jq is installed).
  NOJQ_ENV="$WORK/nojq.bashenv"
  cat > "$NOJQ_ENV" <<'NOJQ'
command() {
  if [[ "$1" == "-v" && "${2:-}" == "jq" ]]; then
    return 1
  fi
  builtin command "$@"
}
NOJQ
  if HOME="$WORK/home" BASH_ENV="$NOJQ_ENV" bash "$ROOT_DIR/scripts/config.sh" \
      sync-vscode "$PROJ2" >/dev/null 2>"$WORK/nojq.err"; then
    fail "config sync-vscode: missing jq must be rejected"
  fi
  grep -Fqi 'requires jq' "$WORK/nojq.err" \
    || fail "config sync-vscode: missing-jq error must mention jq"
  grep -Fqi 'optional everywhere else' "$WORK/nojq.err" \
    || fail "config sync-vscode: missing-jq error should mention optional-everywhere-else policy"

  # (F4) apple backend is rejected.
  dce_set_config_key "$SECRET2/config" CONTAINER_BACKEND "apple"
  if run_config sync-vscode "$PROJ2" >/dev/null 2>"$WORK/apple.err"; then
    fail "config sync-vscode: apple backend must be rejected"
  fi
  grep -Fqi 'docker-compatible' "$WORK/apple.err" \
    || fail "config sync-vscode: apple rejection message must mention docker-compatible"
  dce_set_config_key "$SECRET2/config" CONTAINER_BACKEND "docker"

  # (F5) malformed JSON is rejected without mutating the input file.
  printf '{ "forwardPorts": [1111 }\n' > "$DC2"
  bad_before="$(dce_sha256_file "$DC2")"
  if run_config sync-vscode "$PROJ2" >/dev/null 2>"$WORK/badjson.err"; then
    fail "config sync-vscode: malformed devcontainer.json must error"
  fi
  grep -Fqi 'valid JSON' "$WORK/badjson.err" \
    || fail "config sync-vscode: malformed-json error should mention valid JSON"
  [[ "$(dce_sha256_file "$DC2")" == "$bad_before" ]] \
    || fail "config sync-vscode: malformed JSON input must remain unchanged"

  # (F6) missing devcontainer.json is rejected with guidance.
  rm -f "$DC2"
  if run_config sync-vscode "$PROJ2" >/dev/null 2>"$WORK/miss.err"; then
    fail "config sync-vscode: missing devcontainer.json must error"
  fi
  grep -Fqi 'devcontainer.json' "$WORK/miss.err" \
    || fail "config sync-vscode: missing-file error must mention devcontainer.json"

  pass "dce config sync-vscode: sync/dry-run/nojq/apple-guard/malformed-json/missing-file"
fi

# =============================================================================
# G. `dce rebuild-container` prints the drift notice after a config change
# (stubbed backend; mirrors tests/new-container-lifecycle.sh harness)
# =============================================================================
STUB_DIR="$WORK/sbin"
mkdir -p "$STUB_DIR"
RLOG="$WORK/r.log"
RIMAGES="$WORK/r.images"
: > "$RLOG"
printf 'dce-base:latest\n' > "$RIMAGES"
cat > "$STUB_DIR/_cli" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_imgs="${DC_STUB_IMAGES:-}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"
if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then [[ -f "$_imgs" ]] && cat "$_imgs"; exit 0; fi
if [[ "${1:-}" == "images" ]]; then [[ -f "$_imgs" ]] && cat "$_imgs"; exit 0; fi
case "$me" in
  docker) if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then printf 'colima\n'; fi ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_cli"
cp "$STUB_DIR/_cli" "$STUB_DIR/docker"

ORIG_PATH="$PATH"
run_dce() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" \
  TZ="America/New_York" \
  DC_STUB_LOG="$RLOG" DC_STUB_IMAGES="$RIMAGES" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND=docker \
  bash "$@"
}

# Fresh project with NO ports; devcontainer.json is created with forwardPorts [].
RB_PROJ="rbproj"
: > "$RLOG"
run_dce "$ROOT_DIR/scripts/new-container.sh" "$RB_PROJ" \
  >"$WORK/n.out" 2>"$WORK/n.err" || fail "new (rbproj) exited non-zero ($(cat "$WORK/n.err"))"
RB_DC="$WORK/home/repos/$RB_PROJ/.devcontainer/devcontainer.json"
[[ -f "$RB_DC" ]] || fail "new (rbproj): devcontainer.json not created"

# Mutate ports via `dce config set` (the canonical drift trigger).
run_dce "$ROOT_DIR/scripts/config.sh" set "$RB_PROJ" ports=4000:4000 >/dev/null 2>&1 \
  || fail "config set ports exited non-zero"

# Add the dce-base image presence is already satisfied; rebuild must succeed and
# emit the drift notice on stderr (ports differ: file has none, config has 4000).
: > "$RLOG"
run_dce "$ROOT_DIR/scripts/rebuild-container.sh" "$RB_PROJ" --yes \
  </dev/null >"$WORK/rb.out" 2>"$WORK/rb.err" || fail "rebuild exited non-zero ($(cat "$WORK/rb.err"))"
grep -Fqi 'drift' "$WORK/rb.err" || fail "rebuild: drift notice missing from stderr"
grep -Eqi 'port' "$WORK/rb.err" || fail "rebuild: drift notice must mention ports"
pass "dce rebuild-container: emits drift notice (ports) after config change, exit 0"

# =============================================================================
# H. `dce new` pre-existing devcontainer.json: preserve file + emit drift notice
# =============================================================================
PRE_PROJ="preexistproj"
PRE_REPO="$WORK/home/repos/$PRE_PROJ"
PRE_DC="$PRE_REPO/.devcontainer/devcontainer.json"
mkdir -p "$PRE_REPO/.devcontainer"
cat > "$PRE_DC" <<EOF
{
  "name": "dce-$PRE_PROJ",
  "build": { "dockerfile": "$ROOT_DIR/Containerfiles/Containerfile.base", "context": "$ROOT_DIR" },
  "workspaceFolder": "/workspace",
  "remoteUser": "dev",
  "forwardPorts": [1111]
}
EOF
pre_sha="$(dce_sha256_file "$PRE_DC")"

: > "$RLOG"
run_dce "$ROOT_DIR/scripts/new-container.sh" "$PRE_PROJ" 3000:3000 \
  >"$WORK/pre.stdout" 2>"$WORK/pre.stderr" \
  || fail "new (pre-existing devcontainer) exited non-zero ($(cat "$WORK/pre.stderr"))"
grep -Fq 'already exists - not overwritten' "$WORK/pre.stdout" \
  || fail "new: pre-existing devcontainer notice missing"
grep -Fqi 'sync-vscode' "$WORK/pre.stdout" \
  || fail "new: pre-existing branch should point at sync-vscode"
grep -Fqi 'drift' "$WORK/pre.stderr" \
  || fail "new: pre-existing stale file should emit a drift notice"
grep -Eqi 'port' "$WORK/pre.stderr" \
  || fail "new: drift notice should mention ports"
[[ "$(dce_sha256_file "$PRE_DC")" == "$pre_sha" ]] \
  || fail "new: pre-existing devcontainer.json must not be rewritten"
pass "dce new: pre-existing devcontainer.json stays untouched and emits drift notice"

# =============================================================================
# I. `dce rebuild-container --from-snap`: fallback drift detection branch
# (global config unavailable -> scopes omitted, ports drift still reported)
# =============================================================================
SNAP_PROJ="fromsnapdrift"
: > "$RLOG"
run_dce "$ROOT_DIR/scripts/new-container.sh" "$SNAP_PROJ" \
  >"$WORK/fs.new.out" 2>"$WORK/fs.new.err" \
  || fail "new (from-snap fixture) exited non-zero ($(cat "$WORK/fs.new.err"))"
SNAP_DC="$WORK/home/repos/$SNAP_PROJ/.devcontainer/devcontainer.json"
[[ -f "$SNAP_DC" ]] || fail "from-snap fixture: devcontainer.json missing"

# Canonical drift trigger: mutate config ports only.
run_dce "$ROOT_DIR/scripts/config.sh" set "$SNAP_PROJ" ports=5000:5000 >/dev/null 2>&1 \
  || fail "from-snap fixture: config set ports exited non-zero"

# Snapshot image presence gate.
SNAP_REF="$(dce_snapshot_ref "$SNAP_PROJ" pre)"
printf '%s\n' "$SNAP_REF" >> "$RIMAGES"

# Force the --from-snap fallback branch in rebuild's drift hook: deriving scopes
# from global config now fails, so detection should skip scopes but still surface
# ports drift and remain non-fatal.
rm -f "$DC_ROOT/config"

: > "$RLOG"
run_dce "$ROOT_DIR/scripts/rebuild-container.sh" "$SNAP_PROJ" --from-snap pre --yes \
  </dev/null >"$WORK/fs.rb.out" 2>"$WORK/fs.rb.err" \
  || fail "rebuild --from-snap (fallback) exited non-zero ($(cat "$WORK/fs.rb.err"))"
FS_CREATE="$(grep -E "create --name $SNAP_PROJ" "$RLOG" | head -n1)"
grep -Fq "$SNAP_REF" <<<"$FS_CREATE" \
  || fail "rebuild --from-snap: create must use snapshot ref (got: $FS_CREATE)"
grep -Fqi 'drift' "$WORK/fs.rb.err" \
  || fail "rebuild --from-snap: fallback branch should still emit drift notice"
grep -Eqi 'port' "$WORK/fs.rb.err" \
  || fail "rebuild --from-snap: fallback drift notice should mention ports"
if grep -Fqi 'Global config not found' "$WORK/fs.rb.err"; then
  fail "rebuild --from-snap: fallback drift detection must not hard-fail on missing global config"
fi
pass "dce rebuild-container --from-snap: fallback drift detection remains non-fatal and reports ports"

echo ""
echo "All devcontainer-sync checks passed."
