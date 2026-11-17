#!/usr/bin/env bash
# =============================================================================
# lib/backends/registry.sh - Backend registry: selection, detection, CLI mapping.
#
# Sourced (never executed directly) via lib/container-backend.sh. Holds the
# ordered DCE_BACKENDS registry (order = detection priority) and the generic
# selection layer behind the facade dispatchers: alias normalization,
# CLI-presence probes, auto-detection, backend->CLI mapping, missing-CLI
# guidance, and the backend_use/backend_name/backend_cli entry points.
#
# Cross-file calls (dce_die, _backend_colima_cli_available,
# _backend_use_colima_context, _backend_use_orbstack_context) resolve at
# invocation time against the facade and its sibling modules; nothing is
# auto-sourced here.
# =============================================================================

# Include guard: sourcing this module directly is a safe no-op on re-source.
if [[ -n "${_DC_BACKENDS_REGISTRY_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKENDS_REGISTRY_SH_LOADED=1

# Canonical backend registry. ORDER = detection priority: it mirrors
# backend_detect_available / _backend_detect_auto below (context-aware backends
# pinned before the generic docker fallback), NOT alphabetical order. The
# alphabetical "Supported values" error text in backend_use derives from this
# array via LC_ALL=C sort.
declare -gar DCE_BACKENDS=(apple docker orbstack colima podman)

# Canonicalize a backend name from its common aliases; fails on unknown input.
_backend_normalize() {
  local raw="${1:-}"
  local value="${raw,,}"

  case "$value" in
    "")
      return 1
      ;;
    apple|container|apple-container)
      printf '%s\n' "apple"
      ;;
    docker|docker-desktop)
      printf '%s\n' "docker"
      ;;
    orbstack|orb)
      printf '%s\n' "orbstack"
      ;;
    colima)
      printf '%s\n' "colima"
      ;;
    podman|podman-desktop)
      printf '%s\n' "podman"
      ;;
    *)
      return 1
      ;;
  esac
}

# Return whether the selected backend's CLI binary is on PATH.
_backend_cli_available() {
  local backend="$1"

  case "$backend" in
    apple)
      command -v container >/dev/null 2>&1
      ;;
    docker|orbstack)
      command -v docker >/dev/null 2>&1
      ;;
    colima)
      _backend_colima_cli_available && command -v docker >/dev/null 2>&1
      ;;
    podman)
      command -v podman >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# Name of the Docker CLI's currently active context (Docker CLI concept, not ours).
_backend_docker_context_name() {
  docker context show 2>/dev/null || true
}

# Resolve the docker host endpoint URL for a given context name.
_backend_docker_context_host() {
  local context="$1"
  docker context inspect "$context" --format '{{ (index .Endpoints "docker").Host }}' 2>/dev/null || true
}

# Auto-detect the backend when CONTAINER_BACKEND is unset.
#
# Detection order matters: the active Docker context is inspected first so
# OrbStack and Colima (which both use the docker CLI) are identified before a
# generic docker fallback, then apple/container, docker, and podman by CLI.
_backend_detect_auto() {
  local docker_context=""

  if command -v docker >/dev/null 2>&1; then
    docker_context="$(_backend_docker_context_name)"
    if _backend_context_is_orbstack "$docker_context"; then
      printf '%s\n' "orbstack"
      return 0
    fi

    if _backend_context_is_colima "$docker_context"; then
      printf '%s\n' "colima"
      return 0
    fi
  fi

  if command -v container >/dev/null 2>&1; then
    printf '%s\n' "apple"
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    printf '%s\n' "docker"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    printf '%s\n' "podman"
    return 0
  fi

  echo "ERROR: No supported container backend found." >&2
  echo "  Install apple/container, Docker Desktop, OrbStack, Colima, or Podman." >&2
  return 1
}

# Emit every backend whose CLI(s) are detectable on PATH, one per line, in a
# stable order: apple, docker, orbstack, colima, podman. This is CLI-presence
# detection ONLY -- no daemon reachability probe, no backend selection/pinning,
# no mutation of DEV_CONTAINERS_BACKEND. It is the single shared source of truth
# for "which backends count as available on this host", consumed by both
# `dce doctor` and the integration test harness so the two can never drift.
#
# OrbStack is reported only when a Docker context referencing it exists
# (otherwise it is indistinguishable from plain docker); Colima requires both
# the colima and docker CLIs. Always returns 0 (empty output = none available).
backend_detect_available() {
  if command -v container >/dev/null 2>&1; then printf 'apple\n'; fi
  if command -v docker >/dev/null 2>&1; then printf 'docker\n'; fi
  if command -v docker >/dev/null 2>&1 \
     && docker context ls --format '{{.Name}}' 2>/dev/null | grep -iq orbstack; then
    printf 'orbstack\n'
  fi
  if command -v colima >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    printf 'colima\n'
  fi
  if command -v podman >/dev/null 2>&1; then printf 'podman\n'; fi
}

# Map a canonical backend name to the CLI binary used to drive it.
_backend_set_cli() {
  local selected="$1"

  case "$selected" in
    apple)
      _DC_CLI="container"
      ;;
    docker|orbstack|colima)
      _DC_CLI="docker"
      ;;
    podman)
      _DC_CLI="podman"
      ;;
    *)
      return 1
      ;;
  esac
}

# Print targeted install guidance when a selected backend's CLI is missing.
_backend_warn_missing_cli() {
  local selected="$1"

  echo "ERROR: Backend '$selected' selected but required CLI is unavailable." >&2
  case "$selected" in
    apple)
      echo "  Missing command: container" >&2
      ;;
    docker|orbstack)
      echo "  Missing command: docker" >&2
      ;;
    colima)
      if ! _backend_colima_cli_available; then
        echo "  Missing command: colima" >&2
      fi
      if ! command -v docker >/dev/null 2>&1; then
        echo "  Missing command: docker" >&2
      fi
      echo "  Install on macOS/Linux (Homebrew): brew install colima docker" >&2
      ;;
    podman)
      echo "  Missing command: podman" >&2
      ;;
  esac
}

# Resolve, validate, and lock in the active backend.
#
# Honors CONTAINER_BACKEND if set (otherwise auto-detects), confirms the CLI is
# installed, picks the matching binary, pins the Docker context for
# Colima/OrbStack, and exports DEV_CONTAINERS_BACKEND so later calls are cached.
# Every other backend_* function assumes this has run.
backend_use() {
  local requested="${1:-${CONTAINER_BACKEND:-}}"
  local selected=""

  if [[ -n "$requested" ]]; then
    if ! selected="$(_backend_normalize "$requested")"; then
      echo "ERROR: Unsupported CONTAINER_BACKEND '$requested'." >&2
      echo "  Supported values: $(printf '%s\n' "${DCE_BACKENDS[@]}" | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g')" >&2
      return 1
    fi
  else
    selected="$(_backend_detect_auto)" || return 1
  fi

  if ! _backend_cli_available "$selected"; then
    _backend_warn_missing_cli "$selected"
    return 1
  fi

  if ! _backend_set_cli "$selected"; then
    dce_die "Unsupported backend '$selected'."
  fi

  DEV_CONTAINERS_BACKEND="$selected"
  export DEV_CONTAINERS_BACKEND

  case "$selected" in
    colima)
      _backend_use_colima_context || return 1
      ;;
    orbstack)
      _backend_use_orbstack_context || return 1
      ;;
    *)
      unset DOCKER_CONTEXT
      ;;
  esac
}

# Echo the canonical backend name, running backend_use() if not yet selected.
backend_name() {
  if [[ -z "${DEV_CONTAINERS_BACKEND:-}" ]]; then
    backend_use || return 1
  fi

  printf '%s\n' "$DEV_CONTAINERS_BACKEND"
}

# Echo the CLI binary (docker/container/podman) for the active backend, with
# a live Colima-context re-check so a switched-away context is caught early.
backend_cli() {
  backend_name >/dev/null || return 1
  if [[ -z "$_DC_CLI" ]]; then
    _backend_set_cli "$DEV_CONTAINERS_BACKEND" || return 1
  fi

  if [[ "$DEV_CONTAINERS_BACKEND" == "colima" ]]; then
    _backend_require_colima_context || return 1
  fi

  printf '%s\n' "$_DC_CLI"
}

# True for backends that speak the Docker CLI (docker/orbstack/colima/podman),
# i.e. everything except apple/container. Drives Docker-only code paths
# (devcontainer.json, VS Code attach config).
backend_is_docker_compatible() {
  local backend="${1:-}"
  if [[ -z "$backend" ]]; then
    backend="$(backend_name)" || return 1
  fi

  [[ "$backend" == "docker" || "$backend" == "orbstack" || "$backend" == "colima" || "$backend" == "podman" ]]
}
