#!/usr/bin/env bash
# =============================================================================
# tests/new-container-lifecycle.sh - End-to-end characterization of the
# `dc new` -> `dc rebuild-container` lifecycle against stubbed backends.
#
# This is where the "actually-hard" regressions hide (image derivation,
# config persistence, create-argv parity across new/rebuild, rebuild-never-
# builds, fail-fast on missing image, flag semantics). The real daemon is
# never contacted: stub docker/container/podman binaries log every call and
# answer the read predicates (image ls / ps) from a controlled tag list.
#
# Coverage:
#   dc new (docker):  image derivation, config persistence + inert round-trip,
#                     secret bootstrap (perms), generated Containerfile layer
#                     order, create argv shape (volume/port/resource order,
#                     image positional last), devcontainer.json.
#   dc new (apple):   .vscode/settings.json terminal-profile branch.
#   rebuild:          never builds; stop->delete->create->start order; create
#                     argv parity with `dc new`; default removes hidden volumes.
#   rebuild flags:    fail-fast on missing image (no destructive calls);
#                     --keep-hidden-volumes (no volume rm); --rotate-keys
#                     (backup + new key); --rotate-keys --keep-hidden-volumes
#                     (loud warning banner).
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

# ---------------------------------------------------------------------------
# Fake HOME + global config + overlays (team/user). No `all` so the derived
# hash is purely a function of (nodejs, golang).
# ---------------------------------------------------------------------------
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dev-containers"
OV="$DC_ROOT/overlays"
mkdir -p "$OV/team" "$OV/user"
printf 'DC_OVERLAYS_DIR="%s"\n' "$OV" > "$DC_ROOT/config"
printf 'RUN echo TEAM-NODEJS\n' > "$OV/team/Containerfile.nodejs"
printf 'RUN echo USER-NODEJS\n' > "$OV/user/Containerfile.nodejs"
printf 'RUN echo TEAM-GOLANG\n' > "$OV/team/Containerfile.golang"

# ---------------------------------------------------------------------------
# Stub CLIs (docker/container/podman) + a controllable image list.
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"
IMAGES_BAK="$WORK/images.bak"
: > "$LOG"
printf 'dev-base:latest\n' > "$IMAGES"

cat > "$STUB_DIR/_cli" <<'STUB'
#!/usr/bin/env bash
# Generic backend stub: logs each call; answers `image ls`/`images` from a
# controlled tag file; everything else succeeds silently.
_log="${DC_STUB_LOG:?}"
_imgs="${DC_STUB_IMAGES:-}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"

# Image listing (docker/podman/container) -> print configured tags.
if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then
  [[ -f "$_imgs" ]] && cat "$_imgs"
  exit 0
fi
if [[ "${1:-}" == "images" ]]; then
  [[ -f "$_imgs" ]] && cat "$_imgs"
  exit 0
fi

case "$me" in
  docker)
    if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then printf 'colima\n'; fi
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_cli"
cp "$STUB_DIR/_cli" "$STUB_DIR/docker"
cp "$STUB_DIR/_cli" "$STUB_DIR/container"
cp "$STUB_DIR/_cli" "$STUB_DIR/podman"

ORIG_PATH="$PATH"
stub_path() { export PATH="$STUB_DIR:$ORIG_PATH"; }

# Run a host script under the stub environment (fresh process; globals reset).
# Pin DC_REPOS_DIR so an ambient value in the caller's env cannot redirect the
# host workspace out of the fake HOME (the script falls back to $HOME/repos
# only when DC_REPOS_DIR is unset, which we cannot guarantee across shells).
# TZ is pinned so host-timezone detection is deterministic (see --env TZ).
run_script() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" \
  TZ="America/New_York" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="$BACKEND" \
  bash "$@"
}

# First CALL line matching a regex (for ordering/argv assertions).
first_call() { grep -En "$1" "$LOG" | head -n1 | cut -d: -f1; }

PROJECT="myapp"
REPOS_DIR="$WORK/home/repos/$PROJECT"
SECRET_DIR="$WORK/home/.config/dev-containers/$PROJECT"
CONFIG="$SECRET_DIR/config"

# ===========================================================================
# dc new (docker backend) with scopes + ports + resources + hidden path
# ===========================================================================
BACKEND=docker
: > "$LOG"
run_script "$ROOT_DIR/scripts/new-container.sh" \
  "$PROJECT" nodejs,golang --cpus 2 --memory 4g --hide node_modules 3000:3000 8080 \
  >"$WORK/new.stdout" 2>"$WORK/new.stderr"
[[ $? -eq 0 ]] || fail "dc new exited non-zero
-- stdout:$(cat "$WORK/new.stdout")
-- stderr:$(cat "$WORK/new.stderr")"

# --- config persistence --------------------------------------------------
[[ -f "$CONFIG" ]] || fail "dc new: config not written"
chmod 600 "$CONFIG" 2>/dev/null || true
dc_load_project_config "$CONFIG"
[[ "${CONTAINER_PROJECT:-}" == "$PROJECT" ]] || fail "config: CONTAINER_PROJECT"
[[ "${CONTAINER_OVERLAY_SCOPES:-}" == "nodejs,golang" ]] || fail "config: scopes (got [${CONTAINER_OVERLAY_SCOPES:-}])"
[[ "${CONTAINER_BACKEND:-}" == "docker" ]] || fail "config: backend"
[[ "${CONTAINER_CPUS:-}" == "2" ]] || fail "config: cpus"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "config: memory"
[[ "${PORTS[0]:-}" == "3000:3000" ]] || fail "config: PORTS[0]"
[[ "${PORTS[1]:-}" == "8080" ]] || fail "config: PORTS[1]"
[[ "${CONTAINER_HIDDEN_PATHS[0]:-}" == "node_modules" ]] || fail "config: hidden paths"
[[ "${CONTAINER_IMAGE:-}" == dev-img-*:latest ]] || fail "config: derived image"

# Persisted image is exactly what the helper derives from the scopes -> the
# new/rebuild bridge is deterministic by construction.
expected_img="$(dc_image_ref_from_scopes "$OV" "nodejs,golang")"
[[ "$CONTAINER_IMAGE" == "$expected_img" ]] \
  || fail "config: image [$CONTAINER_IMAGE] != derived [$expected_img]"

# --- secrets bootstrap (perms) -------------------------------------------
[[ -d "$SECRET_DIR" ]] || fail "secrets: dir missing"
# Portable octal mode: GNU stat (-c) first, BSD stat (-f) second. (The reverse
# order is wrong on Linux, where `stat -f '%Lp'` succeeds with filesystem junk.)
_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

[[ "$(_mode "$SECRET_DIR")" == "700" ]] || fail "secrets: dir must be 700"
[[ -f "$SECRET_DIR/ssh_key" ]] && [[ -f "$SECRET_DIR/ssh_key.pub" ]] || fail "secrets: ssh keypair missing"
[[ -f "$SECRET_DIR/github-token" ]] || fail "secrets: token placeholder missing"
[[ -f "$SECRET_DIR/.npmrc" ]] || fail "secrets: npmrc missing"
for f in ssh_key github-token .npmrc; do
  [[ "$(_mode "$SECRET_DIR/$f")" == "600" ]] \
    || fail "secrets: $f must be 600"
done

# --- generated Containerfile layer order (canonical) ---------------------
hash16="$(dc_image_hash_from_ref "$CONTAINER_IMAGE")"
gen_cf="$ROOT_DIR/Containerfiles/generated/Containerfile.$hash16"
[[ -f "$gen_cf" ]] || fail "dc new: generated Containerfile missing at $gen_cf"
gen_markers="$(awk '/^# --- begin overlay:auto:/ { sub(/^overlay:auto:/, "", $4); print $4 }' "$gen_cf")"
[[ "$gen_markers" == "team/nodejs
user/nodejs
team/golang" ]] || fail "dc new: generated layer order wrong [$gen_markers]"

# --- image built once with the derived tag + generated file --------------
grep -Fq "CALL docker build --tag $CONTAINER_IMAGE --file $gen_cf" "$LOG" \
  || fail "dc new: build call missing/wrong
$(grep '^CALL' "$LOG")"

# --- create argv shape: --name, volumes, publish, resources, image LAST ---
NEW_CREATE="$(grep -E 'create --name myapp' "$LOG" | head -n1)"
[[ -n "$NEW_CREATE" ]] || fail "dc new: no create call recorded"
grep -Fq -- "--name myapp"                <<<"$NEW_CREATE" || fail "create: --name"
grep -Fq -- "--volume $REPOS_DIR:/workspace" <<<"$NEW_CREATE" || fail "create: workspace mount"
grep -Fq -- "--volume $SECRET_DIR/.npmrc:/home/dev/.npmrc:ro" <<<"$NEW_CREATE" || fail "create: npmrc mount"
hidden_vol="$(dc_hidden_volume_name "$PROJECT" "node_modules")"
grep -Fq -- "--volume $hidden_vol:/workspace/node_modules" <<<"$NEW_CREATE" || fail "create: hidden mount"
grep -Fq -- "--publish 3000:3000"         <<<"$NEW_CREATE" || fail "create: port 3000"
grep -Fq -- "--publish 8080:8080"         <<<"$NEW_CREATE" || fail "create: port 8080"
grep -Fq -- "--cpus 2"                    <<<"$NEW_CREATE" || fail "create: cpus"
grep -Fq -- "--memory 4g"                 <<<"$NEW_CREATE" || fail "create: memory"
# Image positional must trail every flag.
[[ "${NEW_CREATE##* }" == "$CONTAINER_IMAGE" ]] || fail "create: image must be the last token (got [${NEW_CREATE##* }])"
# Volume group precedes publish group precedes resource group (documented order).
last_vol="$(grep -bo -- '--volume' <<<"$NEW_CREATE" | tail -1 | cut -d: -f1)"
first_pub="$(grep -bo -- '--publish' <<<"$NEW_CREATE" | head -1 | cut -d: -f1)"
first_cpu="$(grep -bo -- '--cpus' <<<"$NEW_CREATE" | head -1 | cut -d: -f1)"
[[ "$last_vol" -lt "$first_pub" ]] || fail "create: volume group must precede publish group"
[[ "$first_pub" -lt "$first_cpu" ]] || fail "create: publish group must precede resource group"

# --- host timezone synced via --env TZ (precedes every other flag group) ----
grep -Fq -- "--env TZ=America/New_York" <<<"$NEW_CREATE" \
  || fail "create: --env TZ=<host zone> missing
$NEW_CREATE"
first_tz="$(grep -bo -- '--env TZ=' <<<"$NEW_CREATE" | head -1 | cut -d: -f1)"
first_vol2="$(grep -bo -- '--volume' <<<"$NEW_CREATE" | head -1 | cut -d: -f1)"
[[ "$first_tz" -lt "$first_vol2" ]] \
  || fail "create: --env TZ must precede the volume group (env is fundamental)"

# --- devcontainer.json (docker-compatible branch) ------------------------
dc_json="$REPOS_DIR/.devcontainer/devcontainer.json"
[[ -f "$dc_json" ]] || fail "devcontainer.json missing"
grep -Fq '"workspaceFolder": "/workspace"' "$dc_json" || fail "devcontainer.json: workspaceFolder"
grep -Fq '"remoteUser": "dev"' "$dc_json" || fail "devcontainer.json: remoteUser"
grep -Fq "source=$hidden_vol" "$dc_json" || fail "devcontainer.json: hidden volume mount entry"
# The VS Code "Reopen in Container" recipe must carry the same TZ so a rebuild
# from VS Code matches a dc-created container.
grep -Fq '"containerEnv"' "$dc_json" || fail "devcontainer.json: containerEnv block missing"
grep -Fq '"TZ": "America/New_York"' "$dc_json" || fail "devcontainer.json: TZ not set in containerEnv"

pass "dc new (docker): config, secrets, layer order, create argv, devcontainer.json"

# ===========================================================================
# image reuse: a second project with the same scopes must NOT rebuild
# ===========================================================================
REUSE_PROJ="reuseproj"
printf '%s\n' "$CONTAINER_IMAGE" >> "$IMAGES"   # derived image now "present"
: > "$LOG"
run_script "$ROOT_DIR/scripts/new-container.sh" "$REUSE_PROJ" nodejs,golang 3000:3000 \
  >"$WORK/reuse.stdout" 2>"$WORK/reuse.stderr" \
  || fail "dc new (reuse) exited non-zero"
if grep -qE 'build --tag dev-img-' "$LOG"; then
  fail "dc new: must not rebuild an existing derived image
$(grep -E 'build' "$LOG")"
fi
grep -Fq "Reusing existing image: $CONTAINER_IMAGE" "$WORK/reuse.stdout" \
  || fail "dc new: should report it is reusing the existing image"
# Reset the image list to base-only for the rebuild sections below.
printf 'dev-base:latest\n' > "$IMAGES"

pass "dc new: reuses existing derived image (no rebuild)"

# ===========================================================================
# rebuild: never builds; stop->delete->create->start; create-argv parity
# ===========================================================================
cp "$IMAGES" "$IMAGES_BAK"
printf '%s\n' "$CONTAINER_IMAGE" >> "$IMAGES"   # derived image now "present"

: > "$LOG"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" \
  >"$WORK/rb.stdout" 2>"$WORK/rb.stderr" || fail "rebuild (default) exited non-zero"

# Never builds an image.
if grep -qE 'build --tag (dev-base|dev-img-)' "$LOG"; then
  fail "rebuild: must never build an image
$(grep -E 'build' "$LOG")"
fi

# Order: delete (rm -f) < create < start. Stop is skipped because stub reports
# the container not running (no `stop myapp` call expected).
del_ln="$(first_call 'rm -f myapp')"
cre_ln="$(first_call 'create --name myapp')"
sta_ln="$(first_call 'start myapp')"
[[ -n "$del_ln" ]] || fail "rebuild: delete call missing"
[[ -n "$cre_ln" ]] || fail "rebuild: create call missing"
[[ -n "$sta_ln" ]] || fail "rebuild: start call missing"
[[ "$del_ln" -lt "$cre_ln" ]] || fail "rebuild: delete must precede create"
[[ "$cre_ln" -lt "$sta_ln" ]] || fail "rebuild: create must precede start"

# Create-argv parity with `dc new`: same volume/port/resource shape, same image.
RB_CREATE="$(grep -E 'create --name myapp' "$LOG" | head -n1)"
[[ "$RB_CREATE" == "$NEW_CREATE" ]] \
  || fail "rebuild/new create-argv parity broken
-- new:     $NEW_CREATE
-- rebuild: $RB_CREATE"

# Default rebuild removes hidden volumes (clean slate) -> volume rm observed.
grep -Fq "CALL docker volume rm $hidden_vol" "$LOG" \
  || fail "rebuild: default should remove hidden volume [$hidden_vol]
$(grep 'volume' "$LOG")"

pass "rebuild (default): never builds, delete<create<start, create-argv parity, removes hidden volumes"

# ===========================================================================
# rebuild fail-fast when the derived image is missing (no destructive calls)
# ===========================================================================
cp "$IMAGES_BAK" "$IMAGES"   # derived image absent again

: > "$LOG"
if printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" \
      >"$WORK/ff.stdout" 2>"$WORK/ff.stderr"; then
  fail "rebuild: must fail fast when derived image missing"
fi
# The "Run: dc rebuild-image all" guidance is echoed on stdout by rebuild.
grep -Fqi 'rebuild-image all' "$WORK/ff.stdout" \
  || fail "rebuild: fail-fast error should instruct dc rebuild-image all"
if grep -qE 'rm -f myapp|create --name myapp|stop myapp' "$LOG"; then
  fail "rebuild: fail-fast must NOT issue destructive calls
$(grep -E 'rm -f|create|stop' "$LOG")"
fi

pass "rebuild: fail-fast on missing image (no destructive calls)"

# ===========================================================================
# rebuild --keep-hidden-volumes: no volume rm
# ===========================================================================
printf '%s\n' "$CONTAINER_IMAGE" >> "$IMAGES"

: > "$LOG"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" --keep-hidden-volumes \
  >"$WORK/kh.stdout" 2>"$WORK/kh.stderr" || fail "rebuild --keep-hidden-volumes exited non-zero"
if grep -qE 'volume rm' "$LOG"; then
  fail "rebuild --keep-hidden-volumes: must not remove volumes
$(grep 'volume' "$LOG")"
fi

pass "rebuild --keep-hidden-volumes: preserves hidden volumes"

# ===========================================================================
# rebuild --rotate-keys --keep-hidden-volumes: loud warning banner
# ===========================================================================
: > "$LOG"
# yes for the destroy confirm, then Enter for the rotate-key pause prompt.
printf 'yes\n\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" \
  "$PROJECT" --rotate-keys --keep-hidden-volumes \
  >"$WORK/warn.stdout" 2>"$WORK/warn.stderr" || fail "rebuild (warning combo) exited non-zero"
grep -Fqi 'WARNING' "$WORK/warn.stdout" || fail "rebuild: --rotate-keys + --keep-hidden-volumes must emit a WARNING banner"

pass "rebuild --rotate-keys --keep-hidden-volumes: loud warning banner"

# ===========================================================================
# rebuild --rotate-keys: old key backed up, new key generated
# ===========================================================================
pub_before="$(cat "$SECRET_DIR/ssh_key.pub")"
: > "$LOG"
# yes for the destroy confirm, then Enter for the rotate pause prompt.
printf 'yes\n\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" --rotate-keys \
  >"$WORK/rk.stdout" 2>"$WORK/rk.stderr" || fail "rebuild --rotate-keys exited non-zero"

# A timestamped backup of the old private key exists.
bak_glob="$SECRET_DIR/ssh_key.bak.*"
( compgen -G "$bak_glob" >/dev/null ) || fail "rebuild --rotate-keys: no key backup found"
# The active public key has changed.
pub_after="$(cat "$SECRET_DIR/ssh_key.pub")"
[[ "$pub_before" != "$pub_after" ]] || fail "rebuild --rotate-keys: SSH public key did not rotate"

pass "rebuild --rotate-keys: backs up old key, generates a new one"

# ===========================================================================
# dc new (apple backend): VS Code terminal-profile settings.json branch
# ===========================================================================
APROJ="appleproj"
BACKEND=apple
: > "$LOG"
run_script "$ROOT_DIR/scripts/new-container.sh" "$APROJ" nodejs 3000:3000 \
  >"$WORK/apple.stdout" 2>"$WORK/apple.stderr" \
  || fail "dc new (apple) exited non-zero"

vs_settings="$WORK/home/repos/$APROJ/.vscode/settings.json"
[[ -f "$vs_settings" ]] || fail "apple: .vscode/settings.json missing"
grep -Fq '"terminal.integrated.defaultProfile.osx": "dev-container"' "$vs_settings" \
  || fail "apple: defaultProfile.dev-container missing"
grep -Fq "scripts/shell.sh $APROJ" "$vs_settings" \
  || fail "apple: terminal profile must reference dc shell.sh $APROJ"
# apple branch must NOT write a Dev Containers devcontainer.json.
[[ ! -f "$WORK/home/repos/$APROJ/.devcontainer/devcontainer.json" ]] \
  || fail "apple: must not write devcontainer.json"
# apple/container also receives the host TZ via --env (backend-agnostic).
APPLE_CREATE="$(grep -E 'create --name appleproj' "$LOG" | head -n1)"
grep -Fq -- "--env TZ=America/New_York" <<<"$APPLE_CREATE" \
  || fail "apple create: --env TZ missing
$APPLE_CREATE"

pass "dc new (apple): VS Code terminal-profile settings.json branch"

echo ""
echo "All new/rebuild lifecycle checks passed."
