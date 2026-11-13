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
# This module also hosts the DC-EMBED directive helpers
# (dce_embed_line_is_directive / dce_embed_src_is_safe /
# dce_embed_directive_args / dce_embed_src_within_dir): the single source of
# truth for the directive's line syntax and path-safety rules (textual and
# symlink resolution), shared by the v2 content hash here and the compose-time
# rewrite in scripts/compose-containerfile.sh. The fragment-walking heredoc
# tracker (dce_embed_heredoc_*) and the FROM/CMD/ENTRYPOINT strip rule
# (dce_fragment_line_is_stripped) live here too, so every fragment scanner --
# the v2 content hash below and compose's emitter/validator -- classifies
# lines identically.
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

# ---------------------------------------------------------------------------
# DC-EMBED directive helpers.
#
# An overlay fragment may carry comment lines of the form
#   # DC-EMBED: <src> <dest> [mode]
# which scripts/compose-containerfile.sh rewrites into a self-contained RUN
# that decodes a gzip+base64 blob into <dest> (see docs/reference/overlays.md).
# The provenance hash must fold the bytes of every referenced <src> (the v2
# scheme below), or editing an embedded file would leave the fingerprint (and
# thus the image tag/labels) unchanged and a rebuild would reuse a stale
# image. These three helpers are the single source of truth for the directive
# syntax and path-safety rule, used by both this module and compose.
# ---------------------------------------------------------------------------

# Whether $1 is a DC-EMBED directive line. Sets BASH_REMATCH[1] to the
# directive's argument portion ("<src> <dest> [mode>") when it returns 0.
dce_embed_line_is_directive() {
  local line="$1"
  [[ "$line" =~ ^[[:space:]]*#[[:space:]]*DC-EMBED:[[:space:]]*(.*)$ ]]
}

# Whether $1 is a valid <src> for a DC-EMBED directive: non-empty, relative
# (no leading /), and free of `..` path components, so it cannot escape the
# fragment's overlays directory. Shared by compose validation and the v2
# content hash so both agree on which sources are in scope.
dce_embed_src_is_safe() {
  local src="$1"
  [[ -n "$src" && "$src" != /* ]] || return 1

  local -a comps=()
  local IFS='/'
  read -r -a comps <<< "$src"
  local comp=""
  for comp in "${comps[@]}"; do
    if [[ "$comp" == ".." ]]; then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Heredoc-body tracking + FROM/CMD/ENTRYPOINT strip rule for fragment walks.
#
# Every consumer that walks an overlay fragment line by line must classify
# lines identically or a fragment could compose differently than it hashes:
# compose-containerfile.sh copies heredoc bodies byte-for-byte (a
# '#'/FROM/CMD/ENTRYPOINT there is script data, not Containerfile syntax) and
# never rewrites a directive inside one, and the v2 content hash must fold
# only the directives compose would actually rewrite. So the heredoc tracker
# and the strip rule live here, and both walkers call exactly these helpers.
#
# A body opens on a line containing `<<`, an optional `-`, optional
# whitespace, then a delimiter that is single-quoted, double-quoted, or bare
# and drawn from [A-Za-z0-9._-] (covering legal shell delimiters beyond the
# obvious word forms, e.g. EOF.V2 or EOF-2). The LAST opener on a line wins
# (`cat <<A <<B` waits for B). A body ends at the delimiter alone on a line;
# leading whitespace counts only for the `<<-` form. Known limitation
# (adequate for real fragments): a `<<<` here-string or a bit-shift like
# `$((1<<2))` can be misread as an opener -- compose warns (non-fatally) when
# a body reaches fragment end unclosed, which surfaces such false openers.
# ---------------------------------------------------------------------------

# Heredoc opener regex: `<<`, optional `-`, optional whitespace, then an
# optionally quoted delimiter from [A-Za-z0-9._-] (groups: 1 = `-` flag,
# 3/4/5 = quoted/bare delimiter).
declare -r DC_EMBED_HD_OPEN_RE="<<(-)?[[:space:]]*(\"([A-Za-z0-9._-]+)\"|'([A-Za-z0-9._-]+)'|([A-Za-z0-9._-]+))"

# Tracking state (module globals; fragment walks are strictly sequential).
DCE_HD_OPEN=0    # 1 while inside a heredoc body
DCE_HD_INDENT=0  # opener used `<<-`: indented terminator tolerated
DCE_HD_DELIM=""  # delimiter of the tracked (last) heredoc on a line

# Reset heredoc tracking state before walking a fresh fragment.
dce_embed_heredoc_reset() {
  DCE_HD_OPEN=0
  DCE_HD_INDENT=0
  DCE_HD_DELIM=""
}

# Feed one line that is NOT inside a heredoc body to the tracker. Scans to the
# end of the line so the last opener wins when several share a line.
dce_embed_heredoc_track() {
  local scan="$1"
  while [[ "$scan" =~ $DC_EMBED_HD_OPEN_RE ]]; do
    DCE_HD_INDENT=0
    [[ "${BASH_REMATCH[1]}" == "-" ]] && DCE_HD_INDENT=1
    DCE_HD_DELIM="${BASH_REMATCH[3]:-${BASH_REMATCH[4]:-${BASH_REMATCH[5]}}}"
    DCE_HD_OPEN=1
    scan="${scan#*"${BASH_REMATCH[0]}"}"
  done
}

# Whether $1 terminates the currently tracked heredoc: the delimiter alone,
# or (only after a `<<-` opener) the delimiter following leading whitespace.
# Both comparisons are literal -- the delimiter is data, never a pattern --
# so a delimiter like EOF.V2 cannot be mis-matched as a regex would.
dce_embed_heredoc_terminator() {
  [[ "$1" == "$DCE_HD_DELIM" ]] && return 0
  (( DCE_HD_INDENT )) || return 1
  [[ "$1" =~ ^[[:space:]]+([A-Za-z0-9._-]+)$ && "${BASH_REMATCH[1]}" == "$DCE_HD_DELIM" ]]
}

# Whether $1 (a fragment line) is stripped from fragment content: FROM on the
# fragment's very first line, or any CMD/ENTRYPOINT line. Matching is the
# first whitespace-separated word, case-insensitive, with leading whitespace
# ignored -- the awk pre-pass semantics (`NR == 1 && toupper($1) == "FROM"`,
# `toupper($1) == "CMD"`, ...) that this walker replaces. The rule applies
# ONLY outside heredoc bodies; callers must check DCE_HD_OPEN first. Compose
# drops such lines; directive scanners skip them (and their heredoc openers)
# to mirror compose exactly -- e.g. `CMD cat <<'EOF'` must not open a body
# for a scanner when compose never sees that `<<` (the CMD line is stripped).
dce_fragment_line_is_stripped() {
  local line="$1"
  local lineno="$2"
  local -a words=()

  read -r -a words <<< "$line"
  (( ${#words[@]} > 0 )) || return 1
  case "${words[0]}" in
    [Ff][Rr][Oo][Mm])
      (( lineno == 1 )) || return 1
      return 0
      ;;
    [Cc][Mm][Dd] | [Ee][Nn][Tt][Rr][Yy][Pp][Oo][Ii][Nn][Tt])
      return 0
      ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Symlink-containment helpers for DC-EMBED <src> paths.
# ---------------------------------------------------------------------------

# Resolve a path to its physical absolute location (portable macOS/Linux: no
# realpath / `readlink -f` dependency). Every directory component is resolved
# via `cd` + `pwd -P`, and a symlinked final component is followed repeatedly,
# so chained links, relative link targets, and `..` targets are all resolved
# physically. Prints the resolved path; returns non-zero when the path cannot
# be resolved (missing parent, dangling link) or a link loop is hit (bounded,
# so `ln -s a a` cannot hang the caller).
dce_path_resolve_physical() {
  local path="$1"
  local dir="" base="" target=""
  local hops=0

  case "$path" in
    /*) : ;;
    *) path="$PWD/$path" ;;
  esac

  while :; do
    hops=$((hops + 1))
    if (( hops > 40 )); then
      return 1
    fi
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    if ! dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
      return 1
    fi
    if [[ ! -e "$dir/$base" && ! -L "$dir/$base" ]]; then
      return 1
    fi
    if [[ ! -L "$dir/$base" ]]; then
      printf '%s/%s\n' "$dir" "$base"
      return 0
    fi
    target="$(readlink "$dir/$base")"
    case "$target" in
      /*) path="$target" ;;
      *) path="$dir/$target" ;;
    esac
  done
}

# Whether the DC-EMBED <src> $2, resolved physically (all symlinks followed),
# lands inside directory $1. Complements the textual dce_embed_src_is_safe
# rule, which cannot see a symlinked files/ entry pointing outside the
# overlays dir. Compose calls this at validate time and dies when it fails,
# so an escaping overlay can never reach the composed file.
dce_embed_src_within_dir() {
  local overlays_dir="$1"
  local src="$2"
  local resolved_dir="" resolved_src=""

  if ! resolved_dir="$(cd "$overlays_dir" 2>/dev/null && pwd -P)"; then
    return 1
  fi
  if ! resolved_src="$(dce_path_resolve_physical "$overlays_dir/$src")"; then
    return 1
  fi
  [[ "$resolved_src" == "$resolved_dir"/* ]]
}

# Print the raw argument portion of every DC-EMBED directive in $1, one per
# line, in file order. Lenient by design: lines that merely look like
# directives are surfaced; the caller decides whether to validate strictly
# (compose-containerfile.sh, which dies) or skip best-effort
# (dce_provenance_content_hash, which must never fail a build).
#
# Heredoc-aware, and mirroring compose's emit_fragment line classification
# exactly (body -> strip rule -> directive -> comment/blank -> opener
# tracking, via the same shared helpers): a directive-looking line inside a
# heredoc body is script data that compose copies verbatim and never
# rewrites, so it is not surfaced -- folding its source into the content hash
# would make the fingerprint react to bytes that never reach the image as an
# embed.
dce_embed_directive_args() {
  local fragment="$1"
  local line=""
  local lineno=0
  dce_embed_heredoc_reset
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if (( DCE_HD_OPEN )); then
      dce_embed_heredoc_terminator "$line" && DCE_HD_OPEN=0
      continue
    fi
    if dce_fragment_line_is_stripped "$line" "$lineno"; then
      continue
    fi
    if dce_embed_line_is_directive "$line"; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      continue
    fi
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    dce_embed_heredoc_track "$line"
  done < "$fragment"
}

# Per-side content fingerprint for a set of EFFECTIVE scopes. Iterates the
# canonical order (all first, then listed scopes -- exactly what composes) and,
# for each existing fragment under $overlays_dir (the resolved leaf overlays/
# directory of one root), folds "v2|<scope>|<sha256(file bytes)>" into the hash
# input.
#
# The v2 scheme additionally folds every DC-EMBED source the fragment
# references, as "embed:<src>|<sha256(src bytes)>": the directive embeds the
# file's bytes into the image, so editing that source without touching the
# fragment must still change the fingerprint, or a rebuild would reuse a stale
# image whose embedded copy predates the edit. The prefix was bumped v1 -> v2
# because the input scheme changed (and old fingerprints must not collide with
# new ones). Sources are resolved relative to $overlays_dir and folded only
# when they are safe (dce_embed_src_is_safe) and exist -- lenient by design,
# since an invalid directive is a compose-time fatal error and provenance must
# never fail a build. Directives are surfaced heredoc-aware
# (dce_embed_directive_args), so only directives compose actually rewrites are
# folded.
#
# Returns empty when the side contributes no fragment for these scopes (e.g.
# that side has no Containerfile.<scope>). The 12-hex truncation matches the
# label contract; the per-fragment version prefix leaves room to evolve the
# scheme further.
dce_provenance_content_hash() {
  local overlays_dir="$1"
  local effective_scopes_csv="$2"

  local acc=""
  local scope="" file="" args="" src="" src_path=""
  local -a scopes=()
  [[ -n "$effective_scopes_csv" ]] && IFS=',' read -r -a scopes <<< "$effective_scopes_csv"

  for scope in "${scopes[@]}"; do
    [[ -n "$scope" ]] || continue
    file="$overlays_dir/Containerfile.$scope"
    [[ -f "$file" ]] || continue
    acc+="v2|$scope|$(dce_sha256_file "$file")|"
    # Fold each DC-EMBED source the fragment references (file order). Skip --
    # never fail -- on anything unusable: see the doc comment above.
    while IFS= read -r args || [[ -n "$args" ]]; do
      src="${args%%[[:space:]]*}"
      [[ -n "$src" ]] || continue
      if ! dce_embed_src_is_safe "$src"; then
        continue
      fi
      src_path="$overlays_dir/$src"
      [[ -f "$src_path" ]] || continue
      acc+="embed:$src|$(dce_sha256_file "$src_path")|"
    done < <(dce_embed_directive_args "$file")
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
  printf '%s/provenance.jsonl\n' "$(dce_project_dir "$1")"
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
