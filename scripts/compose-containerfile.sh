#!/usr/bin/env bash
# =============================================================================
# scripts/compose-containerfile.sh - Compose base image + overlay scopes into
# one generated Containerfile for a derived (dce-img-<hash>) image.
#
# This implements the layering contract: team/all, user/all, then team/<scope>,
# user/<scope> for each requested scope, in that fixed order. FROM (first
# line), CMD, and ENTRYPOINT from overlay fragments are stripped (the composed
# file owns the base image, the final CMD, and a single chained ENTRYPOINT) --
# but only on content lines, never inside heredoc bodies, where those words
# are script data and survive byte-for-byte; COPY/ADD are rejected (overlays
# must not couple to an external build context).
#
# DC-EMBED: an overlay fragment comment line of the form
#
#   # DC-EMBED: <src> <dest> [mode]
#
# is rewritten at compose time into a self-contained RUN that decodes the
# gzip+base64-compressed <src> (resolved relative to the fragment's own
# overlays/ directory) into the absolute <dest> inside the image and chmods it.
# This lets overlays ship scripts without inlining them as readable text
# (apple/container caps a composed Dockerfile at 16,384 bytes) and without
# COPY/ADD (which stay banned). Encoding is deterministic (gzip -n, single-line
# base64), so composing twice yields a byte-identical file and nothing
# generated is ever committed -- the readable files/ source stays the single
# source of truth. Editing an embedded source also changes the provenance
# content hash (the v2 scheme in lib/common/image-provenance.sh), so a rebuild
# never reuses a stale image.
#
# The composed file is a machine artifact: comment lines and blank/whitespace
# lines in overlay fragments are stripped at emit time (the overlay sources
# stay fully readable) to help stay under apple/container's 16,384-byte cap.
# Heredoc bodies are exempt -- a '#' there is script content, not a
# Containerfile comment -- and compose's own output (markers, LABELs, the
# entrypoint runner) is emitted verbatim.
# =============================================================================
set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

usage() {
  echo "Usage: compose-containerfile.sh <output-file> <overlay-scopes-csv>"
}

# Parse flags (--help/-h, and reject unknown flags). No real options today.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      dce_die "Unknown flag for compose-containerfile.sh: $1"
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

OUTPUT_FILE_RAW="$1"
SCOPE_INPUT="$2"

if [[ "$OUTPUT_FILE_RAW" == /* ]]; then
  OUTPUT_FILE="$OUTPUT_FILE_RAW"
else
  OUTPUT_FILE="$PWD/$OUTPUT_FILE_RAW"
fi

OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -P "$OUTPUT_DIR" && pwd)"
OUTPUT_FILE="$OUTPUT_DIR/$(basename "$OUTPUT_FILE")"

# Encode one file for embedding: gzip without timestamp/name header fields
# (-n, so two runs compress identically), then base64 flattened to a single
# line so GNU (76-column wrap) and BSD (no wrap) encoders cannot produce
# different composed files. Output is pure [A-Za-z0-9+/=].
encode_embed_blob() {
  local src="$1"
  gzip -n < "$src" | base64 | tr -d '\n'
}

# Parsed fields of the DC-EMBED directive currently being processed. Set by
# parse_embed_args; consumed by its caller (globals, not stdout, so a dce_die
# inside the parser cannot be silently swallowed by a command substitution).
EMBED_SRC=""
EMBED_DEST=""
EMBED_MODE=""

# Parse the argument portion ("<src> <dest> [mode]") of one DC-EMBED directive
# into EMBED_SRC / EMBED_DEST / EMBED_MODE. $2 is the fragment path (error
# messages only). Dies naming the fragment and the offending value when the
# directive violates the contract:
#   - exactly 2 or 3 whitespace-separated fields
#   - <src>  relative (no leading /) with no `..` component
#     (dce_embed_src_is_safe, lib/common/image-provenance.sh)
#   - <dest> absolute (leading /) and restricted to [A-Za-z0-9._/@+-], since
#     <dest> is interpolated verbatim into the emitted RUN command
#   - [mode] 3-4 octal digits; default 0644
#   - <overlays-dir>/<src> must exist as a regular file and must still resolve
#     (all symlinks followed) to a path inside the overlays dir, so a symlinked
#     files/ entry cannot smuggle in bytes from outside
parse_embed_args() {
  local fragment_file="$1"
  local args="$2"
  local overlays_dir=""
  local -a fields=()

  EMBED_SRC=""
  EMBED_DEST=""
  EMBED_MODE=""

  read -r -a fields <<< "$args"
  if (( ${#fields[@]} < 2 || ${#fields[@]} > 3 )); then
    dce_die "Invalid DC-EMBED directive in $fragment_file: '$args'
Expected: # DC-EMBED: <src> <dest> [mode]"
  fi

  EMBED_SRC="${fields[0]}"
  EMBED_DEST="${fields[1]}"
  EMBED_MODE="${fields[2]:-0644}"

  if ! dce_embed_src_is_safe "$EMBED_SRC"; then
    dce_die "Invalid DC-EMBED directive in $fragment_file: src '$EMBED_SRC' must be relative to the overlays dir and must not contain '..' components"
  fi

  if [[ "$EMBED_DEST" != /* ]]; then
    dce_die "Invalid DC-EMBED directive in $fragment_file: dest '$EMBED_DEST' must be an absolute path inside the image"
  fi
  if [[ ! "$EMBED_DEST" =~ ^[A-Za-z0-9._/@+-]+$ ]]; then
    dce_die "Invalid DC-EMBED directive in $fragment_file: dest '$EMBED_DEST' contains characters that are not safe in a RUN command (allowed: letters, digits, . _ / @ + -)"
  fi

  if [[ ! "$EMBED_MODE" =~ ^[0-7]{3,4}$ ]]; then
    dce_die "Invalid DC-EMBED directive in $fragment_file: mode '$EMBED_MODE' must be 3-4 octal digits (e.g. 0755)"
  fi

  overlays_dir="$(dirname "$fragment_file")"
  if [[ ! -f "$overlays_dir/$EMBED_SRC" ]]; then
    dce_die "Invalid DC-EMBED directive in $fragment_file: embedded source '$overlays_dir/$EMBED_SRC' does not exist"
  fi

  # Symlink containment: dce_embed_src_is_safe is textual, so a symlinked
  # files/ entry whose target lives outside the overlays dir would pass it.
  # Resolve the source physically (all symlinks followed) and require it to
  # stay inside. Fatal here, and this function runs at validate time (before
  # the composed file is opened for writing) as well as at emit time.
  if ! dce_embed_src_within_dir "$overlays_dir" "$EMBED_SRC"; then
    dce_die "Invalid DC-EMBED directive in $fragment_file: src '$EMBED_SRC' resolves (following symlinks) outside the overlays dir '$overlays_dir'
Embedded sources must live inside the fragment's own overlays directory."
  fi
}

# Rewrite one DC-EMBED directive line into its marker comment + RUN pair.
# validate_overlay_file has already vetted the directive, but this re-parses
# with the same function so emission cannot drift from validation.
emit_embed_run() {
  local overlays_dir="$1"
  local fragment_file="$2"
  local args="$3"

  parse_embed_args "$fragment_file" "$args"
  local blob=""
  blob="$(encode_embed_blob "$overlays_dir/$EMBED_SRC")"
  printf '# DC-EMBED %s -> %s (compressed; source: %s/%s)\n' \
    "$EMBED_SRC" "$EMBED_DEST" "$overlays_dir" "$EMBED_SRC"
  printf "RUN printf '%%s' '%s' | base64 -d | gunzip > %s && chmod %s %s\n" \
    "$blob" "$EMBED_DEST" "$EMBED_MODE" "$EMBED_DEST"
}

# Emit one overlay fragment into the composed file with begin/end markers.
# Strips a leading FROM (we always build FROM dce-base) plus any CMD and
# ENTRYPOINT lines: the composed file owns one CMD and one chained ENTRYPOINT,
# so per-fragment ENTRYPOINTs would otherwise collide -- Docker keeps only the
# last in a stage, silently dropping the other ecosystems' sync hooks. The
# strip rule (dce_fragment_line_is_stripped, lib/common/image-provenance.sh)
# applies only to content lines -- never inside a heredoc body, where a
# FROM/CMD/ENTRYPOINT-looking line is script data and must survive verbatim.
#
# The composed file is a machine artifact, so fragment content is minified on
# the way out: comment lines (`^[[:space:]]*#`) and blank/whitespace-only
# lines are dropped, keeping the readable fragment as the single source of
# truth. Heredoc bodies are exempt and are copied byte-for-byte, because a
# '#' there is script content: a line containing `<<` (optional `-`, then an
# optionally quoted word delimiter) opens one, and stripping resumes after
# the terminator line (the delimiter alone; leading whitespace is tolerated
# only for `<<-`). Known limitations, adequate for real fragments: only the
# LAST heredoc opened on a line is tracked (`cat <<A <<B` waits for B), and a
# `<<<` here-string or a bit-shift (`$((1<<2))`) can be misread as an opener;
# a body still open at fragment end draws a non-fatal WARN naming the
# fragment and delimiter, which surfaces typos and such false openers.
#
# DC-EMBED directive comment lines are rewritten in place into their encoded
# marker + RUN form (see header). Directives are detected before stripping,
# so the emitted marker + RUN pair always survives; it is compose's own
# output, never re-read for minification. The FROM/CMD/ENTRYPOINT strip lives
# inside this heredoc-aware walker (it used to be an awk pre-pass over the
# raw fragment, which would silently delete such lines from heredoc bodies);
# the gzip/base64 encoding cannot happen inside awk anyway, so one walker
# does strip, rewrite, and minify over a single read of the fragment.
emit_fragment() {
  local fragment_file="$1"
  local label="$2"
  local overlays_dir=""
  overlays_dir="$(dirname "$fragment_file")"

  echo ""
  echo "# --- begin $label ---"
  local line=""
  local frag_lineno=0
  dce_embed_heredoc_reset
  # SC2094 false positive: emit_embed_run (via parse_embed_args) only reads
  # the fragment to encode embedded sources; it never writes the fragment
  # being read here.
  # shellcheck disable=SC2094
  while IFS= read -r line || [[ -n "$line" ]]; do
    frag_lineno=$((frag_lineno + 1))
    if (( DCE_HD_OPEN )); then
      printf '%s\n' "$line"
      if dce_embed_heredoc_terminator "$line"; then
        DCE_HD_OPEN=0
      fi
      continue
    fi
    # FROM (first line only) / CMD / ENTRYPOINT strip: content lines only.
    if dce_fragment_line_is_stripped "$line" "$frag_lineno"; then
      continue
    fi
    # Directives are comment lines syntactically, so the rewriter must see
    # them before the comment strip or they would be dropped unread.
    if dce_embed_line_is_directive "$line"; then
      emit_embed_run "$overlays_dir" "$fragment_file" "${BASH_REMATCH[1]}"
      continue
    fi
    # Machine-artifact minification: drop comments and blank lines.
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi
    printf '%s\n' "$line"
    # Heredoc openers are tracked only for emitted content lines; the tracker
    # scans to the end of the line so the last opener wins when several
    # share a line.
    dce_embed_heredoc_track "$line"
  done < "$fragment_file"
  if (( DCE_HD_OPEN )); then
    echo "WARN: $fragment_file: heredoc delimiter '$DCE_HD_DELIM' is never terminated; its body was copied verbatim to the end of the fragment (typo in the terminator, or a '<<' that is not a heredoc -- a bit-shift or here-string)" >&2
  fi
  echo "# --- end $label ---"
}

# Reject COPY/ADD in overlays. Generated files build with the repo as context,
# but overlays must stay context-free so team/user fragments compose portably.
#
# Also pre-flights every DC-EMBED directive (syntax, path safety, symlink
# containment, mode, source existence) via parse_embed_args, so an invalid
# overlay dies before the composed file is opened for writing. emit_fragment
# re-parses with the same function, so validation and emission cannot drift
# apart.
#
# The scan mirrors emit_fragment's line classification exactly (heredoc body
# -> strip rule -> directive -> comment/blank -> opener tracking, via the
# same shared helpers in lib/common/image-provenance.sh): a directive-looking
# line inside a heredoc body is script data that emission copies verbatim and
# never rewrites, so it must not fatal here either. COPY/ADD stays a plain
# whole-file grep: it is a static supply-chain guard, and over-rejecting a
# heredoc that embeds a COPY-looking shell line is the safe direction.
validate_overlay_file() {
  local overlay_file="$1"

  if grep -Eiq '^[[:space:]]*(COPY|ADD)[[:space:]]+' "$overlay_file"; then
    dce_die "Overlay file contains COPY/ADD, which is disallowed: $overlay_file
Use RUN/ENV/ARG/SHELL/WORKDIR/USER only."
  fi

  local line=""
  local frag_lineno=0
  dce_embed_heredoc_reset
  # SC2094 false positive: parse_embed_args only reads its fragment argument
  # for error messages/paths; it never writes the fragment being read here.
  # shellcheck disable=SC2094
  while IFS= read -r line || [[ -n "$line" ]]; do
    frag_lineno=$((frag_lineno + 1))
    if (( DCE_HD_OPEN )); then
      if dce_embed_heredoc_terminator "$line"; then
        DCE_HD_OPEN=0
      fi
      continue
    fi
    if dce_fragment_line_is_stripped "$line" "$frag_lineno"; then
      continue
    fi
    if dce_embed_line_is_directive "$line"; then
      parse_embed_args "$overlay_file" "${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi
    dce_embed_heredoc_track "$line"
  done < "$overlay_file"
}

dce_load_global_config

TEAM_OD="$(dce_team_overlays_dir)"
USER_OD="$(dce_user_overlays_dir)"

NORMALIZED_SCOPES="$(dce_normalize_scopes_csv "$SCOPE_INPUT")" || exit 1
EFFECTIVE_SCOPES_CSV="$(dce_effective_scopes_csv "$TEAM_OD" "$USER_OD" "$NORMALIZED_SCOPES")" || exit 1

SELECTED_SCOPES=()
if [[ -n "$EFFECTIVE_SCOPES_CSV" ]]; then
  IFS=',' read -r -a SELECTED_SCOPES <<< "$EFFECTIVE_SCOPES_CSV"
fi

AUTO_OVERLAY_FILES=()
AUTO_OVERLAY_LABELS=()

# Record one overlay file for emission. The caller passes the resolved overlays
# leaf dir, the human-readable namespace label ("team"/"user"), and the scope;
# the label preserves the team/user layering contract for readability even
# though the on-disk layout is now <root>/overlays/Containerfile.<scope>. A
# missing unrequested file is reported but skipped silently (effective-scopes
# resolution already validated requested scopes).
append_auto_overlay() {
  local overlays_dir="$1"
  local namespace="$2"
  local scope="$3"
  local overlay_file="$overlays_dir/Containerfile.$scope"

  if [[ -f "$overlay_file" ]]; then
    validate_overlay_file "$overlay_file"
    AUTO_OVERLAY_FILES+=("$overlay_file")
    AUTO_OVERLAY_LABELS+=("$namespace/$scope")
    echo "  $namespace/$scope: found"
  else
    echo "  $namespace/$scope: not found, skipped"
  fi
}

# Layer overlays in canonical order: for each effective scope, team then user.
echo "==> Layering overlays:"
for scope in "${SELECTED_SCOPES[@]}"; do
  append_auto_overlay "$TEAM_OD" team "$scope"
  append_auto_overlay "$USER_OD" user "$scope"
done

if [[ ${#SELECTED_SCOPES[@]} -gt 0 ]]; then
  SELECTED_SCOPE_SUMMARY="$(dce_join_by ', ' "${SELECTED_SCOPES[@]}")"
else
  SELECTED_SCOPE_SUMMARY="(none)"
fi

# Provenance: detect each overlay source dir independently (plans/versioning.md).
# Per side we always have a content fingerprint; git commit/dirty/source are added
# when the dir is a git checkout. Values are scrubbed before inlining into LABELs
# (no quotes/backslash/dollar reach the Dockerfile). base.id and built.utc cannot
# be known at compose time (no backend), so they are declared as ARGs and injected
# at build time by the caller via --build-arg.
TEAM_CONTENT_HASH="$(dce_provenance_content_hash "$TEAM_OD" "$EFFECTIVE_SCOPES_CSV")"
USER_CONTENT_HASH="$(dce_provenance_content_hash "$USER_OD" "$EFFECTIVE_SCOPES_CSV")"
COMBINED_CONTENT_HASH="$(dce_provenance_combined_hash "$TEAM_CONTENT_HASH" "$USER_CONTENT_HASH")"
TEAM_GIT_COMMIT="$(dce_provenance_git_commit "$DC_TEAM_DIR")"
TEAM_GIT_DIRTY="$(dce_provenance_git_dirty "$DC_TEAM_DIR" overlays)"
TEAM_GIT_SOURCE="$(dce_provenance_git_source "$DC_TEAM_DIR")"
USER_GIT_COMMIT="$(dce_provenance_git_commit "$DC_USER_DIR")"
USER_GIT_DIRTY="$(dce_provenance_git_dirty "$DC_USER_DIR" overlays)"
USER_GIT_SOURCE="$(dce_provenance_git_source "$DC_USER_DIR")"

# Emit the composed file: always FROM dce-base:latest, a provenance LABEL block
# capturing overlay state, each overlay fragment in layered order, then force
# USER dev, a single chained ENTRYPOINT that runs every installed per-language
# sync hook, and a long-running CMD.
{
  echo "FROM dce-base:latest"
  echo ""
  echo "# Provenance labels (plans/versioning.md): overlay state at compose time."
  echo "# base.id / built.utc are injected at build time via --build-arg."
  echo 'ARG DC_BASE_ID=""'
  echo 'ARG DC_BUILT_UTC=""'
  echo "LABEL dce.version=\"$(dce_label_scrub "$DC_VERSION")\""
  echo "LABEL dce.scopes=\"$(dce_label_scrub "$EFFECTIVE_SCOPES_CSV")\""
  echo "LABEL dce.base.image=\"dce-base:latest\""
  echo "LABEL dce.base.id=\"\${DC_BASE_ID}\""
  echo "LABEL dce.team.content_hash=\"$(dce_label_scrub "$TEAM_CONTENT_HASH")\""
  echo "LABEL dce.team.git_commit=\"$(dce_label_scrub "$TEAM_GIT_COMMIT")\""
  echo "LABEL dce.team.git_dirty=\"$(dce_label_scrub "$TEAM_GIT_DIRTY")\""
  echo "LABEL dce.team.source=\"$(dce_label_scrub "$TEAM_GIT_SOURCE")\""
  echo "LABEL dce.user.content_hash=\"$(dce_label_scrub "$USER_CONTENT_HASH")\""
  echo "LABEL dce.user.git_commit=\"$(dce_label_scrub "$USER_GIT_COMMIT")\""
  echo "LABEL dce.user.git_dirty=\"$(dce_label_scrub "$USER_GIT_DIRTY")\""
  echo "LABEL dce.user.source=\"$(dce_label_scrub "$USER_GIT_SOURCE")\""
  echo "LABEL dce.content.hash=\"$(dce_label_scrub "$COMBINED_CONTENT_HASH")\""
  echo "LABEL dce.built.utc=\"\${DC_BUILT_UTC}\""
  echo "LABEL org.opencontainers.image.revision=\"$(dce_label_scrub "$COMBINED_CONTENT_HASH")\""
  echo ""
  echo "# Selected overlay scopes: $SELECTED_SCOPE_SUMMARY"

  for i in "${!AUTO_OVERLAY_FILES[@]}"; do
    emit_fragment "${AUTO_OVERLAY_FILES[$i]}" "overlay:auto:${AUTO_OVERLAY_LABELS[$i]}"
  done

  echo ""
  echo "USER dev"
  # One ENTRYPOINT owned by the composed image: run every dce-*-entrypoint.sh
  # hook the overlays installed, then exec CMD. With no overlays the glob is
  # empty and it simply execs CMD. A hook exiting non-zero (e.g. a
  # DC_*_INSTALL_STRICT=1 failure) aborts startup via set -e so the container
  # does not run with broken dependencies. Quoted heredoc so the inner heredoc
  # and shell variables reach the image verbatim.
  cat <<'RUNNER_EOF'
RUN mkdir -p /home/dev/.local/bin
RUN cat > /home/dev/.local/bin/dce-entrypoint <<'DC_ENTRYPOINT_EOF'
#!/bin/sh
set -eu
# Chain every installed per-language dependency-sync hook, then run CMD.
for ep in /home/dev/.local/bin/dce-*-entrypoint.sh; do
  [ -x "$ep" ] || continue
  "$ep"
done
exec "$@"
DC_ENTRYPOINT_EOF
RUN chmod +x /home/dev/.local/bin/dce-entrypoint
ENTRYPOINT ["/home/dev/.local/bin/dce-entrypoint"]
RUNNER_EOF
  echo 'CMD ["sleep", "infinity"]'
} > "$OUTPUT_FILE"

# Size guard (non-fatal): apple/container refuses to build a Dockerfile larger
# than 16,384 bytes; docker buildx has no such cap and would accept this file.
# DC-EMBED exists precisely to keep scripts from bloating the composed file,
# so point at it when the cap is exceeded.
COMPOSED_BYTES="$(wc -c < "$OUTPUT_FILE" | tr -d '[:space:]')"
if (( COMPOSED_BYTES > 16384 )); then
  {
    echo "WARN: composed Containerfile is $COMPOSED_BYTES bytes, over the 16384-byte limit"
    echo "WARN: apple/container caps a Dockerfile at 16384 bytes and will refuse to build it"
    echo "  (docker buildx has no such cap, so this file may still build on other backends)."
    echo "  Compress large inline scripts with the '# DC-EMBED:' overlay directive"
    echo "  (see docs/reference/overlays.md) to shrink the composed file."
  } >&2
fi

AUTO_OVERLAY_SUMMARY="none"
if [[ ${#AUTO_OVERLAY_LABELS[@]} -gt 0 ]]; then
  AUTO_OVERLAY_SUMMARY="$(dce_join_by ', ' "${AUTO_OVERLAY_LABELS[@]}")"
fi

echo "✓ Generated composed Containerfile: $OUTPUT_FILE"
echo "  Auto overlays included: $AUTO_OVERLAY_SUMMARY"
