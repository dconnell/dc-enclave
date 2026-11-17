#!/usr/bin/env bash
# =============================================================================
# lib/backends/colima.sh - Colima backend: context and runtime detection/pin.
#
# Sourced (never executed directly) via lib/container-backend.sh. Holds the
# thin Colima layer: the CLI-presence probe, Colima Docker-context detection
# and DOCKER_CONTEXT pinning, the `colima status` runtime reader, and the
# context/runtime guard rails called by registry.sh (backend_cli,
# _backend_cli_available, _backend_warn_missing_cli) and by the facade
# dispatchers (backend_system_start, backend_system_info).
#
# Cross-file calls (_backend_docker_context_name and _backend_docker_context_host
# from registry.sh) resolve at invocation time against the facade and its
# sibling modules; nothing is auto-sourced here.
# =============================================================================

# Include guard: sourcing this module directly is a safe no-op on re-source.
if [[ -n "${_DC_BACKENDS_COLIMA_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKENDS_COLIMA_SH_LOADED=1

# Colima needs both its own CLI and the docker CLI (it drives docker).
_backend_colima_cli_available() {
  command -v colima >/dev/null 2>&1
}

# True if a Docker context points at Colima - by name, or by a host URL that
# references the Colima socket path (handles unnamed/renamed contexts).
_backend_context_is_colima() {
  local context="$1"
  local context_lower="${context,,}"

  if [[ "$context_lower" == *"colima"* ]]; then
    return 0
  fi

  if [[ -z "$context" ]]; then
    return 1
  fi

  local docker_host=""
  docker_host="$(_backend_docker_context_host "$context")"
  docker_host="${docker_host,,}"

  [[ "$docker_host" == *"/.colima/"* || "$docker_host" == *"colima"* ]]
}

# True if a Colima context is currently the active Docker context.
_backend_colima_context_active() {
  local context=""
  context="$(_backend_docker_context_name)"
  _backend_context_is_colima "$context"
}

# Locate a Colima Docker context and pin it via DOCKER_CONTEXT, or fail.
_backend_use_colima_context() {
  local ctx
  ctx="$(docker context ls --format '{{.Name}}' 2>/dev/null \
    | awk 'tolower($0) ~ /colima/ {print; exit}')"
  if [[ -z "$ctx" ]]; then
    echo "ERROR: Colima backend requires a Colima Docker context." >&2
    echo "  Run: colima start" >&2
    echo "  Or: docker context use colima" >&2
    return 1
  fi
  export DOCKER_CONTEXT="$ctx"
}

# Read Colima's active runtime (docker/containerd/...) from `colima status`.
_backend_colima_runtime() {
  local status=""
  # `colima status` writes its output to STDERR on current colima versions, so
  # capture both streams (and tolerate the non-zero exit colima returns when the
  # VM is down -- an empty result is handled below as "unknown runtime").
  status="$(colima status 2>&1 || true)"
  [[ -n "$status" ]] || return 1

  local runtime=""
  # `colima status` renders the runtime two ways across versions:
  #   legacy:  `runtime: docker`
  #   modern:  `time=".." level=info msg="runtime: docker"`  (logrus format)
  # Splitting on ':' and matching the first field (the old approach) breaks on
  # the modern form, where field $1 is the timestamp. Match the literal
  # `runtime:` token anywhere in the line and capture the following word.
  runtime="$(printf '%s\n' "$status" \
    | sed -nE 's/.*runtime:[[:space:]]*([A-Za-z0-9._-]+).*/\1/p' \
    | head -n1)"

  [[ -n "$runtime" ]] || return 1
  printf '%s\n' "${runtime,,}"
}

# Fail fast unless a Colima Docker context is active. DC Enclave drives
# Colima through the docker CLI, so it must be pointed at Colima to work.
_backend_require_colima_context() {
  local context=""
  context="$(_backend_docker_context_name)"

  if _backend_context_is_colima "$context"; then
    return 0
  fi

  echo "ERROR: Colima backend requires an active Colima Docker context." >&2
  if [[ -n "$context" ]]; then
    echo "  Current Docker context: $context" >&2
  fi
  echo "  Docker context is managed by Docker CLI configuration." >&2
  echo "  Run: colima start" >&2
  echo "  Or: docker context use colima" >&2
  return 1
}

# Fail fast unless Colima is running with the docker runtime. Non-docker
# runtimes (e.g. containerd) are unsupported and silently misbehave.
_backend_require_colima_docker_runtime() {
  local runtime=""
  runtime="$(_backend_colima_runtime 2>/dev/null || true)"

  if [[ -n "$runtime" && "$runtime" != "docker" ]]; then
    echo "ERROR: Colima backend requires Colima runtime 'docker'." >&2
    echo "  Current Colima runtime: $runtime" >&2
    echo "  Recreate/start with Docker runtime: colima stop && colima start --runtime docker" >&2
    return 1
  fi

  return 0
}
