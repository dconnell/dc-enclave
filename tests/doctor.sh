#!/usr/bin/env bash
# =============================================================================
# tests/doctor.sh - `dc doctor` preflight diagnostics coverage.
#
# doctor runs read-only probes across the host environment and each detected
# backend CLI (and optionally a single backend or project). This test installs
# stub docker/container/podman/colima binaries on a private PATH and a fake
# HOME, then asserts exit codes (nonzero on any failure) and output markers
# across host / all-backends / single-backend / project scopes.
#
# The stub is env-driven so each scenario flips one knob (runtime up/down,
# context drift, missing dev-base) and re-runs `dc doctor`.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DC_BIN="$ROOT_DIR/scripts/dc"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ---------------------------------------------------------------------------
# Stub backend CLIs (one script installed under docker/container/podman/colima).
# Env knobs (all default to the "healthy" state):
#   DC_STUB_DOCKER_UP / DC_STUB_APPLE_UP / DC_STUB_PODMAN_UP / DC_STUB_COLIMA_UP
#   DC_STUB_COLIMA_RUNTIME (docker|containerd)
#   DC_STUB_DOCKER_CONTEXTS        (newline list for `docker context ls`)
#   DC_STUB_DOCKER_CONTEXT_ACTIVE  (what `docker context show` returns when
#                                   DOCKER_CONTEXT is unset)
#   DC_STUB_HAS_DEVBASE            (image ls emits dev-base:latest)
#   DC_STUB_CONTAINERS             (newline list for `docker ps`)
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
      context)
        if [[ "${2:-}" == "show" ]]; then show_ctx; exit 0
        elif [[ "${2:-}" == "ls" ]]; then printf '%s\n' "${DC_STUB_DOCKER_CONTEXTS:-default}"; exit 0
        fi
        exit 0 ;;
      image)
        if [[ "${2:-}" == "ls" ]]; then
          [[ "${DC_STUB_HAS_DEVBASE:-1}" == "1" ]] && printf 'dev-base:latest\n'
          printf 'dev-img-aaaaaaaaaaaaaaaa:latest\n'
          exit 0
        fi
        exit 0 ;;
      ps) printf '%s\n' "${DC_STUB_CONTAINERS:-}"; exit 0 ;;
    esac
    exit 0 ;;
  container)
    case "${1:-}" in
      system) [[ "${2:-}" == "info" ]] && { [[ "${DC_STUB_APPLE_UP:-1}" == "1" ]] && exit 0; exit 1; } ;;
      --version) echo "container stub 1.0"; exit 0 ;;
      image)
        if [[ "${2:-}" == "ls" ]]; then
          [[ "${DC_STUB_HAS_DEVBASE:-1}" == "1" ]] && printf 'dev-base:latest\n'
          exit 0
        fi
        exit 0 ;;
      ps) exit 0 ;;
    esac
    exit 0 ;;
  podman)
    case "${1:-}" in
      info)    [[ "${DC_STUB_PODMAN_UP:-1}" == "1" ]] && exit 0; exit 1 ;;
      --version) echo "podman 99.0 (stub)"; exit 0 ;;
      image)
        if [[ "${2:-}" == "ls" ]]; then
          [[ "${DC_STUB_HAS_DEVBASE:-1}" == "1" ]] && printf 'dev-base:latest\n'
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
DC_ROOT="$HOME/.config/dev-containers"
OV="$DC_ROOT/overlays"
mkdir -p "$OV/team" "$OV/user"
printf 'DC_OVERLAYS_DIR="%s/overlays"\n' "$DC_ROOT" > "$DC_ROOT/config"

# Put the stub CLIs on PATH for the whole test shell. $ORIG_PATH is retained so
# individual scenarios can run with a stripped PATH (e.g. podman absent).
ORIG_PATH="$PATH"
export PATH="$STUB_DIR:$ORIG_PATH"

# Default to a healthy Colima state (colima context listed + active, docker up)
# so the colima stub always present on PATH does not read as "drifted" by default.
# Drift scenarios below override these inline.
export DC_STUB_DOCKER_CONTEXTS="default colima"
export DC_STUB_DOCKER_CONTEXT_ACTIVE=colima

# Run `dc doctor` with the current PATH/HOME and a clean backend override.
# Called DIRECTLY (not via $()) so the exit code reaches the caller's shell:
# the captured text lands in $RUN_OUT and the exit code in $RUN_RC. (Calling it
# inside $() would run it in a subshell and lose $RUN_RC.)
RUN_RC=0
RUN_OUT=""
run_doctor() {
  local out
  set +e
  out="$(HOME="$HOME" env -u CONTAINER_BACKEND "$DC_BIN" doctor "$@" 2>&1)"
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
printf 'DC_OVERLAYS_DIR="%s/overlays"\n' "$DC_ROOT" > "$DC_ROOT/config"

# Overlays root missing -> host failure, nonzero.
rm -rf "$OV"
run_doctor; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "missing overlays dir: expected nonzero, got 0
$out"
[[ "$out" == *"overlay root"* ]] || fail "missing overlays: no overlay-root check line
$out"
pass "missing overlays root: nonzero"
mkdir -p "$OV/team" "$OV/user"

# Malformed DC_OVERLAYS_DIR (unquoted -> rejected by hardened parser).
printf 'DC_OVERLAYS_DIR=%s/overlays\n' "$DC_ROOT" > "$DC_ROOT/config"
run_doctor; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "unquoted DC_OVERLAYS_DIR: expected nonzero"
pass "malformed (unquoted) DC_OVERLAYS_DIR rejected"
printf 'DC_OVERLAYS_DIR="%s/overlays"\n' "$DC_ROOT" > "$DC_ROOT/config"

# ---------------------------------------------------------------------------
# Section 2 - all-backends detection + per-backend probes
# ---------------------------------------------------------------------------
# docker + podman + container stubs present -> three backend sections.
run_doctor; out="$RUN_OUT"
for b in docker podman apple; do
  [[ "$out" == *"Backend: $b"* ]] || fail "all-mode missing Backend: $b section
$out"
done
[[ "$out" == *"dev-base:latest"* ]] || fail "per-backend dev-base check missing
$out"
pass "all-mode: detected docker/podman/apple + dev-base checks"

# Runtime down on docker -> docker section fails, overall nonzero.
DC_STUB_DOCKER_UP=0 run_doctor; out="$RUN_OUT"
{ printf '%s' "$out" | grep -q "Runtime reachable" && printf '%s' "$out" | grep -Eq 'systemctl|service docker|Docker Desktop'; } \
  || fail "docker down: missing runtime-reachable failure detail
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "docker down: expected nonzero overall"
pass "docker runtime down: reported + nonzero"

# dev-base missing on docker -> failure.
DC_STUB_HAS_DEVBASE=0 run_doctor; out="$RUN_OUT"
{ printf '%s' "$out" | grep -q "dev-base:latest missing"; } \
  || fail "missing dev-base: no failure detail
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "missing dev-base: expected nonzero"
pass "missing dev-base: reported + nonzero"
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
# `dc doctor docker` checks only docker (no podman/apple sections).
run_doctor docker; out="$RUN_OUT"
[[ "$out" == *"Backend: docker"* ]] || fail "scoped docker: section missing
$out"
[[ "$out" != *"Backend: podman"* ]] || fail "scoped docker: should not list podman
$out"
[[ "$out" != *"Backend: apple"* ]] || fail "scoped docker: should not list apple
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "scoped healthy docker: expected 0, got $RUN_RC"
pass "single-backend scope: only that backend"

# `dc doctor <unknown>` exits nonzero with guidance.
run_doctor nosuchbackend; out="$RUN_OUT"
[[ "$RUN_RC" -ne 0 ]] || fail "unknown scope: expected nonzero"
[[ "$out" == *"Unknown backend or project"* ]] || fail "unknown scope: no guidance
$out"
pass "unknown scope: nonzero + guidance"

# `dc doctor <backend with CLI missing>`: docker absent from PATH -> fail.
set +e
out="$(PATH="$STUB_NODOCKER:$ORIG_PATH" HOME="$HOME" env -u CONTAINER_BACKEND \
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
  local name="$1" backend="$2" image="${3:-dev-base:latest}" token="${4:-}"
  local pdir="$DC_ROOT/$name"
  mkdir -p "$pdir"
  chmod 700 "$pdir"
  local cfg="$pdir/config"
  cat > "$cfg" <<EOF
CONTAINER_PROJECT="$name"
CONTAINER_OVERLAY_SCOPES=""
CONTAINER_IMAGE="$image"
CONTAINER_BACKEND="$backend"
CONTAINER_CPUS=""
CONTAINER_MEMORY=""
REPOS_DIR="$WORK/repos/$name"
SECRET_DIR="$pdir"
SSH_KEY_PATH="$pdir/ssh_key"
TOKEN_FILE="$pdir/github-token"
NPMRC_PATH="$pdir/.npmrc"
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
make_project alpha docker dev-base:latest "ghp_realtoken"
DC_STUB_CONTAINERS="alpha" run_doctor alpha; out="$RUN_OUT"
[[ "$out" == *"Project: alpha"* ]] || fail "project scope: no Project header
$out"
[[ "$out" == *"Config loads"* ]] || fail "project scope: no config-loads check
$out"
[[ "$RUN_RC" -eq 0 ]] || fail "healthy project: expected 0, got $RUN_RC
$out"
pass "project scope: healthy project -> exit 0"

# Project with placeholder token -> secrets failure, nonzero.
make_project beta docker dev-base:latest ""
DC_STUB_CONTAINERS="beta" run_doctor beta; out="$RUN_OUT"
{ printf '%s' "$out" | grep -Eq "GitHub token"; } \
  || fail "placeholder token: no token check
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "placeholder token project: expected nonzero"
pass "project with placeholder token: reported + nonzero"

# Project referencing a missing image -> failure.
make_project gamma docker dev-img-deadbeefdeadbeef:latest "ghp_realtoken"
run_doctor gamma; out="$RUN_OUT"
{ printf '%s' "$out" | grep -Eq "image|Image"; } \
  || fail "missing image: no image check line
$out"
[[ "$RUN_RC" -ne 0 ]] || fail "missing image project: expected nonzero"
pass "project with missing image: reported + nonzero"

# Project whose recorded backend CLI is missing -> failure.
make_project delta podman dev-base:latest "ghp_realtoken"
set +e
out="$(PATH="$STUB_NOP:$ORIG_PATH" HOME="$HOME" env -u CONTAINER_BACKEND \
        "$DC_BIN" doctor delta 2>&1)"
RUN_RC=$?
set -e
[[ "$RUN_RC" -ne 0 ]] || fail "project backend CLI missing: expected nonzero"
pass "project backend unavailable: reported + nonzero"

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
set +e
out="$(PATH="$WORK/bin_linux:$STUB_NOCOLIMA:$ORIG_PATH" HOME="$HOME" \
        env -u CONTAINER_BACKEND "$DC_BIN" doctor colima 2>&1)"
RUN_RC=$?
out_mac="$(PATH="$WORK/bin_macos:$STUB_NOCOLIMA:$ORIG_PATH" HOME="$HOME" \
        env -u CONTAINER_BACKEND "$DC_BIN" doctor colima 2>&1)"
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

echo ""
echo "All doctor checks passed."
