#!/usr/bin/env bash
# =============================================================================
# tests/provenance.sh - Unit + behavior coverage for image provenance.
#
# Implements the verification checklist of plans/versioning.md: per-directory
# provenance detection (content hash always + git commit when under git),
# JSONL provenance log with dedup-on-change, LABEL emission in the composed
# Containerfile, and value sanitization. These are pure/host-side helpers, so
# they run with no container backend.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Fake HOME so dc_provenance_log_path / dc_log_provenance write under it.
export HOME="$WORK/home"
mkdir -p "$HOME/.config/dev-containers"

OV="$WORK/overlays"
mkdir -p "$OV/team" "$OV/user"

mkfrag() { printf 'RUN echo %s\n' "$2" > "$OV/$1/Containerfile.$2"; }

# ---------------------------------------------------------------------------
# dc_provenance_content_hash (per-namespace, takes EFFECTIVE scopes)
# ---------------------------------------------------------------------------
mkfrag team nodejs
ch1="$(dc_provenance_content_hash "$OV" team nodejs)"
[[ "$ch1" =~ ^[0-9a-f]{12}$ ]] || fail "content_hash: expected 12 hex (got [$ch1])"
ch2="$(dc_provenance_content_hash "$OV" team nodejs)"
[[ "$ch1" == "$ch2" ]] || fail "content_hash: not deterministic"
printf 'RUN echo CHANGED\n' > "$OV/team/Containerfile.nodejs"
ch3="$(dc_provenance_content_hash "$OV" team nodejs)"
[[ "$ch3" != "$ch1" ]] || fail "content_hash: must change when fragment bytes change"
# Empty when the namespace contributes no fragment for the scopes.
[[ -z "$(dc_provenance_content_hash "$OV" user nodejs)" ]] \
  || fail "content_hash: expected empty for missing namespace fragment"
# Including 'all' (when present and effective) changes the hash.
mkfrag team all
with_all="$(dc_provenance_content_hash "$OV" team all,nodejs)"
[[ "$with_all" != "$ch3" ]] || fail "content_hash: must differ when 'all' is included"
# Order-sensitive: all,nodejs != nodejs (would differ anyway since nodejs-only has no all).
mkfrag team golang
ab="$(dc_provenance_content_hash "$OV" team all,nodejs,golang)"
ba="$(dc_provenance_content_hash "$OV" team all,golang,nodejs)"
[[ "$ab" != "$ba" ]] || fail "content_hash: different scope order must hash differently"
pass "dc_provenance_content_hash (deterministic, byte/order-sensitive, empty, all-inclusive)"

# ---------------------------------------------------------------------------
# dc_provenance_combined_hash
# ---------------------------------------------------------------------------
comb1="$(dc_provenance_combined_hash "$ch1" "")"
[[ "$comb1" =~ ^[0-9a-f]{64}$ ]] || fail "combined_hash: expected 64 hex (got [$comb1])"
[[ "$(dc_provenance_combined_hash "$ch1" "")" == "$comb1" ]] \
  || fail "combined_hash: not deterministic"
[[ "$(dc_provenance_combined_hash "$ch3" "")" != "$comb1" ]] \
  || fail "combined_hash: must change when a side changes"
pass "dc_provenance_combined_hash (deterministic, side-sensitive, 64 hex)"

# ---------------------------------------------------------------------------
# dc_json_escape + dc_label_scrub
# ---------------------------------------------------------------------------
[[ "$(dc_json_escape 'plain')" == 'plain' ]] || fail "json_escape: plain passthrough"
[[ "$(dc_json_escape 'a"b')" == 'a\"b' ]] || fail "json_escape: quote escaped"
[[ "$(dc_json_escape 'a\b')" == 'a\\b' ]] || fail "json_escape: backslash escaped"
[[ "$(dc_json_escape $'a\tb')" == 'a\tb' ]] || fail "json_escape: tab escaped"
[[ "$(dc_json_escape $'a\nb')" == 'a\nb' ]] || fail "json_escape: newline escaped"
[[ "$(dc_label_scrub 'sha256:abc')" == 'sha256:abc' ]] || fail "label_scrub: safe passthrough"
scrubbed="$(dc_label_scrub 'a"b$c`d\e')"
[[ "$scrubbed" == 'abcde' ]] || fail "label_scrub: strips quote/backslash/dollar/backtick (got [$scrubbed])"
pass "dc_json_escape + dc_label_scrub (sanitization)"

# ---------------------------------------------------------------------------
# dc_provenance_git_* (gated on git being installed)
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  GREPO="$WORK/teamrepo"
  mkdir -p "$GREPO"
  git -C "$GREPO" init -q
  git -C "$GREPO" config user.email t@t
  git -C "$GREPO" config user.name t
  printf 'RUN echo x\n' > "$GREPO/Containerfile.nodejs"
  git -C "$GREPO" add -A && git -C "$GREPO" commit -qm init

  sha="$(dc_provenance_git_commit "$GREPO")"
  # The FULL sha is stored (not the abbreviated form) so the log holds the
  # canonical identifier; display truncation is a separate concern.
  [[ "$sha" =~ ^[0-9a-f]{40,}$ ]] || fail "git_commit: expected full sha >=40 hex (got [$sha])"
  [[ "$(dc_provenance_git_dirty "$GREPO")" == "false" ]] \
    || fail "git_dirty: clean tree must be false"
  # Dirty after an uncommitted edit.
  printf 'RUN echo y\n' >> "$GREPO/Containerfile.nodejs"
  [[ "$(dc_provenance_git_dirty "$GREPO")" == "true" ]] \
    || fail "git_dirty: dirty tree must be true"
  # The dirty value must NOT change the commit (HEAD is unchanged); it is a
  # separate signal, so both commit + bytes are always available.
  [[ "$(dc_provenance_git_commit "$GREPO")" == "$sha" ]] \
    || fail "git_commit: dirty edit must not change HEAD sha"

  # Non-git dir -> all git fields empty.
  NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"
  [[ -z "$(dc_provenance_git_commit "$NOGIT")" ]] || fail "git_commit: non-git must be empty"
  [[ -z "$(dc_provenance_git_dirty "$NOGIT")" ]] || fail "git_dirty: non-git must be empty"
  [[ -z "$(dc_provenance_git_source "$NOGIT")" ]] || fail "git_source: non-git must be empty"
  pass "dc_provenance_git_* (sha, dirty vs commit, empty for non-git)"
else
  echo "SKIP: dc_provenance_git_* (git not installed)"
fi

# ---------------------------------------------------------------------------
# dc_log_provenance: JSONL append, chmod 600, dedup-on-change
# ---------------------------------------------------------------------------
rm -rf "$OV"; mkdir -p "$OV/team" "$OV/user"
mkfrag team nodejs
mkfrag user nodejs
PROJECT="proj1"
PROJDIR="$HOME/.config/dev-containers/$PROJECT"; mkdir -p "$PROJDIR"

dc_log_provenance "$PROJECT" "dev-img-deadbeefdeadbeef:latest" "new" "$OV" "nodejs" "sha256:baseAAA"
LOG="$PROJDIR/provenance.jsonl"
[[ -f "$LOG" ]] || fail "log: file not created"
mode="$(stat -c %a "$LOG" 2>/dev/null || stat -f %Lp "$LOG")"
[[ "$mode" == "600" ]] || fail "log: expected chmod 600 (got $mode)"
[[ "$(wc -l < "$LOG")" -eq 1 ]] || fail "log: expected one line after first write"
if command -v jq >/dev/null 2>&1; then
  jq -e '.action=="new" and .base.id=="sha256:baseAAA" and .team.content_hash and .user.content_hash and .content_hash' \
    "$LOG" >/dev/null || fail "log: JSON shape invalid"
fi

# Dedup: identical state again -> still one line (action differs, but the image
# inputs did not, and dedup keys on content_hash+base_id).
dc_log_provenance "$PROJECT" "dev-img-deadbeefdeadbeef:latest" "rebuild" "$OV" "nodejs" "sha256:baseAAA"
[[ "$(wc -l < "$LOG")" -eq 1 ]] || fail "log: dedup must keep one line on identical state"

# Change overlay bytes -> new line.
printf 'RUN echo DIFFERENT\n' > "$OV/team/Containerfile.nodejs"
dc_log_provenance "$PROJECT" "dev-img-deadbeefdeadbeef:latest" "rebuild" "$OV" "nodejs" "sha256:baseAAA"
[[ "$(wc -l < "$LOG")" -eq 2 ]] || fail "log: changed overlay must append a line"

# Change base id only -> new line.
dc_log_provenance "$PROJECT" "dev-img-deadbeefdeadbeef:latest" "rebuild" "$OV" "nodejs" "sha256:baseBBB"
[[ "$(wc -l < "$LOG")" -eq 3 ]] || fail "log: changed base must append a line"
pass "dc_log_provenance (JSONL, chmod 600, dedup-on-change)"

# A malformed last line must not crash the dedup path; the next write appends.
printf 'this is not json\n' >> "$LOG"
dc_log_provenance "$PROJECT" "dev-img-deadbeefdeadbeef:latest" "rebuild" "$OV" "nodejs" "sha256:baseBBB"
[[ "$(wc -l < "$LOG")" -eq 5 ]] || fail "log: malformed last line must not abort; expected 5 lines"
pass "dc_log_provenance tolerates a malformed last line (appends without dedup)"

# ---------------------------------------------------------------------------
# Mixed: team under git, user loose -> team.git_commit set, user.git_commit ""
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  rm -rf "$OV"; mkdir -p "$OV/user"
  TGREPO="$OV/team"; mkdir -p "$TGREPO"
  git -C "$TGREPO" init -q
  git -C "$TGREPO" config user.email t@t
  git -C "$TGREPO" config user.name t
  printf 'RUN echo teamgit\n' > "$TGREPO/Containerfile.nodejs"
  git -C "$TGREPO" add -A && git -C "$TGREPO" commit -qm init
  printf 'RUN echo userloose\n' > "$OV/user/Containerfile.nodejs"
  PROJECT="proj2"; PROJDIR="$HOME/.config/dev-containers/$PROJECT"; mkdir -p "$PROJDIR"
  dc_log_provenance "$PROJECT" "dev-img-1111222233334444:latest" "new" "$OV" "nodejs" "sha256:baseZZZ"
  jq -e '.team.git_commit != "" and .user.git_commit == "" and .team.git_dirty == false' \
    "$PROJDIR/provenance.jsonl" >/dev/null \
    || fail "log: mixed case team.git_commit set / user.git_commit empty / dirty=false"
  pass "dc_log_provenance mixed git/loose sides"
else
  echo "SKIP: dc_log_provenance mixed-case (git or jq not installed)"
fi

# ---------------------------------------------------------------------------
# compose-containerfile.sh emits the provenance LABEL block
# ---------------------------------------------------------------------------
DC_ROOT="$HOME/.config/dev-containers"
printf 'DC_OVERLAYS_DIR="%s"\n' "$OV" > "$DC_ROOT/config"
COMPOSE="$ROOT_DIR/scripts/compose-containerfile.sh"
rm -rf "$OV"; mkdir -p "$OV/team" "$OV/user"
printf 'RUN echo L1\n' > "$OV/team/Containerfile.nodejs"
printf 'RUN echo U1\n' > "$OV/user/Containerfile.nodejs"
bash "$COMPOSE" "$WORK/out.Containerfile" "nodejs" >"$WORK/c.out" 2>"$WORK/c.err"
CF="$WORK/out.Containerfile"
[[ -f "$CF" ]] || fail "compose: output not written"
# Bookends preserved.
[[ "$(head -n1 "$CF")" == "FROM dev-base:latest" ]] || fail "compose: FROM must remain first"
grep -Fxq 'USER dev' "$CF" || fail "compose: USER dev must remain present"
grep -Fxq 'CMD ["sleep", "infinity"]' "$CF" || fail "compose: CMD must remain present"
# Provenance labels with inlined per-side content hashes.
grep -Eq '^LABEL devcontainers\.dc\.version="[0-9.]+"' "$CF" || fail "compose: dc.version label missing"
grep -Eq '^LABEL devcontainers\.scopes="nodejs"' "$CF" || fail "compose: scopes label missing"
grep -Eq '^LABEL devcontainers\.team\.content_hash="[0-9a-f]{12}"' "$CF" || fail "compose: team content_hash label invalid"
grep -Eq '^LABEL devcontainers\.user\.content_hash="[0-9a-f]{12}"' "$CF" || fail "compose: user content_hash label invalid"
grep -Eq '^LABEL devcontainers\.content\.hash="[0-9a-f]{64}"' "$CF" || fail "compose: combined content.hash label invalid"
# git_commit label is present and empty for loose-file (non-git) overlays.
grep -Fq 'LABEL devcontainers.team.git_commit=""' "$CF" || fail "compose: loose-file team.git_commit must be empty"
grep -Fq 'LABEL devcontainers.user.git_commit=""' "$CF" || fail "compose: loose-file user.git_commit must be empty"
# base.id / built.utc are populated at build time via ARG (no backend at compose time).
grep -Fq 'ARG DC_BASE_ID=' "$CF" || fail "compose: DC_BASE_ID ARG missing"
grep -Fq 'ARG DC_BUILT_UTC=' "$CF" || fail "compose: DC_BUILT_UTC ARG missing"
grep -Fq 'LABEL devcontainers.base.id="${DC_BASE_ID}"' "$CF" || fail "compose: base.id must reference ARG"
grep -Fq 'LABEL devcontainers.built.utc="${DC_BUILT_UTC}"' "$CF" || fail "compose: built.utc must reference ARG"
# OCI revision carries the combined hash value (matched by capturing the content.hash value).
rev_val="$(grep -Eo '^LABEL devcontainers\.content\.hash="[0-9a-f]{64}"' "$CF" | sed -E 's/.*"([0-9a-f]{64})"/\1/')"
grep -Fq "LABEL org.opencontainers.image.revision=\"$rev_val\"" "$CF" \
  || fail "compose: OCI revision must equal content.hash"
pass "compose-containerfile.sh emits provenance LABEL block"

echo ""
echo "All provenance checks passed."
