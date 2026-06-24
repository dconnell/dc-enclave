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

# Fake HOME so dce_provenance_log_path / dce_log_provenance write under it.
export HOME="$WORK/home"
mkdir -p "$HOME/.config/dce-enclave"

# Two independent roots (mirroring DC_TEAM_DIR / DC_USER_DIR). Each holds an
# overlays/ leaf dir. content_hash takes the leaf dir; dce_log_provenance takes
# the root and derives <root>/overlays itself.
TEAM_ROOT="$WORK/team"
USER_ROOT="$WORK/user"
TEAM_OD="$TEAM_ROOT/overlays"
USER_OD="$USER_ROOT/overlays"
mkdir -p "$TEAM_OD" "$USER_OD"

# mkfrag <side:team|user> <scope> writes a fragment into that side's overlays/.
mkfrag() { printf 'RUN echo %s\n' "$2" > "$WORK/$1/overlays/Containerfile.$2"; }

# ---------------------------------------------------------------------------
# dce_provenance_content_hash (per-side, takes EFFECTIVE scopes)
# ---------------------------------------------------------------------------
mkfrag team nodejs
ch1="$(dce_provenance_content_hash "$TEAM_OD" nodejs)"
[[ "$ch1" =~ ^[0-9a-f]{12}$ ]] || fail "content_hash: expected 12 hex (got [$ch1])"
ch2="$(dce_provenance_content_hash "$TEAM_OD" nodejs)"
[[ "$ch1" == "$ch2" ]] || fail "content_hash: not deterministic"
printf 'RUN echo CHANGED\n' > "$TEAM_OD/Containerfile.nodejs"
ch3="$(dce_provenance_content_hash "$TEAM_OD" nodejs)"
[[ "$ch3" != "$ch1" ]] || fail "content_hash: must change when fragment bytes change"
# Empty when the side contributes no fragment for the scopes.
[[ -z "$(dce_provenance_content_hash "$USER_OD" nodejs)" ]] \
  || fail "content_hash: expected empty for missing side fragment"
# Including 'all' (when present and effective) changes the hash.
mkfrag team all
with_all="$(dce_provenance_content_hash "$TEAM_OD" all,nodejs)"
[[ "$with_all" != "$ch3" ]] || fail "content_hash: must differ when 'all' is included"
# Order-sensitive: all,nodejs != nodejs (would differ anyway since nodejs-only has no all).
mkfrag team golang
ab="$(dce_provenance_content_hash "$TEAM_OD" all,nodejs,golang)"
ba="$(dce_provenance_content_hash "$TEAM_OD" all,golang,nodejs)"
[[ "$ab" != "$ba" ]] || fail "content_hash: different scope order must hash differently"
pass "dce_provenance_content_hash (deterministic, byte/order-sensitive, empty, all-inclusive)"

# ---------------------------------------------------------------------------
# dce_provenance_combined_hash
# ---------------------------------------------------------------------------
comb1="$(dce_provenance_combined_hash "$ch1" "")"
[[ "$comb1" =~ ^[0-9a-f]{64}$ ]] || fail "combined_hash: expected 64 hex (got [$comb1])"
[[ "$(dce_provenance_combined_hash "$ch1" "")" == "$comb1" ]] \
  || fail "combined_hash: not deterministic"
[[ "$(dce_provenance_combined_hash "$ch3" "")" != "$comb1" ]] \
  || fail "combined_hash: must change when a side changes"
pass "dce_provenance_combined_hash (deterministic, side-sensitive, 64 hex)"

# ---------------------------------------------------------------------------
# dce_json_escape + dce_label_scrub
# ---------------------------------------------------------------------------
[[ "$(dce_json_escape 'plain')" == 'plain' ]] || fail "json_escape: plain passthrough"
[[ "$(dce_json_escape 'a"b')" == 'a\"b' ]] || fail "json_escape: quote escaped"
[[ "$(dce_json_escape 'a\b')" == 'a\\b' ]] || fail "json_escape: backslash escaped"
[[ "$(dce_json_escape $'a\tb')" == 'a\tb' ]] || fail "json_escape: tab escaped"
[[ "$(dce_json_escape $'a\nb')" == 'a\nb' ]] || fail "json_escape: newline escaped"
[[ "$(dce_label_scrub 'sha256:abc')" == 'sha256:abc' ]] || fail "label_scrub: safe passthrough"
scrubbed="$(dce_label_scrub 'a"b$c`d\e')"
[[ "$scrubbed" == 'abcde' ]] || fail "label_scrub: strips quote/backslash/dollar/backtick (got [$scrubbed])"
pass "dce_json_escape + dce_label_scrub (sanitization)"

# ---------------------------------------------------------------------------
# dce_provenance_git_* (gated on git being installed)
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  GREPO="$WORK/teamrepo"
  mkdir -p "$GREPO"
  git -C "$GREPO" init -q
  git -C "$GREPO" config user.email t@t
  git -C "$GREPO" config user.name t
  printf 'RUN echo x\n' > "$GREPO/Containerfile.nodejs"
  git -C "$GREPO" add -A && git -C "$GREPO" commit -qm init

  sha="$(dce_provenance_git_commit "$GREPO")"
  # The FULL sha is stored (not the abbreviated form) so the log holds the
  # canonical identifier; display truncation is a separate concern.
  [[ "$sha" =~ ^[0-9a-f]{40,}$ ]] || fail "git_commit: expected full sha >=40 hex (got [$sha])"
  [[ "$(dce_provenance_git_dirty "$GREPO")" == "false" ]] \
    || fail "git_dirty: clean tree must be false"
  # Dirty after an uncommitted edit.
  printf 'RUN echo y\n' >> "$GREPO/Containerfile.nodejs"
  [[ "$(dce_provenance_git_dirty "$GREPO")" == "true" ]] \
    || fail "git_dirty: dirty tree must be true"
  # The dirty value must NOT change the commit (HEAD is unchanged); it is a
  # separate signal, so both commit + bytes are always available.
  [[ "$(dce_provenance_git_commit "$GREPO")" == "$sha" ]] \
    || fail "git_commit: dirty edit must not change HEAD sha"

  # Non-git dir -> all git fields empty.
  NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"
  [[ -z "$(dce_provenance_git_commit "$NOGIT")" ]] || fail "git_commit: non-git must be empty"
  [[ -z "$(dce_provenance_git_dirty "$NOGIT")" ]] || fail "git_dirty: non-git must be empty"
  [[ -z "$(dce_provenance_git_source "$NOGIT")" ]] || fail "git_source: non-git must be empty"
  pass "dce_provenance_git_* (sha, dirty vs commit, empty for non-git)"
else
  echo "SKIP: dce_provenance_git_* (git not installed)"
fi

# ---------------------------------------------------------------------------
# dce_log_provenance: JSONL append, chmod 600, dedup-on-change
# ---------------------------------------------------------------------------
rm -rf "$TEAM_ROOT" "$USER_ROOT"
mkdir -p "$TEAM_OD" "$USER_OD"
mkfrag team nodejs
mkfrag user nodejs
PROJECT="proj1"
PROJDIR="$HOME/.config/dce-enclave/$PROJECT"; mkdir -p "$PROJDIR"

dce_log_provenance "$PROJECT" "dce-img-deadbeefdeadbeef:latest" "new" "$TEAM_ROOT" "$USER_ROOT" "nodejs" "sha256:baseAAA"
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
dce_log_provenance "$PROJECT" "dce-img-deadbeefdeadbeef:latest" "rebuild" "$TEAM_ROOT" "$USER_ROOT" "nodejs" "sha256:baseAAA"
[[ "$(wc -l < "$LOG")" -eq 1 ]] || fail "log: dedup must keep one line on identical state"

# Change overlay bytes -> new line.
printf 'RUN echo DIFFERENT\n' > "$TEAM_OD/Containerfile.nodejs"
dce_log_provenance "$PROJECT" "dce-img-deadbeefdeadbeef:latest" "rebuild" "$TEAM_ROOT" "$USER_ROOT" "nodejs" "sha256:baseAAA"
[[ "$(wc -l < "$LOG")" -eq 2 ]] || fail "log: changed overlay must append a line"

# Change base id only -> new line.
dce_log_provenance "$PROJECT" "dce-img-deadbeefdeadbeef:latest" "rebuild" "$TEAM_ROOT" "$USER_ROOT" "nodejs" "sha256:baseBBB"
[[ "$(wc -l < "$LOG")" -eq 3 ]] || fail "log: changed base must append a line"
pass "dce_log_provenance (JSONL, chmod 600, dedup-on-change)"

# A malformed last line must not crash the dedup path; the next write appends.
printf 'this is not json\n' >> "$LOG"
dce_log_provenance "$PROJECT" "dce-img-deadbeefdeadbeef:latest" "rebuild" "$TEAM_ROOT" "$USER_ROOT" "nodejs" "sha256:baseBBB"
[[ "$(wc -l < "$LOG")" -eq 5 ]] || fail "log: malformed last line must not abort; expected 5 lines"
pass "dce_log_provenance tolerates a malformed last line (appends without dedup)"

# ---------------------------------------------------------------------------
# Mixed: team under git, user loose -> team.git_commit set, user.git_commit ""
# ---------------------------------------------------------------------------
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  rm -rf "$TEAM_ROOT" "$USER_ROOT"
  mkdir -p "$TEAM_OD" "$USER_OD"
  TGREPO="$TEAM_ROOT"
  git -C "$TGREPO" init -q
  git -C "$TGREPO" config user.email t@t
  git -C "$TGREPO" config user.name t
  printf 'RUN echo teamgit\n' > "$TEAM_OD/Containerfile.nodejs"
  git -C "$TGREPO" add -A && git -C "$TGREPO" commit -qm init
  printf 'RUN echo userloose\n' > "$USER_OD/Containerfile.nodejs"
  PROJECT="proj2"; PROJDIR="$HOME/.config/dce-enclave/$PROJECT"; mkdir -p "$PROJDIR"
  dce_log_provenance "$PROJECT" "dce-img-1111222233334444:latest" "new" "$TEAM_ROOT" "$USER_ROOT" "nodejs" "sha256:baseZZZ"
  jq -e '.team.git_commit != "" and .user.git_commit == "" and .team.git_dirty == false' \
    "$PROJDIR/provenance.jsonl" >/dev/null \
    || fail "log: mixed case team.git_commit set / user.git_commit empty / dirty=false"
  pass "dce_log_provenance mixed git/loose sides"
else
  echo "SKIP: dce_log_provenance mixed-case (git or jq not installed)"
fi

# ---------------------------------------------------------------------------
# compose-containerfile.sh emits the provenance LABEL block
# ---------------------------------------------------------------------------
DC_ROOT="$HOME/.config/dce-enclave"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_ROOT"
  printf 'DC_USER_DIR="%s"\n' "$USER_ROOT"
} > "$DC_ROOT/config"
COMPOSE="$ROOT_DIR/scripts/compose-containerfile.sh"
rm -rf "$TEAM_ROOT" "$USER_ROOT"
mkdir -p "$TEAM_OD" "$USER_OD"
printf 'RUN echo L1\n' > "$TEAM_OD/Containerfile.nodejs"
printf 'RUN echo U1\n' > "$USER_OD/Containerfile.nodejs"
bash "$COMPOSE" "$WORK/out.Containerfile" "nodejs" >"$WORK/c.out" 2>"$WORK/c.err"
CF="$WORK/out.Containerfile"
[[ -f "$CF" ]] || fail "compose: output not written"
# Bookends preserved.
[[ "$(head -n1 "$CF")" == "FROM dce-base:latest" ]] || fail "compose: FROM must remain first"
grep -Fxq 'USER dev' "$CF" || fail "compose: USER dev must remain present"
grep -Fxq 'CMD ["sleep", "infinity"]' "$CF" || fail "compose: CMD must remain present"
# Provenance labels with inlined per-side content hashes.
grep -Eq '^LABEL dce\.version="[0-9.]+"' "$CF" || fail "compose: dce.version label missing"
grep -Eq '^LABEL dce\.scopes="nodejs"' "$CF" || fail "compose: scopes label missing"
grep -Eq '^LABEL dce\.team\.content_hash="[0-9a-f]{12}"' "$CF" || fail "compose: team content_hash label invalid"
grep -Eq '^LABEL dce\.user\.content_hash="[0-9a-f]{12}"' "$CF" || fail "compose: user content_hash label invalid"
grep -Eq '^LABEL dce\.content\.hash="[0-9a-f]{64}"' "$CF" || fail "compose: combined content.hash label invalid"
# git_commit label is present and empty for loose-file (non-git) overlays.
grep -Fq 'LABEL dce.team.git_commit=""' "$CF" || fail "compose: loose-file team.git_commit must be empty"
grep -Fq 'LABEL dce.user.git_commit=""' "$CF" || fail "compose: loose-file user.git_commit must be empty"
# base.id / built.utc are populated at build time via ARG (no backend at compose time).
grep -Fq 'ARG DC_BASE_ID=' "$CF" || fail "compose: DC_BASE_ID ARG missing"
grep -Fq 'ARG DC_BUILT_UTC=' "$CF" || fail "compose: DC_BUILT_UTC ARG missing"
grep -Fq 'LABEL dce.base.id="${DC_BASE_ID}"' "$CF" || fail "compose: base.id must reference ARG"
grep -Fq 'LABEL dce.built.utc="${DC_BUILT_UTC}"' "$CF" || fail "compose: built.utc must reference ARG"
# OCI revision carries the combined hash value (matched by capturing the content.hash value).
rev_val="$(grep -Eo '^LABEL dce\.content\.hash="[0-9a-f]{64}"' "$CF" | sed -E 's/.*"([0-9a-f]{64})"/\1/')"
grep -Fq "LABEL org.opencontainers.image.revision=\"$rev_val\"" "$CF" \
  || fail "compose: OCI revision must equal content.hash"
pass "compose-containerfile.sh emits provenance LABEL block"

echo ""
echo "All provenance checks passed."
