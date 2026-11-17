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
# is rewritten at compose time into a self-contained RUN that installs <src>
# (resolved relative to the fragment's own overlays/ directory) at the
# absolute <dest> inside the image and chmods it. The RUN shape depends on
# the --backend variant:
#
#   - apple (default): <src> is inlined as a gzip+base64 blob decoded by one
#     `RUN printf ... | base64 -d | gunzip > dest && chmod` line, and fragment
#     comments/blank lines are stripped (the composed file is a machine
#     artifact). apple/container's effective ~11.5KB composed-Dockerfile cap
#     (the file travels base64-encoded inside a gRPC header; see the size
#     guard at the bottom of this script) forces this, and COPY/ADD stays
#     banned.
#   - docker|orbstack|colima|podman (readable): <src> is inlined verbatim
#     between a quoted-heredoc `RUN cat > dest <<'DELIM'` opener and its
#     terminator, followed by `RUN chmod`; fragment comments/blank lines are
#     preserved. These backends have no Dockerfile cap, so encoding would
#     only destroy build-error readability (errors point into opaque base64
#     instead of real lines).
#
# Encoding (apple mode) is deterministic (gzip -n, single-line base64), and
# the readable delimiter choice is a pure function of the source bytes, so
# composing twice yields a byte-identical file in both modes and nothing
# generated is ever committed -- the readable files/ source stays the single
# source of truth. Editing an embedded source also changes the provenance
# content hash (the v2 scheme in lib/common/image-provenance.sh, which hashes
# sources and is therefore mode-independent), so a rebuild never reuses a
# stale image.
#
# The flag is optional and omitting it means apple mode -- a fail-safe
# default: the encoded/minified form is exactly what satisfies apple's cap,
# so a forgotten flag on a docker-family backend only costs readability,
# never correctness (it can never produce an over-cap apple file). dce's
# callers (scripts/rebuild-image.sh, scripts/new-container.sh) pass their
# active backend on every compose; the name is validated case-insensitively.
#
# In apple mode the composed file is additionally a machine artifact:
# comment lines and blank/whitespace lines in overlay fragments are stripped
# at emit time (the overlay sources stay fully readable) to help stay under
# apple/container's ~11.5KB effective cap (base64-in-gRPC-header; see the
# size guard at the bottom of this script). Heredoc bodies are exempt -- a
# '#' there is script content, not a Containerfile comment -- and compose's
# own output (markers, LABELs, the entrypoint runner) is emitted verbatim in
# both modes.
#
# Apple transport chaining: when the apple-mode composed file exceeds the
# safe cap, compose additionally derives part files
# `Containerfile.<hash>.p0`, `.p1`, ... next to it -- each part a small
# standalone Dockerfile (p0 FROM dce-base:latest, pk FROM the previous
# dce-stage-<hash>-<k-1>, all capped by DCE_APPLE_SAFE_FILE_BYTES) so
# apple/container can build the image as a sequence of small builds. The
# canonical file is never modified: it stays byte-identical and remains the
# single source of truth; parts are derived artifacts, re-derived on every
# apple-mode compose with stale ones pruned (under cap that leaves zero part
# files). Readable mode never emits parts. See the "Apple transport
# chaining" block in the body for the splitting contract.
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
  echo "Usage: compose-containerfile.sh [--backend <name>] <output-file> <overlay-scopes-csv>"
  echo ""
  echo "  --backend  Build target for the composed file's DC-EMBED/minification"
  echo "             variant: apple (default) or docker|orbstack|colima|podman."
  echo "             apple: gzip+base64-encoded embeds, fragments minified, size"
  echo "             guard armed. docker-family/podman: verbatim heredoc embeds,"
  echo "             fragments readable, no size guard."
}

# Selected --backend mode. Omitted = apple, the fail-safe default: the
# encoded/minified form is exactly what satisfies apple/container's cap, so a
# forgotten flag on a docker-family backend only costs readability, never
# correctness (it can never produce an over-cap apple file).
COMPOSE_BACKEND="apple"
COMPOSE_FOR_APPLE=1

# Parse flags (--help/-h, --backend <name>, --; reject unknown flags).
# Positional calls keep working: the first non-flag argument stops parsing,
# and every positional-only caller implicitly gets apple mode.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --backend)
      shift
      if [[ $# -lt 1 ]]; then
        usage
        dce_die "Missing value for --backend for compose-containerfile.sh (expected apple, docker, orbstack, colima, or podman)"
      fi
      COMPOSE_BACKEND="${1,,}"
      case "$COMPOSE_BACKEND" in
        apple)
          COMPOSE_FOR_APPLE=1
          ;;
        docker|orbstack|colima|podman)
          COMPOSE_FOR_APPLE=0
          ;;
        *)
          usage
          dce_die "Unknown --backend for compose-containerfile.sh: $1 (expected apple, docker, orbstack, colima, or podman)"
          ;;
      esac
      shift
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

# Emit one DC-EMBED directive in readable mode (--backend docker|orbstack|
# colima|podman): a marker comment, a quoted-heredoc RUN carrying the source
# bytes verbatim, then a chmod RUN. No cap applies on those backends, so the
# bytes go in as-is and build errors point at real lines instead of base64.
# validate_overlay_file has already vetted the directive, but this re-parses
# with the same function so emission cannot drift from validation.
#
# Delimiter safety: the default DCE_EMBED_EOF would terminate the heredoc
# early if the source itself contains that line, so the delimiter is a pure
# function of the source bytes -- DCE_EMBED_EOF, or _2/_3/... suffixed until
# no line of the source equals it -- keeping compose deterministic. The
# emission is always well-formed: when the source's last byte is not a
# newline, one is emitted before the terminator so it sits on its own line
# (otherwise cat's output would glue onto the delimiter and the heredoc would
# never close). That newline is text, so the dest inside the image then
# differs from the source by exactly that appended trailing newline (apple
# mode's decode RUN preserves bytes exactly; newline-terminated sources, the
# norm, are identical in both modes).
emit_embed_readable() {
  local overlays_dir="$1"
  local fragment_file="$2"
  local args="$3"

  parse_embed_args "$fragment_file" "$args"
  local delim="DCE_EMBED_EOF"
  local base="$delim"
  local n=1
  while grep -Fxq -e "$delim" "$overlays_dir/$EMBED_SRC"; do
    n=$((n + 1))
    delim="${base}_${n}"
  done
  printf '# DC-EMBED %s -> %s (source: %s/%s)\n' \
    "$EMBED_SRC" "$EMBED_DEST" "$overlays_dir" "$EMBED_SRC"
  printf "RUN cat > %s <<'%s'\n" "$EMBED_DEST" "$delim"
  cat "$overlays_dir/$EMBED_SRC"
  # Heredocs are line-oriented: the terminator must start at a line boundary.
  # tail -c 1 of a source ending in a newline is that newline, which command
  # substitution strips to the empty string; any other last byte (or none, on
  # an empty source) means no closing newline was emitted above and the
  # terminator would glue onto the last source line. Deterministic either way.
  if [[ -n "$(tail -c 1 "$overlays_dir/$EMBED_SRC")" ]]; then
    printf '\n'
  fi
  printf '%s\n' "$delim"
  printf 'RUN chmod %s %s\n' "$EMBED_MODE" "$EMBED_DEST"
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
# DC-EMBED directive comment lines are rewritten in place -- into the encoded
# marker + RUN form in apple mode, into the readable heredoc form otherwise
# (see header). Directives are detected before stripping, so the emitted
# lines always survive; it is compose's own output, never re-read for
# minification. The FROM/CMD/ENTRYPOINT strip lives inside this heredoc-aware
# walker (it used to be an awk pre-pass over the raw fragment, which would
# silently delete such lines from heredoc bodies); both modes share it, and
# one walker does strip, rewrite, and minify over a single read of the
# fragment.
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
      if (( COMPOSE_FOR_APPLE )); then
        emit_embed_run "$overlays_dir" "$fragment_file" "${BASH_REMATCH[1]}"
      else
        emit_embed_readable "$overlays_dir" "$fragment_file" "${BASH_REMATCH[1]}"
      fi
      continue
    fi
    # Machine-artifact minification (apple mode only): drop comments and
    # blank lines. Readable mode emits them verbatim -- readability is the
    # point there -- but comment lines must not reach the heredoc tracker
    # below: validate_overlay_file and dce_embed_directive_args drop comments
    # before tracking, so a `<<` inside a comment (e.g. "# tip: use <<'EOF'")
    # must not open a phantom heredoc here only -- classification would drift
    # and a later directive would be copied verbatim instead of rewritten.
    # Blank lines cannot contain `<<`, so their flow stays shared below.
    if (( COMPOSE_FOR_APPLE )); then
      if [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*$ ]]; then
        continue
      fi
    elif [[ "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line"
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

# ---------------------------------------------------------------------------
# Apple transport chaining: derive part files from an over-cap composed file.
#
# apple/container does not hand the raw Dockerfile to its builder -- it ships
# it base64-encoded inside a gRPC header (issue #735), so a composed file over
# DCE_APPLE_SAFE_FILE_BYTES cannot reach the builder in one piece. When that
# happens, compose additionally writes `Containerfile.<hash>.p0`, `.p1`, ...
# next to the canonical file: each part is a small standalone Dockerfile whose
# FROM resumes the previous part's stage, so the image can be built as a
# sequence of small builds, each under the cap. The canonical file is never
# touched -- it stays byte-identical and remains the single source of truth;
# parts are derived artifacts and are re-derived (stale ones pruned) on
# every compose, both modes -- a readable recompose to the same output path
# leaves zero part files. Readable mode never emits parts.
#
# Splitting unit model: a unit is one instruction line starting at column 0
# (RUN|ENV|ARG|LABEL|SHELL|WORKDIR|USER|ENTRYPOINT|CMD|FROM) plus every
# following line up to the next such line -- heredoc bodies (tracked with the
# same dce_embed_heredoc_* helpers the emitter uses, so bodies and their
# terminators stay inside their unit) never split, and instruction detection
# never fires inside an open body. Non-instruction lines (fragment markers,
# blanks) attach to the FOLLOWING unit; trailing ones attach to the last unit.
# The provenance ARG/LABEL block (up through the "# Selected overlay scopes:"
# comment) and the USER-dev trailer are extracted up front and are always
# emitted in the final part only. Units are then packed greedily in order: a
# part takes units while it still fits under the cap (part bytes include that
# part's own header+FROM); a unit too big for any part on its own (one huge
# DC-EMBED blob) gets a dedicated over-cap part plus a distinct WARN pointing
# at the peer-backend build fallback in lib/container-backend.sh. A part is
# never over cap unless a single unit alone forced it -- nothing that could
# have been split is ever left unsplit.
# ---------------------------------------------------------------------------

# Part-header comment text and its byte length -- one deterministic line per
# part. The header counts against the cap, so the packer sizes parts with
# dce_split_header_len, derived from dce_split_header_text's formatted bytes
# (plus the newline) so the accounted length can never drift from the emitted
# text (callers run under LC_ALL=C so ${#} counts bytes).
DCE_SPLIT_HDR_PREFIX='# dce composed image part '
DCE_SPLIT_HDR_MID=' (derived artifact; the canonical file is the single source of truth): apple/container transport chaining (issue #735); machine-generated, do not edit.'

dce_split_header_text() { # <k> <n> -> header line on stdout
  printf '%s%s/%s%s\n' "$DCE_SPLIT_HDR_PREFIX" "$1" "$2" "$DCE_SPLIT_HDR_MID"
}

dce_split_header_len() { # <k> <n> -> bytes incl. newline (printed)
  local text
  text="$(dce_split_header_text "$1" "$2")"
  printf '%s' "$(( ${#text} + 1 ))"
}

# Byte length of a part's FROM line (incl. newline): part 0 reuses dce-base,
# part k resumes the previous chained stage. Reads PART_HASH (the image hash
# from the canonical file's basename).
dce_split_from_len() { # <k> -> bytes incl. newline (printed); reads PART_HASH
  local f
  if (( $1 == 0 )); then
    f="FROM dce-base:latest"
  else
    f="FROM dce-stage-${PART_HASH}-$(( $1 - 1 )):latest"
  fi
  printf '%s' "$(( ${#f} + 1 ))"
}

# Greedy in-order packing of UNIT_SIZES under the cap. Sets PART_START /
# PART_END (inclusive unit-index ranges), PART_SIZE (accounted bytes) and
# PART_OVER (1 = carries a unit that alone exceeds the cap). The header and
# FROM lines embed k/N, whose digit width depends on the final part count,
# so the packer iterates to a fixpoint on the part count (deterministic:
# same units + cap -> same assignment, whatever the digit widths).
dce_split_assign_parts() {
  local cap="$DCE_APPLE_SAFE_FILE_BYTES"
  local n_units=${#UNIT_SIZES[@]}
  local -a starts=() ends=() sizes=()
  local n_est=1 iter k j start pbytes n_new converged=0 last fh fp

  for ((iter = 0; iter < 32; iter++)); do
    starts=(); ends=(); sizes=()
    k=0; start=0
    pbytes=$(( $(dce_split_header_len 0 "$n_est") + $(dce_split_from_len 0) ))
    for ((j = 0; j < n_units; j++)); do
      # A non-empty part that cannot take the whole unit is closed first; an
      # empty part takes the unit regardless (an oversized unit lands alone,
      # flagged over cap below).
      if (( j > start && pbytes + UNIT_SIZES[j] > cap )); then
        starts+=("$start"); ends+=("$(( j - 1 ))"); sizes+=("$pbytes")
        k=$(( k + 1 )); start=$j
        pbytes=$(( $(dce_split_header_len "$k" "$n_est") + $(dce_split_from_len "$k") ))
      fi
      pbytes=$(( pbytes + UNIT_SIZES[j] ))
    done
    starts+=("$start"); ends+=("$(( n_units - 1 ))"); sizes+=("$pbytes")
    # The provenance block + trailer always ride the final part. When they do
    # not fit behind the last unit, the final part carries them alone (empty
    # of units) rather than pushing a splittable unit's part over cap.
    last=$(( ${#starts[@]} - 1 ))
    if (( sizes[last] + PART_RESERVE_BYTES > cap )); then
      starts+=("$n_units"); ends+=("$(( n_units - 1 ))")
      fh="$(dce_split_header_len "$(( last + 1 ))" "$n_est")"
      fp="$(dce_split_from_len "$(( last + 1 ))")"
      sizes+=( $(( fh + fp + PART_RESERVE_BYTES )) )
    else
      sizes[last]=$(( sizes[last] + PART_RESERVE_BYTES ))
    fi
    n_new=${#starts[@]}
    if (( n_new == n_est )); then
      converged=1
      break
    fi
    n_est=$n_new
  done
  if (( ! converged )); then
    dce_die "Internal error: split part-count estimate failed to converge for '$OUTPUT_FILE'"
  fi

  PART_START=("${starts[@]}")
  PART_END=("${ends[@]}")
  PART_SIZE=("${sizes[@]}")
  PART_COUNT=${#PART_START[@]}
  PART_OVER=()
  local x
  for ((x = 0; x < PART_COUNT; x++)); do
    if (( ${PART_SIZE[$x]} > cap )); then
      PART_OVER+=(1)
    else
      PART_OVER+=(0)
    fi
  done
}

# Split an over-cap apple-mode composed file into chained part files next to
# it. Dies when the output basename violates the Containerfile.<hash>
# contract (the stage names embed the image hash, which only the canonical
# file's name carries). Sets PART_COUNT / PART_MAX_BYTES for the caller.
dce_split_apple_parts() {
  # ${#s} must count bytes, not characters (part sizing is byte math).
  local LC_ALL=C

  local base="${OUTPUT_FILE##*/}"
  if [[ ! "$base" =~ ^Containerfile\.([0-9a-f]+)$ ]]; then
    dce_die "Cannot split over-cap composed file into apple transport parts: '$OUTPUT_FILE' does not match the required basename 'Containerfile.<hash>' (hash must be [0-9a-f]+)
Part files chain FROM dce-stage-<hash>-<k> builds, so the image hash must come from the canonical file's name; compose via dce (scripts/rebuild-image.sh) or rename the output (apple/container issue #735)."
  fi
  PART_HASH="${BASH_REMATCH[1]}"

  # Load the canonical file (compose newline-terminates every line it emits).
  local -a lines=()
  mapfile -t lines < "$OUTPUT_FILE"
  local total=${#lines[@]}
  if (( total < 2 )) || [[ "${lines[0]}" != "FROM dce-base:latest" ]]; then
    dce_die "Cannot split '$OUTPUT_FILE': not a canonical composed Containerfile (expected 'FROM dce-base:latest' as line 1)"
  fi

  # The scopes comment is compose-emitted exactly once (fragment comments are
  # stripped in apple mode, so no fragment can inject another one).
  local i scopes_idx=-1
  for ((i = 0; i < total; i++)); do
    if [[ "${lines[$i]}" == "# Selected overlay scopes: "* ]]; then
      if (( scopes_idx >= 0 )); then
        dce_die "Cannot split '$OUTPUT_FILE': multiple '# Selected overlay scopes:' lines (not a canonical composed file)"
      fi
      scopes_idx=$i
    fi
  done
  if (( scopes_idx < 1 )); then
    dce_die "Cannot split '$OUTPUT_FILE': no '# Selected overlay scopes:' line (not a canonical composed file)"
  fi

  # Trailer signature: compose's own trailer starts at USER dev immediately
  # followed by the runner-mkdir RUN. The LAST match wins -- compose's trailer
  # is the tail of the file, so no fragment-emitted pair can shadow it.
  local trailer_idx=-1
  for ((i = total - 2; i >= 0; i--)); do
    if [[ "${lines[$i]}" == "USER dev" && "${lines[$((i + 1))]}" == "RUN mkdir -p /home/dev/.local/bin" ]]; then
      trailer_idx=$i
      break
    fi
  done
  if (( trailer_idx <= scopes_idx )); then
    dce_die "Cannot split '$OUTPUT_FILE': composed USER-dev trailer not found after the provenance block (not a canonical composed file)"
  fi

  # Extracted verbatim; both ride the final part only (PROV spans the blank
  # after FROM through the scopes comment, TRAILER from USER dev through CMD).
  local prov="" trailer="" line
  for ((i = 1; i <= scopes_idx; i++)); do
    prov+="${lines[$i]}"$'\n'
  done
  for ((i = trailer_idx; i < total; i++)); do
    trailer+="${lines[$i]}"$'\n'
  done
  prov="${prov%$'\n'}"
  trailer="${trailer%$'\n'}"
  # Reserve = their emitted size (each is emitted as one printf '%s\n').
  PART_RESERVE_BYTES=$(( ${#prov} + 1 + ${#trailer} + 1 ))

  # Parse the units region into units (see the block comment for the model).
  # Each unit is stored without its trailing newline; its accounted size is
  # the emitted size (text + one newline).
  local -a UNIT_TEXTS=() UNIT_SIZES=()
  local cur="" pending=""
  local -r instr_re='^(RUN|ENV|ARG|LABEL|SHELL|WORKDIR|USER|ENTRYPOINT|CMD|FROM)([[:space:]]|$)'
  local -r frag_marker_re='^# --- (begin|end) overlay:auto:.* ---$'
  dce_embed_heredoc_reset
  for ((i = scopes_idx + 1; i < trailer_idx; i++)); do
    line="${lines[$i]}"
    if [[ "$line" =~ $frag_marker_re ]]; then
      # Compose-owned fragment marker: emit_fragment reset heredoc tracking at
      # this fragment boundary, so the splitter must too -- otherwise a
      # false/unclosed opener in one fragment (accepted input; the emitter
      # only WARNs) leaves the tracker open here and every later fragment
      # merges into one giant unit.
      dce_embed_heredoc_reset
    fi
    if (( DCE_HD_OPEN )); then
      cur+="$line"$'\n'
      if dce_embed_heredoc_terminator "$line"; then
        DCE_HD_OPEN=0
      fi
      continue
    fi
    if [[ "$line" =~ $instr_re ]]; then
      if [[ -n "$cur" ]]; then
        UNIT_TEXTS+=("${cur%$'\n'}")
        UNIT_SIZES+=( ${#cur} )
        cur=""
      fi
      # Pending non-instruction lines attach to the unit they precede.
      cur="$pending$line"$'\n'
      pending=""
      dce_embed_heredoc_track "$line"
      continue
    fi
    pending+="$line"$'\n'
  done
  # Trailing non-instruction lines attach to the last unit (or form a tail
  # element when the region holds no instruction at all).
  if [[ -n "$cur" || -n "$pending" ]]; then
    cur+="$pending"
    if [[ -n "$cur" ]]; then
      UNIT_TEXTS+=("${cur%$'\n'}")
      UNIT_SIZES+=( ${#cur} )
    fi
  fi

  dce_split_assign_parts

  # Emit the parts and verify the accounting against the written bytes.
  local k fpath bytes s
  PART_MAX_BYTES=0
  for ((k = 0; k < PART_COUNT; k++)); do
    fpath="${OUTPUT_FILE}.p${k}"
    {
      dce_split_header_text "$k" "$PART_COUNT"
      if (( k == 0 )); then
        printf 'FROM dce-base:latest\n'
      else
        printf 'FROM dce-stage-%s-%d:latest\n' "$PART_HASH" "$(( k - 1 ))"
      fi
      if (( k == PART_COUNT - 1 )); then
        printf '%s\n' "$prov"
      fi
      for ((s = PART_START[k]; s <= PART_END[k]; s++)); do
        printf '%s\n' "${UNIT_TEXTS[s]}"
      done
      if (( k == PART_COUNT - 1 )); then
        printf '%s\n' "$trailer"
      fi
    } > "$fpath"
    bytes="$(wc -c < "$fpath" | tr -d '[:space:]')"
    if (( bytes > PART_MAX_BYTES )); then
      PART_MAX_BYTES=$bytes
    fi
    if (( PART_OVER[k] == 1 )); then
      # Distinct WARN: this part cannot be transported by apple/container's
      # native builder; the peer-backend fallback (lib/container-backend.sh)
      # or a smaller/split embedded source is required.
      {
        echo "WARN: $fpath is $bytes bytes, over the ${DCE_APPLE_SAFE_FILE_BYTES}-byte apple transport cap: one unit alone exceeds it (e.g. a single huge DC-EMBED blob), so it cannot be split further"
        echo "WARN: this part needs the peer-backend build fallback (lib/container-backend.sh) or split the embedded source file; apple/container's native builder will refuse it (issue #735)"
      } >&2
    elif (( bytes > DCE_APPLE_SAFE_FILE_BYTES )); then
      dce_die "Internal error: part '$fpath' is $bytes bytes, over the cap without the oversized-unit flag (split accounting drifted)"
    fi
  done

  {
    echo "WARN: composed Containerfile split into $PART_COUNT transport part files (largest part $PART_MAX_BYTES bytes): build .p0 .. .p$(( PART_COUNT - 1 )) in order (FROM dce-base, then each chained stage); the canonical file remains the single source of truth (issue #735)"
  } >&2
}

# Remove stale part files from earlier composes: any <output>.p<digits> whose
# index is not in the fresh set. The fresh set is always exactly p0..pN-1
# (N=0 under cap, which removes every stale part file).
dce_prune_stale_parts() { # <fresh-part-count>
  local keep="$1"
  local f suf
  for f in "$OUTPUT_FILE".p[0-9]*; do
    [[ -e "$f" ]] || continue
    suf="${f##*.p}"
    [[ "$suf" =~ ^[0-9]+$ ]] || continue
    # 10# forces base-10 so a zero-padded suffix (08) cannot parse as invalid
    # octal, silently fail the compare, and escape the prune (same hazard
    # lib/container-backend.sh::_backend_version_at_least documents).
    if (( 10#$suf >= keep )); then
      rm -f "$f"
    fi
  done
}

# Size guard (non-fatal, apple mode only): apple/container does not hand the
# raw Dockerfile to
# its builder -- it ships it base64-encoded inside a gRPC header, and gRPC caps
# headers at ~16,384 bytes (apple/container issue #735). base64 inflates by 4/3
# (encoded size = ceil(bytes/3)*4), so the largest file that still encodes under
# the header limit is ~12,288 bytes, and a 15.4KB file has been reported failing
# the real build. 11,520 bytes encodes to exactly 15,360 bytes, leaving ~1KB of
# slack for the header name, framing, and other headers -- hence the ~11.5KB
# effective cap below. docker-family backends and podman have no such cap, and
# the readable variant exists precisely to be over-cap-proof on them, so the
# guard (and its WARN) runs only when composing for apple.
readonly DCE_APPLE_SAFE_FILE_BYTES=11520
PART_COUNT=0
if (( COMPOSE_FOR_APPLE )); then
  COMPOSED_BYTES="$(wc -c < "$OUTPUT_FILE" | tr -d '[:space:]')"
  if (( COMPOSED_BYTES > DCE_APPLE_SAFE_FILE_BYTES )); then
    {
      echo "WARN: composed Containerfile is $COMPOSED_BYTES bytes, over the ${DCE_APPLE_SAFE_FILE_BYTES}-byte (~11.5KB) safe limit"
      echo "WARN: apple/container sends the Dockerfile base64-encoded inside a gRPC header (encoded size = ceil(bytes/3)*4), so the effective cap is ~11.5KB, not the raw 16,384-byte header limit (issue #735)"
      echo "  (docker buildx has no such cap, so this file may still build on other backends)."
      echo "  Compress large inline scripts with the '# DC-EMBED:' overlay directive"
      echo "  (see docs/reference/overlays.md) to shrink the composed file."
    } >&2
    # Transport chaining: emit the chained .pN part files next to the
    # canonical file (which stays byte-identical) so apple/container can
    # still build the image as a sequence of small builds.
    dce_split_apple_parts
  fi
fi
# Hygiene (every compose, both modes): parts derive from the canonical file,
# so stale ones must never survive a recompose to the same output path -- a
# readable or under-cap recompose has an empty fresh set (PART_COUNT=0) and
# removes every .pN, and an over-cap apple recompose leaves exactly its fresh
# p0..pN-1.
dce_prune_stale_parts "$PART_COUNT"

AUTO_OVERLAY_SUMMARY="none"
if [[ ${#AUTO_OVERLAY_LABELS[@]} -gt 0 ]]; then
  AUTO_OVERLAY_SUMMARY="$(dce_join_by ', ' "${AUTO_OVERLAY_LABELS[@]}")"
fi

echo "✓ Generated composed Containerfile: $OUTPUT_FILE"
echo "  Auto overlays included: $AUTO_OVERLAY_SUMMARY"
