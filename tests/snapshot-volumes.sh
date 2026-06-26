#!/usr/bin/env bash
# =============================================================================
# tests/snapshot-volumes.sh - `dce snapshot` (volumes by default) + selective
# exclusion + confirmation prompt + isolated restore + reclamation.
#
# Stubbed-backend characterization:
#   - dce snapshot <project>: captures hidden volumes BY DEFAULT (source mounted
#     READ-ONLY); prompts before copying unless --yes/-y; --exclude-volumes /
#     --exclude-volume <path> skip volumes.
#   - restore (--from-snap): ALWAYS isolates hidden volumes (populated where
#     captured, empty otherwise), leaves originals untouched, reports each, and
#     never fails fast over a missing volume.
#   - Reclamation: snapshot rm / clean --snapshots / dce rm remove snapvols;
#     default clean --hidden-volumes leaves them.
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

export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
TEAM_OD="$TEAM_DIR/overlays"
USER_OD="$USER_DIR/overlays"
mkdir -p "$TEAM_OD" "$USER_DIR"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"
printf 'RUN echo TEAM-NODEJS\n' > "$TEAM_OD/Containerfile.nodejs"

# ---------------------------------------------------------------------------
# Stateful stub CLIs (docker/container/podman). State in files; `run` is the
# volume-copy primitive (auto-creates referenced volumes; fails a designated dst).
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"
VOLUMES="$WORK/volumes.lst"
LABELS="$WORK/labels.lst"
RUNNING="$WORK/running.lst"
EXISTS="$WORK/exists.lst"
: > "$LOG"
printf 'dce-base:latest\n' > "$IMAGES"
: > "$VOLUMES"; : > "$LABELS"; : > "$RUNNING"; : > "$EXISTS"

cat > "$STUB_DIR/_stub" <<STUB
#!/usr/bin/env bash
_log="\${DC_STUB_LOG:?}"
_imgs="\${DC_STUB_IMAGES:?}"
_vols="\${DC_STUB_VOLUMES:?}"
_labels="\${DC_STUB_LABELS:?}"
_running="\${DC_STUB_RUNNING:?}"
_exists="\${DC_STUB_EXISTS:?}"
me="\$(basename "\$0")"
printf 'CALL %s %s\n' "\$me" "\$*" >> "\$_log"

img_add() { printf '%s\n' "\$1" >> "\$_imgs"; }
img_del() { grep -Fxv "\$1" "\$_imgs" > "\$_imgs.tmp" 2>/dev/null; mv "\$_imgs.tmp" "\$_imgs"; }
vol_add() { grep -Fxq "\$1" "\$_vols" 2>/dev/null || printf '%s\n' "\$1" >> "\$_vols"; }
vol_del() { grep -Fxv "\$1" "\$_vols" > "\$_vols.tmp" 2>/dev/null; mv "\$_vols.tmp" "\$_vols"; }
label_set() { printf '%s\t%s\n' "\$1" "\$2" >> "\$_labels"; }

fmt_val() {
  local i=1
  while [[ \$i -le \$# ]]; do
    if [[ "\${!i}" == "--format" ]]; then local nxt=\$((i+1)); printf '%s' "\${!nxt}"; return 0; fi
    i=\$((i+1))
  done
}

if [[ "\${1:-}" == "image" && "\${2:-}" == "ls" ]] || { [[ "\$me" == "container" ]] && [[ "\${1:-}" == "images" || "\${1:-}" == "image" && "\${2:-}" == "ls" ]]; }; then
  fv="\$(fmt_val "\$@")"
  while IFS= read -r line; do
    [[ -z "\$line" ]] && continue
    repo="\${line%:*}"; tag="\${line##*:}"
    if [[ "\$fv" == *":"* ]]; then printf '%s:%s\n' "\$repo" "\$tag"
    else printf '%s\t%s\t%s\n' "\$repo" "\$tag" "id-\$line"; fi
  done < "\$_imgs"
  exit 0
fi
if [[ "\$me" != "container" && "\${1:-}" == "image" && "\${2:-}" == "inspect" ]]; then
  ref="\${3:-}"; fv="\$(fmt_val "\$@")"
  case "\$fv" in
    '{{.Size}}') printf '2048000\n' ;;
    '{{.Id}}') printf 'id-%s\n' "\$ref" ;;
    '{{index .Config.Labels'*)
      key="\$(printf '%s' "\$fv" | sed -n 's/.*Labels *"\([^"]*\)".*/\1/p')"
      while IFS=\$'\\t' read -r lref kv; do
        [[ "\$lref" == "\$ref" ]] || continue
        [[ "\${kv%%=*}" == "\$key" ]] && { printf '%s' "\${kv#*=}"; exit 0; }
      done < "\$_labels" ;;
  esac
  exit 0
fi
if [[ "\$me" == "container" && "\${1:-}" == "image" && "\${2:-}" == "inspect" ]]; then exit 0; fi
if [[ "\${1:-}" == "image" && "\${2:-}" == "rm" ]]; then img_del "\${3:-}"; exit 0; fi

if [[ "\${1:-}" == "commit" ]]; then
  shift; declare -a positionals=()
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--change" ]]; then label_set "P" "\${2#LABEL }"; shift 2
    else positionals+=("\$1"); shift; fi
  done
  img_add "\${positionals[1]}"
  exit 0
fi
if [[ "\$me" == "container" && "\${1:-}" == "inspect" ]]; then exit 0; fi
if [[ "\$me" == "container" && "\${1:-}" == "export" ]]; then exit 0; fi
if [[ "\$me" == "container" && "\${1:-}" == "build" ]]; then
  shift; while [[ \$# -gt 0 ]]; do case "\$1" in --tag) img_add "\$2"; shift 2;; *) shift;; esac; done
  exit 0
fi

if [[ "\${1:-}" == "run" ]]; then
  declare -a refs=(); i=1
  while [[ \$i -le \$# ]]; do
    a="\${!i}"
    if [[ "\$a" == "-v" ]]; then nxt=\$((i+1)); refs+=("\${!nxt%%:*}")
    elif [[ "\$a" == "--mount" ]]; then nxt=\$((i+1)); spec="\${!nxt}"
      src="\$(printf '%s' "\$spec" | sed -n 's/.*source=\([^,]*\).*/\1/p')"
      [[ -n "\$src" ]] && refs+=("\$src")
    fi
    i=\$((i+1))
  done
  for r in "\${refs[@]}"; do vol_add "\$r"; done
  for r in "\${refs[@]}"; do [[ "\$r" == "\${DC_STUB_FAIL_COPY_DST:-}" ]] && exit 1; done
  exit 0
fi

if [[ "\${1:-}" == "volume" && "\${2:-}" == "ls" ]]; then cat "\$_vols"; exit 0; fi
if [[ "\${1:-}" == "volume" && "\${2:-}" == "rm" ]]; then vol_del "\${3:-}"; exit 0; fi
if [[ "\$me" == "container" && "\${1:-}" == "volume" && ( "\${2:-}" == "rm" || "\${2:-}" == "delete" ) ]]; then vol_del "\${3:-}"; exit 0; fi

if [[ "\${1:-}" == "ps" ]]; then
  all=\$([[ "\${2:-}" == "-a" ]] && echo yes || echo no)
  [[ "\$all" == yes ]] && awk 'NF' "\$_exists" 2>/dev/null || awk 'NF' "\$_running" 2>/dev/null
  exit 0
fi
if [[ "\$me" == "docker" && "\${1:-}" == "context" && "\${2:-}" == "show" ]]; then printf 'default\n'; exit 0; fi
if [[ "\${1:-}" == "create" ]]; then
  name=""; i=1
  while [[ \$i -le \$# ]]; do if [[ "\${!i}" == "--name" ]]; then nxt=\$((i+1)); name="\${!nxt}"; fi; i=\$((i+1)); done
  [[ -n "\$name" ]] && grep -Fxq "\$name" "\$_exists" 2>/dev/null || printf '%s\n' "\$name" >> "\$_exists"
  exit 0
fi
if [[ "\${1:-}" == "start" ]]; then printf '%s\n' "\${2:-}" >> "\$_running"; exit 0; fi
if [[ "\${1:-}" == "stop" ]]; then grep -Fxv "\${2:-}" "\$_running" > "\$_running.tmp" 2>/dev/null && mv "\$_running.tmp" "\$_running"; exit 0; fi
if [[ "\${1:-}" == "rm" && "\${2:-}" == "-f" ]]; then grep -Fxv "\${3:-}" "\$_exists" > "\$_exists.tmp" 2>/dev/null && mv "\$_exists.tmp" "\$_exists"; exit 0; fi
if [[ "\${1:-}" == "exec" || "\${1:-}" == "info" || "\${1:-}" == "network" ]]; then exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/_stub"
cp "$STUB_DIR/_stub" "$STUB_DIR/docker"
cp "$STUB_DIR/_stub" "$STUB_DIR/container"
cp "$STUB_DIR/_stub" "$STUB_DIR/podman"

ORIG_PATH="$PATH"
run_script() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" TZ="UTC" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" DC_STUB_VOLUMES="$VOLUMES" \
  DC_STUB_LABELS="$LABELS" DC_STUB_RUNNING="$RUNNING" DC_STUB_EXISTS="$EXISTS" \
  PATH="$STUB_DIR:$ORIG_PATH" CONTAINER_BACKEND="$BACKEND" \
  bash "$@"
}
img_has() { grep -Fxq "$1" "$IMAGES" 2>/dev/null; }
vol_has() { grep -Fxq "$1" "$VOLUMES" 2>/dev/null; }

# ===========================================================================
# Create a project with a hidden path via `dce new` (docker backend).
# ===========================================================================
BACKEND=docker
PROJECT="myapp"
SECRET_DIR="$WORK/home/.config/dce-enclave/$PROJECT"
CONFIG="$SECRET_DIR/config"
: > "$LOG"
run_script "$ROOT_DIR/scripts/new-container.sh" "$PROJECT" nodejs \
  --hide node_modules 3000:3000 >"$WORK/new.stdout" 2>"$WORK/new.stderr" \
  || fail "dce new exited non-zero"
[[ -f "$CONFIG" ]] || fail "dce new: config not written"
chmod 600 "$CONFIG" 2>/dev/null || true
expected_img="$(dce_image_ref_from_scopes "$TEAM_OD" "$USER_OD" "nodejs")"
grep -Fxq "$expected_img" "$IMAGES" || printf '%s\n' "$expected_img" >> "$IMAGES"
grep -Fxq "$PROJECT" "$EXISTS" || printf '%s\n' "$PROJECT" >> "$EXISTS"
grep -Fxq "$PROJECT" "$RUNNING" || printf '%s\n' "$PROJECT" >> "$RUNNING"
orig_vol="$(dce_hidden_volume_name "$PROJECT" "node_modules")"
printf '%s\n' "$orig_vol" >> "$VOLUMES"

# ===========================================================================
# A. confirmation prompt: non-'yes' aborts (no snapshot, no copy); --yes skips
# ===========================================================================
snap_ref_prompt="$(dce_snapshot_ref "$PROJECT" "promptabort")"
: > "$LOG"
# Non-'yes' answer -> exit 0 (aborted), no image, no volume copy.
if printf 'no\n' | run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" promptabort \
      >"$WORK/pa.stdout" 2>"$WORK/pa.stderr"; then
  :
else
  fail "snapshot: aborted confirm should exit 0"
fi
img_has "$snap_ref_prompt" && fail "snapshot: aborted prompt must not create the image" || true
if grep -q '^CALL docker run' "$LOG"; then
  fail "snapshot: aborted prompt must not issue a volume copy"
fi
grep -Fqi 'Aborted' "$WORK/pa.stdout" || fail "snapshot: should print 'Aborted' on non-yes"
pass "snapshot prompt: non-'yes' aborts without copying or committing"

# 'yes' on stdin proceeds.
: > "$LOG"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" promptyes \
  >"$WORK/py.stdout" 2>"$WORK/py.stderr" || fail "snapshot (yes on stdin) exited non-zero"
img_has "$(dce_snapshot_ref "$PROJECT" "promptyes")" || fail "snapshot: 'yes' should create the image"
pass "snapshot prompt: 'yes' on stdin proceeds"

# --yes skips the prompt entirely (no stdin).
: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" promptyesflag --yes \
  </dev/null >"$WORK/pf.stdout" 2>"$WORK/pf.stderr" \
  || fail "snapshot --yes exited non-zero"
img_has "$(dce_snapshot_ref "$PROJECT" "promptyesflag")" || fail "snapshot --yes: should create the image"
pass "snapshot --yes: skips the prompt"

# --exclude-volumes skips the prompt (nothing to copy).
: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" promptexc --exclude-volumes \
  </dev/null >"$WORK/pe.stdout" 2>"$WORK/pe.stderr" \
  || fail "snapshot --exclude-volumes exited non-zero"
pass "snapshot --exclude-volumes: no prompt (nothing to copy)"

# ===========================================================================
# B. snapshot (default, --yes): captures the hidden volume RO, writes manifest
# ===========================================================================
snapvol="$(dce_snapshot_volume_name "$PROJECT" "pre" "node_modules")"
snap_ref="$(dce_snapshot_ref "$PROJECT" "pre")"
manifest="$(dce_snapshot_volumes_manifest "$PROJECT" "pre")"

: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" pre --yes >"$WORK/snap.stdout" 2>"$WORK/snap.stderr" \
  || fail "dce snapshot (default) exited non-zero
-- stderr:$(cat "$WORK/snap.stderr")"

copy_call="$(grep -E 'docker run --rm -u 0 -v .*:/from:ro -v .*:/to dce-base:latest' "$LOG" | head -n1)"
[[ -n "$copy_call" ]] || fail "snapshot: no read-only volume-copy call logged
$(grep '^CALL docker run' "$LOG")"
grep -Fq -- "-v $orig_vol:/from:ro" <<<"$copy_call" \
  || fail "snapshot: source must be mounted read-only [$copy_call]"
grep -Fq -- "-v $snapvol:/to" <<<"$copy_call" || fail "snapshot: dest must be the snapshot volume [$copy_call]"
grep -Fq -- " -u 0 " <<<"$copy_call" || fail "snapshot: copy must run as uid 0"

vol_has "$snapvol" || fail "snapshot: snapvol not created"
vol_has "$orig_vol" || fail "snapshot: original hidden volume must remain"
[[ -f "$manifest" ]] || fail "snapshot: manifest not written"
grep -Fxq "$(printf '%s\t%s\tcaptured' "node_modules" "$snapvol")" "$manifest" \
  || fail "snapshot: manifest row wrong/absent
$(cat "$manifest")"

run_script "$ROOT_DIR/scripts/snapshot.sh" list "$PROJECT" >"$WORK/list.stdout" 2>&1 \
  || fail "snapshots list exited non-zero"
grep -Fq "captured 1" "$WORK/list.stdout" || fail "list: VOLUMES column should say 'captured 1'"
pass "dce snapshot (default): RO clone, manifest, originals untouched, list column"

# ===========================================================================
# C. copy failure -> empty snapvol + WARNING, snapshot still created
# ===========================================================================
snapvol_fail="$(dce_snapshot_volume_name "$PROJECT" "flaky" "node_modules")"
snap_ref_fail="$(dce_snapshot_ref "$PROJECT" "flaky")"
manifest_fail="$(dce_snapshot_volumes_manifest "$PROJECT" "flaky")"
: > "$LOG"
DC_STUB_FAIL_COPY_DST="$snapvol_fail" run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" flaky --yes \
  >"$WORK/flaky.stdout" 2>"$WORK/flaky.stderr" \
  || fail "snapshot (copy failure) must NOT abort (exit non-zero)"
img_has "$snap_ref_fail" || fail "snapshot: FS image must be created even if volume copy fails"
grep -Fqi 'WARNING' "$WORK/flaky.stdout" || fail "snapshot: copy failure must emit a WARNING"
grep -Fxq "$(printf '%s\t%s\tfailed' "node_modules" "$snapvol_fail")" "$manifest_fail" \
  || fail "snapshot: failed manifest row wrong
$(cat "$manifest_fail")"
vol_has "$orig_vol" || fail "snapshot: original must survive a failed copy"
pass "dce snapshot: copy failure -> empty snapvol + WARNING, FS image created"

# ===========================================================================
# D. selective --exclude-volume: one path excluded, another captured
# ===========================================================================
# Add a second hidden path so selective exclusion is observable.
chmod 600 "$CONFIG" 2>/dev/null || true
dce_set_config_array "$CONFIG" CONTAINER_HIDDEN_PATHS "node_modules" ".cache"
chmod 600 "$CONFIG" 2>/dev/null || true
printf '%s\n' "$(dce_hidden_volume_name "$PROJECT" ".cache")" >> "$VOLUMES"

: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" sel --exclude-volume node_modules --yes \
  >"$WORK/sel.stdout" 2>"$WORK/sel.stderr" \
  || fail "dce snapshot --exclude-volume exited non-zero"
manifest_sel="$(dce_snapshot_volumes_manifest "$PROJECT" "sel")"
snapvol_sel_nm="$(dce_snapshot_volume_name "$PROJECT" "sel" "node_modules")"
snapvol_sel_cache="$(dce_snapshot_volume_name "$PROJECT" "sel" ".cache")"
# node_modules excluded (no copy, manifest excluded); .cache captured.
grep -Fxq "$(printf '%s\t%s\texcluded' "node_modules" "$snapvol_sel_nm")" "$manifest_sel" \
  || fail "selective: node_modules should be excluded
$(cat "$manifest_sel")"
grep -Fxq "$(printf '%s\t%s\tcaptured' ".cache" "$snapvol_sel_cache")" "$manifest_sel" \
  || fail "selective: .cache should be captured
$(cat "$manifest_sel")"
# The excluded volume was NOT copied; the captured one WAS.
if grep -Fq -- "-v $orig_vol:/from:ro" "$LOG"; then
  fail "selective: excluded volume must not be copied"
fi
grep -Fq -- "-v $(dce_hidden_volume_name "$PROJECT" ".cache"):/from:ro" "$LOG" \
  || fail "selective: non-excluded volume must be copied"
pass "dce snapshot --exclude-volume <path>: selective exclusion (others still captured)"

# Reset to a single hidden path for the remaining sections.
chmod 600 "$CONFIG" 2>/dev/null || true
dce_set_config_array "$CONFIG" CONTAINER_HIDDEN_PATHS "node_modules"
chmod 600 "$CONFIG" 2>/dev/null || true

# ===========================================================================
# E. restore --from-snap: mounts populated snapshot volume, leaves originals
# ===========================================================================
: > "$LOG"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" --from-snap pre \
  >"$WORK/restore.stdout" 2>"$WORK/restore.stderr" \
  || fail "rebuild --from-snap exited non-zero
-- stderr:$(cat "$WORK/restore.stderr")"
rb_create="$(grep -E 'create --name myapp' "$LOG" | head -n1)"
[[ -n "$rb_create" ]] || fail "restore: no create call"
grep -Fq -- "--volume $snapvol:/workspace/node_modules" <<<"$rb_create" \
  || fail "restore: must mount the snapshot volume
$rb_create"
if grep -Fq -- "--volume $orig_vol:" <<<"$rb_create"; then
  fail "restore: must NOT mount the original hidden volume
$rb_create"
fi
grep -Fqi 'populated' "$WORK/restore.stdout" || fail "restore: should report node_modules populated"
pass "rebuild --from-snap: mounts populated snapshot volume, leaves originals, reports populated"

# ===========================================================================
# F. uncovered path -> empty snapshot volume + report (no fail-fast, no original)
# ===========================================================================
chmod 600 "$CONFIG" 2>/dev/null || true
dce_set_config_array "$CONFIG" CONTAINER_HIDDEN_PATHS "node_modules" "apps/web/.cache"
chmod 600 "$CONFIG" 2>/dev/null || true
new_snapvol="$(dce_snapshot_volume_name "$PROJECT" "pre" "apps/web/.cache")"
: > "$LOG"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" --from-snap pre \
  >"$WORK/restore2.stdout" 2>"$WORK/restore2.stderr" \
  || fail "rebuild --from-snap must NOT fail fast on an uncovered path
-- stderr:$(cat "$WORK/restore2.stderr")"
rb_create2="$(grep -E 'create --name myapp' "$LOG" | head -n1)"
grep -Fq -- "--volume $snapvol:/workspace/node_modules" <<<"$rb_create2" \
  || fail "restore: covered path must mount its snapshot volume"
grep -Fq -- "--volume $new_snapvol:/workspace/apps/web/.cache" <<<"$rb_create2" \
  || fail "restore: uncovered path must mount an (empty) snapshot volume, not the original
$rb_create2"
grep -Fqi 'empty' "$WORK/restore2.stdout" || fail "restore: should report the uncovered volume empty"
pass "rebuild --from-snap: uncovered path -> empty snapshot volume + report"
chmod 600 "$CONFIG" 2>/dev/null || true
dce_set_config_array "$CONFIG" CONTAINER_HIDDEN_PATHS "node_modules"
chmod 600 "$CONFIG" 2>/dev/null || true

# ===========================================================================
# G. snapshot rm / clean --snapshots / dce rm reclaim volumes
# ===========================================================================
: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" rm "$PROJECT" pre >"$WORK/rm.stdout" 2>&1 \
  || fail "snapshot rm exited non-zero"
img_has "$snap_ref" && fail "snapshot rm: image should be removed" || true
vol_has "$snapvol" && fail "snapshot rm: snapvol should be removed" || true
[[ ! -f "$manifest" ]] || fail "snapshot rm: manifest should be removed"
pass "snapshot rm: removes image + snapshot volume + manifest"

run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" pre --yes >/dev/null 2>&1 \
  || fail "re-snapshot pre failed"

: > "$LOG"
run_script "$ROOT_DIR/scripts/clean.sh" --hidden-volumes --dry-run >"$WORK/hv.stdout" 2>&1 \
  || fail "clean --hidden-volumes --dry-run exited non-zero"
if grep -Fq 'dce-snapvol-' "$WORK/hv.stdout"; then
  fail "clean --hidden-volumes: must not list snapshot volumes"
fi
pass "clean --hidden-volumes: ignores dce-snapvol-* (distinct prefix)"

: > "$LOG"
run_script "$ROOT_DIR/scripts/clean.sh" --snapshots "$PROJECT" >"$WORK/cs.stdout" 2>&1 \
  || fail "clean --snapshots <project> exited non-zero"
img_has "$snap_ref" && fail "clean --snapshots: image should be removed" || true
vol_has "$snapvol" && fail "clean --snapshots: snapvol should be removed" || true
pass "clean --snapshots <project>: reclaims image + snapshot volume"

run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" byebye --yes >/dev/null 2>&1 \
  || fail "snapshot (default) for rm-sweep failed"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" keep --yes >/dev/null 2>&1 \
  || fail "snapshot (default) for rm-sweep failed"
snapvol_keep="$(dce_snapshot_volume_name "$PROJECT" "keep" "node_modules")"
snap_ref_bye="$(dce_snapshot_ref "$PROJECT" "byebye")"
vol_has "$snapvol_keep" || fail "setup: keep snapvol missing"
img_has "$snap_ref_bye" || fail "setup: byebye image missing"
: > "$LOG"
run_script "$ROOT_DIR/scripts/rm.sh" "$PROJECT" --yes >"$WORK/rm2.stdout" 2>&1 \
  || fail "dce rm exited non-zero"
vol_has "$snapvol_keep" && fail "dce rm: should sweep the project's snapvols" || true
img_has "$snap_ref_bye" && fail "dce rm: should sweep the project's snapshot images" || true
pass "dce rm: sweeps dce-snapvol-<slug>-* and snapshot images"

echo ""
echo "All snapshot-volume checks passed."
