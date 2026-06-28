#!/usr/bin/env bash
# =============================================================================
# scripts/doctor.sh - `dce doctor`: preflight diagnostics for DC Enclave.
#
# Runs read-only probes and prints pass/fail per subsystem, so the user gets a
# single diagnosis instead of assembling one from `dce status` + tribal knowledge.
# Catches the common drift classes: wrong bash, missing/broken global config,
# stale dce-base, Colima context drift / non-docker runtime, Podman machine
# stopped, missing backend CLI. Never starts or mutates anything.
#
# Scope:
#   dce doctor              every detected backend CLI (+ host checks once)
#   dce doctor <backend>    one backend (apple|docker|orbstack|colima|podman)
#   dce doctor <project>    that project's backend + project-specific checks
#
# Exit code is nonzero if any check fails, so doctor is CI/preflight-friendly.
# =============================================================================
# NOTE: deliberately `set -uo pipefail` WITHOUT `-e`. A doctor must collect every
# failure and report, not abort on the first one. Each probe isolates state in a
# subshell so probing multiple backends never leaks DOCKER_CONTEXT/selection.
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/platform.sh"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# --- output helpers (no ANSI color: matches the rest of the dce toolset) -------
_ok() {  # <label>
  printf '  \xe2\x9c\x93 %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

_bad() {  # <label> [detail...]
  printf '  \xe2\x9c\x97 %s\n' "$1"
  shift
  if [[ -n "${1:-}" ]]; then
    printf '      %s\n' "$1"
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

_skip() {  # <label> <reason>
  printf '  - %s (skipped: %s)\n' "$1" "${2:-prerequisite not met}"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

# Neutral informational line (does not affect pass/fail counts).
_info() {  # <label>: <value>
  printf '  \xc2\xb7 %s\n' "$1"
}

# --- OS-aware remediation hints ------------------------------------------------
# The same broken state has a different fix per platform (e.g. Docker Desktop on
# macOS vs systemctl on Linux, brew on macOS vs a distro package on Linux). Each
# hint is derived from platform_os() so a Linux/WSL2 user never gets dead-end
# macOS-only advice. apple/container and OrbStack are macOS-only products, so
# their hints need no per-OS branching.

# shellcheck disable=SC2329
# Invoked indirectly by name via the _check dispatcher; reached through _chk_bash.
_hint_bash_install() {
  case "$(platform_os)" in
    macos) printf 'macOS ships Bash 3.2; install 4+: brew install bash' ;;
    *)     printf 'install Bash 4+ via your package manager' ;;
  esac
}

_hint_docker_install() {
  case "$(platform_os)" in
    macos) printf 'install Docker Desktop (or: brew install docker)' ;;
    linux) printf 'sudo apt install docker.io (or: sudo dnf install docker)' ;;
    wsl2)  printf 'enable Docker Desktop WSL2 integration (or: sudo apt install docker.io)' ;;
    *)     printf 'install the docker CLI' ;;
  esac
}

_hint_docker_unreachable() {
  case "$(platform_os)" in
    macos) printf 'start Docker Desktop' ;;
    linux) printf 'sudo systemctl start docker (or: sudo service docker start)' ;;
    wsl2)  printf 'start Docker Desktop WSL2 integration (or: sudo service docker start)' ;;
    *)     printf 'start the Docker daemon' ;;
  esac
}

_hint_colima_install() {
  case "$(platform_os)" in
    macos) printf 'brew install colima docker' ;;
    linux) printf 'install colima + docker CLI (distro packages); ensure KVM/virtualization' ;;
    *)     printf 'install colima and the docker CLI' ;;
  esac
}

_hint_podman_install() {
  case "$(platform_os)" in
    macos) printf 'brew install podman' ;;
    *)     printf 'sudo apt install podman (or: sudo dnf install podman)' ;;
  esac
}

_hint_podman_unreachable() {
  case "$(platform_os)" in
    macos) printf 'run: podman machine start' ;;
    linux) printf 'rootless podman not ready; ensure installed (systemctl --user start podman.socket)' ;;
    wsl2)  printf 'ensure podman is installed; systemctl --user start podman.socket' ;;
    *)     printf 'start the Podman runtime' ;;
  esac
}

# Run a check function (which returns 0/1 and may echo a reason to stderr on
# failure) and report it under the given label. stderr is captured as the detail.
_check() {  # <label> <check-fn> [args...]
  local label="$1"; shift
  local detail rc
  detail="$("$@" 2>&1 >/dev/null)" && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    _ok "$label"
  else
    _bad "$label" "${detail:-failed}"
  fi
}

# --- host probes --------------------------------------------------------------

# shellcheck disable=SC2329
# Invoked indirectly by name via the _check dispatcher (see _check calls below).
_chk_bash() {
  if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then return 0; fi
  printf 'Bash %s detected (need 4+); %s\n' "${BASH_VERSION:-unknown}" "$(_hint_bash_install)" >&2
  return 1
}

# shellcheck disable=SC2329
# Invoked indirectly by name via the _check dispatcher.
_chk_global_config() {
  local cfg
  cfg="$(dce_global_config_path)" || return 1
  if [[ -L "$cfg" ]]; then
    echo "global config is a symlink: $cfg" >&2
    return 1
  fi
  if [[ ! -f "$cfg" ]]; then
    echo "not found: $cfg (run: scripts/setup.sh)" >&2
    return 1
  fi
}

# shellcheck disable=SC2329
# Invoked indirectly by name via the _check dispatcher (once per config var).
_chk_root() {  # <varname>
  local varname="$1" cfg val
  cfg="$(dce_global_config_path)" || return 1
  val="$(dce_config_extract_scalar "$cfg" "$varname" 2>/dev/null)" || {
    echo "$varname missing or not a clean quoted value in $cfg" >&2
    return 1
  }
  [[ -n "$val" ]] || { echo "$varname is empty in $cfg" >&2; return 1; }
  # shellcheck disable=SC2088
  # ~ is a literal char matched against user input, not an expansion.
  case "$val" in
    "~")   val="$HOME" ;;
    "~/"*) val="$HOME${val#\~}" ;;
    /*)    : ;;
    *)     val="$HOME/.config/dce-enclave/$val" ;;
  esac
  [[ -d "$val" ]] || { echo "$varname root does not exist: $val" >&2; return 1; }
}

doctor_host() {
  echo ""
  echo "Environment"
  _check "Bash 4+ (current: ${BASH_VERSION%%,*})" _chk_bash
  _check "Global config ($(dce_global_config_path))" _chk_global_config
  _check "DC_TEAM_DIR resolvable + root exists" _chk_root DC_TEAM_DIR
  _check "DC_USER_DIR resolvable + root exists" _chk_root DC_USER_DIR
}

# --- backend probes (all read-only; reachability reuses backend_system_info,
#     which only inspects state, never starts a daemon/machine) ----------------

# True if the backend's CLI(s) are on PATH (and, for orbstack, an OrbStack
# Docker context exists). No mutation, no commit to a backend selection.
_probe_cli() {  # <backend>
  case "$1" in
    apple)   command -v container >/dev/null 2>&1 ;;
    docker)  command -v docker   >/dev/null 2>&1 ;;
    orbstack)
      command -v docker >/dev/null 2>&1 \
        && docker context ls --format '{{.Name}}' 2>/dev/null | grep -iq orbstack
      ;;
    colima)  command -v colima >/dev/null 2>&1 && command -v docker >/dev/null 2>&1 ;;
    podman)  command -v podman >/dev/null 2>&1 ;;
    *)       return 1 ;;
  esac
}

# True if the backend engine/VM answers (read-only: backend_use + backend_system_info
# only inspect; backend_system_info never starts anything). Subshell-isolated so
# DOCKER_CONTEXT pinning for colima/orbstack cannot leak into other probes.
_probe_reachable() {  # <backend>
  ( backend_use "$1" >/dev/null 2>&1 && backend_system_info >/dev/null 2>&1 )
}

_probe_devbase() {  # <backend>
  ( backend_use "$1" >/dev/null 2>&1 && backend_image_exists "dce-base:latest" )
}

# Colima-specific gates (read-only): is the active Docker context Colima, and is
# Colima running with the docker runtime (not containerd)?
_probe_colima_context() { _backend_colima_context_active 2>/dev/null; }
_probe_colima_runtime() {
  local rt
  rt="$(_backend_colima_runtime 2>/dev/null)" || return 1
  [[ "$rt" == "docker" ]]
}

# Print the active docker context name for the backend section header (best-effort;
# blank when undeterminable so the label stays clean).
_docker_context_label() {
  local ctx
  ctx="$(docker context show 2>/dev/null)" || ctx=""
  [[ -n "$ctx" ]] && printf ' (context: %s)' "$ctx"
}

doctor_backend() {  # <backend>
  local b="$1"
  echo ""
  if [[ "$b" == "docker" ]]; then
    printf 'Backend: %s%s\n' "$b" "$(_docker_context_label)"
  else
    printf 'Backend: %s\n' "$b"
  fi

  if ! _probe_cli "$b"; then
    case "$b" in
      apple)   _bad "CLI installed" "container CLI not found on PATH (apple/container is macOS-only)" ;;
      docker)  _bad "CLI installed" "docker CLI not found on PATH ($(_hint_docker_install))" ;;
      orbstack) _bad "CLI installed" "docker CLI or OrbStack Docker context not found (install OrbStack on macOS)" ;;
      colima)  _bad "CLI installed" "colima/docker CLI not found ($(_hint_colima_install))" ;;
      podman)  _bad "CLI installed" "podman CLI not found on PATH ($(_hint_podman_install))" ;;
    esac
    local dep="CLI missing"
    if [[ "$b" == "colima" ]]; then
      _skip "Colima docker context active" "$dep"
      _skip "Colima runtime is docker" "$dep"
    fi
    _skip "Runtime reachable" "$dep"
    _skip "Base image present (dce-base:latest)" "$dep"
    return
  fi
  _ok "CLI installed"

  # Colima has three independent drift vectors; surface each so the user sees the
  # exact root cause instead of a generic "unreachable". Short-circuit the
  # downstream checks once an upstream gate fails so the report pinpoints it.
  if [[ "$b" == "colima" ]]; then
    if _probe_colima_context; then
      _ok "Colima docker context active"
    else
      _bad "Colima docker context active" \
        "active Docker context is not Colima (run: colima start && docker context use colima)"
      _skip "Colima runtime is docker" "context not active"
      _skip "Runtime reachable" "context not active"
      _skip "Base image present (dce-base:latest)" "context not active"
      return
    fi
    if _probe_colima_runtime; then
      _ok "Colima runtime is docker"
    else
      _bad "Colima runtime is docker" \
        "Colima is using a non-docker runtime (recreate: colima stop && colima start --runtime docker)"
      _skip "Runtime reachable" "runtime not docker"
      _skip "Base image present (dce-base:latest)" "runtime not docker"
      return
    fi
  fi

  if _probe_reachable "$b"; then
    _ok "Runtime reachable"
  else
    local hint=""
    case "$b" in
      docker)   hint="$(_hint_docker_unreachable)" ;;
      orbstack) hint="start OrbStack" ;;
      colima)   hint="Colima VM not reachable (run: colima start)" ;;
      apple)    hint="run: container system start" ;;
      podman)   hint="$(_hint_podman_unreachable)" ;;
    esac
    _bad "Runtime reachable" "$hint"
    _skip "Base image present (dce-base:latest)" "runtime unreachable"
    return
  fi

  if _probe_devbase "$b"; then
    _ok "Base image present (dce-base:latest)"
  else
    _bad "Base image present (dce-base:latest)" \
      "dce-base:latest missing from this backend's image store (run: CONTAINER_BACKEND=$b scripts/setup.sh)"
  fi
}

# Enumerate every backend whose CLI is detectable on PATH. Thin delegate to the
# shared lib/container-backend.sh source of truth (backend_detect_available) so
# doctor and the integration harness report the same set of available backends.
detect_backends() {
  backend_detect_available
}

# --- project probes -----------------------------------------------------------

# Resolve the project backend: the recorded CONTAINER_BACKEND, else auto-detect.
_resolve_project_backend() {
  local recorded="${CONTAINER_BACKEND:-}"
  if [[ -n "$recorded" ]]; then printf '%s\n' "$recorded"; return 0; fi
  _backend_detect_auto 2>/dev/null || true
}

# Read-only: does the project's image exist in its backend's store?
_probe_project_image() {  # <backend> <image>
  ( backend_use "$1" >/dev/null 2>&1 && backend_image_exists "$2" )
}

_chk_project_config() {  # <config-file>  (loads in a subshell so a dce_die only
                         # kills the subshell, not doctor)
  ( dce_load_project_config "$1" >/dev/null 2>&1 )
}

doctor_project() {  # <name>
  local name="$1"
  local cfg="$HOME/.config/dce-enclave/$name/config"
  echo ""
  printf 'Project: %s\n' "$name"

  if [[ ! -f "$cfg" ]]; then
    _bad "Config present" "no config at $cfg"
    return
  fi
  _ok "Config present"

  if ! _chk_project_config "$cfg"; then
    _bad "Config loads" "rejected by dce_load_project_config (unsafe/invalid); see dce status"
    return
  fi
  _ok "Config loads"

  # Safe to load in this shell now (it passed all safety checks in the subshell).
  dce_load_project_config "$cfg" >/dev/null 2>&1

  local pb
  pb="$(_resolve_project_backend)"
  if [[ -z "$pb" ]]; then
    _bad "Backend resolvable" "no CONTAINER_BACKEND in config and none auto-detected"
    return
  fi
  _ok "Backend resolvable ($pb)"

  if ! _probe_cli "$pb"; then
    _bad "Backend CLI installed ($pb)" "$pb CLI not found on PATH"
    _skip "Backend runtime reachable" "CLI missing"
    _skip "Project image present" "backend CLI missing"
  else
    _ok "Backend CLI installed ($pb)"
    if _probe_reachable "$pb"; then
      _ok "Backend runtime reachable"
    else
      _bad "Backend runtime reachable" "$pb runtime not reachable"
      _skip "Project image present" "runtime unreachable"
      _info "Secrets / container state not checked (backend unreachable)"
      return
    fi

    local img="${CONTAINER_IMAGE:-}"
    if [[ -z "$img" ]]; then
      _skip "Project image present" "no CONTAINER_IMAGE in config"
    elif _probe_project_image "$pb" "$img"; then
      _ok "Project image present ($img)"
    else
      _bad "Project image present ($img)" \
        "image missing from $pb store (run: CONTAINER_BACKEND=$pb scripts/setup.sh or dce rebuild-image all)"
    fi
  fi

  # Secrets presence (mirrors dce status logic). Missing token/key is actionable.
  local token_state="missing"
  if [[ -n "${TOKEN_FILE:-}" && -f "$TOKEN_FILE" ]]; then
    if grep -v '^#' "$TOKEN_FILE" 2>/dev/null | grep -v '^ghp_REPLACE_ME' | grep -q .; then
      token_state="set"
    else
      token_state="placeholder"
    fi
  fi
  if [[ "$token_state" == "set" ]]; then
    _ok "GitHub token set"
  else
    _bad "GitHub token set" \
      "token $token_state at ${TOKEN_FILE:-(unknown path)} (edit and replace ghp_REPLACE_ME)"
  fi

  if [[ -n "${SSH_KEY_PATH:-}" && -f "$SSH_KEY_PATH" ]]; then
    _ok "SSH deploy key present"
  else
    _bad "SSH deploy key present" "missing at ${SSH_KEY_PATH:-(unknown path)}"
  fi

  # Container state is informational, not a failure (a stopped project is normal).
  if ( backend_use "$pb" >/dev/null 2>&1 ); then
    if backend_is_running "$name" 2>/dev/null; then
      _info "Container state: running"
    elif backend_exists "$name" 2>/dev/null; then
      _info "Container state: stopped"
    else
      _info "Container state: not present (run: dce start $name)"
    fi
  fi
}

# --- argument parsing + dispatch ---------------------------------------------

DOCTOR_MODE="all"
DOCTOR_TARGET=""

if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help)
      cat <<'EOF'
Usage: dce doctor [backend|project]

Runs read-only preflight checks and prints pass/fail per subsystem.

Scope:
  (none)        Every detected backend CLI, plus host checks (bash, global
                config, overlays). Each installed backend gets its own section.
  <backend>     One of: apple, docker, orbstack, colima, podman.
  <project>     A configured project name: checks that project's backend plus
                project-specific state (config, image, secrets, container).

doctor never starts or mutates anything; it only inspects. Exit code is nonzero
if any check fails.

Examples:
  dce doctor              check all detected backends
  dce doctor colima       check only the Colima backend
  dce doctor myapp        check the myapp project and its backend
EOF
      exit 0
      ;;
    apple|docker|orbstack|colima|podman)
      DOCTOR_MODE="backend"; DOCTOR_TARGET="$1" ;;
    *)
      if [[ -f "$HOME/.config/dce-enclave/$1/config" ]]; then
        DOCTOR_MODE="project"; DOCTOR_TARGET="$1"
      else
        printf 'Unknown backend or project: %s\n' "$1" >&2
        printf 'Backends: apple, docker, orbstack, colima, podman\n' >&2
        printf '(or a configured project name)\n' >&2
        exit 2
      fi
      ;;
  esac
fi

printf '======================================================================\n'
printf 'DC Enclave doctor\n'
printf '======================================================================\n'

doctor_host

case "$DOCTOR_MODE" in
  all)
    detected="$(detect_backends)"
    if [[ -z "$detected" ]]; then
      echo ""
      _bad "Backend detected" \
        "no supported backend CLI found on PATH (install apple/container, Docker, OrbStack, Colima, or Podman)"
    else
      while IFS= read -r b; do
        [[ -n "$b" ]] && doctor_backend "$b"
      done <<< "$detected"
    fi
    ;;
  backend)
    doctor_backend "$DOCTOR_TARGET"
    ;;
  project)
    doctor_project "$DOCTOR_TARGET"
    ;;
esac

echo ""
printf -- '----------------------------------------------------------------------\n'
if [[ $FAIL_COUNT -eq 0 ]]; then
  printf 'All checks passed (%d ok, %d skipped).\n' "$PASS_COUNT" "$SKIP_COUNT"
  exit 0
fi
printf 'Result: %d passed, %d failed, %d skipped.\n' "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
printf 'Fix the failing checks above, then rerun: dce doctor\n'
exit 1
