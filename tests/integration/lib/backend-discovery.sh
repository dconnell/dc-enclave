#!/usr/bin/env bash
# =============================================================================
# tests/integration/lib/backend-discovery.sh - Which backends does THIS run
# exercise, and are they actually usable?
#
# Selection + reachability policy for the integration suite, layered on the
# shared lib/container-backend.sh detection so doctor and the harness agree on
# "available". The harness calls these to (a) decide the backend list, (b) fail
# fast inside a containerized worker that cannot start nested runtimes, and
# (c) preflight each backend (doctor + dce-base:latest present).
#
# Selection rules (from the plan):
#   - default: run every detected available backend.
#   - INTEGRATION_BACKENDS="docker,podman" narrows to that subset (intersected
#     with what is actually detected; an override naming an undetected backend
#     is an error so a typo does not silently widen coverage).
#   - reachability is strict by default: detected-but-unreachable = a FAILED
#     run, not a silent skip. INTEGRATION_SKIP_UNREACHABLE=1 downgrades to skip.
#
# Requires $_IT_DCE (path to scripts/dce) to be set by the harness before the
# preflight/reachability helpers are called.
# =============================================================================
if [[ -n "${_IT_BACKEND_DISCOVERY_SH_LOADED:-}" ]]; then return 0; fi
declare -gr _IT_BACKEND_DISCOVERY_SH_LOADED=1

_IT_BD_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_IT_BD_ROOT="$(cd "$_IT_BD_DIR/../../.." && pwd)"
# shellcheck disable=SC1091  # repo lib include, path resolved above
source "$_IT_BD_ROOT/lib/common.sh" 2>/dev/null || true
# shellcheck disable=SC1091  # repo lib include, path resolved above
source "$_IT_BD_ROOT/lib/container-backend.sh"
unset _IT_BD_DIR _IT_BD_ROOT

# Fail fast: the suite creates containers and needs the HOST runtime, so running
# it from inside a containerized CI worker (no nested runtime) is unsupported.
it_assert_not_in_container() {
  if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
    echo "ERROR: integration suite cannot run inside a container" >&2
    echo "  (detected /.dockerenv or /run/.containerenv); it needs host runtime access." >&2
    return 1
  fi
}

# Print every detected available backend (one per line), via the shared API.
it_detected_backends() {
  backend_detect_available
}

# Print the SELECTED backend list for this run: detected ∩ INTEGRATION_BACKENDS,
# or all detected when the override is unset. Aborts on an override naming a
# backend that is not detected (typo guard) unless INTEGRATION_SKIP_UNREACHABLE
# is set, in which case it is dropped with a warning so local dev stays fluid.
it_select_backends() {  # prints newline-list to stdout; returns nonzero on bad override
  local detected selected="" b want rest dropped=""
  detected="$(it_detected_backends)"

  if [[ -z "${INTEGRATION_BACKENDS:-}" ]]; then
    printf '%s\n' "$detected"
    return 0
  fi

  # Build a lookup of detected backends so each override entry is O(1) to check.
  local -A det_set=()
  while IFS= read -r b; do
    [[ -n "$b" ]] && det_set["$b"]=1
  done <<< "$detected"

  # Comma-split the override by hand (portable, no IFS/subshell scoping traps).
  rest="${INTEGRATION_BACKENDS:-}"
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == *,* ]]; then
      want="${rest%%,*}"
      rest="${rest#*,}"
    else
      want="$rest"
      rest=""
    fi
    # Trim surrounding whitespace.
    want="${want#"${want%%[![:space:]]*}"}"
    want="${want%"${want##*[![:space:]]}"}"
    [[ -n "$want" ]] || continue
    if [[ -n "${det_set[$want]:-}" ]]; then
      selected+="$want"$'\n'
    else
      dropped+="$want "
    fi
  done

  if [[ -n "$dropped" ]]; then
    if [[ "${INTEGRATION_SKIP_UNREACHABLE:-0}" == "1" ]]; then
      printf 'WARN: override backend(s) not detected, skipping: %s\n' "$dropped" >&2
    else
      echo "ERROR: INTEGRATION_BACKENDS names undetected backend(s): $dropped" >&2
      echo "  Detected: $(it_detected_backends | tr '\n' ' ')" >&2
      echo "  Set INTEGRATION_SKIP_UNREACHABLE=1 to drop them instead of failing." >&2
      return 1
    fi
  fi

  printf '%s' "$selected"
}

# Reachability = the runtime engine answers AND backend-specific gates hold --
# mirroring `dce doctor`'s PRE-base-image checks only. doctor's overall exit
# code is NOT used here because doctor also fails when dce-base:latest is
# missing, which would make a reachable-but-fresh backend look unreachable and
# skip the very rebuild preflight is supposed to do. base-image presence is
# handled separately by _it_base_image_present + the rebuild step below.
it_backend_reachable() {  # <backend>
  (
    backend_use "$1" >/dev/null 2>&1 || exit 1
    # Colima needs the docker runtime (not containerd) -- doctor's strict colima
    # gate: the runtime must be explicitly "docker", not merely non-empty. Other
    # backends have no extra gate beyond "engine answers".
    if [[ "$1" == "colima" ]]; then
      rt="$(_backend_colima_runtime 2>/dev/null || true)"
      [[ "$rt" == "docker" ]] || exit 1
    fi
    backend_system_info >/dev/null 2>&1
  )
}

# True (return 0) if dce-base:latest exists in <backend>'s image store. Uses the
# lib directly (subshell-isolated) so context pinning never leaks across calls.
_it_base_image_present() {  # <backend>
  (
    # shellcheck disable=SC1091
    source "$_IT_LIB_DIR/common.sh"
    # shellcheck disable=SC1091
    source "$_IT_LIB_DIR/container-backend.sh"
    backend_use "$1" >/dev/null 2>&1 && backend_image_exists "dce-base:latest"
  )
}

# Per-backend preflight (run once before any case touches a backend):
#   1. doctor confirms the runtime answers.
#   2. dce-base:latest must exist; if missing, rebuild it (base only) so the
#      first `dce new` does not fail on a fresh install.
# Prints human-readable status lines; returns nonzero only if the backend is
# unusable (caller decides skip vs fail via the reachability policy).
it_preflight_backend() {  # <backend>
  local backend="$1"
  if ! it_backend_reachable "$backend"; then
    printf '  preflight: %s UNREACHABLE (runtime not answering or backend gate failed)\n' "$backend"
    return 1
  fi
  printf '  preflight: %s reachable\n' "$backend"

  if ! _it_base_image_present "$backend"; then
    printf '  preflight: %s building dce-base:latest ...\n' "$backend"
    # Capture the build log (NOT >/dev/null) so a failure is diagnosable: strict
    # mode otherwise marks the backend FAILED with zero clue why the image build
    # broke. Echo the tail to stderr (visible in the CI step output) + keep the
    # full log under the run's artifacts.
    local _build_log
    _build_log="$(it_log_path "$backend" preflight-build)"
    if ! CONTAINER_BACKEND="$backend" "$_IT_DCE" rebuild-image base >"$_build_log" 2>&1; then
      printf '  preflight: %s rebuild-image base FAILED (full log: %s)\n' "$backend" "$_build_log" >&2
      printf '  ----- tail of preflight build log -----\n' >&2
      tail -n 40 "$_build_log" >&2 2>/dev/null || true
      printf '  ---------------------------------------\n' >&2
      return 1
    fi
  fi
  printf '  preflight: %s ready (dce-base:latest present)\n' "$backend"
  return 0
}
