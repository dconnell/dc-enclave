#!/usr/bin/env bash
# =============================================================================
# lib/backends/apple.sh - apple/container backend logic.
#
# Sourced (never executed directly) via lib/container-backend.sh. Holds all
# apple/container-specific logic: the host-integration version gate and DNS
# probes, the native-build block classifier, the peer-build fallback chain
# (its docker/podman arms reach into the peer CLIs by design, not shared
# plumbing), the chained part-file build, and the export+FROM-scratch commit.
#
# Cross-file calls (dce_warn/dce_die and the _DCE_HOSTS_GATEWAY_* constants
# from common.sh; backend_name, backend_build_image, backend_image_exists and
# the _DC_APPLE_BLOCK_CLASS global from the facade) resolve at invocation time
# via the facade and its sibling modules; nothing is auto-sourced here. The
# readonly _DC_APPLE_HOST_INTEGRATION_MIN_VERSION declared below is likewise
# consumed cross-file by scripts/doctor.sh and scripts/help.sh.
# =============================================================================

# Include guard: sourcing this module directly is a safe no-op on re-source.
if [[ -n "${_DC_BACKENDS_APPLE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_BACKENDS_APPLE_SH_LOADED=1

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
#
# This floor is part of the module's sourced contract, NOT apple.sh-private:
# besides backend_apple_version_supported below, it is read at invocation time
# by scripts/doctor.sh and scripts/help.sh (resolved through the facade after
# container-backend.sh sources this module).
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
