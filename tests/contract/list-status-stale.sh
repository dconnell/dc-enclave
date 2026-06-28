#!/usr/bin/env bash
# =============================================================================
# tests/contract/list-status-stale.sh - Stale-container surfacing in `dce list`/`dce status`.
#
# A container is stale when the image id it is bound to differs from the id its
# configured CONTAINER_IMAGE tag currently resolves to. This typically happens
# after `dce rebuild-image` rebuilds the tag to a new id while the container
# keeps running on the old one until `dce rebuild-container` is run.
#
# The real backend is never contacted: a stub `docker` on a private PATH answers
# the read predicates (ps, ps -a, image inspect, inspect) from a controlled
# state directory. Four projects exercise the predicate matrix:
#   fresh   - container id == desired id      -> NOT stale
#   stale   - container id != desired id      -> STALE (warned)
#   missing - container does not exist        -> NOT stale (cannot be stale)
#   unknown - desired image id unavailable    -> NOT stale (drift unprovable)
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
# Stub docker: answers the four read predicates from a state directory so the
# stale predicate has deterministic inputs. Every path exits 0 (the real
# backend_* callers treat non-zero + empty identically, but staying 0 keeps the
# stub honest about "succeeded with empty result" vs "command failed").
# ---------------------------------------------------------------------------
STATE="$WORK/state"
mkdir -p "$STATE"
: > "$STATE/running"      # container names currently running (one per line)
: > "$STATE/exists"       # container names that exist at all (ps -a)
: > "$STATE/images"       # <ref>\t<image-id> rows
: > "$STATE/containers"   # <name>\t<bound-image-id> rows

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/docker" <<STUB
#!/usr/bin/env bash
state="\${DC_STUB_STATE:?}"
has_a=0
if [[ "\${1:-}" == "ps" ]]; then
  for a in "\$@"; do [[ "\$a" == "-a" ]] && has_a=1; done
  if [[ \$has_a -eq 1 ]]; then
    [[ -f "\$state/exists" ]] && cat "\$state/exists"
  else
    [[ -f "\$state/running" ]] && cat "\$state/running"
  fi
  exit 0
fi
if [[ "\${1:-}" == "image" && "\${2:-}" == "inspect" ]]; then
  ref="\$3"
  [[ -f "\$state/images" ]] && while IFS=\$'\t' read -r r id; do
    [[ "\$r" == "\$ref" ]] && { printf '%s\n' "\$id"; exit 0; }
  done < "\$state/images"
  exit 0
fi
if [[ "\${1:-}" == "inspect" ]]; then
  name="\$2"
  [[ -f "\$state/containers" ]] && while IFS=\$'\t' read -r n id; do
    [[ "\$n" == "\$name" ]] && { printf '%s\n' "\$id"; exit 0; }
  done < "\$state/containers"
  exit 0
fi
# Detection noise (docker backend does not probe context, but answer anyway).
if [[ "\${1:-}" == "context" && "\${2:-}" == "show" ]]; then printf 'default\n'; exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/docker"

# ---------------------------------------------------------------------------
# Fake HOME with four projects. Each config is owner-only (chmod 600) in an
# owner-only dir (chmod 700), as dce_load_project_config requires.
# ---------------------------------------------------------------------------
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
mkdir -p "$DC_ROOT"

# fresh: running, container id == desired id -> not stale
mkdir -p "$DC_ROOT/fresh"
cat > "$DC_ROOT/fresh/config" <<'CFG'
CONTAINER_PROJECT="fresh"
CONTAINER_BACKEND="docker"
CONTAINER_IMAGE="dce-img-fresh:latest"
CONTAINER_OVERLAY_SCOPES="nodejs"
CFG
chmod 700 "$DC_ROOT/fresh"
chmod 600 "$DC_ROOT/fresh/config"
printf 'fresh\n' >> "$STATE/running"
printf 'fresh\n' >> "$STATE/exists"
printf 'dce-img-fresh:latest\tsha-fresh-aaa\n' >> "$STATE/images"
printf 'fresh\tsha-fresh-aaa\n' >> "$STATE/containers"

# stale: stopped, container id != desired id -> STALE
mkdir -p "$DC_ROOT/stale"
cat > "$DC_ROOT/stale/config" <<'CFG'
CONTAINER_PROJECT="stale"
CONTAINER_BACKEND="docker"
CONTAINER_IMAGE="dce-img-stale:latest"
CONTAINER_OVERLAY_SCOPES="nodejs"
CFG
chmod 700 "$DC_ROOT/stale"
chmod 600 "$DC_ROOT/stale/config"
printf 'stale\n' >> "$STATE/exists"
printf 'dce-img-stale:latest\tsha-stale-new\n' >> "$STATE/images"
printf 'stale\tsha-stale-old\n' >> "$STATE/containers"

# missing: container does not exist -> not stale (no entries in running/exists)
mkdir -p "$DC_ROOT/missing"
cat > "$DC_ROOT/missing/config" <<'CFG'
CONTAINER_PROJECT="missing"
CONTAINER_BACKEND="docker"
CONTAINER_IMAGE="dce-img-miss:latest"
CONTAINER_OVERLAY_SCOPES="nodejs"
CFG
chmod 700 "$DC_ROOT/missing"
chmod 600 "$DC_ROOT/missing/config"
printf 'dce-img-miss:latest\tsha-miss-aaa\n' >> "$STATE/images"

# unknown: desired image id unavailable (no images entry) -> not stale
mkdir -p "$DC_ROOT/unknown"
cat > "$DC_ROOT/unknown/config" <<'CFG'
CONTAINER_PROJECT="unknown"
CONTAINER_BACKEND="docker"
CONTAINER_IMAGE="dce-img-unk:latest"
CONTAINER_OVERLAY_SCOPES="nodejs"
CFG
chmod 700 "$DC_ROOT/unknown"
chmod 600 "$DC_ROOT/unknown/config"
printf 'unknown\n' >> "$STATE/running"
printf 'unknown\n' >> "$STATE/exists"
printf 'unknown\tsha-unk-aaa\n' >> "$STATE/containers"

export DC_STUB_STATE="$STATE"
export CONTAINER_BACKEND=docker

run_with_stub() {
  PATH="$STUB_DIR:$PATH" HOME="$WORK/home" CONTAINER_BACKEND=docker \
    DC_STUB_STATE="$STATE" bash "$@"
}

# ---------------------------------------------------------------------------
# dce list: rightmost WARN column shows STALE only for the stale project.
# ---------------------------------------------------------------------------
LIST_OUT="$WORK/list.out"
run_with_stub "$ROOT_DIR/scripts/list.sh" >"$LIST_OUT" 2>&1 \
  || fail "dce list exited non-zero
$(cat "$LIST_OUT")"

# Header carries the new WARN column.
grep -Eq '^[[:space:]]*NAME[[:space:]].*WARN[[:space:]]*$' "$LIST_OUT" \
  || fail "dce list: header missing WARN column
$(cat "$LIST_OUT")"

# Only the stale project is marked STALE; the other three are not.
grep -Eq '^stale[[:space:]].*STALE[[:space:]]*$' "$LIST_OUT" \
  || fail "dce list: stale project should carry STALE warning
$(cat "$LIST_OUT")"
! grep -Eq '^fresh[[:space:]].*STALE' "$LIST_OUT" \
  || fail "dce list: fresh project must not be marked STALE
$(cat "$LIST_OUT")"
! grep -Eq '^missing[[:space:]].*STALE' "$LIST_OUT" \
  || fail "dce list: missing project must not be marked STALE
$(cat "$LIST_OUT")"
! grep -Eq '^unknown[[:space:]].*STALE' "$LIST_OUT" \
  || fail "dce list: unknown project must not be marked STALE
$(cat "$LIST_OUT")"
# The missing project is reported missing (sanity: the stub state is wired up).
grep -Eq '^missing[[:space:]]+missing[[:space:]]' "$LIST_OUT" \
  || fail "dce list: missing project should show 'missing' state
$(cat "$LIST_OUT")"

pass "dce list: STALE warned only for proven image-id drift"

# ---------------------------------------------------------------------------
# dce status: dedicated stale section lists only the stale project, with the
# rebuild-container remediation hint.
# ---------------------------------------------------------------------------
STATUS_OUT="$WORK/status.out"
run_with_stub "$ROOT_DIR/scripts/status.sh" >"$STATUS_OUT" 2>&1 \
  || fail "dce status exited non-zero
$(cat "$STATUS_OUT")"

grep -Eq '^Stale containers:' "$STATUS_OUT" \
  || fail "dce status: missing 'Stale containers:' section
$(cat "$STATUS_OUT")"
grep -Eq '^[[:space:]]+- stale \(run: dce rebuild-container stale\)' "$STATUS_OUT" \
  || fail "dce status: stale project not listed with rebuild hint
$(cat "$STATUS_OUT")"
! grep -Eq 'rebuild-container fresh' "$STATUS_OUT" \
  || fail "dce status: fresh project must not appear in stale remediation
$(cat "$STATUS_OUT")"
! grep -Eq 'rebuild-container missing' "$STATUS_OUT" \
  || fail "dce status: missing project must not appear in stale remediation
$(cat "$STATUS_OUT")"
! grep -Eq 'rebuild-container unknown' "$STATUS_OUT" \
  || fail "dce status: unknown project must not appear in stale remediation
$(cat "$STATUS_OUT")"

pass "dce status: stale section lists only the stale project"

# ---------------------------------------------------------------------------
# Degenerate case: no stale projects -> "Stale containers: none".
# Fix the stale project (make its container id match) and re-run status.
# ---------------------------------------------------------------------------
printf 'stale\tsha-stale-new\n' > "$STATE/containers.tmp"
# Rebuild the containers map with the now-matching id, keeping other rows.
awk -F'\t' -v OFS='\t' '$1=="stale"{$2="sha-stale-new"} {print}' \
  "$STATE/containers" > "$STATE/containers.new" && mv "$STATE/containers.new" "$STATE/containers"

STATUS_OUT2="$WORK/status2.out"
run_with_stub "$ROOT_DIR/scripts/status.sh" >"$STATUS_OUT2" 2>&1 \
  || fail "dce status (after fix) exited non-zero
$(cat "$STATUS_OUT2")"
grep -Eq '^Stale containers:[[:space:]]*$' "$STATUS_OUT2" || {
  # The "none" line is on the following line; accept either shape.
  grep -Eq 'none' "$STATUS_OUT2" \
    || fail "dce status: expected 'none' after fixing drift
$(cat "$STATUS_OUT2")"
}
! grep -Eq 'rebuild-container stale' "$STATUS_OUT2" \
  || fail "dce status: stale project should no longer appear after fix
$(cat "$STATUS_OUT2")"

pass "dce status: reports 'none' once drift is resolved"

echo ""
echo "All stale-container surfacing checks passed."
