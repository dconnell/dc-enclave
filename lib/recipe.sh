#!/usr/bin/env bash
# =============================================================================
# lib/recipe.sh - Untrusted container recipe parsing and merge helpers.
#
# Recipes are shareable key=value files loaded by `dce new` from either:
#   - explicit --config <path> / --config=<path> (single file), or
#   - magic lookup by project name under:
#       $DC_TEAM_DIR/container-recipes/<name>
#       $DC_USER_DIR/container-recipes/<name>
#
# Security posture: recipe files are untrusted input. This loader NEVER sources
# files; it performs pure key=value parsing, rejects malformed/unknown keys, and
# validates every value with the same validators/normalizers used by CLI flags.
#
# `repo-path` policy: unlike other keys, `repo-path` is NOT applied verbatim.
# An auto-loaded recipe cannot silently widen the host bind mount — when a
# recipe-sourced `repo-path` resolves OUTSIDE the default repos dir, the merge
# consumer (scripts/new-container.sh) gates it behind an operator confirmation
# (--yes/-y honors it with a visible notice), and hard-rejects values that
# resolve to a sensitive root (/, $HOME, the repos root, or a parent of it) or
# that contain non-path-safe characters. CLI `--repo-path` is the documented
# power-user escape hatch and skips the confirmation gate.
#
# Merge model (plans/container-recipe.md):
#   1) Recipe-internal merge: user overrides team per key; list keys replace.
#   2) CLI-over-recipe merge is done by new-container.sh after calling
#      dce_recipe_resolve_inputs (this library does not mutate live CLI vars).
# =============================================================================

if [[ -n "${_DC_RECIPE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_RECIPE_SH_LOADED=1

# Per-side parse state keyed by "<side>:<key>" where side is team/user/single.
declare -gA _DC_RECIPE_HAS=()
declare -gA _DC_RECIPE_SCALAR=()
declare -gA _DC_RECIPE_LIST=()

# Merged key state keyed by "<key>".
declare -gA _DC_RECIPE_MERGED_HAS=()
declare -gA _DC_RECIPE_MERGED_SCALAR=()
declare -gA _DC_RECIPE_MERGED_LIST=()

# Materialized merged outputs consumed by new-container.sh.
declare -g _DC_RECIPE_FOUND=false
declare -g _DC_RECIPE_MERGED_SCOPE_INPUT=""
declare -g _DC_RECIPE_MERGED_CONTAINER_CPUS=""
declare -g _DC_RECIPE_MERGED_CONTAINER_MEMORY=""
declare -g _DC_RECIPE_MERGED_NETWORK_INPUT=""
declare -g _DC_RECIPE_MERGED_NETWORK_IP=""
declare -g _DC_RECIPE_MERGED_REPO_PATH_OVERRIDE=""
declare -g _DC_RECIPE_MERGED_SYNC=""
declare -ga _DC_RECIPE_MERGED_HIDDEN_PATH_INPUTS=()
declare -ga _DC_RECIPE_MERGED_SYNC_IGNORE_INPUTS=()
declare -ga _DC_RECIPE_MERGED_PORTS=()

declare -gra _DC_RECIPE_SCALAR_KEYS=(scopes cpus memory ip repo-path sync)
declare -gra _DC_RECIPE_LIST_KEYS=(hide sync-ignore network port)

# Write a recipe file atomically from already-normalized key=value lines.
# Existing content is replaced; an empty line list writes an empty file.
dce_recipe_write_file() {  # <file> [key=value ...]
  local file="$1"
  shift

  local dir=""
  dir="$(dirname "$file")"
  if ! mkdir -p "$dir"; then
    printf 'ERROR: Could not create recipe directory: %s\n' "$dir" >&2
    return 1
  fi

  local tmp_file=""
  tmp_file="$(mktemp "${file}.tmp.XXXXXX")" || {
    printf 'ERROR: Could not create temp file for recipe: %s\n' "$file" >&2
    return 1
  }

  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" > "$tmp_file"
  else
    : > "$tmp_file"
  fi

  chmod 600 "$tmp_file"
  mv "$tmp_file" "$file"
}

# Trim leading/trailing whitespace from one scalar string.
_dce_recipe_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Reset all parse/merge/materialized state for one resolve call.
_dce_recipe_reset_state() {
  declare -gA _DC_RECIPE_HAS=()
  declare -gA _DC_RECIPE_SCALAR=()
  declare -gA _DC_RECIPE_LIST=()
  declare -gA _DC_RECIPE_MERGED_HAS=()
  declare -gA _DC_RECIPE_MERGED_SCALAR=()
  declare -gA _DC_RECIPE_MERGED_LIST=()

  _DC_RECIPE_FOUND=false
  _DC_RECIPE_MERGED_SCOPE_INPUT=""
  _DC_RECIPE_MERGED_CONTAINER_CPUS=""
  _DC_RECIPE_MERGED_CONTAINER_MEMORY=""
  _DC_RECIPE_MERGED_NETWORK_INPUT=""
  _DC_RECIPE_MERGED_NETWORK_IP=""
  _DC_RECIPE_MERGED_REPO_PATH_OVERRIDE=""
  _DC_RECIPE_MERGED_SYNC=""
  declare -ga _DC_RECIPE_MERGED_HIDDEN_PATH_INPUTS=()
  declare -ga _DC_RECIPE_MERGED_SYNC_IGNORE_INPUTS=()
  declare -ga _DC_RECIPE_MERGED_PORTS=()
}

_dce_recipe_parse_error() {
  local file="$1"
  local lineno="$2"
  local message="$3"
  printf 'ERROR: Invalid recipe %s:%s: %s\n' "$file" "$lineno" "$message" >&2
}

_dce_recipe_parse_context() {
  local file="$1"
  local lineno="$2"
  printf '  in recipe %s:%s\n' "$file" "$lineno" >&2
}

_dce_recipe_append_list() {
  local side="$1"
  local key="$2"
  local value="$3"
  local map_key="$side:$key"

  if [[ -n "${_DC_RECIPE_LIST[$map_key]-}" ]]; then
    _DC_RECIPE_LIST["$map_key"]+=$'\n'"$value"
  else
    _DC_RECIPE_LIST["$map_key"]="$value"
  fi
}

_dce_recipe_validate_port_value() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+(:[0-9]+)?$ ]]
}

# Parse one untrusted recipe file into side state (team/user/single).
#
# Rules:
# - key=value per non-comment line (split on first '=')
# - unknown key => error (fail closed)
# - malformed line / empty key => error
# - repeated scalar => last wins
# - repeated list key => accumulates in file order
# - every value validated/normalized via shared helpers
dce_recipe_parse_file() {
  local side="$1"
  local file="$2"

  if [[ ! -f "$file" ]]; then
    printf 'ERROR: Recipe file not found: %s\n' "$file" >&2
    return 1
  fi

  local line=""
  local raw=""
  local key=""
  local value=""
  local normalized=""
  local lineno=0

  # shellcheck disable=SC2094
  # $file is read below and passed to error/context helpers that only print its
  # name; none of them write it. ShellCheck can't verify that across functions.
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    raw="$(_dce_recipe_trim "$line")"

    [[ -z "$raw" ]] && continue
    [[ "${raw:0:1}" == "#" ]] && continue

    if [[ "$raw" != *"="* ]]; then
      _dce_recipe_parse_error "$file" "$lineno" "malformed line (expected key=value)"
      return 1
    fi

    key="${raw%%=*}"
    value="${raw#*=}"
    key="$(_dce_recipe_trim "$key")"
    value="$(_dce_recipe_trim "$value")"

    if [[ -z "$key" ]]; then
      _dce_recipe_parse_error "$file" "$lineno" "empty key"
      return 1
    fi

    case "$key" in
      scopes)
        if ! normalized="$(dce_normalize_scopes_csv "$value")"; then
          _dce_recipe_parse_context "$file" "$lineno"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        _DC_RECIPE_SCALAR["$side:$key"]="$normalized"
        ;;
      cpus)
        if ! dce_validate_cpus_value "$value" >&2; then
          _dce_recipe_parse_context "$file" "$lineno"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        _DC_RECIPE_SCALAR["$side:$key"]="$value"
        ;;
      memory)
        if ! dce_validate_memory_value "$value" >&2; then
          _dce_recipe_parse_context "$file" "$lineno"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        _DC_RECIPE_SCALAR["$side:$key"]="$value"
        ;;
      hide)
        if ! normalized="$(dce_normalize_hidden_paths_csv "$value")"; then
          _dce_recipe_parse_context "$file" "$lineno"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        _dce_recipe_append_list "$side" "$key" "$normalized"
        ;;
      sync-ignore)
        # Same grammar as hide: relative, traversal-free, comma list. Under
        # --sync this is the sync-world analog of hide (Mutagen --ignore rules).
        if ! normalized="$(dce_normalize_hidden_paths_csv "$value")"; then
          _dce_recipe_parse_context "$file" "$lineno"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        _dce_recipe_append_list "$side" "$key" "$normalized"
        ;;
      sync)
        # Persisted as the literal string "0"/"1" to match CONTAINER_SYNC.
        case "$value" in
          0|1|true|false)
            case "$value" in
              true) value=1 ;;
              false) value=0 ;;
            esac
            ;;
          *)
            _dce_recipe_parse_error "$file" "$lineno" "invalid sync value '$value' (expected 0 or 1)"
            return 1
            ;;
        esac
        _DC_RECIPE_HAS["$side:$key"]=1
        _DC_RECIPE_SCALAR["$side:$key"]="$value"
        ;;
      network)
        if ! normalized="$(dce_normalize_network_arg "$value")"; then
          _dce_recipe_parse_context "$file" "$lineno"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        [[ -n "$normalized" ]] && _dce_recipe_append_list "$side" "$key" "$normalized"
        ;;
      ip)
        if ! dce_validate_ip_value "$value" >&2; then
          _dce_recipe_parse_context "$file" "$lineno"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        _DC_RECIPE_SCALAR["$side:$key"]="$value"
        ;;
      repo-path)
        # Stored verbatim here; the consumer (new-container.sh) gates recipe-
        # sourced values so an untrusted recipe cannot silently widen the host
        # bind mount. See the security-posture note at the top of this file.
        _DC_RECIPE_HAS["$side:$key"]=1
        _DC_RECIPE_SCALAR["$side:$key"]="$value"
        ;;
      port)
        if ! _dce_recipe_validate_port_value "$value"; then
          _dce_recipe_parse_error "$file" "$lineno" "invalid port mapping '$value' (expected N or N:N)"
          return 1
        fi
        _DC_RECIPE_HAS["$side:$key"]=1
        _dce_recipe_append_list "$side" "$key" "$value"
        ;;
      *)
        _dce_recipe_parse_error "$file" "$lineno" "unknown key '$key'"
        return 1
        ;;
    esac
  done < "$file"

  return 0
}

_dce_recipe_merge_sides() {
  local preferred_side="$1"
  local fallback_side="$2"
  local key=""

  declare -gA _DC_RECIPE_MERGED_HAS=()
  declare -gA _DC_RECIPE_MERGED_SCALAR=()
  declare -gA _DC_RECIPE_MERGED_LIST=()

  for key in "${_DC_RECIPE_SCALAR_KEYS[@]}"; do
    if [[ -n "${_DC_RECIPE_HAS[$preferred_side:$key]-}" ]]; then
      _DC_RECIPE_MERGED_HAS["$key"]=1
      _DC_RECIPE_MERGED_SCALAR["$key"]="${_DC_RECIPE_SCALAR[$preferred_side:$key]-}"
    elif [[ -n "$fallback_side" && -n "${_DC_RECIPE_HAS[$fallback_side:$key]-}" ]]; then
      _DC_RECIPE_MERGED_HAS["$key"]=1
      _DC_RECIPE_MERGED_SCALAR["$key"]="${_DC_RECIPE_SCALAR[$fallback_side:$key]-}"
    fi
  done

  for key in "${_DC_RECIPE_LIST_KEYS[@]}"; do
    if [[ -n "${_DC_RECIPE_HAS[$preferred_side:$key]-}" ]]; then
      _DC_RECIPE_MERGED_HAS["$key"]=1
      _DC_RECIPE_MERGED_LIST["$key"]="${_DC_RECIPE_LIST[$preferred_side:$key]-}"
    elif [[ -n "$fallback_side" && -n "${_DC_RECIPE_HAS[$fallback_side:$key]-}" ]]; then
      _DC_RECIPE_MERGED_HAS["$key"]=1
      _DC_RECIPE_MERGED_LIST["$key"]="${_DC_RECIPE_LIST[$fallback_side:$key]-}"
    fi
  done
}

# Convert merged key state into the concrete variables new-container.sh applies
# with CLI-over-recipe precedence.
_dce_recipe_materialize_merged_inputs() {
  local list_blob=""
  local item=""
  local combined=""
  local normalized_csv=""
  local -a items=()

  _DC_RECIPE_MERGED_SCOPE_INPUT="${_DC_RECIPE_MERGED_SCALAR[scopes]-}"
  _DC_RECIPE_MERGED_CONTAINER_CPUS="${_DC_RECIPE_MERGED_SCALAR[cpus]-}"
  _DC_RECIPE_MERGED_CONTAINER_MEMORY="${_DC_RECIPE_MERGED_SCALAR[memory]-}"
  _DC_RECIPE_MERGED_NETWORK_IP="${_DC_RECIPE_MERGED_SCALAR[ip]-}"
  _DC_RECIPE_MERGED_REPO_PATH_OVERRIDE="${_DC_RECIPE_MERGED_SCALAR[repo-path]-}"
  _DC_RECIPE_MERGED_SYNC="${_DC_RECIPE_MERGED_SCALAR[sync]-}"

  declare -ga _DC_RECIPE_MERGED_HIDDEN_PATH_INPUTS=()
  if [[ -n "${_DC_RECIPE_MERGED_HAS[hide]-}" ]]; then
    list_blob="${_DC_RECIPE_MERGED_LIST[hide]-}"
    items=()
    if [[ -n "$list_blob" ]]; then
      while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        items+=("$item")
      done <<< "$list_blob"
    fi
    if [[ ${#items[@]} -gt 0 ]]; then
      if ! normalized_csv="$(dce_normalize_hidden_paths_values "${items[@]}")"; then
        return 1
      fi
      if [[ -n "$normalized_csv" ]]; then
        IFS=',' read -r -a _DC_RECIPE_MERGED_HIDDEN_PATH_INPUTS <<< "$normalized_csv"
      fi
    fi
  fi

  # --sync-ignore mirrors hide's grammar and merge shape (list key, replaces).
  declare -ga _DC_RECIPE_MERGED_SYNC_IGNORE_INPUTS=()
  if [[ -n "${_DC_RECIPE_MERGED_HAS[sync-ignore]-}" ]]; then
    list_blob="${_DC_RECIPE_MERGED_LIST[sync-ignore]-}"
    items=()
    if [[ -n "$list_blob" ]]; then
      while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        items+=("$item")
      done <<< "$list_blob"
    fi
    if [[ ${#items[@]} -gt 0 ]]; then
      if ! normalized_csv="$(dce_normalize_hidden_paths_values "${items[@]}")"; then
        return 1
      fi
      if [[ -n "$normalized_csv" ]]; then
        IFS=',' read -r -a _DC_RECIPE_MERGED_SYNC_IGNORE_INPUTS <<< "$normalized_csv"
      fi
    fi
  fi

  _DC_RECIPE_MERGED_NETWORK_INPUT=""
  if [[ -n "${_DC_RECIPE_MERGED_HAS[network]-}" ]]; then
    list_blob="${_DC_RECIPE_MERGED_LIST[network]-}"
    items=()
    if [[ -n "$list_blob" ]]; then
      while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        items+=("$item")
      done <<< "$list_blob"
    fi
    if [[ ${#items[@]} -gt 0 ]]; then
      combined="$(dce_join_by ',' "${items[@]}")"
      if ! _DC_RECIPE_MERGED_NETWORK_INPUT="$(dce_normalize_network_arg "$combined")"; then
        return 1
      fi
    fi
  fi

  declare -ga _DC_RECIPE_MERGED_PORTS=()
  if [[ -n "${_DC_RECIPE_MERGED_HAS[port]-}" ]]; then
    list_blob="${_DC_RECIPE_MERGED_LIST[port]-}"
    if [[ -n "$list_blob" ]]; then
      while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        _DC_RECIPE_MERGED_PORTS+=("$item")
      done <<< "$list_blob"
    fi
  fi

  return 0
}

# Resolve recipe inputs for one `dce new` run.
#
# Args:
#   $1 project name
#   $2 optional explicit --config path (empty => magic lookup by project name)
#
# On success, sets _DC_RECIPE_FOUND + _DC_RECIPE_MERGED_* variables.
dce_recipe_resolve_inputs() {
  local project="$1"
  local explicit_config="${2:-}"

  _dce_recipe_reset_state

  local team_recipe=""
  local user_recipe=""

  if [[ -n "$explicit_config" ]]; then
    if [[ ! -f "$explicit_config" ]]; then
      printf 'ERROR: Recipe file not found: %s\n' "$explicit_config" >&2
      return 1
    fi
    if ! dce_recipe_parse_file single "$explicit_config"; then
      return 1
    fi
    _DC_RECIPE_FOUND=true
    _dce_recipe_merge_sides single ""
    _dce_recipe_materialize_merged_inputs || return 1
    return 0
  fi

  team_recipe="$(dce_team_recipes_dir)/$project"
  user_recipe="$(dce_user_recipes_dir)/$project"

  if [[ -f "$team_recipe" ]]; then
    if ! dce_recipe_parse_file team "$team_recipe"; then
      return 1
    fi
    _DC_RECIPE_FOUND=true
  fi

  if [[ -f "$user_recipe" ]]; then
    if ! dce_recipe_parse_file user "$user_recipe"; then
      return 1
    fi
    _DC_RECIPE_FOUND=true
  fi

  if [[ "$_DC_RECIPE_FOUND" != "true" ]]; then
    return 0
  fi

  # user overrides team, per key. List keys replace (not union).
  _dce_recipe_merge_sides user team
  _dce_recipe_materialize_merged_inputs || return 1
  return 0
}
