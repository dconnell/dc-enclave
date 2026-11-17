#!/usr/bin/env bash
# =============================================================================
# lib/backends/docker-cli.sh - Shared plumbing for the Docker-CLI backend family.
#
# Sourced (never executed directly) via lib/container-backend.sh. Holds the
# docker/orbstack/colima buildx gates (dce_buildx_present/version/
# install_hint/require) and the safe list-membership helpers
# (_backend_list_contains, _backend_image_list_has) used by the facade
# dispatchers.
#
# backend_name/backend_cli resolve against lib/backends/registry.sh at
# invocation time; nothing is auto-sourced here.
# =============================================================================

# Include guard: sourcing this module directly is a safe no-op on re-source.
if [[ -n "${_DC_BACKENDS_DOCKER_CLI_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKENDS_DOCKER_CLI_SH_LOADED=1

# Return 0 if the buildx plugin is available for image builds on the active
# backend. Only the docker family (docker/orbstack/colima) routes `docker build`
# through buildx/BuildKit; podman has its own builder and apple uses a separate
# path, so buildx is not applicable there (reported present so gates pass).
dce_buildx_present() {
  case "$(backend_name)" in
    docker|orbstack|colima)
      "$(backend_cli)" buildx version >/dev/null 2>&1
      ;;
    *)
      return 0
      ;;
  esac
}

# Echo the buildx version string (first line); empty if absent/unavailable.
dce_buildx_version() {
  case "$(backend_name)" in
    docker|orbstack|colima)
      "$(backend_cli)" buildx version 2>/dev/null | awk 'NR==1{print; exit}'
      ;;
  esac
}

# Echo a per-platform install hint for the buildx plugin. buildx is bundled with
# Docker Desktop (macOS) and Docker CE; the common gap is WSL2's docker.io
# (Ubuntu), which ships no buildx.
dce_buildx_install_hint() {
  case "$(uname -s)" in
    Darwin)
      printf 'reinstall/upgrade Docker Desktop (it bundles buildx)'
      ;;
    *)
      printf 'sudo apt-get install docker-buildx-plugin (Docker apt repo), or download from https://github.com/docker/buildx/releases'
      ;;
  esac
}

# Hard gate for image builds: on a docker-compatible backend, require the buildx
# plugin. dce builds with DOCKER_BUILDKIT=1 (Containerfiles use multi-line
# heredoc RUNs the legacy builder drops), and Docker needs the buildx component
# for that. Prints an actionable message and returns non-zero if missing; no-op
# on podman/apple. Used by setup.sh and rebuild-image.sh before building. dce
# verifies, never installs.
dce_buildx_require() {
  if dce_buildx_present; then
    return 0
  fi
  {
    echo "✗ buildx plugin not found (required to build dce images with BuildKit)."
    echo ""
    echo "  dce Containerfiles use multi-line heredoc RUNs that need BuildKit;"
    echo "  without buildx the legacy builder drops them and containers fail to start."
    echo ""
    printf '  Install:  %s\n' "$(dce_buildx_install_hint)"
    echo "  Verify:   docker buildx version"
  } >&2
  return 1
}

# True if <needle> appears as an EXACT line in the output of the given command.
#
# The output is captured IN FULL before testing, so the reader never exits early
# and never SIGPIPEs the producer. This replaces the unsafe `<cmd> | grep -Fxq`
# shape: under `set -o pipefail`, grep's -q early-exit closes the pipe, a large
# producer (e.g. `image ls` over a full image store) dies on its next write with
# SIGPIPE (141), and pipefail turns a found match into a false-negative. Captured
# membership testing has none of that failure mode.
_backend_list_contains() {
  local needle="$1"; shift
  local out=""
  out="$("$@" 2>/dev/null)" || true
  [[ $'\n'"$out"$'\n' == *$'\n'"$needle"$'\n'* ]]
}

# Like _backend_list_contains but for the image store, and normalizes podman's
# "localhost/" prefix. podman stores/lists an unqualified build tag like
# `dce-base:latest` as `localhost/dce-base:latest`, while docker/orbstack/colima
# list the short name; docker/orbstack/colima keep working. Stripping a
# nonexistent leading "localhost/" from those short names is a no-op, so a single
# path covers the whole docker family. (Only image names get the prefix -- never
# container or network names -- so this stays out of _backend_list_contains.)
_backend_image_list_has() {  # <tag>
  local tag="$1" out normalized
  out="$("$(backend_cli)" image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)" || true
  normalized="$(printf '%s\n' "$out" | sed -E 's|^localhost/||')"
  [[ $'\n'"$normalized"$'\n' == *$'\n'"$tag"$'\n'* ]]
}
