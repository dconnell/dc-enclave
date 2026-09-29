#!/usr/bin/env bash
# =============================================================================
# lib/common/workspace.sh - Schema-v2 repo layout + mount planning.
#
# Single source of truth for the runtime shape of a schema-v2 project, shared
# by scripts/new-container.sh and scripts/rebuild-container.sh so the create
# and rebuild mount argv can never drift:
#
#   /workspace                      project root (NOT a bind mount)
#   /workspace/<repo-name>          one read-write bind per repo
#   /workspace/.cache               dce-managed persistent cache volume
#   /workspace/<hidden-path>        one named volume per --hide path
#
# Also owns the managed devcontainer.json location (inside the project config
# dir, never inside a repo) and the single-repo hidden-path shorthand
# (`--hide node_modules` -> `<repo-name>/node_modules`).
#
# Depends on core.sh (dce_project_slug, dce_sha256_hex) and
# hidden-volumes.sh (dce_hidden_volume_name); loaded via lib/common.sh.
# =============================================================================

if [[ -n "${_DC_COMMON_WORKSPACE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_WORKSPACE_SH_LOADED=1

# The dce-managed cache path inside /workspace. Reserved: users cannot claim it
# (or anything under it) as a repo name, repo mount target, or hidden path.
declare -gr _DC_MANAGED_CACHE_PATH=".cache"

# Echo the managed cache path (".cache"), /workspace-relative.
dce_managed_cache_path() {
  printf '%s\n' "$_DC_MANAGED_CACHE_PATH"
}

# Echo the in-container mount target of the managed cache volume.
dce_managed_cache_target() {
  printf '/workspace/%s\n' "$_DC_MANAGED_CACHE_PATH"
}

# Echo the default host repos root (`${DC_REPOS_DIR:-$HOME/repos}`) with a
# leading `~` expanded, but without forcing the path to exist.
dce_default_repos_root() {
  dce_expand_tilde "${DC_REPOS_DIR:-$HOME/repos}"
}

# Echo the canonical in-container target directory for a repo name.
dce_repo_target() {
  local name="$1"
  printf '/workspace/%s\n' "$name"
}

# Parse one repo spec from the new user-facing surfaces. Supported forms:
#   <path>
#   <name>=<path>
# Echoes "<name><TAB><path>" where <name> is empty for the bare-path form.
dce_repo_spec_split() {
  local spec="$1"
  if [[ "$spec" == *=* ]]; then
    printf '%s\t%s\n' "${spec%%=*}" "${spec#*=}"
  else
    printf '\t%s\n' "$spec"
  fi
}

# Derive the default repo name from a host path: trim trailing slashes, then use
# the basename. Callers validate the result with dce_validate_repo_name.
dce_repo_default_name_from_path() {
  local path="$1"
  while [[ "$path" == */ && "$path" != "/" ]]; do
    path="${path%/}"
  done
  basename "$path"
}

# Echo the managed devcontainer.json path for a project: inside the project
# config dir (~/.config/dc-enclave/<project>/), never inside a repo. There is
# no canonical repo root anymore, so editor config lives with the project.
dce_managed_devcontainer_file() {
  local project="$1"
  printf '%s\n' "${HOME}/.config/dc-enclave/${project}/devcontainer.json"
}

# Echo the deterministic managed volume name backing /workspace/.cache.
# Reuses the hidden-volume naming family so snapshot/verify/remove machinery
# treats it like any other managed volume.
dce_cache_volume_name() {
  local project="$1"
  dce_hidden_volume_name "$project" "$_DC_MANAGED_CACHE_PATH"
}

# Echo "<name><TAB><host-path>" lines for the schema-v2 repo set held in the
# REPO_NAMES / REPO_PATHS globals. Tab-separated because both names and paths
# are validated free of control characters, so the separator cannot collide.
dce_repo_entries_lines() {
  local -a names=()
  local -a paths=()
  if declare -p REPO_NAMES >/dev/null 2>&1; then
    names=("${REPO_NAMES[@]}")
  fi
  if declare -p REPO_PATHS >/dev/null 2>&1; then
    paths=("${REPO_PATHS[@]}")
  fi
  local i=0
  for ((i = 0; i < ${#names[@]}; i++)); do
    printf '%s\t%s\n' "${names[i]}" "${paths[i]:-}"
  done
}

# Echo the number of repos in the currently loaded schema-v2 project config.
dce_repo_count() {
  if declare -p REPO_NAMES >/dev/null 2>&1; then
    printf '%s\n' "${#REPO_NAMES[@]}"
  else
    printf '0\n'
  fi
}

# Echo "<name><TAB><host-path>" for the named repo from the currently loaded
# project config. Returns 1 if the repo name is unknown.
dce_repo_entry_by_name() {
  local target_name="$1"
  local line="" name=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%$'\t'*}"
    if [[ "$name" == "$target_name" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(dce_repo_entries_lines)
  return 1
}

# Echo the default shell/interactive workdir for the currently loaded project:
# single-repo projects land in that repo, multi-repo projects land at the
# project root /workspace.
dce_project_default_workdir() {
  local count="0"
  count="$(dce_repo_count)"
  if [[ "$count" == "1" && -n "${REPO_NAMES[0]:-}" ]]; then
    dce_repo_target "${REPO_NAMES[0]}"
  else
    printf '/workspace\n'
  fi
}

# Echo the in-container target path for a named repo in the currently loaded
# project config. Returns 1 if the name is unknown.
dce_project_repo_workdir() {
  local repo_name="$1"
  if dce_repo_entry_by_name "$repo_name" >/dev/null; then
    dce_repo_target "$repo_name"
    return 0
  fi
  return 1
}

# Resolve one repo spec into "<name><TAB><absolute-host-path>". The bare-path
# form derives the repo name from basename(path); the explicit form keeps the
# given name. Relative paths resolve against $PWD after tilde expansion. The
# result is validated with the shared repo-name/path validators.
dce_repo_spec_resolve() {
  local spec="$1"
  local line="" name="" path=""
  line="$(dce_repo_spec_split "$spec")"
  name="${line%%$'\t'*}"
  path="${line#*$'\t'}"

  path="$(dce_expand_tilde "$path")"
  if [[ "$path" != /* ]]; then
    path="$PWD/$path"
  fi

  local resolved=""
  resolved="$(dce_resolve_path "$path")" || return 1
  if [[ -z "$name" ]]; then
    name="$(dce_repo_default_name_from_path "$path")"
  fi

  dce_validate_repo_name "$name" >&2 || return 1
  dce_validate_repo_path "$resolved" >&2 || return 1
  printf '%s\t%s\n' "$name" "$resolved"
}

# Echo the per-repo bind-mount argv words (one "--volume" + one spec pair per
# repo), reading the REPO_NAMES / REPO_PATHS globals. Callers collect with
# mapfile so these compose with the rest of the create/rebuild argv.
dce_repo_mount_args() {
  local line="" name="" path=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    [[ -n "$name" && -n "$path" ]] || continue
    printf '%s\n' "--volume"
    printf '%s\n' "${path}:/workspace/${name}"
  done < <(dce_repo_entries_lines)
}

# Emit the full mount argv for a schema-v2 project container. The ONE mount
# planner shared by `dce new` and `dce rebuild-container` (create-argv parity
# by construction). Emits, in order:
#   one bind per repo       <host-path>:/workspace/<repo-name>
#   managed cache volume    dce-cache volume :/workspace/.cache
#   secret .npmrc bind      <npmrc>:/home/dev/.npmrc:ro   (skipped when empty)
#   one volume per hidden path
# mode: "live" mounts the live managed volumes; "snap:<label>" mounts the
# snapshot-isolated copies (dce-snapvol-*) for hidden paths AND .cache, so a
# restore never reuses live volume state. Repos are host state and always bind.
dce_workspace_mount_args() {
  local project="$1"
  local npmrc_path="$2"
  local mode="$3"
  shift 3
  local -a hidden_paths=("${@:-}")

  local arg=""
  while IFS= read -r arg; do
    [[ -z "$arg" ]] && continue
    printf '%s\n' "$arg"
  done < <(dce_repo_mount_args)

  local cache_vol="" snap_label=""
  case "$mode" in
    live)
      cache_vol="$(dce_cache_volume_name "$project")"
      ;;
    snap:*)
      snap_label="${mode#snap:}"
      cache_vol="$(dce_snapshot_volume_name "$project" "$snap_label" "$_DC_MANAGED_CACHE_PATH")"
      ;;
    *)
      printf 'ERROR: unknown workspace mount mode: %s\n' "$mode" >&2
      return 1
      ;;
  esac
  printf '%s\n' "--volume"
  printf '%s\n' "${cache_vol}:/workspace/${_DC_MANAGED_CACHE_PATH}"

  if [[ -n "$npmrc_path" ]]; then
    printf '%s\n' "--volume"
    printf '%s\n' "${npmrc_path}:/home/dev/.npmrc:ro"
  fi

  local hp="" vol=""
  for hp in "${hidden_paths[@]:-}"; do
    [[ -z "$hp" ]] && continue
    case "$mode" in
      live)    vol="$(dce_hidden_volume_name "$project" "$hp")" ;;
      snap:*)  vol="$(dce_snapshot_volume_name "$project" "$snap_label" "$hp")" ;;
    esac
    printf '%s\n' "--volume"
    printf '%s\n' "${vol}:/workspace/${hp}"
  done
}

# Echo the managed volume paths for a project: the caller's hidden paths plus
# the managed .cache path appended last (deduped, one per line). This is the
# set that mount verification, ownership normalization, snapshots, and `dce rm`
# must all cover. A .cache passed by the caller is not repeated in the user
# section; the managed entry always closes the list so argv ordering stays
# deterministic across create and rebuild.
dce_managed_volume_paths() {
  local p=""
  declare -A seen=()
  for p in "${@:-}"; do
    [[ -z "$p" || "$p" == "$_DC_MANAGED_CACHE_PATH" ]] && continue
    [[ -n "${seen[$p]:-}" ]] && continue
    seen["$p"]=1
    printf '%s\n' "$p"
  done
  printf '%s\n' "$_DC_MANAGED_CACHE_PATH"
}

# Normalize user-supplied hidden paths against the project's repo set (the
# REPO_NAMES global): an unprefixed single-segment path on a single-repo
# project is shorthand for `<repo-name>/<path>` and is normalized before
# persistence; on a multi-repo project the same input is ambiguous and is
# rejected. Repo-prefixed paths pass through untouched. Inputs must already
# have passed dce_normalize_hidden_paths_values (lexical + validation, which
# also rejects the reserved .cache path).
dce_hidden_paths_for_project() {
  local -a names=()
  if declare -p REPO_NAMES >/dev/null 2>&1; then
    names=("${REPO_NAMES[@]}")
  fi

  local -a out=()
  declare -A known_names=()
  local known_name=""
  for known_name in "${names[@]:-}"; do
    [[ -n "$known_name" ]] && known_names["$known_name"]=1
  done
  local p="" out_csv=""
  for p in "${@:-}"; do
    [[ -z "$p" ]] && continue
    # Defense in depth: the managed cache path is reserved even if a caller
    # skips lexical validation (dce_validate_hidden_path already rejects it).
    if [[ "$p" == "$_DC_MANAGED_CACHE_PATH" || "$p" == "$_DC_MANAGED_CACHE_PATH/"* ]]; then
      printf 'ERROR: Hidden path %s is reserved: /workspace/%s is a dce-managed volume.\n' \
        "$p" "$_DC_MANAGED_CACHE_PATH" >&2
      return 1
    fi

    if [[ ${#names[@]} -eq 0 ]]; then
      printf 'ERROR: Cannot normalize hidden path %q: project has no repos.\n' "$p" >&2
      return 1
    fi

    if [[ ${#names[@]} -eq 1 ]]; then
      if [[ "$p" != "${names[0]}" && "$p" != "${names[0]}/"* ]]; then
        p="${names[0]}/$p"
      fi
      out+=("$p")
      continue
    fi

    if [[ "$p" != */* ]]; then
      printf 'ERROR: Ambiguous hidden path %q: name the repo explicitly (%s/<path>).\n' \
        "$p" "${names[0]}" >&2
      return 1
    fi

    local prefix="${p%%/*}"
    if [[ -z "${known_names[$prefix]:-}" ]]; then
      printf 'ERROR: Unknown repo prefix in hidden path %q. Known repos: %s\n' \
        "$p" "$(dce_join_by ', ' "${names[@]}")" >&2
      return 1
    fi

    out+=("$p")
  done

  out_csv="$(dce_join_by ',' "${out[@]:-}")"
  printf '%s\n' "$out_csv"
}
