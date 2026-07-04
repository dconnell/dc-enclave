#!/usr/bin/env bash
# =============================================================================
# tests/contract/devcontainer-sync.sh - Stubbed-backend devcontainer sync e2e.
#
# End-to-end behavior of devcontainer.json drift detection/sync through the
# real `dce` commands, with the container backend stubbed (no real daemon):
#   F. `dce config sync-vscode` (file-only; no backend needed)
#   G. `dce rebuild-container` drift notice after a config change
#   H. `dce new` pre-existing devcontainer.json: preserve file + drift notice
#   I. `dce rebuild-container --from-snap`: fallback drift detection branch
#
# The rebuild/new sections use the same stubbed-CLI harness style as
# tests/contract/new-container-lifecycle.sh.
#
# Pure library-API coverage (expected/recorded/detect/render/sync helpers with
# JSON fixtures) lives in tests/unit/devcontainer-helpers.sh.
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

  # (F1b) With a PAT configured, sync must inject github.gitAuthentication=false
  # so VS Code's git ops defer to the PAT-backed credential store.
  printf 'ghp_testtoken_for_sync\n' > "$SECRET2/github-token"
  chmod 600 "$SECRET2/github-token"
  dce_set_config_key "$SECRET2/config" TOKEN_FILE "$SECRET2/github-token"
  run_config sync-vscode "$PROJ2" >"$WORK/c2.out" 2>"$WORK/c2.err" \
    || fail "config sync-vscode (pat) exited non-zero ($(cat "$WORK/c2.err"))"
  RDC2="$(cat "$DC2")"
  echo "$RDC2" | jq -e '.customizations.vscode.settings["github.gitAuthentication"] == false' >/dev/null \
    || fail "config sync-vscode (pat): github.gitAuthentication must be false"
  # user extensions still preserved.
  echo "$RDC2" | jq -e '.extensions==["x"]' >/dev/null || fail "config sync-vscode (pat): user extensions lost"
  # Remove PAT -> next sync must strip the managed setting (back to ssh/none).
  dce_set_config_key "$SECRET2/config" TOKEN_FILE "$SECRET2/github-token-NONEXISTENT"
  run_config sync-vscode "$PROJ2" >"$WORK/c3.out" 2>"$WORK/c3.err" \
    || fail "config sync-vscode (no-pat) exited non-zero ($(cat "$WORK/c3.err"))"
  RDC3="$(cat "$DC2")"
  echo "$RDC3" | jq -e '.customizations.vscode.settings["github.gitAuthentication"] == null' >/dev/null \
    || fail "config sync-vscode (no-pat): github.gitAuthentication must be removed"

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
# (stubbed backend; mirrors tests/contract/new-container-lifecycle.sh harness)
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

# =============================================================================
# J. `dce config sync-vscode` editor-extensions management (plans/extensions.md)
#    - adopted (manifest present) -> customizations.vscode.extensions fully-managed
#    - pre-adoption (no manifest) -> hand-curated array untouched (migration guard)
# =============================================================================
if ! command -v jq >/dev/null 2>&1; then
  pass "extensions sync contract (skipped — jq not installed)"
else
  # Section I above removed the global config to exercise a fallback branch;
  # recreate it so sync-vscode can resolve the team/user roots again.
  [[ -f "$DC_ROOT/config" ]] || {
    mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
    {
      printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
      printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
    } > "$DC_ROOT/config"
    chmod 600 "$DC_ROOT/config"
  }

  # (J1) Adoption: a user all.txt manifest exists -> sync rewrites
  # customizations.vscode.extensions to the resolved set, replacing any
  # hand-curated array.
  EXT_USER_DIR="$USER_DIR/extensions/vscode"
  mkdir -p "$EXT_USER_DIR"
  printf 'a.b\nc.d\n' > "$EXT_USER_DIR/all.txt"

  EXT_PROJ="extproj"
  EXT_SECRET="$DC_ROOT/$EXT_PROJ"
  EXT_REPO="$WORK/home/repos/$EXT_PROJ"
  mkdir -p "$EXT_SECRET" "$EXT_REPO/.devcontainer"
  chmod 700 "$EXT_SECRET"
  {
    echo "CONTAINER_PROJECT=\"$EXT_PROJ\""
    echo "CONTAINER_BACKEND=\"docker\""
    echo "CONTAINER_IMAGE=\"dce-base:latest\""
    echo "CONTAINER_OVERLAY_SCOPES=\"\""
    echo "REPOS_DIR=\"$EXT_REPO\""
    echo "SECRET_DIR=\"$EXT_SECRET\""
    echo "PORTS=()"
    echo "CONTAINER_HIDDEN_PATHS=()"
    echo "CONTAINER_NETWORKS=()"
  } > "$EXT_SECRET/config"
  chmod 600 "$EXT_SECRET/config"
  EXT_DC="$EXT_REPO/.devcontainer/devcontainer.json"
  printf '{ "customizations": { "vscode": { "extensions": ["hand.curated"] } } }\n' > "$EXT_DC"
  chmod 600 "$EXT_DC"

  HOME="$WORK/home" bash "$ROOT_DIR/scripts/config.sh" sync-vscode "$EXT_PROJ" \
    >"$WORK/j1.out" 2>"$WORK/j1.err" || fail "sync extproj exited non-zero ($(cat "$WORK/j1.err"))"
  J1="$(cat "$EXT_DC")"
  echo "$J1" | jq -e '.customizations.vscode.extensions == ["a.b","c.d"]' >/dev/null \
    || fail "sync extproj: adopted array must equal resolved set (got $(echo "$J1" | jq -c '.customizations.vscode.extensions'))"
  pass "config sync-vscode: adopted -> customizations.vscode.extensions fully-managed"

  # (J2) Migration guard: remove the manifest -> a hand-curated array is preserved.
  rm -f "$EXT_USER_DIR/all.txt"
  printf '{ "customizations": { "vscode": { "extensions": ["keep.me", "user.choice"] } } }\n' > "$EXT_DC"
  HOME="$WORK/home" bash "$ROOT_DIR/scripts/config.sh" sync-vscode "$EXT_PROJ" \
    >"$WORK/j2.out" 2>"$WORK/j2.err" || fail "sync extproj (guard) exited non-zero ($(cat "$WORK/j2.err"))"
  J2="$(cat "$EXT_DC")"
  echo "$J2" | jq -e '.customizations.vscode.extensions == ["keep.me","user.choice"]' >/dev/null \
    || fail "sync extproj guard: pre-adoption array must be untouched (got $(echo "$J2" | jq -c '.customizations.vscode.extensions'))"
  pass "config sync-vscode: migration guard preserves hand-curated array (no manifest)"
fi

echo ""
echo "All devcontainer-sync checks passed."
