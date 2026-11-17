#!/usr/bin/env bash
# =============================================================================
# lib/backends/orbstack.sh - OrbStack backend: Docker-context detection/pin.
#
# Sourced (never executed directly) via lib/container-backend.sh. Holds the
# thin OrbStack layer: the context-name match and the DOCKER_CONTEXT pin that
# registry.sh's backend_use invokes. OrbStack is indistinguishable from plain
# docker without an explicit context, hence the pin.
#
# No cross-file lib callees: the matcher is a pure string test and the pin
# shells out to `docker context ls` directly. Nothing is auto-sourced here.
# =============================================================================

# Include guard: sourcing this module directly is a safe no-op on re-source.
if [[ -n "${_DC_BACKENDS_ORBSTACK_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKENDS_ORBSTACK_SH_LOADED=1

# True if the context name itself indicates OrbStack.
_backend_context_is_orbstack() {
  local context="$1"
  [[ "${context,,}" == *"orbstack"* ]]
}

# Locate an OrbStack Docker context and pin it via DOCKER_CONTEXT, or fail.
# OrbStack is indistinguishable from plain docker without an explicit context.
_backend_use_orbstack_context() {
  local ctx
  ctx="$(docker context ls --format '{{.Name}}' 2>/dev/null \
    | awk 'tolower($0) ~ /orbstack/ {print; exit}')"
  if [[ -z "$ctx" ]]; then
    echo "ERROR: OrbStack backend requires an OrbStack Docker context." >&2
    echo "  Install OrbStack or create a Docker context pointing to it." >&2
    return 1
  fi
  export DOCKER_CONTEXT="$ctx"
}
