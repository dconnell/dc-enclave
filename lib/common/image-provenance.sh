#!/usr/bin/env bash
# =============================================================================
# lib/common/image-provenance.sh - Image provenance capture (host-side).
#
# Sourced (never executed directly) via lib/common.sh. Best-effort provenance so
# a built dce-img-* image can be traced back to the overlay state (team/user
# git commits + file content fingerprints) that produced it. Detection is
# per-root and independent for team and user: each side always yields a
# content_hash, and additionally yields git commit/dirty/source when its root
# (DC_TEAM_DIR / DC_USER_DIR) is a git checkout. The dirty check is scoped to
# the overlays/ subtree so container-recipes/ edits never contaminate overlay
# provenance. None of these helpers needs a container backend. Depends on
# core.sh (dce_sha256_hex, dce_sha256_file) and scopes.sh (for the dedup
# recomputation in dce_log_provenance).
#
# Named image-provenance.sh (not provenance.sh) to avoid visual collision with
# the unrelated scripts/provenance.sh CLI subcommand.
# =============================================================================

if [[ -n "${_DC_COMMON_IMAGE_PROVENANCE_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_IMAGE_PROVENANCE_SH_LOADED=1

# Escape a string for safe embedding in a JSON string value. Backslash and
# double-quote are escaped; the named control chars use their JSON short forms;
# any other control char (< 0x20) becomes \u00XX. Values fed in here (commit
# SHAs, hex hashes, scope names, ISO timestamps, git remote URLs) are normally
# already clean, so this is defensive -- it keeps provenance.jsonl valid even
# if a future field carries an unusual byte.
dce_json_escape() {
  local s="$1"
  local out=""
  local i ch ord code

  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    case "$ch" in
      \\) out+=$'\\\\' ;;
      '"')  out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      $'\b') out+='\b' ;;
      $'\f') out+='\f' ;;
      *)
        ord=$(printf '%d' "'$ch" 2>/dev/null || printf '64')
        if (( ord < 32 )); then
          printf -v code '%04x' "$ord"
          out+="\\u$code"
        else
          out+="$ch"
        fi
        ;;
    esac
  done

  printf '%s' "$out"
}

# Reduce a value to the safe subset for a Dockerfile LABEL double-quoted value.
# Dockerfile label values would otherwise interpret `"` (ends the string), `\`
# (escape), and `$` (ARG/ENV expansion); backtick is stripped defensively too.
# Control chars are removed. Our values are inherently safe, so this is a guard
# against surprises (e.g. an exotic git remote URL). Stripping (not escaping)
# keeps the label inert without depending on Dockerfile escape quirks.
dce_label_scrub() {
  local s="$1"
  local out=""
  local i ch ord

  for ((i = 0; i < ${#s}; i++)); do
    ch="${s:i:1}"
    # shellcheck disable=SC1003
    # '\' is a literal single-backslash comparison (valid in single quotes).
    if [[ "$ch" == '"' || "$ch" == '\' || "$ch" == '$' || "$ch" == '`' ]]; then
      continue
    fi
    ord=$(printf '%d' "'$ch" 2>/dev/null || printf '64')
    (( ord < 32 )) && continue
    out+="$ch"
  done

  printf '%s' "$out"
}

# Per-side content fingerprint for a set of EFFECTIVE scopes. Iterates the
# canonical order (all first, then listed scopes -- exactly what composes) and,
# for each existing fragment under $overlays_dir (the resolved leaf overlays/
# directory of one root), folds "v1|<scope>|<sha256(file bytes)>" into the hash
# input. Returns empty when the side contributes no fragment for these scopes
# (e.g. that side has no Containerfile.<scope>). The 12-hex truncation matches
# the label contract; the per-fragment "v1" prefix leaves room to evolve the
# scheme.
dce_provenance_content_hash() {
  local overlays_dir="$1"
  local effective_scopes_csv="$2"

  local acc=""
  local scope="" file=""
  local -a scopes=()
  [[ -n "$effective_scopes_csv" ]] && IFS=',' read -r -a scopes <<< "$effective_scopes_csv"

  for scope in "${scopes[@]}"; do
    [[ -n "$scope" ]] || continue
    file="$overlays_dir/Containerfile.$scope"
    [[ -f "$file" ]] || continue
    acc+="v1|$scope|$(dce_sha256_file "$file")|"
  done

  [[ -n "$acc" ]] || return 0
  local hash=""
  hash="$(dce_sha256_hex "$acc")"
  printf '%s\n' "${hash:0:12}"
}

# Fold both namespaces' per-side fingerprints into one full (64-hex) hash. Used
# as the stable, always-present combined identifier (label content.hash and the
# JSONL dedup key). Order is fixed (team then user) so the result is stable.
dce_provenance_combined_hash() {
  local team_hash="$1"
  local user_hash="$2"

  dce_sha256_hex "v1|${team_hash}|${user_hash}"
}

# Git HEAD full SHA of $dir, or empty when $dir is not a git checkout. Always
# exits 0 (best-effort: provenance never fails a build). The FULL sha (not the
# abbreviated form) is stored so the log/labels hold the canonical identifier --
# short shas are a display concern, handled at read time.
dce_provenance_git_commit() {
  local dir="$1"

  [[ -d "$dir" ]] || { printf ''; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return 0; }
  git -C "$dir" rev-parse HEAD 2>/dev/null || printf ''
}

# "true" / "false" when $dir is a git checkout (any tracked change, staged
# change, or untracked file vs HEAD counts as dirty), or empty when not under
# git. Uses `git status --porcelain` so an untracked new Containerfile.<scope>
# is also flagged (its bytes already changed the content_hash; this mirrors
# that as a human-readable warning).
#
# An optional second argument is a pathspec limiting the dirty check to that
# subtree. Each root now holds both overlays/ and container-recipes/, so image
# provenance passes "overlays" so a recipe-only edit does not mark overlay
# provenance dirty. Empty/omitted pathspec checks the whole work tree.
dce_provenance_git_dirty() {
  local dir="$1"
  local pathspec="${2:-}"

  [[ -d "$dir" ]] || { printf ''; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return 0; }
  local status_out
  if [[ -n "$pathspec" ]]; then
    status_out="$(git -C "$dir" status --porcelain -- "$pathspec" 2>/dev/null)"
  else
    status_out="$(git -C "$dir" status --porcelain 2>/dev/null)"
  fi
  if [[ -n "$status_out" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# Redact credential material (the userinfo segment) from a git remote URL while
# preserving the non-secret parts (scheme, host, path) so provenance stays
# useful for traceability. This is the single chokepoint called by
# dce_provenance_git_source, so both provenance consumers (the JSONL log and
# the composed image LABELs) get the redacted value.
#
# Behavior:
#   https://token@host/p        -> https://host/p
#   https://user:pass@host/p    -> https://host/p
#   ssh://git@host[:port]/p     -> ssh://host[:port]/p   (git@ is the ssh user,
#                                                     not a secret; dropped for noise)
#   git@host:path.git           -> git@host:path.git     (SCP-like SSH form
#                                                     carries no secret; untouched)
#   bare scheme://host/...      -> unchanged
#   malformed / unrecognized    -> ""                    (fail closed: record
#                                                     nothing rather than risk a
#                                                     credential)
#
# Pure bash string handling (no sed -E / external deps) for portability.
dce_redact_remote_url() {
  local url="$1"

  [[ -n "$url" ]] || { printf ''; return 0; }

  # scheme://authority[/path] form (https, ssh, git, http, file, ...).
  if [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://(.*)$ ]]; then
    local scheme="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    local authority="" path=""
    # Split authority from path at the first '/'.
    if [[ "$rest" == */* ]]; then
      authority="${rest%%/*}"
      path="/${rest#*/}"
    else
      authority="$rest"
      path=""
    fi
    # Strip userinfo: drop everything up to and including the LAST '@' so a
    # deceptive "evil@user:pass@host" cannot smuggle a credential past us.
    if [[ "$authority" == *@* ]]; then
      authority="${authority##*@}"
    fi
    printf '%s' "${scheme}://${authority}${path}"
    return 0
  fi

  # SCP-like SSH form: [user@]host:path. The segment before '@' is the ssh
  # login (conventionally 'git'), not a credential, so it carries no secret and
  # is returned untouched.
  if [[ "$url" == *@*:* ]]; then
    printf '%s' "$url"
    return 0
  fi

  # Unrecognized / malformed: fail closed (no scheme to anchor on, so there is
  # no safe way to guarantee a credential is not embedded).
  printf ''
}

# configured remote.origin.url for $dir, or empty when not under git / no remote.
# The raw URL is passed through dce_redact_remote_url so embedded credentials
# (token@ / user:pass@) never reach the provenance log or image labels.
dce_provenance_git_source() {
  local dir="$1"
  local raw=""

  [[ -d "$dir" ]] || { printf ''; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf ''; return 0; }
  raw="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
  dce_redact_remote_url "$raw"
}

# Render a scopes CSV as a JSON array string, e.g. ["nodejs","golang"] / [].
# Each element is JSON-escaped (scope names are charset-restricted, but escape
# anyway so the output is always valid JSON).
dce_provenance_scopes_json() {
  local csv="$1"
  local out="[" first=1 scope=""
  local -a scopes=()
  [[ -n "$csv" ]] && IFS=',' read -r -a scopes <<< "$csv"

  for scope in "${scopes[@]}"; do
    [[ -n "$scope" ]] || continue
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="\"$(dce_json_escape "$scope")\""
  done

  out+="]"
  printf '%s' "$out"
}

# Path to a project's provenance log.
dce_provenance_log_path() {
  printf '%s/.config/dce-enclave/%s/provenance.jsonl\n' "$HOME" "$1"
}

# Append one provenance entry to the project's JSONL log, deduping on change.
#
# Recomputes the overlay-derived values from the team/user roots ($team_root,
# $user_root -- DC_TEAM_DIR/DC_USER_DIR) + $scopes_csv (the same source of truth
# compose-containerfile.sh uses for the image labels) and merges in $base_id
# (the caller-supplied local dce-base image Id) plus the build timestamp. Dedup
# key is (combined content_hash, base id): every overlay byte and scope is
# already encoded in content_hash, and base id covers a base rebuild, so the two
# together uniquely identify an image state. If the last logged line matches,
# the append is skipped (no churn from no-op rebuilds or rebuild-container). The
# file is created owner-only (chmod 600), matching the security posture of the
# project config.
#
# Provenance signals stay overlay-scoped even though each root now also holds
# container-recipes/: the content hash is computed from overlays/ fragments
# only, git_commit is the repo HEAD, and git_dirty uses an "overlays" pathspec
# so a recipe-only edit does not contaminate overlay provenance.
dce_log_provenance() {
  local project="$1"
  local image_ref="$2"
  local action="$3"
  local team_root="$4"
  local user_root="$5"
  local scopes_csv="$6"
  local base_id="$7"

  local team_od="" user_od=""
  team_od="$team_root/overlays"
  user_od="$user_root/overlays"

  local eff=""
  eff="$(dce_effective_scopes_csv "$team_od" "$user_od" "$scopes_csv" 2>/dev/null || true)"

  local team_ch="" user_ch="" combined=""
  team_ch="$(dce_provenance_content_hash "$team_od" "$eff")"
  user_ch="$(dce_provenance_content_hash "$user_od" "$eff")"
  combined="$(dce_provenance_combined_hash "$team_ch" "$user_ch")"

  local team_commit="" team_dirty="" team_source=""
  local user_commit="" user_dirty="" user_source=""
  team_commit="$(dce_provenance_git_commit "$team_root")"
  team_dirty="$(dce_provenance_git_dirty "$team_root" overlays)"
  team_source="$(dce_provenance_git_source "$team_root")"
  user_commit="$(dce_provenance_git_commit "$user_root")"
  user_dirty="$(dce_provenance_git_dirty "$user_root" overlays)"
  user_source="$(dce_provenance_git_source "$user_root")"

  # dirty is a bare JSON boolean when under git, else an empty JSON string.
  local tdj="" udj=""
  if [[ "$team_dirty" == "true" || "$team_dirty" == "false" ]]; then tdj="$team_dirty"; else tdj='""'; fi
  if [[ "$user_dirty" == "true" || "$user_dirty" == "false" ]]; then udj="$user_dirty"; else udj='""'; fi

  local now=""
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local team_obj="" user_obj="" base_obj="" scopes_json=""
  team_obj="{\"content_hash\":\"$(dce_json_escape "$team_ch")\",\"git_commit\":\"$(dce_json_escape "$team_commit")\",\"git_dirty\":$tdj,\"source\":\"$(dce_json_escape "$team_source")\"}"
  user_obj="{\"content_hash\":\"$(dce_json_escape "$user_ch")\",\"git_commit\":\"$(dce_json_escape "$user_commit")\",\"git_dirty\":$udj,\"source\":\"$(dce_json_escape "$user_source")\"}"
  base_obj="{\"image\":\"dce-base:latest\",\"id\":\"$(dce_json_escape "$base_id")\"}"
  scopes_json="$(dce_provenance_scopes_json "$eff")"

  # Compact JSONL; content_hash is emitted last so dedup can find it via tail.
  local line=""
  line="{\"ts\":\"$(dce_json_escape "$now")\",\"action\":\"$(dce_json_escape "$action")\",\"image_ref\":\"$(dce_json_escape "$image_ref")\",\"scopes\":$scopes_json,\"dc_version\":\"$(dce_json_escape "$DC_VERSION")\",\"base\":$base_obj,\"team\":$team_obj,\"user\":$user_obj,\"content_hash\":\"$(dce_json_escape "$combined")\"}"

  local log_path=""
  log_path="$(dce_provenance_log_path "$project")"

  # Dedup against the last logged line on (content_hash, base id).
  local last=""
  [[ -f "$log_path" ]] && last="$(tail -n1 "$log_path" 2>/dev/null || true)"
  if [[ -n "$last" ]]; then
    local last_ch="" last_base="" cur_ch="" cur_base=""
    last_ch="$(printf '%s' "$last" | grep -oE '"content_hash":"[^"]*"' | tail -n1 || true)"
    last_base="$(printf '%s' "$last" | grep -oE '"id":"[^"]*"' | head -n1 || true)"
    cur_ch="\"content_hash\":\"$(dce_json_escape "$combined")\""
    cur_base="\"id\":\"$(dce_json_escape "$base_id")\""
    if [[ -n "$last_ch" && "$last_ch" == "$cur_ch" && "$last_base" == "$cur_base" ]]; then
      return 0
    fi
  fi

  mkdir -p "$(dirname "$log_path")"
  printf '%s\n' "$line" >> "$log_path"
  chmod 600 "$log_path"
}
