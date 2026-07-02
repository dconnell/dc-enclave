#!/usr/bin/env bash
# =============================================================================
# tests/contract/editor.sh - Stubbed-backend editor launcher coverage.
#
# Exercises scripts/editor.sh end-to-end without a real daemon or real editor
# binary: stub docker (for backend_is_running / start.sh's calls) and stub
# `code` (to capture the launch argv). Apple refusal, selection precedence,
# URI shape, and the start-if-not-running branch are all covered.
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
mkdir -p "$HOME/.config/Code/User"
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

# A minimal apple/container stub. editor.sh refuses BEFORE issuing any
# container commands (the refuse check is right after backend_use), so the
# stub only has to exist on PATH so backend_use's CLI-presence probe passes.
cat > "$STUB_DIR/container" <<'STUB'
#!/usr/bin/env bash
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
# Section 6 - apple backend refuses with actionable guidance
# ===========================================================================
make_project "zeta" running
# Flip the project config to apple backend (no real apple/container needed:
# editor.sh refuses BEFORE any backend probe of running state).
sed -i 's/CONTAINER_BACKEND="docker"/CONTAINER_BACKEND="apple"/' "$DC_ROOT/zeta/config"

if run_editor zeta 2>/dev/null; then
  fail "apple: editor should refuse on apple backend"
fi
err_out="$(run_editor zeta 2>&1 || true)"
grep -Fq "'dce editor' is unsupported on backend 'apple'" <<<"$err_out" \
  || fail "apple: missing refuse message (got: $err_out)"
grep -Eq 'Docker-compatible backend' <<<"$err_out" \
  || fail "apple: missing switch-backend guidance"

# Editor was NOT launched on apple (no code call recorded for zeta).
: > "$CODE_LOG"
run_editor zeta >/dev/null 2>&1 || true
[[ ! -s "$CODE_LOG" ]] || fail "apple: editor binary was invoked despite refuse"

pass "Section 6: apple backend refuses before any editor invocation"

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

cfg_kappa="$HOME/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/kappa.json"
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

cfg_lambda="$HOME/.config/Code/User/globalStorage/ms-vscode-remote.remote-containers/nameConfigs/lambda.json"
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

echo ""
echo "All editor contract checks passed."
