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
DC_ROOT="$HOME/.config/dc-enclave"
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
  local cfg="$HOME/.config/dc-enclave/$project/config"
  [[ -f "$cfg" ]] || fail "missing config for $project"
  # shellcheck disable=SC2034
  # Reset before dce_load_project_config repopulates them from the sourced cfg.
  PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=() REPO_NAMES=() REPO_PATHS=()
  dce_load_project_config "$cfg"
}

# The schema-v2 config has no REPOS_DIR scalar; the repo set is
# REPO_NAMES/REPO_PATHS. Single-repo helpers use index 0.
repo_path_of() {
  printf '%s\n' "${REPO_PATHS[0]:-}"
}

repo_name_of() {
  printf '%s\n' "${REPO_NAMES[0]:-}"
}

assert_no_config() {
  local project="$1"
  [[ ! -f "$HOME/.config/dc-enclave/$project/config" ]] \
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
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == "api/node_modules" ]] || fail "team-only: hide (persisted repo-prefixed)"
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
hide=dist
port=8080
EOF

: > "$LOG"
run_new svc >"$WORK/svc.out" 2>"$WORK/svc.err" || fail "user-over-team create failed"
load_cfg svc
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "nodejs,golang" ]] || fail "user-over-team: inherited scopes"
[[ "${CONTAINER_CPUS:-}" == "3" ]] || fail "user-over-team: cpus override"
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == "svc/dist" ]] || fail "user-over-team: hide replace"
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
run_new cliovr --cpus 6 --hide dist 8080 >"$WORK/cliovr.out" 2>"$WORK/cliovr.err" \
  || fail "cli-over-recipe create failed"
load_cfg cliovr
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "nodejs" ]] || fail "cli-over-recipe: scopes from recipe"
[[ "${CONTAINER_CPUS:-}" == "6" ]] || fail "cli-over-recipe: cpus from CLI"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "cli-over-recipe: memory from recipe"
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == "cliovr/dist" ]] || fail "cli-over-recipe: hide list from CLI"
[[ "${PORTS[*]:-}" == "8080" ]] || fail "cli-over-recipe: ports list from CLI"
pass "CLI flags override recipe values"

# ---------------------------------------------------------------------------
# --save-team / --save-user persist CLI-supplied recipe inputs
# ---------------------------------------------------------------------------
: > "$LOG"
# --yes: the relative --repo path resolves outside the default repos root, which
# now gates CLI entries too (plans/projects-2.md section 8).
run_new saveteam nodejs,golang \
  --cpus 4 --memory 8g \
  --hide ./node_modules --hide build-cache \
  --network app,obs --ip 10.0.0.8 \
  --repo ./repos/saveteam \
  3000:3000 8080 \
  --save-team --yes \
  >"$WORK/saveteam.out" 2>"$WORK/saveteam.err" || fail "--save-team create failed"

[[ -f "$TEAM_REC/saveteam" ]] || fail "--save-team: missing team recipe file"
expected_saveteam="$WORK/expected.saveteam"
cat > "$expected_saveteam" <<'EOF'
scopes=nodejs,golang
cpus=4
memory=8g
hide=node_modules
hide=build-cache
network=app,obs
ip=10.0.0.8
repo=./repos/saveteam
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
run_new saveuser --cpus 6 --hide build-cache --save-user \
  >"$WORK/saveuser.out" 2>"$WORK/saveuser.err" || fail "--save-user create failed"

[[ -f "$USER_REC/saveuser" ]] || fail "--save-user: missing user recipe file"
expected_saveuser="$WORK/expected.saveuser"
cat > "$expected_saveuser" <<'EOF'
cpus=6
hide=build-cache
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
# Recipe-sourced repo= gating
#
# An auto-loaded recipe is untrusted input, so it must not silently widen the
# host bind mount. Outside the default repos dir => confirm (or --yes); a path
# that resolves to a sensitive root (/ , $HOME, the repos root or a parent) is
# hard-rejected even with --yes. CLI `--repo` supports the same host-path inputs,
# but removed surfaces (`repo-path`, `--repo-path`) must fail with replacement
# guidance.
# ---------------------------------------------------------------------------
CUSTOM_REPOS="$WORK/custom-team-repos"

# (a) recipe repo OUTSIDE default + --yes => honored with an explicit msg.
cat > "$TEAM_REC/rp-yes" <<EOF
repo=$CUSTOM_REPOS/rp-yes
EOF
: > "$LOG"
run_new rp-yes --yes >"$WORK/rp-yes.out" 2>"$WORK/rp-yes.err" || fail "recipe repo + --yes should honor the path"
load_cfg rp-yes
exp_yes="$(dce_resolve_path "$CUSTOM_REPOS/rp-yes")"
[[ "$(repo_path_of)" == "$exp_yes" ]] || fail "recipe repo --yes: REPO_PATHS[0] should be the recipe path (got '${REPO_PATHS[0]:-}')"
[[ "$(repo_name_of)" == "rp-yes" ]] || fail "recipe repo --yes: default repo name should be the project name basename/path basename-compatible"
grep -q "honoring recipe repo path" "$WORK/rp-yes.out" || fail "recipe repo --yes: should print an explicit honoring message"
pass "recipe repo outside default honored with --yes (explicit message)"

# (b) recipe repo OUTSIDE default + interactive 'yes' => honored.
cat > "$TEAM_REC/rp-confirm" <<EOF
repo=$CUSTOM_REPOS/rp-confirm
EOF
: > "$LOG"
run_new rp-confirm <<< $'yes\n' >"$WORK/rp-confirm.out" 2>"$WORK/rp-confirm.err" || fail "recipe repo confirm 'yes' should honor"
load_cfg rp-confirm
exp_conf="$(dce_resolve_path "$CUSTOM_REPOS/rp-confirm")"
[[ "$(repo_path_of)" == "$exp_conf" ]] || fail "recipe repo confirm: REPO_PATHS[0] mismatch (got '${REPO_PATHS[0]:-}')"
pass "recipe repo outside default confirmed interactively"

# (c) recipe repo OUTSIDE default + denied => aborted, nothing mounted.
cat > "$TEAM_REC/rp-deny" <<EOF
repo=$CUSTOM_REPOS/rp-deny
EOF
: > "$LOG"
run_new rp-deny <<< $'no\n' >"$WORK/rp-deny.out" 2>"$WORK/rp-deny.err" || true
assert_no_config rp-deny
grep -q "Aborted" "$WORK/rp-deny.out" || fail "recipe repo deny: should print Aborted"
pass "recipe repo outside default can be denied (no mount)"

# (c2) non-interactive (no stdin / EOF) + no --yes => aborted, never silently mounted.
cat > "$TEAM_REC/rp-eof" <<EOF
repo=$CUSTOM_REPOS/rp-eof
EOF
: > "$LOG"
run_new rp-eof </dev/null >"$WORK/rp-eof.out" 2>"$WORK/rp-eof.err" || true
assert_no_config rp-eof
grep -q "Aborted" "$WORK/rp-eof.out" || fail "recipe repo non-interactive: should abort with a message"
pass "recipe repo non-interactive (no --yes) aborts with a message"

# (d) recipe repo traversal => hard-rejected after normalization.
cat > "$TEAM_REC/rp-traversal" <<'EOF'
repo=../../..
EOF
: > "$LOG"
if run_new rp-traversal >"$WORK/rp-traversal.out" 2>"$WORK/rp-traversal.err"; then
  fail "recipe repo traversal (../../..) should be rejected"
fi
assert_no_config rp-traversal
pass "recipe repo traversal rejected after normalization"

# (e) recipe repo resolving to $HOME => hard-rejected even with --yes.
cat > "$TEAM_REC/rp-home" <<EOF
repo=$HOME
EOF
: > "$LOG"
if run_new rp-home --yes >"$WORK/rp-home.out" 2>"$WORK/rp-home.err"; then
  fail "recipe repo resolving to \$HOME should be rejected even with --yes"
fi
assert_no_config rp-home
pass "recipe repo resolving to \$HOME is hard-rejected"

# (f) recipe repo INSIDE the default repos dir => no gate, just works.
INSIDE_REPOS="$WORK/home/repos/shared"
cat > "$TEAM_REC/rp-inside" <<EOF
repo=$INSIDE_REPOS
EOF
: > "$LOG"
run_new rp-inside >"$WORK/rp-inside.out" 2>"$WORK/rp-inside.err" || fail "recipe repo inside repos dir should need no confirmation"
load_cfg rp-inside
exp_in="$(dce_resolve_path "$INSIDE_REPOS")"
[[ "$(repo_path_of)" == "$exp_in" ]] || fail "recipe repo inside repos: REPO_PATHS[0] mismatch (got '${REPO_PATHS[0]:-}')"
pass "recipe repo inside default repos dir needs no confirmation"

# (g) removed CLI --repo-path fails with replacement guidance.
: > "$LOG"
if run_new rp-cli --repo-path "$CUSTOM_REPOS/rp-cli" >"$WORK/rp-cli.out" 2>"$WORK/rp-cli.err" <<< ""; then
  fail "CLI --repo-path should be rejected with replacement guidance"
fi
grep -qi -- '--repo' "$WORK/rp-cli.err" || fail "removed --repo-path error should mention --repo replacement"
grep -qi 'legacy-single-repo' "$WORK/rp-cli.err" \
  || fail "removed --repo-path error should also point to the legacy-single-repo branch (got: $(cat "$WORK/rp-cli.err" 2>/dev/null))"
assert_no_config rp-cli
pass "CLI --repo-path removed with replacement guidance"

# (g2) CLI --repo outside default works and defaults the repo name from basename(path).
# --yes: outside-default-root entries are gated for CLI sources too.
: > "$LOG"
run_new rp-cli2 --yes --repo "$CUSTOM_REPOS/rp-cli" >"$WORK/rp-cli2.out" 2>"$WORK/rp-cli2.err" <<< "" \
  || fail "CLI --repo should honor an explicit path"
load_cfg rp-cli2
exp_cli="$(dce_resolve_path "$CUSTOM_REPOS/rp-cli")"
[[ "$(repo_path_of)" == "$exp_cli" ]] || fail "CLI --repo: REPO_PATHS[0] mismatch (got '${REPO_PATHS[0]:-}')"
[[ "$(repo_name_of)" == "rp-cli" ]] || fail "CLI --repo: default repo name should come from basename(path)"
pass "CLI --repo honors explicit path and basename-derived name"

# (g3) CLI --repo with explicit name=<path> works.
: > "$LOG"
run_new rp-clialias --yes --repo "frontend=$CUSTOM_REPOS/rp-clialias" >"$WORK/rp-clialias.out" 2>"$WORK/rp-clialias.err" \
  || fail "CLI --repo name=path should work"
load_cfg rp-clialias
[[ "${REPO_NAMES[0]:-}" == "frontend" ]] || fail "CLI --repo name=path: explicit repo name not preserved"
pass "CLI --repo name=path preserves explicit name"

# (g4) multi-repo create with repeated --repo works and persists both repos.
: > "$LOG"
run_new multirepo --yes --repo "web=$CUSTOM_REPOS/multi-web" --repo "$CUSTOM_REPOS/multi-api" \
  >"$WORK/multirepo.out" 2>"$WORK/multirepo.err" || fail "multi-repo create with repeated --repo should work"
load_cfg multirepo
[[ ${#REPO_NAMES[@]} -eq 2 ]] || fail "repeated --repo should persist two repo names (got ${#REPO_NAMES[@]})"
[[ "${REPO_NAMES[0]:-}" == "web" && "${REPO_NAMES[1]:-}" == "multi-api" ]] \
  || fail "repeated --repo names wrong (got ${REPO_NAMES[*]:-})"
pass "repeated --repo creates a two-repo project"

# (g5) recipe repo-path is removed with replacement guidance.
cat > "$TEAM_REC/rp-oldkey" <<EOF
repo-path=$CUSTOM_REPOS/rp-oldkey
EOF
if run_new rp-oldkey >"$WORK/rp-oldkey.out" 2>"$WORK/rp-oldkey.err"; then
  fail "recipe repo-path should be rejected with replacement guidance"
fi
grep -qi 'repo=' "$WORK/rp-oldkey.err" || fail "removed recipe repo-path error should mention repo= replacement"
grep -qi 'legacy-single-repo' "$WORK/rp-oldkey.err" \
  || fail "removed recipe repo-path error should also point to the legacy-single-repo branch (got: $(cat "$WORK/rp-oldkey.err" 2>/dev/null))"
assert_no_config rp-oldkey
pass "recipe repo-path removed with replacement guidance"

# (h) other recipe keys still parse/apply alongside repo gating (regression).
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
[[ "${CONTAINER_HIDDEN_PATHS[*]:-}" == "rp-other/node_modules" ]] || fail "recipe other keys: hide"
[[ "${PORTS[*]:-}" == "3000:3000" ]] || fail "recipe other keys: port"
pass "other recipe keys unaffected by repo gating"

# ---------------------------------------------------------------------------
# repo gate hardening (review follow-ups)
#
# Covers the gaps found in review of the recipe repo gate:
#   - symlink redirect: a path that looks inside the repos root lexically but
#     resolves to $HOME via a symlink must be hard-rejected (canonical resolve).
#   - The host root (/) and $HOME are never valid repo paths, for EVERY source.
#   - -y short flag parses in the position-after-name slot (scope pre-parse).
#   - DC_REPOS_DIR='~/repos' is tilde-expanded for the inside/outside test.
# ---------------------------------------------------------------------------

# (i) recipe repo that is a SYMLINK to $HOME => caught by canonical resolve.
mkdir -p "$WORK/home/repos"
ln -s "$HOME" "$WORK/home/repos/link"
cat > "$TEAM_REC/rp-symlink" <<EOF
repo=$WORK/home/repos/link
EOF
: > "$LOG"
if run_new rp-symlink </dev/null >"$WORK/rp-symlink.out" 2>"$WORK/rp-symlink.err"; then
  fail "recipe repo symlink to \$HOME should be rejected"
fi
assert_no_config rp-symlink
pass "recipe repo symlink to a sensitive root is rejected (canonical resolve)"

# (j) CLI --repo "$HOME" => rejected: canonical $HOME (like /) is never a
# valid repo path.
: > "$LOG"
if run_new rp-clihome --repo "$HOME" </dev/null >"$WORK/rp-clihome.out" 2>"$WORK/rp-clihome.err"; then
  fail "CLI --repo \$HOME should be rejected (canonical \$HOME is never mountable)"
fi
assert_no_config rp-clihome
grep -qi 'home directory' "$WORK/rp-clihome.err" \
  || fail "CLI --repo \$HOME rejection should explain the home-directory rule (got: $(cat "$WORK/rp-clihome.err" 2>/dev/null))"
pass "CLI --repo to \$HOME rejected (canonical \$HOME never mountable)"

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
repo=$HOME/repos/tildeinside
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

# ---------------------------------------------------------------------------
# CLI --repo outside the default repos root gates the same way recipes do
#
# plans/projects-2.md section 8 originally made the repos-root/ancestor hard
# rejection recipe-only. We deliberately tighten the policy for the multi-repo
# model: the repos root (and any ancestor of it) is too broad to expose for ANY
# source. Other outside-default-root paths still prompt unless --yes/-y is
# present; / and $HOME remain rejected for every source.
# ---------------------------------------------------------------------------

# (m) CLI --repo outside default + --yes => honored with an explicit msg.
: > "$LOG"
run_new rp-cliyes --yes --repo "$CUSTOM_REPOS/rp-cliyes" </dev/null \
  >"$WORK/rp-cliyes.out" 2>"$WORK/rp-cliyes.err" \
  || fail "CLI --repo outside default + --yes should honor the path"
load_cfg rp-cliyes
exp_cliyes="$(dce_resolve_path "$CUSTOM_REPOS/rp-cliyes")"
[[ "$(repo_path_of)" == "$exp_cliyes" ]] \
  || fail "CLI --repo --yes: REPO_PATHS[0] should be the --repo path (got '${REPO_PATHS[0]:-}')"
grep -q "honoring --repo path" "$WORK/rp-cliyes.out" \
  || fail "CLI --repo --yes: should print an explicit honoring message (got: $(cat "$WORK/rp-cliyes.out" 2>/dev/null))"
pass "CLI --repo outside default honored with --yes (explicit message)"

# (n) CLI --repo outside default + interactive 'yes' => honored.
: > "$LOG"
run_new rp-cliconfirm --repo "$CUSTOM_REPOS/rp-cliconfirm" <<< $'yes\n' \
  >"$WORK/rp-cliconfirm.out" 2>"$WORK/rp-cliconfirm.err" \
  || fail "CLI --repo confirm 'yes' should honor"
grep -qi "requires confirmation" "$WORK/rp-cliconfirm.out" \
  || fail "CLI --repo outside default should prompt before mounting (got: $(cat "$WORK/rp-cliconfirm.out" 2>/dev/null))"
load_cfg rp-cliconfirm
exp_cliconf="$(dce_resolve_path "$CUSTOM_REPOS/rp-cliconfirm")"
[[ "$(repo_path_of)" == "$exp_cliconf" ]] \
  || fail "CLI --repo confirm: REPO_PATHS[0] mismatch (got '${REPO_PATHS[0]:-}')"
pass "CLI --repo outside default confirmed interactively"

# (o) CLI --repo outside default + denied => aborted, nothing mounted.
: > "$LOG"
run_new rp-clideny --repo "$CUSTOM_REPOS/rp-clideny" <<< $'no\n' \
  >"$WORK/rp-clideny.out" 2>"$WORK/rp-clideny.err" || true
assert_no_config rp-clideny
grep -q "Aborted" "$WORK/rp-clideny.out" || fail "CLI --repo deny: should print Aborted"
pass "CLI --repo outside default can be denied (no mount)"

# (o2) CLI --repo outside default, non-interactive (EOF) + no --yes => aborted.
: > "$LOG"
run_new rp-clieof --repo "$CUSTOM_REPOS/rp-clieof" </dev/null \
  >"$WORK/rp-clieof.out" 2>"$WORK/rp-clieof.err" || true
assert_no_config rp-clieof
grep -q "Aborted" "$WORK/rp-clieof.out" || fail "CLI --repo non-interactive: should abort with a message"
pass "CLI --repo non-interactive (no --yes) aborts with a message"

# (p) CLI --repo INSIDE the default repos dir => no gate, no prompt.
: > "$LOG"
run_new rp-cliinside --repo "$WORK/home/repos/cli-inside" </dev/null \
  >"$WORK/rp-cliinside.out" 2>"$WORK/rp-cliinside.err" \
  || fail "CLI --repo inside repos dir should need no confirmation"
if grep -qi "outside the default repos directory" "$WORK/rp-cliinside.out"; then
  fail "CLI --repo inside the repos dir must not prompt"
fi
load_cfg rp-cliinside
pass "CLI --repo inside default repos dir needs no confirmation"

# (p2) CLI --repo resolving to the repos root is rejected outright.
: > "$LOG"
if run_new rp-cliroot --repo "$WORK/home/repos" </dev/null >"$WORK/rp-cliroot.out" 2>"$WORK/rp-cliroot.err"; then
  fail "CLI --repo to the repos root should be rejected outright"
fi
assert_no_config rp-cliroot
grep -qi 'repos root' "$WORK/rp-cliroot.err" \
  || fail "CLI --repo repos-root rejection should explain the broad-mount rule (got: $(cat "$WORK/rp-cliroot.err" 2>/dev/null))"
pass "CLI --repo to the repos root rejected outright"

# (p3) CLI --repo resolving to an ancestor of the repos root is rejected outright.
: > "$LOG"
mkdir -p "$WORK/outer/home/repos"
mkdir -p "$WORK/outer/home/.config/dc-enclave/team/overlays" \
         "$WORK/outer/home/.config/dc-enclave/team/container-recipes" \
         "$WORK/outer/home/.config/dc-enclave/user/overlays" \
         "$WORK/outer/home/.config/dc-enclave/user/container-recipes"
cat > "$WORK/outer/home/.config/dc-enclave/config" <<EOF
DC_TEAM_DIR="$WORK/outer/home/.config/dc-enclave/team"
DC_USER_DIR="$WORK/outer/home/.config/dc-enclave/user"
EOF
if HOME="$WORK/outer/home" DC_REPOS_DIR="$WORK/outer/home/repos" TZ=UTC \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" DC_STUB_NETWORKS="$NETWORKS" \
  PATH="$STUB_DIR:$ORIG_PATH" CONTAINER_BACKEND=docker \
  bash "$ROOT_DIR/scripts/new-container.sh" rp-cliancestor --repo "$WORK/outer" </dev/null \
  >"$WORK/rp-cliancestor.out" 2>"$WORK/rp-cliancestor.err"; then
  fail "CLI --repo to an ancestor of the repos root should be rejected outright"
fi
grep -qi 'parent of it' "$WORK/rp-cliancestor.err" \
  || fail "CLI --repo ancestor rejection should explain the broad-mount rule (got: $(cat "$WORK/rp-cliancestor.err" 2>/dev/null))"
pass "CLI --repo to an ancestor of the repos root rejected outright"

# (q) CLI --repo requires a non-empty repo path.
: > "$LOG"
if run_new rp-cliempty --repo "" </dev/null >"$WORK/rp-cliempty.out" 2>"$WORK/rp-cliempty.err"; then
  fail "CLI --repo with an empty spec should be rejected"
fi
assert_no_config rp-cliempty
grep -qi 'repo spec' "$WORK/rp-cliempty.err" \
  || fail "CLI --repo empty-spec rejection should mention the repo spec requirement (got: $(cat "$WORK/rp-cliempty.err" 2>/dev/null))"
pass "CLI --repo empty spec rejected"

# (q2) CLI --repo name= requires a non-empty path component too.
: > "$LOG"
if run_new rp-cliemptypath --repo 'web=' </dev/null >"$WORK/rp-cliemptypath.out" 2>"$WORK/rp-cliemptypath.err"; then
  fail "CLI --repo name= should be rejected"
fi
assert_no_config rp-cliemptypath
grep -qi 'non-empty path' "$WORK/rp-cliemptypath.err" \
  || fail "CLI --repo name= rejection should mention the empty path (got: $(cat "$WORK/rp-cliemptypath.err" 2>/dev/null))"
pass "CLI --repo name= rejected"

# (r) A safe-looking symlink path that resolves to an unsafe path is rejected.
mkdir -p "$WORK/home/repos/unsafe:semicolon-root"
ln -s "$WORK/home/repos/unsafe:semicolon-root" "$WORK/home/repos/safelink"
: > "$LOG"
if run_new rp-clisafelink --repo "$WORK/home/repos/safelink/child" </dev/null \
  >"$WORK/rp-clisafelink.out" 2>"$WORK/rp-clisafelink.err"; then
  fail "CLI --repo resolving through a symlink to an unsafe path should be rejected"
fi
assert_no_config rp-clisafelink
grep -qi 'unsafe for a bind-mount source' "$WORK/rp-clisafelink.err" \
  || fail "resolved-path unsafe-char rejection should explain the bind-mount rule (got: $(cat "$WORK/rp-clisafelink.err" 2>/dev/null))"
pass "CLI --repo rejects symlink-resolved unsafe paths"

echo ""
echo "All recipe checks passed."
