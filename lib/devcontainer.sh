#!/usr/bin/env bash
# =============================================================================
# lib/devcontainer.sh - Managed .devcontainer/devcontainer.json helpers.
#
# The devcontainer.json that `dce new` seeds (Docker-compatible backends) embeds
# several fields derived from dce-managed state: build.dockerfile (from scopes),
# mounts (the .npmrc bind + one hidden volume per hidden path), runArgs (network
# membership), forwardPorts (ports), containerEnv.TZ, and (when a GitHub PAT is
# configured) customizations.vscode.settings."github.gitAuthentication": false.
# The file is seed-only -- never overwritten -- so once a user edits config
# (scopes/hide/networks/ports) and rebuilds, VS Code silently desyncs.
#
# This lib is the single source of truth for that managed state:
#   - dce_devcontainer_expected_state / _recorded_state : canonical comparable
#       form (the four drift fields), from inputs and from a parsed JSON file.
#   - dce_devcontainer_detect_drift : read-only, non-fatal diff (jq-optional).
#   - dce_devcontainer_render        : full JSON for a from-scratch seed (used by
#       `dce new`; byte-compatible with the historical heredoc).
#   - dce_devcontainer_sync          : jq-required rewrite of the managed fields
#       that preserves user-authored keys/mounts (`dce config sync-vscode`).
#   - dce_devcontainer_build_file    : base-vs-derived Containerfile path.
#
# Apple/container has no devcontainer.json; callers gate on docker-compatible.
# =============================================================================

# Auto-source deps if this lib is loaded directly (single-import convenience).
if [[ -z "${_DC_COMMON_SH_LOADED:-}" ]]; then
  _dce_devcontainer_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  # Sibling lib auto-import; path is resolved above, not followed statically.
  source "$_dce_devcontainer_lib_dir/common.sh"
  unset _dce_devcontainer_lib_dir
fi

if [[ -n "${_DC_VSCODE_DEVCONTAINER_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_VSCODE_DEVCONTAINER_SH_LOADED=1

# The four drift fields, as canonical line tags. A canonical state is a stream of
# "<tag>\t<value>" lines (set fields repeat once per member); comparing two
# sorted streams is the drift test.
declare -gr _DC_DRIFT_TAG_SCOPES="scopes"
declare -gr _DC_DRIFT_TAG_HIDDEN="hidden"
declare -gr _DC_DRIFT_TAG_NETWORKS="networks"
declare -gr _DC_DRIFT_TAG_PORTS="ports"
declare -gr _DC_DRIFT_TAG_EXTENSIONS="extensions"

# Human labels for the drift notice (tag -> label).
_dce_dc_drift_label() {
  case "$1" in
    "$_DC_DRIFT_TAG_SCOPES")  printf 'scopes' ;;
    "$_DC_DRIFT_TAG_HIDDEN")  printf 'hidden paths' ;;
    "$_DC_DRIFT_TAG_NETWORKS") printf 'networks' ;;
    "$_DC_DRIFT_TAG_PORTS")   printf 'ports' ;;
    "$_DC_DRIFT_TAG_EXTENSIONS") printf 'extensions' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Reduce a port mapping to its CONTAINER port (the value forwardPorts carries):
# "host:container" -> container; a bare port -> itself.
_dce_dc_container_port() {
  local m="$1"
  if [[ "$m" == *:* ]]; then
    printf '%s' "${m##*:}"
  else
    printf '%s' "$m"
  fi
}

# Canonical scope token from a build Containerfile path:
#   Containerfile.base            -> "base"
#   Containerfile.<hex>           -> "derived:<hex>"
#   anything else (user-chosen)   -> "derived:other"
# Comparing basenames (not full paths) avoids spurious drift if the dce install
# root moves; the hash is what actually reflects the scope set.
_dce_dc_scope_token() {
  local df="$1"
  local base=""
  base="$(basename "$df")"
  if [[ "$base" == "Containerfile.base" ]]; then
    printf 'base'
  elif [[ "$base" =~ ^Containerfile\.([0-9a-f]+)$ ]]; then
    printf 'derived:%s' "${BASH_REMATCH[1]}"
  else
    printf 'derived:other'
  fi
}

# Split a CSV (possibly empty) into lines, skipping empties. Whitespace within a
# token is preserved; only the comma is a separator.
_dce_dc_csv_lines() {
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  local IFS=','
  local -a parts=()
  local p
  read -r -a parts <<< "$csv"
  for p in "${parts[@]}"; do
    [[ -z "$p" ]] && continue
    printf '%s\n' "$p"
  done
}

# -----------------------------------------------------------------------------
# Expected canonical state (from current config / inputs).
#
# Emits "<tag>\t<value>" lines for the four drift fields:
#   scopes    one line (omitted when build_dockerfile is empty)
#   hidden    one line per hidden path (the managed mount TARGET path)
#   networks  one line per network entry (name or name:ip)
#   ports     one line per CONTAINER port
# Pure: no I/O. Callers pass already-normalized CSVs.
# -----------------------------------------------------------------------------
dce_devcontainer_expected_state() {
  local project="$1"
  local build_dockerfile="$2"
  local hidden_csv="$3"
  local networks_csv="$4"
  local ports_csv="$5"
  # Optional editor-extensions declaration-drift inputs (plans/extensions.md §8A).
  # ext_namespace is the customizations.<ns> key ("vscode" in v1); extensions_csv
  # is the resolved manifest set; manifests_exist gates emission so pre-adoption
  # projects emit nothing (migration guard -> no spurious drift).
  local ext_namespace="${6:-}"
  local extensions_csv="${7:-}"
  local manifests_exist="${8:-false}"

  if [[ -n "$build_dockerfile" ]]; then
    printf '%s\t%s\n' "$_DC_DRIFT_TAG_SCOPES" "$(_dce_dc_scope_token "$build_dockerfile")"
  fi

  local hp=""
  while IFS= read -r hp; do
    [[ -z "$hp" ]] && continue
    printf '%s\t%s\n' "$_DC_DRIFT_TAG_HIDDEN" "$hp"
  done < <(_dce_dc_csv_lines "$hidden_csv")

  local ne=""
  while IFS= read -r ne; do
    [[ -z "$ne" ]] && continue
    printf '%s\t%s\n' "$_DC_DRIFT_TAG_NETWORKS" "$ne"
  done < <(_dce_dc_csv_lines "$networks_csv")

  local pm=""
  while IFS= read -r pm; do
    [[ -z "$pm" ]] && continue
    printf '%s\t%s\n' "$_DC_DRIFT_TAG_PORTS" "$(_dce_dc_container_port "$pm")"
  done < <(_dce_dc_csv_lines "$ports_csv")

  # Extensions: emit one line per resolved id, ONLY post-adoption. Pre-adoption
  # (no manifests) the array is user-owned, so comparing it would cry wolf.
  if [[ "$manifests_exist" == "true" && -n "$ext_namespace" ]]; then
    local ex=""
    while IFS= read -r ex; do
      [[ -z "$ex" ]] && continue
      printf '%s\t%s\n' "$_DC_DRIFT_TAG_EXTENSIONS" "$ex"
    done < <(_dce_dc_csv_lines "$extensions_csv")
  fi
}

# Recorded canonical state (parsed from an existing devcontainer.json).
#
# Same "<tag>\t<value>" lines, but for the MANAGED subset only: managed hidden
# mounts are identified by their dce-hide-<slug>- source; user mounts/keys are
# ignored. jq-preferred with a grep fallback so detection works without jq.
dce_devcontainer_recorded_state() {
  local project="$1"
  local file="$2"
  local ext_namespace="${3:-}"

  [[ -f "$file" ]] || return 0

  local slug=""
  slug="$(dce_project_slug "$project")"

  if command -v jq >/dev/null 2>&1; then
    if dce_devcontainer_recorded_state_jq "$slug" "$file" "$ext_namespace"; then
      return 0
    fi
  fi
  dce_devcontainer_recorded_state_grep "$slug" "$file" "$ext_namespace"
}

# jq path. Emits the canonical lines. Failure (malformed JSON, jq error) falls
# through to the grep path so a corrupt file degrades rather than aborting.
# ext_namespace (optional, arg 3): when non-empty, also emits one
# extensions\t<id> line per element of customizations.<ns>.extensions.
dce_devcontainer_recorded_state_jq() {
  local slug="$1"
  local file="$2"
  local ext_namespace="${3:-}"

  # Tag literals are hardcoded here (the jq program is single-quoted, so bash
  # vars would not expand). They mirror the _DC_DRIFT_TAG_* constants exactly.
  # The scopes token mirrors _dce_dc_scope_token so recorded matches expected.
  # Extension parsing is conditional on $ns being non-empty so a caller that
  # passes no namespace pays no cost and sees no extensions lines.
  jq -r --arg slug "$slug" --arg ns "$ext_namespace" '
    (.build.dockerfile // null) as $df |
    (if $df == null then empty
     else "scopes\t" + ($df | split("/") | last |
       if . == "Containerfile.base" then "base"
       elif test("^Containerfile\\.[0-9a-f]+$") then "derived:" + sub("^Containerfile\\."; "")
       else "derived:other" end) end),
    (.mounts[]?
      | select(test("source=dce-hide-" + $slug + "-"))
      | capture("target=/workspace/(?<p>[^,]+)")
      | "hidden\t" + .p),
    (reduce (.runArgs[]?) as $t ({flag:"", nets:[]};
        if $t == "--network" then .flag = "net"
        elif $t == "--ip" then .flag = "ip"
        elif .flag == "net" then .nets += [$t] | .flag = ""
        elif .flag == "ip" then .nets[-1] += ":" + $t | .flag = ""
        else . end
      ) | .nets[] | "networks\t" + .),
    (.forwardPorts[]? | "ports\t" + tostring),
    (if $ns != "" then
       (.customizations[$ns].extensions[]? | "extensions\t" + .)
     else empty end)
  ' "$file" 2>/dev/null
}

# grep fallback (best-effort): line-based extraction for the constrained format
# dce emits. Robust for scopes/ports, and for hidden/runArgs when each managed
# entry sits on its own line (the seeded layout). ext_namespace (arg 3, optional)
# adds best-effort parsing of customizations.<ns>.extensions: only the simple
# single-line array layout dce seeds is recognized; a hand-reformatted file may
# be missed (jq path handles the general case).
dce_devcontainer_recorded_state_grep() {
  local slug="$1"
  local file="$2"
  local ext_namespace="${3:-}"
  local content=""
  local line="" tok=""

  content="$(cat "$file" 2>/dev/null || true)"

  # scopes: the dockerfile value -> basename -> token.
  while IFS= read -r line; do
    [[ "$line" =~ \"dockerfile\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || continue
    printf '%s\t%s\n' "$_DC_DRIFT_TAG_SCOPES" "$(_dce_dc_scope_token "${BASH_REMATCH[1]}")"
    break
  done <<< "$content"

  # hidden: each managed mount string (source=dce-hide-<slug>-) -> its target path.
  while IFS= read -r line; do
    [[ "$line" == *"source=dce-hide-$slug-"* ]] || continue
    if [[ "$line" =~ target=/workspace/([^,\"]+) ]]; then
      printf '%s\t%s\n' "$_DC_DRIFT_TAG_HIDDEN" "${BASH_REMATCH[1]}"
    fi
  done <<< "$content"

  # networks: walk the runArgs array (one line) reconstructing name[:ip]. Each
  # network is emitted exactly once; the single --ip (if any) is folded onto the
  # FIRST (primary) network -- the only one that carries an IP in the seeded
  # layout.
  local raline=""
  raline="$(printf '%s\n' "$content" | grep -E '"runArgs"' || true)"
  if [[ -n "$raline" ]]; then
    local -a toks=()
    while IFS= read -r tok; do
      tok="${tok#\"}"
      tok="${tok%\"}"
      [[ -n "$tok" ]] && toks+=("$tok")
    done < <(printf '%s\n' "$raline" | grep -oE '"[^"]+"')
    local -a net_names=()
    local net_ip=""
    local i=0
    for ((i = 0; i < ${#toks[@]}; i++)); do
      case "${toks[$i]}" in
        --network)
          if (( i + 1 < ${#toks[@]} )); then
            net_names+=("${toks[$((i + 1))]}")
          fi
          ;;
        --ip)
          if (( i + 1 < ${#toks[@]} )); then
            net_ip="${toks[$((i + 1))]}"
          fi
          ;;
      esac
    done
    local first_net=true
    local nn=""
    for nn in "${net_names[@]}"; do
      if $first_net && [[ -n "$net_ip" ]]; then
        printf '%s\t%s\n' "$_DC_DRIFT_TAG_NETWORKS" "$nn:$net_ip"
      else
        printf '%s\t%s\n' "$_DC_DRIFT_TAG_NETWORKS" "$nn"
      fi
      first_net=false
    done
  fi

  # ports: numbers in the forwardPorts array (one line).
  local fpline=""
  fpline="$(printf '%s\n' "$content" | grep -E '"forwardPorts"' || true)"
  if [[ -n "$fpline" ]]; then
    while IFS= read -r tok; do
      [[ -n "$tok" ]] && printf '%s\t%s\n' "$_DC_DRIFT_TAG_PORTS" "$tok"
    done < <(printf '%s\n' "$fpline" | grep -oE '[0-9]+')
  fi

  # extensions: best-effort parse scoped to customizations.<ns>.extensions.
  # This intentionally DOES NOT scan every "extensions" key in the file: a
  # top-level user-owned "extensions" array must never be mistaken for the
  # managed devcontainer key.
  #
  # Supported fallback layouts:
  #   "customizations": { "<ns>": { "extensions": ["a.b","c.d"] } }
  #   ...or the same with the array split across multiple lines.
  #
  # If the file is heavily reformatted (or malformed), this parser may miss
  # values; the jq path handles the general case.
  if [[ -n "$ext_namespace" ]]; then
    local saw_customizations=false
    local saw_namespace=false
    local in_ext_array=false
    local ext_fragment=""

    while IFS= read -r line; do
      if ! $saw_customizations; then
        [[ "$line" == *'"customizations"'* ]] || continue
        saw_customizations=true
      fi

      if ! $saw_namespace; then
        [[ "$line" == *"\"$ext_namespace\""* ]] || continue
        saw_namespace=true
      fi

      if ! $in_ext_array; then
        if [[ "$line" != *'"extensions"'* || "$line" != *'['* ]]; then
          continue
        fi
        ext_fragment="${line#*[}"
        if [[ "$ext_fragment" == *']'* ]]; then
          ext_fragment="${ext_fragment%%]*}"
          in_ext_array=false
        else
          in_ext_array=true
          continue
        fi
      else
        if [[ "$line" == *']'* ]]; then
          ext_fragment+=$'\n'"${line%%]*}"
          in_ext_array=false
        else
          ext_fragment+=$'\n'"$line"
          continue
        fi
      fi

      local exid=""
      while IFS= read -r exid; do
        # grep -oE yields quoted tokens; strip the quotes.
        exid="${exid#\"}"
        exid="${exid%\"}"
        [[ -n "$exid" ]] && printf '%s\t%s\n' "$_DC_DRIFT_TAG_EXTENSIONS" "$exid"
      done < <(printf '%s\n' "$ext_fragment" | grep -oE '"[^"]+"')
      break
    done <<< "$content"
  fi
}

# -----------------------------------------------------------------------------
# Drift detection (read-only, non-fatal). Returns 1 if any managed field
# differs, 0 otherwise. Prints a one-line summary + per-field diff to STDERR on
# drift. Never writes, never exits. scopes is skipped when build_dockerfile is
# empty (caller could not derive it).
# -----------------------------------------------------------------------------
dce_devcontainer_detect_drift() {
  local project="$1"
  local file="$2"
  local build_dockerfile="$3"
  local hidden_csv="$4"
  local networks_csv="$5"
  local ports_csv="$6"
  # Optional editor-extensions declaration drift (§8A). See expected_state.
  local ext_namespace="${7:-}"
  local extensions_csv="${8:-}"
  local manifests_exist="${9:-false}"

  [[ -f "$file" ]] || return 0

  local expected recorded
  expected="$(dce_devcontainer_expected_state "$project" "$build_dockerfile" \
    "$hidden_csv" "$networks_csv" "$ports_csv" \
    "$ext_namespace" "$extensions_csv" "$manifests_exist")"
  recorded="$(dce_devcontainer_recorded_state "$project" "$file" "$ext_namespace")"

  # Fields to compare; scopes only when a dockerfile was supplied; extensions
  # only when manifests are adopted (pre-adoption the array is user-owned).
  local -a tags=("$_DC_DRIFT_TAG_HIDDEN" "$_DC_DRIFT_TAG_NETWORKS" "$_DC_DRIFT_TAG_PORTS")
  [[ -n "$build_dockerfile" ]] && tags=("$_DC_DRIFT_TAG_SCOPES" "${tags[@]}")
  [[ "$manifests_exist" == "true" && -n "$ext_namespace" ]] \
    && tags+=("$_DC_DRIFT_TAG_EXTENSIONS")

  local drifted=0
  local diff_block=""
  local tag="" exp_vals="" rec_vals=""

  for tag in "${tags[@]}"; do
    exp_vals="$(printf '%s\n' "$expected" | awk -F'\t' -v t="$tag" '$1==t {print $2}' | LC_ALL=C sort -u)"
    rec_vals="$(printf '%s\n' "$recorded" | awk -F'\t' -v t="$tag" '$1==t {print $2}' | LC_ALL=C sort -u)"
    if [[ "$exp_vals" != "$rec_vals" ]]; then
      drifted=1
      diff_block+="$(printf '  %-13s recorded %s | current %s\n' \
        "$(_dce_dc_drift_label "$tag"):" "${rec_vals:-(none)}" "${exp_vals:-(none)}")"$'\n'
    fi
  done

  if [[ $drifted -eq 1 ]]; then
    printf "devcontainer.json drift detected (run 'dce config sync-vscode %s'):\n" "$project" >&2
    printf '%s' "$diff_block" >&2
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Build the managed Containerfile path: Containerfiles/Containerfile.base for a
# scope-less project, else Containerfiles/generated/Containerfile.<16hex>.
# Needs global config loaded (for the overlay dirs) when scopes are present.
# -----------------------------------------------------------------------------
dce_devcontainer_build_file() {
  local root_dir="$1"
  local scopes_csv="$2"

  if [[ -z "$scopes_csv" ]]; then
    printf '%s/Containerfiles/Containerfile.base\n' "$root_dir"
    return 0
  fi

  local img=""
  img="$(dce_image_ref_from_scopes "$(dce_team_overlays_dir)" "$(dce_user_overlays_dir)" "$scopes_csv")" || return 1
  local hash=""
  hash="$(dce_image_hash_from_ref "$img")" || return 1
  printf '%s/Containerfiles/generated/Containerfile.%s\n' "$root_dir" "$hash"
}

# Render the runArgs token list (primary first, with optional --ip; then each
# extra as --network). Emits one token per line.
_dce_dc_runargs_tokens() {
  local networks_csv="$1"
  local entry="" name="" ip=""
  local first=true
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == *:* ]]; then
      name="${entry%%:*}"
      ip="${entry#*:}"
    else
      name="$entry"
      ip=""
    fi
    if $first; then
      printf '%s\n%s\n' "--network" "$name"
      [[ -n "$ip" ]] && printf '%s\n%s\n' "--ip" "$ip"
      first=false
    else
      printf '%s\n%s\n' "--network" "$name"
    fi
  done < <(_dce_dc_csv_lines "$networks_csv")
}

# Build a JSON array string from the arguments (each json-escaped). Empty -> [].
_dce_dc_json_string_array() {
  local e esc arr=""
  for e in "$@"; do
    [[ -z "${e:-}" ]] && continue
    esc="$(dce_json_escape "$e")"
    arr+=$(printf '"%s",' "$esc")
  done
  [[ "$arr" == *, ]] && arr="${arr%,}"
  printf '[%s]' "$arr"
}

# Build a JSON array of numbers from the arguments. Non-numeric -> return 1.
_dce_dc_json_number_array() {
  local n arr=""
  for n in "$@"; do
    [[ -z "${n:-}" ]] && continue
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    arr+="$n,"
  done
  [[ "$arr" == *, ]] && arr="${arr%,}"
  printf '[%s]' "$arr"
}

# Full JSON for a from-scratch seed. Byte-compatible with the heredoc `dce new`
# historically emitted, so existing lifecycle assertions still hold.
#
# The optional auth_method argument ("pat"/"ssh"/"none", from
# dce_git_auth_method) controls whether the VS Code git-auth setting is emitted:
# only "pat" needs github.gitAuthentication=false so VS Code's Source Control
# panel defers to git's credential helper (the PAT-backed ~/.git-credentials)
# instead of prompting via the GitHub extension's OAuth flow.
dce_devcontainer_render() {
  local project="$1"
  local build_dockerfile="$2"
  local build_context="$3"
  local secret_dir="$4"
  local hidden_csv="$5"
  local networks_csv="$6"
  local ports_csv="$7"
  local host_tz="$8"
  local auth_method="${9:-}"
  # Optional editor-extensions seeding (plans/extensions.md). ext_namespace is
  # the customizations.<ns> key ("vscode" in v1); extensions_csv is a comma-joined
  # resolved extension-ID set. Both default empty so pre-extensions callers
  # produce byte-identical output.
  local ext_namespace="${10:-}"
  local extensions_csv="${11:-}"

  local forward_ports_block=""
  local -a container_ports=()
  local pm=""
  while IFS= read -r pm; do
    [[ -z "$pm" ]] && continue
    container_ports+=("$(_dce_dc_container_port "$pm")")
  done < <(_dce_dc_csv_lines "$ports_csv")
  if [[ ${#container_ports[@]} -gt 0 ]]; then
    local fp_csv=""
    local first=true
    local p=""
    for p in "${container_ports[@]}"; do
      if $first; then fp_csv+="$p"; first=false; else fp_csv+=", $p"; fi
    done
    forward_ports_block=$',\n  "forwardPorts": ['"$fp_csv"$']'
  fi

  # mounts always present (npmrc bind + one volume per hidden path).
  local -a mounts_entries=()
  mounts_entries+=("source=$secret_dir/.npmrc,target=/home/dev/.npmrc,type=bind,readonly")
  local hp="" hidden_volume=""
  while IFS= read -r hp; do
    [[ -z "$hp" ]] && continue
    hidden_volume="$(dce_hidden_volume_name "$project" "$hp")"
    mounts_entries+=("source=$hidden_volume,target=/workspace/$hp,type=volume")
  done < <(_dce_dc_csv_lines "$hidden_csv")
  local mounts_block=""
  if [[ ${#mounts_entries[@]} -gt 0 ]]; then
    mounts_block=$',\n  "mounts": [\n'
    local first=true
    local me=""
    for me in "${mounts_entries[@]}"; do
      if ! $first; then mounts_block+=$',\n'; fi
      mounts_block+="    \"$me\""
      first=false
    done
    mounts_block+=$'\n  ]'
  fi

  local runargs_block=""
  if [[ -n "$networks_csv" ]]; then
    local -a ra=()
    mapfile -t ra < <(_dce_dc_runargs_tokens "$networks_csv")
    runargs_block=$',\n  "runArgs": ['
    local first=true
    local t=""
    for t in "${ra[@]}"; do
      if $first; then runargs_block+="\"$t\""; first=false; else runargs_block+=", \"$t\""; fi
    done
    runargs_block+="]"
  fi

  local containerenv_block=""
  if [[ -n "$host_tz" ]]; then
    containerenv_block=$',\n  "containerEnv": {\n    "TZ": "'"$host_tz"$'"\n  }'
  fi

  # Only emit the VS Code git-auth override for PAT auth on a provider that
  # ships one. With the PAT in ~/.git-credentials, VS Code's Source Control panel
  # must defer to git's credential helper instead of routing through the hoster
  # extension's OAuth prompt. GitHub is the only v1 provider with such a setting
  # (github.gitAuthentication); gitlab has no equivalent conflict, so its
  # devcontainer.json carries no customizations block. For ssh/none, the VS Code
  # default is left untouched: ssh auth bypasses HTTPS credentials entirely, and
  # "none" benefits from the hoster extension's interactive OAuth as the only
  # available auth path.
  local customizations_block=""
  local dc_provider="" dc_vscode_setting=""
  dc_provider="$(dce_project_git_host)"
  dc_vscode_setting="$(dce_git_host_field "$dc_provider" vscode_setting)"

  # Editor extensions array (resolved set), when an editor namespace + non-empty
  # CSV were supplied. v1 ext_namespace is always "vscode"; extensions share the
  # customizations.vscode object with the git-auth setting. A non-vscode
  # namespace would need its own customizations key (future-editor work).
  local _ext_array=""
  if [[ -n "$ext_namespace" ]] && [[ -n "$extensions_csv" ]]; then
    local -a _ee=()
    local _id
    while IFS= read -r _id; do
      [[ -n "$_id" ]] && _ee+=("$_id")
    done < <(_dce_dc_csv_lines "$extensions_csv")
    if [[ ${#_ee[@]} -gt 0 ]]; then
      _ext_array="$(_dce_dc_json_string_array "${_ee[@]}")"
    fi
  fi

  local _emit_settings=false
  [[ "$auth_method" == "pat" ]] && [[ -n "$dc_vscode_setting" ]] && _emit_settings=true

  if $_emit_settings && [[ -z "$_ext_array" ]]; then
    # Settings only -- byte-identical to the pre-extensions block.
    customizations_block=$',\n  "customizations": {\n    "vscode": {\n      "settings": {\n        "'"$dc_vscode_setting"$'": false\n      }\n    }\n  }'
  elif $_emit_settings && [[ -n "$_ext_array" ]]; then
    # Settings + extensions under customizations.vscode.
    customizations_block=$',\n  "customizations": {\n    "vscode": {\n      "settings": {\n        "'"$dc_vscode_setting"$'": false\n      },\n      "extensions": '"$_ext_array"$'\n    }\n  }'
  elif [[ -n "$_ext_array" ]]; then
    # Extensions only (no PAT git-auth override).
    customizations_block=$',\n  "customizations": {\n    "vscode": {\n      "extensions": '"$_ext_array"$'\n    }\n  }'
  fi

  cat <<EOF
{
  "name": "dce-$project",
  "build": {
    "dockerfile": "$build_dockerfile",
    "context": "$build_context"
  },
  "workspaceMount": "source=\${localWorkspaceFolder},target=/workspace,type=bind",
  "workspaceFolder": "/workspace",
  "remoteUser": "dev",
  "postCreateCommand": "true"$forward_ports_block$mounts_block$runargs_block$containerenv_block$customizations_block
}
EOF
}

# On-demand rewrite of the managed fields, preserving user-authored keys/mounts.
# REQUIRES jq. dry_run="true" previews without writing. Atomic write; preserves
# the original file mode. Returns 0 on success (1 + stderr message on failure).
#
# The auth_method argument ("pat"/"ssh"/"none") controls the managed VS Code
# git-auth setting: "pat" injects customizations.vscode.settings."github.
# gitAuthentication": false (so VS Code uses the PAT-backed credential store);
# any other value removes it so VS Code falls back to its default. User
# customizations (other settings, extensions) are always preserved.
dce_devcontainer_sync() {
  local project="$1"
  local file="$2"
  local build_dockerfile="$3"
  local build_context="$4"
  local secret_dir="$5"
  local hidden_csv="$6"
  local networks_csv="$7"
  local ports_csv="$8"
  local host_tz="$9"
  local dry_run="${10:-false}"
  local auth_method="${11:-}"
  # Optional editor-extensions management (plans/extensions.md):
  #   ext_namespace   customizations.<ns> key ("vscode" in v1)
  #   extensions_csv  comma-joined resolved extension-ID set
  #   manifests_exist "true" when any effective-scope manifest exists for the
  #                   editor (adoption signal). When false, the array is passed
  #                   through untouched (migration guard); when true, the array
  #                   is rewritten to exactly the resolved set (fully-managed).
  local ext_namespace="${12:-}"
  local extensions_csv="${13:-}"
  local manifests_exist="${14:-false}"

  if ! command -v jq >/dev/null 2>&1; then
    printf 'ERROR: sync-vscode requires jq (it is optional everywhere else).\n' >&2
    return 1
  fi
  if [[ ! -f "$file" ]]; then
    printf 'ERROR: devcontainer.json not found: %s\n' "$file" >&2
    return 1
  fi

  # Managed mounts to (re)add. Existing managed mounts are dropped STRUCTURALLY
  # in jq (hidden vols by their dce-hide-<slug>- source; the npmrc bind by its
  # stable /home/dev/.npmrc target), so a stale npmrc path or an old hidden
  # volume is replaced even if its exact source differs from the current one.
  local -a add_mounts=()
  add_mounts+=("source=$secret_dir/.npmrc,target=/home/dev/.npmrc,type=bind,readonly")
  local hp="" hidden_volume=""
  while IFS= read -r hp; do
    [[ -z "$hp" ]] && continue
    hidden_volume="$(dce_hidden_volume_name "$project" "$hp")"
    add_mounts+=("source=$hidden_volume,target=/workspace/$hp,type=volume")
  done < <(_dce_dc_csv_lines "$hidden_csv")
  local slug=""
  slug="$(dce_project_slug "$project")"

  # runArgs tokens + forwardPorts container ports.
  local -a ra_tokens=()
  if [[ -n "$networks_csv" ]]; then
    mapfile -t ra_tokens < <(_dce_dc_runargs_tokens "$networks_csv")
  fi
  local -a container_ports=()
  local pm=""
  while IFS= read -r pm; do
    [[ -z "$pm" ]] && continue
    container_ports+=("$(_dce_dc_container_port "$pm")")
  done < <(_dce_dc_csv_lines "$ports_csv")

  local mounts_json runargs_json ports_json
  mounts_json="$(_dce_dc_json_string_array "${add_mounts[@]}")" || return 1
  runargs_json="$(_dce_dc_json_string_array "${ra_tokens[@]}")" || return 1
  ports_json="$(_dce_dc_json_number_array "${container_ports[@]}")" || {
    printf 'ERROR: forwardPorts contains a non-numeric port.\n' >&2
    return 1
  }

  # Resolved editor-extensions array for the namespace (empty array when no
  # namespace, no CSV, or adoption is off). Passed to jq regardless; the jq
  # program applies it only when $manifests == "true".
  local exts_json="[]"
  if [[ -n "$ext_namespace" ]] && [[ -n "$extensions_csv" ]]; then
    local -a _sx=()
    local _si
    while IFS= read -r _si; do
      [[ -n "$_si" ]] && _sx+=("$_si")
    done < <(_dce_dc_csv_lines "$extensions_csv")
    exts_json="$(_dce_dc_json_string_array "${_sx[@]}")" || exts_json="[]"
  fi
  # Namespace actually managed (empty when no extensions feature is in use).
  local ext_ns_arg="$ext_namespace"

  # Count user top-level keys we will NOT touch (for the summary). Array
  # subtraction is unambiguous: keys minus the managed set.
  local user_keys="0"
  user_keys="$(jq -r '
      (keys - ["name","build","workspaceMount","workspaceFolder","remoteUser",
               "postCreateCommand","forwardPorts","runArgs","mounts","containerEnv",
               "customizations"]
      ) | length' "$file" 2>/dev/null || printf '0')"

  if [[ "$dry_run" == "true" ]]; then
    printf 'Dry run: would rewrite managed fields (build, mounts, runArgs,\n' >&2
    printf 'forwardPorts, containerEnv.TZ, VS Code git-auth) in %s.\n' "$file" >&2
    if [[ "$manifests_exist" == "true" ]]; then
      printf 'Editor extensions: fully-managed (customizations.%s.extensions).\n' "$ext_ns_arg" >&2
    fi
    printf 'Preserved (untouched): %s user top-level key(s) + user mounts.\n' "$user_keys" >&2
    dce_devcontainer_detect_drift "$project" "$file" "$build_dockerfile" \
      "$hidden_csv" "$networks_csv" "$ports_csv" \
      "$ext_ns_arg" "$extensions_csv" "$manifests_exist" >&2 || true
    return 0
  fi

  local orig_mode=""
  orig_mode="$(dce_file_mode_octal "$file" 2>/dev/null || true)"

  local tmp_file=""
  tmp_file="$(mktemp "${file}.tmp.XXXXXX")" || return 1

  local sync_provider="" sync_vscode_setting=""
  sync_provider="$(dce_project_git_host)"
  sync_vscode_setting="$(dce_git_host_field "$sync_provider" vscode_setting)"

  if ! jq \
      --arg name "dce-$project" \
      --arg df "$build_dockerfile" \
      --arg ctx "$build_context" \
      --argjson fports "$ports_json" \
      --argjson add_mounts "$mounts_json" \
      --arg slug "$slug" \
      --argjson runargs "$runargs_json" \
      --arg tz "$host_tz" \
      --arg auth "$auth_method" \
      --arg vsetting "$sync_vscode_setting" \
      --argjson exts "$exts_json" \
      --arg extns "$ext_ns_arg" \
      --arg manifests "$manifests_exist" '
      .name = $name
      | .build = {"dockerfile": $df, "context": $ctx}
      | .workspaceMount = "source=${localWorkspaceFolder},target=/workspace,type=bind"
      | .workspaceFolder = "/workspace"
      | .remoteUser = "dev"
      | .postCreateCommand = "true"
      | .forwardPorts = $fports
      | .runArgs = $runargs
      | .mounts = ( (.mounts // []) | map(
          . as $e
          | ($e | try capture("source=(?<s>[^\",]+)") catch null) as $src
          | ($e | try capture("target=(?<t>[^\",]+)") catch null) as $tgt
          | if ($src // null) != null and ($src.s | startswith("dce-hide-" + $slug + "-")) then empty
            elif ($tgt // null) != null and $tgt.t == "/home/dev/.npmrc" then empty
            else $e end
        ) ) + $add_mounts
      | (if $tz == "" then .
         else (.containerEnv = ((.containerEnv // {}) + {"TZ": $tz})) end)
      | (if $auth == "pat" and $vsetting != "" then
          .customizations = ((.customizations // {})
            | .vscode = ((.vscode // {})
              | .settings = ((.settings // {})
                + {($vsetting): false})))
        elif $vsetting != "" and ((.customizations // {}) | (.vscode.settings // {}) | has($vsetting)) then
          del(.customizations.vscode.settings[$vsetting])
        else . end)
      | (if $manifests == "true" and $extns != "" then
          .customizations = ((.customizations // {})
            | (.[$extns] // {}) as $ns
            | .[$extns] = ($ns + {"extensions": $exts}))
        else . end)
    ' "$file" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    printf 'ERROR: failed to rewrite devcontainer.json (is it valid JSON?).\n' >&2
    return 1
  fi

  chmod "${orig_mode:-600}" "$tmp_file"
  mv "$tmp_file" "$file"

  printf 'Rewrote managed fields in %s (preserved %s user key(s)).\n' "$file" "$user_keys"

  # Best-effort: confirm the file is now in sync.
  if ! dce_devcontainer_detect_drift "$project" "$file" "$build_dockerfile" \
        "$hidden_csv" "$networks_csv" "$ports_csv" \
        "$ext_ns_arg" "$extensions_csv" "$manifests_exist" >/dev/null 2>&1; then
    dce_warn "devcontainer.json still reports drift after sync (please report this bug): $file"
  fi
  return 0
}
