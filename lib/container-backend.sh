#!/usr/bin/env bash
# =============================================================================
# lib/container-backend.sh - Single abstraction over five container runtimes.
#
# Exposes a stable `backend_*` API (build/create/start/exec/volumes/...) that
# dispatches to the right CLI for the active backend:
#
#   apple   -> `container` (apple/container)   macOS only, distinct CLI shape
#   docker  -> `docker`
#   orbstack-> `docker` (OrbStack Docker context)
#   colima  -> `docker` (Colima, requires Docker runtime + Colima context)
#   podman  -> `podman`
#
# docker/orbstack/colima/podman all share the Docker CLI, so most operations
# collapse to one branch; apple/container diverges and gets per-op fallbacks.
# Selection is memoized in DEV_CONTAINERS_BACKEND / _DC_CLI after backend_use().
# The registry (selection/detection) and docker-CLI-family plumbing live in
# lib/backends/*.sh, sourced below; this file stays the stable facade path.
# =============================================================================

# Auto-source common.sh if this lib is loaded directly (keeps a single import).
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_backend_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_backend_lib_dir/common.sh"
  unset _dce_backend_lib_dir
fi

if [[ -n "${_DC_BACKEND_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKEND_SH_LOADED=1

# Memoized backend selection and CLI/exec state (populated by backend_use).
declare -g DEV_CONTAINERS_BACKEND="${DEV_CONTAINERS_BACKEND:-}"
declare -g _DC_CLI=""
declare -g _DC_PODMAN_HOST_GATEWAY_SUPPORTED=""
declare -g _DC_PODMAN_HOST_GATEWAY_WARNED=0
# Block class matched by _backend_apple_native_build_blocked: "" (no match) or
# egress|context|transport. Reset by the classifier on every call.
declare -g _DC_APPLE_BLOCK_CLASS=""

# Resolve our own directory once so the module sources below use a stable path
# regardless of how this facade was reached (script-relative, symlink, etc.).
_dce_backend_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the backend modules in dependency order (registry first: docker-cli.sh
# calls backend_name/backend_cli from it). Each carries its own include guard,
# so the modules are also safe to source directly from tests.
# shellcheck disable=SC1091
# Sibling lib include; path resolved above, not followed statically.
source "$_dce_backend_lib_dir/backends/registry.sh"
# shellcheck disable=SC1091
source "$_dce_backend_lib_dir/backends/docker-cli.sh"

unset _dce_backend_lib_dir

# Colima needs both its own CLI and the docker CLI (it drives docker).
_backend_colima_cli_available() {
  command -v colima >/dev/null 2>&1
}

# True if the context name itself indicates OrbStack.
_backend_context_is_orbstack() {
  local context="$1"
  [[ "${context,,}" == *"orbstack"* ]]
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

# =============================================================================
# apple/container host-integration probes.
#
# docker-family backends give containers host-loopback reachability for free
# (host.docker.internal). apple/container only does so after a ONE-TIME,
# host-global admin bootstrap (see backend_apple_dns_bootstrap_command): the
# container system then redirects container-bound traffic to a synthetic IP
# into the macOS host's 127.0.0.1 via a packet-filter rule, and dce stages a
# hosts entry for that IP inside every apple container (see
# lib/common/container-hosts.sh, which owns the constants used here). The
# probes below let callers (doctor / new-container guidance) detect whether the
# host-side integration is present and report it accurately. They are strictly
# read-only: dce never runs sudo and never issues mutating `system dns`
# subcommands.
# =============================================================================

# Minimum apple/container CLI version with `container system dns` host
# integration (the domain create/list surface and the localhost redirect).
readonly _DC_APPLE_HOST_INTEGRATION_MIN_VERSION="0.9.0"

# Internal: compare dotted-decimal version strings; return 0 when <have> is
# greater than or equal to <need>. Component-wise numeric compare (0.10.0 >
# 0.9.0); every position up to the LONGER of the two versions participates,
# with missing trailing components counting as 0 (1.4 == 1.4.0, 0.9.0.1 >
# 0.9.0). Fail-safe by design: any malformed, empty, or overlong-component
# input returns 1 ("too old"), so an unparseable version can never let a gated
# feature report success. Components are capped at 15 digits because bash
# arithmetic is 64-bit -- a longer numeric component could overflow and invert
# the comparison instead of failing safely. No version-compare helper existed
# anywhere in lib/ before this one, hence the local definition.
_backend_version_at_least() {  # <have> <need>
  local have="$1" need="$2"

  # Fail-safe: anything malformed (or empty, or with a component longer than 15
  # digits) counts as unsupported; the cap keeps 10# arithmetic inside the
  # 64-bit range so an absurd version can never overflow into a wrong answer.
  if [[ ! "$have" =~ ^[0-9]{1,15}(\.[0-9]{1,15})*$ || ! "$need" =~ ^[0-9]{1,15}(\.[0-9]{1,15})*$ ]]; then
    return 1
  fi

  local -a have_parts=() need_parts=()
  IFS=. read -r -a have_parts <<< "$have"
  IFS=. read -r -a need_parts <<< "$need"

  # Compare every position of the longer version string; shorter inputs read
  # as 0 past their end, so 4+ component versions compare correctly.
  local i have_c need_c
  local max_i=$(( ${#have_parts[@]} > ${#need_parts[@]} ? ${#have_parts[@]} : ${#need_parts[@]} ))
  for ((i = 0; i < max_i; i++)); do
    # 10# forces base-10 so a padded component (01) cannot parse as octal.
    have_c=$(( 10#${have_parts[i]:-0} ))
    need_c=$(( 10#${need_parts[i]:-0} ))
    if (( have_c > need_c )); then
      return 0
    fi
    if (( have_c < need_c )); then
      return 1
    fi
  done
  return 0
}

# Return 0 (supported) when the apple/container CLI's version is at least
# _DC_APPLE_HOST_INTEGRATION_MIN_VERSION. Fail-safe: a missing CLI, a failing
# `container --version`, or an unparseable version string all return 1. The
# version line looks like "container CLI version 1.4.1 (build: release,
# commit: 9a8917c)" -- the first dotted-numeric token is the version (the
# build/commit tail carries none), so a defensive first-match parse beats
# pinning the exact sentence across CLI versions.
backend_apple_version_supported() {
  local raw="" version=""
  raw="$(container --version 2>/dev/null)" || return 1

  version="$(printf '%s\n' "$raw" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1)" || true
  [[ -n "$version" ]] || return 1

  _backend_version_at_least "$version" "$_DC_APPLE_HOST_INTEGRATION_MIN_VERSION"
}

# Return 0 when `container system dns list` shows the dce gateway domain
# ($_DCE_HOSTS_GATEWAY_APPLE_NAME), i.e. the one-time admin bootstrap ran on
# this host. Tolerant by design, degrading to "not present/unknown": a failed
# or malformed listing is indistinguishable from absent, and callers gate
# guidance (never correctness) on the answer.
#
# Parse order: --format json first (a bare array of domain strings -- the
# stable machine-readable form), raw table second for CLIs without the flag.
# A successful JSON listing is conclusive in both directions, so it never
# falls through to the table. Matching tolerates a trailing-dot FQDN form and
# is anchored/quoted so a lookalike substring cannot false-positive. Note the
# list surface exposes domains only -- the CLI cannot report whether the
# domain carries a --localhost entry; reserving the canonical domain name for
# the gateway bootstrap is what makes presence a meaningful signal.
backend_apple_dns_domain_present() {
  local out="" dom=""
  # Regex-escape the dots once (the domain is a constant; keep it that way).
  dom="${_DCE_HOSTS_GATEWAY_APPLE_NAME//./\\.}"
  # The same regexes the probe has always used, now applied with [[ =~ ]] over
  # CAPTURED output: `capture | grep -q` lets grep exit on first match and
  # SIGPIPE the producer, which pipefail turns into a false negative (see
  # _backend_list_contains). No pipe here, so no reader can outlive the
  # already-finished producer.
  local json_re="\"${dom}\.?\""
  local row_re="^[[:space:]]*${dom}\.?([[:space:]]|$)"

  if out="$(container system dns list --format json 2>/dev/null)"; then
    if [[ "$out" =~ $json_re ]]; then
      return 0
    fi
    return 1
  fi

  # Table fallback: one domain per row under a DOMAIN header; anchor to the row.
  # bash =~ anchors ^/$ at string boundaries only, so anchor per line instead.
  if out="$(container system dns list 2>/dev/null)"; then
    local line=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $row_re ]]; then
        return 0
      fi
    done <<< "$out"
  fi
  return 1
}

# Echo the canonical one-time bootstrap command that enables host-loopback
# reachability for apple/container. Requires an administrator and mutates the
# host (DNS domain + packet-filter rule), so dce only ever PRINTS this (doctor
# / new-container guidance) -- never runs it. The IP is the shared gateway
# constant from lib/common/container-hosts.sh; the two must never drift.
backend_apple_dns_bootstrap_command() {
  printf 'sudo container system dns create %s --localhost %s\n' \
    "$_DCE_HOSTS_GATEWAY_APPLE_NAME" "$_DCE_HOSTS_GATEWAY_IP"
}

# Echo a human-readable version string for the active backend.
backend_version() {
  case "$(backend_name)" in
    apple)
      container --version 2>/dev/null || echo "container version unknown"
      ;;
    docker|orbstack)
      docker --version 2>/dev/null || echo "docker version unknown"
      ;;
    colima)
      local colima_version=""
      local docker_version=""

      colima_version="$(colima version 2>/dev/null | awk 'NR == 1 { print; exit }')"
      [[ -n "$colima_version" ]] || colima_version="colima version unknown"
      docker_version="$(docker --version 2>/dev/null || echo "docker version unknown")"

      printf '%s (%s)\n' "$colima_version" "$docker_version"
      ;;
    podman)
      podman --version 2>/dev/null || echo "podman version unknown"
      ;;
  esac
}

# Ensure the runtime engine is up (start daemon/machine/VM as needed) so the
# backend is ready for commands. Returns non-zero (with guidance) if unreachable.
backend_system_start() {
  case "$(backend_name)" in
    apple)
      container system start
      ;;
    docker|orbstack)
      docker info >/dev/null
      ;;
    colima)
      if ! _backend_colima_cli_available; then
        echo "ERROR: Colima backend selected but 'colima' command is unavailable." >&2
        echo "  Install: brew install colima docker" >&2
        return 1
      fi

      if ! _backend_colima_context_active || ! docker info >/dev/null 2>&1; then
        colima start >/dev/null 2>&1 || true
      fi

      _backend_require_colima_context || return 1

      if ! docker info >/dev/null 2>&1; then
        if ! _backend_require_colima_docker_runtime; then
          return 1
        fi
        echo "ERROR: Colima is not reachable via Docker CLI." >&2
        echo "  Try: colima start" >&2
        return 1
      fi

      _backend_require_colima_docker_runtime || return 1
      ;;
    podman)
      if podman info >/dev/null 2>&1; then
        return 0
      fi

      if podman machine --help >/dev/null 2>&1; then
        podman machine start >/dev/null 2>&1 || true
      fi

      if podman info >/dev/null 2>&1; then
        return 0
      fi

      echo "ERROR: Podman is not reachable." >&2
      echo "  Try: podman machine start (macOS) or ensure rootless podman is installed and configured." >&2
      return 1
      ;;
  esac
}

# Print detailed runtime info for the active backend (for `dce status`).
backend_system_info() {
  case "$(backend_name)" in
    apple)
      # apple/container has no `system info` subcommand; `system status` prints
      # the status table and exits 0 when services are running (reachability
      # probe for doctor + the integration suite).
      container system status
      ;;
    docker|orbstack)
      docker info
      ;;
    colima)
      colima status
      echo "---"
      _backend_require_colima_context || return 1
      docker info
      ;;
    podman)
      podman info
      ;;
  esac
}

# True if a captured apple/container build log shows the native builder CANNOT
# complete the build in the current host environment -- independent of the
# Containerfile itself. Three known classes, none of them a Containerfile bug:
#   egress    -- no outbound network -> apt/apk cannot resolve or reach any repo
#                ("Temporary failure resolving", "Unable to locate package",
#                etc.). The apple builder runs in a vmnet-NAT'd namespace that
#                a host VPN (or this host's networking) breaks.
#   context   -- no build-context transfer -> COPY/ADD of a local file fails
#                because the builder receives an empty context ("failed to
#                calculate checksum").
#   transport -- the gRPC transport carrying the build dies mid-call
#                ("Transport became inactive", and on newer versions "Stream
#                unexpectedly closed"): apple base64-encodes the Dockerfile
#                into a ~16KB-capped gRPC header, an ~11.5KB effective file cap
#                (https://github.com/apple/container/issues/735).
# On a match, sets the global _DC_APPLE_BLOCK_CLASS to egress|context|transport
# so callers can warn accurately per class; it is reset to empty on entry so a
# non-matching log can never leak a stale class. This is the trigger for
# _backend_apple_build_image's peer-backend fallback, which is safe because a
# genuine Containerfile error also fails on the peer -- and for the transport
# class the peer (docker/podman) has no Dockerfile size cap.
# Used as:  if _backend_apple_native_build_blocked "$log"; then ...; fi
_backend_apple_native_build_blocked() {  # <build-log>
  _DC_APPLE_BLOCK_CLASS=""
  [[ -n "$1" ]] || return 1

  # Match with [[ =~ ]] over the captured string, not `| grep -q`: a large
  # build log plus grep's early-exit can SIGPIPE the producer, and pipefail
  # would turn a found match into a false negative (see
  # backend_apple_dns_domain_present for the same reasoning).
  local log="$1"
  local egress_re='Temporary failure resolving|Temporary failure in name resolution|Unable to locate package|no installation candidate|Failed to fetch'
  local context_re='failed to calculate checksum'
  local transport_re='Transport became inactive|Stream unexpectedly closed'

  if [[ "$log" =~ $egress_re ]]; then
    _DC_APPLE_BLOCK_CLASS="egress"
    return 0
  fi
  if [[ "$log" =~ $context_re ]]; then
    _DC_APPLE_BLOCK_CLASS="context"
    return 0
  fi
  if [[ "$log" =~ $transport_re ]]; then
    _DC_APPLE_BLOCK_CLASS="transport"
    return 0
  fi
  return 1
}

# Pick a reachable peer backend whose build network CAN reach the internet, for
# sourcing an image when apple/container's own builder has no egress. The docker
# family (docker/orbstack/colima) all drive the `docker` CLI and share its build
# network, so one `docker info` reachability check covers all three; podman is
# the fallback. Echoes the CLI binary name (docker|podman), or returns non-zero
# if none is reachable.
_backend_apple_peer_cli() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf 'docker\n'
    return 0
  fi
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    printf 'podman\n'
    return 0
  fi
  return 1
}

# Build <tag> on a peer CLI and load the resulting image archive into
# apple/container's store under the same tag. Returns non-zero on any failure;
# the caller decides how to surface it. <peer-cli> is "docker" or "podman".
#
# docker: build into docker's own store (`docker build --tag`) then `docker save`
# to a tarball. The older `docker build --output type=oci,dest=` form is NOT
# supported by the default docker/orbstack driver ("OCI exporter is not supported
# for the docker driver"), and `--output` to a file needs a docker-container
# driver regardless; build-then-save works with the stock driver. (The heredocs
# in Containerfile.base still need buildx, but that is the modern docker default
# and buildx is present on any real install.)
# podman has no --output on build, so it builds OCI then exports via
# `save --format oci-archive`; podman stores unqualified tags under localhost/,
# which the archive preserves, so the loaded image must be re-tagged to the name
# apple-side lookups (backend_image_exists) expect.
_backend_apple_build_via_peer() {  # <peer-cli> <tag> <file> <context> [build-args...]
  local peer="$1" tag="$2" file="$3" context="$4"; shift 4
  local image_tar ok=1
  image_tar="$(mktemp "${TMPDIR:-/tmp}/dce-apple-peer.XXXXXX.tar")" || return 1

  if [[ "$peer" == "docker" ]]; then
    docker build --tag "$tag" --file "$file" "$@" "$context" \
      && docker save -o "$image_tar" "$tag" \
      && container image load --input "$image_tar" >/dev/null \
      || ok=0
  else  # podman
    podman build --format oci --tag "$tag" --file "$file" "$@" "$context" \
      && podman save --format oci-archive -o "$image_tar" "$tag" \
      && container image load --input "$image_tar" >/dev/null \
      && container image tag "localhost/$tag" "$tag" \
      || ok=0
  fi

  rm -f "$image_tar"
  [[ $ok -eq 1 ]] || return 1

  # Final guard: confirm the tag actually landed under the expected name before
  # reporting success (catches any tag-prefix surprise across CLI versions).
  backend_image_exists "$tag"
}

# Internal: attempt a NATIVE apple/container build of <tag> from <file>, tee'ing
# live output to the user while capturing the log so an environment-blocked
# failure can be classified without a second run. The return status
# distinguishes the two failure shapes so callers can choose between
# propagation and a peer fallback:
#   0  native build succeeded
#   1  real build error (matched no environment-block class; output was already
#      streamed -- callers must propagate it, never mask it with a peer build)
#   2  environment/transport-blocked failure; _DC_APPLE_BLOCK_CLASS names the
#      matched class (egress|context|transport) and a peer backend CAN
#      complete this build (for transport: no Dockerfile size cap)
# An internal setup failure (e.g. mktemp) also returns 1: fail without
# fallback, the safest degradation for an unknown cause.
_backend_apple_build_native() {  # <tag> <file> <context> [build-args...]
  local tag="$1" file="$2" context="$3"; shift 3
  local work_dir native_log rc=1

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dce-apple-build.XXXXXX")" || return 1
  native_log="$work_dir/native.log"

  if container build --tag "$tag" --file "$file" "$@" "$context" 2>&1 | tee "$native_log"; then
    rc=0
  elif ! _backend_apple_native_build_blocked "$(cat "$native_log" 2>/dev/null || true)"; then
    : # Real build error -- already streamed via tee; just propagate non-zero.
  else
    rc=2 # Environment/transport-blocked; class is in _DC_APPLE_BLOCK_CLASS.
  fi

  rm -rf "$work_dir"
  return "$rc"
}

# Build an image for the apple/container backend. The native builder is tried
# first (_backend_apple_build_native); on an environment-blocked failure (no
# outbound network / no build-context transfer -- typically a host VPN the
# vmnet NAT cannot traverse -- or a gRPC transport death from an oversized
# Dockerfile, issue #735) it transparently rebuilds on a reachable docker/podman
# peer and loads the image into apple/container under the same tag. Any OTHER
# failure (real Containerfile error, etc.) is re-streamed and propagated -- the
# fallback never masks it (a genuine error fails on the peer too).
# _DC_APPLE_BLOCK_CLASS names the matched block class so the warnings stay
# accurate per class.
_backend_apple_build_image() {  # <tag> <file> <context> [build-args...]
  local tag="$1" file="$2" context="$3"; shift 3
  local peer rc=0

  _backend_apple_build_native "$tag" "$file" "$context" "$@" || rc=$?

  if (( rc == 0 )); then
    return 0
  fi
  if (( rc == 1 )); then
    return 1 # Real build error -- already streamed; propagate, never mask.
  fi

  # rc == 2: environment/transport-blocked (class in _DC_APPLE_BLOCK_CLASS).
  if ! peer="$(_backend_apple_peer_cli)"; then
    if [[ "$_DC_APPLE_BLOCK_CLASS" == "transport" ]]; then
      dce_warn "apple/container's native builder gRPC transport rejected this build -- most"
      dce_warn "likely the Containerfile exceeds apple's ~11.5KB effective cap (issue #735),"
      dce_warn "and no reachable docker/podman peer (which has no cap) to build on."
      dce_warn "Build '$tag' on another backend, export OCI, then: container image load."
    else
      dce_warn "apple/container's native builder cannot complete this build in the current"
      dce_warn "environment (no outbound network or no build-context transfer -- typically a"
      dce_warn "host VPN the vmnet NAT cannot traverse), and no reachable docker/podman peer"
      dce_warn "to build on. Build '$tag' on another backend, export OCI, then: container image load."
    fi
    return 1
  fi

  if [[ "$_DC_APPLE_BLOCK_CLASS" == "transport" ]]; then
    dce_warn "apple/container's native builder gRPC transport rejected this build -- most"
    dce_warn "likely the Containerfile exceeds apple's ~11.5KB effective cap (issue #735)."
    dce_warn "Falling back: building '$tag' on '$peer' (no size cap) and loading the image"
    dce_warn "into apple/container."
  else
    dce_warn "apple/container's native builder cannot complete this build (environment block:"
    dce_warn "no outbound network / no build-context transfer)."
    dce_warn "Falling back: building '$tag' on '$peer' and loading the image into apple/container."
  fi
  if _backend_apple_build_via_peer "$peer" "$tag" "$file" "$context" "$@"; then
    return 0
  fi
  dce_warn "peer build/load failed; apple/container image store left unchanged."
  return 1
}

# Build an image from a Containerfile. Extra args are forwarded to the builder.
backend_build_image() {
  local tag="$1"
  local file="$2"
  local context="$3"
  shift 3

  case "$(backend_name)" in
    apple)
      _backend_apple_build_image "$tag" "$file" "$context" "$@"
      ;;
    docker|orbstack|colima|podman)
      # Force BuildKit: composed images write their ENTRYPOINT via a multi-line
      # `RUN cat >f <<'EOF' ... EOF` shell heredoc, which the *legacy* Docker
      # builder (the default when dockerd is started bare, e.g. on WSL2) parses
      # as a one-line RUN and emits as an EMPTY file -- the container then exits
      # 255 on start. BuildKit parses the heredoc as one instruction and writes
      # it intact. BuildKit is the default on Docker 23+, so this is a no-op
      # there; podman ignores DOCKER_BUILDKIT.
      DOCKER_BUILDKIT=1 "$(backend_cli)" build --tag "$tag" --file "$file" "$@" "$context"
      ;;
  esac
}

# Build an image from a Containerfile, transparently handling the transport-
# chaining part files compose-containerfile.sh (apple mode) emits when the
# composed file exceeds apple/container's ~11.5KB effective Dockerfile cap
# (issue #735): consecutive part files "<file>.p0", "<file>.p1", ... next to
# the canonical file (p0 FROM dce-base:latest, pk FROM the previous part's
# dce-stage-<hash>-<k-1>:latest).
#
# Part discovery: a missing "<file>.p0" means no chain exists and the call is
# a plain backend_build_image passthrough (byte-identical behavior). If p0
# exists but the sequence has a gap (e.g. .p0 then .p2 -- a part vanished
# between compose and build), die naming the missing file rather than silently
# building a broken image lineage.
#
# apple: the parts are built sequentially with the NATIVE builder, part k
# tagged dce-stage-<hash>-<k>:latest (<hash> parsed from the mandatory
# "Containerfile.<hash>" basename -- the stage names embed it, the same
# contract compose enforces) and the FINAL part tagged <tag>; only the final
# part receives the extra build-args (non-final parts declare no ARGs). The
# canonical file itself is never built. A part that is environment/transport-
# blocked in apple's native builder cannot simply continue on a peer mid-chain
# -- part k's FROM references the previous stage tag, which lives only in
# apple's store when parts 0..k-1 built natively, so the peer could never
# resolve it (a mixed-store dead end). Instead the FIRST blocked part restarts
# the WHOLE chain on a reachable peer from part 0: parts 0..N-2 build directly
# on the peer CLI under their stage tags (podman's localhost/ prefix
# resolution makes the unqualified FROM names resolve within podman's own
# store), and the final part goes through _backend_apple_build_via_peer
# (build -> save -> `container image load` -> final-tag guard, including
# podman re-tagging), so <tag> lands in apple/container's store with every
# stage resolvable in one place. No reachable peer -- or a real (non-block)
# build error, which would fail on the peer identically -- aborts the chain.
# docker/orbstack/colima/podman: those builders have no Dockerfile cap, so the
# parts are never touched and only the canonical <file> is built.
# Used as:  backend_build_image_chained "dce-img-<hash>:latest" <file> <ctx> \
#             --build-arg DC_BASE_ID=... --build-arg DC_BUILT_UTC=...
backend_build_image_chained() {  # <tag> <file> <context> [extra build-args...]
  local tag="$1"
  local file="$2"
  local context="$3"
  shift 3

  # docker-family/podman: parts are an apple-only artifact (no cap there).
  if [[ "$(backend_name)" != "apple" ]]; then
    backend_build_image "$tag" "$file" "$context" "$@"
    return
  fi

  # Discover the consecutive part sequence: p0, p1, ... up to the first gap.
  local parts=()
  local k=0
  while [[ -f "${file}.p${k}" ]]; do
    parts+=("${file}.p${k}")
    k=$((k + 1))
  done

  if [[ ${#parts[@]} -eq 0 ]]; then
    backend_build_image "$tag" "$file" "$context" "$@"
    return
  fi

  # Corruption guard: an existing part beyond the first gap means the sequence
  # is broken (e.g. .p0 and .p2 with .p1 gone) -- the build would chain FROM an
  # image that is never produced. Die naming the exact missing file.
  local stray
  for stray in "$file".p*; do
    [[ -e "$stray" && "$stray" =~ \.p([0-9]+)$ ]] || continue
    # 10# forces base-10 so a zero-padded index (08) cannot parse as invalid
    # octal, silently fail the compare, and let the stray escape the gap
    # check (same hazard _backend_version_at_least documents for versions).
    if (( 10#${BASH_REMATCH[1]} >= k )); then
      dce_die "Chained build part sequence is broken: '$file.p$k' is missing but later parts exist (e.g. '$stray').
The parts chain FROM each previous stage's image, so the chain cannot build with a gap; re-compose via dce (scripts/rebuild-image.sh) to regenerate them (apple/container issue #735)."
    fi
  done

  local base="${file##*/}"
  local stage_hash=""
  if [[ ! "$base" =~ ^Containerfile\.([0-9a-f]+)$ ]]; then
    dce_die "Cannot build chained apple parts: '$file' does not match the required basename 'Containerfile.<hash>' (hash must be [0-9a-f]+)
The stage tags derive from the image hash, so the canonical file must be named by it; compose via dce (scripts/rebuild-image.sh) or rename the output (apple/container issue #735)."
  fi
  stage_hash="${BASH_REMATCH[1]}"

  local total=${#parts[@]}
  local k part stage_tag peer="" rc pk

  # Build the parts with the NATIVE apple builder directly -- NOT per-part
  # through backend_build_image. A per-part peer fallback would strand the
  # chain in a mixed-store dead end: part k chains FROM the previous part's
  # stage tag, which exists only in apple's store when parts 0..k-1 built
  # natively, so a peer continuing from part k could never resolve it. The
  # FIRST environment/transport-blocked part instead restarts the WHOLE chain
  # on the peer from part 0, guaranteeing every stage the final part chains
  # FROM lives in one store.
  for ((k = 0; k < total; k++)); do
    part="${parts[$k]}"
    if ((k + 1 == total)); then
      # Final part: the caller's tag, plus the extra build-args (provenance).
      stage_tag="$tag"
    else
      stage_tag="dce-stage-${stage_hash}-${k}:latest"
    fi
    printf '  chained part %d/%d -> %s\n' "$((k + 1))" "$total" "$stage_tag"

    rc=0
    if ((k + 1 == total)); then
      _backend_apple_build_native "$stage_tag" "$part" "$context" "$@" || rc=$?
    else
      _backend_apple_build_native "$stage_tag" "$part" "$context" || rc=$?
    fi

    if (( rc == 0 )); then
      continue
    fi
    if (( rc == 1 )); then
      # Real Containerfile error: already streamed by the native attempt.
      # The peer would fail identically -- abort instead of masking it.
      return 1
    fi

    # rc == 2: this part is environment/transport-blocked in apple's native
    # builder (class in _DC_APPLE_BLOCK_CLASS); a peer CAN build it. Restart
    # the whole chain on the peer from part 0.
    if ! peer="$(_backend_apple_peer_cli)"; then
      if [[ "$_DC_APPLE_BLOCK_CLASS" == "transport" ]]; then
        dce_warn "apple/container's native builder gRPC transport rejected chained part $((k + 1))/$total -- most"
        dce_warn "likely the part exceeds apple's ~11.5KB effective cap (issue #735), and no"
        dce_warn "reachable docker/podman peer (which has no cap) to build on."
      else
        dce_warn "apple/container's native builder cannot build chained part $((k + 1))/$total in the"
        dce_warn "current environment (no outbound network or no build-context transfer --"
        dce_warn "typically a host VPN the vmnet NAT cannot traverse), and no reachable"
        dce_warn "docker/podman peer."
      fi
      dce_warn "The chained build cannot proceed: build the parts on another backend, export"
      dce_warn "OCI, then: container image load."
      return 1
    fi
    dce_warn "apple/container's native builder cannot build chained part $((k + 1))/$total ($_DC_APPLE_BLOCK_CLASS block)."
    dce_warn "Restarting the whole chain on peer '$peer' from part 0: the stages built so far"
    dce_warn "live only in apple/container's image store, invisible to the peer builder, so"
    dce_warn "continuing from part $((k + 1)) could not resolve their chained FROM tags."
    for ((pk = 0; pk < total - 1; pk++)); do
      stage_tag="dce-stage-${stage_hash}-${pk}:latest"
      printf '  chained part %d/%d -> %s\n' "$((pk + 1))" "$total" "$stage_tag"
      if [[ "$peer" == "docker" ]]; then
        docker build --tag "$stage_tag" --file "${parts[$pk]}" "$context" || return 1
      else
        # podman: --format oci keeps the build OCI-native for the later save,
        # and podman's localhost/ prefix resolution makes the unqualified FROM
        # stage names resolve within podman's own store.
        podman build --format oci --tag "$stage_tag" --file "${parts[$pk]}" "$context" || return 1
      fi
    done
    # Final part on the peer: _backend_apple_build_via_peer already handles
    # build -> save -> `container image load` -> final-tag guard (including
    # podman's localhost/ re-tagging), and carries the extra build-args.
    printf '  chained part %d/%d -> %s\n' "$total" "$total" "$tag"
    if _backend_apple_build_via_peer "$peer" "$tag" "${parts[$((total - 1))]}" "$context" "$@"; then
      return 0
    fi
    dce_warn "peer build/load failed; apple/container image store left unchanged."
    return 1
  done
}

# Return whether an image tag exists in the backend's image store.
# apple/container has several list-flag variants across versions, hence fallbacks.
backend_image_exists() {
  local tag="$1"

  case "$(backend_name)" in
    apple)
      if container image ls --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1; then
        _backend_list_contains "$tag" container image ls --format '{{.Repository}}:{{.Tag}}'
      elif container images --format '{{.Repository}}:{{.Tag}}' >/dev/null 2>&1; then
        _backend_list_contains "$tag" container images --format '{{.Repository}}:{{.Tag}}'
      else
        # Raw-table fallback for older apple/container: reformat to repo:tag and
        # exact-match against the captured output (no early-exit reader).
        local raw="" rows=""
        raw="$(container image ls 2>/dev/null)" || raw=""
        rows="$(printf '%s\n' "$raw" | awk '{print $1 ":" $2}')" || rows=""
        [[ $'\n'"$rows"$'\n' == *$'\n'"$tag"$'\n'* ]]
      fi
      ;;
    docker|orbstack|colima|podman)
      _backend_image_list_has "$tag"
      ;;
  esac
}

# Echo the backend-local image Id (content digest) for an image reference, or
# empty if it cannot be determined. Used for image provenance (the base.id
# label/log field) so a reader can tell whether dce-base was rebuilt since a
# derived image was built. Best-effort and backend-local by design: it never
# fails a build (empty is acceptable), and the value is not portable across
# backends -- it is only meaningful within one backend's image store.
backend_image_id() {
  local ref="$1"

  case "$(backend_name)" in
    apple)
      # apple/container's inspect surface differs from docker's; attempt the
      # closest form and fall through to empty on any failure.
      container image inspect "$ref" --format '{{.ID}}' 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image inspect "$ref" --format '{{.Id}}' 2>/dev/null || true
      ;;
  esac
}

# Echo the on-disk size (in bytes) of an image, or empty when it cannot be
# determined. Best-effort and backend-local by design (like backend_image_id):
# empty is an acceptable "unknown," never a hard failure. Used by snapshot
# listings so operators can see disk cost.
backend_image_size() {
  local ref="$1"

  case "$(backend_name)" in
    apple)
      container image inspect "$ref" --format '{{.size}}' 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image inspect "$ref" --format '{{.Size}}' 2>/dev/null || true
      ;;
  esac
}

# Echo the value of an OCI image LABEL key, or empty when absent / unknown.
# Best-effort and backend-local by design: never fails a listing. Used to read
# dce.snapshot.* provenance labels stamped on snapshot images.
backend_image_label() {
  local ref="$1"
  local key="$2"

  case "$(backend_name)" in
    apple)
      container image inspect "$ref" --format "{{index .config.labels \"$key\"}}" 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image inspect "$ref" --format "{{index .Config.Labels \"$key\"}}" 2>/dev/null || true
      ;;
  esac
}

# Echo the backend-local image Id that a running/stopped container is bound to,
# or empty if it cannot be determined. Used by the stale-container check
# (scripts/list.sh, scripts/status.sh) to compare the container's bound image
# against the current image the project's CONTAINER_IMAGE tag resolves to.
# Best-effort and backend-local by design, like backend_image_id: empty is an
# acceptable "unknown," never a hard failure.
backend_container_image_id() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      # apple/container's inspect surface differs from docker's; attempt the
      # closest form and fall through to empty on any failure.
      container inspect "$name" --format '{{.ImageID}}' 2>/dev/null || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" inspect "$name" --format '{{.Image}}' 2>/dev/null || true
      ;;
  esac
}

# Determine whether a project's container is stale: bound to an older image than
# the project's configured CONTAINER_IMAGE tag currently resolves to. This is
# the single stale predicate shared by `dce list` and `dce status`.
#
# Returns 0 (stale) only when drift is *proven*: the backend is usable, the
# container exists, and both the desired image's id and the container's bound
# image id are known and differ. Returns 1 in every other case (container
# missing, backend unavailable, an id unknown), so the caller never produces a
# false-positive stale warning. Prints a one-line reason on stdout when stale,
# empty otherwise, so callers can surface the comparison in debug output.
backend_container_is_stale() {
  local project="$1"
  local desired_ref="$2"

  [[ -n "$desired_ref" ]] || return 1

  local desired_id="" container_id=""
  desired_id="$(backend_image_id "$desired_ref" 2>/dev/null || true)"
  [[ -n "$desired_id" ]] || return 1

  container_id="$(backend_container_image_id "$project" 2>/dev/null || true)"
  [[ -n "$container_id" ]] || return 1

  if [[ "$desired_id" != "$container_id" ]]; then
    printf '%s\n' "container image $container_id != desired $desired_id"
    return 0
  fi
  return 1
}

# List images as repo<TAB>tag<TAB>id rows (normalized across backends/versions).
backend_list_images() {
  case "$(backend_name)" in
    apple)
      if container image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' >/dev/null 2>&1; then
        container image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}'
      elif container images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' >/dev/null 2>&1; then
        container images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}'
      else
        container image ls 2>/dev/null | awk 'NR > 1 {print $1 "\t" $2 "\t" $3}'
      fi
      ;;
    docker|orbstack|colima|podman)
      # podman lists unqualified builds as "localhost/<repo>"; strip the prefix
      # so consumers (clean/snapshot/rm/provenance) that match on short repo
      # names like "dce-base", "dce-img-<hash>", "dce-<project>", or
      # "dce-snap-<...>" see the same short repo as docker/orbstack/colima.
      # sed is not an early-exit reader, so
      # it cannot SIGPIPE the producer under pipefail.
      "$(backend_cli)" image ls --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}' \
        | sed -E 's|^localhost/||'
      ;;
  esac
}

# Remove an image reference (silently succeeds if already absent).
backend_remove_image() {
  local image_ref="$1"

  case "$(backend_name)" in
    apple)
      container image rm "$image_ref" >/dev/null 2>&1 || container rmi "$image_ref" >/dev/null 2>&1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" image rm "$image_ref" >/dev/null
      ;;
  esac
}

# Apply an additional tag <dst_ref> to an existing image <src_ref>.
#
# Tags are applied POST-build only, never as extra build-time `--tag` flags:
# apple/container's peer-fallback build path (docker/podman build -> save ->
# `container image load`) silently drops extra build-time tags, so additional
# names (e.g. per-project dce-<project>:latest aliases) must be attached after
# the canonical image already exists in the backend's store. The backend CLI's
# exit code propagates; callers surface failures.
backend_tag_image() {
  local src_ref="$1"
  local dst_ref="$2"

  case "$(backend_name)" in
    apple)
      container image tag "$src_ref" "$dst_ref"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" tag "$src_ref" "$dst_ref"
      ;;
  esac
}

# List volume names (one per line). apple/container may emit JSON, hence parsing.
backend_list_volumes() {
  local backend=""
  backend="$(backend_name)" || return 1

  case "$backend" in
    apple)
      if container volume list --format json >/dev/null 2>&1; then
        container volume list --format json 2>/dev/null | awk -F'"' '/"name"[[:space:]]*:/ {print $4}'
      elif container volume ls --format '{{.Name}}' >/dev/null 2>&1; then
        container volume ls --format '{{.Name}}' 2>/dev/null
      else
        container volume list 2>/dev/null | awk 'NR > 1 {print $1}'
      fi
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" volume ls --format '{{.Name}}' 2>/dev/null
      ;;
  esac
}

# Remove a named volume (silently succeeds if already absent).
backend_remove_volume() {
  local volume_name="$1"

  case "$(backend_name)" in
    apple)
      if container volume delete "$volume_name" >/dev/null 2>&1; then
        return 0
      fi
      container volume rm "$volume_name" >/dev/null 2>&1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" volume rm "$volume_name" >/dev/null 2>&1
      ;;
  esac
}

# Copy the full contents of <src_volume> into <dst_volume>, preserving
# ownership and permissions. Used by `dce snapshot --include-volumes` to clone a
# hidden volume into a snapshot-specific volume isolated from the live original.
#
# Safety contract:
#   - The SOURCE is mounted READ-ONLY. The copy helper runs as root (uid 0) to
#     read every file; a read-only source makes it structurally impossible for a
#     copy-recipe bug to corrupt the LIVE volume a normal rebuild depends on.
#     "The source container is stopped" only blocks app writes, not helper
#     writes, so RO is the meaningful guarantee.
#   - The helper image is dce-base:latest (guaranteed present when a dce project
#     exists; ships tar/coreutils). The recipe is a pure-reader tar pipe; tar -p
#     preserves dev:dev (and any root:root) ownership, so no re-chown is needed.
#   - Named volumes are auto-created on reference, so <dst_volume> exists after
#     this call even on failure (as an empty volume) -- the desired degraded
#     state when a copy fails.
#
# Returns the helper's exit code (non-zero on copy failure). apple/container has
# no native volume-to-volume copy (`container cp` is container<->host only), so
# every backend uses the same temp-container recipe; only the mount flag differs
# (apple's `-v` documents no `:ro` suffix, so `--mount ... readonly` is used).
backend_volume_copy() {
  local src="$1"
  local dst="$2"

  local backend=""
  backend="$(backend_name)" || return 1

  local recipe='tar -C /from -cf - . | tar -C /to -xf -'

  case "$backend" in
    docker|orbstack|colima|podman)
      "$(backend_cli)" run --rm -u 0 \
        -v "$src":/from:ro -v "$dst":/to \
        dce-base:latest sh -c "$recipe" >/dev/null
      ;;
    apple)
      container run --rm --uid 0 \
        --mount type=volume,source="$src",target=/from,readonly \
        --mount type=volume,source="$dst",target=/to \
        dce-base:latest sh -c "$recipe" >/dev/null
      ;;
  esac
}

# List running containers (raw backend output).
backend_list_running() {
  case "$(backend_name)" in
    apple)
      # apple/container has no `ps` subcommand; the alias is `ls` (a.k.a `list`).
      container ls
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" ps
      ;;
  esac
}

# List all containers including stopped (raw backend output).
backend_list_all() {
  case "$(backend_name)" in
    apple)
      container ls -a
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" ps -a
      ;;
  esac
}

# Return whether a named container exists (any state).
backend_exists() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      # `ls -a -q` prints one container name per line (running + stopped); the
      # `-q` form avoids depending on the human-readable table column layout.
      _backend_list_contains "$name" container ls -a -q
      ;;
    docker|orbstack|colima|podman)
      _backend_list_contains "$name" "$(backend_cli)" ps -a --format '{{.Names}}'
      ;;
  esac
}

# Return whether a named container is currently running.
backend_is_running() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      _backend_list_contains "$name" container ls -q
      ;;
    docker|orbstack|colima|podman)
      _backend_list_contains "$name" "$(backend_cli)" ps --format '{{.Names}}'
      ;;
  esac
}

# Resolve the {id, image} pair VS Code's experimental apple-container attach URI
# needs, by inspecting the live container. Prints "<id>\t<image>" on stdout.
# Used by `dce editor`'s apple launch path (lib/editor.sh). `id` is what
# `container exec` keys on (the container name); `image` is informational for
# VS Code (shown in the workspace title). Reads both from `container inspect`
# via jq so the URI matches exactly what VS Code's own picker would build; the
# same .configuration.image.reference field is already read this way by the
# apple snapshot path (_backend_apple_container_commit). When jq is unavailable
# or inspect fails, falls back to (name, fallback_image) so the launch still
# proceeds -- the attach keys on `id`, which is always the container name.
backend_apple_attach_ref() {
  local name="$1"
  local fallback_image="${2:-}"

  local raw=""
  raw="$(container inspect "$name" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && command -v jq >/dev/null 2>&1; then
    local id="" image=""
    id="$(printf '%s' "$raw" | jq -r '.[0].configuration.id // empty' 2>/dev/null || true)"
    image="$(printf '%s' "$raw" | jq -r '.[0].configuration.image.reference // empty' 2>/dev/null || true)"
    if [[ -n "$id" && -n "$image" ]]; then
      printf '%s\t%s\n' "$id" "$image"
      return 0
    fi
  fi

  [[ -n "$fallback_image" ]] || fallback_image="(unknown)"
  printf '%s\t%s\n' "$name" "$fallback_image"
}

# Resolve the DNS nameserver IPs to pass to a container at create time (--dns).
# Prints one IP per line on stdout (empty output = pass no --dns). Semantics:
#   - $DCE_DNS overrides on every backend (comma- or space-separated). An empty
#     value (variable set but empty) opts out entirely.
#   - Otherwise the apple/container backend defaults to public resolvers, because
#     apple/container's auto-configured resolver (the vmnet gateway, e.g.
#     192.168.64.1) does not forward external DNS -- containers can reach IPs but
#     not resolve hostnames, breaking extension install / git over https / npm.
#   - Docker-compatible backends default to none: their embedded DNS resolver
#     (e.g. 127.0.0.11) already resolves correctly.
backend_dns_servers() {
  local backend="${1:-}"

  if [[ -v DCE_DNS ]]; then
    local raw="${DCE_DNS//,/ }"
    # shellcheck disable=SC2206  # word-split DCE_DNS tokens (IPs have no spaces) by design
    local -a parts=($raw)
    local s
    for s in "${parts[@]}"; do
      [[ -n "$s" ]] && printf '%s\n' "$s"
    done
    return 0
  fi

  if [[ "$backend" == "apple" ]]; then
    printf '%s\n' 1.1.1.1 8.8.8.8
  fi
}

# Create a container from an image with the given create flags.
#
# For Podman we add a host.docker.internal=host-gateway alias when supported,
# so containers can reach the host by the same name as Docker backends; older
# Podman gets a one-time warning to use host.containers.internal instead.
backend_create() {
  local name="$1"
  local image="$2"
  shift 2

  local backend=""
  backend="$(backend_name)" || return 1

  local -a create_args=("$@")
  if [[ "$backend" == "podman" ]]; then
    if _backend_podman_supports_host_gateway; then
      create_args+=(--add-host "host.docker.internal=host-gateway")
    elif [[ "$_DC_PODMAN_HOST_GATEWAY_WARNED" -eq 0 ]]; then
      dce_warn "Podman host-gateway alias is unavailable; use host.containers.internal inside containers."
      _DC_PODMAN_HOST_GATEWAY_WARNED=1
    fi
  fi

  # DNS nameservers (apple defaults to public resolvers; DCE_DNS overrides on
  # every backend). --dns is accepted by `container create` and `docker create`.
  local dns_servers=""
  dns_servers="$(backend_dns_servers "$backend")"
  if [[ -n "$dns_servers" ]]; then
    local d
    while IFS= read -r d; do
      [[ -n "$d" ]] && create_args+=(--dns "$d")
    done <<< "$dns_servers"
  fi

  case "$backend" in
    apple)
      container create --name "$name" "${create_args[@]}" "$image"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" create --name "$name" "${create_args[@]}" "$image" >/dev/null
      ;;
  esac
}

# apple/container has no `commit` and no image `import`, so a commit is composed
# from `export` (flat merged FS tar, volumes excluded) + `build FROM scratch ADD`.
# `FROM scratch` discards image config, so base-image metadata (USER, WORKDIR,
# ENV, CMD, ENTRYPOINT) is read from the container's current image via
# `container image inspect` and re-emitted. USER re-application is mandatory:
# after a restore, credential injection writes ~/.ssh as the dev user, so a
# snapshot that defaulted to root would break the dev user. The caller must
# ensure the container is stopped first (export requires a stopped container).
_backend_apple_container_commit() {
  local container_name="$1"
  local image_tag="$2"
  shift 2
  local -a label_kv=("$@")

  # Read the source image's config so the FROM-scratch snapshot can re-apply
  # USER/WORKDIR/ENV/CMD/ENTRYPOINT -- without them the restored container has
  # no command and `container create` fails ("command/entrypoint not specified").
  # apple/container's inspect has no Go-template --format, so the config is read
  # from JSON via jq. jq is optional elsewhere in dce; without it the snapshot is
  # bare (metadata lost) and restore will fail.
  local image_ref="" cfg_user="" cfg_workdir="" cfg_env="" cfg_cmd="" cfg_entrypoint=""
  if command -v jq >/dev/null 2>&1; then
    image_ref="$(container inspect "$container_name" 2>/dev/null \
      | jq -r '.[0].configuration.image.reference // empty')"
    if [[ -n "$image_ref" ]]; then
      local img_json
      img_json="$(container image inspect "$image_ref" 2>/dev/null || true)"
      if [[ -n "$img_json" ]]; then
        # .config.config is the OCI config object; arrays emit empty when
        # null/[] so CMD/ENTRYPOINT are omitted rather than printed as [].
        cfg_user="$(printf '%s' "$img_json" | jq -r '.[0].variants[0].config.config.user // empty')"
        cfg_workdir="$(printf '%s' "$img_json" | jq -r '.[0].variants[0].config.config.WorkingDir // empty')"
        cfg_env="$(printf '%s' "$img_json" | jq -r '.[0].variants[0].config.config.Env[]?')"
        # Arrays: emit the JSON form only when non-empty so CMD/ENTRYPOINT are
        # omitted (not printed as []) when the source image has none.
        cfg_cmd="$(printf '%s' "$img_json" | jq -rc '(.[0].variants[0].config.config.Cmd // []) | if length > 0 then . else empty end')"
        cfg_entrypoint="$(printf '%s' "$img_json" | jq -rc '(.[0].variants[0].config.config.Entrypoint // []) | if length > 0 then . else empty end')"
      fi
    fi
  else
    dce_warn "apple snapshots require jq to copy image config; '$container_name' snapshot will lack USER/CMD/ENTRYPOINT and may fail to restore."
  fi

  local work_dir=""
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/dce-snap.XXXXXX")" || {
    echo "ERROR: could not create a temp dir for the apple snapshot build." >&2
    return 1
  }
  # Normalize: $TMPDIR ends with "/", so the raw path contains "//" which
  # apple/container's builder rejects with "X is not a child of Y" when it is
  # passed as the build context. cd -P resolves the "//" and the /var symlink.
  work_dir="$(cd -P "$work_dir" && pwd)"
  local tar_file="$work_dir/rootfs.tar"
  local cfile="$work_dir/Containerfile"

  if ! container export -o "$tar_file" "$container_name" >/dev/null 2>&1; then
    rm -rf "$work_dir"
    echo "ERROR: apple/container export failed for '$container_name'." >&2
    echo "       Ensure the container is stopped before snapshotting." >&2
    return 1
  fi

  {
    printf 'FROM scratch\n'
    printf 'ADD rootfs.tar /\n'
    [[ -n "$cfg_user" ]] && printf 'USER %s\n' "$cfg_user"
    [[ -n "$cfg_workdir" ]] && printf 'WORKDIR %s\n' "$cfg_workdir"
    if [[ -n "$cfg_env" ]]; then
      local env_line=""
      while IFS= read -r env_line; do
        [[ -n "$env_line" ]] && printf 'ENV %s\n' "$env_line"
      done <<< "$cfg_env"
    fi
    # cfg_cmd / cfg_entrypoint are already JSON exec-form arrays (["a","b"]).
    [[ -n "$cfg_cmd" ]] && printf 'CMD %s\n' "$cfg_cmd"
    [[ -n "$cfg_entrypoint" ]] && printf 'ENTRYPOINT %s\n' "$cfg_entrypoint"
    if [[ ${#label_kv[@]} -gt 0 ]]; then
      local kv=""
      printf 'LABEL'
      for kv in "${label_kv[@]}"; do
        [[ -n "$kv" ]] && printf ' %s' "$kv"
      done
      printf '\n'
    fi
  } > "$cfile"

  # Route through backend_build_image so the snapshot build gets the same
  # peer-backend fallback as dce-base when apple's native builder can't complete
  # it in the current environment (no build-context transfer). Native is tried
  # first; the FROM-scratch+ADD build only falls back if context transfer fails.
  if ! backend_build_image "$image_tag" "$cfile" "$work_dir" >/dev/null 2>&1; then
    rm -rf "$work_dir"
    echo "ERROR: apple/container build failed for snapshot '$image_tag'." >&2
    return 1
  fi

  rm -rf "$work_dir"
}

# Commit a container's filesystem to <image_tag> as a new image. Captures the
# image + writable layer only (never named volumes or the bind-mounted repo),
# matching `export` semantics. Optional label_kv pairs ("key=value") are stamped
# as OCI image labels for snapshot provenance. The caller MUST ensure the
# container is stopped first: a clean commit (and apple's export) require it.
#
# docker/orbstack/colima/podman use native `<cli> commit`, which carries USER,
# ENV, WORKDIR, CMD, ENTRYPOINT, and existing labels forward automatically.
# apple/container has no commit/import, so it composes export + FROM-scratch
# build and re-applies base metadata (see _backend_apple_container_commit).
backend_container_commit() {
  local container_name="$1"
  local image_tag="$2"
  shift 2
  local -a label_kv=("$@")

  local backend=""
  backend="$(backend_name)" || return 1

  case "$backend" in
    docker|orbstack|colima|podman)
      local -a args=("commit")
      local kv=""
      for kv in "${label_kv[@]:-}"; do
        [[ -n "$kv" ]] || continue
        args+=(--change "LABEL $kv")
      done
      args+=("$container_name" "$image_tag")
      "$(backend_cli)" "${args[@]}" >/dev/null
      ;;
    apple)
      _backend_apple_container_commit "$container_name" "$image_tag" "${label_kv[@]:-}"
      ;;
  esac
}

# Start an existing container.
backend_start() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container start "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" start "$name" >/dev/null
      ;;
  esac
}

# Stop a running container.
backend_stop() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container stop "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" stop "$name" >/dev/null
      ;;
  esac
}

# Fetch a container's stdout/stderr log stream.
#
# Structured args keep the user-facing shape uniform: follow=true attaches
# (-f, blocks until interrupted); tail (empty or integer N) limits output to
# the last N lines. The follow flag (-f) is identical on every backend; the
# tail flag is NOT -- docker/orbstack/colima/podman take `--tail N`, while
# apple/container has no `--tail` and exposes line count as `-n N` -- so the
# flag is translated per backend to keep `dce logs --tail` working everywhere.
backend_logs() {
  local name="$1"
  local follow="$2"
  local tail="${3:-}"

  local backend=""
  backend="$(backend_name)" || return 1

  local -a log_args=()
  if [[ "$follow" == "true" ]]; then
    log_args+=("-f")
  fi
  if [[ -n "$tail" ]]; then
    if [[ "$backend" == "apple" ]]; then
      log_args+=("-n" "$tail")
    else
      log_args+=("--tail" "$tail")
    fi
  fi

  case "$backend" in
    apple)
      container logs "${log_args[@]}" "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" logs "${log_args[@]}" "$name"
      ;;
  esac
}

# Delete a container (force-remove for Docker CLIs).
backend_delete() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container delete "$name"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" rm -f "$name" >/dev/null
      ;;
  esac
}

# Run a command in a container as the dev user (non-interactive, no TTY).
backend_exec() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec "$name" "$@"
      ;;
  esac
}

# Run a command in a container as root (uid 0). Used for setup that the dev
# user can't do, e.g. chown of hidden-volume mount points.
backend_exec_as_root() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec --uid 0 "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -u 0 "$name" "$@"
      ;;
  esac
}

# Run a command in a container with stdin attached (no TTY). Used to stream
# data into the container, e.g. piping a host file or tar into the container.
backend_exec_stdin() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec -i "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -i "$name" "$@"
      ;;
  esac
}

# Run a command in a container as root (uid 0) with stdin attached (no TTY).
# Used to stream data into the container with root permissions, e.g. staging a
# hosts fragment at /tmp before an /etc/hosts reconcile -- system files the dev
# user cannot write directly.
backend_exec_stdin_as_root() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container exec -i --uid 0 "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -i -u 0 "$name" "$@"
      ;;
  esac
}

# Open an interactive (TTY) session in a container as dev.
#
# Args before a literal "--" are passed as exec options (e.g. --env KEY=VAL);
# everything after "--" is the command to run. This lets callers inject env
# vars without colliding with the exec option namespace.
backend_exec_interactive() {
  local name="$1"
  shift

  local -a exec_args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      shift
      break
    fi
    exec_args+=("$1")
    shift
  done

  local -a command=("$@")

  case "$(backend_name)" in
    apple)
      container exec -it "${exec_args[@]}" "$name" "${command[@]}"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" exec -it "${exec_args[@]}" "$name" "${command[@]}"
      ;;
  esac
}

# =============================================================================
# Network management. User-defined networks are first-class objects on both
# backend families: docker/orbstack/colima/podman via the Docker CLI, and
# apple/container via `container network` (macOS 26+). The CLI shapes diverge
# (apple uses `delete` not `rm`; apple resolves peers as `<name>.test`; apple
# cannot live-attach a network to an existing container), so every divergence
# is pinned in tests/contract/backend-dispatch.sh.
# =============================================================================

# Create a user-defined network. Extra args (e.g. --subnet <cidr>) are appended
# after the name, matching apple/container's documented form and docker's lenient
# ordering. Idempotent callers should check backend_network_exists first.
backend_network_create() {
  local name="$1"
  shift

  case "$(backend_name)" in
    apple)
      container network create "$name" "$@"
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network create "$name" "$@" >/dev/null
      ;;
  esac
}

# List user-defined network names, one per line. docker emits names directly via
# --format; apple prints a columned table (NETWORK/STATE/SUBNET) whose header is
# skipped only when the first field is literally "NETWORK" (robust to reordering).
backend_network_list() {
  case "$(backend_name)" in
    apple)
      container network list 2>/dev/null \
        | awk 'NR==1 && $1=="NETWORK" {next} NF {print $1}'
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network ls --format '{{.Name}}' 2>/dev/null
      ;;
  esac
}

# Return 0 if a named network exists on the active backend, 1 if absent.
# Returns 2 if the underlying list call itself failed.
backend_network_exists() {
  local name="$1"
  local listed=""

  if ! listed="$(backend_network_list 2>/dev/null)"; then
    return 2
  fi

  local n=""
  while IFS= read -r n; do
    [[ "$n" == "$name" ]] && return 0
  done <<< "$listed"

  return 1
}

# Remove a user-defined network (silently succeeds if already absent on docker).
backend_network_rm() {
  local name="$1"

  case "$(backend_name)" in
    apple)
      container network delete "$name" >/dev/null 2>&1 || true
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network rm "$name" >/dev/null 2>&1 || true
      ;;
  esac
}

# Live-attach an existing container to a network. Extra args (e.g. --ip <addr>)
# are Docker connect options and precede NETWORK CONTAINER per docker syntax.
# apple/container sets networks only at create time, so live-attach is refused.
backend_network_connect() {
  local name="$1"
  local container="$2"
  shift 2

  case "$(backend_name)" in
    apple)
      echo "ERROR: apple/container cannot live-attach a network to an existing container." >&2
      echo "       Re-create with: dce rebuild-container $container (after adding the network to its config)." >&2
      return 1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network connect "$@" "$name" "$container" >/dev/null
      ;;
  esac
}

# Detach a container from a network. Unsupported on apple/container (see connect).
backend_network_disconnect() {
  local name="$1"
  local container="$2"

  case "$(backend_name)" in
    apple)
      echo "ERROR: apple/container cannot detach a network from an existing container." >&2
      return 1
      ;;
    docker|orbstack|colima|podman)
      "$(backend_cli)" network disconnect "$name" "$container" >/dev/null 2>&1 || true
      ;;
  esac
}
