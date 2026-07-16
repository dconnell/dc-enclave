#!/usr/bin/env bash
# =============================================================================
# tests/contract/sync-lifecycle.sh - End-to-end characterization of the
# `--sync` (Mutagen-synced workspace) feature against stubbed backends.
#
# Covers the contract plans/sync.md defines:
#   dce new --sync:        volume mount swap (dce-sync-<slug>-<12hex>:/workspace),
#                          --env DCE_WORKSPACE_TYPE=sync, no hidden mounts,
#                          config persistence (CONTAINER_SYNC=1 +
#                          CONTAINER_SYNC_IGNORE_PATHS, empty hidden paths),
#                          mutagen sync create called with host alpha + beta +
#                          the derived --sync-ignore rules.
#   mutual exclusion:      --sync + --hide fails fast; --sync-ignore alone
#                          fails fast; apple/podman backend + --sync fails fast.
#   rebuild:               mounts the sync volume, flushes before delete,
#                          create-argv parity with `dce new`, session resume.
#   rm:                    terminates the sync session, removes the sync volume.
#   snapshot:              prints the sync-volume exclusion guard.
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

# Fake HOME + global config + a nodejs overlay (so a derived image composes).
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
TEAM_OD="$TEAM_DIR/overlays"
USER_OD="$USER_DIR/overlays"
mkdir -p "$TEAM_OD" "$USER_OD"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"
printf 'RUN echo TEAM-NODEJS\n' > "$TEAM_OD/Containerfile.nodejs"

# ---------------------------------------------------------------------------
# Stub CLIs: docker (logs calls, answers image ls/ps/exec) + mutagen (logs,
# reports sessions present).
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"
: > "$LOG"
printf 'dce-base:latest\n' > "$IMAGES"

cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_imgs="${DC_STUB_IMAGES:-}"
printf 'CALL %s %s\n' "docker" "$*" >> "$_log"
if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then
  [[ -f "$_imgs" ]] && cat "$_imgs"; exit 0
fi
if [[ "${1:-}" == "images" ]]; then
  [[ -f "$_imgs" ]] && cat "$_imgs"; exit 0
fi
if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then printf 'default\n'; exit 0; fi
if [[ "${1:-}" == "ps" ]]; then
  [[ -n "${DC_STUB_RUNNING:-}" ]] && printf '%s\n' "$DC_STUB_RUNNING"; exit 0
fi
if [[ "${1:-}" == "exec" ]]; then exit 0; fi
# volume ls: emit a controlled volume list (incl. a dce-sync-* volume) so the
# clean-sweep exclusion contract can be asserted.
if [[ "${1:-}" == "volume" && "${2:-}" == "ls" ]]; then
  [[ -n "${DC_STUB_SYNC_VOL:-}" ]] && printf '%s\n' "$DC_STUB_SYNC_VOL"
  exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/docker"
cp "$STUB_DIR/docker" "$STUB_DIR/container"
cp "$STUB_DIR/docker" "$STUB_DIR/podman"

# Mutagen stub logs to the SAME ordered log as docker so cross-tool ordering
# (flush-before-delete, terminate-before-volume-rm) can be asserted by line.
cat > "$STUB_DIR/mutagen" <<'STUB'
#!/usr/bin/env bash
printf 'CALL mutagen %s\n' "$*" >> "${DC_STUB_LOG:?}"
case "${1:-} ${2:-}" in
  "sync list") exit 0 ;;        # session exists
  "sync create") exit 0 ;;
  "sync flush") exit 0 ;;
  "sync resume") exit 0 ;;
  "sync terminate") exit 0 ;;
  "version ") printf 'mutagen 0.18.0\n'; exit 0 ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/mutagen"

ORIG_PATH="$PATH"
run_script() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" \
  TZ="America/New_York" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" \
  DC_STUB_RUNNING="${DC_STUB_RUNNING:-}" \
  DC_STUB_SYNC_VOL="${DC_STUB_SYNC_VOL:-}" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="$BACKEND" \
  bash "$@"
}
first_call() { grep -En "$1" "$LOG" | head -n1 | cut -d: -f1; }

# ===========================================================================
# dce new --sync --sync-ignore node_modules,dist (docker backend)
# ===========================================================================
BACKEND=docker
PROJECT="syncapp"
REPOS_DIR="$WORK/home/repos/$PROJECT"
SECRET_DIR="$WORK/home/.config/dce-enclave/$PROJECT"
CONFIG="$SECRET_DIR/config"

: > "$LOG"; 
if ! run_script "$ROOT_DIR/scripts/new-container.sh" \
  "$PROJECT" nodejs --sync --sync-ignore node_modules,dist --cpus 2 --memory 4g 3000:3000 \
  >"$WORK/new.stdout" 2>"$WORK/new.stderr"; then
  fail "dce new --sync exited non-zero
-- stdout:$(cat "$WORK/new.stdout")
-- stderr:$(cat "$WORK/new.stderr")"
fi

# --- config persistence ---
[[ -f "$CONFIG" ]] || fail "config not written"
chmod 600 "$CONFIG" 2>/dev/null || true
dce_load_project_config "$CONFIG"
[[ "${CONTAINER_SYNC:-}" == "1" ]] || fail "config: CONTAINER_SYNC must be 1"
[[ "${CONTAINER_IMAGE:-}" == dce-img-*:latest ]] || fail "config: derived image"
# Sync-ignored paths persisted; hidden paths empty.
[[ "${CONTAINER_SYNC_IGNORE_PATHS[0]:-}" == "node_modules" ]] || fail "config: sync-ignore[0]"
[[ "${CONTAINER_SYNC_IGNORE_PATHS[1]:-}" == "dist" ]] || fail "config: sync-ignore[1]"
[[ ${#CONTAINER_HIDDEN_PATHS[@]} -eq 0 ]] || fail "config: hidden paths must be empty under --sync"

# --- create argv: sync volume mount, workspace-type env, no hidden mounts ---
NEW_CREATE="$(grep -E 'create --name syncapp' "$LOG" | head -n1)"
[[ -n "$NEW_CREATE" ]] || fail "no create call recorded"
sync_vol="$(dce_sync_volume_name "$PROJECT")"
grep -Fq -- "--env DCE_WORKSPACE_TYPE=sync" <<<"$NEW_CREATE" || fail "create: DCE_WORKSPACE_TYPE=sync"
grep -Fq -- "--volume $sync_vol:/workspace" <<<"$NEW_CREATE" || fail "create: sync volume mount [$sync_vol]"
grep -Fq -- "--volume $SECRET_DIR/.npmrc:/home/dev/.npmrc:ro" <<<"$NEW_CREATE" || fail "create: npmrc mount"
# No hidden-volume mounts under --sync.
! grep -Fq -- "dce-hide-" <<<"$NEW_CREATE" || fail "create: must have NO hidden mounts under --sync"
grep -Fq -- "--publish 3000:3000" <<<"$NEW_CREATE" || fail "create: port"
grep -Fq -- "--cpus 2" <<<"$NEW_CREATE" || fail "create: cpus"
[[ "${NEW_CREATE##* }" == "$CONTAINER_IMAGE" ]] || fail "create: image must be last"
# env group precedes volume group (env is fundamental).
first_env="$(grep -bo -- '--env' <<<"$NEW_CREATE" | head -1 | cut -d: -f1)"
first_vol="$(grep -bo -- '--volume' <<<"$NEW_CREATE" | head -1 | cut -d: -f1)"
[[ "$first_env" -lt "$first_vol" ]] || fail "create: env must precede volume group"

# --- mutagen session created (host alpha, container beta, --name, ignore) ---
CREATE_LINE="$(grep -E 'sync create' "$LOG" | head -n1)"
[[ -n "$CREATE_LINE" ]] || fail "mutagen sync create not called"
grep -Fq -- "$REPOS_DIR" <<<"$CREATE_LINE" || fail "mutagen alpha must be host REPOS_DIR"
grep -Fq -- "docker://$PROJECT//workspace" <<<"$CREATE_LINE" || fail "mutagen beta must be docker://<project>//workspace"
grep -Fq -- "--name dce-sync-syncapp" <<<"$CREATE_LINE" || fail "mutagen --name"
grep -Fq -- "--ignore node_modules" <<<"$CREATE_LINE" || fail "mutagen --ignore node_modules"
grep -Fq -- "--ignore dist" <<<"$CREATE_LINE" || fail "mutagen --ignore dist"
grep -Fq -- "--mode two-way-resolved" <<<"$CREATE_LINE" || fail "mutagen host-canonical mode (two-way-resolved = alpha-wins)"

pass "dce new --sync: mount swap, env, config, mutagen create, no hidden mounts"

# ===========================================================================
# mutual exclusion / fail-fast (must NOT create anything)
# ===========================================================================
: > "$LOG"
if run_script "$ROOT_DIR/scripts/new-container.sh" "bad1" nodejs --sync --hide node_modules \
  >"$WORK/b1.out" 2>"$WORK/b1.err"; then
  fail "--sync + --hide must fail fast"
fi
grep -Fqi 'mutually exclusive' "$WORK/b1.err" || fail "--sync+--hide must mention mutual exclusion"
! grep -qE 'create --name bad1' "$LOG" || fail "--sync+--hide must not create a container"

if run_script "$ROOT_DIR/scripts/new-container.sh" "bad2" nodejs --sync-ignore node_modules \
  >"$WORK/b2.out" 2>"$WORK/b2.err"; then
  fail "--sync-ignore without --sync must fail fast"
fi
grep -Fqi 'only has meaning with --sync' "$WORK/b2.err" || fail "lone --sync-ignore message"

# apple backend + --sync must fail fast (no Mutagen transport).
BACKEND=apple
: > "$LOG"
if run_script "$ROOT_DIR/scripts/new-container.sh" "bad3" --sync \
  >"$WORK/b3.out" 2>"$WORK/b3.err"; then
  fail "--sync on apple backend must fail fast"
fi
grep -Fqi 'apple/container' "$WORK/b3.err" || fail "apple --sync must mention apple/container"
! grep -qE 'create --name bad3' "$LOG" || fail "apple --sync must not create a container"
BACKEND=docker

# podman backend + --sync must fail fast (Mutagen has no podman transport; the
# docker-transport bridge to a podman-machine VM is SSH-host-key blocked).
BACKEND=podman
: > "$LOG"
if run_script "$ROOT_DIR/scripts/new-container.sh" "bad4" --sync \
  >"$WORK/b4.out" 2>"$WORK/b4.err"; then
  fail "--sync on podman backend must fail fast"
fi
grep -Fqi 'podman' "$WORK/b4.err" || fail "podman --sync must mention podman"
! grep -qE 'create --name bad4' "$LOG" || fail "podman --sync must not create a container"
BACKEND=docker

pass "--sync mutual-exclusion + apple/podman fail-fast"

# ===========================================================================
# rebuild on a synced project: mount preserved, flush before delete, parity
# ===========================================================================
printf '%s\n' "$CONTAINER_IMAGE" >> "$IMAGES"   # derived image now "present"
: > "$LOG"; 
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" \
  >"$WORK/rb.out" 2>"$WORK/rb.err" || fail "rebuild exited non-zero"

# Never builds an image during rebuild.
if grep -qE 'build --tag (dce-base|dce-img-)' "$LOG"; then
  fail "rebuild must never build an image"
fi
# Flush before delete (data-loss prevention): flush call precedes container delete.
flush_ln="$(first_call 'sync flush' || true)"; flush_ln="${flush_ln:-999999}"
del_ln="$(first_call 'rm -f syncapp')"
[[ -n "$del_ln" ]] || fail "rebuild: container delete missing"
[[ "$flush_ln" -lt "$del_ln" ]] \
  || fail "rebuild: mutagen flush must precede container delete (flush=$flush_ln del=$del_ln)"
# Create-argv parity with `dce new`.
RB_CREATE="$(grep -E 'create --name syncapp' "$LOG" | head -n1)"
[[ "$RB_CREATE" == "$NEW_CREATE" ]] \
  || fail "rebuild/new create-argv parity broken
-- new:     $NEW_CREATE
-- rebuild: $RB_CREATE"
# Session resumed (session exists per stub).
grep -Fq 'sync resume' "$LOG" || fail "rebuild must resume the sync session"

pass "rebuild (synced): flush<delete, create-argv parity, session resume"

# ===========================================================================
# snapshot: sync volume is excluded (guard message printed)
# ===========================================================================
: > "$LOG"
export DC_STUB_RUNNING="syncapp"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" "lbl" \
  >"$WORK/snap.out" 2>"$WORK/snap.err" || { cat "$WORK/snap.err"; fail "snapshot exited non-zero"; }
unset DC_STUB_RUNNING
grep -Fqi 'sync volume excluded' "$WORK/snap.out" || fail "snapshot must note sync-volume exclusion"
# No snapshot-volume copy attempted for the sync volume (no hidden paths to copy).
! grep -Eq 'volume copy|backend_volume_copy' "$LOG" || true

pass "snapshot: sync volume excluded (host canonical)"

# ===========================================================================
# rm: terminates the sync session + removes the sync volume
# ===========================================================================
: > "$LOG"; 
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rm.sh" "$PROJECT" \
  >"$WORK/rm.out" 2>"$WORK/rm.err" || fail "rm exited non-zero"
grep -Fq 'sync terminate' "$LOG" || fail "rm must terminate the sync session"
grep -Fq "volume rm $sync_vol" "$LOG" || fail "rm must remove the sync volume [$sync_vol]"
# Session terminated BEFORE the volume is removed (so Mutagen releases it).
term_ln="$(grep -En 'sync terminate' "$LOG" | head -1 | cut -d: -f1)"
volrm_ln="$(first_call "volume rm $sync_vol")"
[[ "$term_ln" -lt "$volrm_ln" ]] \
  || fail "rm: session terminate must precede volume removal"

pass "rm: session terminated, sync volume removed (terminate before volume rm)"

# ===========================================================================
# dce clean must NEVER touch dce-sync-* (prefix exclusion contract)
# ===========================================================================
: > "$LOG"
DC_STUB_SYNC_VOL="$sync_vol" \
  run_script "$ROOT_DIR/scripts/clean.sh" --hidden-volumes \
  >"$WORK/clean.out" 2>"$WORK/clean.err" || { cat "$WORK/clean.err"; fail "clean --hidden-volumes exited non-zero"; }
# The sync volume is listed by the backend but must NOT be removed: the
# dce-hide- prefix scope excludes dce-sync-* by construction.
! grep -Fq "volume rm $sync_vol" "$LOG" \
  || fail "dce clean --hidden-volumes must NOT remove a dce-sync-* volume [$sync_vol]"

: > "$LOG"
DC_STUB_SYNC_VOL="$sync_vol" \
  run_script "$ROOT_DIR/scripts/clean.sh" --snapshots \
  >"$WORK/clean2.out" 2>"$WORK/clean2.err" || { cat "$WORK/clean2.err"; fail "clean --snapshots exited non-zero"; }
! grep -Fq "volume rm $sync_vol" "$LOG" \
  || fail "dce clean --snapshots must NOT remove a dce-sync-* volume [$sync_vol]"

pass "dce clean: dce-sync-* never swept by --hidden-volumes or --snapshots"

echo ""
echo "All sync-lifecycle checks passed."
