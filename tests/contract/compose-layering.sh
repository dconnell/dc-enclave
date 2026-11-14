#!/usr/bin/env bash
# =============================================================================
# tests/contract/compose-layering.sh - Characterize scripts/compose-containerfile.sh.
#
# The compose helper implements the documented canonical layering contract
# (docs/explanation/overlay-model.md "Canonical layering order"; plans/layering.md). This locks it down so
# a reorder or a stripped guard regresses loudly:
#
#   - Canonical overlay order: team/all, user/all, team/<s1>, user/<s1>,
#     team/<s2> ... (one namespace pair per effective scope, all first).
#   - Silent skip of a namespace file that does not exist (no user/golang).
#   - Bookends: FROM dce-base:latest ... USER dev / CMD ["sleep", "infinity"].
#   - FROM (first line) and CMD lines stripped from overlay fragments.
#   - COPY/ADD rejected with a clear error.
#   - Fragment comment lines and blank lines stripped from the composed output
#     (machine artifact); heredoc bodies preserved byte-for-byte (quoted
#     <<'EOF' and <<- indented-terminator forms), stripping resuming after the
#     terminator; DC-EMBED directives still rewritten despite being comments.
#   - The FROM/CMD/ENTRYPOINT strip is heredoc-aware (no awk pre-pass): lines
#     starting with CMD/ENTRYPOINT/FROM inside a heredoc body are script data
#     and survive byte-identically, while a leading FROM and top-level
#     CMD/ENTRYPOINT are still stripped.
#   - Exotic delimiters (EOF.V2 quoted, EOF-2 bare) are recognized so their
#     bodies stay verbatim; an unclosed heredoc (e.g. a false opener like
#     `RUN echo $((1<<2))`) warns non-fatally naming fragment + delimiter and
#     copies the rest of the fragment verbatim.
#   - A directive-looking line inside a heredoc body is data: emitted
#     verbatim, never rewritten, never validated, never folded into the
#     provenance content hash.
#   - A DC-EMBED src symlink resolving outside its overlays dir is rejected
#     at validate time (fatal, before the output file is written); a symlink
#     resolving inside it still composes.
#   - Missing requested scope fails fast (delegates to dce_effective_scopes_csv).
#   - `all` auto-prepended even when not requested, when Containerfile.all exists.
#   - DC-EMBED directives rewritten into deterministic decode RUNs (marker
#     comment + `base64 -d | gunzip`), decoded bytes identical to the source,
#     default 0644 / explicit 0755 modes, file order preserved.
#   - Invalid DC-EMBED directives (missing src, `..` traversal, absolute src,
#     non-absolute dest, bad mode) rejected before any output file is written.
#   - Editing an embedded source changes the provenance content hash label.
#   - A composed file over the effective ~11.5KB cap (11,520 bytes: the
#     Dockerfile travels base64-encoded inside a ~16,384-byte gRPC header,
#     apple/container issue #735) triggers a prominent non-fatal warning, and
#     output under 11,520 bytes draws no size warning.
#   - `--backend <name>` selects the composed-file variant: `apple` (the
#     default; gzip+base64-encoded minified DC-EMBED RUNs, comment/blank
#     stripping, size guard) vs the docker-family/podman names `docker`,
#     `orbstack`, `colima`, `podman` (readable: DC-EMBED as verbatim heredoc
#     RUN blocks, fragment comments/blanks preserved, no size guard). The
#     FROM/CMD/ENTRYPOINT strip and COPY/ADD rejection apply in both modes,
#     and the provenance ARG/LABEL block is byte-identical across modes.
#   - Omitting the flag is byte-identical to `--backend apple` (fail-safe
#     default: a forgotten flag on a docker-family backend only costs
#     readability, never correctness).
#   - Readable-mode heredoc delimiters: a source containing a line equal to
#     the default delimiter gets a deterministic `_2`-suffixed one instead,
#     body intact; unknown/missing `--backend` values die with usage.
#   - Readable mode, source without a trailing newline: the terminator still
#     sits on its own line (well-formed emission); the dest gains that one
#     newline, and the apple-mode decode round-trip preserves the exact
#     source bytes.
#   - Readable mode: comment lines never feed the heredoc tracker (matching
#     the validator), so a `<<` inside a comment cannot phantom-open a body;
#     a directive after such a comment is still rewritten. Apple mode keeps
#     dropping comments and rewriting the directive.
#   - Apple transport chaining: an over-cap apple-mode compose additionally
#     derives part files Containerfile.<hash>.p0, .p1, ... (contiguous, each
#     under the 11,520-byte cap; p0 FROM dce-base, pk FROM the previous
#     dce-stage-<hash>-<k-1>; ARG/LABEL/scopes/USER/ENTRYPOINT/CMD only in
#     the final part; every canonical instruction in exactly one part; the
#     entrypoint-runner heredoc stays whole; deterministic). A part filled to
#     exactly the cap emits exactly cap bytes (the header length derives from
#     the header text itself, so the post-emit drift guard cannot fire on a
#     valid compose). Stale higher-index parts are pruned on shrinking
#     recomposes, every part is pruned once the output is under cap again,
#     and pruning runs on every compose: a readable recompose to the same
#     path leaves zero .pN files. The splitter resets heredoc tracking at
#     compose-owned fragment markers, so a false opener in one fragment
#     cannot merge later fragments into one giant unit. A single unit too
#     big for any part (one huge DC-EMBED blob) gets a dedicated over-cap
#     part plus a distinct peer-build-fallback WARN. Readable mode never
#     emits parts, and an over-cap apple compose whose output basename lacks
#     Containerfile.<hash> dies (the stage names need the image hash from the
#     basename).
#   - Committed golden fixture (tests/fixtures/compose-apple-golden.txt):
#     apple-mode output is byte-identical to the pinned pre-change behavior
#     (temp overlays dir paths normalized to <DC_TEAM_DIR>).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Fake HOME + global config so compose resolves DC_TEAM_DIR/DC_USER_DIR via the
# real dce_load_global_config path (no monkey-patching of the helper).
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dc-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

COMPOSE="$ROOT_DIR/scripts/compose-containerfile.sh"

# Compose <scopes> into $WORK/out.Containerfile; echo nothing. Caller checks rc.
run_compose() {
  local scopes="$1"
  bash "$COMPOSE" "$WORK/out.Containerfile" "$scopes" >"$WORK/compose.stdout" 2>"$WORK/compose.stderr"
}

# Compose <scopes> with an optional --backend value as $1 ("" = omit the flag,
# exercising the default path). Same output files as run_compose.
run_compose_backend() {
  local backend="$1"
  local scopes="$2"
  if [[ -n "$backend" ]]; then
    bash "$COMPOSE" --backend "$backend" "$WORK/out.Containerfile" "$scopes" >"$WORK/compose.stdout" 2>"$WORK/compose.stderr"
  else
    bash "$COMPOSE" "$WORK/out.Containerfile" "$scopes" >"$WORK/compose.stdout" 2>"$WORK/compose.stderr"
  fi
}

# Output path for over-cap apple fixtures. It must carry the basename
# contract (Containerfile.<hex image hash>): the chained part files derive
# their stage names (dce-stage-<hash>-<k>) from it, and compose refuses to
# split an over-cap file whose basename cannot yield the hash.
CAP_FILE="$WORK/Containerfile.deadbeefcafebabe"

# Compose <scopes> (optional --backend in $1, "" = omit the flag) to an
# explicit output file. Same stdout/stderr captures as run_compose.
run_compose_out() {
  local out="$1"
  local backend="$2"
  local scopes="$3"
  if [[ -n "$backend" ]]; then
    bash "$COMPOSE" --backend "$backend" "$out" "$scopes" >"$WORK/compose.stdout" 2>"$WORK/compose.stderr"
  else
    bash "$COMPOSE" "$out" "$scopes" >"$WORK/compose.stdout" 2>"$WORK/compose.stderr"
  fi
}

# Byte size of <file> (whitespace-stripped wc -c, matching the usage above).
file_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

# Numeric suffixes of the <base>.pN part files that exist, ascending.
list_parts() {
  local f
  for f in "$1".p[0-9]*; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "${f##*.p}"
  done | sort -n
}

# Extract emitted overlay labels (namespace/scope) in file order.
overlay_labels() {
  awk '/^# --- begin overlay:auto:/ { sub(/^overlay:auto:/, "", $4); print $4 }' "$WORK/out.Containerfile"
}

# ---------------------------------------------------------------------------
# Canonical order + silent skip
# ---------------------------------------------------------------------------
printf 'RUN echo TEAM-ALL\n'    > "$TEAM_DIR/overlays/Containerfile.all"
printf 'RUN echo USER-ALL\n'    > "$USER_DIR/overlays/Containerfile.all"
printf 'RUN echo TEAM-NODEJS\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
printf 'RUN echo USER-NODEJS\n' > "$USER_DIR/overlays/Containerfile.nodejs"
printf 'RUN echo TEAM-GOLANG\n' > "$TEAM_DIR/overlays/Containerfile.golang"
# user/golang intentionally absent -> must be skipped silently.

run_compose "nodejs,golang"

expected_markers="team/all
user/all
team/nodejs
user/nodejs
team/golang"
got_markers="$(overlay_labels)"
[[ "$got_markers" == "$expected_markers" ]] \
  || fail "canonical order: expected [$expected_markers] got [$got_markers]"

# user/golang absence must be reported in stdout but must NOT appear in output.
grep -Fq 'user/golang: not found, skipped' "$WORK/compose.stdout" \
  || fail "silent skip: expected 'user/golang: not found, skipped' in stdout"
! grep -q 'overlay:auto:user/golang' "$WORK/out.Containerfile" \
  || fail "silent skip: user/golang fragment must not be emitted"

pass "canonical layer order + silent skip of missing namespace"

# ---------------------------------------------------------------------------
# Bookends
# ---------------------------------------------------------------------------
[[ "$(head -n1 "$WORK/out.Containerfile")" == "FROM dce-base:latest" ]] \
  || fail "bookend: first line must be FROM dce-base:latest"
grep -Fxq 'USER dev' "$WORK/out.Containerfile" \
  || fail "bookend: USER dev must be present"
grep -Fxq 'CMD ["sleep", "infinity"]' "$WORK/out.Containerfile" \
  || fail "bookend: CMD [\"sleep\", \"infinity\"] must be present"
# The bookends come after the last fragment: CMD is the final non-blank line.
[[ "$(awk 'NF {last=$0} END {print last}' "$WORK/out.Containerfile")" == 'CMD ["sleep", "infinity"]' ]] \
  || fail "bookend: CMD must be the final non-blank line"

pass "FROM dce-base / USER dev / CMD bookends"

# ---------------------------------------------------------------------------
# FROM (leading) + CMD + ENTRYPOINT stripping from overlay fragments
# ---------------------------------------------------------------------------
printf 'FROM dce-base:latest\nRUN echo STRIPEME\ncmd ["echo", "cmdme"]\nENTRYPOINT ["/tmp/leakme"]\n' \
  > "$TEAM_DIR/overlays/Containerfile.nodejs"
rm -f "$USER_DIR/overlays/Containerfile.nodejs" "$TEAM_DIR/overlays/Containerfile.golang" "$TEAM_DIR/overlays/Containerfile.all" "$USER_DIR/overlays/Containerfile.all"

run_compose "nodejs"
grep -Fq 'STRIPEME' "$WORK/out.Containerfile" \
  || fail "strip: RUN line from fragment must survive"
! grep -Fqi 'cmdme' "$WORK/out.Containerfile" \
  || fail "strip: CMD line must be stripped from fragment"
! grep -Fqi 'leakme' "$WORK/out.Containerfile" \
  || fail "strip: ENTRYPOINT line must be stripped from fragment"
# Exactly one FROM (the emitted dce-base); the fragment's leading FROM is gone.
from_count="$(grep -Eci '^FROM ' "$WORK/out.Containerfile")"
[[ "$from_count" -eq 1 ]] || fail "strip: expected exactly one FROM (got $from_count)"
# Exactly one ENTRYPOINT (the composed chained runner); the fragment's own
# ENTRYPOINT is gone, so multi-overlay containers don't clobber each other.
ep_count="$(grep -Eci '^ENTRYPOINT ' "$WORK/out.Containerfile")"
[[ "$ep_count" -eq 1 ]] || fail "strip: expected exactly one ENTRYPOINT (got $ep_count)"
grep -Eq 'ENTRYPOINT \["/home/dev/.local/bin/dce-entrypoint"\]' "$WORK/out.Containerfile" \
  || fail "strip: single ENTRYPOINT must be the composed runner"

pass "FROM/CMD/ENTRYPOINT stripping from overlay fragments"

# ---------------------------------------------------------------------------
# Comment/blank stripping: composed output is a machine artifact
# ---------------------------------------------------------------------------
# Fragments keep their full documentation; the composed file drops comment
# lines and blank/whitespace-only lines from fragment content (compose's own
# markers and bookends are emitted verbatim, as the marker-exact asserts here
# pin down).
{
  printf '# a fragment comment (must be stripped)\n'
  printf '\n'
  printf '   \t  \n'
  printf 'RUN echo KEEPER-ONE\n'
  printf '   # indented comment (must be stripped)\n'
  printf 'RUN echo KEEPER-TWO\n'
  printf '# trailing comment (must be stripped)\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" || fail "strip: compose must succeed on comment-heavy fragment"
CF="$WORK/out.Containerfile"

! grep -Fq 'must be stripped' "$CF" \
  || fail "comment strip: fragment comments must not reach composed output"
block="$(awk -v b="# --- begin overlay:auto:team/nodejs ---" \
              -v e="# --- end overlay:auto:team/nodejs ---" \
              '$0 == b { f = 1; next } $0 == e { f = 0 } f' "$CF")"
expected_block="RUN echo KEEPER-ONE
RUN echo KEEPER-TWO"
[[ "$block" == "$expected_block" ]] \
  || fail "comment strip: fragment block must be exactly the kept RUN lines (got: [$block])"

# Compose's own output keeps its shape: header comments, blank separators and
# provenance LABELs are emitted verbatim (never minified).
[[ "$(sed -n '2p' "$CF")" == "" ]] \
  || fail "comment strip: compose's own blank line after FROM must survive"
grep -Fxq '# Provenance labels (plans/versioning.md): overlay state at compose time.' "$CF" \
  || fail "comment strip: compose's own header comment must survive"
grep -Eq '^LABEL dce\.version=' "$CF" \
  || fail "comment strip: provenance LABEL block must survive"

pass "fragment comments/blank lines stripped; compose's own output verbatim"

# ---------------------------------------------------------------------------
# Heredoc bodies survive byte-for-byte (quoted 'EOF' and <<- indented forms)
# ---------------------------------------------------------------------------
# A '#' line inside a heredoc is script content, not a Containerfile comment,
# and blank lines there are script formatting: both must reach the composed
# output unchanged, and stripping must resume after the terminator.
cat > "$WORK/hd-body.expected" <<'EXPECTED_BODY'
#!/bin/sh
# comment inside heredoc (script content, keep)

echo hd-one

# second comment inside heredoc (keep)
echo hd-two
EXPECTED_BODY

{
  printf 'RUN echo BEFORE-HEREDOC\n'
  printf "RUN cat > /tmp/hd-test.sh <<'HD_EOF'\n"
  cat "$WORK/hd-body.expected"
  printf 'HD_EOF\n'
  printf 'RUN chmod +x /tmp/hd-test.sh\n'
  printf '# comment after heredoc (must be stripped)\n'
  printf '\n'
  printf 'RUN echo AFTER-HEREDOC\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" || fail "heredoc: compose must succeed"

# Extract the heredoc body from the composed file (between the opener's `<<`
# line and the bare terminator) and require byte identity.
awk '!inb && index($0, "<<") { inb = 1; next } inb && $0 == "HD_EOF" { exit } inb' \
  "$CF" > "$WORK/hd-body.got"
cmp -s "$WORK/hd-body.got" "$WORK/hd-body.expected" \
  || fail "heredoc: composed heredoc body differs from the fragment source body"
grep -Fxq 'HD_EOF' "$CF" \
  || fail "heredoc: bare terminator line must be preserved"
grep -Fq 'RUN echo AFTER-HEREDOC' "$CF" \
  || fail "heredoc: stripping must resume after the terminator"
! grep -Fq 'comment after heredoc' "$CF" \
  || fail "heredoc: comments after the terminator must still be stripped"

pass "quoted heredoc body byte-identical; stripping resumes after terminator"

# `<<-` opener with an indented terminator: body verbatim, indented terminator
# consumed, stripping resumed afterwards.
cat > "$WORK/hd-tabs.expected" <<'EXPECTED_BODY'
#!/bin/sh
# keep me (inside <<- heredoc)

	indented body line
	# indented comment (keep)
EXPECTED_BODY

{
  printf 'RUN echo TEAM-SIDE-INERT\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
{
  printf 'RUN echo BEFORE-TABS\n'
  printf "RUN cat > /tmp/hd-tabs.sh <<-'HD2_EOF'\n"
  cat "$WORK/hd-tabs.expected"
  printf '\tHD2_EOF\n'
  printf 'RUN echo AFTER-TABS\n'
  printf '# trailing comment (must be stripped)\n'
} > "$USER_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" || fail "heredoc <<-: compose must succeed"

awk '!inb && index($0, "<<") { inb = 1; next } inb && $0 ~ /^[[:space:]]*HD2_EOF$/ { exit } inb' \
  "$CF" > "$WORK/hd-tabs.got"
cmp -s "$WORK/hd-tabs.got" "$WORK/hd-tabs.expected" \
  || fail "heredoc <<-: composed heredoc body differs from the fragment source body"
grep -Fxq "$(printf '\tHD2_EOF')" "$CF" \
  || fail "heredoc <<-: indented terminator line must be preserved verbatim"
grep -Fq 'RUN echo AFTER-TABS' "$CF" \
  || fail "heredoc <<-: stripping must resume after the indented terminator"
! grep -Fq 'trailing comment' "$CF" \
  || fail "heredoc <<-: comments after the terminator must still be stripped"

pass "<<- heredoc with indented terminator preserved; stripping resumes"


# ---------------------------------------------------------------------------
# COPY / ADD rejection
# ---------------------------------------------------------------------------
printf 'RUN ok\nCOPY foo bar\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
if run_compose "nodejs" 2>/dev/null; then
  fail "rejection: COPY must make compose fail"
fi
grep -Fqi 'COPY/ADD' "$WORK/compose.stderr" \
  || fail "rejection: COPY error must mention COPY/ADD"

printf 'RUN ok\nADD foo.tar /x\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
if run_compose "nodejs" 2>/dev/null; then
  fail "rejection: ADD must make compose fail"
fi
# A rejected run must not leave a partial generated file behind.
[[ ! -f "$WORK/out.Containerfile" ]] || rm -f "$WORK/out.Containerfile"

pass "COPY/ADD rejected with clear error"

# ---------------------------------------------------------------------------
# Missing requested scope fails fast
# ---------------------------------------------------------------------------
printf 'RUN echo NODE\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
if run_compose "nodejs,ghostscope" 2>/dev/null; then
  fail "fail-fast: missing requested scope must error"
fi
grep -Fq 'ghostscope' "$WORK/compose.stderr" \
  || fail "fail-fast: error must name the missing scope"

pass "missing requested scope fails fast"

# ---------------------------------------------------------------------------
# `all` auto-prepended even when only team/all exists and `all` not requested
# ---------------------------------------------------------------------------
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
printf 'RUN echo TEAM-ALL\n'  > "$TEAM_DIR/overlays/Containerfile.all"
printf 'RUN echo TEAM-NODE\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose "nodejs"
got_markers="$(overlay_labels)"
expected_markers="team/all
team/nodejs"
[[ "$got_markers" == "$expected_markers" ]] \
  || fail "auto-all: expected [$expected_markers] got [$got_markers]"

pass "all auto-prepended when present (not requested)"

# ---------------------------------------------------------------------------
# DC-EMBED: rewrite, decode round-trip, modes, order, provenance, determinism
# ---------------------------------------------------------------------------
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
mkdir -p "$TEAM_DIR/overlays/files"
printf '#!/bin/sh\necho embedded-script-ran\n' > "$TEAM_DIR/overlays/files/dce-embed-me.sh"
{
  printf '# fragment doc comment above the embeds (stripped, not a directive)\n'
  printf '\n'
  printf 'RUN echo BEFORE-EMBED\n'
  printf '# DC-EMBED: files/dce-embed-me.sh /usr/local/bin/dce-embed-me.sh\n'
  printf '# plain comment between directives (stripped; directives survive)\n'
  printf '\n'
  printf '# DC-EMBED: files/dce-embed-me.sh /usr/local/bin/dce-embed-me-755 0755\n'
  printf '\n'
  printf 'RUN echo AFTER-EMBED\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose "nodejs" || fail "embed: compose must succeed with valid DC-EMBED directives"
CF="$WORK/out.Containerfile"

# Marker comments keep the readable source traceable in the generated file.
grep -Fq "# DC-EMBED files/dce-embed-me.sh -> /usr/local/bin/dce-embed-me.sh (compressed; source: $TEAM_DIR/overlays/files/dce-embed-me.sh)" "$CF" \
  || fail "embed: default-mode marker comment missing"
grep -Fq "# DC-EMBED files/dce-embed-me.sh -> /usr/local/bin/dce-embed-me-755 (compressed; source: $TEAM_DIR/overlays/files/dce-embed-me.sh)" "$CF" \
  || fail "embed: explicit-mode marker comment missing"

# Emitted RUN shape: decode | gunzip into dest, then chmod (default 0644 and
# explicit 0755, respectively). Anchored so a malformed rewrite cannot pass.
grep -Eq '^RUN printf .%s. .[A-Za-z0-9+/=]+. \| base64 -d \| gunzip > /usr/local/bin/dce-embed-me\.sh && chmod 0644 /usr/local/bin/dce-embed-me\.sh$' "$CF" \
  || fail "embed: default 0644 RUN line missing/malformed"
grep -Eq '^RUN printf .%s. .[A-Za-z0-9+/=]+. \| base64 -d \| gunzip > /usr/local/bin/dce-embed-me-755 && chmod 0755 /usr/local/bin/dce-embed-me-755$' "$CF" \
  || fail "embed: explicit 0755 RUN line missing/malformed"

# Directives are rewritten in file order, in place between fragment lines.
ln_before="$(grep -nF 'RUN echo BEFORE-EMBED' "$CF" | cut -d: -f1)"
ln_after="$(grep -nF 'RUN echo AFTER-EMBED' "$CF" | cut -d: -f1)"
ln_e1="$(grep -nFe '-> /usr/local/bin/dce-embed-me.sh (compressed' "$CF" | cut -d: -f1)"
ln_e2="$(grep -nFe '-> /usr/local/bin/dce-embed-me-755 (compressed' "$CF" | cut -d: -f1)"
(( ln_before < ln_e1 && ln_e1 < ln_e2 && ln_e2 < ln_after )) \
  || fail "embed: expected order BEFORE-EMBED < e1 < e2 < AFTER-EMBED (got $ln_before $ln_e1 $ln_e2 $ln_after)"

# Round-trip: decode the first blob and compare bytes with the source file.
# macOS BSD base64 historically wants -D, GNU wants -d; try both.
b64decode() {
  if printf '' | base64 -d >/dev/null 2>&1; then
    printf '%s' "$1" | base64 -d
  else
    printf '%s' "$1" | base64 -D
  fi
}
embed_run_line="$(grep -F 'gunzip > /usr/local/bin/dce-embed-me.sh && chmod 0644' "$CF")"
embed_re='^RUN printf .%s. .([A-Za-z0-9+/=]+). \| base64 -d \| gunzip > /usr/local/bin/dce-embed-me\.sh && chmod 0644 /usr/local/bin/dce-embed-me\.sh$'
blob=""
[[ "$embed_run_line" =~ $embed_re ]] && blob="${BASH_REMATCH[1]}"
[[ -n "$blob" ]] || fail "embed: could not extract base64 blob from the generated RUN"
b64decode "$blob" | gunzip > "$WORK/embed.decoded"
cmp -s "$WORK/embed.decoded" "$TEAM_DIR/overlays/files/dce-embed-me.sh" \
  || fail "embed: decoded bytes differ from the source file"

pass "DC-EMBED rewritten into working decode RUN (marker, 0644/0755, order, byte-exact round-trip)"

# Editing the embedded source must change the provenance content hash label
# (v2 scheme), or a rebuild would reuse a stale image; unchanged inputs must
# keep it stable.
team_hash() { grep -Eo '^LABEL dce\.team\.content_hash="[0-9a-f]{12}"' "$CF" | sed 's/.*"\([0-9a-f]*\)"/\1/'; }
h1="$(team_hash)"
run_compose "nodejs"
h2="$(team_hash)"
[[ -n "$h1" && "$h1" == "$h2" ]] || fail "embed provenance: content hash must be stable across unchanged runs"
printf '#!/bin/sh\necho embedded-script-CHANGED\n' > "$TEAM_DIR/overlays/files/dce-embed-me.sh"
run_compose "nodejs"
h3="$(team_hash)"
[[ -n "$h3" && "$h3" != "$h1" ]] || fail "embed provenance: editing the embedded source must change the content hash"

# Determinism: restore the source, compose twice, outputs must be identical.
printf '#!/bin/sh\necho embedded-script-ran\n' > "$TEAM_DIR/overlays/files/dce-embed-me.sh"
run_compose "nodejs"
cp "$CF" "$WORK/first.Containerfile"
run_compose "nodejs"
cmp -s "$WORK/first.Containerfile" "$CF" \
  || fail "embed: composing twice must yield a byte-identical file"

pass "DC-EMBED provenance sensitivity + compose determinism"

# ---------------------------------------------------------------------------
# DC-EMBED rejections: die before any output file is written
# ---------------------------------------------------------------------------
rm -f "$WORK/out.Containerfile"
# The traversal case must be rejected even though the file it points at exists.
printf 'echo pwned\n' > "$DC_ROOT/escape.sh"

reject_embed() { # <directive-line> <needle that must appear in stderr>
  local directive="$1"
  local needle="$2"
  printf 'RUN echo ok\n%s\n' "$directive" > "$TEAM_DIR/overlays/Containerfile.nodejs"
  if run_compose "nodejs"; then
    fail "embed reject: directive must fail: $directive"
  fi
  grep -Fq "$needle" "$WORK/compose.stderr" \
    || fail "embed reject: error must mention '$needle' (got: $(cat "$WORK/compose.stderr"))"
  [[ ! -e "$WORK/out.Containerfile" ]] \
    || fail "embed reject: invalid directive must abort before the output file is written"
}
reject_embed '# DC-EMBED: files/missing.sh /usr/bin/x' 'does not exist'
reject_embed '# DC-EMBED: ../../escape.sh /usr/bin/x' "'..'"
reject_embed '# DC-EMBED: /etc/passwd /usr/bin/x' 'relative'
reject_embed '# DC-EMBED: files/dce-embed-me.sh not-absolute' 'absolute path'
reject_embed '# DC-EMBED: files/dce-embed-me.sh /usr/bin/x 0999' 'octal'
reject_embed '# DC-EMBED: onlyonefield' 'DC-EMBED'
rm -f "$DC_ROOT/escape.sh"

pass "DC-EMBED rejections (missing/traversal/absolute src, relative dest, bad mode, arity)"

# ---------------------------------------------------------------------------
# COPY/ADD must still be rejected alongside DC-EMBED support
# ---------------------------------------------------------------------------
printf 'RUN ok\n# DC-EMBED: files/dce-embed-me.sh /usr/bin/x\nCOPY foo bar\n' \
  > "$TEAM_DIR/overlays/Containerfile.nodejs"
if run_compose "nodejs" 2>/dev/null; then
  fail "rejection: COPY must make compose fail even in a DC-EMBED-bearing fragment"
fi
grep -Fqi 'COPY/ADD' "$WORK/compose.stderr" \
  || fail "rejection: COPY error must mention COPY/ADD"

pass "COPY/ADD still rejected with DC-EMBED present"

# ---------------------------------------------------------------------------
# Size guard: apple/container's effective ~11.5KB cap (base64 in gRPC header)
# ---------------------------------------------------------------------------
# apple/container ships the composed Dockerfile to its builder base64-encoded
# inside a gRPC header capped at ~16,384 bytes (apple/container issue #735).
# base64 inflates by 4/3 (encoded size = ceil(bytes/3)*4), so files between
# 11,520 bytes (~15,360 encoded) and the raw 16,384-byte header cap pass a
# naive byte count but still fail the real build. Bulk filler must be
# strippable-proof content: RUN lines survive minification (comment lines
# would be stripped and the guard would never trigger).
bigline="$(printf 'x%.0s' $(seq 1 70))"
{
  echo 'RUN echo big'
  for _ in $(seq 1 260); do
    printf 'RUN echo %s\n' "$bigline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_out "$CAP_FILE" "" "nodejs" || fail "size guard: oversized output must not abort compose"
CF="$CAP_FILE"
[[ -f "$CF" ]] || fail "size guard: output file must exist"
big_bytes="$(wc -c < "$CF" | tr -d '[:space:]')"
(( big_bytes > 16384 )) \
  || fail "size guard: fixture must exceed the raw 16384-byte header cap (got $big_bytes)"
grep -Fq "$big_bytes bytes" "$WORK/compose.stderr" \
  || fail "size guard: warning must name the actual composed size"
grep -Fq '11520' "$WORK/compose.stderr" \
  || fail "size guard: warning must name the 11520-byte (~11.5KB) safe file limit"
grep -Fq '#735' "$WORK/compose.stderr" \
  || fail "size guard: warning must cite apple/container issue #735"
grep -Fq 'DC-EMBED' "$WORK/compose.stderr" \
  || fail "size guard: warning must suggest compressing via DC-EMBED"

pass "size guard: oversized output warns (non-fatal), names the 11520-byte cap, cites #735, suggests DC-EMBED"

# ---------------------------------------------------------------------------
# Size guard band: output between 11,520 and 16,384 bytes must WARN
# ---------------------------------------------------------------------------
# The old guard warned only over 16,384 bytes, so a ~12.5KB composed file
# sailed through and still failed apple/container's build. Land the fixture
# inside that band: compose a small base first, then pad with real RUN lines
# sized to cross 11,520 bytes while staying under the raw 16,384-byte header
# cap (comments/blanks are stripped at emit time, so padding must be
# instruction lines to actually grow the composed file).
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
printf 'RUN echo band-base\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose_out "$CAP_FILE" "" "nodejs"
base_bytes="$(file_bytes "$CAP_FILE")"

padline="RUN true #$(printf 'p%.0s' $(seq 1 48))"
padbytes=$(( ${#padline} + 1 ))   # + trailing newline
band_target=12500                 # comfortably inside the 11520..16384 band
npad=$(( (band_target - base_bytes + padbytes - 1) / padbytes ))
{
  printf 'RUN echo band-padded\n'
  for _ in $(seq 1 "$npad"); do
    printf '%s\n' "$padline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_out "$CAP_FILE" "" "nodejs" || fail "size guard band: compose must succeed (the size warning is non-fatal)"
CF="$CAP_FILE"
band_bytes="$(wc -c < "$CF" | tr -d '[:space:]')"
(( band_bytes > 11520 && band_bytes < 16384 )) \
  || fail "size guard band: fixture must land in the 11520..16384 band (base=$base_bytes pad=${npad}x$padbytes, got $band_bytes)"
grep -Fq "WARN: composed Containerfile is $band_bytes bytes" "$WORK/compose.stderr" \
  || fail "size guard band: output in the 11520..16384 band must warn on stderr (got: $(cat "$WORK/compose.stderr"))"
grep -Fq '11520' "$WORK/compose.stderr" \
  || fail "size guard band: warning must name the 11520-byte safe limit"
grep -Fq '#735' "$WORK/compose.stderr" \
  || fail "size guard band: warning must cite apple/container issue #735"
grep -Fq 'DC-EMBED' "$WORK/compose.stderr" \
  || fail "size guard band: warning must suggest compressing via DC-EMBED"

pass "size guard: output in the 11520..16384 band warns ($band_bytes bytes; silent under the old 16384-byte guard)"

# ---------------------------------------------------------------------------
# Size guard: output under 11,520 bytes draws no size warning
# ---------------------------------------------------------------------------
printf 'RUN echo small\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" || fail "size guard small: compose must succeed"
CF="$WORK/out.Containerfile"
small_bytes="$(wc -c < "$CF" | tr -d '[:space:]')"
(( small_bytes > 0 && small_bytes < 11520 )) \
  || fail "size guard small: fixture must be under 11520 bytes (got $small_bytes)"
! grep -q 'WARN: composed Containerfile' "$WORK/compose.stderr" \
  || fail "size guard small: output under 11520 bytes must not draw a size warning (got: $(cat "$WORK/compose.stderr"))"

pass "size guard: output under 11520 bytes draws no size warning ($small_bytes bytes)"

# ---------------------------------------------------------------------------
# Heredoc bodies keep CMD/ENTRYPOINT/FROM-looking lines byte-identically
# ---------------------------------------------------------------------------
# The strip used to be an awk pre-pass over the RAW fragment (before the
# heredoc walker), silently deleting heredoc body lines that start with
# CMD/ENTRYPOINT (and a leading FROM... anywhere). Now the strip lives in the
# heredoc-aware walker: content lines only. A FROM on the fragment's very
# first line and top-level CMD/ENTRYPOINT lines must still be stripped.
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true

cat > "$WORK/hd-kw.expected" <<'EXPECTED_BODY'
CMD echo inside-heredoc-cmd
ENTRYPOINT ["/bin/inside-heredoc-ep"]
FROM inside-heredoc-from
# not a Containerfile comment: heredoc script content

blank line inside heredoc (keep)
EXPECTED_BODY

{
  printf 'FROM dce-base:latest\n'
  printf '# fragment doc comment (must be stripped)\n'
  printf 'RUN echo BEFORE-KEYWORDS\n'
  printf "RUN cat > /tmp/hd-kw.sh <<'HD_KW_EOF'\n"
  cat "$WORK/hd-kw.expected"
  printf 'HD_KW_EOF\n'
  printf 'CMD ["echo", "stripped-top-level"]\n'
  printf 'ENTRYPOINT ["/tmp/stripped-top-level-ep"]\n'
  printf 'RUN echo AFTER-KEYWORDS\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" || fail "heredoc keywords: compose must succeed"
CF="$WORK/out.Containerfile"

awk '!inb && index($0, "<<") { inb = 1; next } inb && $0 == "HD_KW_EOF" { exit } inb' \
  "$CF" > "$WORK/hd-kw.got"
cmp -s "$WORK/hd-kw.got" "$WORK/hd-kw.expected" \
  || fail "heredoc keywords: body with CMD/ENTRYPOINT/FROM/# lines must survive byte-identically (got: $(cat "$WORK/hd-kw.got"))"

[[ "$(grep -Ecx 'FROM dce-base:latest' "$CF")" -eq 1 ]] \
  || fail "heredoc keywords: expected exactly one whole-line 'FROM dce-base:latest' (fragment's leading FROM must be stripped)"
grep -Fxq 'FROM inside-heredoc-from' "$CF" \
  || fail "heredoc keywords: FROM-looking line inside the heredoc body must survive"
grep -Fcx 'ENTRYPOINT ["/bin/inside-heredoc-ep"]' "$CF" | grep -qx 1 \
  || fail "heredoc keywords: ENTRYPOINT-looking line inside the heredoc body must survive"
! grep -Fqi 'stripped-top-level' "$CF" \
  || fail "heredoc keywords: top-level CMD/ENTRYPOINT outside the heredoc must still be stripped"
grep -Fq 'RUN echo AFTER-KEYWORDS' "$CF" \
  || fail "heredoc keywords: stripping must resume after the terminator"
! grep -Fq 'never terminated' "$WORK/compose.stderr" \
  || fail "heredoc keywords: closed heredoc must not warn"

pass "heredoc body keeps CMD/ENTRYPOINT/FROM lines verbatim; top-level strip intact"

# ---------------------------------------------------------------------------
# Exotic heredoc delimiters (EOF.V2 quoted, EOF-2 bare) stay verbatim
# ---------------------------------------------------------------------------
cat > "$WORK/hd-exotic.expected" <<'EXPECTED_BODY'
# comment inside exotic-delimited heredoc (keep)

	tab-indented line after blank (keep)
EXPECTED_BODY

{
  printf 'RUN echo BEFORE-EXOTIC\n'
  printf "RUN cat > /tmp/hd-exotic.sh <<'EOF.V2'\n"
  cat "$WORK/hd-exotic.expected"
  printf 'EOF.V2\n'
  printf 'RUN echo AFTER-EXOTIC\n'
  printf '# after exotic heredoc (must be stripped)\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" || fail "heredoc exotic: compose must succeed with quoted 'EOF.V2' delimiter"
CF="$WORK/out.Containerfile"
! grep -Fq 'never terminated' "$WORK/compose.stderr" \
  || fail "heredoc exotic: EOF.V2 terminator must be recognized (no unclosed warning)"
awk '!inb && index($0, "<<") { inb = 1; next } inb && $0 == "EOF.V2" { exit } inb' \
  "$CF" > "$WORK/hd-exotic.got"
cmp -s "$WORK/hd-exotic.got" "$WORK/hd-exotic.expected" \
  || fail "heredoc exotic: quoted EOF.V2 body must be byte-identical (comments/blanks intact)"
grep -Fq 'RUN echo AFTER-EXOTIC' "$CF" \
  || fail "heredoc exotic: stripping must resume after the EOF.V2 terminator"
! grep -Fq 'after exotic heredoc' "$CF" \
  || fail "heredoc exotic: comments after the EOF.V2 terminator must be stripped"

{
  printf 'RUN echo BEFORE-EXOTIC-BARE\n'
  printf 'RUN cat > /tmp/hd-exotic2.sh <<EOF-2\n'
  printf '# bare EOF-2 body comment (keep)\n'
  printf 'EOF-2\n'
  printf 'RUN echo AFTER-EXOTIC-BARE\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" || fail "heredoc exotic: compose must succeed with bare EOF-2 delimiter"
CF="$WORK/out.Containerfile"
! grep -Fq 'never terminated' "$WORK/compose.stderr" \
  || fail "heredoc exotic: EOF-2 terminator must be recognized (no unclosed warning)"
grep -Fxq '# bare EOF-2 body comment (keep)' "$CF" \
  || fail "heredoc exotic: bare-delimiter body comment must survive"
grep -Fq 'RUN echo AFTER-EXOTIC-BARE' "$CF" \
  || fail "heredoc exotic: stripping must resume after the EOF-2 terminator"

pass "exotic heredoc delimiters (<<'EOF.V2', <<EOF-2) recognized; bodies verbatim"

# ---------------------------------------------------------------------------
# False opener (bit-shift): unclosed-heredoc warning, rest copied verbatim
# ---------------------------------------------------------------------------
{
  printf 'RUN echo BEFORE-FALSE-OPEN\n'
  # shellcheck disable=SC2016  # literal bit-shift text is the point: it must reach compose unexpanded
  printf 'RUN echo $((1<<2))\n'
  printf '# inside false heredoc: would-be comment (kept verbatim)\n'
  printf 'CMD echo would-be-stripped-if-not-in-body\n'
  printf 'RUN echo AFTER-FALSE-OPEN\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" \
  || fail "false opener: compose must succeed (unclosed-heredoc warning is non-fatal)"
CF="$WORK/out.Containerfile"
grep -Fq 'never terminated' "$WORK/compose.stderr" \
  || fail "false opener: expected unclosed-heredoc warning on stderr (got: $(cat "$WORK/compose.stderr"))"
grep -Fq "delimiter '2' is never terminated" "$WORK/compose.stderr" \
  || fail "false opener: warning must name the false delimiter"
grep -Fq "$TEAM_DIR/overlays/Containerfile.nodejs" "$WORK/compose.stderr" \
  || fail "false opener: warning must name the fragment"
grep -Fxq '# inside false heredoc: would-be comment (kept verbatim)' "$CF" \
  || fail "false opener: rest of fragment must be copied verbatim (comments not stripped)"
grep -Fxq 'CMD echo would-be-stripped-if-not-in-body' "$CF" \
  || fail "false opener: rest of fragment must be copied verbatim (CMD not stripped)"
# shellcheck disable=SC2016  # literal bit-shift text asserted verbatim
if ! grep -Fq '$((1<<2))' "$CF" || ! grep -Fq 'RUN echo AFTER-FALSE-OPEN' "$CF"; then
  fail "false opener: opener line and the rest must reach the composed output"
fi

# shellcheck disable=SC2016  # literal bit-shift text in the label, on purpose
pass 'false opener RUN echo $((1<<2)): warns non-fatally and copies the rest verbatim'

# ---------------------------------------------------------------------------
# Directive-looking line INSIDE a heredoc body: data, not a directive
# ---------------------------------------------------------------------------
# Neither validated (an invalid directive form must not kill compose when it
# is heredoc data), nor rewritten, nor folded into the provenance content
# hash (only directives compose actually rewrites may fold their src).
{
  printf 'RUN echo BEFORE-DIR-IN-HEREDOC\n'
  printf "RUN cat > /tmp/hd-dir.sh <<'HD_DIR_EOF'\n"
  printf '# DC-EMBED: files/heredoc-only.sh /usr/bin/hd-dir-probe\n'
  printf '#!/bin/sh\n'
  printf 'HD_DIR_EOF\n'
  printf 'RUN echo AFTER-DIR-IN-HEREDOC\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
# files/heredoc-only.sh deliberately does NOT exist here: if validation
# treated the body line as a real directive, compose would die.
run_compose "nodejs" \
  || fail "directive-in-heredoc: compose must succeed (heredoc body line is not validated)"
CF="$WORK/out.Containerfile"
grep -Fxq '# DC-EMBED: files/heredoc-only.sh /usr/bin/hd-dir-probe' "$CF" \
  || fail "directive-in-heredoc: body line must be emitted verbatim"
! grep -Fq 'hd-dir-probe (compressed' "$CF" \
  || fail "directive-in-heredoc: body line must not be rewritten into marker/RUN"
! grep -Fq 'never terminated' "$WORK/compose.stderr" \
  || fail "directive-in-heredoc: closed heredoc must not warn"

# Provenance: with the file present, editing ONLY the embedded-looking file
# must not change the content hash (fragment bytes are unchanged, and a
# heredoc-body directive is never folded).
printf 'echo heredoc-only-v1\n' > "$TEAM_DIR/overlays/files/heredoc-only.sh"
run_compose "nodejs" || fail "directive-in-heredoc: compose must succeed with the file present"
CF="$WORK/out.Containerfile"
h_heredoc_1="$(team_hash)"
printf 'echo heredoc-only-v2\n' > "$TEAM_DIR/overlays/files/heredoc-only.sh"
run_compose "nodejs" || fail "directive-in-heredoc: compose must succeed after editing the file"
CF="$WORK/out.Containerfile"
h_heredoc_2="$(team_hash)"
[[ -n "$h_heredoc_1" && "$h_heredoc_1" == "$h_heredoc_2" ]] \
  || fail "directive-in-heredoc: provenance must not fold a heredoc-body directive (hash changed $h_heredoc_1 -> $h_heredoc_2)"
rm -f "$TEAM_DIR/overlays/files/heredoc-only.sh"

pass "directive-looking line inside heredoc: verbatim, unvalidated, not hashed"

# ---------------------------------------------------------------------------
# DC-EMBED src symlink containment: outside the overlays dir is fatal
# ---------------------------------------------------------------------------
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR"/overlays/Containerfile.* 2>/dev/null || true
rm -f "$WORK/out.Containerfile"

# A symlink resolving INSIDE the overlays dir is fine (relative target).
printf '#!/bin/sh\necho internal-link-ok\n' > "$TEAM_DIR/overlays/files/internal-target.sh"
ln -sf internal-target.sh "$TEAM_DIR/overlays/files/internal-link.sh"
printf 'RUN echo ok\n# DC-EMBED: files/internal-link.sh /usr/bin/x\n' \
  > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose "nodejs" \
  || fail "symlink containment: an internal symlink src must still compose"

# A symlink climbing OUT of the overlays dir (relative .. target) is fatal,
# and must abort before the output file is written.
printf 'echo pwned-via-symlink\n' > "$TEAM_DIR/escape.sh"
ln -sf ../../escape.sh "$TEAM_DIR/overlays/files/evil-link.sh"
printf 'RUN echo ok\n# DC-EMBED: files/evil-link.sh /usr/bin/x\n' \
  > "$TEAM_DIR/overlays/Containerfile.nodejs"
# The internal-link run above left a composed file behind; the failing run
# below must not leave one of its own.
rm -f "$WORK/out.Containerfile"
if run_compose "nodejs"; then
  fail "symlink containment: compose must fail when the src symlink resolves outside the overlays dir"
fi
grep -Fq 'evil-link.sh' "$WORK/compose.stderr" \
  || fail "symlink containment: error must name the src (got: $(cat "$WORK/compose.stderr"))"
grep -Fqi 'outside the overlays dir' "$WORK/compose.stderr" \
  || fail "symlink containment: error must name the containment rule"
[[ ! -e "$WORK/out.Containerfile" ]] \
  || fail "symlink containment: must abort before the output file is written"

rm -f "$TEAM_DIR/overlays/files/evil-link.sh" "$TEAM_DIR/overlays/files/internal-link.sh" \
  "$TEAM_DIR/overlays/files/internal-target.sh" "$TEAM_DIR/escape.sh"

pass "symlinked DC-EMBED src: internal target composes, escaping target dies at validate"

# ---------------------------------------------------------------------------
# --backend flag: omitted default must be byte-identical to --backend apple
# ---------------------------------------------------------------------------
# The flag is optional and fail-safe: forgetting it on a docker-family backend
# must never change bytes, so a stale cap can never bite. Same fixture, two
# runs, byte-compare.
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
mkdir -p "$TEAM_DIR/overlays/files"
printf '#!/bin/sh\necho backend-probe\n' > "$TEAM_DIR/overlays/files/backend-probe.sh"
{
  printf '# readable-vs-apple fragment comment (stripped in apple mode)\n'
  printf '\n'
  printf 'RUN echo BACKEND-MODE-PROBE\n'
  printf 'CMD ["echo", "mode-probe-stripped-cmd"]\n'
  printf '# DC-EMBED: files/backend-probe.sh /usr/local/bin/backend-probe\n'
  printf '# DC-EMBED: files/backend-probe.sh /usr/local/bin/backend-probe-755 0755\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose "nodejs" || fail "backend default: positional compose must succeed"
cp "$WORK/out.Containerfile" "$WORK/default.Containerfile"
run_compose_backend apple "nodejs" || fail "backend apple: compose must succeed"
cp "$WORK/out.Containerfile" "$WORK/apple.Containerfile"
cmp -s "$WORK/default.Containerfile" "$WORK/apple.Containerfile" \
  || fail "backend default: omitted flag must be byte-identical to --backend apple"
grep -Fq 'BACKEND-MODE-PROBE' "$WORK/default.Containerfile" \
  || fail "backend default: probe line missing from composed output"

pass "--backend omitted == --backend apple (byte-identical; fail-safe default)"

# ---------------------------------------------------------------------------
# Provenance ARG/LABEL block is byte-identical across modes
# ---------------------------------------------------------------------------
# The v2 hash hashes sources (not composed bytes), so the provenance block
# must not depend on the backend mode: image identity stays comparable.
run_compose_backend docker "nodejs" || fail "backend docker: compose must succeed"
cp "$WORK/out.Containerfile" "$WORK/readable.Containerfile"
prov_apple="$(grep -E '^(ARG|LABEL) ' "$WORK/apple.Containerfile")"
prov_readable="$(grep -E '^(ARG|LABEL) ' "$WORK/readable.Containerfile")"
[[ "$prov_apple" == "$prov_readable" && -n "$prov_apple" ]] \
  || fail "provenance block: ARG/LABEL lines must be identical across modes (apple: [$prov_apple] readable: [$prov_readable])"

pass "provenance ARG/LABEL block identical across apple and readable modes"

# ---------------------------------------------------------------------------
# Readable mode: DC-EMBED as verbatim heredoc, minification off, strip intact
# ---------------------------------------------------------------------------
CF="$WORK/readable.Containerfile"

# Full fragment block characterization: comments/blank lines preserved, the
# top-level CMD stripped, directives rewritten into heredoc RUN pairs with
# the source bytes verbatim between opener and terminator, chmod per mode
# (explicit 0755 and default 0644), and markers without "(compressed".
expected_block="$(cat <<EXPECTED_BLOCK
# readable-vs-apple fragment comment (stripped in apple mode)

RUN echo BACKEND-MODE-PROBE
# DC-EMBED files/backend-probe.sh -> /usr/local/bin/backend-probe (source: $TEAM_DIR/overlays/files/backend-probe.sh)
RUN cat > /usr/local/bin/backend-probe <<'DCE_EMBED_EOF'
#!/bin/sh
echo backend-probe
DCE_EMBED_EOF
RUN chmod 0644 /usr/local/bin/backend-probe
# DC-EMBED files/backend-probe.sh -> /usr/local/bin/backend-probe-755 (source: $TEAM_DIR/overlays/files/backend-probe.sh)
RUN cat > /usr/local/bin/backend-probe-755 <<'DCE_EMBED_EOF'
#!/bin/sh
echo backend-probe
DCE_EMBED_EOF
RUN chmod 0755 /usr/local/bin/backend-probe-755
EXPECTED_BLOCK
)"
block="$(awk -v b="# --- begin overlay:auto:team/nodejs ---" \
              -v e="# --- end overlay:auto:team/nodejs ---" \
              '$0 == b { f = 1; next } $0 == e { f = 0 } f' "$CF")"
[[ "$block" == "$expected_block" ]] \
  || fail "readable embed: fragment block differs from expected readable form (got: [$block])"

grep -Fxq "RUN cat > /usr/local/bin/backend-probe <<'DCE_EMBED_EOF'" "$CF" \
  || fail "readable embed: quoted-heredoc opener RUN missing/malformed"
grep -Fxq 'RUN chmod 0755 /usr/local/bin/backend-probe-755' "$CF" \
  || fail "readable embed: explicit 0755 chmod missing (fixture carries a 0755 directive)"
! grep -Fq '(compressed' "$CF" \
  || fail "readable embed: marker must not claim compression"
! grep -Fq 'mode-probe-stripped-cmd' "$CF" \
  || fail "readable embed: top-level fragment CMD must still be stripped"
# Base64 blobs must not appear anywhere in readable output (the point of the
# mode: build errors point at real lines, not opaque encoded text).
! grep -Eq 'base64 -d \| gunzip' "$CF" \
  || fail "readable embed: encoded decode RUN must not appear in readable mode"

pass "readable mode: verbatim heredoc embeds, 0644/0755 chmods, comments/blanks kept, CMD stripped"

# ---------------------------------------------------------------------------
# Readable mode: delimiter collision resolved deterministically
# ---------------------------------------------------------------------------
# A source that itself contains a line equal to the default delimiter would
# terminate the heredoc early; compose must pick a suffixed one (_2, _3, ...)
# deterministically and keep the body byte-intact.
printf '#!/bin/sh\necho collision-probe\nDCE_EMBED_EOF\n' > "$TEAM_DIR/overlays/files/collision-probe.sh"
printf '# DC-EMBED: files/collision-probe.sh /usr/local/bin/collision-probe\n' \
  > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_backend docker "nodejs" || fail "collision: compose must succeed with a colliding source"
CF="$WORK/out.Containerfile"
grep -Fxq "RUN cat > /usr/local/bin/collision-probe <<'DCE_EMBED_EOF_2'" "$CF" \
  || fail "collision: expected the deterministic DCE_EMBED_EOF_2 delimiter"
grep -Fxq 'DCE_EMBED_EOF_2' "$CF" \
  || fail "collision: terminator line missing"
awk '!inb && index($0, "<<") { inb = 1; next } inb && $0 == "DCE_EMBED_EOF_2" { exit } inb' \
  "$CF" > "$WORK/collision.got"
cmp -s "$WORK/collision.got" "$TEAM_DIR/overlays/files/collision-probe.sh" \
  || fail "collision: heredoc body must carry the source bytes verbatim (including the DCE_EMBED_EOF line)"
run_compose_backend docker "nodejs"
cmp -s "$WORK/out.Containerfile" "$CF" \
  || fail "collision: delimiter choice must be deterministic across runs"

pass "readable mode: colliding delimiter disambiguated deterministically (body intact)"

# ---------------------------------------------------------------------------
# Readable mode: source without a trailing newline still well-formed
# ---------------------------------------------------------------------------
# A source whose last byte is not a newline must not glue cat's output onto
# the heredoc terminator (the heredoc would never close and the rest of the
# composed file would be swallowed). Emission closes the line first; the
# remaining divergence is the dest gaining that one newline. Apple mode's
# decode round-trip must still preserve the exact source bytes.
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
printf 'echo no-trailing-newline-probe' > "$TEAM_DIR/overlays/files/no-newline-probe.sh"
printf '# DC-EMBED: files/no-newline-probe.sh /usr/local/bin/no-newline-probe\n' \
  > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_backend docker "nodejs" || fail "no-newline: readable compose must succeed"
CF="$WORK/out.Containerfile"
grep -Fxq "RUN cat > /usr/local/bin/no-newline-probe <<'DCE_EMBED_EOF'" "$CF" \
  || fail "no-newline: quoted-heredoc opener missing"
grep -Fxq 'DCE_EMBED_EOF' "$CF" \
  || fail "no-newline: terminator must sit alone on its own line (source lacks a trailing newline)"
awk -v opener="RUN cat > /usr/local/bin/no-newline-probe <<'DCE_EMBED_EOF'" \
  '$0 == opener { inb = 1; next } inb && $0 == "DCE_EMBED_EOF" { exit } inb' \
  "$CF" > "$WORK/no-newline.got"
printf 'echo no-trailing-newline-probe\n' > "$WORK/no-newline.expected"
cmp -s "$WORK/no-newline.got" "$WORK/no-newline.expected" \
  || fail "no-newline: readable body must be the source bytes + one appended newline"

run_compose "nodejs" || fail "no-newline: apple compose must succeed"
CF="$WORK/out.Containerfile"
embed_run_line="$(grep -F 'gunzip > /usr/local/bin/no-newline-probe && chmod 0644' "$CF")"
embed_re='^RUN printf .%s. .([A-Za-z0-9+/=]+). \| base64 -d \| gunzip > /usr/local/bin/no-newline-probe && chmod 0644 /usr/local/bin/no-newline-probe$'
blob=""
[[ "$embed_run_line" =~ $embed_re ]] && blob="${BASH_REMATCH[1]}"
[[ -n "$blob" ]] || fail "no-newline: could not extract the apple-mode blob"
b64decode "$blob" | gunzip > "$WORK/no-newline.apple"
cmp -s "$WORK/no-newline.apple" "$TEAM_DIR/overlays/files/no-newline-probe.sh" \
  || fail "no-newline: apple decode must preserve the source bytes exactly (no newline appended)"

pass "readable mode: newline-less source emits a well-formed heredoc; apple round-trip byte-exact"

# ---------------------------------------------------------------------------
# Readable mode: comment lines never open heredocs (validator parity)
# ---------------------------------------------------------------------------
# validate_overlay_file and dce_embed_directive_args drop comment lines
# BEFORE heredoc tracking, so a `<<` inside a comment is never an opener for
# validation/provenance. Readable emission must classify identically: emit
# the comment verbatim but skip tracking, or a phantom heredoc would make
# the following directive be copied verbatim instead of rewritten.
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
printf '#!/bin/sh\necho comment-hd-probe\n' > "$TEAM_DIR/overlays/files/comment-hd-probe.sh"
{
  printf 'RUN echo BEFORE-COMMENT-HEREDOC\n'
  printf "# tip: use <<'EOF' in RUN cat\n"
  printf '# DC-EMBED: files/comment-hd-probe.sh /usr/local/bin/comment-hd-probe\n'
  printf 'RUN echo AFTER-COMMENT-HEREDOC\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_backend docker "nodejs" \
  || fail "comment heredoc: readable compose must succeed"
CF="$WORK/out.Containerfile"
! grep -Fq 'never terminated' "$WORK/compose.stderr" \
  || fail "comment heredoc: a comment's << must not open a heredoc (unclosed warning fired)"
grep -Fxq "# tip: use <<'EOF' in RUN cat" "$CF" \
  || fail "comment heredoc: readable mode must emit the comment verbatim"
grep -Fxq "RUN cat > /usr/local/bin/comment-hd-probe <<'DCE_EMBED_EOF'" "$CF" \
  || fail "comment heredoc: the directive after a <<-bearing comment must still be rewritten in readable mode"
grep -Fxq 'RUN chmod 0644 /usr/local/bin/comment-hd-probe' "$CF" \
  || fail "comment heredoc: rewritten directive must carry its chmod"

run_compose_backend apple "nodejs" \
  || fail "comment heredoc: apple compose must succeed"
CF="$WORK/out.Containerfile"
grep -Eq '^RUN printf .%s. .[A-Za-z0-9+/=]+. \| base64 -d \| gunzip > /usr/local/bin/comment-hd-probe && chmod 0644 /usr/local/bin/comment-hd-probe$' "$CF" \
  || fail "comment heredoc: apple mode must still rewrite the directive into a decode RUN"
! grep -Fq 'tip: use' "$CF" \
  || fail "comment heredoc: apple mode must still drop comment lines"
! grep -Fq 'never terminated' "$WORK/compose.stderr" \
  || fail "comment heredoc: apple mode must not warn (comments dropped before tracking)"

pass "readable mode: comments never open heredocs (directive after a <<-bearing comment rewritten; apple shape unchanged)"

# ---------------------------------------------------------------------------
# Readable mode: COPY/ADD rejection unchanged
# ---------------------------------------------------------------------------
printf 'RUN ok\nCOPY foo bar\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
if run_compose_backend docker "nodejs"; then
  fail "readable reject: COPY must make compose fail in readable mode too"
fi
grep -Fqi 'COPY/ADD' "$WORK/compose.stderr" \
  || fail "readable reject: COPY error must mention COPY/ADD"
rm -f "$WORK/out.Containerfile"

pass "readable mode: COPY/ADD still rejected"

# ---------------------------------------------------------------------------
# Readable mode: no size guard (oversized output draws no WARN)
# ---------------------------------------------------------------------------
# The guard exists only for apple's base64-in-gRPC-header transport; readable
# files have no cap, so the same bulk that warns in apple mode stays silent.
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
bigline="$(printf 'x%.0s' $(seq 1 70))"
{
  echo 'RUN echo big-readable'
  for _ in $(seq 1 260); do
    printf 'RUN echo %s\n' "$bigline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_backend docker "nodejs" || fail "readable size: compose must succeed"
CF="$WORK/out.Containerfile"
big_bytes="$(wc -c < "$CF" | tr -d '[:space:]')"
(( big_bytes > 11520 )) \
  || fail "readable size: fixture must exceed the 11520-byte apple cap (got $big_bytes)"
! grep -q 'WARN: composed Containerfile' "$WORK/compose.stderr" \
  || fail "readable size: no size guard output allowed in readable mode (got: $(cat "$WORK/compose.stderr"))"
# Sanity: the same fixture DOES warn in apple mode (guard still armed there).
# Sanity: the same fixture DOES warn in apple mode (guard still armed). The
# apple run goes to the basename-conforming CAP_FILE: over-cap apple output
# without a Containerfile.<hash> basename cannot be split into part files.
run_compose_out "$CAP_FILE" "" "nodejs"
grep -Fq 'WARN: composed Containerfile' "$WORK/compose.stderr" \
  || fail "readable size: apple mode must still warn on the same oversized fixture"

pass "readable mode: oversized output draws no size guard WARN ($big_bytes bytes); apple mode still warns"

# ---------------------------------------------------------------------------
# Readable mode: determinism (compose twice -> byte-identical)
# ---------------------------------------------------------------------------
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
{
  printf '# deterministic-readable comment\n'
  printf '\n'
  printf 'RUN echo DETERMINISM-READABLE\n'
  printf '# DC-EMBED: files/backend-probe.sh /usr/local/bin/backend-probe 0755\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_backend docker "nodejs" || fail "readable determinism: first compose must succeed"
cp "$WORK/out.Containerfile" "$WORK/readable-first.Containerfile"
run_compose_backend docker "nodejs" || fail "readable determinism: second compose must succeed"
cmp -s "$WORK/readable-first.Containerfile" "$WORK/out.Containerfile" \
  || fail "readable determinism: composing twice must yield a byte-identical file"

pass "readable mode: composing twice is byte-identical"

# ---------------------------------------------------------------------------
# --backend validation: case-insensitive names; unknown/missing value dies
# ---------------------------------------------------------------------------
run_compose_backend APPLE "nodejs" \
  || fail "backend validation: --backend must be matched case-insensitively (APPLE)"
grep -Fq '(compressed; source:' "$WORK/out.Containerfile" \
  || fail "backend validation: APPLE must resolve to apple mode (encoded output)"
run_compose_backend Docker "nodejs" \
  || fail "backend validation: --backend must be matched case-insensitively (Docker)"
grep -Fq "RUN cat > /usr/local/bin/backend-probe <<'DCE_EMBED_EOF'" "$WORK/out.Containerfile" \
  || fail "backend validation: Docker must resolve to readable mode (heredoc output)"

# usage() prints to stdout (existing unknown-flag convention); dce_die prints
# the ERROR line to stderr. Capture both streams and check each.
if bash "$COMPOSE" --backend containerd "$WORK/out.Containerfile" nodejs >"$WORK/compose.stdout" 2>"$WORK/compose.stderr"; then
  fail "backend validation: unknown backend must die"
fi
grep -Fq 'containerd' "$WORK/compose.stderr" \
  || fail "backend validation: unknown-backend error must name the value (got: $(cat "$WORK/compose.stderr"))"
grep -Fqi 'usage' "$WORK/compose.stdout" \
  || fail "backend validation: unknown-backend error must show usage"

rm -f "$WORK/out.Containerfile"
if bash "$COMPOSE" --backend >"$WORK/compose.stdout" 2>"$WORK/compose.stderr"; then
  fail "backend validation: --backend with no value must die"
fi
grep -Fqi 'usage' "$WORK/compose.stdout" \
  || fail "backend validation: missing-value error must show usage"
[[ ! -e "$WORK/out.Containerfile" ]] \
  || fail "backend validation: a rejected flag run must not write the output file"

pass "--backend validation: case-insensitive apple/docker names; unknown or missing value dies with usage"

# ---------------------------------------------------------------------------
# Apple transport chaining: over-cap composed file -> chained part files
# ---------------------------------------------------------------------------
# When the apple-mode composed file exceeds the 11,520-byte transport cap,
# compose additionally derives part files Containerfile.<hash>.p0, .p1, ...
# next to it: each part is a small standalone Dockerfile (FROM dce-base, then
# FROM the previous dce-stage-<hash>-<k>) under the cap, so apple/container
# can build the image as a sequence of small builds (the Dockerfile travels
# base64-encoded inside a ~16KB gRPC header; issue #735). The canonical file
# stays byte-identical and remains the single source of truth; readable mode
# never splits. Fixture sizing reuses the band test's adaptive padding
# technique: measure a small compose, then pad with real RUN units (comments/
# blanks are stripped at emit time, so padding must be instruction units).
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
chain_hash="0123456789abcdef"
part_file="$WORK/Containerfile.$chain_hash"

printf 'RUN echo chain-base\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose_out "$part_file" "" "nodejs"
chain_base_bytes="$(file_bytes "$part_file")"

chain_padline="RUN true #$(printf 'c%.0s' $(seq 1 48))"
chain_padbytes=$(( ${#chain_padline} + 1 ))   # + trailing newline
chain_target=42000
chain_npad=$(( (chain_target - chain_base_bytes + chain_padbytes - 1) / chain_padbytes ))
{
  printf 'RUN echo chain-padded\n'
  for _ in $(seq 1 "$chain_npad"); do
    printf '%s\n' "$chain_padline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_out "$part_file" "" "nodejs" || fail "parts: over-cap apple compose must succeed"
cf_part="$part_file"
chain_bytes="$(file_bytes "$cf_part")"
(( chain_bytes > 11520 )) || fail "parts: fixture must exceed the 11520-byte cap (got $chain_bytes)"

# Part set: exactly contiguous p0..pN-1.
parts_idx="$(list_parts "$part_file")"
[[ -n "$parts_idx" ]] || fail "parts: over-cap apple compose must emit part files (got none)"
mapfile -t parts_arr <<< "$parts_idx"
n_parts=${#parts_arr[@]}
(( n_parts >= 2 )) || fail "parts: expected >= 2 part files, got $n_parts"
for ((i = 0; i < n_parts; i++)); do
  [[ "${parts_arr[$i]}" == "$i" ]] \
    || fail "parts: expected contiguous p0..p$((n_parts-1)), got [${parts_arr[*]}]"
done
if [[ -e "$part_file.p$n_parts" ]]; then
  fail "parts: unexpected extra part file .p$n_parts"
fi

# Every part stays under the cap (this fixture has no oversized single unit).
chain_max_bytes=0
for ((i = 0; i < n_parts; i++)); do
  b="$(file_bytes "$part_file.p$i")"
  if (( b > 11520 )); then
    fail "parts: .p$i is $b bytes, over the 11520-byte cap"
  fi
  if (( b > chain_max_bytes )); then
    chain_max_bytes=$b
  fi
done

# FROM chaining: p0 reuses dce-base; pk resumes the previous stage image.
[[ "$(sed -n '1p' "$part_file.p0")" == *"part 0/$n_parts "* ]] \
  || fail "parts: p0 header must name part 0/$n_parts (got: $(sed -n '1p' "$part_file.p0"))"
[[ "$(sed -n '2p' "$part_file.p0")" == "FROM dce-base:latest" ]] \
  || fail "parts: p0 line 2 must be FROM dce-base:latest (got: $(sed -n '2p' "$part_file.p0"))"
for ((i = 1; i < n_parts; i++)); do
  [[ "$(sed -n '1p' "$part_file.p$i")" == *"part $i/$n_parts "* ]] \
    || fail "parts: p$i header must name part $i/$n_parts"
  [[ "$(sed -n '2p' "$part_file.p$i")" == "FROM dce-stage-$chain_hash-$((i-1)):latest" ]] \
    || fail "parts: p$i line 2 must chain FROM dce-stage-$chain_hash-$((i-1)):latest (got: $(sed -n '2p' "$part_file.p$i"))"
done

# Provenance ARG/LABEL block, scopes comment, and the USER-dev trailer only
# in the final part.
part_last=$(( n_parts - 1 ))
for ((i = 0; i < part_last; i++)); do
  if grep -Eq '^(ARG|LABEL|USER|ENTRYPOINT|CMD)([[:space:]]|$)' "$part_file.p$i"; then
    fail "parts: non-final .p$i must not carry ARG/LABEL/USER/ENTRYPOINT/CMD lines"
  fi
  if grep -Fq '# Selected overlay scopes:' "$part_file.p$i"; then
    fail "parts: non-final .p$i must not carry the scopes comment"
  fi
done
grep -Eq '^LABEL dce\.version=' "$part_file.p$part_last" \
  || fail "parts: final part must carry the provenance LABEL block"
grep -Fq '# Selected overlay scopes:' "$part_file.p$part_last" \
  || fail "parts: final part must carry the scopes comment"
grep -Fxq 'USER dev' "$part_file.p$part_last" \
  || fail "parts: final part must carry USER dev"
grep -Fxq 'ENTRYPOINT ["/home/dev/.local/bin/dce-entrypoint"]' "$part_file.p$part_last" \
  || fail "parts: final part must carry the ENTRYPOINT"
grep -Fxq 'CMD ["sleep", "infinity"]' "$part_file.p$part_last" \
  || fail "parts: final part must carry the CMD"

# Every canonical instruction lands in exactly one part (RUN count matches),
# and the entrypoint-runner heredoc stays whole inside the final part.
canon_runs="$(grep -Ec '^RUN ' "$cf_part" || true)"
sum_runs=0
for ((i = 0; i < n_parts; i++)); do
  r="$(grep -Ec '^RUN ' "$part_file.p$i" || true)"
  sum_runs=$(( sum_runs + r ))
done
(( canon_runs >= 2 )) || fail "parts: fixture must contain RUN instructions"
[[ "$canon_runs" == "$sum_runs" ]] \
  || fail "parts: RUN count mismatch canonical=$canon_runs parts=$sum_runs"
for ((i = 0; i < part_last; i++)); do
  if grep -Fq 'DC_ENTRYPOINT_EOF' "$part_file.p$i"; then
    fail "parts: entrypoint-runner heredoc must not split across parts (.p$i)"
  fi
done
runner_opener="RUN cat > /home/dev/.local/bin/dce-entrypoint <<'DC_ENTRYPOINT_EOF'"
awk -v o="$runner_opener" '$0 == o { f = 1; next } f && $0 == "DC_ENTRYPOINT_EOF" { exit } f' \
  "$cf_part" > "$WORK/runner.canon"
awk -v o="$runner_opener" '$0 == o { f = 1; next } f && $0 == "DC_ENTRYPOINT_EOF" { exit } f' \
  "$part_file.p$part_last" > "$WORK/runner.part"
cmp -s "$WORK/runner.canon" "$WORK/runner.part" \
  || fail "parts: entrypoint-runner heredoc body differs inside the final part"

# Extended size-guard WARN: names the part count and the largest part.
grep -Fq "WARN: composed Containerfile is $chain_bytes bytes" "$WORK/compose.stderr" \
  || fail "parts: static over-cap WARN missing"
grep -Fq "WARN: composed Containerfile split into $n_parts transport part files" "$WORK/compose.stderr" \
  || fail "parts: split WARN must name the part count (got: $(cat "$WORK/compose.stderr"))"
grep -Fq "(largest part $chain_max_bytes bytes)" "$WORK/compose.stderr" \
  || fail "parts: split WARN must name the largest part size ($chain_max_bytes)"

# Determinism: recompose -> byte-identical canonical file and parts.
for ((i = 0; i < n_parts; i++)); do
  cp "$part_file.p$i" "$WORK/det.p$i"
done
cp "$cf_part" "$WORK/det.canon"
run_compose_out "$part_file" "" "nodejs" || fail "parts: determinism recompose must succeed"
cmp -s "$WORK/det.canon" "$cf_part" \
  || fail "parts: canonical bytes must be unchanged across recompose"
for ((i = 0; i < n_parts; i++)); do
  cmp -s "$WORK/det.p$i" "$part_file.p$i" \
    || fail "parts: .p$i must be byte-identical across recompose"
done

pass "apple chaining: over-cap compose emits $n_parts chained parts (cap-respected, final-only metadata, heredoc intact, deterministic)"

# ---------------------------------------------------------------------------
# Part hygiene: shrinking recomposes drop stale higher-index parts; an
# under-cap recompose leaves zero part files
# ---------------------------------------------------------------------------
shrink_padline="RUN true #$(printf 's%.0s' $(seq 1 48))"
shrink_target=24000
shrink_npad=$(( (shrink_target - chain_base_bytes + chain_padbytes - 1) / chain_padbytes ))
{
  printf 'RUN echo chain-shrunk\n'
  for _ in $(seq 1 "$shrink_npad"); do
    printf '%s\n' "$shrink_padline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_out "$part_file" "" "nodejs" || fail "shrink: still-over-cap recompose must succeed"
shrink_idx="$(list_parts "$part_file")"
[[ -n "$shrink_idx" ]] || fail "shrink: recompose must still emit part files"
mapfile -t shrink_arr <<< "$shrink_idx"
n_shrink=${#shrink_arr[@]}
(( n_shrink >= 2 )) || fail "shrink: recompose must still be over cap (got $n_shrink part file(s))"
(( n_shrink < n_parts )) \
  || fail "shrink: expected fewer parts after shrinking (was $n_parts, still $n_shrink)"
for ((i = 0; i < n_shrink; i++)); do
  [[ "${shrink_arr[$i]}" == "$i" ]] \
    || fail "shrink: parts must stay contiguous p0..p$((n_shrink-1)), got [${shrink_arr[*]}]"
done
if [[ -e "$part_file.p$n_shrink" ]]; then
  fail "shrink: stale .p$n_shrink must be removed after the part count dropped to $n_shrink"
fi

# Fully under cap again: zero part files must remain.
printf 'RUN echo chain-small\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose_out "$part_file" "" "nodejs" || fail "shrink: under-cap recompose must succeed"
under_bytes="$(file_bytes "$part_file")"
(( under_bytes < 11520 )) || fail "shrink: final fixture must be under cap (got $under_bytes)"
for f in "$part_file".p[0-9]*; do
  if [[ -e "$f" ]]; then
    fail "shrink: under-cap compose must remove all part files (found $f)"
  fi
done

pass "shrink: stale higher-index parts removed on smaller over-cap recompose; under-cap recompose leaves zero part files"

# ---------------------------------------------------------------------------
# Giant single unit: one DC-EMBED blob alone over the cap gets a dedicated
# over-cap part plus a distinct WARN (peer-build fallback / split the source)
# ---------------------------------------------------------------------------
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
rm -rf "$TEAM_DIR/overlays/files"
mkdir -p "$TEAM_DIR/overlays/files"
# 12KB of random bytes: gzip cannot shrink them, so the emitted base64 blob
# alone (~16KB) exceeds the transport cap. Byte determinism is not required
# here (structure assertions only).
head -c 12288 /dev/urandom > "$TEAM_DIR/overlays/files/giant.bin"
{
  printf 'RUN echo GIANT-BEFORE\n'
  printf '# DC-EMBED: files/giant.bin /usr/local/lib/giant.bin\n'
  printf 'RUN echo GIANT-AFTER\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_out "$part_file" "" "nodejs" \
  || fail "giant: compose must succeed (an over-cap part is a WARN, not fatal)"
giant_idx="$(list_parts "$part_file")"
[[ -n "$giant_idx" ]] || fail "giant: over-cap compose must emit part files"
mapfile -t giant_arr <<< "$giant_idx"
n_giant=${#giant_arr[@]}
giant_over_count=0
giant_over_idx=-1
for ((i = 0; i < n_giant; i++)); do
  b="$(file_bytes "$part_file.p$i")"
  if (( b > 11520 )); then
    giant_over_count=$(( giant_over_count + 1 ))
    giant_over_idx=$i
  fi
done
(( giant_over_count == 1 )) \
  || fail "giant: expected exactly one over-cap part (got $giant_over_count of $n_giant)"
# The oversized part carries exactly the one oversized unit (its DC-EMBED
# marker comment rides along); every other part stays under the cap.
giant_over_file="$part_file.p$giant_over_idx"
giant_runs="$(grep -Ec '^RUN ' "$giant_over_file" || true)"
[[ "$giant_runs" == "1" ]] \
  || fail "giant: the over-cap part must contain exactly one RUN unit (got $giant_runs)"
grep -Fq 'gunzip > /usr/local/lib/giant.bin' "$giant_over_file" \
  || fail "giant: the over-cap part must contain the giant embed RUN"
grep -Fq '# DC-EMBED files/giant.bin -> /usr/local/lib/giant.bin' "$giant_over_file" \
  || fail "giant: the giant unit's marker comment must ride the same part"
for ((i = 0; i < n_giant; i++)); do
  if (( i != giant_over_idx )); then
    b="$(file_bytes "$part_file.p$i")"
    if (( b > 11520 )); then
      fail "giant: .p$i must stay under the cap (got $b)"
    fi
  fi
done
grep -Fq 'peer-backend build fallback' "$WORK/compose.stderr" \
  || fail "giant: over-cap part must draw the distinct peer-build-fallback WARN (got: $(cat "$WORK/compose.stderr"))"
grep -Fq 'split the embedded source' "$WORK/compose.stderr" \
  || fail "giant: WARN must suggest splitting the embedded source"

pass "giant single unit: dedicated over-cap part (exactly one RUN unit) + distinct peer-build-fallback WARN"

# ---------------------------------------------------------------------------
# Readable mode over cap: no part files emitted, stale parts pruned, no guard
# ---------------------------------------------------------------------------
# Parts exist only for apple's capped transport. The same bulk to a
# basename-conforming path in readable mode must never create a part file,
# and a readable recompose to the same output path must still prune stale
# .pN files left by an earlier apple compose: parts are derived from the
# canonical file, so stale ones must never survive a recompose in any mode
# (anything globbing them would see provenance from an older compose).
bigline="$(printf 'x%.0s' $(seq 1 70))"
{
  echo 'RUN echo big-readable-noparts'
  for _ in $(seq 1 260); do
    printf 'RUN echo %s\n' "$bigline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
# The giant-unit apple compose above left real part files next to $part_file;
# seed known-stale ones on top (including a high index and a zero-padded index
# whose 08 would misparse as invalid octal in bare arithmetic -- the prune must
# force base-10) so the assertion below is deterministic even if earlier
# sections change their part counts.
printf 'FROM dce-base:latest\n' > "$part_file.p0"
printf 'FROM dce-base:latest\n' > "$part_file.p9"
printf 'FROM dce-base:latest\n' > "$part_file.p08"

run_compose_out "$part_file" docker "nodejs" || fail "readable parts: compose must succeed"
readable_bulk_bytes="$(file_bytes "$part_file")"
(( readable_bulk_bytes > 11520 )) \
  || fail "readable parts: fixture must be over cap (got $readable_bulk_bytes)"
for f in "$part_file".p[0-9]*; do
  if [[ -e "$f" ]]; then
    fail "readable parts: stale $f must be pruned by a readable recompose (readable mode never emits parts)"
  fi
done
! grep -q 'WARN: composed Containerfile' "$WORK/compose.stderr" \
  || fail "readable parts: readable mode must not draw any size-guard WARN"

pass "readable mode over cap: no part files emitted, stale parts pruned, no guard ($readable_bulk_bytes bytes)"

# ---------------------------------------------------------------------------
# Basename contract: over-cap apple compose to a non-Containerfile.<hash>
# output path dies (stage chaining needs the image hash from the basename)
# ---------------------------------------------------------------------------
# The bulk overlay from the previous section is still in place (over cap).
if run_compose "nodejs"; then
  fail "basename: over-cap apple compose to out.Containerfile must die"
fi
grep -Fq 'Containerfile.<hash>' "$WORK/compose.stderr" \
  || fail "basename: error must state the Containerfile.<hash> basename contract (got: $(cat "$WORK/compose.stderr"))"
for f in "$WORK/out.Containerfile".p[0-9]*; do
  if [[ -e "$f" ]]; then
    fail "basename: the rejected run must not emit part files (found $f)"
  fi
done

pass "basename contract: over-cap apple compose without Containerfile.<hash> dies before emitting parts"

# ---------------------------------------------------------------------------
# Exact-boundary part: a part filled to EXACTLY the 11520-byte cap emits
# exactly cap bytes and must not trip the post-emit drift guard
# ---------------------------------------------------------------------------
# The packer sizes parts with dce_split_header_len; if that accounting drifts
# even 1 byte small against the emitted dce_split_header_text bytes, a part
# filled to exactly the cap emits cap+1 bytes and compose FATALLY dies
# ("split accounting drifted") on a perfectly valid input. Construction
# (adaptive, like the band test): a probe compose measures the true per-part
# overhead (header line + FROM line bytes) from the emitted part files
# themselves, then the fixture pads so p0 lands exactly one pad-unit short of
# the cap and p1 lands exactly at the cap (p1 opens with the pad unit that
# 1-byte-small accounting would wrongly swallow into p0, emitting cap+1 bytes
# there). Verified with wc -c: the test fails loudly if the fixture misses
# either boundary.
rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
rm -f "$part_file" "$part_file".p[0-9]* 2>/dev/null || true
exact_target=11520
exact_padline="RUN true #$(printf 'e%.0s' $(seq 1 48))"
exact_padbytes=$(( ${#exact_padline} + 1 ))   # one pad unit's emitted bytes
(( exact_padbytes == 59 )) \
  || fail "exact: pad unit must be 59 emitted bytes (got $exact_padbytes)"

# One RUN unit of exactly <bytes> emitted bytes ("RUN true #" is 10 chars).
exact_unit() { # <bytes> -> stdout
  printf 'RUN true #%s\n' "$(printf 'z%.0s' $(seq 1 $(( $1 - 11 ))))"
}

# Probe: a coarse over-cap compose to measure the true header/FROM byte
# lengths from real part files (no duplication of the script's sizing math).
{
  printf 'RUN echo exact-probe\n'
  for _ in $(seq 1 340); do
    printf '%s\n' "$exact_padline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
run_compose_out "$part_file" "" "nodejs" || fail "exact: probe compose must succeed"
exact_H="$(head -n 1 "$part_file.p0" | wc -c | tr -d '[:space:]')"
exact_from0="$(sed -n '2p' "$part_file.p0" | wc -c | tr -d '[:space:]')"
exact_from1="$(sed -n '2p' "$part_file.p1" | wc -c | tr -d '[:space:]')"

# Targets: p0 exactly one pad-unit short of the cap; p1 exactly at the cap.
# The region's first unit carries compose's pending blank + begin-marker
# lines ahead of the first RUN, so the adjuster must absorb those bytes too.
exact_begin_marker='# --- begin overlay:auto:team/nodejs ---'
exact_pending_bytes=$(( 1 + ${#exact_begin_marker} + 1 ))   # blank + marker lines
exact_p0_target=$(( exact_target + 1 - exact_padbytes ))
exact_a0=$(( exact_p0_target - exact_H - exact_from0 - exact_padbytes - exact_pending_bytes ))
exact_a1=$(( exact_target - exact_H - exact_from1 - 5 * exact_padbytes ))
(( exact_a0 >= 12 && exact_a1 >= 12 )) \
  || fail "exact: adjuster sizes must be sane (a0=$exact_a0 a1=$exact_a1 H=$exact_H f0=$exact_from0 f1=$exact_from1)"

exact_ok=0
for ((exact_attempt = 1; exact_attempt <= 2; exact_attempt++)); do
  {
    exact_unit "$exact_a0"
    printf '%s\n' "$exact_padline"
    printf '%s\n' "$exact_padline"
    exact_unit "$exact_a1"
    for _ in $(seq 1 12); do
      printf '%s\n' "$exact_padline"
    done
  } > "$TEAM_DIR/overlays/Containerfile.nodejs"
  if ! run_compose_out "$part_file" "" "nodejs"; then
    fail "exact: over-cap compose must succeed -- a part filled to exactly the ${exact_target}-byte cap must not trip the drift guard (got: $(cat "$WORK/compose.stderr"))"
  fi
  exact_p0_bytes="$(file_bytes "$part_file.p0")"
  exact_p1_bytes="$(file_bytes "$part_file.p1")"
  if (( exact_p0_bytes == exact_p0_target && exact_p1_bytes == exact_target )); then
    exact_ok=1
    break
  fi
  # Digit-width insurance: re-measure the overheads from this compose's own
  # part headers (the part count -- and so the k/N width -- is now exact)
  # and rebuild once.
  exact_H="$(head -n 1 "$part_file.p0" | wc -c | tr -d '[:space:]')"
  exact_from0="$(sed -n '2p' "$part_file.p0" | wc -c | tr -d '[:space:]')"
  exact_from1="$(sed -n '2p' "$part_file.p1" | wc -c | tr -d '[:space:]')"
  exact_a0=$(( exact_p0_target - exact_H - exact_from0 - exact_padbytes - exact_pending_bytes ))
  exact_a1=$(( exact_target - exact_H - exact_from1 - 5 * exact_padbytes ))
done
(( exact_ok )) \
  || fail "exact: fixture missed the boundary (p0=$exact_p0_bytes target=$exact_p0_target, p1=$exact_p1_bytes target=$exact_target)"
! grep -q 'split accounting drifted' "$WORK/compose.stderr" \
  || fail "exact: drift guard must not fire on a cap-exact part"
! grep -q 'peer-backend build fallback' "$WORK/compose.stderr" \
  || fail "exact: no unit alone exceeds the cap in this fixture (got: $(cat "$WORK/compose.stderr"))"
grep -Fq 'WARN: composed Containerfile split into' "$WORK/compose.stderr" \
  || fail "exact: over-cap fixture must still split"
for f in "$part_file".p[0-9]*; do
  [[ -e "$f" ]] || continue
  exact_b="$(file_bytes "$f")"
  (( exact_b <= exact_target )) || fail "exact: $f is $exact_b bytes, over the cap"
done

pass "exact-boundary part: cap-filled part is exactly $exact_target bytes (p0=$exact_p0_bytes p1=$exact_p1_bytes), no drift die"

# ---------------------------------------------------------------------------
# False-opener fragment: the splitter resets heredoc tracking at the
# compose-owned fragment markers (no spurious giant merged unit)
# ---------------------------------------------------------------------------
# emit_fragment resets heredoc tracking per fragment, but the splitter parsed
# the whole units region with one tracker: a fragment with a false/unclosed
# heredoc opener (accepted input; the emitter only WARNs) left the splitter's
# tracker open across the `# --- end/begin overlay:auto:... ---` markers, so
# every later fragment merged into one giant unit -> a spurious dedicated
# over-cap part plus a misleading giant-unit WARN.
rm -rf "$TEAM_DIR/overlays/files"
rm -f "$USER_DIR/overlays/Containerfile.nodejs"
# Fragment A (team/nodejs): a false opener that never terminates.
{
  printf 'RUN echo phantom-open <<NOT_A_HEREDOC\n'
  printf 'RUN echo phantom-body-1\n'
  printf 'RUN echo phantom-body-2\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"
# Fragment B (user/nodejs): ordinary units, padded adaptively so the total is
# over cap with no unit anywhere near it (pre-fix, fragment B merged into the
# phantom heredoc body and became one giant over-cap unit).
printf 'RUN echo phantom-user-base\n' > "$USER_DIR/overlays/Containerfile.nodejs"
run_compose_out "$part_file" "" "nodejs" || fail "phantom: base compose must succeed"
phantom_base_bytes="$(file_bytes "$part_file")"
phantom_padline="RUN true #$(printf 'p%.0s' $(seq 1 48))"
phantom_padbytes=$(( ${#phantom_padline} + 1 ))
phantom_npad=$(( (14000 - phantom_base_bytes + phantom_padbytes - 1) / phantom_padbytes ))
# Fragment B: ordinary units only (no opener) -- pre-fix, all of this merged
# into fragment A's phantom heredoc body and became one giant over-cap unit.
{
  printf 'RUN echo phantom-user-padded\n'
  for _ in $(seq 1 "$phantom_npad"); do
    printf '%s\n' "$phantom_padline"
  done
} > "$USER_DIR/overlays/Containerfile.nodejs"

run_compose_out "$part_file" "" "nodejs" || fail "phantom: over-cap compose must succeed"
phantom_bytes="$(file_bytes "$part_file")"
(( phantom_bytes > 11520 )) \
  || fail "phantom: fixture must be over cap (got $phantom_bytes)"
grep -Fq "heredoc delimiter 'NOT_A_HEREDOC' is never terminated" "$WORK/compose.stderr" \
  || fail "phantom: emitter WARN for the false opener must survive (got: $(cat "$WORK/compose.stderr"))"
! grep -q 'peer-backend build fallback' "$WORK/compose.stderr" \
  || fail "phantom: splitter must not report a giant merged unit (got: $(cat "$WORK/compose.stderr"))"
phantom_idx="$(list_parts "$part_file")"
[[ -n "$phantom_idx" ]] || fail "phantom: over-cap compose must emit part files"
mapfile -t phantom_parts <<< "$phantom_idx"
for i in "${!phantom_parts[@]}"; do
  phantom_b="$(file_bytes "$part_file.p${phantom_parts[$i]}")"
  (( phantom_b <= 11520 )) \
    || fail "phantom: .p${phantom_parts[$i]} is $phantom_b bytes over cap -- the false opener merged later fragments into one giant unit"
done
# RUN conservation: every canonical RUN lands in exactly one part.
phantom_canon_runs="$(grep -Ec '^RUN ' "$part_file" || true)"
phantom_sum_runs=0
for i in "${!phantom_parts[@]}"; do
  phantom_r="$(grep -Ec '^RUN ' "$part_file.p${phantom_parts[$i]}" || true)"
  phantom_sum_runs=$(( phantom_sum_runs + phantom_r ))
done
[[ "$phantom_canon_runs" == "$phantom_sum_runs" ]] \
  || fail "phantom: RUN count mismatch canonical=$phantom_canon_runs parts=$phantom_sum_runs"
(( phantom_canon_runs >= 4 )) \
  || fail "phantom: fixture must carry the fragment A/B RUNs (got $phantom_canon_runs)"

pass "false-opener fragment: markers reset splitter heredoc tracking (no giant merged unit; emitter WARN intact)"

# ---------------------------------------------------------------------------
# Committed golden: apple-mode output pinned byte-for-byte
# ---------------------------------------------------------------------------
# The omitted-flag == --backend apple check proves internal identity under the
# current code; this golden pins the bytes themselves against pre-change
# behavior, so a future edit cannot silently perturb apple-mode output (the
# fail-safe default every positional caller gets). The only run-dependent
# bytes are the absolute overlays dirs inside the DC-EMBED marker comment;
# both sides are normalized to <DC_TEAM_DIR>/<DC_USER_DIR> before the cmp.
# Regenerate deliberately (then review the git diff) with:
#   DCE_UPDATE_GOLDEN=1 bash tests/contract/compose-layering.sh
GOLDEN="$ROOT_DIR/tests/fixtures/compose-apple-golden.txt"
GOLDEN_HEADER_MARKER='# ---8<--- golden body below (test-managed; header text lives in this test) ---8<---'

# Print <file> with the temp overlays dirs scrubbed to fixed placeholders.
golden_normalize() { # <file> -> stdout
  awk -v t="$TEAM_DIR" -v u="$USER_DIR" '
    {
      while ((i = index($0, t)) > 0) $0 = substr($0, 1, i - 1) "<DC_TEAM_DIR>" substr($0, i + length(t))
      while ((i = index($0, u)) > 0) $0 = substr($0, 1, i - 1) "<DC_USER_DIR>" substr($0, i + length(u))
      print
    }' "$1"
}

rm -f "$TEAM_DIR/overlays"/Containerfile.* "$USER_DIR/overlays"/Containerfile.* 2>/dev/null || true
mkdir -p "$TEAM_DIR/overlays/files"
printf '#!/bin/sh\necho golden-embed-body\n' > "$TEAM_DIR/overlays/files/golden-embed.sh"
{
  printf '# golden-fixture comment (stripped in apple mode)\n'
  printf '\n'
  printf 'FROM dce-base:latest\n'
  printf 'RUN echo GOLDEN-PROBE\n'
  printf 'CMD ["echo", "golden-cmd-stripped"]\n'
  printf '# DC-EMBED: files/golden-embed.sh /usr/local/bin/golden-embed 0755\n'
  printf '\n'
  printf 'RUN echo GOLDEN-AFTER-EMBED\n'
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose_backend apple "nodejs" || fail "golden: apple compose must succeed"

if [[ "${DCE_UPDATE_GOLDEN:-0}" == "1" ]]; then
  mkdir -p "$(dirname "$GOLDEN")"
  {
    cat <<'GOLDEN_HEADER'
# Committed golden: byte-exact apple-mode output of scripts/compose-containerfile.sh
# for the synthetic fixture built by the "Committed golden" section at the end of
# tests/contract/compose-layering.sh (team-only nodejs scope exercising comment/
# blank stripping, the FROM/CMD strip, and one DC-EMBED directive with mode 0755).
# It pins the fail-safe default output against pre-change behavior: a diff means
# apple-mode bytes moved and must be deliberate.
#
# Determinism scope: everything here is stable across runs and temp dirs (git
# labels are constant-empty for the suite's non-git fixture dirs; the content
# hash folds file bytes only) EXCEPT the gzip+base64 blob, which is stable per
# machine only (docs claim one-machine reproducibility). The absolute overlays
# dir in the DC-EMBED marker is rewritten to <DC_TEAM_DIR> on both sides before
# the cmp.
#
# Regenerate deliberately (then review the git diff before committing):
#   DCE_UPDATE_GOLDEN=1 bash tests/contract/compose-layering.sh
GOLDEN_HEADER
    printf '%s\n' "$GOLDEN_HEADER_MARKER"
    golden_normalize "$WORK/out.Containerfile"
  } > "$GOLDEN"
  echo "Golden rewritten: $GOLDEN (review the git diff before committing)"
else
  [[ -f "$GOLDEN" ]] \
    || fail "golden: committed fixture missing at $GOLDEN (regenerate deliberately with DCE_UPDATE_GOLDEN=1)"
  # Header lines above the marker are documentation; from the marker down the
  # bytes are the pinned output.
  awk -v m="$GOLDEN_HEADER_MARKER" 'seen { print } $0 == m { seen = 1 }' "$GOLDEN" > "$WORK/golden.body"
  golden_normalize "$WORK/out.Containerfile" > "$WORK/golden.got"
  cmp -s "$WORK/golden.got" "$WORK/golden.body" \
    || fail "golden: apple-mode output drifted from tests/fixtures/compose-apple-golden.txt (if intended, regenerate deliberately with DCE_UPDATE_GOLDEN=1)"
fi

pass "apple-mode golden fixture byte-identical (tests/fixtures/compose-apple-golden.txt)"

echo ""
echo "All compose layering checks passed."
