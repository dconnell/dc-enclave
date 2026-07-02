#!/usr/bin/env bash
# =============================================================================
# tests/contract/recipe.sh - Container recipe loading/merge coverage for `dce new`.
#
# Covers plans/container-recipe.md phase 2 behavior:
#   - magic lookup by project name under team/user container-recipes/
#   - user-over-team merge per key (list keys replace, not union)
#   - --config explicit recipe bypasses magic lookup
#   - CLI flags override recipe values (list keys replace as a whole)
#   - --save-team / --save-user persist CLI-supplied recipe inputs
#   - missing recipe keeps current defaults
#   - fail-closed parser behavior (unknown key, malformed line, invalid values)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
TEAM_OD="$TEAM_DIR/overlays"
USER_OD="$USER_DIR/overlays"
TEAM_REC="$TEAM_DIR/container-recipes"
USER_REC="$USER_DIR/container-recipes"
mkdir -p "$TEAM_OD" "$USER_OD" "$TEAM_REC" "$USER_REC"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

# Overlay fixtures used by recipe-driven scopes.
printf 'RUN echo TEAM-NODEJS\n' > "$TEAM_OD/Containerfile.nodejs"
printf 'RUN echo TEAM-GOLANG\n' > "$TEAM_OD/Containerfile.golang"

# Stub backend CLIs (docker/container/podman) to avoid daemon dependency.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"
NETWORKS="$WORK/networks.lst"
: > "$LOG"
printf 'dce-base:latest\n' > "$IMAGES"
printf 'app\nobs\n' > "$NETWORKS"

cat > "$STUB_DIR/_cli" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_imgs="${DC_STUB_IMAGES:-}"
_nets="${DC_STUB_NETWORKS:-}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"

if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then
  [[ -f "$_imgs" ]] && cat "$_imgs"
  exit 0
fi
if [[ "${1:-}" == "images" ]]; then
  [[ -f "$_imgs" ]] && cat "$_imgs"
  exit 0
fi

if [[ "${1:-}" == "network" && "${2:-}" == "ls" ]]; then
  [[ -f "$_nets" ]] && cat "$_nets"
  exit 0
fi

if [[ "$me" == "docker" && "${1:-}" == "context" && "${2:-}" == "show" ]]; then
  printf 'colima\n'
  exit 0
fi

exit 0
STUB
chmod +x "$STUB_DIR/_cli"
cp "$STUB_DIR/_cli" "$STUB_DIR/docker"
cp "$STUB_DIR/_cli" "$STUB_DIR/container"
cp "$STUB_DIR/_cli" "$STUB_DIR/podman"

ORIG_PATH="$PATH"
run_new() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" \
  TZ="UTC" \
  DC_STUB_LOG="$LOG" \
  DC_STUB_IMAGES="$IMAGES" \
  DC_STUB_NETWORKS="$NETWORKS" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="docker" \
  bash "$ROOT_DIR/scripts/new-container.sh" "$@"
}

load_cfg() {
  local project="$1"
  local cfg="$HOME/.config/dce-enclave/$project/config"
  [[ -f "$cfg" ]] || fail "missing config for $project"
  # shellcheck disable=SC2034
  # Reset before dce_load_project_config repopulates them from the sourced cfg.
  PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
  dce_load_project_config "$cfg"
}

assert_no_config() {
  local project="$1"
  [[ ! -f "$HOME/.config/dce-enclave/$project/config" ]] \
    || fail "unexpected config created for failing recipe: $project"
}

# ---------------------------------------------------------------------------
# team-only recipe autoload by project name
# ---------------------------------------------------------------------------
cat > "$TEAM_REC/api" <<'EOF'
scopes=nodejs
cpus=2
memory=4g
hide=node_modules
port=3000:3000
EOF

: > "$LOG"
run_new api >"$WORK/api.out" 2>"$WORK/api.err" || fail "team-only recipe create failed"
load_cfg api
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "nodejs" ]] || fail "team-only: scopes"
[[ "${CONTAINER_CPUS:-}" == "2" ]] || fail "team-only: cpus"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "team-only: memory"
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == "node_modules" ]] || fail "team-only: hide"
[[ "${PORTS[*]:-}" == "3000:3000" ]] || fail "team-only: port"
pass "team recipe auto-load"

# ---------------------------------------------------------------------------
# user-over-team merge, list keys replace (not union)
# ---------------------------------------------------------------------------
cat > "$TEAM_REC/svc" <<'EOF'
scopes=nodejs,golang
cpus=1
hide=node_modules
port=3000:3000
EOF
cat > "$USER_REC/svc" <<'EOF'
cpus=3
hide=.cache
port=8080
EOF

: > "$LOG"
run_new svc >"$WORK/svc.out" 2>"$WORK/svc.err" || fail "user-over-team create failed"
load_cfg svc
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "nodejs,golang" ]] || fail "user-over-team: inherited scopes"
[[ "${CONTAINER_CPUS:-}" == "3" ]] || fail "user-over-team: cpus override"
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == ".cache" ]] || fail "user-over-team: hide replace"
[[ "${PORTS[*]:-}" == "8080" ]] || fail "user-over-team: port replace"
pass "user recipe overrides team per key"

# ---------------------------------------------------------------------------
# --config explicit file bypasses magic lookup
# ---------------------------------------------------------------------------
cat > "$TEAM_REC/explicit" <<'EOF'
scopes=nodejs
cpus=1
port=1111
EOF
cat > "$USER_REC/explicit" <<'EOF'
cpus=9
port=2222
EOF
cat > "$WORK/custom.recipe" <<'EOF'
scopes=golang
cpus=5
port=7000
EOF

: > "$LOG"
run_new explicit --config "$WORK/custom.recipe" >"$WORK/explicit.out" 2>"$WORK/explicit.err" \
  || fail "explicit --config create failed"
load_cfg explicit
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "golang" ]] || fail "--config: scopes should come from explicit file"
[[ "${CONTAINER_CPUS:-}" == "5" ]] || fail "--config: cpus should come from explicit file"
[[ "${PORTS[*]:-}" == "7000" ]] || fail "--config: port should come from explicit file"
pass "--config explicit recipe source"

# ---------------------------------------------------------------------------
# CLI-over-recipe precedence
# ---------------------------------------------------------------------------
cat > "$TEAM_REC/cliovr" <<'EOF'
scopes=nodejs
cpus=2
memory=4g
hide=node_modules
port=3000:3000
EOF

: > "$LOG"
run_new cliovr --cpus 6 --hide .cache 8080 >"$WORK/cliovr.out" 2>"$WORK/cliovr.err" \
  || fail "cli-over-recipe create failed"
load_cfg cliovr
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "nodejs" ]] || fail "cli-over-recipe: scopes from recipe"
[[ "${CONTAINER_CPUS:-}" == "6" ]] || fail "cli-over-recipe: cpus from CLI"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "cli-over-recipe: memory from recipe"
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == ".cache" ]] || fail "cli-over-recipe: hide list from CLI"
[[ "${PORTS[*]:-}" == "8080" ]] || fail "cli-over-recipe: ports list from CLI"
pass "CLI flags override recipe values"

# ---------------------------------------------------------------------------
# --save-team / --save-user persist CLI-supplied recipe inputs
# ---------------------------------------------------------------------------
: > "$LOG"
run_new saveteam nodejs,golang \
  --cpus 4 --memory 8g \
  --hide ./node_modules --hide .cache \
  --network app,obs --ip 10.0.0.8 \
  --repo-path ./repos/saveteam \
  3000:3000 8080 \
  --save-team \
  >"$WORK/saveteam.out" 2>"$WORK/saveteam.err" || fail "--save-team create failed"

[[ -f "$TEAM_REC/saveteam" ]] || fail "--save-team: missing team recipe file"
expected_saveteam="$WORK/expected.saveteam"
cat > "$expected_saveteam" <<'EOF'
scopes=nodejs,golang
cpus=4
memory=8g
hide=node_modules
hide=.cache
network=app,obs
ip=10.0.0.8
repo-path=./repos/saveteam
port=3000:3000
port=8080
EOF
if ! cmp -s "$expected_saveteam" "$TEAM_REC/saveteam"; then
  fail "--save-team: recipe content mismatch"
fi
pass "--save-team writes canonical recipe content"

cat > "$TEAM_REC/saveuser" <<'EOF'
scopes=nodejs
memory=4g
port=3000
EOF

: > "$LOG"
run_new saveuser --cpus 6 --hide .cache --save-user \
  >"$WORK/saveuser.out" 2>"$WORK/saveuser.err" || fail "--save-user create failed"

[[ -f "$USER_REC/saveuser" ]] || fail "--save-user: missing user recipe file"
expected_saveuser="$WORK/expected.saveuser"
cat > "$expected_saveuser" <<'EOF'
cpus=6
hide=.cache
EOF
if ! cmp -s "$expected_saveuser" "$USER_REC/saveuser"; then
  fail "--save-user: recipe content mismatch"
fi
pass "--save-user stores only CLI-supplied keys"

: > "$LOG"
run_new saveboth golang 7000 --save-team --save-user \
  >"$WORK/saveboth.out" 2>"$WORK/saveboth.err" || fail "--save-team --save-user create failed"

[[ -f "$TEAM_REC/saveboth" ]] || fail "--save both: missing team recipe"
[[ -f "$USER_REC/saveboth" ]] || fail "--save both: missing user recipe"
expected_saveboth="$WORK/expected.saveboth"
cat > "$expected_saveboth" <<'EOF'
scopes=golang
port=7000
EOF
if ! cmp -s "$expected_saveboth" "$TEAM_REC/saveboth"; then
  fail "--save both: team recipe content mismatch"
fi
if ! cmp -s "$expected_saveboth" "$USER_REC/saveboth"; then
  fail "--save both: user recipe content mismatch"
fi
pass "--save-team --save-user writes both recipe files"

# ---------------------------------------------------------------------------
# Missing recipe keeps defaults
# ---------------------------------------------------------------------------
: > "$LOG"
run_new norecipe >"$WORK/norecipe.out" 2>"$WORK/norecipe.err" || fail "missing-recipe create failed"
load_cfg norecipe
[[ -z "${CONTAINER_OVERLAY_SCOPES:-}" ]] || fail "missing recipe: scopes should default empty"
[[ -z "${CONTAINER_CPUS:-}" ]] || fail "missing recipe: cpus should default empty"
[[ -z "${CONTAINER_MEMORY:-}" ]] || fail "missing recipe: memory should default empty"
[[ ${#PORTS[@]} -eq 0 ]] || fail "missing recipe: ports should default empty"
pass "missing recipe preserves default behavior"

# ---------------------------------------------------------------------------
# Fail-closed parser behavior
# ---------------------------------------------------------------------------
cat > "$TEAM_REC/badkey" <<'EOF'
oops=1
EOF
if run_new badkey >"$WORK/badkey.out" 2>"$WORK/badkey.err"; then
  fail "unknown recipe key should fail"
fi
assert_no_config badkey

cat > "$TEAM_REC/badline" <<'EOF'
scopes
EOF
if run_new badline >"$WORK/badline.out" 2>"$WORK/badline.err"; then
  fail "malformed recipe line should fail"
fi
assert_no_config badline

cat > "$TEAM_REC/badcpus" <<'EOF'
cpus=0
EOF
if run_new badcpus >"$WORK/badcpus.out" 2>"$WORK/badcpus.err"; then
  fail "invalid cpus should fail"
fi
assert_no_config badcpus

cat > "$TEAM_REC/badport" <<'EOF'
port=abc
EOF
if run_new badport >"$WORK/badport.out" 2>"$WORK/badport.err"; then
  fail "invalid port should fail"
fi
assert_no_config badport

cat > "$TEAM_REC/badscope" <<'EOF'
scopes=ghostscope
EOF
if run_new badscope >"$WORK/badscope.out" 2>"$WORK/badscope.err"; then
  fail "unknown recipe scope should fail"
fi
assert_no_config badscope

pass "invalid recipes fail closed and create nothing"

# ---------------------------------------------------------------------------
# Recipe-sourced repo-path gating
#
# An auto-loaded recipe is untrusted input, so it must not silently widen the
# host bind mount. Outside the default repos dir => confirm (or --yes); a path
# that resolves to a sensitive root (/ , $HOME, the repos root or a parent) is
# hard-rejected even with --yes. CLI --repo-path is the documented escape hatch
# and is never gated.
# ---------------------------------------------------------------------------
CUSTOM_REPOS="$WORK/custom-team-repos"

# (a) recipe repo-path OUTSIDE default + --yes => honored with an explicit msg.
cat > "$TEAM_REC/rp-yes" <<EOF
repo-path=$CUSTOM_REPOS/rp-yes
EOF
: > "$LOG"
run_new rp-yes --yes >"$WORK/rp-yes.out" 2>"$WORK/rp-yes.err" || fail "recipe repo-path + --yes should honor the path"
load_cfg rp-yes
exp_yes="$(dce_resolve_path "$CUSTOM_REPOS/rp-yes")"
[[ "$REPOS_DIR" == "$exp_yes" ]] || fail "recipe repo-path --yes: REPOS_DIR should be the recipe path (got '${REPOS_DIR:-}')"
grep -q "honoring recipe repo-path" "$WORK/rp-yes.out" || fail "recipe repo-path --yes: should print an explicit honoring message"
pass "recipe repo-path outside default honored with --yes (explicit message)"

# (b) recipe repo-path OUTSIDE default + interactive 'yes' => honored.
cat > "$TEAM_REC/rp-confirm" <<EOF
repo-path=$CUSTOM_REPOS/rp-confirm
EOF
: > "$LOG"
run_new rp-confirm <<< $'yes\n' >"$WORK/rp-confirm.out" 2>"$WORK/rp-confirm.err" || fail "recipe repo-path confirm 'yes' should honor"
load_cfg rp-confirm
exp_conf="$(dce_resolve_path "$CUSTOM_REPOS/rp-confirm")"
[[ "$REPOS_DIR" == "$exp_conf" ]] || fail "recipe repo-path confirm: REPOS_DIR mismatch (got '${REPOS_DIR:-}')"
pass "recipe repo-path outside default confirmed interactively"

# (c) recipe repo-path OUTSIDE default + denied => aborted, nothing mounted.
cat > "$TEAM_REC/rp-deny" <<EOF
repo-path=$CUSTOM_REPOS/rp-deny
EOF
: > "$LOG"
run_new rp-deny <<< $'no\n' >"$WORK/rp-deny.out" 2>"$WORK/rp-deny.err" || true
assert_no_config rp-deny
grep -q "Aborted" "$WORK/rp-deny.out" || fail "recipe repo-path deny: should print Aborted"
pass "recipe repo-path outside default can be denied (no mount)"

# (c2) non-interactive (no stdin / EOF) + no --yes => aborted, never silently mounted.
cat > "$TEAM_REC/rp-eof" <<EOF
repo-path=$CUSTOM_REPOS/rp-eof
EOF
: > "$LOG"
run_new rp-eof </dev/null >"$WORK/rp-eof.out" 2>"$WORK/rp-eof.err" || true
assert_no_config rp-eof
grep -q "Aborted" "$WORK/rp-eof.out" || fail "recipe repo-path non-interactive: should abort with a message"
pass "recipe repo-path non-interactive (no --yes) aborts with a message"

# (d) recipe repo-path traversal => hard-rejected after normalization.
cat > "$TEAM_REC/rp-traversal" <<'EOF'
repo-path=../../..
EOF
: > "$LOG"
if run_new rp-traversal >"$WORK/rp-traversal.out" 2>"$WORK/rp-traversal.err"; then
  fail "recipe repo-path traversal (../../..) should be rejected"
fi
assert_no_config rp-traversal
pass "recipe repo-path traversal rejected after normalization"

# (e) recipe repo-path resolving to $HOME => hard-rejected even with --yes.
cat > "$TEAM_REC/rp-home" <<EOF
repo-path=$HOME
EOF
: > "$LOG"
if run_new rp-home --yes >"$WORK/rp-home.out" 2>"$WORK/rp-home.err"; then
  fail "recipe repo-path resolving to \$HOME should be rejected even with --yes"
fi
assert_no_config rp-home
pass "recipe repo-path resolving to \$HOME is hard-rejected"

# (f) recipe repo-path INSIDE the default repos dir => no gate, just works.
INSIDE_REPOS="$WORK/home/repos/shared"
cat > "$TEAM_REC/rp-inside" <<EOF
repo-path=$INSIDE_REPOS
EOF
: > "$LOG"
run_new rp-inside >"$WORK/rp-inside.out" 2>"$WORK/rp-inside.err" || fail "recipe repo-path inside repos dir should need no confirmation"
load_cfg rp-inside
exp_in="$(dce_resolve_path "$INSIDE_REPOS")"
[[ "$REPOS_DIR" == "$exp_in" ]] || fail "recipe repo-path inside repos: REPOS_DIR mismatch (got '${REPOS_DIR:-}')"
pass "recipe repo-path inside default repos dir needs no confirmation"

# (g) CLI --repo-path outside default => escape hatch, no prompt, honored.
: > "$LOG"
run_new rp-cli --repo-path "$CUSTOM_REPOS/rp-cli" >"$WORK/rp-cli.out" 2>"$WORK/rp-cli.err" <<< "" \
  || fail "CLI --repo-path should work without a prompt"
load_cfg rp-cli
exp_cli="$(dce_resolve_path "$CUSTOM_REPOS/rp-cli")"
[[ "$REPOS_DIR" == "$exp_cli" ]] || fail "CLI --repo-path: REPOS_DIR mismatch (got '${REPOS_DIR:-}')"
pass "CLI --repo-path escape hatch preserved (no prompt)"

# (h) other recipe keys still parse/apply alongside repo-path gating (regression).
cat > "$TEAM_REC/rp-other" <<'EOF'
scopes=nodejs
cpus=2
memory=4g
hide=node_modules
port=3000:3000
EOF
: > "$LOG"
run_new rp-other >"$WORK/rp-other.out" 2>"$WORK/rp-other.err" <<< "" || fail "recipe with other keys should create"
load_cfg rp-other
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "nodejs" ]] || fail "recipe other keys: scopes"
[[ "${CONTAINER_CPUS:-}" == "2" ]] || fail "recipe other keys: cpus"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "recipe other keys: memory"
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == "node_modules" ]] || fail "recipe other keys: hide"
[[ "${PORTS[*]:-}" == "3000:3000" ]] || fail "recipe other keys: port"
pass "other recipe keys unaffected by repo-path gating"

# ---------------------------------------------------------------------------
# repo-path gate hardening (review follow-ups)
#
# Covers the gaps found in review of the recipe repo-path gate:
#   - symlink redirect: a path that looks inside the repos root lexically but
#     resolves to $HOME via a symlink must be hard-rejected (canonical resolve).
#   - CLI escape hatch: --repo-path to $HOME is honored (sensitive-root
#     rejection is recipe-only by design).
#   - -y short flag parses in the position-after-name slot (scope pre-parse).
#   - DC_REPOS_DIR='~/repos' is tilde-expanded for the inside/outside test.
# ---------------------------------------------------------------------------

# (i) recipe repo-path that is a SYMLINK to $HOME => caught by canonical resolve.
mkdir -p "$WORK/home/repos"
ln -s "$HOME" "$WORK/home/repos/link"
cat > "$TEAM_REC/rp-symlink" <<EOF
repo-path=$WORK/home/repos/link
EOF
: > "$LOG"
if run_new rp-symlink </dev/null >"$WORK/rp-symlink.out" 2>"$WORK/rp-symlink.err"; then
  fail "recipe repo-path symlink to \$HOME should be rejected"
fi
assert_no_config rp-symlink
pass "recipe repo-path symlink to a sensitive root is rejected (canonical resolve)"

# (j) CLI --repo-path "$HOME" => escape hatch restored (recipe-only rejection).
: > "$LOG"
run_new rp-clihome --repo-path "$HOME" </dev/null >"$WORK/rp-clihome.out" 2>"$WORK/rp-clihome.err" \
  || fail "CLI --repo-path \$HOME should be honored (escape hatch)"
load_cfg rp-clihome
exp_clihome="$(dce_resolve_path "$HOME")"
[[ "$REPOS_DIR" == "$exp_clihome" ]] || fail "CLI --repo-path \$HOME: REPOS_DIR mismatch (got '${REPOS_DIR:-}')"
pass "CLI --repo-path to \$HOME honored (escape hatch preserved)"

# (k) -y short flag parses in the position-after-name slot (was misparsed as scope).
: > "$LOG"
run_new rp-shorty -y </dev/null >"$WORK/rp-shorty.out" 2>"$WORK/rp-shorty.err" \
  || { cat "$WORK/rp-shorty.err" >&2; fail "dce new <name> -y should parse"; }
if grep -qi "Invalid scope name" "$WORK/rp-shorty.err"; then
  fail "-y was misparsed as a scope in the position-after-name slot"
fi
pass "short flag -y accepted in the position-after-name slot"

# (l) DC_REPOS_DIR='~/repos' is tilde-expanded for the default-root comparison.
# A recipe path actually inside ~/repos must NOT be misclassified as outside.
cat > "$TEAM_REC/rp-tilde" <<EOF
repo-path=$HOME/repos/tildeinside
EOF
: > "$LOG"
# shellcheck disable=SC2088
# The literal ~/repos is the point of the test: it must be expanded by the gate.
HOME="$WORK/home" DC_REPOS_DIR='~/repos' TZ=UTC \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" DC_STUB_NETWORKS="$NETWORKS" \
  PATH="$STUB_DIR:$ORIG_PATH" CONTAINER_BACKEND=docker \
  bash "$ROOT_DIR/scripts/new-container.sh" rp-tilde </dev/null \
  >"$WORK/rp-tilde.out" 2>"$WORK/rp-tilde.err" \
  || { cat "$WORK/rp-tilde.err" >&2; fail "DC_REPOS_DIR=~/repos with inside path should not prompt"; }
if grep -qi "outside the default repos directory" "$WORK/rp-tilde.out"; then
  fail "DC_REPOS_DIR=~/repos misclassified an inside path as outside"
fi
load_cfg rp-tilde
pass "DC_REPOS_DIR=~/repos tilde-expanded for the inside/outside comparison"

echo ""
echo "All recipe checks passed."
