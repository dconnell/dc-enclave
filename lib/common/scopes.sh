#!/usr/bin/env bash
# =============================================================================
# lib/common/scopes.sh - Overlay scope + derived image-ref resolution.
#
# Sourced (never executed directly) via lib/common.sh. Implements the overlay
# layering contract: requested named scopes must exist in the team or user
# overlays dir (missing ones fail fast), "all" is never taken from the request
# but auto-prepended when a Containerfile.all exists, and the resulting order
# drives both overlay composition and the deterministic image-tag derivation
# (dce_image_ref_from_scopes / dce_image_hash_from_ref). Depends on core.sh
# (dce_join_by, dce_sha256_hex).
# =============================================================================

if [[ -n "${_DC_COMMON_SCOPES_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_SCOPES_SH_LOADED=1

dce_validate_scope_name() {
  local scope="$1"
  [[ "$scope" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

# Normalize a comma-separated scope list: trim/lowercase each token, drop
# empties, reject invalid names, and de-duplicate while preserving order.
dce_normalize_scopes_csv() {
  local input="$1"

  local -a normalized=()
  local -a raw_scopes=()
  declare -A seen=()
  local raw_scope=""
  local scope=""

  IFS=',' read -r -a raw_scopes <<< "$input"
  for raw_scope in "${raw_scopes[@]}"; do
    scope="${raw_scope//[[:space:]]/}"
    scope="${scope,,}"
    [[ -z "$scope" ]] && continue

    if ! dce_validate_scope_name "$scope"; then
      printf 'ERROR: Invalid scope name: %s\n' "$scope" >&2
      printf '  Allowed pattern: ^[a-z0-9][a-z0-9._-]*$\n' >&2
      return 1
    fi

    if [[ -n "${seen[$scope]-}" ]]; then
      continue
    fi

    seen["$scope"]=1
    normalized+=("$scope")
  done

  dce_join_by ',' "${normalized[@]}"
}

# Return whether an overlay scope exists in either team or user overlays dir.
# Each dir is the resolved leaf overlays/ directory of a root (see
# dce_team_overlays_dir / dce_user_overlays_dir).
dce_scope_exists() {
  local team_od="$1"
  local user_od="$2"
  local scope="$3"

  [[ -f "$team_od/Containerfile.$scope" || -f "$user_od/Containerfile.$scope" ]]
}

# Resolve the final, effective scope list for a create/rebuild.
#
# Implements the layering contract: requested named scopes must exist in the
# team or user overlays dir (missing ones fail fast), "all" is never taken from
# the request but auto-prepended when a Containerfile.all exists. The resulting
# order drives overlay composition and image-tag derivation.
dce_effective_scopes_csv() {
  local team_od="$1"
  local user_od="$2"
  local requested_scopes_csv="$3"

  local normalized_csv=""
  if ! normalized_csv="$(dce_normalize_scopes_csv "$requested_scopes_csv")"; then
    return 1
  fi

  local -a requested=()
  local -a selected=()
  local -a missing=()
  local -a effective=()
  local scope=""

  IFS=',' read -r -a requested <<< "$normalized_csv"
  for scope in "${requested[@]}"; do
    [[ -z "$scope" ]] && continue
    [[ "$scope" == "all" ]] && continue

    if dce_scope_exists "$team_od" "$user_od" "$scope"; then
      selected+=("$scope")
    else
      missing+=("$scope")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'ERROR: Missing overlay scope(s): %s\n' "$(dce_join_by ', ' "${missing[@]}")" >&2
    printf '  Add Containerfile.<scope> under %s or %s\n' "$team_od" "$user_od" >&2
    return 1
  fi

  if dce_scope_exists "$team_od" "$user_od" "all"; then
    effective+=("all")
  fi

  effective+=("${selected[@]}")

  dce_join_by ',' "${effective[@]}"
}

# Derive the deterministic image tag for a scope set.
#
# No overlays -> dce-base:latest (the shared base). Otherwise the effective
# scopes are hashed into dce-img-<16hex>:latest so identical scope sets always
# resolve to one reusable, shareable derived image across projects/machines.
dce_image_ref_from_scopes() {
  local team_od="$1"
  local user_od="$2"
  local requested_scopes_csv="$3"

  local effective_scopes_csv=""
  if ! effective_scopes_csv="$(dce_effective_scopes_csv "$team_od" "$user_od" "$requested_scopes_csv")"; then
    return 1
  fi

  if [[ -z "$effective_scopes_csv" ]]; then
    printf 'dce-base:latest\n'
    return 0
  fi

  local -a scopes=()
  local scope=""
  local scope_key="v1"

  IFS=',' read -r -a scopes <<< "$effective_scopes_csv"
  for scope in "${scopes[@]}"; do
    [[ -z "$scope" ]] && continue
    scope_key+="|${#scope}:$scope"
  done

  local hash=""
  hash="$(dce_sha256_hex "$scope_key")"
  hash="${hash:0:16}"

  printf 'dce-img-%s:latest\n' "$hash"
}

# Extract the 16-hex hash from a dce-img-* reference, or fail for other refs.
dce_image_hash_from_ref() {
  local image_ref="$1"
  local repo="${image_ref%%:*}"

  if [[ "$repo" =~ ^dce-img-([0-9a-f]{16})$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}
