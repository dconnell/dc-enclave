#!/usr/bin/env bash
# =============================================================================
# tests/contract/doctor.sh - `dce doctor` preflight diagnostics coverage.
#
# doctor runs read-only probes across the host environment and each detected
# backend CLI (and optionally a single backend or project). This test installs
# stub docker/container/podman/colima binaries on a private PATH and a fake
# HOME, then asserts exit codes (nonzero on any failure) and output markers
# across host / all-backends / single-backend / project scopes.
#
# The stub is env-driven so each scenario flips one knob (runtime up/down,
# context drift, missing dce-base) and re-runs `dce doctor`.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DC_BIN="$ROOT_DIR/scripts/dce"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Lib functions are used to write a self-consistent devcontainer.json for the
# all-overlay regression below (Section 5a). Sourced in the TEST shell; the
# `dce doctor` invocations run as separate subprocesses.
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/devcontainer.sh"

# ---------------------------------------------------------------------------
# Stub backend CLIs (one script installed under docker/container/podman/colima).
# Env knobs (all default to the "healthy" state):
#   DC_STUB_DOCKER_UP / DC_STUB_APPLE_UP / DC_STUB_PODMAN_UP / DC_STUB_COLIMA_UP
#   DC_STUB_COLIMA_RUNTIME (docker|containerd)
#   DC_STUB_DOCKER_CONTEXTS        (newline list for `docker context ls`)
#   DC_STUB_DOCKER_CONTEXT_ACTIVE  (what `docker context show` returns when
#                                   DOCKER_CONTEXT is unset)
#   DC_STUB_HAS_DEVBASE            (image ls emits dce-base:latest)
#   DC_STUB_CONTAINERS             (newline list for `docker ps`)
#   DC_STUB_APPLE_VERSION          (what `container --version` reports; default 1.0)
#   DC_STUB_APPLE_DNS_DOMAIN       (1 = `system dns list` shows the gateway domain)
#   DC_STUB_APPLE_PROBE            (doctor's in-container gateway probe outcome:
#                                   refused|ok|timeout|noutil)
#   DC_STUB_APPLE_CONTAINERS       (newline list for `container ls -q` (running))
#   DC_STUB_APPLE_STOPPED          (extra stopped-only names for `ls -a -q`)
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/_backend_stub" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
show_ctx() {
  # backend_use pins context by exporting DOCKER_CONTEXT; honor it when set so
  # colima/orbstack context checks resolve correctly.
  printf '%s\n' "${DOCKER_CONTEXT:-${DC_STUB_DOCKER_CONTEXT_ACTIVE:-default}}"
}
case "$name" in
  docker)
    case "${1:-}" in
      info)    [[ "${DC_STUB_DOCKER_UP:-1}" == "1" ]] && exit 0; exit 1 ;;
      --version|version) echo "Docker version 99.0 (stub)"; exit 0 ;;
      buildx)
        if [[ "${2:-}" == "version" ]]; then
          [[ "${DC_STUB_BUILDX:-1}" == "1" ]] && { echo "github.com/docker/buildx v99.0.0-stub"; exit 0; }
          exit 1
        fi
        ;;
      context)
        if [[ "${2:-}" == "show" ]]; then show_ctx; exit 0
        elif [[ "${2:-}" == "ls" ]]; then printf '%s\n' "${DC_STUB_DOCKER_CONTEXTS:-default}"; exit 0
        fi
        exit 0 ;;
      image)
        if [[ "${2:-}" == "ls" ]]; then
          [[ "${DC_STUB_HAS_DEVBASE:-1}" == "1" ]] && printf 'dce-base:latest\n'
          printf 'dce-img-aaaaaaaaaaaaaaaa:latest\n'
          exit 0
        fi
        exit 0 ;;
      exec)
        _all="$*"
        # Simulate the container's ~/.git-credentials for the token-drift probe.
        for _a in "$@"; do
          case "$_a" in
            *'test -f ~/.git-credentials'*) [[ -n "${DC_STUB_GIT_CREDS:-}" ]]; exit ;;
            *'cat ~/.git-credentials'*) printf '%s' "${DC_STUB_GIT_CREDS:-}"; exit 0 ;;
          esac
        done
        # _dce_ext_vscode_container_bin resolver: sh -c '...command -v code...'.
        if [[ "$3" == "sh" && "$4" == "-c" && "$_all" == *"command -v code"* ]]; then
          printf '%s\n' '/home/dev/.vscode-server/bin/stubhash/bin/code'
          exit 0
        fi
        # dce_ext_list_installed: <bin> --list-extensions.
        case "${*: -2}" in
          *'code --list-extensions') printf '%s' "${DC_STUB_CONTAINER_EXT:-}"; exit 0 ;;
        esac
        exit 0 ;;
      ps) printf '%s\n' "${DC_STUB_CONTAINERS:-}"; exit 0 ;;
    esac
    exit 0 ;;
  container)
    case "${1:-}" in
      system)
        # Reachability is determined by `system status` (backend_system_info);
        # `system info` is gated too so neither subcommand reads as up.
        if [[ "${2:-}" == "status" || "${2:-}" == "info" ]]; then
          [[ "${DC_STUB_APPLE_UP:-1}" == "1" ]] && exit 0
          exit 1
        fi
        if [[ "${2:-}" == "dns" && "${3:-}" == "list" ]]; then
          # backend_apple_dns_domain_present parses --format json first (bare
          # array), falling back to the raw table; emit the matching shape.
          if [[ "${DC_STUB_APPLE_DNS_DOMAIN:-1}" == "1" ]]; then
            if [[ "${4:-}" == "--format" ]]; then
              printf '["host.container.internal"]\n'
            else
              printf 'DOMAIN\nhost.container.internal\n'
            fi
          else
            if [[ "${4:-}" == "--format" ]]; then printf '[]\n'; else printf 'DOMAIN\n'; fi
          fi
          exit 0
        fi
        exit 0 ;;
      --version) printf 'container stub %s\n' "${DC_STUB_APPLE_VERSION:-1.0}"; exit 0 ;;
      image)
        if [[ "${2:-}" == "ls" ]]; then
          [[ "${DC_STUB_HAS_DEVBASE:-1}" == "1" ]] && printf 'dce-base:latest\n'
          exit 0
        fi
        exit 0 ;;
      ls)
        # `ls -q` (backend_is_running) vs `ls -a -q` (backend_exists): the
        # stopped-only list is appended for -a so state probes can tell
        # "stopped" from "never created".
        printf '%s\n' "${DC_STUB_APPLE_CONTAINERS:-}"
        if [[ "${2:-}" == "-a" && -n "${DC_STUB_APPLE_STOPPED:-}" ]]; then
          printf '%s\n' "${DC_STUB_APPLE_STOPPED}"
        fi
        exit 0 ;;
      ps) exit 0 ;;
      exec)
        # Mirror the docker stub's credential probes (git-token drift check).
        for _a in "$@"; do
          case "$_a" in
            *'test -f ~/.git-credentials'*) [[ -n "${DC_STUB_GIT_CREDS:-}" ]]; exit ;;
            *'cat ~/.git-credentials'*) printf '%s' "${DC_STUB_GIT_CREDS:-}"; exit 0 ;;
          esac
        done
        # doctor's host.docker.internal gateway probe (see
        # _doctor_apple_gateway_probe in scripts/doctor.sh): the probe emits a
        # __DCE_PROBE_RC__ marker when it actually ran, and its exit code
        # carries the outcome -- refused (1), connect ok (0), timeout (124),
        # tools missing (127, no marker). Knob per scenario.
        for _a in "$@"; do
          case "$_a" in
            */dev/tcp/*)
              case "${DC_STUB_APPLE_PROBE:-refused}" in
                ok)      printf '__DCE_PROBE_RC__=0\n'; exit 0 ;;
                refused) printf '__DCE_PROBE_RC__=1\n'; exit 1 ;;
                timeout) exit 124 ;;
                noutil)  exit 127 ;;
              esac
              ;;
          esac
        done
        exit 0 ;;
    esac
    exit 0 ;;
  podman)
    case "${1:-}" in
      info)    [[ "${DC_STUB_PODMAN_UP:-1}" == "1" ]] && exit 0; exit 1 ;;
      --version) echo "podman 99.0 (stub)"; exit 0 ;;
      image)
        if [[ "${2:-}" == "ls" ]]; then
          [[ "${DC_STUB_HAS_DEVBASE:-1}" == "1" ]] && printf 'dce-base:latest\n'
          exit 0
        fi
        exit 0 ;;
      ps) exit 0 ;;
    esac
    exit 0 ;;
  colima)
    case "${1:-}" in
      status)
        if [[ "${DC_STUB_COLIMA_UP:-1}" == "1" ]]; then
          echo "runtime: ${DC_STUB_COLIMA_RUNTIME:-docker}"
          exit 0
        fi
        exit 1 ;;
      version) echo "colima version 99.0 (stub)"; exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_backend_stub"
for b in docker container podman colima; do
  cp "$STUB_DIR/_backend_stub" "$STUB_DIR/$b"
done

# Shared fake HOME with a healthy global config + overlays.
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dc-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

# Put the stub CLIs on PATH for the whole test shell. $ORIG_PATH is retained so
# individual scenarios can run with a stripped PATH (e.g. podman absent).
ORIG_PATH="$PATH"
export PATH="$STUB_DIR:$ORIG_PATH"

# Remove directories containing a specific executable name from a PATH string.
# This keeps "CLI missing" scenarios deterministic even when the host/container
# image already has that CLI installed on PATH.
path_without_cmd() {  # <cmd> <path>
  local cmd="$1" in_path="$2"
  local out="" dir=""
  local -a dirs=()
  IFS=':' read -r -a dirs <<< "$in_path"
  for dir in "${dirs[@]}"; do
    [[ -n "$dir" ]] || continue
    if [[ -x "$dir/$cmd" ]]; then
      continue
    fi
    if [[ -n "$out" ]]; then
      out+=":"
    fi
    out+="$dir"
  done
  printf '%s' "$out"
}

ORIG_PATH_NO_DOCKER="$(path_without_cmd docker "$ORIG_PATH")"
ORIG_PATH_NO_PODMAN="$(path_without_cmd podman "$ORIG_PATH")"
ORIG_PATH_NO_COLIMA="$(path_without_cmd colima "$ORIG_PATH")"

# path_without_cmd strips the WHOLE directory holding a CLI; on a Homebrew mac
# that dir also holds Bash 5. dce `exec`s subcommand scripts, re-triggering the
# `#!/usr/bin/env bash` shebang, which would then resolve to /bin/bash 3.2 and
# abort with "requires Bash 4+". Provide a dir that always exposes this test's
# Bash 4+ on PATH so the shebang chain keeps working under the filtered PATHs.
BASH_BIN="$WORK/bin_bash"
mkdir -p "$BASH_BIN"
ln -sf "$BASH" "$BASH_BIN/bash"

# path_without_cmd strips the WHOLE directory holding a container CLI; on Linux
# CI runners docker lives in /usr/bin (and /bin symlinks to it on merged-usr),
# so coreutils (dirname, cut, grep, ...) go with it and `dce doctor` can't even
# start. On macOS dev this is harmless (Docker is in a Homebrew dir, coreutils
# in /usr/bin). Expose those coreutils WITHOUT the container CLIs by symlinking
# every executable in the system bin dirs except docker/podman/container/colima.
COREUTILS_BIN="$WORK/bin_coreutils"
mkdir -p "$COREUTILS_BIN"
for _src in /usr/bin /bin; do
  [[ -d "$_src" ]] || continue
  for _f in "$_src"/*; do
    [[ -f "$_f" && -x "$_f" ]] || continue
    _b="${_f##*/}"
    case "$_b" in docker|podman|container|colima) continue ;; esac
    [[ -e "$COREUTILS_BIN/$_b" ]] || ln -s "$_f" "$COREUTILS_BIN/$_b"
  done
done

# Default to a healthy Colima state (colima context listed + active, docker up)
# so the colima stub always present on PATH does not read as "drifted" by default.
# Drift scenarios below override these inline.
export DC_STUB_DOCKER_CONTEXTS="default colima"
export DC_STUB_DOCKER_CONTEXT_ACTIVE=colima

# Run `dce doctor` with the current PATH/HOME and a clean backend override.
# Called DIRECTLY (not via $()) so the exit code reaches the caller's shell:
# the captured text lands in $RUN_OUT and the exit code in $RUN_RC. (Calling it
# inside $() would run it in a subshell and lose $RUN_RC.)
RUN_RC=0
RUN_OUT=""
run_doctor() {
  local out
  set +e
  out="$(HOME="$HOME" /usr/bin/env -u CONTAINER_BACKEND "$DC_BIN" doctor "$@" 2>&1)"
  RUN_RC=$?
  set -e
  RUN_OUT="$out"
}

# A stub dir that omits podman, for "backend CLI missing" scenarios.
STUB_NOP="$WORK/bin_nop"
mkdir -p "$STUB_NOP"
for b in docker container colima; do cp "$STUB_DIR/_backend_stub" "$STUB_NOP/$b"; done

# A stub dir that omits docker, for "docker CLI missing" scenarios.
STUB_NODOCKER="$WORK/bin_nodocker"
mkdir -p "$STUB_NODOCKER"
for b in container podman colima; do cp "$STUB_DIR/_backend_stub" "$STUB_NODOCKER/$b"; done

# ---------------------------------------------------------------------------
# Section 1 - host checks
# ---------------------------------------------------------------------------
run_doctor; out="$RUN_OUT"
[[ "$RUN_RC" -eq 0 ]] || fail "healthy host/all: expected exit 0, got $RUN_RC
$out"
[[ "$out" == *"All checks passed"* ]] || fail "healthy run missing summary
$out"
[[ "$out" == *$'\xe2\x9c\x93'* ]] || fail "no pass marker (\xe2\x9c\x93) in output
$out"
pass "healthy run: exit 0 + summary + pass markers"

# Missing global config -> host failure, nonzero.
rm "$DC_ROOT/config"
run_doctor; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "missing global config: expected nonzero, got 0
$out"
[[ "$out" == *$'\xe2\x9c\x97'* ]] \
  || fail "missing config: no fail marker (\xe2\x9c\x97)
$out"
[[ "$out" == *"Global config"* ]] || fail "missing config: no 'Global config' line
$out"
pass "missing global config: nonzero + fail marker"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

# Missing buildx with docker CLI present -> host failure (BuildKit preflight).
export DC_STUB_BUILDX=0
run_doctor; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "missing buildx: expected nonzero"
printf '%s' "$out" | grep -qi 'buildx plugin' \
  || fail "missing buildx: expected buildx failure detail\n$out"
export DC_STUB_BUILDX=1
pass "missing buildx: host check fails with install guidance"

# Team root missing -> host failure, nonzero.
rm -rf "$TEAM_DIR"
run_doctor; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "missing overlays dir: expected nonzero, got 0
$out"
[[ "$out" == *"DC_TEAM_DIR"* ]] || fail "missing team root: no DC_TEAM_DIR check line
$out"
pass "missing team root: nonzero"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"

# Malformed DC_TEAM_DIR (unquoted -> rejected by hardened parser).
{
  printf 'DC_TEAM_DIR=%s\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"
run_doctor; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "unquoted DC_TEAM_DIR: expected nonzero"
pass "malformed (unquoted) DC_TEAM_DIR rejected"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

# ---------------------------------------------------------------------------
# Section 2 - all-backends detection + per-backend probes
# ---------------------------------------------------------------------------
# docker + podman + container stubs present -> three backend sections.
run_doctor; out="$RUN_OUT"
for b in docker podman apple; do
  [[ "$out" == *"Backend: $b"* ]] || fail "all-mode missing Backend: $b section
$out"
done
[[ "$out" == *"dce-base:latest"* ]] || fail "per-backend dce-base check missing
$out"
pass "all-mode: detected docker/podman/apple + dce-base checks"

# Runtime down on docker -> docker section fails, overall nonzero.
DC_STUB_DOCKER_UP=0 run_doctor; out="$RUN_OUT"
{ printf '%s' "$out" | grep -q "Runtime reachable" && printf '%s' "$out" | grep -Eq 'systemctl|service docker|Docker Desktop'; } \
  || fail "docker down: missing runtime-reachable failure detail
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "docker down: expected nonzero overall"
pass "docker runtime down: reported + nonzero"

# dce-base missing on docker -> failure.
DC_STUB_HAS_DEVBASE=0 run_doctor; out="$RUN_OUT"
{ printf '%s' "$out" | grep -q "dce-base:latest missing"; } \
  || fail "missing dce-base: no failure detail
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "missing dce-base: expected nonzero"
pass "missing dce-base: reported + nonzero"
export DC_STUB_HAS_DEVBASE=1

# podman unreachable -> reported.
DC_STUB_PODMAN_UP=0 run_doctor; out="$RUN_OUT"
[[ "$out" == *"Backend: podman"* ]] || fail "podman section missing
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "podman down: expected nonzero"
pass "podman runtime down: reported + nonzero"
export DC_STUB_PODMAN_UP=1

# ---------------------------------------------------------------------------
# Section 3 - colima drift (the headline support case)
# ---------------------------------------------------------------------------
# Healthy colima: colima CLI present, colima context listed & active, docker up.
DC_STUB_DOCKER_CONTEXTS="default colima" DC_STUB_DOCKER_CONTEXT_ACTIVE=colima \
  DC_STUB_COLIMA_UP=1 run_doctor; out="$RUN_OUT"
[[ "$out" == *"Backend: colima"* ]] || fail "healthy colima: section missing
$out"
[[ "$out" == *"Colima docker context active"* ]] || fail "colima context check missing
$out"
pass "healthy colima: detected + context check present"

# Colima context drifted: colima CLI present but active docker context is not
# colima. The context check must fail and pinpoint the fix.
DC_STUB_DOCKER_CONTEXTS="default colima" DC_STUB_DOCKER_CONTEXT_ACTIVE=default \
  DC_STUB_COLIMA_UP=1 run_doctor; out="$RUN_OUT"
{ printf '%s' "$out" | grep -q "Colima docker context active" \
  && printf '%s' "$out" | grep -Eq "context not pointing|docker context use colima"; } \
  || fail "colima drift: missing context-failure detail
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "colima drift: expected nonzero"
pass "colima context drift: pinpointed + nonzero"

# Colima wrong runtime (containerd) -> runtime check fails with recreate hint.
DC_STUB_DOCKER_CONTEXTS="default colima" DC_STUB_DOCKER_CONTEXT_ACTIVE=colima \
  DC_STUB_COLIMA_UP=1 DC_STUB_COLIMA_RUNTIME=containerd run_doctor; out="$RUN_OUT"
{ printf '%s' "$out" | grep -q "Colima runtime is docker" \
  && printf '%s' "$out" | grep -q "colima start --runtime docker"; } \
  || fail "colima runtime: missing failure detail
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "colima wrong runtime: expected nonzero"
pass "colima non-docker runtime: pinpointed + nonzero"

# Restore the healthy default colima state for subsequent sections.
export DC_STUB_DOCKER_CONTEXT_ACTIVE=colima DC_STUB_COLIMA_RUNTIME=docker

# ---------------------------------------------------------------------------
# Section 4 - scope: single backend, unknown scope
# ---------------------------------------------------------------------------
# `dce doctor docker` checks only docker (no podman/apple sections).
run_doctor docker; out="$RUN_OUT"
[[ "$out" == *"Backend: docker"* ]] || fail "scoped docker: section missing
$out"
[[ "$out" != *"Backend: podman"* ]] || fail "scoped docker: should not list podman
$out"
[[ "$out" != *"Backend: apple"* ]] || fail "scoped docker: should not list apple
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "scoped healthy docker: expected 0, got $RUN_RC"
pass "single-backend scope: only that backend"

# `dce doctor <unknown>` exits nonzero with guidance.
run_doctor nosuchbackend; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "unknown scope: expected nonzero"
[[ "$out" == *"Unknown backend or project"* ]] || fail "unknown scope: no guidance
$out"
pass "unknown scope: nonzero + guidance"

# `dce doctor <backend with CLI missing>`: docker absent from PATH -> fail.
set +e
out="$(PATH="$BASH_BIN:$STUB_NODOCKER:$ORIG_PATH_NO_DOCKER:$COREUTILS_BIN" HOME="$HOME" /usr/bin/env -u CONTAINER_BACKEND \
        "$DC_BIN" doctor docker 2>&1)"
RUN_RC=$?
set -e
[[ "$RUN_RC" -ne 0 ]] || fail "missing-cli backend scope: expected nonzero"
{ printf '%s' "$out" | grep -Eq "CLI installed"; } \
  || fail "missing-cli backend scope: no 'CLI installed' check
$out"
pass "backend with missing CLI: reported + nonzero"

# ---------------------------------------------------------------------------
# Section 5 - project scope
# ---------------------------------------------------------------------------
make_project() {  # <name> <backend> <image> [token-content]
  local name="$1" backend="$2" image="${3:-dce-base:latest}" token="${4:-}"
  local pdir="$DC_ROOT/projects/$name"
  mkdir -p "$pdir"
  chmod 700 "$pdir"
  local cfg="$pdir/config"
  cat > "$cfg" <<EOF
CONTAINER_PROJECT="$name"
CONFIG_SCHEMA_VERSION="2"
CONTAINER_OVERLAY_SCOPES=""
CONTAINER_IMAGE="$image"
CONTAINER_BACKEND="$backend"
CONTAINER_CPUS=""
CONTAINER_MEMORY=""
SECRET_DIR="$pdir"
SSH_KEY_PATH="$pdir/ssh_key"
TOKEN_FILE="$pdir/github-token"
NPMRC_PATH="$pdir/.npmrc"
REPO_NAMES=($name)
REPO_PATHS=("$WORK/repos/$name")
PORTS=()
CONTAINER_HIDDEN_PATHS=()
CONTAINER_NETWORKS=()
EOF
  chmod 600 "$cfg"
  # ssh key present, token optionally filled.
  : > "$pdir/ssh_key"; chmod 600 "$pdir/ssh_key"
  if [[ -n "$token" ]]; then printf '%s\n' "$token" > "$pdir/github-token"
  else printf 'ghp_REPLACE_ME\n' > "$pdir/github-token"; fi
  chmod 600 "$pdir/github-token"
}

# Healthy project on docker.
make_project alpha docker dce-base:latest "ghp_realtoken"
DC_STUB_CONTAINERS="alpha" run_doctor alpha; out="$RUN_OUT"
[[ "$out" == *"Project: alpha"* ]] || fail "project scope: no Project header
$out"
[[ "$out" == *"Config loads"* ]] || fail "project scope: no config-loads check
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "healthy project: expected 0, got $RUN_RC
$out"
pass "project scope: healthy project -> exit 0"

# Project with placeholder token -> secrets failure, nonzero.
make_project beta docker dce-base:latest ""
DC_STUB_CONTAINERS="beta" run_doctor beta; out="$RUN_OUT"
{ printf '%s' "$out" | grep -Eq "GitHub token"; } \
  || fail "placeholder token: no token check
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "placeholder token project: expected nonzero"
pass "project with placeholder token: reported + nonzero"

# Project referencing a missing image -> failure.
make_project gamma docker dce-img-deadbeefdeadbeef:latest "ghp_realtoken"
run_doctor gamma; out="$RUN_OUT"
{ printf '%s' "$out" | grep -Eq "image|Image"; } \
  || fail "missing image: no image check line
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "missing image project: expected nonzero"
pass "project with missing image: reported + nonzero"

# Project whose recorded backend CLI is missing -> failure.
make_project delta podman dce-base:latest "ghp_realtoken"
set +e
out="$(PATH="$BASH_BIN:$STUB_NOP:$ORIG_PATH_NO_PODMAN:$COREUTILS_BIN" HOME="$HOME" /usr/bin/env -u CONTAINER_BACKEND \
        "$DC_BIN" doctor delta 2>&1)"
RUN_RC=$?
set -e
[[ "$RUN_RC" -ne 0 ]] || fail "project backend CLI missing: expected nonzero"
pass "project backend unavailable: reported + nonzero"

# ---------------------------------------------------------------------------
# Section 5a - devcontainer drift vs the auto-layered "all" overlay (regression)
# ---------------------------------------------------------------------------
# A Containerfile.all overlay auto-layers on EVERY project (scopes.sh), so a
# no-scope project composes to a derived (base+all) image. Doctor must resolve
# effective scopes (auto-prepending "all") when deriving its expected
# devcontainer state, or it false-reports "managed fields drifted" for every
# project. See _dce_doctor_effective_scopes in scripts/doctor.sh.
printf 'RUN echo ALL-OVERLAY\n' > "$USER_DIR/overlays/Containerfile.all"
# The lib helpers read the DC_TEAM_DIR/DC_USER_DIR globals (set locally, not
# exported, so the `dce doctor` subprocess still loads its own from the config).
# shellcheck disable=SC2034  # read cross-file by dce_team_overlays_dir et al.
DC_TEAM_DIR="$TEAM_DIR"
# shellcheck disable=SC2034
DC_USER_DIR="$USER_DIR"
allo_img="$(dce_image_ref_from_scopes "$TEAM_DIR/overlays" "$USER_DIR/overlays" "")"
make_project alloverlay docker "$allo_img" "ghp_realtoken"
allo_dc="$DC_ROOT/projects/alloverlay/devcontainer.json"
mkdir -p "$DC_ROOT/projects/alloverlay"
allo_bf="$(dce_devcontainer_build_file "$ROOT_DIR" \
  "$(dce_effective_scopes_csv "$TEAM_DIR/overlays" "$USER_DIR/overlays" "")")"
dce_devcontainer_render "alloverlay" "$allo_bf" "$ROOT_DIR" "$DC_ROOT/projects/alloverlay" \
  "" "" "" "" "ssh" "" "" "$(printf 'alloverlay\t%s' "$WORK/repos/alloverlay")" \
  > "$allo_dc"
DC_STUB_CONTAINERS="" run_doctor alloverlay; out="$RUN_OUT"
[[ "$out" != *"managed fields drifted"* ]] \
  || fail "all-overlay project falsely reported devcontainer drift:
$out"
pass "all-overlay: doctor resolves effective scopes (no false devcontainer drift)"
rm -f "$USER_DIR/overlays/Containerfile.all"

# ---------------------------------------------------------------------------
# Section 5b - project token-drift probe (PAT only, read-only, hash-compared)
# ---------------------------------------------------------------------------
# The drift probe compares the host PAT to the container's ~/.git-credentials:
# match -> pass; differs -> _bad with the rotate-token fix; absent -> info;
# ssh/none -> skipped. DC_STUB_GIT_CREDS is what the stub returns for
# `cat ~/.git-credentials` (and gates the `test -f` probe).
make_project drift_match docker dce-base:latest "ghp_realtoken"
DC_STUB_CONTAINERS="drift_match" DC_STUB_GIT_CREDS=$'https://x-access-token:ghp_realtoken@github.com\n' \
  run_doctor drift_match; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq "git token in sync with container" \
  || fail "drift match: missing 'git token in sync' check
$out"
if printf '%s' "$out" | grep -Eq 'container token differs|rotate-token drift_match'; then
  fail "drift match: must not report drift
$out"
fi
[[ "$RUN_RC" -eq 0 ]] || fail "drift match: expected exit 0, got $RUN_RC"
pass "doctor: PAT in sync -> pass, no drift report"

make_project drift_stale docker dce-base:latest "ghp_realtoken"
DC_STUB_CONTAINERS="drift_stale" DC_STUB_GIT_CREDS=$'https://x-access-token:STALE@github.com\n' \
  run_doctor drift_stale; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq "git token in sync with container" \
  || fail "drift stale: missing check line
$out"
printf '%s' "$out" | grep -Fq "container token differs from host token" \
  || fail "drift stale: missing drift detail
$out"
printf '%s' "$out" | grep -Fq "dce rotate-token drift_stale" \
  || fail "drift stale: missing rotate-token fix command
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "drift stale: expected nonzero"
pass "doctor: stale container token -> reported + rotate-token fix + nonzero"

make_project drift_absent docker dce-base:latest "ghp_realtoken"
DC_STUB_CONTAINERS="drift_absent" DC_STUB_GIT_CREDS="" run_doctor drift_absent; out="$RUN_OUT"
printf '%s' "$out" | grep -Fqi 'not yet in container' \
  || fail "drift absent: missing info line
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "drift absent: should be info, not a failure (got $RUN_RC)"
pass "doctor: container token absent -> info (not a failure)"

# ssh/none auth: drift probe skipped (no PAT to compare).
make_project drift_ssh docker dce-base:latest ""
DC_STUB_CONTAINERS="drift_ssh" run_doctor drift_ssh; out="$RUN_OUT"
printf '%s' "$out" | grep -Eq 'git token in sync.*skipped.*ssh/none' \
  || fail "drift ssh: expected skipped check
$out"
pass "doctor: ssh/none auth -> drift check skipped"

# ---------------------------------------------------------------------------
# Section 5c - editor-extension drift probes (plans/extensions.md §8)
# ---------------------------------------------------------------------------
# Declaration drift = manifest set vs recorded customizations.vscode.extensions
# (FAIL -> sync-vscode). Runtime drift = installed vs declared (informational).
# Both need the managed devcontainer.json + adopted manifests; otherwise skipped.
make_project extdoc docker dce-base:latest "ghp_realtoken"
# Adopt: a user all.txt manifest exists. Seed a MANAGED devcontainer.json IN
# SYNC (repo bind + managed /workspace/.cache volume; no localWorkspaceFolder
# mount -- the v2 mount shape doctor's drift comparator expects).
mkdir -p "$USER_DIR/extensions/vscode"
printf 'a.b\n' > "$USER_DIR/extensions/vscode/all.txt"
EXTDOC_DC="$DC_ROOT/projects/extdoc/devcontainer.json"
mkdir -p "$DC_ROOT/projects/extdoc"
write_extdoc_dc() {  # <extensions-json-array>
  local extarr="$1"
  cat > "$EXTDOC_DC" <<EOF
{
  "build": { "dockerfile": "$ROOT_DIR/Containerfiles/Containerfile.base" },
  "workspaceFolder": "/workspace",
  "remoteUser": "dev",
  "postCreateCommand": "true",
  "mounts": [
    "source=$WORK/repos/extdoc,target=/workspace/extdoc,type=bind",
    "source=$(dce_cache_volume_name extdoc),target=/workspace/.cache,type=volume"
  ],
  "customizations": { "vscode": { "extensions": $extarr } }
}
EOF
}
write_extdoc_dc '["a.b"]'
rm -rf "$WORK/repos/extdoc/.devcontainer"
# Runtime match: container installs exactly a.b.
DC_STUB_CONTAINERS="extdoc" DC_STUB_CONTAINER_EXT=$'a.b\n' run_doctor extdoc; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq "devcontainer.json in sync" \
  || fail "ext match: missing devcontainer.json in-sync check
$out"
printf '%s' "$out" | grep -Fq "editor extensions in sync with container" \
  || fail "ext match: missing extension in-sync check
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "ext match: expected exit 0 (got $RUN_RC)
$out"
pass "doctor: extensions in sync -> ok (declaration + runtime)"

# Declaration drift: recorded array differs from the manifest set.
write_extdoc_dc '["stale.id"]' 
DC_STUB_CONTAINERS="extdoc" DC_STUB_CONTAINER_EXT=$'a.b\n' run_doctor extdoc; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq "devcontainer.json in sync" \
  || fail "ext decl-drift: missing check line
$out"
printf '%s' "$out" | grep -Fq "sync-vscode extdoc" \
  || fail "ext decl-drift: missing sync-vscode fix
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "ext decl-drift: declaration drift must be nonzero"
pass "doctor: extension declaration drift -> fail + sync-vscode fix"

# Declaration drift must still be checked when the container is STOPPED: this is
# static config drift (manifest vs devcontainer.json), not runtime state.
write_extdoc_dc '["stale.stopped"]' 
DC_STUB_CONTAINERS="" run_doctor extdoc; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq "sync-vscode extdoc" \
  || fail "ext decl-drift stopped: missing sync-vscode fix\n$out"
[[ "$RUN_RC" -ne 0 ]] || fail "ext decl-drift stopped: declaration drift must be nonzero"
pass "doctor: declaration drift still fails when container is stopped"

# Remaining runtime-drift probes in this section self-prefix DC_STUB_CONTAINERS
# on each run_doctor call (the bare assignment previously here was non-exported
# and thus never reached the stub subprocess; shellcheck flagged it as unused).

# Runtime drift: installed set has an undeclared extension (informational, not fail).
write_extdoc_dc '["a.b"]'
DC_STUB_CONTAINERS="extdoc" DC_STUB_CONTAINER_EXT=$'a.b\nextra.installed\n' run_doctor extdoc; out="$RUN_OUT"
printf '%s' "$out" | grep -Fqi 'runtime drift' \
  || fail "ext runtime-drift: missing info line
$out"
printf '%s' "$out" | grep -Fq "dce extensions diff extdoc" \
  || fail "ext runtime-drift: missing diff fix
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "ext runtime-drift: must be informational (exit 0), got $RUN_RC"
pass "doctor: extension runtime drift -> informational (not a failure)"

# Pre-adoption (no manifests): both extension checks skip cleanly.
make_project extpre docker dce-base:latest "ghp_realtoken"
DC_STUB_CONTAINERS="extpre" run_doctor extpre; out="$RUN_OUT"
printf '%s' "$out" | grep -Eq 'editor extensions in sync.*skipped' \
  || fail "ext pre-adoption: expected skipped extension check
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "ext pre-adoption: expected exit 0 (got $RUN_RC)"
pass "doctor: pre-adoption -> extension probes skipped"

# ---------------------------------------------------------------------------
# Section 6 - OS-specific remediation hints
# ---------------------------------------------------------------------------
# Force a platform deterministically with uname stubs so assertions do not
# depend on the host running the tests. platform_os() reads `uname -s` (and
# /proc/version for WSL2); a Darwin stub -> macos, a Linux stub -> linux.
make_uname_stub() {  # <dir> <uname -s value>
  local d="$1" val="$2"
  mkdir -p "$d"
  cat > "$d/uname" <<UNAME
#!/usr/bin/env bash
case "\${1:-}" in
  -s|"") printf '%s\n' "$val" ;;
  *) /usr/bin/uname "\$@" 2>/dev/null || /bin/uname "\$@" ;;
esac
UNAME
  chmod +x "$d/uname"
}
make_uname_stub "$WORK/bin_macos" Darwin
make_uname_stub "$WORK/bin_linux" Linux

# A stub dir that omits colima, for "colima CLI missing" scenarios.
STUB_NOCOLIMA="$WORK/bin_nocolima"
mkdir -p "$STUB_NOCOLIMA"
for b in docker container podman; do cp "$STUB_DIR/_backend_stub" "$STUB_NOCOLIMA/$b"; done

# docker unreachable: Linux -> systemctl/service; macOS -> Docker Desktop.
export DC_STUB_DOCKER_UP=0
PATH="$WORK/bin_linux:$PATH" run_doctor; out="$RUN_OUT"
printf '%s' "$out" | grep -Eq 'systemctl|service docker' \
  || fail "linux: docker-unreachable hint lacks systemctl/service
$out"
PATH="$WORK/bin_macos:$PATH" run_doctor; out="$RUN_OUT"
printf '%s' "$out" | grep -q 'Docker Desktop' \
  || fail "macos: docker-unreachable hint lacks Docker Desktop
$out"
export DC_STUB_DOCKER_UP=1
pass "docker-unreachable hint is OS-specific (linux vs macos)"

# colima CLI missing: macOS -> brew; Linux -> distro package (no brew).
# $BASH_BIN (this test's Bash 4+) is prepended to the filtered PATH because
# path_without_cmd strips the Homebrew dir that holds BOTH colima and Bash 5;
# without it, dce's subcommand shebang would resolve to /bin/bash 3.2 and abort.
set +e
out="$(PATH="$BASH_BIN:$WORK/bin_linux:$STUB_NOCOLIMA:$ORIG_PATH_NO_COLIMA:$COREUTILS_BIN" HOME="$HOME" \
        /usr/bin/env -u CONTAINER_BACKEND "$DC_BIN" doctor colima 2>&1)"
RUN_RC=$?
out_mac="$(PATH="$BASH_BIN:$WORK/bin_macos:$STUB_NOCOLIMA:$ORIG_PATH_NO_COLIMA:$COREUTILS_BIN" HOME="$HOME" \
        /usr/bin/env -u CONTAINER_BACKEND "$DC_BIN" doctor colima 2>&1)"
set -e
[[ "$RUN_RC" -ne 0 ]] || fail "colima CLI missing: expected nonzero"
printf '%s' "$out" | grep -q 'colima' || fail "linux colima-missing hint dropped backend name"
printf '%s' "$out_mac" | grep -q 'brew' || fail "macos colima-missing hint lacks brew
$out_mac"
printf '%s' "$out" | grep -qi 'distro\|package\|kvm' \
  || { printf '%s' "$out" | grep -qi 'brew' && fail "linux colima-missing hint says brew (macos-only)
$out"; }
pass "colima-CLI-missing hint is OS-specific (brew vs distro)"

# podman unreachable: macOS -> podman machine start; Linux -> rootless/systemctl.
export DC_STUB_PODMAN_UP=0
PATH="$WORK/bin_macos:$PATH" run_doctor podman; out_mac="$RUN_OUT"
printf '%s' "$out_mac" | grep -q 'podman machine start' \
  || fail "macos: podman-unreachable hint lacks 'podman machine start'
$out_mac"
PATH="$WORK/bin_linux:$PATH" run_doctor podman; out="$RUN_OUT"
printf '%s' "$out" | grep -Eq 'rootless|systemctl' \
  || fail "linux: podman-unreachable hint lacks rootless/systemctl
$out"
export DC_STUB_PODMAN_UP=1
pass "podman-unreachable hint is OS-specific (machine vs rootless)"

# ---------------------------------------------------------------------------
# Section 7 - apple backend: host.docker.internal parity + live gateway probe
# ---------------------------------------------------------------------------
# apple/container gets host-loopback reachability only after (a) a CLI
# >= 0.9.0 and (b) the one-time host bootstrap domain (`system dns create` +
# pf redirect). Doctor gates (a)/(b) hard and probes the live redirect from
# inside a running apple project container: fast-refuse = redirect alive,
# timeout = redirect missing (e.g. after a host reboot).

# Healthy apple: supported version + domain present -> pass, no bootstrap cmd.
run_doctor apple; out="$RUN_OUT"
[[ "$RUN_RC" -eq 0 ]] || fail "apple healthy: expected exit 0, got $RUN_RC
$out"
printf '%s' "$out" | grep -Fq '0.9.0' \
  || fail "apple healthy: version-gate line (>= 0.9.0) missing
$out"
printf '%s' "$out" | grep -Fq 'host.docker.internal' \
  || fail "apple healthy: domain check line missing
$out"
if printf '%s' "$out" | grep -Fq 'dns create'; then
  fail "apple healthy: must not print the bootstrap command
$out"
fi
pass "apple healthy: version + domain ok, no bootstrap command"

# Domain absent -> deliberate hard failure with the exact bootstrap remedy
# plus the caveats (sudo, host-global, Private Relay, lost on reboot).
DC_STUB_APPLE_DNS_DOMAIN=0 run_doctor apple; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "apple domain absent: expected nonzero
$out"
printf '%s' "$out" | grep -Fq 'sudo container system dns create host.container.internal --localhost 203.0.113.113' \
  || fail "apple domain absent: exact bootstrap command missing
$out"
printf '%s' "$out" | grep -Fqi 'Private Relay' \
  || fail "apple domain absent: Private Relay caveat missing
$out"
printf '%s' "$out" | grep -Eiq 'reboot|restart' \
  || fail "apple domain absent: reboot caveat missing
$out"
pass "apple domain absent: hard fail + exact remedy + caveats"

# Stopped apple runtime (`container system status` fails): reachability is
# probed FIRST, so the version/domain host-integration checks must be gated
# behind it -- with the DNS domain also absent, the only failure is the
# unreachable runtime, never the domain-absent misconfiguration.
DC_STUB_APPLE_UP=0 DC_STUB_APPLE_DNS_DOMAIN=0 run_doctor apple; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "apple runtime down: expected nonzero
$out"
printf '%s' "$out" | grep -q 'Runtime reachable' \
  || fail "apple runtime down: missing Runtime reachable failure
$out"
printf '%s' "$out" | grep -Eq 'container system start' \
  || fail "apple runtime down: missing 'container system start' hint
$out"
if printf '%s' "$out" | grep -Fq 'host.docker.internal'; then
  fail "apple runtime down: host-integration checks must not run when unreachable
$out"
fi
pass "apple runtime down: unreachable reported, host-integration checks gated"

# Version < 0.9.0 -> hard failure with an upgrade hint.
DC_STUB_APPLE_VERSION=0.8.2 run_doctor apple; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "apple old version: expected nonzero
$out"
printf '%s' "$out" | grep -Eiq 'upgrade' \
  || fail "apple old version: upgrade hint missing
$out"
pass "apple version < 0.9.0: hard fail + upgrade hint"

# Version inside the pf-reload bug window (0.9.0 <= v < 1.5.0) with the domain
# present: the < 1.5.0 note is INFORMATIONAL ONLY -> overall PASS, info shown.
DC_STUB_APPLE_VERSION=1.4.1 run_doctor apple; out="$RUN_OUT"
[[ "$RUN_RC" -eq 0 ]] || fail "apple 1.4.1: < 1.5.0 must not fail (got $RUN_RC)
$out"
printf '%s' "$out" | grep -Fq '1.5.0' \
  || fail "apple 1.4.1: expected the < 1.5.0 informational line
$out"
pass "apple version < 1.5.0: info line only, still passes"

# Project scope, running container, probe fast-refused -> path alive (pass).
make_project applelive apple dce-base:latest "ghp_realtoken"
DC_STUB_APPLE_CONTAINERS="applelive" DC_STUB_APPLE_PROBE=refused \
  run_doctor applelive; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq 'host.docker.internal path to host loopback reachable' \
  || fail "apple probe refused: reachable line missing
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "apple probe refused: expected exit 0, got $RUN_RC
$out"
pass "apple project, running + fast-refused probe: reachable ok"

# Probe connect succeeds (gateway answered) -> the "(connected)" classification.
DC_STUB_APPLE_CONTAINERS="applelive" DC_STUB_APPLE_PROBE=ok \
  run_doctor applelive; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq 'host.docker.internal path to host loopback reachable (connected)' \
  || fail "apple probe ok: expected (connected) line
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "apple probe ok: expected exit 0, got $RUN_RC
$out"
pass "apple project, probe connect ok: (connected) classification"

# Probe times out (pf redirect missing) -> failure + re-run bootstrap/reboot hint.
DC_STUB_APPLE_CONTAINERS="applelive" DC_STUB_APPLE_PROBE=timeout \
  run_doctor applelive; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "apple probe timeout: expected nonzero
$out"
printf '%s' "$out" | grep -Fq 'sudo container system dns create host.container.internal --localhost 203.0.113.113' \
  || fail "apple probe timeout: bootstrap hint missing
$out"
printf '%s' "$out" | grep -Eiq 'reboot' \
  || fail "apple probe timeout: reboot hint missing
$out"
pass "apple project, probe timeout: fail + re-run bootstrap hint"

# Probe tools unavailable in the container -> skipped with a reason.
DC_STUB_APPLE_CONTAINERS="applelive" DC_STUB_APPLE_PROBE=noutil \
  run_doctor applelive; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq 'host.docker.internal path to host loopback reachable (skipped:' \
  || fail "apple probe noutil: expected skipped-with-reason line
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "apple probe noutil: skip must not fail (got $RUN_RC)
$out"
pass "apple project, probe tools missing: skipped with reason"

# Container stopped -> probe skipped (a stopped project is normal, not a fail).
DC_STUB_APPLE_CONTAINERS="" DC_STUB_APPLE_STOPPED="applelive" \
  run_doctor applelive; out="$RUN_OUT"
printf '%s' "$out" | grep -Fq 'host.docker.internal path to host loopback reachable (skipped: container not running)' \
  || fail "apple stopped: expected probe skip with reason
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "apple stopped: skip must not fail (got $RUN_RC)
$out"
pass "apple project, stopped container: probe skipped"

echo ""
echo "All doctor checks passed."
