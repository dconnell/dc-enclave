#!/usr/bin/env bash
# =============================================================================
# tests/snapshots.sh - Container snapshot create/list/rm/restore/clean coverage.
#
# Stubbed-backend characterization of the snapshot feature (plans/snapshots.md):
#   - backend_container_commit dispatch: native `commit` on docker-family, and
#     the apple export + FROM-scratch build path (with mandatory USER re-apply).
#   - dce snapshot: stop -> commit -> start; refuse overwrite; label validation.
#   - dce snapshots list: project scoping + sizes.
#   - dce rebuild-container --from-snap: bypasses scope derivation, does NOT
#     rewrite CONTAINER_IMAGE, recreates from the snapshot ref.
#   - dce clean: default leaves dce-snap-*; --snapshots reclaims; --dry-run and
#     per-project scoping behave.
#
# The real daemon is never contacted: stub docker/container/podman binaries keep
# state in files (image list, running/existing containers, labels) so the read
# predicates answer from a controlled world.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# Does an image exist in the stub store? (Defined early; used in every section.)
img_has() { grep -Fxq "$1" "$IMAGES" 2>/dev/null; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ---------------------------------------------------------------------------
# Fake HOME + global config + overlays.
# ---------------------------------------------------------------------------
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
# Stateful stub CLIs (docker/container/podman). State lives in files so it
# survives across separate process invocations.
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"          # one "repo:tag" per line
LABELS="$WORK/labels.lst"          # "repo:tag<TAB>key=value" per line
RUNNING="$WORK/running.lst"        # container names currently running
EXISTS="$WORK/exists.lst"          # container names that exist
APPLE_CFILE="$WORK/apple.Containerfile"  # captured apple build Containerfile
: > "$LOG"
printf 'dce-base:latest\n' > "$IMAGES"
: > "$LABELS"
: > "$RUNNING"
: > "$EXISTS"

cat > "$STUB_DIR/_stub" <<STUB
#!/usr/bin/env bash
# Stateful backend stub. Logs every call; answers read predicates from files;
# mutates state for commit/build/create/start/stop/rm/image rm.
_log="\${DC_STUB_LOG:?}"
_imgs="\${DC_STUB_IMAGES:?}"
_labels="\${DC_STUB_LABELS:?}"
_running="\${DC_STUB_RUNNING:?}"
_exists="\${DC_STUB_EXISTS:?}"
me="\$(basename "\$0")"
printf 'CALL %s %s\n' "\$me" "\$*" >> "\$_log"

# --- helpers ----------------------------------------------------------------
img_lines() { [[ -f "\$_imgs" ]] && cat "\$_imgs"; }
img_has() { grep -Fxq "\$1" "\$_imgs" 2>/dev/null; }
img_add() { printf '%s\n' "\$1" >> "\$_imgs"; }
img_del() { grep -Fxv "\$1" "\$_imgs" > "\$_imgs.tmp" 2>/dev/null && mv "\$_imgs.tmp" "\$_imgs"; }
label_set() { printf '%s\t%s\n' "\$1" "\$2" >> "\$_labels"; }
label_get() { grep -F "\$1	" "\$_labels" 2>/dev/null | sed -n 's/^[^	]*	\([^=]*\)=\(.*\)\$/KEY=\1/p' | head -n1; }

# Scan argv for "--format <value>"; echo the value (or empty).
fmt_val() {
  local i=1
  while [[ \$i -le \$# ]]; do
    if [[ "\${!i}" == "--format" ]]; then
      local nxt=\$((i+1))
      printf '%s' "\${!nxt}"
      return 0
    fi
    i=\$((i+1))
  done
}

# --- image ls (docker/podman/apple variants) --------------------------------
if [[ "\${1:-}" == "image" && "\${2:-}" == "ls" ]] || { [[ "\$me" == "container" ]] && [[ "\${1:-}" == "images" || "\${1:-}" == "image" && "\${2:-}" == "ls" ]]; }; then
  fv="\$(fmt_val "\$@")"
  while IFS= read -r line; do
    [[ -z "\$line" ]] && continue
    repo="\${line%:*}"; tag="\${line##*:}"
    if [[ "\$fv" == *'\t'* ]]; then
      printf '%s\t%s\t%s\n' "\$repo" "\$tag" "id-\$line"
    elif [[ "\$fv" == *":"* ]]; then
      printf '%s:%s\n' "\$repo" "\$tag"
    else
      printf '%s\t%s\t%s\n' "\$repo" "\$tag" "id-\$line"
    fi
  done < "\$_imgs"
  exit 0
fi

# --- image inspect <ref> --format <fmt> (size / id / label lookup) ----------
# Docker-family only; apple is handled by the container-specific block below.
if [[ "\$me" != "container" && "\${1:-}" == "image" && "\${2:-}" == "inspect" ]]; then
  ref="\${3:-}"; fv="\$(fmt_val "\$@")"
  case "\$fv" in
    '{{.Size}}') printf '2048000\n'; exit 0 ;;
    '{{.Id}}') printf 'id-%s\n' "\$ref"; exit 0 ;;
    '{{index .Config.Labels'*)
      key="\$(printf '%s' "\$fv" | sed -n 's/.*Labels *"\([^"]*\)".*/\1/p')"
      while IFS=\$'\\t' read -r lref kv; do
        [[ "\$lref" == "\$ref" ]] || continue
        k="\${kv%%=*}"
        [[ "\$k" == "\$key" ]] && { printf '%s' "\${kv#*=}"; exit 0; }
      done < "\$_labels"
      exit 0
      ;;
  esac
  exit 0
fi

# --- image rm <ref> ---------------------------------------------------------
if [[ "\${1:-}" == "image" && "\${2:-}" == "rm" ]]; then
  img_del "\${3:-}"; exit 0
fi
# apple image rm / rmi aliases
if [[ "\$me" == "container" && "\${1:-}" == "image" && "\${2:-}" == "rm" ]]; then
  img_del "\${3:-}"; exit 0
fi

# --- commit (docker-family): commit [--change 'LABEL k=v']... NAME TAG ------
if [[ "\${1:-}" == "commit" ]]; then
  shift
  declare -a changes=(); positionals=()
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--change" ]]; then
      changes+=("\$2"); shift 2
    else
      positionals+=("\$1"); shift
    fi
  done
  name="\${positionals[0]}"; tag="\${positionals[1]}"
  img_add "\$tag"
  for c in "\${changes[@]}"; do
    case "\$c" in
      LABEL\ *) kv="\${c#LABEL }"; label_set "\$tag" "\$kv" ;;
    esac
  done
  exit 0
fi

# --- apple: container inspect <name> --format {{.ImageID}} ------------------
if [[ "\$me" == "container" && "\${1:-}" == "inspect" && "\${2:-}" != "image" ]]; then
  fv="\$(fmt_val "\$@")"
  [[ "\$fv" == '{{.ImageID}}' ]] && { printf 'sha256:base-image\n'; exit 0; }
  exit 0
fi

# --- apple: container image inspect <ref|id> --format <field> ---------------
# Unified apple handler: size / id / label lookup / config fields.
if [[ "\$me" == "container" && "\${1:-}" == "image" && "\${2:-}" == "inspect" ]]; then
  ref="\${3:-}"; fv="\$(fmt_val "\$@")"
  case "\$fv" in
    '{{.size}}') printf '2048000\n'; exit 0 ;;
    '{{.ID}}') printf 'id-%s\n' "\$ref"; exit 0 ;;
    '{{index .config.labels'*)
      key="\$(printf '%s' "\$fv" | sed -n 's/.*labels *"\([^"]*\)".*/\1/p')"
      while IFS=\$'\\t' read -r lref kv; do
        [[ "\$lref" == "\$ref" ]] || continue
        k="\${kv%%=*}"
        [[ "\$k" == "\$key" ]] && { printf '%s' "\${kv#*=}"; exit 0; }
      done < "\$_labels"
      exit 0
      ;;
    '{{.config.user}}')        printf 'dev\n'; exit 0 ;;
    '{{.config.workingDir}}')  printf '/workspace\n'; exit 0 ;;
    '{{.config.env}}')         printf '[PATH=/usr/local/sbin:/usr/local/bin]\n'; exit 0 ;;
    '{{.config.cmd}}')         printf '[/usr/local/bin/entrypoint]\n'; exit 0 ;;
    '{{.config.entrypoint}}')  printf '[]\n'; exit 0 ;;
  esac
  exit 0
fi

# --- apple: container export -o <tar> <name> --------------------------------
if [[ "\$me" == "container" && "\${1:-}" == "export" ]]; then
  tar_out=""; name=""
  i=1
  while [[ \$i -le \$# ]]; do
    if [[ "\${!i}" == "-o" ]]; then nxt=\$((i+1)); tar_out="\${!nxt}"; fi
    i=\$((i+1))
  done
  name="\${@:\$#}"
  : > "\$tar_out"
  exit 0
fi

# --- apple: container build --tag <tag> --file <cfile> <ctx> ---------------
if [[ "\$me" == "container" && "\${1:-}" == "build" ]]; then
  shift
  tag=""; cfile=""
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --tag) tag="\$2"; shift 2 ;;
      --file) cfile="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  img_add "\$tag"
  [[ -n "\$cfile" && -f "\$cfile" ]] && cp "\$cfile" "\${DC_STUB_APPLE_CFILE:?}"
  # Record LABELs from the Containerfile so label lookups work post-build.
  if [[ -n "\$cfile" && -f "\$cfile" ]]; then
    while IFS= read -r ln; do
      case "\$ln" in
        LABEL\ *) rest="\${ln#LABEL }"; for kv in \$rest; do label_set "\$tag" "\$kv"; done ;;
      esac
    done < "\$cfile"
  fi
  exit 0
fi

# --- ps / ps -a / ps --format / context show --------------------------------
if [[ "\${1:-}" == "ps" ]]; then
  fv="\$(fmt_val "\$@")"
  all=\$([[ "\${2:-}" == "-a" ]] && echo yes || echo no)
  if [[ "\$all" == yes ]]; then src="\$_exists"; else src="\$_running"; fi
  if [[ -z "\$fv" ]]; then
    awk 'NF' "\$src" 2>/dev/null
  else
    awk 'NF' "\$src" 2>/dev/null
  fi
  exit 0
fi
if [[ "\$me" == "docker" && "\${1:-}" == "context" && "\${2:-}" == "show" ]]; then
  printf 'default\n'; exit 0
fi

# --- create / start / stop / rm -f / delete / exec / volume / network -------
if [[ "\${1:-}" == "create" ]]; then
  # last positional is the image; --name <n> is the container name.
  name=""
  i=1
  while [[ \$i -le \$# ]]; do
    if [[ "\${!i}" == "--name" ]]; then nxt=\$((i+1)); name="\${!nxt}"; fi
    i=\$((i+1))
  done
  [[ -n "\$name" ]] && grep -Fxq "\$name" "\$_exists" 2>/dev/null || printf '%s\n' "\$name" >> "\$_exists"
  exit 0
fi
if [[ "\${1:-}" == "start" ]]; then printf '%s\n' "\${2:-}" >> "\$_running"; exit 0; fi
if [[ "\${1:-}" == "stop" ]]; then grep -Fxv "\${2:-}" "\$_running" > "\$_running.tmp" 2>/dev/null && mv "\$_running.tmp" "\$_running"; exit 0; fi
if [[ "\${1:-}" == "rm" && "\${2:-}" == "-f" ]]; then grep -Fxv "\${3:-}" "\$_exists" > "\$_exists.tmp" 2>/dev/null && mv "\$_exists.tmp" "\$_exists"; grep -Fxv "\${3:-}" "\$_running" > "\$_running.tmp" 2>/dev/null && mv "\$_running.tmp" "\$_running"; exit 0; fi
if [[ "\$me" == "container" && "\${1:-}" == "delete" ]]; then grep -Fxv "\${2:-}" "\$_exists" > "\$_exists.tmp" 2>/dev/null && mv "\$_exists.tmp" "\$_exists"; exit 0; fi
if [[ "\${1:-}" == "exec" || "\${1:-}" == "exec" ]]; then exit 0; fi
if [[ "\${1:-}" == "volume" || "\${1:-}" == "network" ]]; then exit 0; fi
if [[ "\${1:-}" == "info" ]]; then exit 0; fi

exit 0
STUB
chmod +x "$STUB_DIR/_stub"
cp "$STUB_DIR/_stub" "$STUB_DIR/docker"
cp "$STUB_DIR/_stub" "$STUB_DIR/container"
cp "$STUB_DIR/_stub" "$STUB_DIR/podman"

ORIG_PATH="$PATH"
run_script() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" \
  TZ="America/New_York" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" DC_STUB_LABELS="$LABELS" \
  DC_STUB_RUNNING="$RUNNING" DC_STUB_EXISTS="$EXISTS" \
  DC_STUB_APPLE_CFILE="$APPLE_CFILE" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="$BACKEND" \
  bash "$@"
}
first_call() { grep -En "$1" "$LOG" | head -n1 | cut -d: -f1; }

# ===========================================================================
# A. backend_container_commit dispatch (direct, docker-family + apple)
# ===========================================================================
# docker-family: native commit with --change LABEL forwarding.
BACKEND=docker
: > "$LOG"
DEV_CONTAINERS_BACKEND=docker _DC_CLI=docker PATH="$STUB_DIR:$ORIG_PATH" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" DC_STUB_LABELS="$LABELS" \
  DC_STUB_RUNNING="$RUNNING" DC_STUB_EXISTS="$EXISTS" DC_STUB_APPLE_CFILE="$APPLE_CFILE" \
  bash -c 'source "'"$ROOT_DIR"'/lib/common.sh"; source "'"$ROOT_DIR"'/lib/container-backend.sh"; backend_container_commit myproj snap:latest dce.snapshot.label=pre dce.snapshot.project=myproj' \
  >/dev/null 2>&1 || fail "backend_container_commit (docker) exited non-zero"
grep -Fq "CALL docker commit --change LABEL dce.snapshot.label=pre --change LABEL dce.snapshot.project=myproj myproj snap:latest" "$LOG" \
  || fail "docker commit argv wrong
$(grep '^CALL' "$LOG")"
pass "backend_container_commit (docker): native commit + --change LABEL forwarding"

# apple: export + inspect-base + FROM scratch build; USER dev re-applied.
BACKEND=apple
: > "$LOG"
# Ensure the container exists so apple export has a target.
printf 'appleproj\n' >> "$EXISTS"
DEV_CONTAINERS_BACKEND=apple _DC_CLI=container PATH="$STUB_DIR:$ORIG_PATH" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" DC_STUB_LABELS="$LABELS" \
  DC_STUB_RUNNING="$RUNNING" DC_STUB_EXISTS="$EXISTS" DC_STUB_APPLE_CFILE="$APPLE_CFILE" \
  bash -c 'source "'"$ROOT_DIR"'/lib/common.sh"; source "'"$ROOT_DIR"'/lib/container-backend.sh"; backend_container_commit appleproj dce-snap-appleproj-pre:latest dce.snapshot.project=appleproj dce.snapshot.label=pre dce.snapshot.base=dce-img-x:latest dce.snapshot.utc=2025-01-01T00:00:00Z' \
  >/dev/null 2>&1 || fail "backend_container_commit (apple) exited non-zero"
grep -Fq "CALL container inspect appleproj --format {{.ImageID}}" "$LOG" \
  || fail "apple: must inspect container for its image id"
grep -Fq "CALL container image inspect sha256:base-image --format {{.config.user}}" "$LOG" \
  || fail "apple: must inspect base image config (user)"
grep -Fq "CALL container export -o " "$LOG" || fail "apple: must export container FS"
grep -Eq "CALL container build --tag dce-snap-appleproj-pre:latest --file " "$LOG" \
  || fail "apple: must build the snapshot image"
[[ -f "$APPLE_CFILE" ]] || fail "apple: generated Containerfile not captured"
grep -Fq "FROM scratch" "$APPLE_CFILE" || fail "apple Containerfile: FROM scratch"
grep -Fq "ADD rootfs.tar /" "$APPLE_CFILE" || fail "apple Containerfile: ADD rootfs.tar /"
grep -Fxq "USER dev" "$APPLE_CFILE" || fail "apple Containerfile: must re-apply USER dev"
grep -Fxq "WORKDIR /workspace" "$APPLE_CFILE" || fail "apple Containerfile: must re-apply WORKDIR"
grep -Fq "ENV PATH=/usr/local/sbin:/usr/local/bin" "$APPLE_CFILE" || fail "apple Containerfile: ENV not re-applied"
grep -Fxq 'CMD ["/usr/local/bin/entrypoint"]' "$APPLE_CFILE" || fail "apple Containerfile: CMD JSON form wrong"
grep -Fq "LABEL dce.snapshot.project=appleproj dce.snapshot.label=pre" "$APPLE_CFILE" \
  || fail "apple Containerfile: LABEL provenance missing"
# apple also must not emit an ENTRYPOINT line when base has none ([]).
if grep -Fq "ENTRYPOINT" "$APPLE_CFILE"; then
  fail "apple Containerfile: must omit ENTRYPOINT when base has none"
fi
# The snapshot image now exists in the store.
img_has "dce-snap-appleproj-pre:latest" || fail "apple: snapshot image not registered"
pass "backend_container_commit (apple): export+inspect+FROM scratch build, USER dev re-applied"

# ===========================================================================
# Set up a real-ish project via `dce new` (docker) for the script-level tests.
# ===========================================================================
BACKEND=docker
PROJECT="myapp"
SECRET_DIR="$WORK/home/.config/dce-enclave/$PROJECT"
CONFIG="$SECRET_DIR/config"
: > "$LOG"
run_script "$ROOT_DIR/scripts/new-container.sh" "$PROJECT" nodejs 3000:3000 \
  >"$WORK/new.stdout" 2>"$WORK/new.stderr" || fail "dce new exited non-zero"
[[ -f "$CONFIG" ]] || fail "dce new: config not written"
chmod 600 "$CONFIG" 2>/dev/null || true
expected_img="$(dce_image_ref_from_scopes "$TEAM_OD" "$USER_OD" "nodejs")"
# Make the derived image "present" (dce new's build already added it; ensure so).
grep -Fxq "$expected_img" "$IMAGES" || printf '%s\n' "$expected_img" >> "$IMAGES"
# Container exists + is running (dce new created+started it).
grep -Fxq "$PROJECT" "$EXISTS" || printf '%s\n' "$PROJECT" >> "$EXISTS"
grep -Fxq "$PROJECT" "$RUNNING" || printf '%s\n' "$PROJECT" >> "$RUNNING"

# ===========================================================================
# B. dce snapshot: stop -> commit -> start; refuse overwrite; label validation
# ===========================================================================
snap_ref="$(dce_snapshot_ref "$PROJECT" "pre")"
: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" pre >"$WORK/snap.stdout" 2>"$WORK/snap.stderr" \
  || fail "dce snapshot exited non-zero
-- stderr:$(cat "$WORK/snap.stderr")"

# Commit happened with the snapshot ref + provenance labels.
grep -Fq "CALL docker commit --change LABEL dce.snapshot.project=myapp" "$LOG" \
  || fail "snapshot: docker commit with project label missing"
if ! grep -Fq "CALL docker commit" "$LOG" || ! grep -Fq "$snap_ref" "$LOG"; then
  fail "snapshot: commit did not target $snap_ref"
fi
# It was running -> stop then start observed, in that order.
stop_ln="$(first_call 'docker stop myapp')"
start_ln="$(first_call 'docker start myapp')"
commit_ln="$(first_call 'docker commit')"
[[ -n "$stop_ln" ]] || fail "snapshot: must stop a running container"
[[ -n "$start_ln" ]] || fail "snapshot: must restart the container"
[[ "$stop_ln" -lt "$commit_ln" ]] || fail "snapshot: stop must precede commit"
[[ "$commit_ln" -lt "$start_ln" ]] || fail "snapshot: commit must precede restart"
# Container is running again afterward.
grep -Fxq "$PROJECT" "$RUNNING" || fail "snapshot: container not restarted"
# Snapshot image registered.
img_has "$snap_ref" "$IMAGES" || fail "snapshot: image not registered"
pass "dce snapshot: stop -> commit -> start, provenance labels"

# Refuse to overwrite an existing label.
: > "$LOG"
if run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" pre \
      >"$WORK/snap2.stdout" 2>"$WORK/snap2.stderr"; then
  fail "dce snapshot: must refuse to overwrite an existing label"
fi
grep -Fqi 'already exists' "$WORK/snap2.stderr" || fail "snapshot: overwrite error message missing"
# No second commit attempted.
if grep -q 'docker commit' "$LOG"; then
  fail "snapshot: must not commit when refusing overwrite"
fi
pass "dce snapshot: refuses to overwrite an existing label"

# Label charset validation: reject a label with '/' (would escape the ref slot).
: > "$LOG"
if run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" "bad/label" \
      >"$WORK/snap3.stdout" 2>"$WORK/snap3.stderr"; then
  fail "dce snapshot: must reject a label containing '/'"
fi
grep -Fqi 'Invalid snapshot label' "$WORK/snap3.stderr" || fail "snapshot: label validation message missing"
pass "dce snapshot: validates label charset (rejects '/')"

# Default label is a sortable timestamp.
: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" >"$WORK/snap4.stdout" 2>"$WORK/snap4.stderr" \
  || fail "dce snapshot (default label) exited non-zero"
# A second snapshot ref with a timestamp-shaped label now exists for myapp.
if ! grep -Fxq "dce-snap-myapp-$(date -u +%Y%m%d)-" "$IMAGES" 2>/dev/null \
   && ! grep -qE '^dce-snap-myapp-[0-9]{8}-[0-9]{6}:latest$' "$IMAGES"; then
  fail "snapshot: default label should be a timestamp (got images: $(cat "$IMAGES"))"
fi
pass "dce snapshot: default label is a sortable timestamp"

# ===========================================================================
# C. dce snapshots list: filters by project, prints sizes
# ===========================================================================
# Add a snapshot for a second project so scoping is observable.
printf '%s\n' "dce-snap-other-v1:latest" >> "$IMAGES"
printf 'dce-snap-other-v1:latest\tdce.snapshot.project=other\n' >> "$LABELS"
# Make "other" a configured project so its slug resolves.
mkdir -p "$WORK/home/.config/dce-enclave/other"
printf 'CONTAINER_OVERLAY_SCOPES=""\n' > "$WORK/home/.config/dce-enclave/other/config"

: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" list "$PROJECT" >"$WORK/list1.stdout" 2>"$WORK/list1.stderr" \
  || fail "dce snapshots list <project> exited non-zero"
# myapp's snapshots appear; other's do not.
grep -Fq "pre" "$WORK/list1.stdout" || fail "snapshots list: myapp 'pre' missing"
if grep -Fq "other" "$WORK/list1.stdout"; then
  fail "snapshots list <myapp>: must not list 'other' project's snapshots"
fi
pass "dce snapshots list <project>: scoped to one project"

: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" list >"$WORK/list2.stdout" 2>"$WORK/list2.stderr" \
  || fail "dce snapshots list exited non-zero"
grep -Fq "pre" "$WORK/list2.stdout" || fail "snapshots list: 'pre' missing"
grep -Fq "other" "$WORK/list2.stdout" || fail "snapshots list: 'other' missing"
# Size column header present.
grep -Fq "SIZE" "$WORK/list2.stdout" || fail "snapshots list: SIZE column missing"
pass "dce snapshots list: lists all projects with a SIZE column"

# dce snapshot rm removes one snapshot image.
: > "$LOG"
run_script "$ROOT_DIR/scripts/snapshot.sh" rm "$PROJECT" pre >"$WORK/rm.stdout" 2>"$WORK/rm.stderr" \
  || fail "dce snapshot rm exited non-zero"
grep -Fq "CALL docker image rm $snap_ref" "$LOG" || fail "snapshot rm: image rm missing"
img_has "$snap_ref" "$IMAGES" && fail "snapshot rm: image still present" || true
pass "dce snapshot rm: removes one snapshot image"

# Re-create 'pre' for the clean/restore sections below.
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" pre >/dev/null 2>&1 \
  || fail "dce snapshot (re-create pre) exited non-zero"
img_has "$snap_ref" "$IMAGES" || fail "snapshot: re-create failed"

# ===========================================================================
# D. dce rebuild-container --from-snap: bypass scope derivation, no config write
# ===========================================================================
# Capture CONTAINER_IMAGE before; it must NOT change after a from-snap restore.
ci_before="$(dce_config_extract_scalar "$CONFIG" CONTAINER_IMAGE)" || ci_before=""
# Make the scope-DERIVED image ABSENT to prove --from-snap does not require it.
grep -Fxv "$expected_img" "$IMAGES" > "$IMAGES.tmp" && mv "$IMAGES.tmp" "$IMAGES"
img_has "$expected_img" "$IMAGES" && fail "test setup: derived image should be absent for --from-snap" || true
img_has "$snap_ref" "$IMAGES" || fail "test setup: snapshot must be present"

: > "$LOG"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" --from-snap pre \
  >"$WORK/rbfs.stdout" 2>"$WORK/rbfs.stderr" || fail "rebuild --from-snap exited non-zero
-- stderr:$(cat "$WORK/rbfs.stderr")"

# It must NOT have failed with the scope-image-missing guidance.
if grep -Fqi 'rebuild-image all' "$WORK/rbfs.stdout"; then
  fail "rebuild --from-snap: must not demand the scope-derived image"
fi
# The create call uses the SNAPSHOT ref, not the derived image.
rb_create="$(grep -E 'create --name myapp' "$LOG" | head -n1)"
[[ -n "$rb_create" ]] || fail "rebuild --from-snap: no create call"
grep -Fq -- "$snap_ref" <<<"$rb_create" || fail "rebuild --from-snap: create must use the snapshot ref
$rb_create"
# CONTAINER_IMAGE in config is unchanged (not rewritten to the snapshot).
ci_after="$(dce_config_extract_scalar "$CONFIG" CONTAINER_IMAGE)" || ci_after=""
[[ "$ci_before" == "$ci_after" ]] \
  || fail "rebuild --from-snap: must NOT rewrite CONTAINER_IMAGE (before=[$ci_before] after=[$ci_after])"
# Restore summary notes the stale-read signal.
grep -Fqi 'stale' "$WORK/rbfs.stdout" || fail "rebuild --from-snap: should note the stale-detection signal"
pass "rebuild-container --from-snap: bypasses scope derivation, no CONTAINER_IMAGE rewrite, recreates from snapshot"

# --from-snap fail-fast when the snapshot label is absent.
run_script "$ROOT_DIR/scripts/snapshot.sh" rm "$PROJECT" pre >/dev/null 2>&1 || true
: > "$LOG"
if printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" --from-snap pre \
      >"$WORK/rbmiss.stdout" 2>"$WORK/rbmiss.stderr"; then
  fail "rebuild --from-snap: must fail when the snapshot is missing"
fi
grep -Fqi 'snapshot' "$WORK/rbmiss.stdout" || fail "rebuild --from-snap: missing-snapshot error should name the snapshot"
if grep -qE 'rm -f myapp|create --name myapp' "$LOG"; then
  fail "rebuild --from-snap: must NOT issue destructive calls when the snapshot is missing"
fi
pass "rebuild-container --from-snap: fail-fast on missing snapshot (no destructive calls)"

# ===========================================================================
# E. dce clean: default ignores snapshots; --snapshots reclaims; dry-run/scoping
# ===========================================================================
# Recreate two snapshots: one for myapp, one for 'other'.
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" keep1 >/dev/null 2>&1 || fail "setup snapshot keep1"
run_script "$ROOT_DIR/scripts/snapshot.sh" "$PROJECT" keep2 >/dev/null 2>&1 || fail "setup snapshot keep2"
img_has "dce-snap-myapp-keep1:latest" "$IMAGES" || fail "setup: keep1 missing"
img_has "dce-snap-myapp-keep2:latest" "$IMAGES" || fail "setup: keep2 missing"

# Default clean leaves dce-snap-* untouched (is_managed_repo excludes them).
: > "$LOG"
run_script "$ROOT_DIR/scripts/clean.sh" --dry-run >"$WORK/clean_def.stdout" 2>"$WORK/clean_def.stderr" \
  || fail "dce clean (default, dry-run) exited non-zero"
img_has "dce-snap-myapp-keep1:latest" "$IMAGES" || fail "default clean: must not remove snapshots"
img_has "dce-snap-other-v1:latest" "$IMAGES" || fail "default clean: must not remove other's snapshot"
# Default clean must not even list dce-snap-* as removal candidates.
if grep -q 'dce-snap-' "$WORK/clean_def.stdout"; then
  fail "default clean: must not surface snapshots as removal candidates"
fi
pass "dce clean (default): leaves dce-snap-* untouched"

# --dry-run lists but removes nothing.
: > "$LOG"
run_script "$ROOT_DIR/scripts/clean.sh" --snapshots --dry-run >"$WORK/clean_dr.stdout" 2>"$WORK/clean_dr.stderr" \
  || fail "dce clean --snapshots --dry-run exited non-zero"
grep -Fq "dce-snap-myapp-keep1:latest" "$WORK/clean_dr.stdout" || fail "clean --snapshots --dry-run: must list keep1"
grep -Fq "dce-snap-other-v1:latest" "$WORK/clean_dr.stdout" || fail "clean --snapshots --dry-run: must list other"
img_has "dce-snap-myapp-keep1:latest" "$IMAGES" || fail "clean --dry-run: must NOT remove anything"
pass "dce clean --snapshots --dry-run: lists, removes nothing"

# --snapshots <project> scopes to that project only.
: > "$LOG"
run_script "$ROOT_DIR/scripts/clean.sh" --snapshots "$PROJECT" >"$WORK/clean_sc.stdout" 2>"$WORK/clean_sc.stderr" \
  || fail "dce clean --snapshots <project> exited non-zero"
img_has "dce-snap-myapp-keep1:latest" "$IMAGES" && fail "clean --snapshots <myapp>: keep1 should be removed" || true
img_has "dce-snap-myapp-keep2:latest" "$IMAGES" && fail "clean --snapshots <myapp>: keep2 should be removed" || true
# other's snapshot survives a myapp-scoped sweep.
img_has "dce-snap-other-v1:latest" "$IMAGES" || fail "clean --snapshots <myapp>: must not touch other's snapshot"
pass "dce clean --snapshots <project>: scoped reclamation"

# --snapshots (no project) reclaims the remainder (other-v1).
: > "$LOG"
run_script "$ROOT_DIR/scripts/clean.sh" --snapshots >"$WORK/clean_all.stdout" 2>"$WORK/clean_all.stderr" \
  || fail "dce clean --snapshots exited non-zero"
img_has "dce-snap-other-v1:latest" "$IMAGES" && fail "clean --snapshots: other-v1 should be removed" || true
# No dce-snap-* remain at all.
if grep -q '^dce-snap-' "$IMAGES"; then
  fail "clean --snapshots: snapshots remain
$(grep '^dce-snap-' "$IMAGES")"
fi
pass "dce clean --snapshots: reclaims all snapshots"

# --hidden-volumes and --snapshots are mutually exclusive.
if run_script "$ROOT_DIR/scripts/clean.sh" --hidden-volumes --snapshots \
      >"$WORK/clean_x.stdout" 2>"$WORK/clean_x.stderr"; then
  fail "dce clean: --hidden-volumes and --snapshots must be mutually exclusive"
fi
pass "dce clean: --hidden-volumes / --snapshots are mutually exclusive"

echo ""
echo "All snapshot checks passed."
