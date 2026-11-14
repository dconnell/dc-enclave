#!/usr/bin/env bash
# =============================================================================
# tests/contract/clean-stages.sh - `dce clean` reclaims apple chained-build
# stage repos (dce-stage-<16hex>-<n>).
#
# compose-containerfile.sh's apple transport chaining (issue #735) builds the
# intermediate images dce-stage-<hash>-0 .. <hash>-(N-1) alongside the final
# dce-img-<hash>. Stages are pure derived intermediates -- the final image
# exists independently -- so the default `dce clean` sweep must reclaim every
# tag on them. is_managed_repo names the stage family explicitly so the
# reclaim does not depend on the project-alias grammar happening to match
# stage names (a project could alias-collide, or the alias grammar could
# tighten, and stages must stay reclaimable regardless).
#
# Stub-driven (stateful fake docker CLI; the real daemon is never contacted).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ---------------------------------------------------------------------------
# Fake HOME + global config (no project configs: expected repos = dce-base).
# ---------------------------------------------------------------------------
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dc-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR" "$USER_DIR"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

# ---------------------------------------------------------------------------
# Stateful stub docker CLI: image store in a file, every call logged.
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"
: > "$LOG"

HASH="0123456789abcdef"
STAGE0="dce-stage-$HASH-0"
STAGE1="dce-stage-$HASH-1"
STAGE2="dce-stage-$HASH-2"

cat > "$STUB_DIR/_cs_stub" <<STUB
#!/usr/bin/env bash
_log="\${DC_STUB_LOG:?}"
_imgs="\${DC_STUB_IMAGES:?}"
printf 'CALL %s %s\n' "\$(basename "\$0")" "\$*" >> "\$_log"

img_del() { grep -Fxv "\$1" "\$_imgs" > "\$_imgs.tmp" 2>/dev/null && mv "\$_imgs.tmp" "\$_imgs"; }

case "\${1:-}" in
  info) exit 0 ;;
  image)
    case "\${2:-}" in
      ls)
        fv=""
        while [[ \$# -gt 0 ]]; do
          [[ "\$1" == "--format" ]] && fv="\$2"
          shift
        done
        while IFS= read -r line; do
          [[ -z "\$line" ]] && continue
          repo="\${line%:*}"; tag="\${line##*:}"
          if [[ "\$fv" == *'{{.Repository}}:{{.Tag}}'* ]]; then
            printf '%s:%s\n' "\$repo" "\$tag"
          else
            printf '%s\t%s\tid-%s\n' "\$repo" "\$tag" "\$line"
          fi
        done < "\$_imgs"
        exit 0
        ;;
      rm)
        shift
        for ref in "\$@"; do img_del "\$ref"; done
        exit 0
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_cs_stub"
cp "$STUB_DIR/_cs_stub" "$STUB_DIR/docker"

ORIG_PATH="$PATH"

img_has() { grep -Fxq "$1" "$IMAGES" 2>/dev/null; }

run_clean() {
  HOME="$WORK/home" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND=docker \
  bash "$@"
}

# ---------------------------------------------------------------------------
# The world: dce-base (expected, kept), three chained stages from one over-cap
# build, the final derived image (orphan here but dce-managed grammar), plus
# images the sweep must never touch (a non-dce image and a lookalike repo that
# matches neither the stage nor the alias grammar).
# ---------------------------------------------------------------------------
printf 'dce-base:latest\n%s:latest\n%s:latest\n%s:latest\ndce-img-%s:latest\nuser-image:latest\ndce-stage-%s-0:old\n' \
  "$STAGE0" "$STAGE1" "$STAGE2" "$HASH" "$HASH" > "$IMAGES"
cp "$IMAGES" "$WORK/before.lst"

# --- dry run: stages are listed as removal candidates, nothing removed ------
run_clean "$ROOT_DIR/scripts/clean.sh" --dry-run >"$WORK/dry.out" 2>"$WORK/dry.err" \
  || fail "clean --dry-run exited non-zero
$(cat "$WORK/dry.err")"
grep -Fq "$STAGE0:latest" "$WORK/dry.out" || fail "dry run: must list $STAGE0:latest"
grep -Fq "$STAGE2:latest" "$WORK/dry.out" || fail "dry run: must list $STAGE2:latest"
grep -Fq "$STAGE0:old" "$WORK/dry.out" || fail "dry run: must list every stage tag (incl. non-latest)"
diff -q "$WORK/before.lst" "$IMAGES" >/dev/null \
  || fail "dry run: must not remove anything"
pass "clean --dry-run: lists stage tags as orphans, removes nothing"

# --- default clean: every stage tag reclaimed, everything else kept ---------
run_clean "$ROOT_DIR/scripts/clean.sh" >"$WORK/clean.out" 2>"$WORK/clean.err" \
  || fail "clean exited non-zero
$(cat "$WORK/clean.err")"

for ref in "$STAGE0:latest" "$STAGE1:latest" "$STAGE2:latest" "$STAGE0:old"; do
  ! img_has "$ref" || fail "clean: stage tag $ref must be reclaimed"
  grep -Fq "image rm $ref" "$LOG" || fail "clean: must issue image rm for $ref
$(cat "$LOG")"
done
img_has "dce-base:latest" || fail "clean: dce-base must never be reclaimed"
img_has "user-image:latest" || fail "clean: non-dce images must never be touched"
pass "clean default: every dce-stage-<16hex>-<n> tag reclaimed via image rm"

# The derived image is not selected by any config here, so it is an orphan too:
# assert its rm call so the stage reclaim can't be confused with it.
grep -Fq "image rm dce-img-$HASH:latest" "$LOG" \
  || fail "clean: config-less derived image is still an orphan and must be removed
$(cat "$LOG")"
pass "clean default: config-less dce-img stays an orphan (distinct from stage reclaim)"

# --- grammar negatives: the sweep is not a loose dce-stage-* prefix match ----
# An uppercase "hash" matches neither the stage grammar ([0-9a-f]{16}) nor the
# lowercase-only alias grammar, so that repo is foreign and must stay.
printf 'dce-base:latest\ndce-stage-ZZZZZZZZZZZZZZZZ-0:latest\nuser-image:latest\n' > "$IMAGES"
: > "$LOG"
run_clean "$ROOT_DIR/scripts/clean.sh" >"$WORK/clean2.out" 2>"$WORK/clean2.err" \
  || fail "clean (lookalikes) exited non-zero
$(cat "$WORK/clean2.err")"

img_has "dce-stage-ZZZZZZZZZZZZZZZZ-0:latest" \
  || fail "clean: an uppercase-hash repo matches neither the stage grammar nor the
alias grammar and must be left untouched (the sweep must not be a loose
dce-stage-* prefix match)
$(cat "$LOG")"
img_has "user-image:latest" \
  || fail "clean: non-dce images must never be touched"
pass "clean grammar: only dce-stage-<16hex>-<digits> matches the stage family"

echo ""
echo "All clean-stages checks passed."
