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
#   - A composed file over 16,384 bytes triggers a prominent non-fatal warning.
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
# >16,384-byte composed output: prominent, non-fatal warning
# ---------------------------------------------------------------------------
# Bulk filler must be strippable-proof content: RUN lines survive minification
# (comment lines would now be stripped and the guard would never trigger).
bigline="$(printf 'x%.0s' $(seq 1 70))"
{
  echo 'RUN echo big'
  for _ in $(seq 1 260); do
    printf 'RUN echo %s\n' "$bigline"
  done
} > "$TEAM_DIR/overlays/Containerfile.nodejs"

run_compose "nodejs" || fail "size guard: oversized output must not abort compose"
[[ -f "$CF" ]] || fail "size guard: output file must exist"
grep -Fq '16384' "$WORK/compose.stderr" \
  || fail "size guard: warning must name the 16384-byte apple/container limit"
grep -Fq "$(wc -c < "$CF" | tr -d '[:space:]') bytes" "$WORK/compose.stderr" \
  || fail "size guard: warning must name the actual composed size"
grep -Fq 'DC-EMBED' "$WORK/compose.stderr" \
  || fail "size guard: warning must suggest compressing via DC-EMBED"

pass "size guard: >16384-byte output warns (non-fatal) and suggests DC-EMBED"

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

echo ""
echo "All compose layering checks passed."
