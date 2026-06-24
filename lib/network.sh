#!/usr/bin/env bash
# =============================================================================
# lib/network.sh - Private-network orchestration for dce-managed containers.
#
# Sourced (never executed) by scripts that create/rebuild containers and by the
# `dce network` subcommand. Sits on top of lib/common.sh (pure validators + the
# hardened config loader) and lib/container-backend.sh (the backend_network_*
# dispatch). All per-CLI divergence lives there; this file is backend-aware but
# CLI-agnostic.
#
# Model (see plans/internal-networking.md):
#   - Networks are first-class daemon objects; existence is the source of truth.
#     dce stores NO subnet bookkeeping -- both backend families auto-allocate and
#     validate overlap natively.
#   - Per-container membership lives in the project config as
#     CONTAINER_NETWORKS=( <name>[:<ip>] ... ), alongside everything else.
#   - Linking is explicit: the primary network is attached at create time
#     (`--network`/`--ip`); additional networks are live-connected after create.
#   - Static IPs are opt-in (default is peer-by-name DNS). apple/container has
#     neither static IPs nor live-attach, so it is restricted to a single network
#     attached at create (peer name resolves as `<name>.test` there).
# =============================================================================

# Auto-source the two libs this file depends on, so sourcing network.sh alone is
# enough (mirrors how container-backend.sh auto-sources common.sh).
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_network_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=common.sh
  source "$_dce_network_lib_dir/common.sh"
  unset _dce_network_lib_dir
fi
if [[ -z "${_DC_BACKEND_SH_LOADED:-}" ]]; then
  _dce_network_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=container-backend.sh
  source "$_dce_network_lib_dir/container-backend.sh"
  unset _dce_network_lib_dir
fi

if [[ -n "${_DC_NETWORK_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_NETWORK_SH_LOADED=1

# Normalize a `--network` flag value (a comma-separated list of `name` or
# `name:ip` tokens) into a canonical CSV of `name[:ip]` entries. Lowercases names
# (friendly, matches scope handling), drops empties, validates each name + IP,
# and de-duplicates by name (first occurrence wins; a conflicting IP for an
# already-seen name is an error). Echoes the CSV (possibly empty); returns 1 on
# any invalid token.
dce_normalize_network_arg() {
  local input="$1"

  if [[ -z "${input//[[:space:]]/}" ]]; then
    printf ''
    return 0
  fi

  local -a raw_tokens=()
  local -a normalized=()
  declare -A seen_ip=()
  local raw="" token="" name="" ip="" existing=""

  IFS=',' read -r -a raw_tokens <<< "$input"
  for raw in "${raw_tokens[@]}"; do
    token="${raw//"$(printf '\t')"/}"
    # trim leading/trailing whitespace
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -z "$token" ]] && continue

    if [[ "$token" == *:* ]]; then
      name="${token%%:*}"
      ip="${token#*:}"
    else
      name="$token"
      ip=""
    fi

    # Tolerate incidental whitespace around either part (e.g. "myapp : 10.0.0.4").
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    ip="${ip#"${ip%%[![:space:]]*}"}"
    ip="${ip%"${ip##*[![:space:]]}"}"

    # A second colon (e.g. "a:b:c") means a malformed entry; dce_validate_ip_value
    # rejects any residual whitespace/format below.
    if [[ "$ip" == *:* ]]; then
      printf 'ERROR: Invalid network entry %q (bad IP field).\n' "$token" >&2
      return 1
    fi

    name="${name,,}"

    if ! dce_validate_network_name "$name"; then
      printf 'ERROR: Invalid network name: %s\n' "$name" >&2
      printf '  Allowed pattern: ^[a-z0-9][a-z0-9._-]*$\n' >&2
      return 1
    fi

    if [[ -n "$ip" ]]; then
      if ! dce_validate_ip_value "$ip" >&2; then
        return 1
      fi
    fi

    if [[ -n "${seen_ip[$name]+x}" ]]; then
      existing="${seen_ip[$name]}"
      if [[ "$existing" != "${ip:-}" ]]; then
        printf 'ERROR: Network %q listed with conflicting IPs (%s vs %s).\n' "$name" "$existing" "${ip:-<none>}" >&2
        return 1
      fi
      continue
    fi
    seen_ip["$name"]="${ip:-}"

    if [[ -n "$ip" ]]; then
      normalized+=("$name:$ip")
    else
      normalized+=("$name")
    fi
  done

  dce_join_by ',' "${normalized[@]}"
}

# Extract the network name from a `name[:ip]` entry.
dce_network_entry_name() {
  local entry="$1"
  if [[ "$entry" == *:* ]]; then
    printf '%s' "${entry%%:*}"
  else
    printf '%s' "$entry"
  fi
}

# Extract the static IP from a `name[:ip]` entry (empty if none).
dce_network_entry_ip() {
  local entry="$1"
  if [[ "$entry" == *:* ]]; then
    printf '%s' "${entry#*:}"
  else
    printf ''
  fi
}

# Enforce backend-specific limits on the requested network set. apple/container
# supports a single network per container (attached at create) and has no static
# IP assignment, so reject extra networks and any IP. Docker-compatible backends
# are unrestricted here. Returns 0/1.
dce_network_check_backend_limits() {
  local backend="$1"
  shift
  local -a entries=("$@")
  local entry=""

  if [[ "$backend" != "apple" ]]; then
    return 0
  fi

  if [[ ${#entries[@]} -gt 1 ]]; then
    echo "ERROR: apple/container supports a single network per container; got ${#entries[@]}." >&2
    echo "       Reduce to one network, or use a Docker-compatible backend (docker/orbstack/colima/podman)." >&2
    return 1
  fi

  for entry in "${entries[@]}"; do
    [[ -z "$entry" ]] && continue
    if [[ -n "$(dce_network_entry_ip "$entry")" ]]; then
      echo "ERROR: apple/container does not support static container IPs." >&2
      echo "       Drop --ip / the ':ip' suffix, or use a Docker-compatible backend." >&2
      return 1
    fi
  done

  return 0
}

# Ensure every referenced network exists on the active backend. A missing
# network fails fast with create guidance rather than silently auto-creating it
# (networks are first-class objects created via `dce network create`). Returns 0
# if all exist, 1 if any is missing or the list call failed.
dce_networks_ensure_exist() {
  local -a entries=("$@")
  local entry="" name="" rc=0

  for entry in "${entries[@]}"; do
    [[ -z "$entry" ]] && continue
    name="$(dce_network_entry_name "$entry")"
    if ! backend_network_exists "$name"; then
      rc=$?
      if [[ "$rc" -eq 2 ]]; then
        printf 'ERROR: Could not verify network %q on the backend.\n' "$name" >&2
      else
        printf 'ERROR: Network %q does not exist on backend %q.\n' "$name" "${DEV_CONTAINERS_BACKEND:-?}" >&2
        printf '       Create it first: dce network create %s\n' "$name" >&2
      fi
      return 1
    fi
  done

  return 0
}

# Emit the create-time network args for the active backend, one arg per line
# (caller captures with `mapfile -t arr < <(...)`). The PRIMARY (first) entry is
# attached at create; extras are handled by dce_networks_attach_extras. On apple
# the single network is attached with no IP. Emits nothing when there are no
# networks.
dce_networks_create_args() {
  local -a entries=("$@")
  local backend="${DEV_CONTAINERS_BACKEND:-}"

  [[ ${#entries[@]} -eq 0 ]] && return 0

  local primary="${entries[0]}"
  local primary_name="" primary_ip=""
  primary_name="$(dce_network_entry_name "$primary")"
  primary_ip="$(dce_network_entry_ip "$primary")"

  if [[ "$backend" == "apple" ]]; then
    printf '%s\n%s\n' "--network" "$primary_name"
    return 0
  fi

  printf '%s\n%s\n' "--network" "$primary_name"
  if [[ -n "$primary_ip" ]]; then
    printf '%s\n%s\n' "--ip" "$primary_ip"
  fi
}

# After create: live-connect every network beyond the primary (Docker-only; on
# apple the limits check already rejected extras). Returns 0 if all connects
# succeed, 1 otherwise.
dce_networks_attach_extras() {
  local project="$1"
  shift
  local -a entries=("$@")
  local backend="${DEV_CONTAINERS_BACKEND:-}"

  [[ "$backend" == "apple" ]] && return 0
  [[ ${#entries[@]} -le 1 ]] && return 0

  local i="" entry="" name="" ip=""
  for ((i = 1; i < ${#entries[@]}; i++)); do
    entry="${entries[$i]}"
    [[ -z "$entry" ]] && continue
    name="$(dce_network_entry_name "$entry")"
    ip="$(dce_network_entry_ip "$entry")"
    if [[ -n "$ip" ]]; then
      if ! backend_network_connect "$name" "$project" --ip "$ip"; then
        printf 'ERROR: Failed to attach container %q to network %q.\n' "$project" "$name" >&2
        return 1
      fi
    else
      if ! backend_network_connect "$name" "$project"; then
        printf 'ERROR: Failed to attach container %q to network %q.\n' "$project" "$name" >&2
        return 1
      fi
    fi
  done

  return 0
}

# Scan every project config and emit one line per (project, network) membership:
# "<project>\t<network>\t<ip>" (ip is "-" when none). Each project loads through
# the hardened loader inside a subshell so a single bad config cannot abort the
# scan. Used by `dce network ls` / `dce network members`.
dce_network_scan_membership() {
  local base="$HOME/.config/dce-enclave"
  local config_file="" project="" line="" ip=""

  [[ -d "$base" ]] || return 0

  for config_file in "$base"/*/config; do
    [[ -f "$config_file" ]] || continue
    project="$(basename "$(dirname "$config_file")")"
    # Subshell isolates a failing load and scopes the sourced globals.
    while IFS=$'\t' read -r net nip; do
      [[ -z "$net" ]] && continue
      printf '%s\t%s\t%s\n' "$project" "$net" "${nip:--}"
    done < <(
      PORTS=()
      CONTAINER_HIDDEN_PATHS=()
      CONTAINER_NETWORKS=()
      if dce_load_project_config "$config_file" 2>/dev/null; then
        # NOTE: this runs in a process-substitution subshell, not a function, so
        # `local` is unavailable; plain assignments are correctly scoped here.
        for _scan_e in "${CONTAINER_NETWORKS[@]}"; do
          [[ -z "$_scan_e" ]] && continue
          _scan_n="${_scan_e%%:*}"
          _scan_p=""
          [[ "$_scan_e" == *:* ]] && _scan_p="${_scan_e#*:}"
          printf '%s\t%s\n' "$_scan_n" "$_scan_p"
        done
      fi
    )
  done
}

# Print membership for a single network: "<project>\t<ip>" lines (ip "-" if none).
dce_network_members_of() {
  local name="$1"
  local p net ip

  while IFS=$'\t' read -r p net ip; do
    [[ "$net" == "$name" ]] || continue
    printf '%s\t%s\n' "$p" "$ip"
  done < <(dce_network_scan_membership)
}

# Print the list of project names currently referencing a network (space-sep),
# for the `dce network rm` membership guard. Returns 0 always; empty if none.
dce_network_referencing_projects() {
  local name="$1"
  local -a out=()
  local p net ip

  while IFS=$'\t' read -r p net ip; do
    [[ "$net" == "$name" ]] || continue
    out+=("$p")
  done < <(dce_network_scan_membership)

  printf '%s' "${out[*]}"
}
