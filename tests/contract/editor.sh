#!/usr/bin/env bash
# =============================================================================
# tests/contract/editor.sh - Stubbed-backend editor launcher coverage.
#
# Exercises scripts/editor.sh end-to-end without a real daemon or real editor
# binary: stub docker (for backend_is_running / start.sh's calls) and stub
# `code` (to capture the launch argv). Apple refusal, selection precedence,
# URI shape, and the start-if-not-running branch are all covered.
#
# Section 16 covers the detached first-open extension watcher
# (plans/extensions-first-open-convergence.md): spawn + notice, convergence,
# timeout, single-flight, mid-watch stop, stale-lock takeover, and the
# pre-adoption no-op. Its stubs add a file-backed probe counter
# (DC_STUB_EXT_SERVER_APPEAR_AFTER) and its sections use bounded-poll helpers
# (wait_for_pattern / wait_watcher_done) + tiny watcher intervals so no
# watcher can outlive the section that spawned it.
#
# Pure host-side helper coverage (id normalization, selection, URI encoder,
# binary discovery contract) lives in tests/unit/editor-helpers.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Load the provider registry so credential test configs can be built data-driven
# (token filename, sentinel, env-var name per provider), mirroring
# tests/contract/security-token-argv.sh.
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/git-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ===========================================================================
# Stub harness: fake docker + fake editor binary.
# ===========================================================================
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
# Create both the Linux (.config/Code/User) and macOS (Library/Application
# Support/Code/User) VS Code user dirs so the named-attach seed
# (dce_vscode_remote_containers_storage_candidates, lib/vscode.sh:35-48) finds a
# live parent on either platform; otherwise nameConfig assertions are
# macOS-only failures unrelated to the behavior under test.
mkdir -p "$HOME/.config/Code/User" "$HOME/Library/Application Support/Code/User"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"
chmod 600 "$DC_ROOT/config"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
DOCKER_LOG="$WORK/docker.log"
RUNNING_FILE="$WORK/running.lst"     # names currently "running", one per line
CONTAINERS_FILE="$WORK/containers.lst"  # names that exist (any state)
CODE_LOG="$WORK/code.log"            # argv of each editor invocation
: > "$DOCKER_LOG"
: > "$CODE_LOG"
: > "$RUNNING_FILE"
: > "$CONTAINERS_FILE"

# ---------------------------------------------------------------------------
# Fake docker: answers the predicates editor.sh + start.sh exercise.
# Stateful: a `start NAME` flips NAME into the running list so a subsequent
# backend_is_running sees it as up.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_run="${DC_STUB_RUNNING:?}"
_ctrs="${DC_STUB_CONTAINERS:?}"
_have_creds_env="${DC_STUB_CONTAINER_CREDS+x}"
_creds="${DC_STUB_CONTAINER_CREDS-}"
printf 'CALL docker %s\n' "$*" >> "$_log"

# Drain stdin only for interactive exec calls (start.sh re-injects the SSH key
# via `docker exec -i`; even though we don't set SSH_KEY_PATH in the test, the
# stub stays stdin-safe for any future caller).
_drain_stdin=false
for _a in "$@"; do
  case "$_a" in
    -i|--interactive|-i*|-it) _drain_stdin=true ;;
  esac
done

case "${1:-}" in
  info)
    # backend_system_start probes reachability via `docker info`.
    exit 0
    ;;
  ps)
    # backend_is_running uses: docker ps --format '{{.Names}}'
    # backend_exists (any state) uses: docker ps -a --format '{{.Names}}'
    any=""
    for _a in "$@"; do [[ "$_a" == "-a" ]] && any=1; done
    if [[ -n "$any" ]]; then
      [[ -f "$_ctrs" ]] && cat "$_ctrs"
    else
      [[ -f "$_run" ]] && cat "$_run"
    fi
    exit 0
    ;;
  start)
    # backend_start: move the named container into "running".
    _name="${@: -1}"
    grep -qxF -- "$_name" "$_run" 2>/dev/null || printf '%s\n' "$_name" >> "$_run"
    exit 0
    ;;
  create)
    # editor.sh never calls create; start.sh doesn't either. Accept silently.
    exit 0
    ;;
  exec)
    # Optional credential-file state simulation for drift warning coverage. When
    # DC_STUB_CONTAINER_CREDS is set by the caller, answer the ~/.git-credentials
    # existence/read probes the same way tests/unit/git-credentials.sh does.
    if [[ -n "$_have_creds_env" ]]; then
      if [[ "$*" == *'cat ~/.git-credentials'* ]]; then
        printf '%s' "$_creds"
        exit 0
      fi
      if [[ "$*" == *'test -f ~/.git-credentials'* ]]; then
        [[ -n "$_creds" ]] && exit 0 || exit 1
      fi
    fi
    # start.sh's git-credential wiring issues several `docker exec ... git
    # config --global --unset-all ...` calls (all best-effort, all tolerate
    # failure). With TOKEN_FILE/SSH_KEY_PATH unset in the test config the
    # method is "none", so the calls are all unsets; succeed silently.
    $_drain_stdin && cat > /dev/null

    # --- attach-mode extension enforcement probes (plans/extensions.md §6) ---
    # _dce_ext_vscode_container_bin resolver: sh -c '...command -v code...'.
    #
    # DC_STUB_EXT_SERVER_APPEAR_AFTER=<n> (with DC_STUB_EXT_PROBE_COUNT=<file>)
    # simulates a VS Code Server that is injected only after the nth
    # CLI-resolution probe -- what a first-ever attach looks like while the
    # detached watcher polls. The counter must be a FILE: every probe is a
    # separate stub process. A missing/unreadable/unwritable counter degrades
    # to count 0 (the probe still advances in memory) instead of erroring.
    # APPEAR_AFTER unset -> exactly the old behavior, including the
    # DC_STUB_EXT_SERVER_ABSENT switch below.
    if [[ "$3" == "sh" && "$4" == "-c" && "$*" == *"command -v code"* ]]; then
      if [[ -n "${DC_STUB_EXT_SERVER_APPEAR_AFTER:-}" ]]; then
        _probe_count=0
        if [[ -n "${DC_STUB_EXT_PROBE_COUNT:-}" && -r "$DC_STUB_EXT_PROBE_COUNT" ]]; then
          _probe_count="$(cat "$DC_STUB_EXT_PROBE_COUNT" 2>/dev/null || printf '0')"
          case "$_probe_count" in '' | *[!0-9]*) _probe_count=0 ;; esac
        fi
        _probe_count=$((_probe_count + 1))
        if [[ -n "${DC_STUB_EXT_PROBE_COUNT:-}" ]]; then
          printf '%s\n' "$_probe_count" > "$DC_STUB_EXT_PROBE_COUNT" 2>/dev/null || true
        fi
        if [[ "$_probe_count" -le "$DC_STUB_EXT_SERVER_APPEAR_AFTER" ]]; then
          exit 1
        fi
        printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code-server'
        exit 0
      fi
      if [[ "${DC_STUB_EXT_SERVER_ABSENT:-0}" == "1" ]]; then
        exit 1
      fi
      printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code-server'
      exit 0
    fi
    # dce_ext_list_installed: <bin> --list-extensions.
    if [[ "${@: -1}" == "--list-extensions" ]]; then
      [[ -f "${DC_STUB_CONTAINER_EXT:-}" ]] && cat "${DC_STUB_CONTAINER_EXT}" 2>/dev/null || true
      exit 0
    fi
    # dce_ext_install_one: <bin> --install-extension <id>.
    if [[ "${@: -2:1}" == "--install-extension" ]]; then
      _id="${@: -1}"
      if [[ -n "${DC_STUB_INSTALL_LOG:-}" ]]; then
        printf 'INSTALL %s\n' "$_id" >> "$DC_STUB_INSTALL_LOG"
      fi
      if [[ -n "${DC_STUB_INSTALL_FAIL_IDS:-}" ]]; then
        for _bad in $DC_STUB_INSTALL_FAIL_IDS; do
          [[ "$_bad" == "$_id" ]] && exit 1
        done
      fi
      exit 0
    fi
    exit 0
    ;;
  context)
    [[ "${2:-}" == "show" ]] && { printf 'default\n'; exit 0; }
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/docker"

# An apple/container stub. `dce editor` now launches on apple (experimental),
# so this stub has to answer the same predicates editor.sh + start.sh exercise
# for the docker stub: running/exists lists, start, exec (git-credential wiring
# + VS Code Server probes), and `inspect` for backend_apple_attach_ref's
# {id, image} resolution. It mirrors the docker stub's exec probe surface so
# extension-enforcement coverage can be reused on apple later.
cat > "$STUB_DIR/container" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_run="${DC_STUB_RUNNING:?}"
_ctrs="${DC_STUB_CONTAINERS:?}"
_have_creds_env="${DC_STUB_CONTAINER_CREDS+x}"
_creds="${DC_STUB_CONTAINER_CREDS-}"
_inspect_id="${DC_STUB_APPLE_INSPECT_ID:-}"
_inspect_image="${DC_STUB_APPLE_INSPECT_IMAGE:-}"
printf 'CALL container %s\n' "$*" >> "$_log"

_drain_stdin=false
for _a in "$@"; do
  case "$_a" in
    -i|--interactive|-i*|-it) _drain_stdin=true ;;
  esac
done

case "${1:-}" in
  system)
    # backend_system_start for apple runs `container system start`; tolerate.
    exit 0
    ;;
  ls)
    # backend_is_running: `container ls -q`; backend_exists: `container ls -a -q`.
    any=""
    for _a in "$@"; do [[ "$_a" == "-a" ]] && any=1; done
    if [[ -n "$any" ]]; then
      [[ -f "$_ctrs" ]] && cat "$_ctrs"
    else
      [[ -f "$_run" ]] && cat "$_run"
    fi
    exit 0
    ;;
  start)
    _name="${@: -1}"
    grep -qxF -- "$_name" "$_run" 2>/dev/null || printf '%s\n' "$_name" >> "$_run"
    exit 0
    ;;
  create)
    exit 0
    ;;
  inspect)
    # backend_apple_attach_ref reads .[0].configuration.id and
    # .[0].configuration.image.reference via jq. Emit the shape VS Code's
    # `container inspect` returns. Defaults: id = the inspected name, image =
    # the DC_STUB_APPLE_INSPECT_IMAGE override (or dce-base:latest).
    _name="${@: -1}"
    _id="${_inspect_id:-$_name}"
    _image="${_inspect_image:-dce-base:latest}"
    printf '[{"configuration":{"id":"%s","image":{"reference":"%s"}}}]\n' "$_id" "$_image"
    exit 0
    ;;
  exec)
    if [[ -n "$_have_creds_env" ]]; then
      if [[ "$*" == *'cat ~/.git-credentials'* ]]; then
        printf '%s' "$_creds"
        exit 0
      fi
      if [[ "$*" == *'test -f ~/.git-credentials'* ]]; then
        [[ -n "$_creds" ]] && exit 0 || exit 1
      fi
    fi
    $_drain_stdin && cat > /dev/null
    # _dce_ext_vscode_container_bin resolver probe: sh -c '...command -v code...'.
    #
    # DC_STUB_EXT_SERVER_APPEAR_AFTER=<n> (with DC_STUB_EXT_PROBE_COUNT=<file>)
    # simulates a VS Code Server that is injected only after the nth
    # CLI-resolution probe -- what a first-ever attach looks like while the
    # detached watcher polls. The counter must be a FILE: every probe is a
    # separate stub process. A missing/unreadable/unwritable counter degrades
    # to count 0 (the probe still advances in memory) instead of erroring.
    # APPEAR_AFTER unset -> exactly the old behavior, including the
    # DC_STUB_EXT_SERVER_ABSENT switch below.
    if [[ "$3" == "sh" && "$4" == "-c" && "$*" == *"command -v code"* ]]; then
      if [[ -n "${DC_STUB_EXT_SERVER_APPEAR_AFTER:-}" ]]; then
        _probe_count=0
        if [[ -n "${DC_STUB_EXT_PROBE_COUNT:-}" && -r "$DC_STUB_EXT_PROBE_COUNT" ]]; then
          _probe_count="$(cat "$DC_STUB_EXT_PROBE_COUNT" 2>/dev/null || printf '0')"
          case "$_probe_count" in '' | *[!0-9]*) _probe_count=0 ;; esac
        fi
        _probe_count=$((_probe_count + 1))
        if [[ -n "${DC_STUB_EXT_PROBE_COUNT:-}" ]]; then
          printf '%s\n' "$_probe_count" > "$DC_STUB_EXT_PROBE_COUNT" 2>/dev/null || true
        fi
        if [[ "$_probe_count" -le "$DC_STUB_EXT_SERVER_APPEAR_AFTER" ]]; then
          exit 1
        fi
        printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code-server'
        exit 0
      fi
      if [[ "${DC_STUB_EXT_SERVER_ABSENT:-0}" == "1" ]]; then
        exit 1
      fi
      printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code-server'
      exit 0
    fi
    if [[ "${@: -1}" == "--list-extensions" ]]; then
      [[ -f "${DC_STUB_CONTAINER_EXT:-}" ]] && cat "${DC_STUB_CONTAINER_EXT}" 2>/dev/null || true
      exit 0
    fi
    if [[ "${@: -2:1}" == "--install-extension" ]]; then
      _id="${@: -1}"
      if [[ -n "${DC_STUB_INSTALL_LOG:-}" ]]; then
        printf 'INSTALL %s\n' "$_id" >> "$DC_STUB_INSTALL_LOG"
      fi
      if [[ -n "${DC_STUB_INSTALL_FAIL_IDS:-}" ]]; then
        for _bad in $DC_STUB_INSTALL_FAIL_IDS; do
          [[ "$_bad" == "$_id" ]] && exit 1
        done
      fi
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/container"

# ---------------------------------------------------------------------------
# Fake editor binary: captures argv so tests can assert the launch shape.
# Named `code` so dce_editor_find_binary's PATH lookup resolves to it.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/code" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_CODE_LOG:?}"
printf 'CALL code %s\n' "$*" >> "$_log"
exit 0
STUB
chmod +x "$STUB_DIR/code"

ORIG_PATH="$PATH"

# Build a project config + register the container name as existing/running.
# $1 = project name; $2 = "running" to pre-mark as running, "" to leave stopped.
make_project() {
  local project="$1"
  local running="${2:-}"
  local cfg_dir="$DC_ROOT/$project"
  local repos="$WORK/home/repos/$project"
  mkdir -p "$cfg_dir" "$repos"
  chmod 700 "$cfg_dir"
  cat > "$cfg_dir/config" <<CFG
CONTAINER_PROJECT="$project"
CONTAINER_BACKEND="docker"
CONTAINER_IMAGE="dce-base:latest"
REPOS_DIR="$repos"
SECRET_DIR="$cfg_dir"
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

# Like make_project, but configures a REAL (non-placeholder) git token for
# <provider> plus an SSH_KEY_PATH, so dce_git_auth_method resolves to "pat" and
# `dce editor` exercises the credential-wiring path. The token value is unique
# enough to grep for and is never the provider sentinel.
#
# $1 = project name; $2 = "running" to pre-mark running, "" stopped;
# $3 = provider (github|gitlab). Echoes the real token value on stdout so the
# caller can assert it never leaks into the docker argv.
make_project_token() {
  local project="$1"
  local running="${2:-}"
  local provider="${3:-github}"
  local cfg_dir="$DC_ROOT/$project"
  local repos="$WORK/home/repos/$project"
  local sentinel="" real_token="" token_file=""
  sentinel="$(dce_git_host_field "$provider" sentinel)"
  real_token="${sentinel%%_REPLACE_ME}_REAL0123456789abcdefXYZ"
  token_file="$WORK/$(dce_git_host_field "$provider" token_filename)-$project"
  printf '%s\n' "$real_token" > "$token_file"
  chmod 600 "$token_file"

  mkdir -p "$cfg_dir" "$repos"
  chmod 700 "$cfg_dir"
  cat > "$cfg_dir/config" <<CFG
CONTAINER_PROJECT="$project"
CONTAINER_BACKEND="docker"
CONTAINER_GIT_HOST="$provider"
CONTAINER_IMAGE="dce-base:latest"
REPOS_DIR="$repos"
SECRET_DIR="$cfg_dir"
SSH_KEY_PATH="$cfg_dir/ssh_key"
TOKEN_FILE="$token_file"
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
  printf '%s' "$real_token"
}

# Run editor.sh with all stubs wired. Captures stdout/stderr/exit separately.
run_editor() {
  DC_STUB_LOG="$DOCKER_LOG" \
  DC_STUB_RUNNING="$RUNNING_FILE" \
  DC_STUB_CONTAINERS="$CONTAINERS_FILE" \
  DC_STUB_CODE_LOG="$CODE_LOG" \
  DC_STUB_CONTAINER_EXT="${DC_STUB_CONTAINER_EXT:-}" \
  DC_STUB_INSTALL_LOG="${DC_STUB_INSTALL_LOG:-}" \
  DC_STUB_INSTALL_FAIL_IDS="${DC_STUB_INSTALL_FAIL_IDS:-}" \
  DC_STUB_EXT_SERVER_ABSENT="${DC_STUB_EXT_SERVER_ABSENT:-0}" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="docker" \
  DEV_CONTAINERS_BACKEND="" \
  HOME="$WORK/home" \
  "$ROOT_DIR/scripts/editor.sh" "$@"
}

# ===========================================================================
# Section 1 - happy path: running container -> editor launched with attach URI
# ===========================================================================
make_project "alpha" running
: > "$DOCKER_LOG"; : > "$CODE_LOG"
run_editor alpha >"$WORK/sec1.out" 2>"$WORK/err" || fail "editor alpha exited non-zero
-- stderr:$(cat "$WORK/err")"

# The code binary was invoked exactly once with --folder-uri vscode-remote://...
code_calls="$(grep -c '^CALL code ' "$CODE_LOG" || true)"
[[ "$code_calls" -eq 1 ]] || fail "happy: expected 1 code call, got $code_calls"

# The URI must contain the attached-container scheme + the project name hex.
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "happy: code argv missing attached-container URI (got $(cat "$CODE_LOG"))"

# Hex token decodes back to "/alpha" (the Docker namespace prefix + project name).
hex="$(grep -oE 'attached-container\+[0-9a-f]+' "$CODE_LOG" | head -n1)"
hex="${hex#*+}"
hex="${hex%%/*}"
decoded=""
for ((i = 0; i < ${#hex}; i += 2)); do
  # shellcheck disable=SC2059
  # pair is constructed from a charset-restricted hex string emitted by the lib.
  decoded+="$(printf '%b' "\\x${hex:i:2}")"
done
[[ "$decoded" == "/alpha" ]] || fail "happy: URI hex decoded to '$decoded', expected '/alpha'"

# Workspace path appears in the URI tail.
grep -Fq 'attached-container+'"${hex}"'/workspace' "$CODE_LOG" \
  || fail "happy: URI missing /workspace tail"

# Container was already running: start.sh must NOT have been invoked.
if grep -Eq 'docker start alpha' "$DOCKER_LOG"; then
  fail "happy: container was running but start.sh issued docker start"
fi

pass "Section 1: running container -> editor launched with attach URI"

# ===========================================================================
# Section 2 - stopped container -> start.sh path runs before editor launch
# ===========================================================================
make_project "beta" ""    # exists but not running
: > "$DOCKER_LOG"; : > "$CODE_LOG"
run_editor beta >"$WORK/sec2.out" 2>"$WORK/err" || fail "editor beta exited non-zero
-- stderr:$(cat "$WORK/err")"

# start.sh issues `docker start beta` (our stub moves it into running).
grep -Eq 'CALL docker start beta' "$DOCKER_LOG" \
  || fail "stopped: start.sh did not issue 'docker start beta'"

# Editor still launched afterwards with the right URI.
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "stopped: editor not launched after start"

# Container is now in the running list.
grep -qxF "beta" "$RUNNING_FILE" || fail "stopped: beta not marked running after start"

pass "Section 2: stopped container -> start.sh runs, then editor launches"

# ===========================================================================
# Section 3 - --editor override selects the requested editor
# ===========================================================================
make_project "gamma" running
: > "$CODE_LOG"

# vscode (default) selects `code`.
run_editor gamma >/dev/null 2>&1 || fail "editor gamma (default) exited non-zero"
grep -Eq '^CALL code --folder-uri' "$CODE_LOG" \
  || fail "default editor: code not invoked (got $(cat "$CODE_LOG"))"

: > "$CODE_LOG"
# Override to vscode-insiders. No code-insiders stub on PATH -> the override
# must hard-error with the missing-binary guidance, proving the override took
# effect (default vscode would have found the `code` stub).
if run_editor --editor vscode-insiders gamma >/dev/null 2>&1; then
  fail "override: vscode-insiders should hard-error (binary absent) but editor exited 0"
fi
# Verify it failed at binary discovery, not at backend/editor selection.
err_out="$(run_editor --editor vscode-insiders gamma 2>&1 >/dev/null || true)"
grep -Fq "Editor binary not found for 'vscode-insiders'" <<<"$err_out" \
  || fail "override: missing-binary guidance not shown (got: $err_out)"

pass "Section 3: --editor override selects the requested editor"

# ===========================================================================
# Section 4 - precedence: --editor wins over $DCE_EDITOR
# ===========================================================================
make_project "delta" running
: > "$CODE_LOG"

# $DCE_EDITOR=vscode-insiders would hard-error (no code-insiders stub); an
# explicit --editor vscode must override it and succeed via the `code` stub.
DCE_EDITOR=vscode-insiders run_editor --editor vscode delta >"$WORK/d.out" 2>"$WORK/err" \
  || fail "precedence: --editor should override \$DCE_EDITOR
-- stderr:$(cat "$WORK/err")"
grep -Eq '^CALL code --folder-uri' "$CODE_LOG" \
  || fail "precedence: --editor vscode did not win over \$DCE_EDITOR"

pass "Section 4: --editor precedence over \$DCE_EDITOR"

# ===========================================================================
# Section 5 - unknown explicit editor hard-errors cleanly
# ===========================================================================
make_project "epsilon" running
if run_editor --editor acme epsilon 2>/dev/null; then
  fail "unknown editor: --editor acme should hard-error"
fi
err_out="$(run_editor --editor acme epsilon 2>&1 || true)"
grep -Fq "Unknown editor 'acme'" <<<"$err_out" \
  || fail "unknown editor: missing guidance (got: $err_out)"
grep -Eq 'Known editors:.*vscode' <<<"$err_out" \
  || fail "unknown editor: known-editors hint missing"

pass "Section 5: unknown explicit editor hard-errors with guidance"

# ===========================================================================
# Section 6 - apple backend: experimental launch via apple-container URI
#
# `dce editor` no longer refuses on apple; it launches VS Code with an
# apple-container+<hex> URI (experimental upstream support), resolving {id,
# image} from `container inspect`. The container stub answers inspect with a
# known {id, image}; the fake `code` captures the --folder-uri argv.
# ===========================================================================
make_project "zeta" running
sed -i.bak 's/CONTAINER_BACKEND="docker"/CONTAINER_BACKEND="apple"/' "$DC_ROOT/zeta/config"
rm -f "$DC_ROOT/zeta/config.bak"

: > "$DOCKER_LOG"; : > "$CODE_LOG"
DC_STUB_APPLE_INSPECT_IMAGE="dce-base:latest" \
  run_editor zeta >"$WORK/sec6.out" 2>"$WORK/err" || fail "editor zeta (apple) exited non-zero
-- stderr:$(cat "$WORK/err")"

# Editor launched exactly once with the apple-container scheme (NOT docker's
# attached-container scheme).
code_calls="$(grep -c '^CALL code ' "$CODE_LOG" || true)"
[[ "$code_calls" -eq 1 ]] || fail "apple: expected 1 code call, got $code_calls"
grep -Fq -- '--folder-uri vscode-remote://apple-container+' "$CODE_LOG" \
  || fail "apple: code argv missing apple-container URI (got $(cat "$CODE_LOG"))"
grep -Fq 'vscode-remote://attached-container+' "$CODE_LOG" \
  && fail "apple: code argv used docker attached-container URI (got $(cat "$CODE_LOG"))"

# The hex token decodes to {"id":"zeta","image":"dce-base:latest"} -- the pair
# the container inspect stub reported. VS Code parses the authority with
# JSON.parse, so assert via the decoded JSON rather than a fragile hex literal.
hex="$(grep -oE 'apple-container\+[0-9a-f]+' "$CODE_LOG" | head -n1)"
hex="${hex#*+}"
decoded=""
for ((i = 0; i < ${#hex}; i += 2)); do
  # shellcheck disable=SC2059
  # pair is constructed from a charset-restricted hex string emitted by the lib.
  decoded+="$(printf '%b' "\\x${hex:i:2}")"
done
[[ "$decoded" == *'"id":"zeta"'* ]] || fail "apple: URI hex id mismatch (decoded: $decoded)"
[[ "$decoded" == *'"image":"dce-base:latest"'* ]] || fail "apple: URI hex image mismatch (decoded: $decoded)"
# Workspace path tail.
grep -Fq "apple-container+${hex}/workspace" "$CODE_LOG" \
  || fail "apple: URI missing /workspace tail"

# Experimental notice surfaced.
grep -Fqi 'EXPERIMENTAL' "$WORK/sec6.out" \
  || fail "apple: missing experimental notice (got: $(cat "$WORK/sec6.out"))"
grep -Fqi 'experimentalAppleContainerSupport' "$WORK/sec6.out" \
  || fail "apple: missing experimentalAppleContainerSupport setting hint"

# The attach ref was resolved from `container inspect zeta` (live, not config).
grep -Eq 'CALL container inspect zeta' "$DOCKER_LOG" \
  || fail "apple: backend_apple_attach_ref did not inspect container (got: $(cat "$DOCKER_LOG"))"

pass "Section 6: apple backend launches via experimental apple-container URI"

# ===========================================================================
# Section 7 - usage: missing project arg
# ===========================================================================
if run_editor 2>/dev/null; then
  fail "usage: missing project should exit non-zero"
fi
err_out="$(run_editor 2>&1 || true)"
grep -Eq 'Usage: dce editor' <<<"$err_out" \
  || fail "usage: missing usage banner (got: $err_out)"

pass "Section 7: missing project arg -> usage error"

# ===========================================================================
# Section 8 - missing config for unknown project
# ===========================================================================
if run_editor no-such-project 2>/dev/null; then
  fail "unknown project: should exit non-zero"
fi
err_out="$(run_editor no-such-project 2>&1 || true)"
grep -Fq "No config for 'no-such-project'" <<<"$err_out" \
  || fail "unknown project: missing guidance (got: $err_out)"

pass "Section 8: unknown project -> clear error"

# ===========================================================================
# Section 9 - credential injection parity: running container + PAT wires git
# auth on launch (the reported bug). `dce shell` wires credentials via
# dce_ensure_git_credentials; `dce editor` must do the same so the editor lands
# with working git auth without a separate `dce shell`.
# ===========================================================================
web_github="$(dce_git_host_field github web_host)"
ssh_github="$(dce_git_host_field github ssh_host)"
tok_alpha="$(make_project_token "eta" running github)"
: > "$DOCKER_LOG"; : > "$CODE_LOG"
run_editor eta >"$WORK/sec9.out" 2>"$WORK/err" || fail "editor eta exited non-zero
-- stderr:$(cat "$WORK/err")"

# PAT wiring markers must appear: HTTPS insteadOf + credential.helper store.
grep -Fq -- "git config --global url.https://${web_github}/.insteadOf" "$DOCKER_LOG" \
  || fail "eta: PAT insteadOf wiring not issued (got: $(cat "$DOCKER_LOG"))"
grep -Fq -- "git config --global --add credential.helper store" "$DOCKER_LOG" \
  || fail "eta: credential.helper store not added"

# Already running -> must NOT call docker start (wiring is independent of start).
grep -Eq 'docker start eta' "$DOCKER_LOG" \
  && fail "eta: was running but editor issued docker start"

# Editor still launched.
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "eta: editor not launched after credential wiring"

# Security invariant: the token value must never appear in a host argv.
grep -Fq -- "$tok_alpha" "$DOCKER_LOG" \
  && fail "eta: token value leaked into host argv"

pass "Section 9: running + PAT -> git credentials wired on editor launch (no start)"

# ===========================================================================
# Section 10 - stopped container + PAT: start.sh runs, THEN credentials wired.
# ===========================================================================
make_project_token "theta" "" github > /dev/null
: > "$DOCKER_LOG"; : > "$CODE_LOG"
run_editor theta >"$WORK/sec10.out" 2>"$WORK/err" || fail "editor theta exited non-zero
-- stderr:$(cat "$WORK/err")"

grep -Eq 'CALL docker start theta' "$DOCKER_LOG" \
  || fail "theta: start.sh did not issue 'docker start theta'"
grep -Fq -- "git config --global --add credential.helper store" "$DOCKER_LOG" \
  || fail "theta: credential.helper store not added after start"
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "theta: editor not launched after start+wiring"

pass "Section 10: stopped + PAT -> start, then credentials wired, then launch"

# ===========================================================================
# Section 11 - gitlab provider: PAT wiring uses the gitlab host (data-driven
# over the provider registry, like security-token-argv.sh).
# ===========================================================================
web_gitlab="$(dce_git_host_field gitlab web_host)"
make_project_token "iota" running gitlab > /dev/null
: > "$DOCKER_LOG"; : > "$CODE_LOG"
run_editor iota >"$WORK/sec11.out" 2>"$WORK/err" || fail "editor iota exited non-zero
-- stderr:$(cat "$WORK/err")"

grep -Fq -- "git config --global url.https://${web_gitlab}/.insteadOf" "$DOCKER_LOG" \
  || fail "iota: gitlab PAT insteadOf wiring not issued"
grep -Fq -- "git config --global --add credential.helper store" "$DOCKER_LOG" \
  || fail "iota: credential.helper store not added"
# GitHub insteadOf must NOT be SET for a gitlab project. Match the SET form
# (trailing " git@github.com:") so the legit --unset-all cleanup of the
# image-baked github rule (no trailing value) is not mistaken for wiring.
grep -Fq -- "url.https://${web_github}/.insteadOf git@${ssh_github}:" "$DOCKER_LOG" \
  && fail "iota: github insteadOf wired (set) for a gitlab project"

pass "Section 11: gitlab PAT -> gitlab host wiring (provider-correct)"

# ===========================================================================
# Section 12 - placeholder token: treated as unset -> no PAT wiring (method
# "none"); matches dce shell's behavior for an unfilled token file.
# ===========================================================================
make_project "kappa" running
# Inject a placeholder-only token file + SSH path so the project has a token
# slot, but dce_read_git_token filters the sentinel out -> auth method "none".
kappa_sentinel="$(dce_git_host_field github sentinel)"
kappa_cfg="$DC_ROOT/kappa/config"
kappa_token="$WORK/github-token-kappa"
printf '%s\n' "$kappa_sentinel" > "$kappa_token"
chmod 600 "$kappa_token"
{
  printf 'TOKEN_FILE="%s"\n' "$kappa_token"
  printf 'SSH_KEY_PATH="%s/ssh_key"\n' "$DC_ROOT/kappa"
} >> "$kappa_cfg"
: > "$DOCKER_LOG"; : > "$CODE_LOG"
run_editor kappa >"$WORK/sec12.out" 2>"$WORK/err" || fail "editor kappa exited non-zero
-- stderr:$(cat "$WORK/err")"

grep -Fq -- "git config --global --add credential.helper store" "$DOCKER_LOG" \
  && fail "kappa: PAT wiring issued for a placeholder (unset) token"
# Match the SET form so the method-"none" cleanup unsets are not mistaken for
# active PAT wiring.
grep -Fq -- "url.https://${web_github}/.insteadOf git@${ssh_github}:" "$DOCKER_LOG" \
  && fail "kappa: PAT insteadOf set for a placeholder (unset) token"

# Resolve the VS Code Remote-Containers nameConfig dir for the ACTIVE platform
# (the seed writes under .config on Linux/WSL2, under Library/Application Support
# on macOS). The harness pre-creates BOTH User dirs so the seed finds a live
# parent on either OS, which makes a "which dir exists?" heuristic resolve to
# the macOS path on Linux (the macOS dir always exists) and miss the file the
# Linux seed wrote. Drive this off uname so it matches the seed's platform_os.
if [[ "$(uname -s)" == "Darwin" ]]; then
  _rc_storage="$HOME/Library/Application Support/Code/User/globalStorage/ms-vscode-remote.remote-containers"
else
  _rc_storage="$HOME/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers"
fi

cfg_kappa="$_rc_storage/nameConfigs/kappa.json"
[[ -f "$cfg_kappa" ]] || fail "kappa: named attach config not written"
if jq -e '.remoteEnv.GIT_CONFIG_COUNT == "2"' "$cfg_kappa" >/dev/null 2>&1; then
  fail "kappa: placeholder-token project should not carry PAT remoteEnv override"
fi

pass "Section 12: placeholder token -> no PAT wiring (treated as unset)"

# ===========================================================================
# Section 13 - named attach config carries the deterministic Git override.
# Attach-mode named configs support remoteEnv, which VS Code applies to the
# editor/terminal processes at attach time. dce uses that deterministic hook to
# force Git's runtime config (`credential.helper = ""`, then `store`) so the
# editor ignores VS Code's host-forwarding helper and uses the PAT-backed
# ~/.git-credentials instead.
# ===========================================================================
make_project_token "lambda" running github > /dev/null
: > "$DOCKER_LOG"; : > "$CODE_LOG"
run_editor lambda >"$WORK/sec13.out" 2>"$WORK/err" || fail "editor lambda exited non-zero
-- stderr:$(cat "$WORK/err")"

cfg_lambda="$_rc_storage/nameConfigs/lambda.json"
[[ -f "$cfg_lambda" ]] || fail "lambda: named attach config not written"

grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "lambda: editor not launched"

jq -e '
  .workspaceFolder == "/workspace"
  and .remoteEnv.GIT_CONFIG_COUNT == "2"
  and .remoteEnv.GIT_CONFIG_KEY_0 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_0 == ""
  and .remoteEnv.GIT_CONFIG_KEY_1 == "credential.helper"
  and .remoteEnv.GIT_CONFIG_VALUE_1 == "store"
' "$cfg_lambda" >/dev/null || fail "lambda: named attach config missing deterministic Git remoteEnv override"

pass "Section 13: named attach config carries Git remoteEnv override"

# ===========================================================================
# Section 14 - PAT drift warning: editor preserves the shell/start only-if-
# missing policy for ~/.git-credentials, so a rotated host token should produce
# a visible warning pointing at `dce rotate-token` rather than silently failing
# later in VS Code's Git UI / terminal.
# ===========================================================================
make_project_token "mu" running github > /dev/null
: > "$DOCKER_LOG"; : > "$CODE_LOG"
export DC_STUB_CONTAINER_CREDS=$'https://x-access-token:STALE@github.com\n'
run_editor mu >"$WORK/sec14.out" 2>"$WORK/err" || fail "editor mu exited non-zero
-- stderr:$(cat "$WORK/err")"
unset DC_STUB_CONTAINER_CREDS

grep -Fq 'rotate-token mu' "$WORK/err" \
  || fail "mu: token-drift warning missing rotate-token guidance (got: $(cat "$WORK/err"))"

pass "Section 14: PAT drift warns and points to rotate-token"

# ===========================================================================
# Section 15 - attach-mode extension enforcement (plans/extensions.md §6).
# VS Code's attached-container open does not reliably process
# customizations.vscode.extensions, so `dce editor` installs declared-but-
# missing extensions itself via the in-container code-server CLI before launch.
# ===========================================================================
# Helper: seed an extension manifest under the user tree.
seed_ext_manifest() {  # <scope> <content>
  local scope="$1" content="$2"
  local dir="$USER_DIR/extensions/vscode"
  mkdir -p "$dir"
  printf '%b' "$content" > "$dir/$scope.txt"
}

# (a) Declared set has two IDs; one already installed -> only the missing one
# is installed. Idempotent: the already-installed id is never re-installed.
make_project "nu" running
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/nu/config"
seed_ext_manifest nodejs $'alpha.installed\nbeta.missing\n'
CONTAINER_EXT_FILE="$WORK/nu-installed.txt"
printf 'alpha.installed\n' > "$CONTAINER_EXT_FILE"
INSTALL_LOG="$WORK/nu-installs.log"
: > "$INSTALL_LOG"
: > "$CODE_LOG"
DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  run_editor nu >"$WORK/sec15a.out" 2>"$WORK/err" || fail "editor nu exited non-zero
-- stderr:$(cat "$WORK/err")"

# Editor still launched.
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "nu: editor not launched after enforcement"
# Missing id installed; already-installed id was NOT re-installed (idempotent).
grep -Fq 'INSTALL beta.missing' "$INSTALL_LOG" \
  || fail "nu: missing extension not installed (log: $(cat "$INSTALL_LOG"))"
grep -Fq 'INSTALL alpha.installed' "$INSTALL_LOG" \
  && fail "nu: already-installed extension was re-installed (not idempotent)"
# Status line surfaced to the user.
grep -Fq 'editor extensions: installing' "$WORK/sec15a.out" \
  || fail "nu: missing install status line (got: $(cat "$WORK/sec15a.out"))"
pass "Section 15a: enforcement installs declared-but-missing; idempotent over installed"

# (c) Pre-adoption (no manifests): enforcement is a no-op; no install calls.
make_project "omicron" running
: > "$INSTALL_LOG"
: > "$CODE_LOG"
DC_STUB_INSTALL_LOG="$INSTALL_LOG" run_editor omicron >"$WORK/sec15c.out" 2>"$WORK/err" \
  || fail "editor omicron exited non-zero
-- stderr:$(cat "$WORK/err")"
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "omicron: editor not launched (pre-adoption)"
[[ ! -s "$INSTALL_LOG" ]] \
  || fail "omicron: pre-adoption must not install anything (log: $(cat "$INSTALL_LOG"))"
pass "Section 15c: pre-adoption (no manifests) -> no enforcement, editor launches"

# (d) Per-id install failure is reported but not fatal: the editor still
# launches, the failing id is surfaced, the succeeding id is installed.
make_project "pi" running
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/pi/config"
seed_ext_manifest nodejs $'good.id\nbad.id\n'
: > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
: > "$CODE_LOG"
DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DC_STUB_INSTALL_FAIL_IDS="bad.id" \
  run_editor pi >"$WORK/sec15d.out" 2>"$WORK/err" || fail "editor pi exited non-zero
-- stderr:$(cat "$WORK/err")"
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "pi: editor not launched despite a per-id install failure"
grep -Fq 'INSTALL good.id' "$INSTALL_LOG" \
  || fail "pi: good.id not installed (log: $(cat "$INSTALL_LOG"))"
grep -Fq 'INSTALL bad.id' "$INSTALL_LOG" \
  || fail "pi: bad.id install attempt not recorded (log: $(cat "$INSTALL_LOG"))"
grep -Fq 'bad.id' "$WORK/sec15d.out" \
  || fail "pi: failing id not surfaced in status (got: $(cat "$WORK/sec15d.out"))"
pass "Section 15d: per-id install failure is non-fatal (editor still launches)"

# ===========================================================================
# Section 16 helpers - bounded polling for the detached extension watcher.
#
# The watcher spawned by `dce editor` on a first-ever open
# (plans/extensions-first-open-convergence.md) outlives the run_editor
# invocation, so its log/lock must be polled with a deadline instead of
# checked once. Every Section 16 subsection that can spawn a watcher MUST:
#   1. point TMPDIR at a fresh dir under $WORK (the watcher's lock + log live
#      under "${TMPDIR}/dce-ext-watch.<project>.*"; isolating per section
#      keeps projects from observing each other),
#   2. bound the watcher with tiny DCE_EXT_WATCH_INTERVAL/TIMEOUT values so
#      it can never outlive the section,
#   3. join it BEFORE the section's `pass` line, so the EXIT trap's
#      `rm -rf "$WORK"` can never race a live watcher. Canonical join rules:
#      (1) a watcher spawned in the background is joined with
#      wait_watcher_done FIRST (lock appear -> disappear), and only then are
#      one-shot content greps run -- once the lock is gone the process is
#      proven exited and its log final;
#      (2) a foreground/direct invocation needs no poll: the process
#      exit/wait IS the join -- assert lock absence one-shot afterwards.
# ===========================================================================

# Poll <file> every 0.1s until it contains <fixed-string>, or timeout. Must
# tolerate the file not existing yet: the watcher truncates its log at start,
# but a just-spawned watcher may not have gotten there. Returns 0 when found,
# 1 on timeout.
wait_for_pattern() {  # <file> <fixed-string> <timeout_seconds>
  local file="$1" pattern="$2" timeout="$3"
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    if [[ -f "$file" ]] && grep -Fq -- "$pattern" "$file"; then
      return 0
    fi
    sleep 0.1
  done
  [[ -f "$file" ]] && grep -Fq -- "$pattern" "$file"
}

# Join a spawned watcher with a two-phase bounded poll (0.1s cadence, one
# deadline computed at entry and shared by both phases):
#   Phase 1 -- wait for the lock dir to APPEAR. A just-spawned watcher (nohup
#     child via run_editor, or a direct background invocation) needs ~50-200ms
#     to start bash, source its libs, and mkdir the lock, so an immediate
#     "is the lock gone" check would succeed before the watcher ever held the
#     lock and silently turn the join into a no-op.
#   Phase 2 -- wait for the lock dir to DISAPPEAR (= the watcher exited: it
#     removes the lock via its EXIT trap).
# Returns 0 when the lock appeared and was then released, 1 when the overall
# <timeout> budget is exceeded in either phase. Callers must only use this for
# watchers that are certain to spawn (all current call sites do).
# TMPDIR may conventionally carry a trailing '/', so strip it before
# concatenating -- the code under test joins
# "${TMPDIR}/dce-ext-watch.<project>.lock", and POSIX collapses the doubled
# slash either way, but the assertions below compare literal paths.
wait_watcher_done() {  # <project> <timeout_seconds>
  local project="$1" timeout="$2"
  local base="${TMPDIR:-/tmp}"
  base="${base%/}"
  local lock="$base/dce-ext-watch.${project}.lock"
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )) && [[ ! -e "$lock" ]]; do
    sleep 0.1
  done
  [[ -e "$lock" ]] || return 1 # lock never appeared within the budget
  while (( SECONDS < deadline )) && [[ -e "$lock" ]]; do
    sleep 0.1
  done
  [[ ! -e "$lock" ]]
}

# ===========================================================================
# Section 16 - detached extension watcher on first-ever open
# (plans/extensions-first-open-convergence.md).
#
# Today a first-ever `dce editor` open (VS Code Server not yet injected into
# the container) skips extension enforcement and tells the user to re-run.
# The converged behavior: when the server is absent AND the project is
# post-adoption with a non-empty declared set, editor.sh spawns the detached
# watcher (nohup scripts/_editor-ext-watch.sh ...) with a per-project log +
# single-flight lock under TMPDIR, prints a background notice carrying the
# log path, and still launches the editor immediately; the watcher polls
# until the server lands, runs the same enforcement (same stubbed INSTALL
# calls), and logs its outcome. Pre-adoption or empty-declared projects keep
# today's silent no-op (16f).
#
# The former Section 15b (sync-path skip notice when the server is absent)
# was removed: 16a/16h supersede its scenario for post-adoption projects and
# 16f pins the pre-adoption no-op. Section 15a/15c/15d (the unchanged
# synchronous path) are untouched above.
#
# Test-first state: every subsection here except 16f FAILS until the
# implementation lands -- scripts/_editor-ext-watch.sh does not exist yet and
# editor.sh neither spawns a watcher nor prints the background/log-path
# notice. 16f is expected to pass before AND after.
# ===========================================================================
WATCH_SCRIPT="$ROOT_DIR/scripts/_editor-ext-watch.sh"

# Invoke the watcher script directly -- the way editor.sh spawns it -- with the
# stubbed backend env wired. This is the direct-call equivalent of run_editor:
# every var is pinned per call, so nothing leaks between sections. Callers
# add/override specific vars with an env prefix, e.g.
#   DC_STUB_EXT_SERVER_APPEAR_AFTER=1 run_watcher upsilon vscode 0.2 10
run_watcher() {
  PATH="$STUB_DIR:$ORIG_PATH" \
    HOME="$WORK/home" CONTAINER_BACKEND="docker" \
    DC_STUB_LOG="$DOCKER_LOG" \
    DC_STUB_RUNNING="$RUNNING_FILE" \
    DC_STUB_CONTAINERS="$CONTAINERS_FILE" \
    DC_STUB_CONTAINER_EXT="${DC_STUB_CONTAINER_EXT:-}" \
    DC_STUB_INSTALL_LOG="${DC_STUB_INSTALL_LOG:-}" \
    DC_STUB_EXT_SERVER_ABSENT="${DC_STUB_EXT_SERVER_ABSENT:-0}" \
    DC_STUB_EXT_SERVER_APPEAR_AFTER="${DC_STUB_EXT_SERVER_APPEAR_AFTER:-}" \
    DC_STUB_EXT_PROBE_COUNT="${DC_STUB_EXT_PROBE_COUNT:-}" \
    "$WATCH_SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# (16a) Post-adoption + server absent: editor.sh must spawn the detached
# watcher, print the background notice WITH the log path, still launch the
# editor synchronously, and NOT install anything itself (server absent). The
# watcher then polls until its timeout (the stubbed server never appears)
# and logs the retry-hint timeout line -- waiting for that line doubles as
# the join guarantee before this section ends.
# ---------------------------------------------------------------------------
make_project "rho" running
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/rho/config"
seed_ext_manifest nodejs $'alpha.installed\nbeta.missing\n'
printf 'alpha.installed\n' > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
: > "$CODE_LOG"
TMPDIR="$WORK/tmp16a"
export TMPDIR
mkdir -p "$TMPDIR"
rho_watch_log="${TMPDIR%/}/dce-ext-watch.rho.log"
DC_STUB_EXT_SERVER_ABSENT=1 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DCE_EXT_WATCH_INTERVAL=0.2 DCE_EXT_WATCH_TIMEOUT=2 \
  run_editor rho >"$WORK/sec16a.out" 2>"$WORK/err" || fail "editor rho exited non-zero
-- stderr:$(cat "$WORK/err")"
unset DCE_EXT_WATCH_INTERVAL DCE_EXT_WATCH_TIMEOUT

# Editor launched synchronously despite the absent server.
grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "rho: editor not launched alongside the watcher (got $(cat "$CODE_LOG"))"

# The notice must say the work moved to the background and point at the log.
grep -Fq 'VS Code Server not yet injected' "$WORK/sec16a.out" \
  || fail "rho: missing server-absent notice (got: $(cat "$WORK/sec16a.out"))"
grep -Fq 'background' "$WORK/sec16a.out" \
  || fail "rho: notice does not mention the background watcher (got: $(cat "$WORK/sec16a.out"))"
grep -Fq "$rho_watch_log" "$WORK/sec16a.out" \
  || fail "rho: notice missing the watcher log path $rho_watch_log (got: $(cat "$WORK/sec16a.out"))"

# The launch path itself must not have installed anything (server absent).
[[ ! -s "$INSTALL_LOG" ]] \
  || fail "rho: install ran in the launch path despite absent server (log: $(cat "$INSTALL_LOG"))"

# A watcher was actually spawned: either it still holds its single-flight
# lock or it already wrote its log.
[[ -e "${TMPDIR%/}/dce-ext-watch.rho.lock" || -f "$rho_watch_log" ]] \
  || fail "rho: no watcher lock or log -- nothing was spawned"

# Join the watcher before the EXIT trap removes $WORK: the server never
# appears, so the watcher must end on its 2s timeout with the retry hint.
wait_watcher_done rho 10 || fail "rho: watcher lock still held 10s after spawn"
# The watcher is proven exited, so its log is final: one-shot greps.
grep -Fq 'not injected within' "$rho_watch_log" \
  || fail "rho: watcher log missing timeout line (got: $(cat "$rho_watch_log" 2>/dev/null || true))"
grep -Fq 'dce editor' "$rho_watch_log" \
  || fail "rho: timeout line missing the 'dce editor' retry hint (log: $(cat "$rho_watch_log" 2>/dev/null || true))"
pass "Section 16a: server absent + declared set -> detached watcher, non-blocking launch, notice with log path"

# ---------------------------------------------------------------------------
# (16b) The watcher converges once the server lands. APPEAR_AFTER=2 keeps the
# stubbed server absent for the first 2 CLI-resolution probes (editor.sh's
# availability check + the watcher's first poll; the count lives in a file
# because every probe is a separate stub process), so editor.sh spawns the
# watcher, and the watcher's next poll sees the server, breaks, and runs the
# same enforcement as the synchronous path. Idempotence must hold through the
# watcher: the already-installed id is never re-installed.
# ---------------------------------------------------------------------------
make_project "sigma" running
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/sigma/config"
seed_ext_manifest nodejs $'alpha.installed\nbeta.missing\n'
printf 'alpha.installed\n' > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
: > "$CODE_LOG"
rm -f "$WORK/sigma-count" # probe counter; the stub initializes it from 0
TMPDIR="$WORK/tmp16b"
export TMPDIR
mkdir -p "$TMPDIR"
sigma_watch_log="${TMPDIR%/}/dce-ext-watch.sigma.log"
DC_STUB_EXT_SERVER_APPEAR_AFTER=2 DC_STUB_EXT_PROBE_COUNT="$WORK/sigma-count" \
  DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DCE_EXT_WATCH_INTERVAL=0.2 DCE_EXT_WATCH_TIMEOUT=15 \
  run_editor sigma >"$WORK/sec16b.out" 2>"$WORK/err" || fail "editor sigma exited non-zero
-- stderr:$(cat "$WORK/err")"
unset DC_STUB_EXT_SERVER_APPEAR_AFTER DC_STUB_EXT_PROBE_COUNT \
  DCE_EXT_WATCH_INTERVAL DCE_EXT_WATCH_TIMEOUT

# Join the watcher first (lock appear -> disappear): once the lock is gone
# the watcher is proven exited and its output is final, so the convergence
# and idempotence assertions below are one-shot greps.
wait_watcher_done sigma 10 || fail "sigma: watcher lock still held 10s after spawn"
grep -Fq 'INSTALL beta.missing' "$INSTALL_LOG" \
  || fail "sigma: watcher never installed the missing id (install log: $(cat "$INSTALL_LOG" 2>/dev/null || true))"
grep -Fq 'INSTALL alpha.installed' "$INSTALL_LOG" \
  && fail "sigma: already-installed id re-installed through the watcher (not idempotent)"
grep -Fq 'watch complete' "$sigma_watch_log" \
  || fail "sigma: watcher log missing completion line (got: $(cat "$sigma_watch_log" 2>/dev/null || true))"
pass "Section 16b: watcher converges when the server lands; idempotence preserved"

# ---------------------------------------------------------------------------
# (16c) Timeout skip: the server never lands, so the watcher must give up on
# schedule and log the retry hint pointing at `dce editor` -- with no install
# attempted along the way.
# ---------------------------------------------------------------------------
make_project "tau" running
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/tau/config"
seed_ext_manifest nodejs $'alpha.installed\nbeta.missing\n'
: > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
: > "$CODE_LOG"
TMPDIR="$WORK/tmp16c"
export TMPDIR
mkdir -p "$TMPDIR"
tau_watch_log="${TMPDIR%/}/dce-ext-watch.tau.log"
DC_STUB_EXT_SERVER_ABSENT=1 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DCE_EXT_WATCH_INTERVAL=0.2 DCE_EXT_WATCH_TIMEOUT=1 \
  run_editor tau >"$WORK/sec16c.out" 2>"$WORK/err" || fail "editor tau exited non-zero
-- stderr:$(cat "$WORK/err")"
unset DCE_EXT_WATCH_INTERVAL DCE_EXT_WATCH_TIMEOUT

wait_watcher_done tau 10 || fail "tau: watcher lock still held 10s after spawn"
wait_for_pattern "$tau_watch_log" 'not injected within' 10 \
  || fail "tau: watcher log missing timeout line (got: $(cat "$tau_watch_log" 2>/dev/null || true))"
grep -Fq 'dce editor' "$tau_watch_log" \
  || fail "tau: timeout line missing the 'dce editor' retry hint (log: $(cat "$tau_watch_log" 2>/dev/null || true))"
[[ ! -s "$INSTALL_LOG" ]] \
  || fail "tau: installs recorded despite the server never landing (log: $(cat "$INSTALL_LOG"))"
pass "Section 16c: watcher times out with the retry hint; no installs attempted"

# ---------------------------------------------------------------------------
# (16d) Single-flight: two concurrent watchers for the same project must not
# double-install. The first invocation is launched in the background; the
# second runs in the foreground and must observe the fresh lock, log "already
# active", and exit 0 while the first converges. Each declared-but-missing id
# must be installed exactly once across both invocations.
#
# Determinism contract: each watcher gets its OWN probe counter with its OWN
# schedule. Watcher A's server appears only on the 26th probe
# (APPEAR_AFTER=25), so at interval 0.2 it polls ~5s before converging and
# holds a FRESH lock for several seconds -- enough that even a CI runner
# whose latecomer takes ~0.5s+ to reach its lock check still overlaps (A's
# ~5-7s convergence stays far below its 15s timeout). B's server appears on
# its very first probe (APPEAR_AFTER=0): in the correct path B never probes
# at all (it exits at the lock check), but if single-flight were broken and B
# took over, it would converge immediately and re-install -- failing the
# exactly-once assertions loudly instead of hanging on a timeout.
# ---------------------------------------------------------------------------
make_project "upsilon" running
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/upsilon/config"
seed_ext_manifest nodejs $'alpha.installed\nbeta.missing\ngamma.missing\n'
printf 'alpha.installed\n' > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
# Expected test-first failure: the watcher script does not exist until the
# implementation lands.
[[ -x "$WATCH_SCRIPT" ]] \
  || fail "upsilon: scripts/_editor-ext-watch.sh does not exist yet (expected pre-implementation failure)"
# Probe counters, one per watcher: the stub advances each FILE independently,
# so A and B never see each other's probes.
rm -f "$WORK/upsilon-bg-count" "$WORK/upsilon-fg-count"
TMPDIR="$WORK/tmp16d"
export TMPDIR
mkdir -p "$TMPDIR"
ups_watch_log="${TMPDIR%/}/dce-ext-watch.upsilon.log"
# The test synchronizes on the first watcher's lock being FRESH -- its
# deadline file existing -- instead of the lock dir alone (0.1s poll, bounded
# at 10s): the mkdir -> deadline-write window inside the watcher would
# otherwise let B observe a half-taken lock and read it as stale. Waiting for
# the deadline then launching B immediately guarantees a true latecomer that
# must observe the fresh lock and log "already active"; A still holds the
# lock for ~5s, so the overlap survives even slow CI startup.
ups_lock="${TMPDIR%/}/dce-ext-watch.upsilon.lock"
ups_fg_rc=0
ups_bg_rc=0
DC_STUB_EXT_SERVER_ABSENT=0 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DC_STUB_EXT_SERVER_APPEAR_AFTER=25 DC_STUB_EXT_PROBE_COUNT="$WORK/upsilon-bg-count" \
  run_watcher upsilon vscode 0.2 15 >>"$ups_watch_log" 2>&1 &
ups_bg=$!
ups_lock_deadline=$(( SECONDS + 10 ))
while (( SECONDS < ups_lock_deadline )) && [[ ! -f "$ups_lock/deadline" ]]; do
  sleep 0.1
done
[[ -f "$ups_lock/deadline" ]] \
  || fail "upsilon: first watcher never took its lock ($ups_lock/deadline absent after 10s)"
DC_STUB_EXT_SERVER_ABSENT=0 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DC_STUB_EXT_SERVER_APPEAR_AFTER=0 DC_STUB_EXT_PROBE_COUNT="$WORK/upsilon-fg-count" \
  run_watcher upsilon vscode 0.2 10 >>"$ups_watch_log" 2>&1 || ups_fg_rc=$?
wait "$ups_bg" || ups_bg_rc=$?
# Defensive: POSIX-mode bash would persist env-prefix assignments on function
# calls past the call (see run_editor); drop the schedule vars so later
# sections start from a clean slate.
unset DC_STUB_EXT_SERVER_APPEAR_AFTER DC_STUB_EXT_PROBE_COUNT
[[ "$ups_fg_rc" -eq 0 && "$ups_bg_rc" -eq 0 ]] \
  || fail "upsilon: both watcher invocations must exit 0 (fg=$ups_fg_rc bg=$ups_bg_rc, log: $ups_watch_log)"

wait_for_pattern "$ups_watch_log" 'already active' 10 \
  || fail "upsilon: second watcher did not log 'already active' (log: $(cat "$ups_watch_log" 2>/dev/null || true))"
ups_n_beta="$(grep -cxF 'INSTALL beta.missing' "$INSTALL_LOG" || true)"
ups_n_gamma="$(grep -cxF 'INSTALL gamma.missing' "$INSTALL_LOG" || true)"
[[ "$ups_n_beta" -eq 1 ]] \
  || fail "upsilon: beta.missing installed $ups_n_beta times, expected exactly 1 (log: $(cat "$INSTALL_LOG"))"
[[ "$ups_n_gamma" -eq 1 ]] \
  || fail "upsilon: gamma.missing installed $ups_n_gamma times, expected exactly 1 (log: $(cat "$INSTALL_LOG"))"
# The first watcher was already reaped by `wait "$ups_bg"` above -- that wait
# IS the join, and the EXIT trap removes the lock synchronously before reap.
[[ ! -e "$ups_lock" ]] \
  || fail "upsilon: lock must be removed after the first watcher exits"
grep -Fq 'watch complete' "$ups_watch_log" \
  || fail "upsilon: watcher log missing completion line (got: $(cat "$ups_watch_log" 2>/dev/null || true))"
pass "Section 16d: concurrent watchers are single-flight; each missing id installed exactly once"

# ---------------------------------------------------------------------------
# (16e) Container stops mid-watch: the watcher must notice the container went
# away (backend_is_running fails -- the stubs re-read the running list file on
# every call), log it, and exit 0 without attempting any install. Invoked
# directly in the background with a generous timeout; phi is dropped from the
# running list ~0.8s in, so the "stopped" line must appear well before the
# timeout path could.
# ---------------------------------------------------------------------------
make_project "phi" running
: > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
TMPDIR="$WORK/tmp16e"
export TMPDIR
mkdir -p "$TMPDIR"
phi_watch_log="${TMPDIR%/}/dce-ext-watch.phi.log"
phi_rc=0
DC_STUB_EXT_SERVER_ABSENT=1 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DC_STUB_EXT_SERVER_APPEAR_AFTER='' DC_STUB_EXT_PROBE_COUNT='' \
  run_watcher phi vscode 0.5 10 >>"$phi_watch_log" 2>&1 &
phi_bg=$!
sleep 0.8
sed -i.bak '/^phi$/d' "$RUNNING_FILE"
rm -f "$RUNNING_FILE.bak"
wait "$phi_bg" || phi_rc=$?
unset DC_STUB_EXT_SERVER_APPEAR_AFTER DC_STUB_EXT_PROBE_COUNT
[[ "$phi_rc" -eq 0 ]] \
  || fail "phi: watcher exited non-zero after the container stopped (rc=$phi_rc, log: $phi_watch_log)"
wait_for_pattern "$phi_watch_log" 'stopped' 10 \
  || fail "phi: watcher log missing stopped line (got: $(cat "$phi_watch_log" 2>/dev/null || true))"
[[ ! -s "$INSTALL_LOG" ]] \
  || fail "phi: installs recorded for a stopped container (log: $(cat "$INSTALL_LOG"))"
# The watcher was already reaped by `wait "$phi_bg"` above -- that wait IS
# the join, and the EXIT trap removes the lock synchronously before reap.
[[ ! -e "${TMPDIR%/}/dce-ext-watch.phi.lock" ]] \
  || fail "phi: lock must be removed after the watcher exits"
pass "Section 16e: container stopped mid-watch -> watcher logs it and exits without installs"

# ---------------------------------------------------------------------------
# (16f) Pre-adoption + server absent: the silent no-op MUST stay silent. No
# manifests are seeded for chi and no scopes are declared, so editor.sh
# launches the editor and neither spawns a watcher, prints a background
# notice, nor touches TMPDIR. Regression guard expected to PASS both before
# and after the implementation. No join is needed: pre-adoption categorically
# spawns no watcher, and the lock+log absence assertions below prove none was
# ever created.
# ---------------------------------------------------------------------------
make_project "chi" running
: > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
: > "$CODE_LOG"
TMPDIR="$WORK/tmp16f"
export TMPDIR
mkdir -p "$TMPDIR"
DC_STUB_EXT_SERVER_ABSENT=1 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DCE_EXT_WATCH_INTERVAL=0.2 DCE_EXT_WATCH_TIMEOUT=1 \
  run_editor chi >"$WORK/sec16f.out" 2>"$WORK/err" || fail "editor chi exited non-zero
-- stderr:$(cat "$WORK/err")"
unset DCE_EXT_WATCH_INTERVAL DCE_EXT_WATCH_TIMEOUT

grep -Fq -- '--folder-uri vscode-remote://attached-container+' "$CODE_LOG" \
  || fail "chi: editor not launched (pre-adoption)"
grep -Fq 'background' "$WORK/sec16f.out" \
  && fail "chi: pre-adoption must not print a background notice (got: $(cat "$WORK/sec16f.out"))"
[[ ! -e "${TMPDIR%/}/dce-ext-watch.chi.lock" ]] \
  || fail "chi: watcher lock created for a pre-adoption project"
[[ ! -e "${TMPDIR%/}/dce-ext-watch.chi.log" ]] \
  || fail "chi: watcher log created for a pre-adoption project"
[[ ! -s "$INSTALL_LOG" ]] \
  || fail "chi: pre-adoption must not install anything (log: $(cat "$INSTALL_LOG"))"
pass "Section 16f: pre-adoption + server absent -> nothing spawned, nothing printed (silent no-op)"

# ---------------------------------------------------------------------------
# (16g) Stale lock takeover: a leftover lock whose deadline is in the past
# must NOT block a fresh watcher. The stale lock is removed and retaken; the
# fresh watcher converges immediately (APPEAR_AFTER=0 -> server present on
# the very first probe) and no "already active" line is ever logged.
# ---------------------------------------------------------------------------
make_project "psi" running
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/psi/config"
seed_ext_manifest nodejs $'alpha.installed\nbeta.missing\n'
: > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
TMPDIR="$WORK/tmp16g"
export TMPDIR
mkdir -p "$TMPDIR"
psi_lock="${TMPDIR%/}/dce-ext-watch.psi.lock"
psi_watch_log="${TMPDIR%/}/dce-ext-watch.psi.log"
mkdir -p "$psi_lock"
# Portable "10 seconds ago" (date -v-10S is macOS-only).
printf '%s\n' "$(($(date +%s) - 10))" > "$psi_lock/deadline"
psi_rc=0
DC_STUB_EXT_SERVER_ABSENT=0 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" \
  DC_STUB_EXT_SERVER_APPEAR_AFTER=0 DC_STUB_EXT_PROBE_COUNT='' \
  run_watcher psi vscode 0.2 10 >>"$psi_watch_log" 2>&1 || psi_rc=$?
unset DC_STUB_EXT_SERVER_APPEAR_AFTER DC_STUB_EXT_PROBE_COUNT
[[ "$psi_rc" -eq 0 ]] \
  || fail "psi: direct watcher invocation failed (rc=$psi_rc, log: $psi_watch_log)"
wait_for_pattern "$INSTALL_LOG" 'INSTALL beta.missing' 10 \
  || fail "psi: watcher did not take over the stale lock and install (log: $(cat "$INSTALL_LOG" 2>/dev/null || true))"
grep -Fq 'already active' "$psi_watch_log" \
  && fail "psi: stale lock was treated as still active (log: $(cat "$psi_watch_log" 2>/dev/null || true))"
# A foreground invocation's wait/exit IS the join: the EXIT trap must have
# removed the lock synchronously by the time the process is reaped.
[[ ! -e "$psi_lock" ]] || fail "psi: lock must be removed after a foreground watcher exits"
pass "Section 16g: stale lock is removed and retaken; the watcher converges"

# ---------------------------------------------------------------------------
# (16h) Apple mirror of 16a: the detached-watcher behavior is backend-neutral.
# Backend selection mirrors Section 6 (CONTAINER_BACKEND=apple in the project
# config + DC_STUB_APPLE_INSPECT_IMAGE for the attach-ref inspect); every 16a
# assertion carries over, with the apple-container launch URI.
# ---------------------------------------------------------------------------
make_project "omega" running
sed -i.bak 's/CONTAINER_BACKEND="docker"/CONTAINER_BACKEND="apple"/' "$DC_ROOT/omega/config"
rm -f "$DC_ROOT/omega/config.bak"
printf 'CONTAINER_OVERLAY_SCOPES="nodejs"\n' >> "$DC_ROOT/omega/config"
seed_ext_manifest nodejs $'alpha.installed\nbeta.missing\n'
printf 'alpha.installed\n' > "$CONTAINER_EXT_FILE"
: > "$INSTALL_LOG"
: > "$CODE_LOG"
TMPDIR="$WORK/tmp16h"
export TMPDIR
mkdir -p "$TMPDIR"
omega_watch_log="${TMPDIR%/}/dce-ext-watch.omega.log"
DC_STUB_EXT_SERVER_ABSENT=1 DC_STUB_CONTAINER_EXT="$CONTAINER_EXT_FILE" \
  DC_STUB_INSTALL_LOG="$INSTALL_LOG" DC_STUB_APPLE_INSPECT_IMAGE="dce-base:latest" \
  DCE_EXT_WATCH_INTERVAL=0.2 DCE_EXT_WATCH_TIMEOUT=2 \
  run_editor omega >"$WORK/sec16h.out" 2>"$WORK/err" || fail "editor omega (apple) exited non-zero
-- stderr:$(cat "$WORK/err")"
unset DCE_EXT_WATCH_INTERVAL DCE_EXT_WATCH_TIMEOUT

grep -Fq -- '--folder-uri vscode-remote://apple-container+' "$CODE_LOG" \
  || fail "omega: editor not launched on the apple path (got $(cat "$CODE_LOG"))"
grep -Fq 'VS Code Server not yet injected' "$WORK/sec16h.out" \
  || fail "omega: missing server-absent notice (got: $(cat "$WORK/sec16h.out"))"
grep -Fq 'background' "$WORK/sec16h.out" \
  || fail "omega: notice does not mention the background watcher (got: $(cat "$WORK/sec16h.out"))"
grep -Fq "$omega_watch_log" "$WORK/sec16h.out" \
  || fail "omega: notice missing the watcher log path (got: $(cat "$WORK/sec16h.out"))"
[[ ! -s "$INSTALL_LOG" ]] \
  || fail "omega: install ran in the launch path despite absent server (log: $(cat "$INSTALL_LOG"))"
[[ -e "${TMPDIR%/}/dce-ext-watch.omega.lock" || -f "$omega_watch_log" ]] \
  || fail "omega: no watcher lock or log -- nothing was spawned"
wait_watcher_done omega 10 || fail "omega: watcher lock still held 10s after spawn"
# The watcher is proven exited, so its log is final: one-shot greps.
grep -Fq 'not injected within' "$omega_watch_log" \
  || fail "omega: watcher log missing timeout line (got: $(cat "$omega_watch_log" 2>/dev/null || true))"
grep -Fq 'dce editor' "$omega_watch_log" \
  || fail "omega: timeout line missing the 'dce editor' retry hint (log: $(cat "$omega_watch_log" 2>/dev/null || true))"
pass "Section 16h: apple backend mirrors 16a (detached watcher + non-blocking launch)"

echo ""
echo "All editor contract checks passed."
