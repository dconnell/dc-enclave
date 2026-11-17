#!/usr/bin/env bash
# =============================================================================
# lib/backends/podman.sh - Podman backend: host-gateway capability probe.
#
# Sourced (never executed directly) via lib/container-backend.sh. Holds the
# thin Podman layer: the one-time probe deciding whether `podman create`
# understands --add-host host-gateway (docker's host.docker.internal alias).
#
# Cross-file state: the probe result is cached in
# _DC_PODMAN_HOST_GATEWAY_SUPPORTED, a facade-owned global (declared in
# container-backend.sh's globals block, alongside _DC_PODMAN_HOST_GATEWAY_WARNED
# which the facade's backend_create writes for the one-time fallback warning).
# Caller: backend_create in the facade. Nothing is auto-sourced here.
# =============================================================================

# Include guard: sourcing this module directly is a safe no-op on re-source.
if [[ -n "${_DC_BACKENDS_PODMAN_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKENDS_PODMAN_SH_LOADED=1

# Capability probe: does this Podman version understand --add-host host-gateway?
# Result is cached in _DC_PODMAN_HOST_GATEWAY_SUPPORTED so we only probe once.
_backend_podman_supports_host_gateway() {
  if [[ -n "$_DC_PODMAN_HOST_GATEWAY_SUPPORTED" ]]; then
    [[ "$_DC_PODMAN_HOST_GATEWAY_SUPPORTED" == "1" ]]
    return $?
  fi

  if podman create --help 2>/dev/null | grep -q 'host-gateway'; then
    _DC_PODMAN_HOST_GATEWAY_SUPPORTED="1"
    return 0
  fi

  _DC_PODMAN_HOST_GATEWAY_SUPPORTED="0"
  return 1
}
