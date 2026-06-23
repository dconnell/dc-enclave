#!/usr/bin/env bash
# =============================================================================
# tests/compose-layering.sh - Characterize scripts/compose-containerfile.sh.
#
# The compose helper implements the documented canonical layering contract
# (README "Canonical layering order"; plans/layering.md). This locks it down so
# a reorder or a stripped guard regresses loudly:
#
#   - Canonical overlay order: team/all, user/all, team/<s1>, user/<s1>,
#     team/<s2> ... (one namespace pair per effective scope, all first).
#   - Silent skip of a namespace file that does not exist (no user/golang).
#   - Bookends: FROM dev-base:latest ... USER dev / CMD ["sleep", "infinity"].
#   - FROM (first line) and CMD lines stripped from overlay fragments.
#   - COPY/ADD rejected with a clear error.
#   - Missing requested scope fails fast (delegates to dc_effective_scopes_csv).
#   - `all` auto-prepended even when not requested, when Containerfile.all exists.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# Fake HOME + global config so compose resolves DC_TEAM_DIR/DC_USER_DIR via the
# real dc_load_global_config path (no monkey-patching of the helper).
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dev-containers"
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
[[ "$(head -n1 "$WORK/out.Containerfile")" == "FROM dev-base:latest" ]] \
  || fail "bookend: first line must be FROM dev-base:latest"
grep -Fxq 'USER dev' "$WORK/out.Containerfile" \
  || fail "bookend: USER dev must be present"
grep -Fxq 'CMD ["sleep", "infinity"]' "$WORK/out.Containerfile" \
  || fail "bookend: CMD [\"sleep\", \"infinity\"] must be present"
# The bookends come after the last fragment: CMD is the final non-blank line.
[[ "$(awk 'NF {last=$0} END {print last}' "$WORK/out.Containerfile")" == 'CMD ["sleep", "infinity"]' ]] \
  || fail "bookend: CMD must be the final non-blank line"

pass "FROM dev-base / USER dev / CMD bookends"

# ---------------------------------------------------------------------------
# FROM (leading) + CMD + ENTRYPOINT stripping from overlay fragments
# ---------------------------------------------------------------------------
printf 'FROM dev-base:latest\nRUN echo STRIPEME\ncmd ["echo", "cmdme"]\nENTRYPOINT ["/tmp/leakme"]\n' \
  > "$TEAM_DIR/overlays/Containerfile.nodejs"
rm -f "$USER_DIR/overlays/Containerfile.nodejs" "$TEAM_DIR/overlays/Containerfile.golang" "$TEAM_DIR/overlays/Containerfile.all" "$USER_DIR/overlays/Containerfile.all"

run_compose "nodejs"
grep -Fq 'STRIPEME' "$WORK/out.Containerfile" \
  || fail "strip: RUN line from fragment must survive"
! grep -Fqi 'cmdme' "$WORK/out.Containerfile" \
  || fail "strip: CMD line must be stripped from fragment"
! grep -Fqi 'leakme' "$WORK/out.Containerfile" \
  || fail "strip: ENTRYPOINT line must be stripped from fragment"
# Exactly one FROM (the emitted dev-base); the fragment's leading FROM is gone.
from_count="$(grep -Eci '^FROM ' "$WORK/out.Containerfile")"
[[ "$from_count" -eq 1 ]] || fail "strip: expected exactly one FROM (got $from_count)"
# Exactly one ENTRYPOINT (the composed chained runner); the fragment's own
# ENTRYPOINT is gone, so multi-overlay containers don't clobber each other.
ep_count="$(grep -Eci '^ENTRYPOINT ' "$WORK/out.Containerfile")"
[[ "$ep_count" -eq 1 ]] || fail "strip: expected exactly one ENTRYPOINT (got $ep_count)"
grep -Eq 'ENTRYPOINT \["/home/dev/.local/bin/dc-entrypoint"\]' "$WORK/out.Containerfile" \
  || fail "strip: single ENTRYPOINT must be the composed runner"

pass "FROM/CMD/ENTRYPOINT stripping from overlay fragments"

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

echo ""
echo "All compose layering checks passed."
