#!/usr/bin/env bash
# =============================================================================
# tests/contract/extensions.sh - Stubbed-backend `dce extensions` coverage.
#
# Drives scripts/extensions.sh end-to-end with fakes of docker (backend_exec +
# predicates) and the host `code` binary. Covers: show/list/host/available/diff
# outputs, capture (explicit IDs + --all), merge de-dup + comment preservation,
# --user/--team targeting, scope validation, unknown-editor rejection, apple
# refusal, and usage failures.
#
# Pure host-side helper coverage (resolve/parse/format/namespace/set math) lives
# in tests/unit/extensions-helpers.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DC_BIN="$ROOT_DIR/scripts/dce"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ---------------------------------------------------------------------------
# Stub harness: fake HOME + global config + stub docker + stub host `code`.
# ---------------------------------------------------------------------------
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"
chmod 600 "$DC_ROOT/config"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
DOCKER_LOG="$WORK/docker.log"
RUNNING_FILE="$WORK/running.lst"
CONTAINERS_FILE="$WORK/containers.lst"
CONTAINER_EXT_FILE="$WORK/container-ext.lst"   # extensions `installed` in container
HOST_CODE_LOG="$WORK/host-code.log"
HOST_EXT_FILE="$WORK/host-ext.lst"             # extensions on host editor
: > "$DOCKER_LOG"
: > "$RUNNING_FILE"
: > "$CONTAINERS_FILE"
: > "$HOST_CODE_LOG"

# Fake docker: answers the predicates extensions.sh + container-backend use.
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_run="${DC_STUB_RUNNING:?}"
_ext="${DC_STUB_CONTAINER_EXT:?}"
printf 'CALL docker %s\n' "$*" >> "$_log"

case "${1:-}" in
  info)
    # backend_system_info reachability probe.
    exit 0
    ;;
  ps)
    # backend_is_running uses: docker ps --format '{{.Names}}'
    any=""
    for _a in "$@"; do [[ "$_a" == "-a" ]] && any=1; done
    if [[ -n "$any" ]]; then
      [[ -f "${DC_STUB_CONTAINERS:-/dev/null}" ]] && cat "${DC_STUB_CONTAINERS}" 2>/dev/null || true
    else
      [[ -f "$_run" ]] && cat "$_run" 2>/dev/null || true
    fi
    exit 0
    ;;
  exec)
    # dce_ext_list_installed / _install_one resolve the in-container `code` CLI
    # first (the VS Code Server binary is not on the default PATH docker-exec
    # uses), then invoke it. The stub recognizes both phases:
    #   resolver:  docker exec <name> sh -c '...command -v code...'
    #   list:      docker exec <name> <bin> --list-extensions
    #   install:   docker exec <name> <bin> --install-extension <id>
    _all="$*"
    if [[ "$3" == "sh" && "$4" == "-c" && "$_all" == *"command -v code"* ]]; then
      if [[ "${DC_STUB_CODE_ABSENT:-0}" == "1" ]]; then
        exit 127
      fi
      if [[ "${DC_STUB_RESOLVE_BIN_EMPTY:-0}" == "1" ]]; then
        exit 1
      fi
      if [[ "${DC_STUB_RESOLVE_BIN_REMOTECLI_NOSIBLING:-0}" == "1" ]]; then
        # Simulate PATH resolving to remote-cli/code, but only code-server exists
        # in canonical locations. The resolver must skip the wrapper and keep
        # searching until it finds a usable binary path.
        printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code-server'
        exit 0
      fi
      if [[ "${DC_STUB_RESOLVE_BIN_REMOTECLI:-0}" == "1" ]]; then
        printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code'
        exit 0
      fi
      printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code'
      exit 0
    fi
    if [[ "${@: -1}" == "--list-extensions" ]]; then
      if [[ "${DC_STUB_CODE_ABSENT:-0}" == "1" || "${DC_STUB_LIST_FAIL:-0}" == "1" ]]; then
        exit 127
      fi
      [[ -f "$_ext" ]] && cat "$_ext" 2>/dev/null || true
      exit 0
    fi
    if [[ "${@: -2:1}" == "--install-extension" ]]; then
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"

# Fake host `code`: `code --list-extensions` emits HOST_EXT_FILE; other calls
# are logged (and succeed) so the lib's macOS-app fallback never triggers.
cat > "$STUB_DIR/code" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_HOST_CODE_LOG:?}"
_ext="${DC_STUB_HOST_EXT:?}"
printf 'CALL code %s\n' "$*" >> "$_log"
if [[ "${1:-}" == "--list-extensions" ]]; then
  [[ -f "$_ext" ]] && cat "$_ext" 2>/dev/null || true
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/code"

ORIG_PATH="$PATH"

# Build a minimal project config (mirrors editor.sh's fixture + scopes).
make_project() {
  local project="$1" scopes="${2:-}" running="${3:-}"
  local cfg_dir="$HOME/.config/dce-enclave/$project"
  local repos="$WORK/repos/$project"
  mkdir -p "$cfg_dir" "$repos"
  chmod 700 "$cfg_dir"
  cat > "$cfg_dir/config" <<CFG
CONTAINER_PROJECT="$project"
CONTAINER_BACKEND="docker"
CONTAINER_GIT_HOST="github"
CONTAINER_IMAGE="dce-base:latest"
CONTAINER_OVERLAY_SCOPES="$scopes"
REPOS_DIR="$repos"
SECRET_DIR="$cfg_dir"
SSH_KEY_PATH="$cfg_dir/ssh_key"
TOKEN_FILE="$cfg_dir/github-token"
NPMRC_PATH="$cfg_dir/.npmrc"
PORTS=()
CONTAINER_HIDDEN_PATHS=()
CONTAINER_NETWORKS=()
CFG
  chmod 600 "$cfg_dir/config"
  grep -qxF -- "$project" "$CONTAINERS_FILE" 2>/dev/null || printf '%s\n' "$project" >> "$CONTAINERS_FILE"
  if [[ "$running" == "running" ]]; then
    grep -qxF -- "$project" "$RUNNING_FILE" 2>/dev/null || printf '%s\n' "$project" >> "$RUNNING_FILE"
  fi
}

# Run `dce extensions ...` with all stubs wired.
run_ext() {
  DC_STUB_LOG="$DOCKER_LOG" \
  DC_STUB_RUNNING="$RUNNING_FILE" \
  DC_STUB_CONTAINERS="$CONTAINERS_FILE" \
  DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_HOST_CODE_LOG="$HOST_CODE_LOG" \
  DC_STUB_HOST_EXT="$HOST_EXT_FILE" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="docker" \
  HOME="$WORK/home" \
  "$DC_BIN" extensions "$@"
}

# Seed manifest fixtures (default: user namespace).
seed_manifest() {
  local side="$1" scope="$2" content="$3"
  local root
  [[ "$side" == "team" ]] && root="$TEAM_DIR" || root="$USER_DIR"
  local dir="$root/extensions/vscode"
  mkdir -p "$dir"
  printf '%b' "$content" > "$dir/$scope.txt"
}

# ===========================================================================
# Setup: project "alpha" with scope nodejs; host + container extension state.
# ===========================================================================
make_project "alpha" "nodejs" running
printf 'container.only\nshared.both\n' > "$CONTAINER_EXT_FILE"   # installed in container
printf 'host.only\nshared.both\n'     > "$HOST_EXT_FILE"          # installed on host
seed_manifest user all "all.user\nshared.declared\n"
seed_manifest user nodejs "# node scope\nnode.user\nshared.declared\n"

# ===========================================================================
# 1. show: merged effective manifest set (all + nodejs, user only).
# ===========================================================================
OUT="$(run_ext show alpha)"
EXP=$'all.user\nshared.declared\nnode.user'
[[ "$OUT" == "$EXP" ]] || fail "show: got [$OUT] expected [$EXP]"
# show --format json
OUT_JSON="$(run_ext show alpha --format json)"
[[ "$OUT_JSON" == '["all.user","shared.declared","node.user"]' ]] \
  || fail "show --format json: got [$OUT_JSON]"
pass "show: merged effective set (ids + json)"

# show is static (manifest-only) and must not touch the container backend.
: > "$DOCKER_LOG"
OUT="$(run_ext show alpha)"
[[ "$OUT" == "$EXP" ]] || fail "show static: got [$OUT] expected [$EXP]"
[[ ! -s "$DOCKER_LOG" ]] \
  || fail "show static: must not call backend CLI (log: $(cat "$DOCKER_LOG"))"
pass "show: backend-agnostic (no backend CLI calls)"

# ===========================================================================
# 2. list: installed in the container.
# ===========================================================================
OUT="$(run_ext list alpha)"
EXP=$'container.only\nshared.both'
[[ "$OUT" == "$EXP" ]] || fail "list: got [$OUT] expected [$EXP]"
pass "list: container installed set"

# Regression: `code` is NOT on the bare docker-exec PATH (VS Code Server only
# puts it on the integrated terminal's PATH). The dispatch MUST resolve the
# binary via the VS Code Server install path before invoking it, so list works
# whenever the user has attached VS Code at least once. Assert both phases land
# in the docker call log: the resolver (sh -c '...command -v code...') and the
# subsequent exec of the resolved path with --list-extensions.
grep -Fq 'command -v code' "$DOCKER_LOG" \
  || fail "list: missing resolver call (docker log):\n$(cat "$DOCKER_LOG")"
grep -Fq -- '--list-extensions' "$DOCKER_LOG" \
  || fail "list: missing --list-extensions call (docker log):\n$(cat "$DOCKER_LOG")"
pass "list: resolves in-container code via VS Code Server path"

# Resolver-empty regression: if PATH lookup fails and the resolver cannot find
# ~/.vscode-server/bin/*/bin/code either, list must fail with actionable
# guidance (not claim the host `code` binary is sufficient).
if DC_STUB_RESOLVE_BIN_EMPTY=1 run_ext list alpha >"$WORK/list-empty.out" 2>"$WORK/list-empty.err"; then
  fail "list: must fail when resolver cannot find any in-container code binary"
fi
grep -Fq 'Could not resolve a VS Code Server' "$WORK/list-empty.err" \
  || fail "list resolver-empty: missing VS Code Server guidance\n$(cat "$WORK/list-empty.err")"
pass "list: resolver-empty path returns actionable error"

# Resolver fallback should accept remote-cli layout too (newer VS Code server
# layouts can expose PATH as .../bin/remote-cli/code. The resolver must map
# that wrapper to a sibling executable usable from plain docker exec.
if ! DC_STUB_RESOLVE_BIN_REMOTECLI=1 run_ext list alpha >"$WORK/list-rcli.out" 2>"$WORK/list-rcli.err"; then
  fail "list: remote-cli resolver path should succeed\n$(cat "$WORK/list-rcli.err")"
fi
grep -Fq 'container.only' "$WORK/list-rcli.out" \
  || fail "list remote-cli: expected extension output missing\n$(cat "$WORK/list-rcli.out")"
pass "list: resolver accepts remote-cli code path"

# PATH remote-cli wrapper with no sibling executable is unusable from host exec;
# resolver must continue searching canonical server paths and still succeed.
if ! DC_STUB_RESOLVE_BIN_REMOTECLI_NOSIBLING=1 run_ext list alpha >"$WORK/list-rcli2.out" 2>"$WORK/list-rcli2.err"; then
  fail "list: remote-cli-no-sibling should fall back to canonical paths\n$(cat "$WORK/list-rcli2.err")"
fi
grep -Fq 'container.only' "$WORK/list-rcli2.out" \
  || fail "list remote-cli-no-sibling: expected extension output missing\n$(cat "$WORK/list-rcli2.out")"
pass "list: remote-cli wrapper fallback finds usable server binary"

# ===========================================================================
# 3. host: installed on the host editor.
# ===========================================================================
OUT="$(run_ext host)"
EXP=$'host.only\nshared.both'
[[ "$OUT" == "$EXP" ]] || fail "host: got [$OUT] expected [$EXP]"
pass "host: host installed set"

# host takes no project/ids.
if run_ext host alpha >/dev/null 2>&1; then
  fail "host: must reject an unexpected project positional"
fi
if run_ext host alpha beta >/dev/null 2>&1; then
  fail "host: must reject unexpected extra positional args"
fi
pass "host: rejects unexpected positional arguments"

# Host lookup should honor DCE_EDITOR_BIN override even when `code` is on PATH.
cat > "$STUB_DIR/code-alt" <<'STUB'
#!/usr/bin/env bash
printf 'alt.only\n'
STUB
chmod +x "$STUB_DIR/code-alt"
OUT="$(DCE_EDITOR_BIN="$STUB_DIR/code-alt" run_ext host)"
[[ "$OUT" == "alt.only" ]] || fail "host override: expected [alt.only] got [$OUT]"
pass "host: DCE_EDITOR_BIN override honored"

# A non-executable override must NOT silently fall back to PATH `code`: the user
# told us exactly where the binary is, so a broken setting should surface, not mask.
NONEXEC="$WORK/nonexec-code"
printf '#!/usr/bin/env bash\n' > "$NONEXEC"   # exists but not +x
if DCE_EDITOR_BIN="$NONEXEC" run_ext host >/dev/null 2>&1; then
  fail "host: non-executable DCE_EDITOR_BIN must error, not fall back to PATH"
fi
pass "host: non-executable DCE_EDITOR_BIN errors (no silent PATH fallback)"

# ===========================================================================
# 4. available: host minus container.
# ===========================================================================
OUT="$(run_ext available alpha)"
[[ "$OUT" == "host.only" ]] || fail "available: got [$OUT] expected [host.only]"
pass "available: host minus container"

# ===========================================================================
# 5. diff: both directions (installed-not-declared, declared-not-installed).
# ===========================================================================
OUT="$(run_ext diff alpha)"
# Undeclared (installed, not in declared set): container.only, shared.both
grep -Fq 'container.only' <<<"$OUT" || fail "diff: missing undeclared container.only"
grep -Fq 'shared.both' <<<"$OUT" || fail "diff: missing undeclared shared.both"
# Missing (declared, not installed): all.user, shared.declared, node.user
grep -Fq 'all.user' <<<"$OUT" || fail "diff: missing declared all.user"
grep -Fq 'shared.declared' <<<"$OUT" || fail "diff: missing declared shared.declared"
# Capture hint names the undeclared id.
grep -Fq 'container.only' <<<"$OUT" || true
grep -Fqi 'capture' <<<"$OUT" || fail "diff: must point at capture"
pass "diff: reports both drift directions + capture hint"

# ===========================================================================
# 6. capture: explicit IDs merge into user manifest (de-dup, comments kept).
# ===========================================================================
# Reset the nodejs user manifest to one with an existing comment + an ID.
seed_manifest user nodejs "# header comment\nexisting.id\n"
OUT="$(run_ext capture alpha --scope nodejs new.id existing.id other.new 2>&1)" || fail "capture explicit exited non-zero: $OUT"
FILE="$USER_DIR/extensions/vscode/nodejs.txt"
[[ -f "$FILE" ]] || fail "capture: manifest file not created at $FILE"
# Existing content (comment + existing.id) preserved verbatim.
grep -Fq '# header comment' "$FILE" || fail "capture: existing comment dropped"
grep -Fq 'existing.id' "$FILE" || fail "capture: existing id dropped"
# existing.id NOT duplicated.
[[ "$(grep -c '^existing.id$' "$FILE")" -eq 1 ]] || fail "capture: existing.id duplicated"
# New IDs appended, sorted.
newblock="$(grep -E '^(new\.id|other\.new)$' "$FILE" | sort | tr '\n' ',')"
[[ "$newblock" == "new.id,other.new," ]] || fail "capture: new ids not appended sorted (got [$newblock])"
# No extra blank line should be injected between existing content and appends.
[[ "$(grep -c '^$' "$FILE")" -eq 0 ]] || fail "capture: injected unexpected blank line(s)"
pass "capture: explicit IDs merge, de-dup, preserve comments, append sorted"

# capture with explicit IDs is static and must not touch the backend.
: > "$DOCKER_LOG"
OUT="$(run_ext capture alpha --scope staticscope static.id 2>&1)" \
  || fail "capture static exited non-zero: $OUT"
SFILE="$USER_DIR/extensions/vscode/staticscope.txt"
grep -Fq 'static.id' "$SFILE" || fail "capture static: static.id missing from $SFILE"
[[ ! -s "$DOCKER_LOG" ]] \
  || fail "capture static: must not call backend CLI (log: $(cat "$DOCKER_LOG"))"
pass "capture explicit IDs: backend-agnostic (no backend CLI calls)"

# ===========================================================================
# 7. capture --all: snapshot the container's installed set.
# ===========================================================================
seed_manifest team all ""   # ensure a clean team all target
OUT="$(run_ext capture alpha --scope all --all --team 2>&1)" \
  || fail "capture --all exited non-zero: $OUT"
TFILE="$TEAM_DIR/extensions/vscode/all.txt"
grep -Fq 'container.only' "$TFILE" || fail "capture --all: container.only missing"
grep -Fq 'shared.both' "$TFILE" || fail "capture --all: shared.both missing"
pass "capture --all: snapshots container installed set into --team manifest"

# ===========================================================================
# 8. capture: refuses bulk-dump with no IDs and no --all.
# ===========================================================================
if run_ext capture alpha --scope nodejs >/dev/null 2>&1; then
  fail "capture: must refuse when no IDs and no --all given"
fi
pass "capture: refuses empty (no IDs / no --all)"

# capture's source selector is XOR: --all cannot be combined with explicit IDs.
if run_ext capture alpha --scope nodejs --all explicit.id >/dev/null 2>&1; then
  fail "capture: --all and explicit IDs together must be rejected"
fi
pass "capture: rejects --all combined with explicit IDs"

# ===========================================================================
# 8b. capture: --user and --team are mutually exclusive.
# ===========================================================================
if run_ext capture alpha --scope nodejs --user --team good.id >/dev/null 2>&1; then
  fail "capture: --user and --team together must be rejected"
fi
pass "capture: --user/--team mutually exclusive"

# ===========================================================================
# 9. capture: validates the scope name.
# ===========================================================================
if run_ext capture alpha --scope "Bad Scope" some.id >/dev/null 2>&1; then
  fail "capture: invalid scope name must be rejected"
fi
pass "capture: invalid scope name rejected"

# ===========================================================================
# 9b. capture: rejects malformed extension IDs (protects manifest integrity).
# ===========================================================================
if run_ext capture alpha --scope nodejs "bad id with space" >/dev/null 2>&1; then
  fail "capture: malformed id (space) must be rejected"
fi
if run_ext capture alpha --scope nodejs "nohostdot" >/dev/null 2>&1; then
  fail "capture: malformed id (missing dot) must be rejected"
fi
# A valid ID still succeeds.
seed_manifest user nodejs ""   # clean slate
run_ext capture alpha --scope nodejs "good.publisher" >/dev/null 2>&1 \
  || fail "capture: valid publisher.name id must succeed"
pass "capture: rejects malformed ids, accepts valid publisher.name"

# ===========================================================================
# 10. unknown editor -> error.
# ===========================================================================
if run_ext --editor zed show alpha >/dev/null 2>&1; then
  fail "extensions: unknown editor must error"
fi
pass "unknown editor rejected"

# ===========================================================================
# 11. apple backend: container-derived ops refuse; static ops work.
# ===========================================================================
make_project "beta" "nodejs" running
# Rewrite beta's backend to apple.
sed -i.bak 's/CONTAINER_BACKEND="docker"/CONTAINER_BACKEND="apple"/' "$HOME/.config/dce-enclave/beta/config"
rm -f "$HOME/.config/dce-enclave/beta/config.bak"
# apple has no docker stub relevant; `dce extensions list beta` must refuse.
if DC_STUB_RUNNING="$RUNNING_FILE" DC_STUB_LOG="$DOCKER_LOG" \
   PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" \
   "$DC_BIN" extensions list beta >/dev/null 2>&1; then
  fail "extensions list on apple must refuse"
fi
# show is static -> works even on apple.
if ! DC_STUB_RUNNING="$RUNNING_FILE" DC_STUB_LOG="$DOCKER_LOG" \
     PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" \
     "$DC_BIN" extensions show beta >/dev/null 2>&1; then
  fail "extensions show on apple must work (static op)"
fi
pass "apple: container-derived ops refuse; static show works"

# ===========================================================================
# 12. container not running -> error (no auto-start).
# ===========================================================================
make_project "gamma" "nodejs"   # exists, not running
if run_ext list gamma >/dev/null 2>&1; then
  fail "list: must fail when container not running (no auto-start)"
fi
pass "list: not-running -> error (no auto-start)"

# diff is a drift probe: skip cleanly (exit 0) when prerequisites are unmet.
OUT="$(run_ext diff gamma 2>&1)" || fail "diff (not running) must skip with exit 0"
grep -Fqi 'skip' <<<"$OUT" || fail "diff (not running): missing skip message"
pass "diff: not-running -> clean skip"

# code absent in-container: diff must skip with guidance, not hard-fail.
OUT="$(DC_STUB_CODE_ABSENT=1 run_ext diff alpha 2>&1)" \
  || fail "diff (code absent) must skip with exit 0"
grep -Fqi 'skip' <<<"$OUT" || fail "diff (code absent): missing skip message"
pass "diff: code-absent -> clean skip"

# apple backend: diff must skip cleanly (host/static guidance path).
OUT="$(DC_STUB_RUNNING="$RUNNING_FILE" DC_STUB_LOG="$DOCKER_LOG" \
   PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" \
   "$DC_BIN" extensions diff beta 2>&1)" \
  || fail "diff (apple) must skip with exit 0"
grep -Fqi 'skip' <<<"$OUT" || fail "diff (apple): missing skip message"
pass "diff: apple backend -> clean skip"

# ===========================================================================
# 13. missing project arg -> usage failure.
# ===========================================================================
if run_ext show >/dev/null 2>&1; then
  fail "show: missing project must fail"
fi
pass "missing project arg -> usage failure"

# ===========================================================================
# 14. --help / no subcommand -> usage, exit 0.
# ===========================================================================
run_ext --help >/dev/null || fail "--help must exit 0"
run_ext >/dev/null 2>&1 || fail "no subcommand must exit 0 (usage)"
# Help must win even when other flags are present (parser should not try to
# validate semantic flag combinations before honoring --help).
run_ext --help --user --team >/dev/null 2>&1 || fail "--help with extra flags must still exit 0"
pass "--help / no subcommand -> usage exit 0"

# ===========================================================================
# 15. dce_ext_check_runtime_drift: match / drift / absent / skip tokens.
# (lib helper exercised directly with the stubbed backend; it backs the doctor
#  runtime-drift probe and the rebuild-container pre-destroy warning.)
# ===========================================================================
# Source the libs the helper needs (container-backend for backend_use/is_running).
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/container-backend.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/extensions.sh"

with_backend() {
  export DC_STUB_LOG="$DOCKER_LOG" \
         DC_STUB_RUNNING="$RUNNING_FILE" \
         DC_STUB_CONTAINERS="$CONTAINERS_FILE" \
         DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE"
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="docker" \
  HOME="$WORK/home" \
  backend_use docker 2>/dev/null
}

# match: installed == declared. Use a dedicated project whose manifests union
# to exactly the installed set. Clear any all.txt left by earlier capture tests
# so resolve_set is fully under this block's control.
make_project "rtdrift" "nodejs" running
mkdir -p "$TEAM_DIR/extensions/vscode" "$USER_DIR/extensions/vscode"
: > "$TEAM_DIR/extensions/vscode/all.txt"
printf 'a.b\n' > "$USER_DIR/extensions/vscode/all.txt"
printf 'c.d\n' > "$USER_DIR/extensions/vscode/nodejs.txt"
printf 'a.b\nc.d\n' > "$CONTAINER_EXT_FILE"
with_backend
TOK="$(with_backend; PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" dce_ext_check_runtime_drift rtdrift vscode "$TEAM_DIR" "$USER_DIR" "nodejs")"
[[ "$TOK" == "match" ]] || fail "runtime_drift(match): expected match got [$TOK]"

# drift: install an extra extension in the container not in either manifest.
printf 'a.b\nc.d\nextra.installed\n' > "$CONTAINER_EXT_FILE"
TOK="$(with_backend; PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" dce_ext_check_runtime_drift rtdrift vscode "$TEAM_DIR" "$USER_DIR" "nodejs")"
[[ "$TOK" == "drift" ]] || fail "runtime_drift(drift): expected drift got [$TOK]"

# absent: running + adopted, but `code` missing inside the container.
TOK="$(DC_STUB_CODE_ABSENT=1 with_backend; DC_STUB_CODE_ABSENT=1 PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" dce_ext_check_runtime_drift rtdrift vscode "$TEAM_DIR" "$USER_DIR" "nodejs")"
[[ "$TOK" == "absent" ]] || fail "runtime_drift(absent/code-missing): expected absent got [$TOK]"

# skip: container not running (gamma exists, not running).
TOK="$(with_backend; PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" dce_ext_check_runtime_drift gamma vscode "$TEAM_DIR" "$USER_DIR" "nodejs")"
[[ "$TOK" == "skip" ]] || fail "runtime_drift(skip/not-running): expected skip got [$TOK]"

# skip: pre-adoption (no manifests for an unscoped project). Remove the all.txt
# files left by earlier tests so an empty-scope project is genuinely
# pre-adoption (manifests_exist only checks "all" for empty scopes).
make_project "delta" "" running
rm -f "$TEAM_DIR/extensions/vscode/all.txt" "$USER_DIR/extensions/vscode/all.txt"
TOK="$(with_backend; PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" dce_ext_check_runtime_drift delta vscode "$TEAM_DIR" "$USER_DIR" "")"
[[ "$TOK" == "skip" ]] || fail "runtime_drift(skip/pre-adoption): expected skip got [$TOK]"

# skip: apple backend (non-docker-compatible). beta is apple. The helper's
# contract is "caller has selected the backend via backend_use"; here we select
# apple directly via DEV_CONTAINERS_BACKEND (the post-backend_use state) rather
# than calling `backend_use apple`, which would fail: no `container` CLI stub is
# on PATH, so it returns 1 and leaves the backend unset, causing backend_name to
# auto-detect the docker stub and compute drift instead of skipping.
TOK="$(DC_STUB_RUNNING="$RUNNING_FILE" DC_STUB_LOG="$DOCKER_LOG" \
  PATH="$STUB_DIR:$ORIG_PATH" HOME="$WORK/home" \
  DEV_CONTAINERS_BACKEND=apple \
  dce_ext_check_runtime_drift beta vscode "$TEAM_DIR" "$USER_DIR" "nodejs")"
[[ "$TOK" == "skip" ]] || fail "runtime_drift(skip/apple): expected skip got [$TOK]"
pass "dce_ext_check_runtime_drift: match/drift/absent/skip tokens (running/pre-adoption/apple)"

echo ""
echo "All extensions contract checks passed."
